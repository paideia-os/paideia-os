# mfence discipline audit — R18-M5-002 (#776)

Enumeration of every cross-CPU synchronization site in the paideia-os
kernel where the ordering of same-CPU memory operations matters for
correctness under x86-TSO, and the rationale for each `mfence` (or its
absence).

## Model

x86-TSO (Intel SDM Vol 3A §8.2) permits reordering ONLY of a store
followed by a load to a different address (store-buffer forwarding
handles same-address). It forbids:

- Load-load reordering.
- Load-store reordering.
- Store-store reordering.

Under this model, `mfence` (SDM Vol 3A §8.2.5) is architecturally
required in two situations:

1. **Store → later-load-of-different-address must be ordered.** A plain
   store may sit in the store buffer while the later load bypasses it
   from cache. Only `mfence` or a `LOCK`-prefixed RMW drains the store
   buffer before the load issues.

2. **WB store → MMIO/UC store must be ordered.** WB stores may be
   reordered past MMIO/UC stores from the same CPU (SDM Vol 3A §11.3.1).
   Programming an APIC ICR (xAPIC MMIO) or IRET-ing to user code
   immediately after WB writes to peer-visible state is only correct
   with an intervening `mfence` (or a WRMSR / other serializing
   instruction).

`LOCK`-prefixed RMWs (`xchg mem, r`; `lock cmpxchg`; `lock xadd`;
etc.) are already full fences (SDM Vol 3A §8.1.2, §8.2.5) — an mfence
after such an instruction is redundant.

`INVLPG` is NOT in the SDM's list of serializing instructions (§8.3),
but its TLB effect is guaranteed to complete before the next
instruction executes on the same CPU (§4.10.4.1). This local-completion
guarantee, combined with TSO's in-program-order visibility of stores
from the same CPU (§8.2.2), gives the receiver-side of the shootdown
its ordering for free — see Site 3.

## Site inventory (HEAD after #776)

| # | Location | Site | mfence? | Rationale |
|---|----------|------|---------|-----------|
| 1 | `mm/tlb_shootdown.pdx` `tlb_shootdown_range` | After peer-CB writes (step b'), before IPI send | **YES (added)** | WB stores to peer CB[+88/+96/+104] must be globally visible before the xAPIC-MMIO / x2APIC-WRMSR IPI trigger; TSO does not order WB→UC (SDM §11.3.1). |
| 2 | `mm/tlb_shootdown.pdx` `tlb_shootdown_range` | After all peer acks observed (step e'), before return | **YES (added)** | Acquire-side of the shootdown rendezvous: ack-observation loads must happen-before the caller's follow-on writes (PTE teardown, frame free). Timeout path skips this — caller cannot safely proceed on timeout. |
| 3 | `ipi/vectors.pdx` `_ipi_handler_f2` | Between INVLPG loop and ack store | **NO** | INVLPG's local TLB effect is complete before the next instruction (SDM §4.10.4.1); TSO ensures the ack store from this CPU cannot become globally visible before the INVLPG effect. Documented inline; audit trail here. |
| 4 | `ipi/vectors.pdx` `_ipi_handler_f1` | After preempt_needed store | **NO** | preempt_needed is written and consumed by the SAME CPU (IRQ-tail preempt check on the receiver). Same-CPU store→load with store-buffer forwarding is TSO-correct (SDM §8.2.3.5). |
| 5 | `sync/spinlock.pdx` `spin_lock` | `xchg` publishing self as tail | Implicit | `xchg mem, r` is implicitly LOCK-prefixed (SDM Vol 2A §XCHG) — full fence. No additional mfence needed. Reviewed in #768. |
| 6 | `sync/spinlock.pdx` `spin_unlock` | `lock_cmpxchg` releasing lock | Implicit | LOCK prefix is a full fence. No additional mfence needed. Reviewed in #768. |
| 7 | `sync/atomic_refcount.pdx` `atomic_refcount_inc/dec` | `lock_xadd_q` | Implicit | LOCK prefix is a full fence. No additional mfence needed. Reviewed in #769. |
| 8 | `sync/atomic.pdx` `atomic_cas_u64` / `atomic_xadd_u64` / `atomic_xchg_u64` | Any LOCK-prefixed RMW | Implicit | LOCK prefix is a full fence. Reviewed in #770. |
| 9 | `sync/atomic.pdx` `atomic_store_u64` | After plain qword store | **NO (by design)** | Release semantics on x86 is delivered by TSO alone. Callers who need store-then-load ordering call `mem_barrier()` explicitly. Reviewed in #770. |
| 10 | `sync/atomic.pdx` `mem_barrier` | Standalone primitive | The mfence | This IS the mfence primitive callers use when they need one outside a LOCKed RMW. Reviewed in #770. |

## Ordering derivation

### Site 1 (initiator: CB writes → IPI send)

Initiator sequence:
```
  mov [peer_cb + 88], va_start     ; WB store
  mov [peer_cb + 96], va_end       ; WB store
  mov [peer_cb + 104], epoch+1     ; WB store
  mfence                            ; #776 fence
  call lapic_send_ipi_broadcast    ; MMIO store to LAPIC ICR page
                                    ; (or WRMSR for x2APIC, which is
                                    ;  itself serializing)
```

Without the mfence: on the xAPIC MMIO path, the store buffer may drain
the LAPIC ICR write BEFORE the CB stores, and the receiver could take
the IPI interrupt with `peer_cb + 88/96/104` still holding values from
a previous shootdown request. It would then INVLPG the wrong range and
publish ack==epoch(new), satisfying the initiator's poll for a flush
that never happened over the intended VAs.

The mfence forces store-buffer drainage before the MMIO write, so the
receiver's rdmsr-derived CB reads observe the new start/end/epoch.

On x2APIC-only builds a WRMSR IA32_X2APIC_ICR is itself fully
serializing (SDM Vol 2C §WRMSR) and the mfence is redundant — we fence
unconditionally because paideia-os targets both APIC modes.

### Site 2 (initiator: ack observation → caller's follow-on work)

Initiator sequence:
```
  mov rax, [peer_cb + 112]         ; ack load (bounded poll)
  cmp rax, epoch
  jae observed_ack
  ; ... poll loop ...
observed_ack:
  mfence                            ; #776 fence
  ; caller may now: unmap PTE, free frame, etc.
```

Under TSO, the initiator's post-poll loads/stores could in principle be
reordered so that the caller's subsequent store (a PTE teardown, say)
becomes globally visible before the ack observation completes on this
CPU. The mfence serializes: no subsequent memory op on this CPU can
issue until all pre-mfence loads (the ack chain) have completed and
all pre-mfence stores have drained.

The receiver-side pairing: `_ipi_handler_f2` executes INVLPG, then a
plain store to `CB[+112] = epoch`. Under TSO the ack store becomes
visible only after the INVLPG's local effect (Site 3 rationale). So
the combined initiator-fence + receiver-TSO chain gives:

```
  receiver INVLPG completes locally
    ↓ (TSO in-program-order same-CPU stores)
  receiver ack store visible globally
    ↓ (initiator poll observes)
  initiator mfence
    ↓
  initiator's subsequent PTE teardown / frame free
```

The frame is safe to free.

### Site 3 (receiver: INVLPG → ack store — NO mfence)

Receiver sequence:
```
  invlpg [rsi]                      ; TLB flush for one page
  ; ... loop over range ...
  mov [cb + 112], epoch             ; ack store
```

Two guarantees combine:

1. SDM Vol 3A §4.10.4.1: "The INVLPG instruction is guaranteed to
   invalidate any translation from the linear address to the physical
   frame in TLB caches. Instructions that follow INVLPG in program
   order are guaranteed to execute after the invalidation is complete."
2. SDM Vol 3A §8.2.2 (x86-TSO): stores from a single CPU become
   globally visible in program order.

Therefore the ack store cannot be observed by any other CPU before the
INVLPG's local effect is complete. No additional fence is required
here.

If a future memory-model weakening (or a non-Intel-authorized fork of
the architecture) broke §4.10.4.1 in isolation, we would add an mfence
here. Today, the receiver-side handler is a tight `invlpg → ack`
sequence and the extra fence would add ~15 cycles per shootdown
without any correctness benefit.

### Site 4 (receiver: preempt_needed store — NO mfence)

`_ipi_handler_f1` writes `[gs:PERCPU_OFF_PREEMPT_NEEDED] = 1`. The
consumer is the IRQ-tail preempt check on the SAME CPU (currently the
`trampoline_vec32` tail in `core/int/idt.pdx`; syscall-return and
#PF-return tail checks join in R18.M4). Same-CPU store → same-CPU load
is TSO-correct via store-buffer forwarding (SDM §8.2.3.5).

Cross-CPU: no other CPU ever reads `preempt_needed` on this CPU's CB
— the field is strictly per-CPU-owned. No fence required.

## Related audit

- `design/multicore/swapgs-audit.md` — pairing invariant for SWAPGS
  under R18-M2 (#766). Ordering discipline for the `swapgs` sequence
  is unrelated to memory-ordering fences: SWAPGS is a fully
  serializing MSR swap and does not need mfence bracketing.

## Followup

- **R18.M4+ runq**: adding per-CPU runqueue enqueue/dequeue on the IPI
  path introduces new cross-CPU sites — every enqueue by one CPU that
  is drained by another CPU needs a Site 1-style fence pattern. Fold
  into this table when R18.M4-004 (per-CPU runq) lands.
- **R18.M4+ syscall / #PF tail preempt checks**: adds new consumers of
  `preempt_needed`. Same rationale as Site 4 (same-CPU only) applies
  as long as the flag is never mirrored across CPUs.
- **INVPCID upgrade**: when the paideia-as encoder gains INVPCID
  support, the receiver-side `invlpg` loop collapses to a single
  `invpcid`. INVPCID has the same local-completion guarantee as INVLPG
  (SDM Vol 2A §INVPCID), so Site 3's rationale carries over unchanged.
- **Non-Intel bring-up**: AMD's memory model is the same TSO variant
  as Intel's (AMD APM Vol 2 §7.2). Neither adds nor removes fence
  requirements. No audit update required for AMD.
- **Aarch64 port (R30+)**: the entire table would be re-derived under
  the aarch64 weak memory model; every "NO mfence — TSO delivers it"
  cell becomes a `dmb`/`dsb`/`isb` decision. Out of scope for R18.

## Change log

- 2026-08-09 — Initial audit landed with #776 R18-M5-002. Added Site 1
  and Site 2 mfences to `tlb_shootdown_range`. Documented Sites 3 and
  4 as intentionally-no-fence with inline SDM citations. Confirmed
  Sites 5-10 already fenced (implicit LOCK) or intentionally
  unfenced (release-store discipline) from #768/#769/#770.
