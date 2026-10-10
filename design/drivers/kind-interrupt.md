# PaideiaOS — KIND_INTERRUPT: per-vector interrupt capability substrate

**Status:** Draft v0.1 (frozen for Wave 59 D1 landing)
**Date:** 2026-10-10
**Wave / issue:** Wave 59 D1 (paideia-os#2518); first consumer Wave 59 D15 (Intel HDA controller)
**Repository:** paideia-os (kernel-side primitives); paideia-as (encoder gate)
**Scope:** Replace the ad-hoc, hard-coded IDT register path at `src/kernel/core/int/*` with a `KIND_INTERRUPT`-mediated flow in which every userspace-visible IRQ vector is owned, mintable, revocable, and rebindable through the capability system. Specifies capability shape, lifecycle, affinity, migration overlay with the legacy IDT, witness fingerprints, and walks the Intel HDA MSI-X path end-to-end as the correctness demo.

---

## Hard inputs (do not relitigate)

- `design/00-feature-inventory.md` — E3 (driver framework), E4 (PCIe/NVMe/xHCI), U4 (audio).
- `design/01-foundational-decisions.md` — Q6, Q13, Q14; `design/capabilities/linearity-and-tags.md` §3 base-kind freeze.
- `design/drivers/architecture.md`, `design/drivers/framework.md` — distributed-hierarchical pattern; drivers run in userspace; the kernel does vector → endpoint routing and nothing else.
- `design/drivers/driver-cap.md` — `KIND_DRIVER` derived over `KIND_DEVICE`; `R_DRIVER_IRQ` right is the authority-to-request leg; `KIND_INTERRUPT` is what the request mints.
- `design/kernel/kind-surface-mint.md` — the mint-op-arg packing idiom (opcode in `op_arg[7:0]`; payload in high bits).
- `design/roadmap/next-wave-softarch.md` §R29, §R33 — splits `KIND_DRIVER` monolith so a driver can mint per-vector IRQ endpoints without holding the whole device; HDA is R33.M1 consumer promoted to Wave 59 D15.
- `src/kernel/core/cap/kind.pdx` — base-kind slot allocation (slot 9 `KIND_INTERRUPT`; slot 14 `KIND_HW`).
- `src/kernel/core/cap/kind_hw_interrupt.pdx` — `KIND_HW_INTERRUPT` (derived tag 0x140); row-indirection tail; MINT/REVOKE real; MASK/UNMASK/ACK are `INVOKE_UNSUPPORTED` stubs today.
- `src/kernel/core/cap/kind_hw_msix_vector.pdx` — `KIND_HW_MSIX_VECTOR` (derived tag 0x141); per-MSI-X-vector child under a `KIND_HW_INTERRUPT` parent; cascade-revoke invariant lives there.
- `src/kernel/core/cap/interrupt_cap.pdx` — `KIND_INTERRUPT_CAP` (derived tag 0x40) + `KIND_NOTIFICATION_CAP` (0x41) composed cap for the userspace-visible IRQ-receive leg; mint gate real, descriptor write deferred.
- `src/kernel/core/int/idt.pdx` — the IDT install path this document migrates; 256-entry static table; vectors 0/3/6/8/13/14/32/33/36/240/241/242 are hard-coded today.
- `src/kernel/core/apic/ioapic.pdx`, `ioapic_route.pdx`, `vector_pool.pdx`, `msi.pdx`, `eoi.pdx` — the hardware primitives this cap composes over.

---

## 0. Decisions summary

### 0.1 Inherited (binding)

| Source | Constraint |
|---|---|
| Pillar 3 (microkernel) | The kernel does IDT install, LAPIC EOI, IPI delivery, `KIND_INTERRUPT` mint, IOMMU domain switching. Nothing else. |
| Pillar 6 (security by construction) | No ambient IRQ authority. A driver that holds no `KIND_INTERRUPT` cap on vector *v* cannot receive, mask, acknowledge, or rebind *v*. |
| Pillar 9 (hierarchically defined) | A device's vectors derive from the device's `KIND_DEVICE` cap through the driver's `KIND_DRIVER` cap. The cascade is `KIND_DEVICE → KIND_DRIVER → KIND_INTERRUPT → KIND_HW_MSIX_VECTOR` for MSI-X-capable devices. |
| CAP freeze (base kinds) | 16 base kinds frozen. `KIND_INTERRUPT = 9` (slot 9) exists as a base kind; this document finally gives it a real body. Nothing new gets a base slot. |
| `KIND_HW_INTERRUPT` substrate | Already real: GSI + affinity + trigger allocation; MINT and REVOKE round-trip through `_hw_interrupt_table` with cascade through MSI-X children. |

### 0.2 New decisions in this document

| # | Choice | Rationale |
|---|---|---|
| **INT-D1** | **`KIND_INTERRUPT` is the userspace-visible IRQ-vector cap.** It is the *composed* cap drivers hold on their IRQ vectors — not the hardware-topology cap (`KIND_HW_INTERRUPT` 0x140) nor the per-MSI-X-vector cap (`KIND_HW_MSIX_VECTOR` 0x141), both of which stay kernel-internal. Base slot 9; derived tag `0x50` (unused). | Keeps the LAM 4-bit kind-hint fast-dispatch intact on slot 9 (one indirection saved per IRQ-receive). The 0x140 / 0x141 tags remain where they are — those are the kernel's hardware-authority objects. 0x50 is deliberately above the base range to signal "derived"; see §1.1. |
| **INT-D2** | **A `KIND_INTERRUPT` cap is a four-tuple**: `(vector:u8, parent_hw_int_slot:u8, notif_slot:u16, rights:u16)` carried in the 16-byte descriptor tail. The parent `KIND_HW_INTERRUPT` cap holds the GSI + affinity + trigger; this cap only holds the vector-to-notification binding + the ops surface. | Separation of concerns: hardware topology is the kernel's business, binding is the driver's business. Revocation of the parent cascades to this cap by construction (same cascade machinery as 0x141). |
| **INT-D3** | **Delivery is via a paired `KIND_NOTIFICATION` cap**, not a direct function-pointer handler. The driver's `KIND_INTERRUPT` cap carries the slot of a `KIND_NOTIFICATION` cap it owns; the kernel's ISR trampoline posts to that notification; the driver blocks in `notif_wait` on the receive-side cap. | Pillar 3 (microkernel). No userspace code runs in the ISR. No function-pointer registration, no `set_handler(fn, ctx)` call. The ISR is a short, kernel-only trampoline that posts a signal; everything else is scheduled work. The ISR → notification bridge is the same one R24.M3 NVMe uses (`irq_notify.pdx`), re-targeted at the `KIND_INTERRUPT`-side notif-slot pointer. |
| **INT-D4** | **The IDT is a static 256-entry table, programmed once at boot; vectors are migrated to KIND-flow by **binding**, not by rewriting IDT entries at mint time.** Every vector 0x60..0xEF (the MSI-X pool, per `vector_pool.pdx`) is installed at boot with a *dispatcher* trampoline (`_kind_dispatch_vec_v`) that reads `_int_vector_table[v - 0x60]` for its notification pointer. Mint writes the pointer; revoke clears it; the IDT entry never changes. | Avoids the "rewrite IDT during interrupt" race entirely. Pointer-store is atomic on x86-64 for aligned 8-byte stores (SDM Vol 3A §9.1.1), so masking + unmasking is a pointer write without IPI quiescence. The 2048-byte vector table (256 vectors × 8 bytes) is .bss-static; zero means "unbound". |
| **INT-D5** | **Mask/unmask is a pointer-level operation**, not an IOAPIC/MSI-X mask-bit write. "Masked" means `_int_vector_table[v]` is cleared or holds a kernel-defined "muted" sentinel; the ISR trampoline sees NULL/muted and spends two instructions (test + jz) acknowledging and returning. Hardware-level mask (RTE bit 16 for IOAPIC, bit 0 of the MSI-X table entry) is driven by a separate op `OP_HW_MASK` that calls down to `KIND_HW_INTERRUPT`'s mask routine via the parent slot. | Fast path: software-mask is the common case (short-term quiesce around a driver reconfiguration). Hardware-mask is used only when the driver is being torn down and no further IRQ should fire *at all*. Keeps the ISR instruction count at single-digit for the mute case. |
| **INT-D6** | **Vector allocation is per-CPU, scanned by `vector_alloc_for_cpu` in `apic/vector_pool.pdx`.** `KIND_INTERRUPT`'s mint path *consumes* a `(vector, cpu_idx)` pair from the pool; its revoke path *releases* the pair. Allocation is held in the cap's tail; no separate ledger. | The 128-entry `_msix_assignments` table in `vector_pool.pdx` becomes the ledger-of-record for every bound vector, and `cap_table` becomes the inverse index (slot → vector). Dropping the parallel ledger removes a class of drift bugs; see §4.4. |
| **INT-D7** | **Rebind is a two-step revoke + remint**, not a mutation of a live cap. A driver that wants to change its CPU affinity on a vector calls `cap_revoke` on its `KIND_INTERRUPT` slot, then `cap_mint` with the new affinity. This changes the IOAPIC RTE / MSI-X message-address through the parent `KIND_HW_INTERRUPT` cap's existing `rebind_affinity` path. | Linearity-preserving: a `KIND_INTERRUPT` cap is a *witness* of a specific (vector, cpu) binding, so changing the binding is literally destroying this cap and minting another. Matches `KIND_SURFACE` modeset-txn discipline (`design/kernel/kind-surface-mint.md`). |
| **INT-D8** | **Overlay mode for migration.** Vectors 0x20..0x5F (ISA + kernel-internal) continue to use hard-coded trampolines (timer, UART RX, IPIs). Vectors 0x60..0xEF (the MSI-X pool) use the `_kind_dispatch_vec_v` dispatcher. The two coexist indefinitely; migration of individual legacy vectors (e.g. UART RX at vec 36) to the KIND path is per-vector and tracked by individual issues. | The hard-coded trampolines are correctness-critical for the boot path (timer must preempt before task 1 exists; UART RX must drive the serial console before the notification machinery is awake). Not every vector *should* be KIND-mediated. The overlay says: KIND is default for *driver-owned* vectors; legacy is default for *kernel-essential* vectors. See §4. |

### 0.3 Three meta-positions

1. **The cap is the vector, not an opaque handle.** A `KIND_INTERRUPT` cap *identifies* a vector; it is not a userspace-opaque opaque opaque pointer. Observable ops (`OP_QUERY_VECTOR`, `OP_QUERY_CPU`) return the vector and CPU as plain u64s, which the driver uses for its own internal bookkeeping (e.g. HDA's per-stream vector-to-queue table). Capability discipline is independent of information-hiding; a driver that holds the cap *knows* its vector.

2. **No "set_handler(fn, ctx)".** There is no userspace function pointer in an ISR path, ever. The 90% of embedded-OS IRQ API that reads `register_isr(vec, fn, data)` is replaced by `cap_mint(KIND_INTERRUPT, {vec, cpu, notif_slot, rights})` + `notif_wait(notif_slot)`. This also closes a whole family of CFI / sealed-cap bypasses: there is no cross-privilege indirect call to attack.

3. **Masking is a software concept first, a hardware concept second.** A driver that wants to pause IRQ delivery while it reconfigures its ring buffer sets the software mask (pointer-store NULL/muted). The hardware stays armed; a late IRQ fires, hits the muted sentinel, and is EOI'd into oblivion. This is cheaper than an IOAPIC-level mask and far cheaper than a cross-core IPI quiesce. Hardware mask is reserved for *teardown*, where "no further IRQ should fire *at all*" is the actual requirement.

---

## 1. Capability shape

### 1.1 Tag layout

The base-kind slot is 9 (`KIND_INTERRUPT`), already allocated in `src/kernel/core/cap/kind.pdx` since R6. The derived-tag value is `0x50` — above the 4-bit base-slot range, distinct from `KIND_INTERRUPT_CAP = 0x40` (the retired name; this file replaces it), `KIND_NOTIFICATION_CAP = 0x41`, `KIND_HW_INTERRUPT = 0x140`, and `KIND_HW_MSIX_VECTOR = 0x141`.

```
Base-kind enum (16 slots, frozen)        Derived tags (u64 kind field)
  0: KIND_NULL                            0x50: KIND_INTERRUPT         (this document)
  1: KIND_PROCESS                         0x40: KIND_INTERRUPT_CAP     (retired alias — see §4.6)
  ...                                     0x41: KIND_NOTIFICATION_CAP
  9: KIND_INTERRUPT  <-- base            0x140: KIND_HW_INTERRUPT      (kernel-internal)
 10: KIND_DEVICE                         0x141: KIND_HW_MSIX_VECTOR    (kernel-internal)
 12: KIND_NOTIFICATION  <-- paired       0x15..0x30: driver / dmesg / acpi / pci-dev
 14: KIND_HW                             0x100..0x1FF: hardware-adjacent derived kinds
```

LAM kind-hint fast-dispatch on bits [62:59] uses the base slot. On slot 9 the handler is `cap_handler_interrupt`; it reads the full u64 kind field at descriptor offset 0 and routes to the `0x50` branch. The existing `0x40` (`KIND_INTERRUPT_CAP`) branch in `cap_handler_interrupt` is a thin shim that treats 0x40-shaped caps as a bug-compatibility layer for R24.M5 NVMe (see §4.6).

### 1.2 Descriptor layout (16-byte tail)

A cap descriptor is 32 bytes total: 16-byte header + 16-byte kind-specific tail. The tail for `KIND_INTERRUPT`:

| Offset | Size | Field | Semantics |
|-------:|-----:|---|---|
|   +0  |  1 | `vector`                | x86 IDT vector in [0x60..0xEF]; mint rejects vectors outside the MSI-X pool. |
|   +1  |  1 | `parent_hw_int_slot`    | cap_table slot of the parent `KIND_HW_INTERRUPT` cap (0x140) that authorizes this vector's GSI. 0xFF = synthesized (used only in migration overlay, see §4.3). |
|   +2  |  2 | `notif_slot`            | cap_table slot of the paired `KIND_NOTIFICATION` cap on which the kernel ISR posts signals. 0 = unbound / muted. |
|   +4  |  2 | `rights`                | subset of `R_INT_ALL` (see §1.3). |
|   +6  |  2 | `cpu_idx`               | dense logical CPU index; redundant with the vector-pool ledger entry but materialized here to avoid a ledger lookup on hot ops. |
|   +8  |  2 | `pending_count`         | u16 saturating; incremented by the ISR, decremented by `OP_ACK`. Observable through `OP_QUERY_PENDING`. |
|  +10  |  1 | `flags`                 | bit 0 = `MUTED_SW`, bit 1 = `MUTED_HW`, bit 2 = `LEVEL_TRIGGER` (mirrors the parent for fast reads), bits 3..7 reserved. |
|  +11  |  5 | `_reserved`             | zero-initialized; reserved for future delivery policy (e.g. coalescing threshold, deadline). |

Total: 16 bytes exactly, no padding.

**Why materialize `cpu_idx` + flags here.** On a hot path (ISR → notification → driver wakes up and ACKs), we would otherwise do: cap_table[slot] → parent_hw_int_slot → cap_table[parent] → `_hw_interrupt_table[row_id]` → cpu_affinity_mask → bit-scan. Materialization collapses this to one cap_table read.

**Why 0xFF-sentinel for parent.** During the migration overlay (§4.3) we need to be able to mint `KIND_INTERRUPT` caps on vectors whose parent topology is still owned by the hard-coded IDT path (e.g. UART RX at vec 36). The 0xFF sentinel says: "no parent `KIND_HW_INTERRUPT` cap exists for this vector; revocation of this cap does not cascade upward; HW mask ops are unsupported." This is a deliberate overlay-only concession, documented, and gated on an issue (§4.3).

### 1.3 Rights

```
R_INT_RECEIVE   = 0x01   // bind to a notification + receive signals
R_INT_ACK       = 0x02   // OP_ACK: decrement pending_count + EOI
R_INT_MASK_SW   = 0x04   // OP_MASK_SW / OP_UNMASK_SW: pointer-level mute
R_INT_MASK_HW   = 0x08   // OP_MASK_HW / OP_UNMASK_HW: cascade to parent
R_INT_OBSERVE   = 0x10   // OP_QUERY_VECTOR / _CPU / _PENDING / _FLAGS
R_INT_REBIND    = 0x20   // revoke + remint shortcut (atomic from the driver's view)
R_INT_REVOKE    = 0x40   // supervisor revoke path
R_INT_ALL       = 0x7F
```

A driver *typically* holds `R_INT_RECEIVE | R_INT_ACK | R_INT_MASK_SW | R_INT_OBSERVE = 0x17`. The supervisor holds `R_INT_MASK_HW | R_INT_REBIND | R_INT_REVOKE = 0x68`. Default-mint hands out `0x17`; supervisor-mint is a separate op gated on `KIND_DRIVER.R_DRIVER_IRQ`.

### 1.4 Ops surface

Dispatch is through `cap_handler_interrupt(cap_slot, op_arg)` where `op_arg[7:0]` is the ordinal and bits [63:8] carry the payload per the `kind-surface-mint.md` packing idiom:

| Ordinal | Name              | Rights         | Payload   | Returns |
|--------:|---|---|---|---|
| 0       | `OP_QUERY_VECTOR` | `R_INT_OBSERVE`| — | u64 vector |
| 1       | `OP_QUERY_CPU`    | `R_INT_OBSERVE`| — | u64 cpu_idx |
| 2       | `OP_QUERY_PENDING`| `R_INT_OBSERVE`| — | u64 pending_count (snapshot) |
| 3       | `OP_QUERY_FLAGS`  | `R_INT_OBSERVE`| — | u64 flags byte |
| 4       | `OP_ACK`          | `R_INT_ACK`    | — | 0 on success; `INVOKE_UNSUPPORTED` if `pending_count == 0` |
| 5       | `OP_MASK_SW`      | `R_INT_MASK_SW`| — | 0 |
| 6       | `OP_UNMASK_SW`    | `R_INT_MASK_SW`| — | 0 |
| 7       | `OP_MASK_HW`      | `R_INT_MASK_HW`| — | 0; delegates to parent |
| 8       | `OP_UNMASK_HW`    | `R_INT_MASK_HW`| — | 0; delegates to parent |
| 9       | `OP_BIND_NOTIF`   | `R_INT_RECEIVE`| `notif_slot:u16 << 8` | 0; validates kind of notif slot |
| 10      | `OP_UNBIND_NOTIF` | `R_INT_RECEIVE`| — | 0; sets `notif_slot = 0`; sets `MUTED_SW` |
| 11      | `OP_REBIND_CPU`   | `R_INT_REBIND` | `new_cpu_idx:u8 << 8` | 0; cascades to parent |

Any op whose rights check fails returns `INVOKE_DENIED` (`0xFFFFFFFFFFFFFFFD`). An unknown ordinal returns `INVOKE_UNSUPPORTED` (`0xFFFFFFFFFFFFFFFC`). The return-code lane is byte-for-byte compatible with every other kind handler.

**Ordinals 5–8 are the mask surface.** Software mask is a one-store op on `_int_vector_table[vector - 0x60]` (set to the muted sentinel 0x1); unmask is a one-store op (reinstall the notif pointer). Hardware mask delegates to `KIND_HW_INTERRUPT.OP_MASK` through the parent slot — that op will land as part of R29.M2 (currently stubbed `INVOKE_UNSUPPORTED` in `kind_hw_interrupt.pdx:177`). This document specifies the API contract; the body of the hardware-side mask lands with the IOAPIC/MSI-X mask-bit landing.

### 1.5 Revoke semantics

`cap_revoke(slot)` on a `KIND_INTERRUPT` cap:

1. Reads the descriptor; validates `kind == 0x50`.
2. Software-masks: stores 0 (or muted sentinel) into `_int_vector_table[vector - 0x60]`.
3. If `parent_hw_int_slot != 0xFF`, decrements the parent's cascade-child count (the `KIND_HW_INTERRUPT` row's reserved `[+24]` field, future work; today a no-op).
4. Releases the (vector, cpu_idx) pair back to the per-CPU pool via `vector_free_for_cpu` (`apic/vector_pool.pdx`).
5. Unbinds `_msix_assignments` for the pair.
6. Clears the cap_table slot (kind=0, rights=0, tail zeroed).
7. Does **not** cascade to the paired notification cap. A notification is a first-class long-lived object; the driver may keep it to receive on another interrupt. Revoking the notification itself is a separate `cap_revoke(notif_slot)`.
8. Emits witness `INT KIND REVOKE OK vec=0x<nn> cpu=<cc>` (see §5).

Idempotent: revoke on an already-revoked slot returns `REVOKE_ALREADY = 0xFFFFFFFFFFFFFFF7` without side effects.

Cascade from parent: `hw_int_cap_revoke` in `kind_hw_interrupt.pdx` already walks `cap_table` for children with `kind == 0x141` (MSI-X) and revokes them. This document extends the walk to `kind == 0x50` with matching `parent_hw_int_slot`. The invariant becomes: "no dangling `KIND_INTERRUPT` cap after its parent `KIND_HW_INTERRUPT` is revoked."

---

## 2. Lifecycle

### 2.1 Allocation and mint

```
                    cap_mint(KIND_INTERRUPT, args)
                               │
                               ▼
                 ┌──────────── sanity checks ───────────┐
                 │  vector ∈ [0x60..0xEF]               │
                 │  cpu_idx < VECTOR_POOL_MAX_CPUS      │
                 │  rights ⊆ R_INT_ALL                  │
                 │  notif_slot: cap_table[notif].kind    │
                 │              == KIND_NOTIFICATION     │
                 │  parent_hw_int_slot:                  │
                 │     cap_table[p].kind == 0x140        │
                 │     parent.rights & R_HW_INT_MINT     │
                 └───────────────────┬──────────────────┘
                                     │
                 ┌───────────────────▼──────────────────┐
                 │  vector_alloc_for_cpu(cpu_idx) ensures │
                 │  the (vector, cpu) pair is free in     │
                 │  _vector_pool_bitmap. If vector is a   │
                 │  wildcard (0xFF), scan returns the     │
                 │  next free slot; otherwise verify it   │
                 │  is free and claim it.                 │
                 └───────────────────┬──────────────────┘
                                     │
                 ┌───────────────────▼──────────────────┐
                 │  _msix_assignments[j] write:          │
                 │   {seg,bus,dev,func,vector,entry,cpu} │
                 │  if the caller provided a BDF; else   │
                 │  zero (overlay mode).                 │
                 └───────────────────┬──────────────────┘
                                     │
                 ┌───────────────────▼──────────────────┐
                 │  cap_table[new_slot] = {              │
                 │    kind      = 0x50,                  │
                 │    rights    = args.rights,           │
                 │    gen       = lam_bump_gen(),        │
                 │    tail      = {vector,parent_slot,   │
                 │                 notif_slot,rights,    │
                 │                 cpu_idx,0,flags,0}    │
                 │  }                                    │
                 └───────────────────┬──────────────────┘
                                     │
                 ┌───────────────────▼──────────────────┐
                 │  _int_vector_table[vector - 0x60]     │
                 │     = &cap_table[notif_slot]          │
                 │  (publishes the notif pointer; from   │
                 │   this instant the next IRQ delivers) │
                 └───────────────────┬──────────────────┘
                                     │
                                     ▼
                             witness mint
                     "INT KIND MINT OK vec=0x<nn>"
```

The pointer publication at `_int_vector_table[vector - 0x60]` is the "unmask" moment. It MUST happen *after* the cap_table write, so that a racing ISR firing between the cap_table write and the vector-table write sees unbound and no-ops cleanly; and so that an ISR firing after the vector-table write but before the mint-return sees a fully-formed cap. Store ordering: on x86-64, aligned 8-byte stores are atomic (SDM Vol 3A §9.1.1) and WB-domain stores are in-order from any CPU's view, so a mint running on CPU-A publishes to CPU-B via the vector-table pointer with no fence needed (TSO).

**Alloc rights ladder:**

- Caller must hold a `KIND_DRIVER` cap with `R_DRIVER_IRQ` (bit 2 of `R_DRIVER_ALL` per `drivers/driver-cap.md` §3).
- Caller must hold a `KIND_HW_INTERRUPT` cap on the GSI underlying this vector, with `R_HW_INT_MINT` (0x200). This is where the device-authority gate lives.
- Caller must hold a `KIND_NOTIFICATION` cap with `R_NOTIFY_RECV`, pre-allocated.

The supervisor runs all three of these on behalf of the driver during probe (see §6.2 HDA walkthrough). A driver *never* calls `cap_mint(KIND_INTERRUPT, ...)` directly; it calls `supervisor_mint_vector(driver_cap, device_cap, policy)` and the supervisor assembles the three sources of authority.

### 2.2 Mint return codes

```
INT_MINT_OK              = 0
INT_MINT_BAD_VECTOR      = 0xFFFFFFFFFFFFFFFF   // outside [0x60..0xEF]
INT_MINT_BAD_CPU         = 0xFFFFFFFFFFFFFFFE   // cpu_idx >= MAX_CPUS
INT_MINT_BAD_RIGHTS      = 0xFFFFFFFFFFFFFFFD   // rights ⊄ R_INT_ALL
INT_MINT_BAD_PARENT      = 0xFFFFFFFFFFFFFFFC   // parent slot not KIND_HW_INTERRUPT or missing R_HW_INT_MINT
INT_MINT_BAD_NOTIF       = 0xFFFFFFFFFFFFFFFB   // notif slot not KIND_NOTIFICATION or missing R_NOTIFY_RECV
INT_MINT_VEC_IN_USE      = 0xFFFFFFFFFFFFFFFA   // vector_pool reports vector already allocated on cpu_idx
INT_MINT_ENOSPC          = 0xFFFFFFFFFFFFFFF9   // cap_table full
```

Same code-space as every other mint path; distinguishable by the specific sentinel.

### 2.3 Register-handler effect: there is none

There is deliberately no `OP_REGISTER_HANDLER(fn_ptr, ctx_ptr)` op. The pending-count accessor (`OP_QUERY_PENDING`) + the paired notification is the entire delivery surface. A driver that wants a specific function to run on each IRQ writes:

```
loop {
    notif_wait(my_notif_cap);              // block
    while (cap_invoke(my_int_cap, OP_QUERY_PENDING) > 0) {
        service_device();                   // driver-defined
        cap_invoke(my_int_cap, OP_ACK);     // decrements pending; EOI if last
    }
}
```

The pending counter + the while-loop collapse coalesced IRQs correctly: if two IRQs fire while the driver is in `service_device`, the pending counter reads 2 after the loop body returns, so the driver drains twice without ever losing a wake-up. The EOI happens inside `OP_ACK`'s last decrement — the driver controls it rather than the kernel autosignalling.

**Why this matters.** The ad-hoc R16.M4 UART RX path hard-codes the ring-draining loop inside the kernel's `_typed_handler_36`. The KIND path moves that loop to userspace, where it belongs under Pillar 3. The kernel's cost shrinks to: increment pending; post notification; EOI. The whole thing is ~15 instructions.

### 2.4 ISR trampoline shape (kernel-side)

```asm
_kind_dispatch_vec_v:                      ; one trampoline per vector in 0x60..0xEF
    ; standard trampoline prologue (push 0 placeholder, push vec, save 15 GPRs,
    ; load _isr_scratch_rax). Shared tail code at _kind_dispatch_core.
    mov rax, 0; push rax                   ; errcode placeholder
    mov rax, <v>; push rax                 ; vector
    mov rax, [rip + _isr_scratch_rax]
    push rax; <14 GPR pushes>              ; standard 15-GPR save
    mov rdi, <v - 0x60>                    ; vector-table index
    call _kind_dispatch_core
    <15 GPR pops>; add rsp, 16
    jmp _isr_return

_kind_dispatch_core:                       ; rdi = vector index [0..0x8F]
    lea rax, [rip + _int_vector_table]
    mov rsi, [rax + rdi*8]                 ; load notif pointer
    test rsi, rsi
    jz   _dispatch_muted                   ; muted sentinel is 0x1; NULL is 0; both land here
    cmp  rsi, 1
    je   _dispatch_muted
    ; rsi = &notif_cap (first field is sema_ptr); post signal
    mov rdx, [rsi + 0]                     ; sema addr
    mov rcx, 1
    lock xadd [rdx], rcx                   ; atomic increment on notif pending
    call sched_wake_notif                  ; wake the waiter (userspace blocked in notif_wait)
    ; also bump our pending_count in the cap tail
    mov rdx, [rsi + 8]                     ; cap_table[int_slot] back-ptr
    lea rcx, [rdx + 24]                    ; tail offset of pending_count
    mov r8w, [rcx]
    cmp r8w, 0xFFFF
    je  _dispatch_sat                      ; saturating increment
    inc r8w
    mov [rcx], r8w
_dispatch_sat:
    jmp _dispatch_eoi
_dispatch_muted:
    ; drop the IRQ; EOI anyway
_dispatch_eoi:
    call apic_eoi
    ret
```

The sketch is informative only (no code in this doc per the contract); the real body lands at `src/kernel/core/int/kind_dispatch.pdx` (new file) in the D1 implementation PR. Instruction count: ~18 for the fast path, ~5 for the muted path, both well below any current ISR latency floor.

**Why 256-way vectors instead of one dispatcher.** We could have a single trampoline that reads the current vector from the stack and dispatches. We don't: the single-dispatcher approach adds a mov + an and + a cmp before the vector-table lookup, costing ~3 cycles on every IRQ. 256 near-identical trampolines cost 256 × 32 = 8 KiB of .text, which is fine. The `idt_install` loop in `idt.pdx` is already shaped to install heterogeneous trampolines per vector; adding 144 more entries (0x60..0xEF) is a mechanical extension of the existing switch.

---

## 3. Per-vector affinity

### 3.1 IOAPIC path (ISA-mapped vectors)

For a legacy ISA interrupt remapped into the MSI-X vector space (rare but supported — e.g. for ACPI SCI / GPE on a laptop that doesn't support MSI-X on the LPC bridge), the parent `KIND_HW_INTERRUPT` cap carries the IOAPIC redirection-table entry (RTE) through `_hw_interrupt_table[row_id]`. The RTE encodes:

| RTE bits | Field | Owned by |
|---|---|---|
| [7:0]  | vector | `KIND_INTERRUPT` tail +0 |
| [10:8] | delivery mode (0 = fixed) | always 0 at this layer |
| [11]   | dest mode (0 = physical) | always 0 at this layer |
| [15:13]| polarity + trigger | `KIND_HW_INTERRUPT._hw_interrupt_table[+0].edge_or_level` |
| [16]   | mask | driven by `OP_MASK_HW` through parent |
| [63:56]| destination APIC-ID | `KIND_HW_INTERRUPT._hw_interrupt_table[+8].cpu_affinity_mask` → lowest-set-bit APIC ID |

Rebind on affinity change (`OP_REBIND_CPU`) walks:

1. Revoke this `KIND_INTERRUPT` cap on cpu_idx `old`.
2. Call parent `KIND_HW_INTERRUPT.rebind_affinity(new_cpu_mask)` — this is the R29.M2 integration point today stubbed `INVOKE_UNSUPPORTED`. The function will program the IOAPIC RTE at `ioapic_mmio + 0x10 + 2*gsi + 1` with the new destination APIC-ID (`ioapic.pdx:ioapic_program_redir`).
3. Mint a new `KIND_INTERRUPT` cap on cpu_idx `new`.

The caller receives the new cap's slot through the mint return path. The driver's userspace code treats the slot change as any other revoke+remint — its notification cap is unchanged, so its `notif_wait` loop just continues to see wake-ups on the new CPU.

### 3.2 MSI-X path (the common case for Wave 59)

For MSI-capable PCIe devices (NVMe, HDA, xHCI, NICs, GPUs), the parent `KIND_HW_INTERRUPT` cap holds a GSI *and* has one or more `KIND_HW_MSIX_VECTOR` children (one per MSI-X table entry on the device). The topology:

```
     KIND_DEVICE (PCIe BDF)                            → tail: {seg, bus, dev, func, class}
         │ holds R_DEVICE_IRQ
         ▼
     KIND_HW_INTERRUPT (gsi=auto, affinity=0xFFFF…)    → tail: {gsi, affinity_mask, trigger}
         │ cascades on revoke
         ▼
     KIND_HW_MSIX_VECTOR * N (one per table entry)     → tail: {msix_table_offset, msix_data, parent_slot}
         │ driver asks supervisor to bind cap
         ▼
     KIND_INTERRUPT (vector=0xNN, cpu=K)               → tail: {vector, parent_hw_int_slot=0x140 parent, notif, rights}
         │ 1:1 with a MSI-X vector; the vector field here = the one in the parent's `msix_data`
         ▼
     KIND_NOTIFICATION (driver's inbox for this vec)
```

Programming the MSI-X message-address register uses the vector (bits [7:0] of the message-data) and the destination APIC-ID (bits [19:12] of the message-address). The current `apic/msi.pdx` has a `msix_program_entry(bdf, entry_idx, vec, apic_id)` helper that writes both; R29.M2 lifts this to be driven through `KIND_HW_MSIX_VECTOR.OP_PROGRAM` with the vector + apic_id drawn from the parent's affinity. The `KIND_INTERRUPT` cap's own `OP_REBIND_CPU` lands here: it just invokes `KIND_HW_MSIX_VECTOR.OP_PROGRAM` with the new apic_id. The MSI-X entry mutation is a single 32-bit MMIO write + a 32-bit mask-bit flip for the quiesce window; no IPI quiesce needed on x86-64 (SDM Vol 3A §10.11.5 mask-bit discipline).

### 3.3 Multi-core delivery policy

Three policies are expressible through the parent `KIND_HW_INTERRUPT`'s `cpu_affinity_mask`:

- **Pin** (default for Wave 59): `cpu_affinity_mask = (1 << cpu_idx)`. Exactly one CPU receives. Highest cache locality for ring-buffer processing; lowest best-case latency for the specific CPU. Chosen for HDA because the audio ring must be serviced from the CPU that owns the audio clock scheduling.
- **Steer**: `cpu_affinity_mask = any subset`. The IOAPIC/MSI-X lowest-priority delivery mode walks the set and picks the lowest-TPR CPU. Rarely used; useful for drivers with a free-running pool of worker threads.
- **Broadcast**: `cpu_affinity_mask = ~0`. Fixed delivery to the lowest-APIC-ID CPU. Essentially never used — this is almost always a bug — but allowed for completeness.

A `KIND_INTERRUPT` cap pins to one CPU regardless of parent policy (its `cpu_idx` field is scalar). The parent policy drives which CPU the hardware delivers to; the child cap records which CPU bound. Mismatch is a bug caught by the mint-time `vector_alloc_for_cpu` call (which fails if the vector is already bound on a different CPU).

### 3.4 Hotplug and migration

CPU hotplug (`design/drivers/cpu-hotplug.md`): on CPU-offline, all `KIND_INTERRUPT` caps bound to that CPU must be revoked or rebound. The supervisor walks `cap_table` for descriptors with `kind == 0x50 && cpu_idx == offlined_cpu` and either revokes (if the device is being quiesced) or rebinds to the fallback CPU. The rebind path is §3.1; the walk is bounded by cap_table size (256 today, 1024 at Wave 59; worst case 1024 u64 reads).

Online: no action. Newly-online CPUs become candidates for subsequent mints; existing caps don't migrate automatically. (A driver that wants to spread load across new CPUs explicitly rebinds.)

---

## 4. Interaction with the existing IDT path

### 4.1 The current reality

`src/kernel/core/int/idt.pdx` installs 256 IDT entries at boot. Vectors 0, 3, 6, 8, 13, 14 are CPU exceptions wired to typed handlers (`_typed_handler_N`); vector 32 is the timer; vector 33 is the generic IPI (nothing currently; vestigial); vector 36 is UART RX; vectors 240/241/242 are reschedule/TLB-shootdown IPIs. The rest point at a stub at offset 0 which, if hit, triple-faults the box.

This is not a bug — it is a conscious under-engineering choice from R6. Every vector that *actually fires* today is one of those listed, and anything else firing on a well-behaved machine means an unexpected device interrupt we would want to see fault at.

### 4.2 Migration philosophy: KIND is default for driver vectors; legacy stays for kernel vectors

The split is drawn at the vector-pool boundary (0x60 per `vector_pool.pdx`):

| Vector range | Owner | Delivery model | Migration status |
|---|---|---|---|
| 0x00..0x1F | CPU exceptions | Hard-coded typed handler | **No KIND** — intrinsically kernel-handled. |
| 0x20..0x2F | ISA legacy (PIT, UART, KBD, RTC, …) | Hard-coded trampoline (today only vec 32 timer + vec 36 UART RX are live) | **Overlay** — may be minted as `KIND_INTERRUPT` with `parent_hw_int_slot = 0xFF`; see §4.3. |
| 0x30..0x5F | Kernel-internal (TLB shootdown, reschedule IPI, future NMI watchdog) | Hard-coded trampoline | **No KIND** — kernel-internal; not driver-visible. |
| 0x60..0xEF | MSI-X pool | `_kind_dispatch_vec_v` trampoline | **KIND-mediated by default.** |
| 0xF0..0xFF | LAPIC IPIs + spurious | Hard-coded trampoline | **No KIND** — LAPIC-level. |

The two interesting ranges are 0x20..0x2F (ISA legacy, overlay) and 0x60..0xEF (MSI-X, pure-KIND). All others are off-limits to the KIND path.

### 4.3 Overlay mode for legacy vectors (0x20..0x2F)

The migration-overlay need arises because the UART RX path (vec 36 = 0x24) is a live driver that already receives IRQs through the hard-coded `_isr_stub_36` trampoline, and we want to migrate it to KIND without regressing the serial console.

The overlay is minimal:

1. **Dual-wire the vector.** `_isr_stub_36` continues to exist. In its body, after the GPR save but before the current hard-coded "walk the ring" code, insert a `test [_int_vector_table + (36 - 0x20) * 8], 0`. If the slot is non-zero and non-muted, call `_kind_dispatch_core` with vector index 4 (= 0x24 - 0x20), post the notification, EOI, iretq. If the slot is zero or muted, fall through to the existing hard-coded path.
2. **Separate vector-table.** Vectors 0x20..0x2F use `_int_vector_table_legacy[16]`, offset-indexed by `vec - 0x20`. This is a parallel table from the MSI-X range; it exists to keep the hot-path address arithmetic for `_kind_dispatch_core` simple (one base + one index) while allowing the ISA range to be migrated piecemeal.
3. **Parent sentinel.** `KIND_INTERRUPT` caps minted on vectors 0x20..0x2F carry `parent_hw_int_slot = 0xFF` (synthesized / no parent). Rights `R_INT_MASK_HW` and `OP_REBIND_CPU` on these caps return `INVOKE_UNSUPPORTED` — the kernel still owns the hardware wiring for ISA legacy vectors because the IOAPIC RTE for them is pinned at boot. A follow-up issue (post-Wave 59) tracks lifting ISA vectors into real `KIND_HW_INTERRUPT` parents.

The overlay is removable: when every ISA vector has moved to KIND + its ISA parent has been promoted to `KIND_HW_INTERRUPT`, the hard-coded fallback in each `_isr_stub_N` becomes dead code and the overlay deletes.

### 4.4 Vector-pool as single source of truth

The current `_msix_assignments` table in `vector_pool.pdx` is the inverse-index of what's allocated. Pre-Wave 59, it is written by the one path (`vector_alloc_for_cpu` + its callers in NVMe/HDA driver boot). Post-Wave 59, it is written only by `cap_mint(KIND_INTERRUPT, …)` / cleared only by `cap_revoke`, so the invariant "`_msix_assignments` lane is live ⇔ a `KIND_INTERRUPT` cap exists on that lane" becomes machine-checkable.

The debt-catalog audit refresh (commit 188ad283 as of this writing) will add an invariant-check witness: scan `_msix_assignments`, scan `cap_table` for `KIND_INTERRUPT` descriptors, assert the two sets are the same vector/cpu pairs. Mismatch is a kernel panic in debug builds, a klog warning in release.

### 4.5 Static-dispatch for ISA RX

A paideia-as encoder constraint: `_isr_stub_N` cannot do a function-table dispatch (no indirect call targets in a `pub let` body today). The overlay therefore inlines the test-and-branch rather than calling into a central dispatcher. This is specific to the ISA range; the MSI-X range gets a dedicated per-vector trampoline anyway.

### 4.6 The `KIND_INTERRUPT_CAP = 0x40` retirement

`src/kernel/core/cap/interrupt_cap.pdx` currently defines `KIND_INTERRUPT_CAP = 0x40` as a stand-alone cap, with its own mint gate (R24-M5-002 / #904). That path exists because R24.M5 needed a userspace-visible NVMe IRQ cap before `KIND_HW_INTERRUPT` / `KIND_HW_MSIX_VECTOR` existed. With Wave 59 D1 landing, `0x40` and `0x50` would be two names for the same abstraction.

Decision: **retire `0x40`, migrate NVMe to `0x50`.** The retirement is a two-step mechanical replacement:

1. Change `KIND_INTERRUPT_CAP = 0x40` to be an *alias* of `0x50` in `interrupt_cap.pdx` (one-line edit); interim period for the NVMe driver code to accept either.
2. Delete the old `interrupt_cap_mint` body; redirect all callers to the new `cap_mint(0x50, …)` through supervisor_mint_vector.
3. Delete the `KIND_INTERRUPT_CAP` symbol entirely in a follow-up PR once no caller remains.

The compatibility shim in `cap_handler_interrupt` (routing `0x40` → `0x50` handler) is in place for one wave; it is explicitly scheduled for deletion.

---

## 5. Witnessing

### 5.1 Fingerprint tags

Every mint, revoke, mask, and dispatch emits a klog_s1 line with the standard `SUBSYS_CAP_` subsystem tag. Format:

```
INT KIND MINT OK      vec=0x<nn> cpu=<cc> slot=<ss>
INT KIND MINT ERR     vec=0x<nn> cpu=<cc> rc=0x<rc>
INT KIND REVOKE OK    vec=0x<nn> cpu=<cc> slot=<ss>
INT KIND REVOKE ALREADY slot=<ss>
INT KIND MASK SW      vec=0x<nn>
INT KIND UNMASK SW    vec=0x<nn>
INT KIND MASK HW      vec=0x<nn>  parent_slot=<ps>
INT KIND UNMASK HW    vec=0x<nn>  parent_slot=<ps>
INT KIND BIND NOTIF   vec=0x<nn> notif=<ns>
INT KIND UNBIND NOTIF vec=0x<nn>
INT KIND REBIND CPU   vec=0x<nn> old_cpu=<oc> new_cpu=<nc>
INT KIND DISPATCH     vec=0x<nn> pending=<pp>
INT KIND ACK          vec=0x<nn> pending_after=<pa>
```

Each tag is a `.rodata` string literal in `src/kernel/core/cap/kind_interrupt.pdx` (new file for Wave 59 D1). The `<nn>` / `<cc>` / `<ss>` / `<rc>` placeholders are formatted by the klog_s1 u64-to-hex emitter.

### 5.2 Dispatch chatter policy

`INT KIND DISPATCH` is on the IRQ hot path. In debug builds (`DEBUG_IRQ_TRACE=1`), every dispatch emits a tag. In release builds, dispatch is silent; only mint/revoke/mask boundary events emit. This matches the policy in `kind_hw_interrupt.pdx`'s `cap_hw_int_msg` (chatty for the handler-entry case but silenced in release).

The `OP_ACK` chatter is unconditional and inexpensive: 1 line per driver-handled IRQ, which is at most ~10 KHz on any realistic driver load (NVMe at saturation).

### 5.3 Witness fixtures

Three witness programs land with D1:

1. **`kind_interrupt_mint_revoke`** (boot witness, `kernel_main.pdx`). Allocates a `KIND_HW_INTERRUPT` parent (gsi=0x40, affinity=0x01, edge). Allocates a `KIND_NOTIFICATION`. Mints a `KIND_INTERRUPT` cap at (vec=0x60, cpu=0). Queries vector/cpu/pending/flags. Masks + unmasks SW. Revokes. Asserts: cap_table slot cleared; `_int_vector_table[0] == 0`; vector-pool `(0x60, 0)` released. Emits `R29 KIND_INTERRUPT MINT_REVOKE OK` on success.

2. **`kind_interrupt_dispatch_simulated`** (unit-style boot witness). After mint, simulate an IRQ by directly invoking `_kind_dispatch_core` with the vector index. Assert `pending_count == 1`. Invoke `OP_ACK`. Assert `pending_count == 0`. Emit `R29 KIND_INTERRUPT DISPATCH OK`. The real HW-IRQ-driven witness is the HDA path (§6).

3. **`kind_interrupt_cascade_from_parent`** (boot witness). Mint parent + child; revoke the parent; assert the child is auto-revoked by the cascade walker in `hw_int_cap_revoke`; assert `_int_vector_table[vec-0x60] == 0`. Emit `R29 KIND_INTERRUPT CASCADE OK`.

All three are added to the `smoke.pdx` / `tests/witness_*` boot-witness roster per `design/testing/*`.

### 5.4 Negative witnesses

The structural failure cases are gated on explicit sub-tests:

- **W-N1** mint with `vector = 0x30` (below pool floor) → `INT_MINT_BAD_VECTOR`.
- **W-N2** mint with `cpu_idx = 16` (above `VECTOR_POOL_MAX_CPUS`) → `INT_MINT_BAD_CPU`.
- **W-N3** mint with rights = `0x80` (`R_INT_ALL` is `0x7F`) → `INT_MINT_BAD_RIGHTS`.
- **W-N4** mint with `parent_hw_int_slot` pointing to a `KIND_NULL` slot → `INT_MINT_BAD_PARENT`.
- **W-N5** mint with `notif_slot` pointing to a `KIND_PAGE` slot → `INT_MINT_BAD_NOTIF`.
- **W-N6** double-mint same vector → `INT_MINT_VEC_IN_USE`.

Each negative witness emits an `INT KIND MINT ERR rc=0x<rc>` line and verifies the specific rc. Failure to produce the exact rc is a witness-fail.

---

## 6. First consumer: Intel HDA controller (Wave 59 D15)

### 6.1 Hardware shape

Target: Intel HDA controller as implemented on Raptor Lake-U (T14 G4) and QEMU `ich9-hda` (for CI).

- PCI BDF: `0000:00:1f.3` on real HW (vendor 0x8086, device 0x51CA for Raptor Point-U cAVS); `0000:00:1b.0` on QEMU ich9.
- MMIO BARs: BAR0 is the controller register file (~16 KiB).
- MSI-X capability at offset `0xA0` in config space; typically 1 vector exposed by both real HW and QEMU ich9. Each stream (RIRB response, CORB solicited, stream descriptor IRQs) multiplexes onto that vector through the GCTL interrupt-source register.
- IRQ semantics: single shared vector; the driver reads INTSTS/INTCTL to find which engine fired (RIRB non-empty, stream buffer-complete, codec-wake, etc.).

The driver lives at `src/kernel/drivers/hda/` — new directory to be created by Wave 59 D15. Within paideia-os's microkernel model, it runs as a userspace task; the kernel-side driver scaffold under `src/kernel/drivers/hda/*` is the stub-process-image + handoff schemas, not kernel code.

### 6.2 End-to-end IRQ path

```
             ┌─────────────────────────────────────────────────┐
             │              Supervisor (userspace)              │
             │                                                   │
             │  on PCI enumeration finds 8086:51CA at 0:1f.3:    │
             │    1. mint KIND_DEVICE cap for the BDF            │
             │    2. mint KIND_DRIVER cap scoped to that BDF     │
             │    3. spawn hda_driver task; hand over the cap    │
             └──────────────────────────┬────────────────────────┘
                                        │
                           ┌────────────▼────────────┐
                           │  hda_driver task starts  │
                           │  (userspace, aspace H)   │
                           └────────────┬────────────┘
                                        │
       ┌────────────────────────────────▼────────────────────────────────┐
       │  Driver asks supervisor:                                         │
       │    supervisor_request_mmio(KIND_DRIVER, bar=0, len=0x4000)       │
       │    → supervisor mints MMIO cap, aspace_map's it into aspace H   │
       │                                                                  │
       │    supervisor_request_irq(KIND_DRIVER, msix_entry=0, cpu=1)      │
       │    → supervisor:                                                 │
       │        a. mints KIND_HW_INTERRUPT parent (gsi auto, affinity=1, │
       │           edge; parent carries the IOAPIC/MSI-X topology bits)  │
       │        b. mints KIND_HW_MSIX_VECTOR child (table_offset=0,       │
       │           data=auto_vector_from_vector_pool(cpu=1))              │
       │        c. mints KIND_NOTIFICATION (RECV) and shares with driver  │
       │        d. mints KIND_INTERRUPT (RIGHTS=0x17) with:               │
       │             vector = <from step b>                               │
       │             parent_hw_int_slot = <step a slot>                   │
       │             notif_slot = <step c slot>                           │
       │             cpu_idx = 1                                          │
       │        e. programs MSI-X table entry 0 via                       │
       │           msix_program_entry(bdf, 0, vec, apic_id)               │
       │        f. publishes _int_vector_table[vec - 0x60] = &notif       │
       │    hands {KIND_INTERRUPT slot, KIND_NOTIFICATION slot} to driver │
       └────────────────────────────────┬────────────────────────────────┘
                                        │
       ┌────────────────────────────────▼────────────────────────────────┐
       │  Driver programs HDA registers in BAR0:                          │
       │    - CORB base/wp/rp                                             │
       │    - RIRB base/wp (RIRB response buffer)                         │
       │    - INTCTL: set MSI-enable (bit 31) + stream-complete bits      │
       │    - GCTL: enable controller + unsol-response                    │
       └────────────────────────────────┬────────────────────────────────┘
                                        │
       ┌────────────────────────────────▼────────────────────────────────┐
       │  Driver enters receive loop:                                     │
       │                                                                  │
       │    for ever {                                                    │
       │      notif_wait(my_notif_slot);        <-- BLOCKS                │
       │      while (cap_invoke(my_int_slot, OP_QUERY_PENDING) > 0) {    │
       │        intsts = read_mmio(BAR0 + 0x24);                          │
       │        if (intsts & RIRB_INT) drain_rirb();                      │
       │        if (intsts & STREAM_INT) service_stream();                │
       │        write_mmio(BAR0 + 0x24, intsts);  <-- clear               │
       │        cap_invoke(my_int_slot, OP_ACK);                          │
       │      }                                                           │
       │    }                                                             │
       └──────────────────────────────────────────────────────────────────┘
```

### 6.3 First-IRQ timeline

Clock tick 0: driver completes HDA controller init, writes GCTL to enable; calls `notif_wait(my_notif_slot)`; task-blocks; scheduler picks another runnable task.

Clock tick τ_hw: an HDA codec drives a stream-buffer-complete event. The controller asserts its MSI-X vector 0. The LAPIC on CPU 1 fires an interrupt at vector 0x61 (allocated by vector pool).

Clock tick τ_hw + 2 cycles: CPU 1 enters `_kind_dispatch_vec_61`. Standard trampoline prologue runs (~15 pushes).

Clock tick τ_hw + ~40 cycles: `_kind_dispatch_core` loads `_int_vector_table[1]` (vector 0x61 index), reads the notification pointer, atomically increments `[rsi + 0]` (notification sema), calls `sched_wake_notif`. `sched_wake_notif` moves the hda_driver TCB from WAITING to RUNNABLE in the runqueue.

Clock tick τ_hw + ~60 cycles: increment `pending_count` from 0 → 1 in the cap tail. Call `apic_eoi`.

Clock tick τ_hw + ~75 cycles: trampoline epilogue (15 pops, add rsp, iretq).

Clock tick τ_hw + ε: timer tick arrives (τ_hw happens to fall near a slice boundary), preempt tail picks the hda_driver TCB from the runqueue, `sched_switch_r15` to it. The driver's RIP resumes just past the `notif_wait` return. The while-loop condition evaluates, `OP_QUERY_PENDING` returns 1. Driver reads INTSTS from MMIO, services, acks, loops. Pending drops to 0, loop exits, driver returns to `notif_wait`.

Total kernel-side ISR cost: ~75 cycles (plus the ~500 cycles the preempt tail already costs). Driver-side cost: one trap into cap_invoke, one MMIO read, one MMIO write, one trap into cap_invoke. 

### 6.4 Shared-vector correctness

HDA multiplexes all its sources onto one vector. The driver reads INTSTS to find out which. Does the KIND path support this?

Yes. The driver gets *one* `KIND_INTERRUPT` cap for the vector; the "which source fired" is a driver-level concern that the driver reads from BAR0. The pending-count semantic is "the number of IRQ assertions since last ACK" — if two codec stream events + one RIRB response arrive before the driver drains, pending reaches 3, the driver drains all three sources in its while-loop (one `OP_QUERY_PENDING` → 3; one `OP_ACK` per iteration → 2 → 1 → 0), and all three cause-flags in INTSTS get cleared in one or multiple MMIO reads. The driver does not need to know *which* source each pending-count-tick corresponds to; the hardware provides that via INTSTS.

### 6.5 Error paths

- **Codec unresponsive on CORB verb:** driver's RIRB-response timeout hits; the driver masks SW (`OP_MASK_SW`), resets the controller, unmasks SW. No kernel involvement.
- **MSI-X vector-overflow (impossible on single-vector devices but modeled anyway):** driver's `OP_ACK` saturates the pending counter at `0xFFFF`; the saturation flag will be surfaced via `OP_QUERY_FLAGS` in a later wave (today the saturation is silent; see §7).
- **Driver crash mid-service:** the driver aspace faults → `process_death.pdx` cascades cap revokes → `KIND_INTERRUPT` revoke sets `_int_vector_table[vec-0x60] = 0` → further IRQs no-op through the muted path. The supervisor's cascade-restart (per `design/drivers/cascade-restart.md`) respawns the driver, which re-does step §6.2.

### 6.6 CI story

QEMU `ich9-hda` with `-device ich9-intel-hda -device hda-duplex` fires MSI-X IRQs for both the controller and the codec sides. The Wave 59 D15 CI witness drives:

1. Boot kernel + supervisor + hda_driver (new userspace task-image).
2. Wait 2 seconds.
3. Have hda_driver emit `HDA IRQ COUNT = <n>` after a well-known number of audio-stream events (QEMU is deterministic in interrupt rates for scripted inputs; see `tools/qemu-hda-smoke.sh`).
4. Assert `n == expected ± 1`.

If the KIND path is wiring correctly, `n > 0`. If zero, either the mint didn't publish the vector-table pointer, or `sched_wake_notif` isn't delivering wake-ups, or the driver's `notif_wait` is wrong. The witness fingerprint `HDA KIND INT OK vec=0x<nn> count=<n>` identifies the pass case.

---

## 7. Failure modes and open questions

### 7.1 Known failure modes

1. **Vector-table pointer torn in the mint window.** On x86-64 aligned 8-byte stores are atomic (SDM Vol 3A §9.1.1), so no mitigation needed. On a hypothetical cross-architecture port, publication would need a release fence.
2. **Notification receiver dies between mint and first IRQ.** The ISR dispatches to a notification whose TCB has been destroyed. `sched_wake_notif` must handle `NULL`-owner notifications gracefully (silent no-op + warning). The current implementation in `irq_notify.pdx` already does this via a sentinel in the notification descriptor; the KIND path inherits.
3. **CPU hotplug mid-dispatch.** CPU goes offline while an IRQ for its vector is pending in the LAPIC IRR. SDM Vol 3A §10.6.1 says IRR entries drain to the destination before the CPU goes offline; the kernel's hotplug path waits for drain. The KIND path doesn't change this.
4. **Mint-revoke-mint sequence re-using a vector.** Vector is freed in revoke, re-allocated in mint; LAM generation on the slot differs, so stale cap-handle references fail; vector-table pointer is overwritten atomically. Correct.
5. **Simultaneous mint from two cores on same vector.** `vector_alloc_for_cpu` uses a per-CPU bitmap and an acquire-release lock; concurrent mints on *different* cores can't collide because each CPU owns its own vector range. Concurrent mints on the *same* CPU serialize through the lock.

### 7.2 Open questions (deferred to post-Wave-59)

- **Q-INT-1.** Should `pending_count` saturate or wrap? Current choice is saturate at `0xFFFF`; wrap might match some hardware semantics better. Deferred until a device with real coalescing exposes the issue (likely R91 10GbE NIC).
- **Q-INT-2.** `OP_ACK` currently requires `R_INT_ACK`; should it also auto-check and refuse if `pending_count == 0`? Current choice is yes (returns `INVOKE_UNSUPPORTED`). Alternative: silent no-op. Deferring until a driver's actual behavior calls for one or the other.
- **Q-INT-3.** `OP_REBIND_CPU` is specified but its implementation body depends on `KIND_HW_INTERRUPT.rebind_affinity` landing (R29.M2 stub). This is tracked by a dependency link in Wave 59 D1's issue body.
- **Q-INT-4.** Overlay for vector 32 (timer): should we eventually allow the scheduler to mint a `KIND_INTERRUPT` cap on the timer vector so a timer-driver task can observe ticks? Current answer: no, timer is kernel-internal. If userspace needs ticks, it goes through `KIND_TIMER` which is a wholly separate derivation path. Noted here to document the choice.
- **Q-INT-5.** Rights-to-op matrix is 11 ops × 7 rights = 77 cells; the one explicitly flagged in §1.4 is enough for Wave 59. Full matrix with every refinement goes to `design/capabilities/rights-catalog.md` as a follow-up append; this doc is self-contained for the subset D1 lands.

### 7.3 Verification checklist

Before Wave 59 D1 PR merges:

- [ ] `kind_interrupt.pdx` exists at `src/kernel/core/cap/kind_interrupt.pdx` with the layout per §1.
- [ ] `kind_dispatch.pdx` exists at `src/kernel/core/int/kind_dispatch.pdx` with the per-vector trampolines per §2.4.
- [ ] `idt.pdx` extended to install 144 trampolines for 0x60..0xEF.
- [ ] `_int_vector_table[144]` (`.bss`, zero-init, align 64) declared.
- [ ] `vector_alloc_for_cpu` + `vector_free_for_cpu` are the only writers of `_msix_assignments`.
- [ ] `cap_invoke_dispatch` routes `kind == 0x50` to `cap_handler_interrupt`.
- [ ] `interrupt_cap.pdx` reduced to an alias layer forwarding to `cap_handler_interrupt`.
- [ ] All six negative witnesses (§5.4) pass; all three positive witnesses (§5.3) pass.
- [ ] `hw_int_cap_revoke`'s cascade walker extended for `kind == 0x50` children.
- [ ] HDA driver stub (`src/kernel/drivers/hda/`) at least contains a probe handoff schema.
- [ ] `design/drivers/kind-interrupt.md` (this file) linked from `design/00-feature-inventory.md` under E3, and from `design/drivers/architecture.md` §4.

---

## 8. Citations and cross-references

**Internal, binding (same-repo):**

- `src/kernel/core/cap/kind.pdx` §KIND_INTERRUPT (slot 9) — the base-kind enum this document specifies for.
- `src/kernel/core/cap/kind_hw_interrupt.pdx` — the hardware-topology cap this cap derives *below* (the inverse of a usual derive-over relation; this cap pairs with a parent of that kind).
- `src/kernel/core/cap/kind_hw_msix_vector.pdx` — the MSI-X-vector cap this cap is 1:1 with on MSI-X devices.
- `src/kernel/core/cap/interrupt_cap.pdx` — the R24.M5 scaffolding being retired.
- `src/kernel/core/int/idt.pdx` — the IDT install path being extended.
- `src/kernel/core/apic/vector_pool.pdx` — the per-CPU vector allocator this doc designates as the single source of truth.
- `src/kernel/core/apic/eoi.pdx` — EOI primitive called from `_kind_dispatch_core`.
- `src/kernel/core/apic/msi.pdx` — MSI-X table-entry programming.
- `src/kernel/core/apic/ioapic.pdx`, `ioapic_route.pdx` — IOAPIC RTE programming for the (rare) legacy-overlay path.
- `src/kernel/core/apic/irq_notify.pdx` — the ISR → notification bridge this doc re-targets.
- `src/kernel/core/notification/*` — the paired `KIND_NOTIFICATION` cap, pre-existing.
- `src/kernel/core/driver/driver_table.pdx` — where `KIND_DRIVER` caps live; the authority gate for `supervisor_request_irq`.

**Internal, context:**

- `design/drivers/architecture.md` §4 — "IRQ delivery via IPC endpoint" position statement that this doc operationalizes.
- `design/drivers/framework.md` §3.3, §5 — driver lifecycle; where in Init → Running the IRQ cap mint happens.
- `design/drivers/driver-cap.md` §3 — `R_DRIVER_IRQ` right; §4 — NVMe placeholder manifest (one of the retirement path's test subjects).
- `design/kernel/kind-surface-mint.md` — the op-arg packing idiom.
- `design/capabilities/linearity-and-tags.md` §3.1 — base-kind freeze.
- `design/capabilities/derived-kinds.md` — derived-kind lifecycle; §4 on cascading revoke.
- `design/roadmap/next-wave-softarch.md` §R29, §R33 — origin of this cap design in the roadmap.
- `design/kernel/r16-m4-005-ioapic-irq4.md`, `r16-m4-004-idt-vec24-wire.md` — the hard-coded path for UART RX that §4.3 overlays onto.

**External (verify at implementation):**

- Intel SDM Vol 3A §6 (interrupts and exceptions), §9 (processor management), §10 (APIC/MSI-X), §11 (MTRR/PAT, for MMIO caching mode on BAR0).
- ACPI 6.5 §5.2.12 (MADT), §5.2.13 (interrupt source overrides).
- PCI Local Bus Specification 3.0 §6.8 (MSI/MSI-X capability).
- Intel HDA Specification Rev 1.0a (CORB/RIRB/GCTL/INTCTL/INTSTS registers).
- SOF (Sound Open Firmware) architecture overview (optional firmware path, R33+).

**Related, non-binding:**

- `design/drivers/perf-baselines.md` — the ISR-latency target this doc's §6.3 timeline must satisfy.
- `design/drivers/per-driver-tests.md` — witness pattern that the §5.3 fixtures follow.
- `design/drivers/cascade-restart.md` — the supervisor's response to driver crashes that §6.5 relies on.

---

*End of document.*
