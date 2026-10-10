# PaideiaOS — KIND_HW_TIMELINE: hardware clock-domain-crossing timeline capability

**Status:** Draft v0.1 (frozen for Wave 59 D3 skeleton landing)
**Date:** 2026-10-10
**Wave / issue:** Wave 59 D3 (paideia-os#2520); first consumers R33 (audio), R37 (GPU), R34 (USB isoch)
**Repository:** paideia-os (kernel-side primitive); paideia-as (encoder gate)
**Scope:** Specify the capability shape for a cross-domain monotonic timeline — a `KIND_HW_TIMELINE` cap that generalizes the Vulkan timeline-semaphore / drm-syncobj primitive to arbitrary hardware clock domains (GPU seqno queues, HDA stream positions, USB SOF framecounts) *and* a pure-CPU software-fed variant for userspace coordination. Pins row layout, mint/revoke/signal/wait semantics, the shared-memory view that lets a hardware counter write enter the timeline without a kernel round-trip, witness fingerprints, and the three-consumer walkthrough.

---

## Hard inputs (do not relitigate)

- `design/00-feature-inventory.md` — U4 (audio), R37 (GPU), R34 (USB isoch).
- `design/01-foundational-decisions.md` — Q6, Q13, Q14; `design/capabilities/linearity-and-tags.md` §3 base-kind freeze.
- `design/architecture/next-wave-derived-kinds.md` §KIND_HW_TIMELINE — the planning skeleton this document realizes: base `KIND_HW = 14`, derived tag `0x143`, descriptor tail `{monotonic_ns_offset:i64, resolution_ns:u32, source, clock_id}`. The planning skeleton covered the CPU-sampling case only; this document extends it to timeline-semaphore shape (counter + wait/signal) and keeps the base + tag.
- `design/drivers/kind-interrupt.md` — sibling R29 derived-kind doc; this document reuses its witness convention + section shape.
- `design/drivers/kind-dma-domain.md` — sibling R29 derived-kind doc; this document reuses its KIND-row-layout + mint/revoke/cascade vocabulary.
- `design/kernel/kind-surface-mint.md` — the mint-op-arg packing idiom (opcode in `op_arg[7:0]`; payload in high bits).
- `src/kernel/core/cap/kind.pdx` — base-kind slot allocation; the R29 derived-kind block already pins `0x143` as "timeline reserved" (header comment line 275).
- `src/kernel/core/cap/kind_hw_interrupt.pdx` — the row-indirection substrate shape this cap copies verbatim.
- `src/kernel/core/cap/kind_hw_msix_vector.pdx` — the cascade-by-parent walker shape this cap composes.
- `src/kernel/core/notification/*` — the paired `KIND_NOTIFICATION` cap, pre-existing; used for wait-side blocking (see §2.3).
- `src/kernel/core/apic/hpet.pdx`, `src/kernel/core/apic/tsc.pdx` — the CPU-side time sources `waited_us` is measured against.

---

## 0. Decisions summary

### 0.1 Inherited (binding)

| Source | Constraint |
|---|---|
| Pillar 3 (microkernel) | The kernel owns the row that *names* the timeline + the wait queue; the HW-fed counter view is in a shared-memory page the device writes directly, with no kernel round-trip on signal. |
| Pillar 6 (security by construction) | No ambient signal authority. A holder of only `R_TL_WAIT` can observe counter values; it cannot advance them. A HW-fed timeline whose counter page the kernel did not stamp into the mapping cannot be signaled. |
| Pillar 9 (hierarchically defined) | A timeline derives from a parent authority: either `KIND_HW` (for a HW-fed timeline, authorizing the kernel to stamp the counter MMIO window into a shared view) or `KIND_NOTIFICATION` (for a SW-fed timeline, authorizing the kernel to allocate a wait queue). Both parents land in the same derived tag. |
| CAP freeze (base kinds) | 16 base kinds frozen. `KIND_HW = 14` is the base; `0x143` is the derived tag (adjacent to `0x140`/`0x141`/`0x142` in the R29 block, already reserved for timeline in `kind.pdx` and `kind_dma_domain.pdx`). Nothing new gets a base slot. |

### 0.2 New decisions in this document

| # | Choice | Rationale |
|---|---|---|
| **TL-D1** | **`KIND_HW_TIMELINE` is a single derived kind serving BOTH the hardware-fed and software-fed variants.** The `hw_backed` bit in the row distinguishes them. Signaling is cheap in both variants; the kernel path differs only on wake. | Two derived tags for "monotonic 64-bit counter with wait semantics" would fragment the wait path across two handlers for no observable gain. The hw/sw split is a bit in the row, not a tag split. |
| **TL-D2** | **Base kind = `KIND_HW` (14). Derived tag = `0x143`.** Keeps the name honest for the primary case (HW-fed timelines backed by iGPU seqno queues, HDA LPIB, USB SOF framecounts), continues the R29 derived-kind block contiguity (0x140 int / 0x141 msix / 0x142 dma / 0x143 timeline), and matches the planning catalog without renaming. | Unlike `KIND_DMA_DOMAIN` (which was re-based because `KIND_HW` would have let a device-authority holder manufacture memory reach), a timeline cap does NOT authorize memory reach; it authorizes synchronization. The parent `KIND_HW` cap authorizes "the kernel may stamp a BAR window into a view I provide" for the HW-fed case; for the SW-fed case, the mint gate accepts `KIND_NOTIFICATION` as an alternate parent (see §2.1). The dual-parent gate is honest about both variants. |
| **TL-D3** | **A timeline's counter is a monotonic 64-bit value owned by the cap holder.** `cap_timeline_signal(cap, value)` is strictly-monotonic: a signal with `value <= current` returns `TL_SIGNAL_NONMONOTONIC`. `cap_timeline_wait(cap, >=value, timeout)` blocks until the counter reaches or exceeds `value`, or the timeout expires. | Matches Vulkan `VK_KHR_timeline_semaphore` + drm-syncobj timeline-mode semantics verbatim; keeps GPU driver bring-up at R37 straight transliteration. Rejecting non-monotonic advances closes the "signal-stale-value races the wait" class of bugs by construction. |
| **TL-D4** | **HW-fed signaling bypasses the kernel.** The row carries a `counter_view_pa` — a 4 KiB kernel-owned page mapped into the driver's aspace read-write. The hardware writes its monotonic counter into bytes `[0..8]` of this page via its own MMIO or DMA path (iGPU seqno write, HDA LPIB, USB SOF). `cap_timeline_signal` on a HW-fed cap is a `mfence; mov [counter_view_pa], value; sfence` sequence from userspace — no syscall, no cap_invoke, no scheduler wake. The wait side sees the new value by load. | A hardware timeline that costs a syscall per advance is a hardware timeline nobody uses. Vulkan sync-fd and drm-syncobj took this hit historically; Linux's timeline-semaphore v2 reaches sub-microsecond signal because the kernel is off this path. Our shared view is strictly simpler than Linux's futex-over-syncobj dance: one write, two fences, done. The waking semantics are §2.4. |
| **TL-D5** | **Wait is kernel-mediated through a paired `KIND_NOTIFICATION`.** Every timeline cap carries a `notif_slot` pointing at a `KIND_NOTIFICATION` cap the holder owns. `cap_timeline_wait(cap, >=target, timeout)` arms a waiter record (`{notif_slot, target, deadline}`) in the row's wait list and calls `notif_wait` on the paired notification. The signaler side (both HW and SW variants) is responsible for an explicit "post" — but the HW-fed variant posts cheaply: see §2.4. | Separation of signal (fast path, no kernel) and wake (requires scheduler cooperation) is forced by the microkernel pillar: the kernel cannot be absent from a wake path, so the signaler either (a) accepts a syscall cost to wake, or (b) accepts polling. Our choice is (a) — the HW signaler posts an edge-trigger via a dedicated per-timeline "doorbell notification" the kernel pre-arms on mint. The scheduler wakes the waiter; the waiter re-reads the counter and decides to proceed or re-arm. |
| **TL-D6** | **Row-indirection tail**, 32 bytes, identical shape to KIND_HW_INTERRUPT / KIND_HW_MSIX_VECTOR / KIND_DMA_DOMAIN. `target_ptr` holds `row_id` in bits [15:0]; the row is `_hw_timeline_table[row_id]`. | Fourth consecutive R29-era derived kind under this shape; a different encoding would fragment the revoke/cascade reasoning across the family. |
| **TL-D7** | **Table cap: `HW_TIMELINE_MAX = 64`.** One timeline per driver + ample headroom for GPU-engine sub-timelines (RCS, BCS, VECS, VCS, VECS2 at Iris Xe = 5 per driver + 1 for the engine group) + HDA stream positions (up to 15 streams per controller) + USB SOF (one per xHCI controller). 64 × 32 = 2 KiB .bss. | Same ceiling philosophy as KIND_HW_INTERRUPT (also 64): the reachable set is bounded by the device census, not by an abstract scaling target. |
| **TL-D8** | **Cascade on parent revoke.** When the parent `KIND_HW` (or `KIND_NOTIFICATION`) cap is revoked, every timeline deriving from it is auto-revoked by a walker. The signal view mapping is torn down with the row. | Dangling timeline past parent-revoke would leave a stale shared-mem view the device could still DMA into — the exact bug `kind-dma-domain.md §2.5` closes for memory reach, closed here for sync state. |

### 0.3 Three meta-positions

1. **A timeline is NOT a notification.** A notification is a single-bit event: either signaled or not. A timeline is a monotonic counter: the state space is `u64`, and *every* intermediate value is observable through `cap_timeline_wait`. The holder of a timeline cap can wait on `value >= 7` and `value >= 42` concurrently; the holder of a notification cap can only wait on "has it fired". The derivation `KIND_NOTIFICATION → KIND_HW_TIMELINE` reflects "a timeline is a strictly richer sync primitive"; the derived tag is distinct because the handler + the row shape are different.

2. **The hardware is the signaler, not the authority.** The authority to signal a HW-fed timeline is held by whoever maps the counter view page as writable. In practice that is the device itself (via its DMA domain) + the driver (which also sees the page for liveness checks). The kernel is NOT the signaler, and does NOT validate every write. What the kernel validates is at *mint* time: the counter_view_pa must be a page the holder has `R_TL_SIGNAL` authority to designate, which it establishes by presenting an unforgeable `KIND_HW` ancestor cap (through which the kernel accepts the BAR-mapped source), and the kernel stamps the page's physical address into the row.

3. **Software timelines pay for being software.** A SW-fed timeline's `cap_timeline_signal` traps into the kernel because userspace cannot wake another userspace waiter without going through the scheduler. That is not a design regression; it is the irreducible cost of software coordination without hardware atomics shared with the kernel. The HW-fed path saves ~2 μs per signal; the SW-fed path matches a futex wake. Consumers choose based on signal frequency.

---

## 1. Capability shape

### 1.1 Tag layout

The base-kind slot is 14 (`KIND_HW`), already allocated in `src/kernel/core/cap/kind.pdx`. The derived-tag value is `0x143` — reserved for timeline across `kind.pdx` (line 275), `kind_dma_domain.pdx` (line 54), and `kind_op_region.pdx` (line 226) since the R29.M5 landing.

```
Base-kind enum (16 slots, frozen)        Derived tags (u64 kind field)
  0: KIND_NULL                          0x140: KIND_HW_INTERRUPT        (sibling, R29.M1)
  1: KIND_PROCESS                       0x141: KIND_HW_MSIX_VECTOR      (sibling, R29.M1)
  ...                                   0x142: KIND_DMA_DOMAIN          (sibling, R29.M5)
 12: KIND_NOTIFICATION  <-- alt parent  0x143: KIND_HW_TIMELINE         (this document)
 14: KIND_HW  <-- base                  0x144..0x14F: reserved (R29 block)
```

LAM kind-hint fast-dispatch on bits [62:59] uses the base slot (14). On slot 14 the handler is a dispatch shim that reads the full u64 kind field at descriptor offset 0 and routes to the `0x140`/`0x141`/`0x143` branches. The MSI-X-vector branch (`0x141`) already demonstrates the shared-base-slot dispatch pattern; this cap is a third tenant of slot 14.

### 1.2 Descriptor tail (16-byte header + 16-byte tail)

A cap descriptor is 32 bytes total: 16-byte header + 16-byte kind-specific tail. `target_ptr` in the tail header holds `row_id` in bits [15:0]; bits [63:16] MUST be zero. The row at `_hw_timeline_table[row_id]` carries 32 bytes (four u64s):

| Offset | Bits    | Field               | Meaning |
|-------:|---------|---|---|
|   +0   | [31:0]  | `clock_id`          | u32; opaque identifier scoped to the parent `KIND_HW` cap. For GPU seqno queues this is `(engine_class << 16) | engine_instance`; for HDA this is the stream_index; for USB this is `(bus_id << 8) | 0` for SOF. |
|   +0   | [47:32] | `source`            | u16; 0 = SW_FED, 1 = GPU_SEQNO, 2 = HDA_LPIB, 3 = USB_SOF, 4 = TSC_DERIVED, 5..0xFFFF reserved. |
|   +0   | [55:48] | `flags`             | u8; bit 0 = `HW_BACKED` (shadows source != SW_FED, materialized for one-byte read), bit 1 = `WAIT_QUEUE_PRESENT`, bits 2..7 reserved. |
|   +0   | [63:56] | `in_use`            | u8; 0 = free, 1 = allocated. |
|   +8   | [63:0]  | `counter_view_pa`   | u64; physical address of a 4 KiB kernel-owned page whose first 8 bytes hold the monotonic counter. For SW-fed timelines, this points at a kernel-owned page bound to the timeline's row; for HW-fed timelines, the kernel stamps in a BAR-backed PA at mint. |
|  +16   | [15:0]  | `parent_slot`       | u16; cap_table slot of the KIND_HW (or KIND_NOTIFICATION) ancestor. Used by the cascade walker. |
|  +16   | [31:16] | `notif_slot`        | u16; cap_table slot of the paired KIND_NOTIFICATION for wake delivery. |
|  +16   | [47:32] | `wait_head`         | u16; head of the per-timeline wait list stored in `_hw_timeline_waiters[]`. 0xFFFF = empty. |
|  +16   | [63:48] | `resolution_ns`     | u16; counter tick in nanoseconds, 0 = "device-defined, unitless". Used only by observers to interpret `OP_SAMPLE` results. |
|  +24   | [63:0]  | `last_signaled`     | u64; snapshot of the last signaled value (updated by the kernel on syscall-mediated signal; stale for HW-fed signals, by construction). Observable via `OP_QUERY_LAST`. |

Total: 32 bytes exactly, no padding.

**Why `last_signaled` is a snapshot, not the truth.** For HW-fed timelines the authoritative value lives in the counter view page; `last_signaled` is a tracing/observability aid updated by the kernel only when a syscall-mediated signal happens. A wait path NEVER consults `last_signaled`; it reads `[counter_view_pa]` directly (through a kernel mapping or the view page itself).

### 1.3 Rights

```
R_TL_WAIT       = 0x01   // cap_timeline_wait: observe + block on value
R_TL_SIGNAL     = 0x02   // cap_timeline_signal: advance the counter
R_TL_OBSERVE    = 0x10   // OP_SAMPLE / OP_QUERY_* snapshot ops
R_TL_REBIND     = 0x20   // supervisor path: re-point notif_slot or counter_view_pa
R_TL_REVOKE     = 0x40   // supervisor revoke
R_TL_ALL        = 0x73
```

A GPU driver typically holds `R_TL_SIGNAL | R_TL_OBSERVE = 0x12` on a HW-fed timeline it owns the backing BAR for; a userspace waiter holds `R_TL_WAIT | R_TL_OBSERVE = 0x11`; the supervisor holds the remainder. Default-mint hands out `R_TL_WAIT | R_TL_SIGNAL | R_TL_OBSERVE = 0x13`.

### 1.4 Ops surface

Dispatch is through `cap_handler_hw_timeline(rights, target_ptr, op_arg)` with `op_arg[7:0]` as the ordinal, bits [63:8] as the payload per the `kind-surface-mint.md` packing idiom:

| Ordinal | Name              | Rights          | Payload | Returns |
|--------:|---|---|---|---|
| 0       | `OP_SAMPLE`       | `R_TL_OBSERVE`  | — | current counter value (reads from counter_view_pa) |
| 1       | `OP_QUERY_SOURCE` | `R_TL_OBSERVE`  | — | source u64 (0..5) |
| 2       | `OP_QUERY_CLOCK_ID` | `R_TL_OBSERVE` | — | clock_id u64 |
| 3       | `OP_QUERY_LAST`   | `R_TL_OBSERVE`  | — | `last_signaled` snapshot |
| 4       | `OP_QUERY_RESOLUTION` | `R_TL_OBSERVE` | — | resolution_ns |
| 5       | `OP_SIGNAL`       | `R_TL_SIGNAL`   | `value:u56 << 8` (low 56 bits of target), or `value_ptr:u56` for full-u64 signals | `TL_SIGNAL_OK` / `TL_SIGNAL_NONMONOTONIC` / `INVOKE_DENIED` |
| 6       | `OP_WAIT`         | `R_TL_WAIT`     | `target:u56 << 8` + a second syscall arg for timeout | `TL_WAIT_OK` / `TL_WAIT_TIMEOUT` |
| 7       | `OP_BIND_NOTIF`   | `R_TL_REBIND`   | `notif_slot:u16 << 8` | 0 |
| 8       | `OP_SNAPSHOT_SIG` | `R_TL_SIGNAL` + `R_TL_OBSERVE` | — | current counter value AND the row's `last_signaled` updated to it (reconciliation op; see §2.6) |

Any op whose rights check fails returns `INVOKE_DENIED` (`0xFFFFFFFFFFFFFFFD`). An unknown ordinal returns `INVOKE_UNSUPPORTED` (`0xFFFFFFFFFFFFFFFC`). Return-code lane matches every other kind handler.

**Why `OP_SIGNAL` has a 56-bit immediate path AND a pointer path.** The common case for GPU seqno writes is a monotonically increasing u64 that quickly exceeds 2^56. The immediate path (`value` fits in op_arg bits [63:8]) is a syscall-free fast path for the first ~75 million signals (2^56 / 2^30 bytes-per-tick for GPU). Above that, or for timeline consumers using full-u64 clock_id values (TSC-derived variant), the pointer path reads the 8-byte value from the holder's VA — one `user_mem_copy_in` cost per signal, but still trivially bounded.

### 1.5 Revoke semantics

`cap_revoke(slot)` on a `KIND_HW_TIMELINE` cap:

1. Reads the descriptor; validates `kind == 0x143`.
2. Walks the row's wait list (`wait_head`), sets each pending waiter's abort flag, and posts their paired notifications so they return `TL_WAIT_ABORTED`.
3. Unmaps the counter view page from the holder's aspace (for SW-fed) or clears the row's `counter_view_pa` reference (for HW-fed; the BAR mapping is torn down with the parent `KIND_HW` cap).
4. Zeros the row (dropping `in_use`), clears the descriptor.
5. Does NOT cascade to the paired notification. A `KIND_NOTIFICATION` is a first-class long-lived object; the holder may keep it to pair with a different timeline. Revoking the notification is a separate `cap_revoke(notif_slot)` call.
6. Emits witness `TL REVOKE OK slot=0x<nn>`.

Idempotent: revoke on an already-revoked slot returns `TL_REVOKE_ALREADY` without side effects.

Cascade from parent: `hw_cap_revoke` extends its walker to `kind == 0x143` children by matching `parent_slot`. Invariant: no dangling timeline cap after its parent `KIND_HW` is revoked.

---

## 2. Lifecycle

### 2.1 Mint

```
                    cap_mint(KIND_HW_TIMELINE, args)
                                 │
                                 ▼
                 ┌──────────── sanity checks ────────────┐
                 │  source ∈ {0..5}                       │
                 │  rights ⊆ R_TL_ALL                     │
                 │  notif_slot: cap_table[n].kind         │
                 │              == KIND_NOTIFICATION      │
                 │  parent_slot:                          │
                 │    for HW-fed: cap_table[p].kind       │
                 │                == KIND_HW,             │
                 │                parent.rights & R_HW_MINT│
                 │    for SW-fed: cap_table[p].kind       │
                 │                == KIND_NOTIFICATION,   │
                 │                parent.rights & R_NOTIFY_MINT│
                 └───────────────────┬────────────────────┘
                                     │
                 ┌───────────────────▼────────────────────┐
                 │  Allocate counter_view page:           │
                 │   HW-fed: kernel reads the parent      │
                 │     KIND_HW row for the BAR PA +       │
                 │     offset; stamps PA into row.        │
                 │   SW-fed: kernel allocates a fresh     │
                 │     4 KiB frame via phys_alloc; zeros  │
                 │     it; records PA in row.             │
                 │  Both: aspace_map(RW) into the holder. │
                 └───────────────────┬────────────────────┘
                                     │
                 ┌───────────────────▼────────────────────┐
                 │  Row claim at _hw_timeline_table[r]:   │
                 │   [+0]  = packed(clock_id, source,     │
                 │                   flags, in_use=1)     │
                 │   [+8]  = counter_view_pa              │
                 │   [+16] = packed(parent_slot,          │
                 │           notif_slot, 0xFFFF, res_ns)  │
                 │   [+24] = 0 (last_signaled)            │
                 └───────────────────┬────────────────────┘
                                     │
                                     ▼
                       witness `TL MINT OK slot=0x<nn> hw=<0|1>`
```

Mint return codes (`block 0xFFFFFFCF..0xFFFFFFDF` — disjoint from DMA_* and MSIX_*):

```
TL_MINT_OK            = 0
TL_MINT_BAD_SOURCE    = 0xFFFFFFCF   // source outside {0..5}
TL_MINT_BAD_RIGHTS    = 0xFFFFFFCE   // rights ⊄ R_TL_ALL
TL_MINT_BAD_PARENT    = 0xFFFFFFCD   // parent slot wrong kind or missing MINT
TL_MINT_BAD_NOTIF     = 0xFFFFFFCC   // notif slot wrong kind or missing RECV
TL_MINT_ENOSPC        = 0xFFFFFFCB   // table full
TL_MINT_BAD_VIEW      = 0xFFFFFFCA   // HW-fed: counter_view_pa not in parent's reach
```

### 2.2 Signal: SW-fed path

`cap_timeline_signal(cap, value)` on a SW-fed timeline:

1. Syscall entry; cap_invoke dispatches `OP_SIGNAL` to the timeline handler.
2. Handler reads the current counter from `[counter_view_pa]`; if `value <= current`, returns `TL_SIGNAL_NONMONOTONIC`.
3. Handler writes `value` to `[counter_view_pa]` (kernel mapping is pre-pinned at mint).
4. Handler walks the row's wait list; for each waiter whose `target <= value`, posts the waiter's notification + removes them from the list.
5. Updates `last_signaled = value`.
6. Emits `TL SIGNAL OK val=<value>` and returns.

Cost: one syscall + one list walk + N notification posts. For a GPU-driver command-queue that signals 10 Hz, this is negligible; for a 100 kHz audio-mclk timeline, this would be prohibitive — which is why audio-mclk uses the HW-fed path (source = `HDA_LPIB`).

### 2.3 Signal: HW-fed path

HW-fed `cap_timeline_signal` does NOT enter the kernel on the signal side at all. The driver (or the device, via its DMA domain) writes directly to the counter view page:

```asm
; driver-side, no syscall
mov rax, <new_value>
mfence                            ; ordering vs. prior memory ops the signal describes
mov [counter_view_va], rax        ; publish
sfence                            ; publish is visible to subsequent loads
```

For the device-side case (GPU seqno queue writing the counter via its own DMA path), the hardware is responsible for the fence equivalent — Intel iGPU seqno writes are posted-write-visible-after-sfence per Intel iGPU PRM (see §4.2); HDA LPIB updates are coherent-DMA writes governed by the device's own ordering model.

The wake side is where the kernel re-enters: §2.4.

### 2.4 Wake delivery for HW-fed timelines

A device writing the counter does not know who is waiting; the kernel does, because every waiter arms itself through `cap_timeline_wait`. The kernel-side wake path uses one of two mechanisms:

- **Polling by scheduler tick (default for low-rate timelines).** The scheduler, on each tick, walks `_hw_timeline_waiters` and for each armed waiter re-reads `[counter_view_pa]` and compares against the target. This is O(N_waiters) per tick, which is bounded (≤64 timelines × ≤8 waiters each ≈ 512 u64 reads per tick) and runs on the idle shoulder.
- **Doorbell interrupt (opt-in for high-rate timelines).** The device's own IRQ (via `KIND_INTERRUPT`) is the wake trigger. On mint, the holder may pass a doorbell `KIND_INTERRUPT` cap slot; the kernel's IRQ handler for that vector walks the row's wait list and wakes waiters whose target has been reached. Cost: one IRQ per signal batch (not per signal), amortized over the batch.

The default is polling because it needs no additional cap plumbing. GPU drivers at R37 upgrade to the doorbell path because their signal rate (~1 kHz per engine, ~5 engines = ~5 kHz) exceeds the scheduler tick (1 kHz).

### 2.5 Wait

`cap_timeline_wait(cap, target, timeout)` on either variant:

1. Syscall entry; handler reads the current counter from `[counter_view_pa]`.
2. If `current >= target`, returns `TL_WAIT_OK` immediately (fast path for already-passed targets).
3. Else, allocates a waiter record at `_hw_timeline_waiters[free_slot]` with `{notif_slot, target, deadline = now + timeout}` and splices it into the row's wait list at `wait_head`.
4. Calls `notif_wait(notif_slot, timeout)` which blocks the caller.
5. On wake (either from scheduler-poll match, doorbell IRQ, or timeout):
   - Re-reads `[counter_view_pa]`; if `current >= target`, waiter record is removed, witness `TL WAIT UNBLOCK val=<current> waited_us=<Δ>` is emitted, returns `TL_WAIT_OK`.
   - If timeout expired, waiter record is removed, emits `TL WAIT TIMEOUT val=<current> target=<target> waited_us=<Δ>`, returns `TL_WAIT_TIMEOUT`.
   - If parent revoked, returns `TL_WAIT_ABORTED`.

`waited_us` is measured from `cap_timeline_wait` entry (sampled from the HPET or TSC counter captured at step 1) to wake (sampled again at step 5). The two-sample Δ in microseconds is the fingerprint value.

### 2.6 Reconciliation (`OP_SNAPSHOT_SIG`)

For HW-fed timelines, `last_signaled` is stale by construction — the kernel is off the signal path. `OP_SNAPSHOT_SIG` is a kernel-mediated "fetch current counter and copy it into last_signaled" op that lets a supervisor observe the device's progress without a stall. The supervisor runs it on a cadence (default 10 Hz) for every HW-fed timeline it tracks; the row's `last_signaled` becomes the canonical "where did we last see this device" for the dmesg / debug consumer.

The op requires BOTH `R_TL_SIGNAL` and `R_TL_OBSERVE` because the writer touches the row (signal-class authority) *and* reads a derivable truth (observe-class). Supervisor holds both.

---

## 3. Shared-mem view: how a HW counter write enters the timeline

The crux of this cap. For a HW-fed timeline, the counter page is a 4 KiB physical frame whose address lives in `counter_view_pa`. The frame is mapped:

1. **Into kernel aspace** at a fixed-offset window (`_hw_timeline_views[row_id]` → kernel VA computed as `_HW_TIMELINE_VIEW_BASE + row_id * 4096`). The kernel reads `[counter_view_pa]` from this VA. Needed for `OP_SAMPLE`, `cap_timeline_wait`'s step 1, and the scheduler-poll walker.
2. **Into the holder's user aspace** at a VA chosen by the holder (passed as a mint argument). Readable; also writable if the holder has `R_TL_SIGNAL`. This is the window the driver writes to on HW-fed signal.
3. **Into the device's DMA domain** (for the device-side-written variants: GPU seqno, HDA LPIB). The driver uses its `KIND_DMA_DOMAIN` cap to map the page's IOVA; the device programs its seqno-write MMIO register with that IOVA; thereafter the device writes update the page's first 8 bytes with no CPU involvement.

### 3.1 Ordering guarantees

The ordering surface a holder needs on the write side:

- **Signaler → waiter visibility.** After the write + sfence, any reader (kernel-side on `cap_timeline_wait`'s step 1, or driver-side polling) sees the new value. On x86-64 this is TSO-guaranteed for aligned 8-byte stores (SDM Vol 3A §9.1.1); the sfence is a defense-in-depth belt for consumers that mix WB and WC memory. For WC-mapped seqno pages (iGPU default), the sfence is load-bearing.
- **Device → kernel visibility.** The device's write path is governed by its own ordering model. For Intel iGPU, the seqno-write MMIO (`RING_HWS_PGA` + the device's `MI_FLUSH_DW` → `PIPE_CONTROL` chain) guarantees the counter write is visible to coherent CPU reads after a GPU-side `MI_FLUSH_DW` command retires (Intel iGPU PRM Volume 7 §4.7, "Pipeline Flush"). The driver issues `MI_FLUSH_DW` before signaling user-visible completion; the kernel reads then see the new counter. Similar guarantees exist for HDA LPIB (ICH spec §3.3.42) and USB SOF (xHCI spec §4.11.4).

### 3.2 Why no kernel round-trip

Because the counter *is* a shared-mem variable, not a kernel data structure. The kernel's view is a read-mapping, not an authoritative copy. "The timeline" has one truth, which is the page content; both signaler and waiter observe that truth through mappings they already hold. The syscall-cost tax a conventional sync-primitive pays per signal — scheduler-queue walk, atomic increment, wake-pending-waiters — is pushed to the wake path, which happens at waiter frequency, not signal frequency. For a GPU that signals 10 kHz but has 1 waiter polling at 100 Hz, that's a 100× cost reduction over any kernel-mediated primitive.

---

## 4. First consumers

### 4.1 Audio (R33) — HDA stream position timeline

HDA controllers expose a per-stream Link Position In Buffer (LPIB) register at BAR0 + `0x80 + stream_offset + 0x04`. The hardware DMA engine updates LPIB continuously as it reads/writes the ring buffer. Mint:

```
# in hda_driver (userspace, paideia-as)
hw_cap <- supervisor_mint(KIND_HW, scope=hda_bar0)
notif_cap <- supervisor_mint(KIND_NOTIFICATION, {RECV})
tl_cap <- cap_mint(KIND_HW_TIMELINE, {
    source       = HDA_LPIB,
    clock_id     = stream_index,
    parent_slot  = hw_cap.slot,
    notif_slot   = notif_cap.slot,
    counter_view_pa = <LPIB register's host-visible PA via DMA domain>,
    rights       = R_TL_WAIT | R_TL_SIGNAL | R_TL_OBSERVE,
    resolution_ns = 20833,       # 48 kHz: 1 tick = 1/48000 s ≈ 20.83 μs
})
```

Note: HDA LPIB is a controller-written register, not a seqno queue. The driver maps the register's host-visible shadow (via `DMA Position Buffer`, see `kind-dma-domain.md §10.1`) as the counter view. Signal is purely hardware-driven; the driver only *waits* (`OP_WAIT` on buffer-complete milestones).

### 4.2 GPU (R37) — Iris Xe engine seqno timelines

One timeline per engine (RCS, BCS, VECS, VCS, VECS2). Each engine has a HWS (Hardware Status) page in GPU memory; the counter view is a page in host DRAM mapped into both kernel-aspace and the Iris Xe DMA domain. The driver programs the engine's `RING_HWS_PGA` to the IOVA of this page; the GPU writes the completion seqno to byte 0 of the page as command buffers retire.

Mint shape identical to §4.1 modulo source (`GPU_SEQNO`), clock_id (`(class << 16) | instance`), and counter_view_pa (host-DRAM frame rather than LPIB-shadow).

Signal is device-driven. Driver issues `MI_FLUSH_DW` + `MI_STORE_DWORD` in the GPU batch to write the seqno; kernel waiters see the write after `MI_FLUSH_DW` retires. Doorbell wake (§2.4 opt-in) is driven by the engine's "user interrupt" vector (`KIND_INTERRUPT` cap).

### 4.3 USB isoch (R34) — SOF framecount timeline

xHCI's "Frame Index Register" (`FRINDEX`, Operational Base + 0x44) is a 14-bit counter incremented every 125 μs. For isoch endpoints, scheduling is anchored to SOF boundaries; a timeline on `FRINDEX` gives drivers a cheap "wait until frame N" primitive. Source = `USB_SOF`; clock_id = bus_id; counter_view_pa = host-visible shadow of `FRINDEX` (xHCI shadows the register into a DMA-written page via `Microframe Index` entries in the Scheduler Context).

Resolution_ns = 125000 (one microframe); the 14-bit wraparound is handled driver-side via a 50-bit "epoch" counter the driver layers on top of the raw timeline (the timeline's `cap_timeline_signal` is monotonic — the driver's software overlay translates `FRINDEX` wraps into monotonic ticks and signals the timeline).

---

## 5. Witnessing

### 5.1 Fingerprint tags

Every mint, revoke, signal, wait, and wake emits a klog_s1 line with the `SUBSYS_CAP_` subsystem tag:

```
TL MINT OK      slot=0x<nn> hw=<0|1>
TL MINT ERR     rc=0x<rc>
TL REVOKE OK    slot=0x<nn>
TL REVOKE ALREADY slot=0x<nn>
TL SIGNAL OK    val=<nn>
TL SIGNAL NONMONOTONIC prev=<nn> attempted=<nn>
TL WAIT ARM     slot=0x<nn> target=<nn>
TL WAIT UNBLOCK val=<nn> waited_us=<nn>
TL WAIT TIMEOUT val=<nn> target=<nn> waited_us=<nn>
TL WAIT ABORTED slot=0x<nn>
TL SNAPSHOT     slot=0x<nn> val=<nn>
```

Tag strings are `.rodata` literals in `src/kernel/core/cap/kind_hw_timeline.pdx`. The `<nn>` placeholders are formatted by the klog_s1 u64-to-hex / u64-to-dec emitters.

### 5.2 Dispatch chatter policy

Mint, revoke, signal (SW-fed only — HW-fed signal is kernel-less by design, so there is no site to emit from), wake, and timeout are all unconditional emits. `TL WAIT ARM` is unconditional. `TL SIGNAL OK` for SW-fed signaling is unconditional; for the HW-fed path, a periodic observer running `OP_SNAPSHOT_SIG` emits `TL SNAPSHOT` instead.

### 5.3 Witness fixtures (deliverable in follow-up slice)

Three boot-witness programs:

1. **`hw_timeline_mint_revoke_sw`**: mint a SW-fed timeline (source = 0, no HW parent needed — uses a `KIND_NOTIFICATION` parent). Query source/clock_id/resolution. Signal 1. Wait for `>= 1` (immediate return — fast path). Revoke. Asserts row cleared, counter_view page returned to allocator.
2. **`hw_timeline_signal_wait_sw`**: mint; from thread A, `cap_timeline_wait(cap, >= 7)`; from thread B, loop signaling 1..7 at 100 ms intervals; A unblocks at value=7. Asserts `waited_us` ∈ [600000, 800000].
3. **`hw_timeline_hw_fed_simulated`**: mint a HW-fed timeline with a synthetic counter_view page the test writes directly. Wait for `>= 42`. Test harness writes 42 to the page. Scheduler-poll wake fires. Assert `TL WAIT UNBLOCK val=42`.

### 5.4 Golden sequence (this wave)

The `tests/fingerprints/kind_hw_timeline.golden` captured for Wave 59 D3 is the minimum-viable triple:

```
TL MINT OK slot=0x<nn> hw=0
TL SIGNAL OK val=1
TL WAIT UNBLOCK val=1 waited_us=<nn>
```

Where `0x<nn>` is any hex and `<nn>` any decimal; the golden is placeholder-matched by a follow-up smoke slice (not wired to boot yet). The sequence demonstrates: mint-succeeds, signal-advances-counter, wait-unblocks-with-measured-latency.

---

## 6. Failure modes

### 6.1 Known failure modes

1. **Signaler races the waiter in HW-fed mode.** Waiter reads counter at step 1, computes `target not yet reached`, arms waiter record. Signaler writes new value *between* step 1 and step 3. Resolution: step 3 re-reads the counter under the row's lock after inserting the waiter record; if `current >= target`, immediately wake. This is the standard double-check-after-arm pattern; no new mechanism needed.
2. **Doorbell IRQ fires before any waiter is armed.** The IRQ handler finds `wait_head == 0xFFFF` and no-ops. Correct.
3. **Non-monotonic signal from a buggy device.** The HW-fed path has no kernel-side monotonic check — a device that writes a lower value than it previously wrote is a device bug the kernel cannot cheaply catch. The scheduler-poll walker *can* catch this (compares to `last_signaled`); on detection it emits `TL REGRESSION slot=0x<nn> prev=<nn> new=<nn>` and marks the row's `flags` with a sticky `REGRESSED` bit, surfacing via `OP_QUERY_FLAGS`. Supervisor policy on regression is driver-specific (cascade restart is the typical response).
4. **Counter view page mapped RW to multiple drivers.** The mint gate rejects a `counter_view_pa` that is already stamped in another live timeline row. Enforced by scanning `_hw_timeline_table` on mint.
5. **Timeline waited on past parent revoke.** Covered by §1.5 step 2: parent revoke walks children and aborts their waiters.

### 6.2 Open questions (deferred post-Wave-59)

- **Q-TL-1.** Should `OP_WAIT` have an `>=` AND `==` comparison mode? Current spec is `>=` only (matches Vulkan). An `==` mode would let a driver wait on a specific value; marginal utility, deferred.
- **Q-TL-2.** Doorbell-wake rights plumbing (parent `KIND_INTERRUPT` slot in the mint path). Current spec has it as a mint-time optional field; the exact rights-check structure is TBD until R37 consumption clarifies the pattern.
- **Q-TL-3.** Timeline-of-timelines (a cap that fires when timeline A reaches value X AND timeline B reaches value Y). Vulkan has no analog; drm-syncobj has `WAIT_FOR_FENCE_ARRAY`. Deferred until a real consumer wants it.

### 6.3 Verification checklist (for the follow-up implementation slice)

- [ ] `kind_hw_timeline.pdx` body: real mint/revoke bodies landed with tail encoder/decoder.
- [ ] `_hw_timeline_table[64]` (.bss, zero-init, align 64) declared.
- [ ] `_hw_timeline_waiters[256]` (.bss) declared for wait records.
- [ ] `_hw_timeline_views` kernel-aspace window reserved in the kernel linker script.
- [ ] `cap_invoke_dispatch` routes `kind == 0x143` to `cap_handler_hw_timeline`.
- [ ] `hw_cap_revoke`'s cascade walker extended for `kind == 0x143` children.
- [ ] Scheduler-tick poll walker landed (bounded ≤64 timelines × ≤8 waiters).
- [ ] Three positive witnesses (§5.3) pass; `tests/fingerprints/kind_hw_timeline.golden` wired into `run-smoke.sh`.

---

## 7. Citations and cross-references

**Internal, binding (same-repo):**

- `src/kernel/core/cap/kind.pdx` — base-kind enum (slot 14 `KIND_HW`); R29 derived-kind block already reserves `0x143` for timeline (header line 275).
- `src/kernel/core/cap/kind_hw_interrupt.pdx` — row-indirection substrate shape, copied verbatim.
- `src/kernel/core/cap/kind_hw_msix_vector.pdx` — cascade-by-parent walker shape.
- `src/kernel/core/cap/kind_dma_domain.pdx` — the DMA primitive that device-side writes to the counter view page flow through.
- `src/kernel/core/cap/kind_notification.pdx` — the paired `KIND_NOTIFICATION` for wake delivery.
- `src/kernel/core/apic/hpet.pdx`, `tsc.pdx` — time sources for `waited_us`.
- `design/drivers/kind-interrupt.md` — sibling R29 doc, witness convention source.
- `design/drivers/kind-dma-domain.md` — sibling R29 doc, cascade vocabulary source.
- `design/architecture/next-wave-derived-kinds.md` §KIND_HW_TIMELINE — the planning skeleton this document realizes + extends.

**External (verify at implementation):**

- Khronos: *Vulkan 1.3 Specification* §7.5 "Timeline Semaphores".
- freedesktop.org: `drm/drm_syncobj.c` + DRM API docs on timeline-mode syncobjs.
- Intel Iris Xe PRM Volume 7 §4.7 "Pipeline Flush"; Volume 2a §MI_FLUSH_DW, MI_STORE_DWORD.
- Intel HDA Specification Rev 1.0a §3.3.42 "LPIB — Link Position In Buffer".
- xHCI Specification Rev 1.2 §4.11.4 "Isochronous Transfer Scheduling"; §5.4.5 "Frame Index Register".
- SDM Vol 3A §9.1.1 (store atomicity), §11 (MTRR/PAT for WC-mapped seqno pages).

**Related, non-binding:**

- `design/compositor/pwp-spec-vocabulary.md` — compositor's planned use of timeline-semaphore vocabulary (R37 downstream).
- `design/drivers/perf-baselines.md` — the signal-rate / wake-rate budgets this cap's §2.4 polling vs. doorbell split satisfies.

---

*End of document.*
