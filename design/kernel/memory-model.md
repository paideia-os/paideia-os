# PaideiaOS — Kernel Memory Model

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Architectural specification of the PaideiaOS kernel memory model. Covers the address-space layout (per-CPU NUMA-local kernel direct map + critical-structures region + capability-mediated user), page-table management as capabilities, NUMA strategy, page-size policy (4K/2M/1G), the page-fault-as-effect protocol, copy-on-write via substructural sharing, memory typing (MMIO, persistent, CXL.mem, encrypted), PCID + KPTI-equivalent address-space switching, tiered memory reclamation, and CXL.mem / persistent-memory architectural hooks. Resolves CAP-O3 (descriptor-table placement) and CAP-O4 (5-level paging interaction).

**Hard inputs (do not relitigate):**
- `design/00-feature-inventory.md` — C2 (physical memory manager NUMA-aware), C3 (virtual memory / AS objects), C10 (address-space isolation primitives), C13 (page-fault / external-pager protocol); D11 (PMem/CXL.mem), D12 (disaggregated memory).
- `design/01-foundational-decisions.md` — Q12 (48-bit default, 57-bit opt-in per AS), Q15 (max mitigations default), §3 tension #3 (LAM availability across i7 generations).
- `design/02-development-environment.md` — feature-masked CI lanes test the 5-level / no-5-level / no-LAM combinations (§10.5).
- `design/toolchain/custom-assembler.md` — substructural lattice (Q-A2), algebraic effects (Q-A3), elaborator (Q-A4), R12/R13 capability band, R14/R15 effect environment, unsafe escape (Q-A8).
- `design/ipc/wait-free-dataflow.md` — IPC slot arrays are shared memory between producer/consumer; cache-line discipline; replay-marker emission.
- `design/capabilities/linearity-and-tags.md` — descriptor table in kernel-only memory; kind-tagged variants; retype operation; LAM tag layout; software-LAM fallback.
- `design/security/pq-trust-root.md` — software enclave is IOMMU-isolated userspace; TME-MK where available.

---

## 0. Decisions summary

### 0.1 Inherited (already binding)

| Source | Constraint |
|---|---|
| Q12 | 48-bit (4-level) paging is the per-AS default; 57-bit (5-level) is opt-in per AS. |
| Q15 | Max Spectre/Meltdown mitigations are default; KPTI-equivalent split tables; `relax-mitigations` capability for opt-out. |
| CAP-Q1 | Capability handles are LAM-tagged pointers into the kernel-only descriptor table. |
| CAP-Q2 | Descriptors are kind-tagged variants with a 16-byte common header. |
| CAP-Q3 | Two-tier kind hierarchy: closed 16-kind base enum + userspace-derived kinds via the type system. |
| CAP-Q5 | LAM tag layout (15 bits at 4-level): 8-bit epoch + 2-bit linearity + 4-bit kind hint + 1-bit sealed. |
| CAP-Q7 | Retype: memory regions transform into other capability kinds, consuming the underlying memory. |

### 0.2 New decisions in this document

| # | Question | Decision |
|---|---|---|
| MEM-Q1 | Kernel AS view of physical memory | Per-CPU NUMA-local direct map of the calling CPU's NUMA-local physical RAM, on-demand mapping for cross-NUMA access, and a small (≤ 64 GiB) fixed *critical-structures region* always mapped, holding the descriptor table, per-CPU scheduler queues, IDT/GDT, IOAPIC base. Bulk userspace memory remains capability-mediated. |
| MEM-Q2 | Page-table management | seL4-style: each page-table level (PML5/PML4/PDPT/PD/PT) is its own capability kind; userspace retypes memory regions into page-table caps; userspace assembles the tree via `map(cap, vaddr, page_cap, rights)` operations; the kernel verifies alignment, rights, and substructural discipline at install. |
| MEM-Q3 | NUMA strategy | Per-domain physical-page free lists + per-domain slab pools per kind. NUMA affinity is a descriptor flag. No automatic rebalancing. Explicit `migrate_cap` for migration; cross-domain access is allowed but logs an audit warning. |
| MEM-Q4 | Page-size policy | All three Intel page sizes (4 KiB, 2 MiB, 1 GiB) supported as *derived kinds* of a single base `page` kind, preserving the closed CAP-Q3 enum: `Page4KCap`, `Page2MCap`, `Page1GCap` are functor-typed signatures over base `page`. The kernel descriptor's kind-specific tail carries the size; the type system enforces the static distinction. |
| MEM-Q5 | External pager protocol | Page fault is an algebraic effect (`!{page_fault}`). The address space's installed handler (a userspace pager process holding `pager_cap` for the AS) handles it via the standard effect-dispatch mechanism. |
| MEM-Q6 | Copy-on-write | CoW emerges from the substructural lattice + page-fault effect handler: an affine read-only child cap is shared while the linear write cap is private; on write to a shared page, the page fault handler allocates, copies, and remaps. No dedicated CoW kind. |
| MEM-Q7 | Memory typing | Physical attributes (RWX, cacheability mode, MTRR/PAT bits, NUMA domain, TME-MK key-id, persistence flag) live in the descriptor tail. Semantic distinctions (`MmioMemCap`, `PersistentMemCap`, `EncryptedMemCap`, `IpcSlotRingCap`, `SharedMemCap`) are *derived kinds* over the base `memory` kind with effect-typed signatures. |
| MEM-Q8 | TLB / AS switching | PCID-tagged TLB (4096 simultaneous PCIDs; per-CPU LRU recycling). KPTI-equivalent split page tables (kernel and user halves are separate sets) by default per Q15. `relax-mitigations` capability switches to a combined kernel-user page table for trusted single-tenant workloads; the use is audited. |
| MEM-Q9 | Reclamation under pressure | Tiered: the pager (per MEM-Q5) handles routine pressure (eviction to backing store, drop clean shared pages, expire CoW snapshots). The kernel raises a `MemoryPressure` effect at crisis pressure; the *supervisor* handles it by revoking specific capabilities per its policy. The supervisor must hold reserved memory to be reachable in low-memory conditions. |
| MEM-Q10 | CXL.mem / PMem hooks | Derived kinds with specific effect rows: `PersistentMemCap !{pmem_read, pmem_write, pmem_clwb, pmem_fence}` (durability is type-enforced); `CxlMemCap` with host-bias/device-bias modes as effect operations; `FarMemCap` with latency-class metadata. The kernel descriptor flags distinguish at runtime; the type system enforces statically. |

### 0.3 Three meta-positions

1. **Kernel size is bounded.** Despite the per-CPU NUMA direct map and the critical-structures region, the kernel's *code* and *exclusively-owned data* remain a small surface (target: < 256 KiB of code, per the microkernel pillar). The direct map is *access*, not *code*; the kernel mostly reads userspace-owned descriptors through it.

2. **The 5-level paging path is degraded but supported.** Per CAP-Q5, 5-level paging gives only 6 LAM tag bits (vs 15 at 4-level). The capability system's fast-path checks lose the kind hint and shrink the revocation-epoch window. Documents and code paths treat 5-level as a power-user opt-in for processes needing > 128 TiB virtual; the recommendation in CAP-O4 stands.

3. **Substructural discipline at the page-cap level produces CoW without a CoW mechanism.** This is the most novel claim in this document. The fact that `mem_share` lowers a cap from linear to affine, that affine caps can be shared while linear cannot, and that the page-table installer marks pages read-only when more than one affine view exists, combine to produce CoW semantics *as a consequence* of the system rather than as a feature. The pager's job becomes implementing the write-fault response, which is purely a copy-and-remap operation. See §7.

---

## 1. Architectural overview

```
   48-bit canonical address space (Q12 default)

   0xFFFF_FFFF_FFFF_FFFF  ┌──────────────────────────────────────┐
                          │ Kernel half (negative canonical)      │
                          │                                       │
                          │  ┌─────────────────────────────────┐ │
                          │  │  Critical structures region     │ │
                          │  │  (~64 GiB at fixed VA)          │ │
                          │  │   - descriptor table             │ │
                          │  │   - per-CPU areas (one per CPU) │ │
                          │  │   - IDT, GDT, IOAPIC base       │ │
                          │  │   - effect environment slots    │ │
                          │  └─────────────────────────────────┘ │
                          │                                       │
                          │  ┌─────────────────────────────────┐ │
                          │  │ Per-CPU NUMA-local direct maps  │ │
                          │  │   CPU 0 sees its NUMA-0 RAM here│ │
                          │  │   CPU 1 sees its NUMA-0 RAM here│ │
                          │  │   ...                            │ │
                          │  │   (each CPU has a different     │ │
                          │  │    layout, walked via FS-base)  │ │
                          │  └─────────────────────────────────┘ │
                          │                                       │
                          │  ┌─────────────────────────────────┐ │
                          │  │ Cross-NUMA on-demand mapping    │ │
                          │  │   (transient; explicit op)      │ │
                          │  └─────────────────────────────────┘ │
                          │                                       │
   0xFFFF_8000_0000_0000  └───────────────────────────────────────┘
                          ┌─── non-canonical hole ────────────────┐
   0x0000_7FFF_FFFF_FFFF  └───────────────────────────────────────┘
                          ┌──────────────────────────────────────┐
                          │ User half (positive canonical)        │
                          │                                       │
                          │  per-process VMAs as capability-      │
                          │  managed page tables                  │
                          │                                       │
                          │  IPC channel slot arrays are shared   │
                          │  memory regions mapped here in both   │
                          │  producer and consumer ASes (via      │
                          │  mem_share)                           │
                          │                                       │
                          │  no kernel mapping under KPTI         │
                          │  (kernel CR3 switched on entry)       │
                          │                                       │
   0x0000_0000_0000_0000  └───────────────────────────────────────┘

   57-bit canonical address space (Q12 opt-in)

   Same partition, scaled: kernel half from 0xFF80_... down;
   user half from 0x007F_... up. The critical-structures region
   is still ~64 GiB (it's bounded, not proportional). Per-CPU
   NUMA direct maps can be larger. LAM tag space shrinks to 6
   bits per CAP-Q5.
```

The kernel half is fully populated for every AS (KPTI moves the *visibility* of this in the user-mode page-table set, not the layout itself).

---

## 2. Address-space layout (MEM-Q1)

### 2.1 The kernel half partition

The kernel half of every AS contains, in order:

| Region | VA range (48-bit) | Size | Purpose |
|---|---|---|---|
| Critical structures | `0xFFFF_8000_0000_0000` – `0xFFFF_8FFF_FFFF_FFFF` | ≤ 64 GiB | Fixed-VA kernel state: descriptor table base, per-CPU areas, IDT, GDT, IOAPIC base, MSR shadow, effect-environment template. |
| Per-CPU NUMA-local direct maps | `0xFFFF_9000_0000_0000` – `0xFFFF_DFFF_FFFF_FFFF` | ~4.5 TiB | Each CPU's slot maps its NUMA-local physical RAM 1:1. CPU 0 sees its memory at `0xFFFF_9000_…`; CPU 1 at `0xFFFF_A000_…`; etc. Slot size up to 1 TiB per CPU (sufficient for current NUMA node sizes). |
| Cross-NUMA on-demand window | `0xFFFF_E000_0000_0000` – `0xFFFF_FFFE_FFFF_FFFF` | ~2 TiB | Reserved for transient cross-NUMA mappings established by `MapAcrossNuma` operations. |
| Trampoline / KPTI scratch | `0xFFFF_FFFF_0000_0000` – `0xFFFF_FFFF_FFFF_FFFF` | 4 GiB | Tiny region also mapped into the user CR3 set under KPTI for syscall/IPC entry. |

### 2.2 Per-CPU lookup

Each CPU's per-CPU area holds the offset into the per-CPU NUMA-local direct-map window for its own NUMA-local memory. Kernel code computes physical-to-virtual via `direct_va = phys + gs_base.direct_map_offset` where `gs_base` is the per-CPU GS-base set at thread start. This is one ALU op per access.

### 2.3 The descriptor table

The descriptor table (per CAP-Q1) is anchored at a fixed offset in the critical-structures region: `0xFFFF_8000_0000_0000`. Each kind's slab allocator partitions a region of the descriptor table; the kind tag in the LAM bits + the offset within the kind's slab gives O(1) descriptor lookup.

**Resolving CAP-O3:** the descriptor table lives in the critical-structures region of the kernel half at a fixed VA. It is mapped in every AS (modulo KPTI's user-side hiding). The descriptor-table region's size budget is ~16 GiB (4× the per-kind slab quotas).

### 2.4 KPTI interaction

Under KPTI (default per Q15), each AS has *two* CR3 values:
- **Kernel CR3**: full kernel-half + user-half mappings.
- **User CR3**: only the user-half + the 4 GiB trampoline region.

Syscall/IPC entry switches from User CR3 to Kernel CR3; return switches back. The PCID-tagged TLB (per MEM-Q8) preserves most TLB entries across the switch.

A process holding `relax-mitigations` (per Q15) gets a *single* CR3 (combined kernel + user); no KPTI cost. The audit log records every use.

### 2.5 The IPC slot arrays

IPC channel slot arrays are shared-memory regions, mapped into both producer and consumer ASes via the `mem_share` mechanism (the consumer holds an affine `Page2MCap` derived from the producer's linear page). Both ASes see the slots in their user half; the page-table installer ensures cacheability is WB; the channel's metadata records the location.

---

## 3. Page-table management (MEM-Q2)

### 3.1 Page-table capability kinds

Five capability kinds, one per page-table level. Each kind's tail carries the level-specific metadata (entry count, alignment requirements).

| Kind | Size | Entries | When used |
|---|---|---|---|
| `PML5Cap` | 4 KiB | 512 × 8 B | Top level, 5-level paging only (Q12 opt-in). |
| `PML4Cap` | 4 KiB | 512 × 8 B | Top level for 4-level paging; mid-level for 5-level. |
| `PDPTCap` | 4 KiB | 512 × 8 B | Page-directory-pointer table; maps 1 GiB pages when used as leaf. |
| `PDCap` | 4 KiB | 512 × 8 B | Page directory; maps 2 MiB pages when used as leaf. |
| `PTCap` | 4 KiB | 512 × 8 B | Page table; maps 4 KiB pages. |

### 3.2 Construction

Userspace:
1. Has a memory cap covering 4 KiB.
2. Calls `retype(mem_cap, PML4Cap)` to convert; receives a `PML4Cap`.
3. Repeats for each level.
4. Calls `map(parent_cap, vaddr, child_cap, rights)` to install entries.

The kernel's `map` operation verifies:
- The parent and child kinds are correct for the level relationship.
- The vaddr is canonical and aligned to the level.
- The substructural class of the child matches expectations (page caps are linear for owner, affine for shared-read).
- The caller has `pt_map` rights on the parent.
- The leaf cap (a page cap of appropriate size: `Page4KCap` at PT level, `Page2MCap` at PD level, `Page1GCap` at PDPT level) is alignment-compatible.

### 3.3 Page table reclamation

When a `PTCap` (etc.) is revoked, the kernel walks the table for active mappings; each child cap is implicitly released (handed back to its owner). The page-table page is returned to the memory pool (the original memory cap is *not* automatically reformed; the supervisor must explicitly recover memory via `untype`).

### 3.4 Address-space objects

An *address space* is a top-level capability of kind `AspaceCap`; its tail carries a pointer to the top-level page table (`PML4Cap` for 4-level, `PML5Cap` for 5-level). Creating an AS is `retype(mem, AspaceCap)` plus assigning the top page table.

### 3.5 5-level paging selection

The `AspaceCap` carries a 5-level flag. The kernel checks `CR4.LA57` at AS activation; mismatches between AS flag and CPU capability produce an error. The CI feature-masked lanes (per `02-development-environment.md` §10.5) exercise both regimes.

---

## 4. NUMA strategy (MEM-Q3)

### 4.1 Per-domain layout

The kernel maintains, per NUMA domain:
- A physical free-list of 4K pages (the canonical buddy-allocator-equivalent).
- A separate free-list of 2M pages.
- A separate free-list of 1G pages.
- Per-kind slab pools for each descriptor variant.
- A NUMA-affine pool for IPC slot arrays.

The total per-domain footprint is bounded by the NUMA domain's physical-RAM share.

### 4.2 NUMA affinity in the descriptor

Each memory descriptor's tail carries `numa_domain: u8`. Capability operations respect this:
- `mem_share` to a process whose preferred NUMA differs is allowed but logs.
- `mem_read` / `mem_write` from a CPU in a different NUMA pays the on-demand cross-NUMA mapping cost (§2.1's window).

### 4.3 `migrate_cap` operation

```
migrate(cap : MemCap, target_numa : NumaDomain, policy : MigrationPolicy)
  -> MemCap
```

The kernel:
1. Allocates a fresh page in the target NUMA domain.
2. Copies the page contents.
3. Updates all page-table entries that map the original.
4. Optionally invalidates the original (per `policy`).
5. Returns a new cap with `numa_domain = target_numa`.

Migration is explicit; no background thread.

### 4.4 The Lozi-et-al lesson

The decision to *not* auto-rebalance is informed by Lozi, Lepers, Funston, et al., *The Linux Scheduler: a Decade of Wasted Cores* (EuroSys 2016), which documented how Linux's scheduling-and-memory-rebalancing interactions silently degraded performance for years. PaideiaOS's posture: NUMA is a first-class capability attribute; the application or supervisor decides when to migrate; nothing happens behind your back.

---

## 5. Page-size policy (MEM-Q4)

### 5.1 Derived kinds preserve the base enum

The CAP-Q3 closed enum of 16 base kinds does *not* grow. Instead, the kernel has one base `page` kind whose descriptor tail carries the page size; the type system defines three derived kinds:

```paideia-as
module Page4KCap : MemoryDerivedCapSig = derive(PageCap, size = 4*KiB)
module Page2MCap : MemoryDerivedCapSig = derive(PageCap, size = 2*MiB)
module Page1GCap : MemoryDerivedCapSig = derive(PageCap, size = 1*GiB)
```

Code expecting a `Page4KCap` cannot accidentally receive a `Page1GCap`; type errors are compile-time. The kernel descriptor's `size` field is the runtime backstop.

### 5.2 Size selection at retype

```
retype(mem_cap, Page4KCap)  -- mem_cap must be ≥ 4 KiB, 4 KiB aligned
retype(mem_cap, Page2MCap)  -- mem_cap must be ≥ 2 MiB, 2 MiB aligned
retype(mem_cap, Page1GCap)  -- mem_cap must be ≥ 1 GiB, 1 GiB aligned
```

The kernel verifies alignment and size; mismatch produces `RetypeAlignment` error.

### 5.3 Promotion / demotion

PaideiaOS does *not* perform transparent huge-page promotion. The programmer chooses size at retype. Demotion (1G → 2M) is a deliberate operation: a `Page1GCap` can be split into 512 `Page2MCap`s via `split_page(cap)`; the original cap is consumed. Promotion is *not* supported (combining smaller pages is hard to make safe; the boundaries are not contiguous-aware).

### 5.4 TLB benefits

The 1 GiB page maps into a single PDPT entry, occupying one TLB slot — invaluable for the kernel direct map and large data regions (audit log, NIC ring buffers, persistent memory). The kernel's per-CPU NUMA direct map uses 1 GiB pages where possible (the NUMA node's RAM is usually 1G-aligned at its base).

---

## 6. Page-fault and pager protocol (MEM-Q5)

### 6.1 The `PageFault` effect

```paideia-as
effect PageFault {
  op handle : (faulting_vaddr : u64,
               fault_kind : FaultKind,
               faulting_thread : ThreadCap,
               aspace : AspaceCap)
              -> FaultResponse

  type FaultKind = NotPresent | WriteToReadOnly | UserExecKernelPage
                 | RsvdBitSet  | InstrFetchFromNX | CowWrite | …
}
```

The kernel raises this effect on every page fault. The handler runs in userspace; it has the faulting thread suspended; it has full access to the AS via its `pager_cap`.

### 6.2 Handler installation

At AS creation, the supervisor installs a `PageFault` handler in the AS's effect environment. The handler is a userspace pager process holding `pager_cap` for the AS; the cap authorizes the pager to allocate and map pages in the AS.

The handler may be replaced (e.g., during a fork-like operation: a new pager is installed; the previous one is detached). The replacement is itself audited.

### 6.3 Fault delivery sequence

```
1. CPU page-faults: vaddr in CR2, error code on stack, CPU traps to IDT vector 14.
2. Kernel saves the faulting thread's state; switches stack.
3. Kernel reads CR2 and the error code; constructs the FaultKind.
4. Kernel computes the AS's PageFault handler (looks up in the AS's effect env).
5. Kernel emits the effect: the handler is dispatched as a function call from the kernel
   stack — but the call's "callee" is a userspace endpoint (via IPC).
6. The pager receives the fault; processes it; replies with FaultResponse.
7. Kernel updates page tables per the response; resumes the faulting thread.
```

The latency budget is per the IPC primitive's hot-path (§12 of the IPC doc): handler dispatch + IPC round-trip + page-table install. Target: sub-microsecond on warm pager.

### 6.4 The `FaultResponse`

```paideia-as
type FaultResponse =
  | Mapped (cap : PageCap, rights : Rights)           // install this; resume
  | DeferredFault (token : ResumeToken)               // pager will call back; thread blocked
  | Forbidden                                          // the fault is illegal; signal the thread
  | Migrate (target_numa : NumaDomain)                // the pager is migrating; retry after
```

### 6.5 Demand paging

Demand paging is the default. The supervisor at process start grants the pager `pager_cap`; the pager establishes only a minimal set of mappings (text segment via mmap-equivalent); subsequent reads/writes fault, the pager handles. The pager owns the policy (which pages stay resident, which go to backing store).

### 6.6 Interaction with the IPC primitive

The pager-as-handler is itself an IPC consumer; the fault delivery is a session-typed channel `PageFaultChannel` with session `↑Fault . ↓Response . end`. The pager runs as a wait-free consumer per the IPC primitive's discipline.

---

## 7. Copy-on-write (MEM-Q6)

### 7.1 The substructural setup

A page cap minted with `mem_share` rights is *affine* (it can be dropped, can be copied via mint, but cannot be written through). The original cap retains `mem_write` rights as a *linear* cap.

When the owner mints affine share-children to N other processes:
1. The kernel marks the page's PTE read-only in *all* mappings (including the owner's).
2. The descriptor records `shared_count = N`.

### 7.2 The write fault

When any holder (owner or sharer) attempts to write through a read-only mapping, the `PageFault` effect handler receives `WriteToReadOnly`. The pager:
1. Checks the descriptor's `shared_count`: > 1 means CoW is in effect.
2. Allocates a fresh page (NUMA-local to the faulting CPU).
3. Copies the old page's contents.
4. Maps the fresh page into the faulting AS with the original rights (writable for the owner; the affine share-children remain pointing to the old page, which still has `shared_count - 1` references).
5. Decrements the original page's `shared_count`; if it reaches 1, the remaining holder regains write access (its mapping is upgraded).
6. Resumes the faulter.

### 7.3 Why this is novel

In Linux/BSD CoW, the kernel maintains explicit CoW state; the kernel's fork code marks pages CoW; the kernel's page-fault handler does the copy. CoW is a *feature* with its own code path.

In PaideiaOS, CoW is *not a feature* — it is the natural consequence of:
- Affine read-share caps being introduced into the linear-by-default lattice.
- The page-table installer's policy of marking pages read-only when their share count exceeds 1.
- The pager's standard write-fault handling.

No code in the kernel is dedicated to CoW; the pager's policy can implement it (or not — a pager could choose to deny the write, returning `Forbidden`, which is a different valid policy).

### 7.4 The fork-equivalent semantics

PaideiaOS has no `fork()` (no POSIX, per Q9). The equivalent is: a process snapshots an AS by minting affine share-children of every page cap in the AS, installing them in a new AS via a fresh page table built up by the seL4-style mechanism (§3). The mint operations and the page-table assembly are O(n) in the page count; if the new AS later writes, CoW happens as a page-fault response.

This is more verbose than `fork()` but vastly more explicit; the supervisor can audit exactly which pages were shared and at what rights.

---

## 8. Memory typing (MEM-Q7)

### 8.1 Physical attributes in the descriptor

The memory descriptor's tail carries:

| Field | Bits | Purpose |
|---|---|---|
| `base` | 52 | Physical base address (50 bits sufficient for 4 PiB; rounded to 52 for alignment). |
| `length` | 52 | Region length in bytes. |
| `rwx` | 3 | Permission bits used to populate PTE on map. |
| `cacheability` | 3 | WB / WT / WC / WP / UC / UC- (encoded). |
| `mtrr_pat` | 3 | MTRR/PAT index hint. |
| `numa` | 8 | NUMA domain. |
| `tme_keyid` | 16 | TME-MK key-id (0 = unencrypted). |
| `persistence` | 1 | Set for PMem regions. |
| `mmio` | 1 | Set for MMIO regions (forces UC + special-instruction discipline). |

### 8.2 Derived kinds

Userspace defines, via the CAP-Q3 two-tier mechanism, derived kinds with effect-typed signatures:

```paideia-as
module MmioMemCap : MemoryDerivedCapSig = derive(MemCap)
  with effects = !{mmio_read, mmio_write, mmio_fence}
       cacheability = UC

module PersistentMemCap : MemoryDerivedCapSig = derive(MemCap)
  with effects = !{pmem_read, pmem_write, pmem_clwb, pmem_fence}
       persistence = true
       cacheability = WB

module EncryptedMemCap : MemoryDerivedCapSig = derive(MemCap)
  with effects = !{mem_read, mem_write}
       tme_keyid = nonzero

module IpcSlotRingCap : MemoryDerivedCapSig = derive(MemCap)
  with effects = !{spsc_load, spsc_store, spsc_fence}
       cacheability = WB
       alignment = 64                  // cache-line discipline

module SharedMemCap : MemoryDerivedCapSig = derive(MemCap)
  with effects = !{mem_read, mem_write, mem_share}
       linearity_class = Affine
```

### 8.3 What the type system catches

- Treating MMIO as normal memory (a write to an `MmioMemCap` requires the `mmio_write` effect, not `mem_write`).
- Writing to PMem without the `pmem_clwb` discipline (the type system requires `clwb` after each `pmem_write` before the next operation; the elaborator enforces this).
- Sharing memory without the `SharedMemCap` derivation (a linear `MemCap` cannot be `mem_share`-d).

### 8.4 What the runtime catches

- An `unsafe` block that fabricates a write to an MMIO region without the descriptor's `mmio = true` flag: the kernel's write path checks the descriptor; the absent flag makes the write proceed *but* the LAM kind hint and effect environment may have logged an anomaly via the audit channel.
- A capability whose descriptor's `cacheability` does not match the page-table entry's PAT bits: the page-table installer refuses to install.

---

## 9. TLB and AS switching (MEM-Q8)

### 9.1 PCID assignment

Each `AspaceCap` is assigned a 12-bit PCID at creation. The PCID space (0–4095) is managed per-CPU LRU; an exhausted PCID space recycles the oldest PCID by invalidating its TLB entries via `INVPCID type=1`.

The PCID is recorded in the descriptor's tail and is loaded into CR3.PCID on every `mov cr3` operation.

### 9.2 KPTI-equivalent split tables

For every AS, two page-table sets:
- **Kernel set**: full mappings.
- **User set**: user half + 4 GiB trampoline only.

The trampoline contains:
- The IDT entries' code path stubs (so syscall/IPC entry can switch CR3 before touching real kernel code).
- The IST stacks for fault handling.
- A small read-only region with effect-environment pointers.

CR3 switching at entry/exit costs ~150–300 cycles on modern hardware; PCID preserves most TLB entries across the switch.

### 9.3 `relax-mitigations` opt-out

A process holding `relax-mitigations` (per Q15) is assigned an `AspaceCap` whose tail records `single_cr3 = true`. The kernel uses a combined kernel-user page-table set for this AS; no CR3 switch on syscall/IPC entry; full TLB benefit.

Every use is logged. The supervisor's grant of `relax-mitigations` is audited; revocation cascades through the supervisor's policy.

### 9.4 Cross-AS IPC

IPC across ASes (the wait-free dataflow primitive's cross-AS path) requires:
1. Source AS holds `SendCap`; target AS holds `RecvCap`.
2. The channel's slot array is shared memory (mapped in both ASes via `mem_share`).
3. On enqueue, the source writes to its mapping of the slot.
4. The IPI to the target CPU triggers a context switch in the target AS.
5. The target's CR3 is loaded (PCID-tagged, mostly TLB-warm), the target dequeues.

The PCID + shared-slot approach means cross-AS IPC pays approximately one cache-coherence round-trip per message; no TLB-shootdown cost.

---

## 10. Reclamation under pressure (MEM-Q9)

### 10.1 Routine: pager-level

When the pager's per-AS memory budget approaches its limit, the pager's policy decides eviction. Standard patterns:
- Drop clean shared pages (the affine share-children); they can be re-faulted if accessed.
- Write dirty pages to backing store (the pager's `swap_cap` channels them to the disk server).
- Drop CoW snapshots that are superseded.

The pager owns the policy; the kernel offers the operations.

### 10.2 Crisis: `MemoryPressure` effect

When the kernel cannot allocate even for the pager (the pager itself faulted; no memory available), the kernel raises:

```paideia-as
effect MemoryPressure {
  op crisis : (failing_aspace : AspaceCap, requested_size : usize)
              -> CrisisResponse
}
```

The supervisor's installed handler responds:
- Revoke specific capabilities held by non-essential processes (kills them).
- Reduce caches in audited subsystems (the audit log signer's buffer; the network stack's NIC ring).
- Deny new allocations (the failing operation returns `OutOfMemory`).
- Trigger paging migration to another node (in multi-node deployments via D14).

### 10.3 Supervisor reserved memory

The supervisor's `AspaceCap` carries a *reserved memory budget*: a quantity of physical memory pre-allocated and not subject to general reclamation. This ensures the supervisor remains reachable in low-memory conditions. The reserved budget is set at boot (a kernel command-line parameter) and is part of the supervisor's identity.

### 10.4 No OOM killer

There is no kernel-internal OOM-killer policy. The supervisor *may* implement an OOM-equivalent policy as part of its `MemoryPressure` handler, but the kernel makes no decisions.

---

## 11. CXL.mem / persistent memory hooks (MEM-Q10)

### 11.1 Persistent memory

`PersistentMemCap` requires the `pmem_clwb` and `pmem_fence` effects after writes for durability. The type system enforces the discipline:

```paideia-as
fn save_persistent(p : Page4KCap[PersistentMemCap]) -> unit !{pmem_write, pmem_clwb, pmem_fence} =
  ; ... writes to p ...
  pmem_clwb p             ; required by the type system; elaborator inserts if omitted
  pmem_fence              ; required before any next pmem op
```

The kernel descriptor's `persistence = true` flag triggers special handling at retype (alignment to PMem region boundaries) and at the page-table installer (WB cacheability, but PAT bit selected for PMem).

### 11.2 CXL.mem bias modes

`CxlMemCap` has two operating modes encoded as effect operations:

```paideia-as
effect CxlBias {
  op host_to_device : (cap : CxlMemCap) -> CxlMemCapDeviceBias
  op device_to_host : (cap : CxlMemCapDeviceBias) -> CxlMemCap
}
```

Host-bias: the host CPU caches the memory directly (standard CC.PROT). Device-bias: the device (e.g., a CXL accelerator) has exclusive cache state. Transitions are explicit operations; the kernel's installer manages the CXL.mem coherence protocol bits.

### 11.3 Disaggregated / far memory

`FarMemCap` carries metadata:

```paideia-as
module FarMemCap : MemoryDerivedCapSig = derive(MemCap)
  with effects = !{far_read, far_write}
       latency_class = { LocalDIMM | CxlAttached | NetworkPaged }
       persistence = optional
```

The latency class is type-system-visible so programmers can write latency-aware code. The runtime mapping (to actual remote memory) is the pager's job; the kernel just provides the descriptor structure.

### 11.4 Phase 3+

PaideiaOS does not ship D11/D12 in phase 1 or phase 2. The architectural hooks here ensure the eventual implementations slot in without protocol changes; phase-3 work fills in the actual hardware integration (the QEMU CXL device model maturity per CAP-O4 / dev-env H7 is gating).

---

## 12. paideia-as implementation

### 12.1 Module layout

`src/kernel/mm/` is the kernel memory manager:

```
src/kernel/mm/
├── direct_map.s          # per-CPU NUMA direct map setup
├── critical.s            # critical-structures region init
├── descriptor_table.s    # descriptor table location and slab allocators
├── pt.s                  # page-table-as-capability ops
├── pcid.s                # PCID allocation and recycling
├── kpti.s                # KPTI-equivalent split tables
├── numa.s                # per-domain free lists, migrate_cap
├── pages.s               # page-size derived kinds (4K/2M/1G)
├── fault.s               # page-fault entry; PageFault effect emission
├── pressure.s            # MemoryPressure effect emission
└── memtype.s             # MMIO/PMem/CXL.mem flag handling
```

### 12.2 Phase-1 vs phase-2 split

Phase 1 (NASM bootstrap):
- The per-CPU NUMA direct map is set up at boot.
- The critical-structures region is fixed.
- Page tables are kernel-internal data structures (the seL4-style capability model is phase 2 — the elaborator isn't ready).
- 4K and 2M pages only.
- No KPTI in phase 1 (test hardware is dev workstations that the developer trusts).
- No CXL.mem / PMem.

Phase 2 (paideia-as coexistence):
- Page tables become capabilities.
- 1G pages enabled.
- KPTI enabled by default; relax-mitigations capability available.
- PageFault and MemoryPressure effects come online.
- CoW emerges from substructural sharing.

Phase 3 (paideia-as canonical):
- All features active.
- CXL.mem / PMem derived kinds ship when hardware models stabilize.

### 12.3 Boot path

The boot sequence:
1. UEFI loader provides the memory map.
2. PaideiaOS loader constructs the initial page tables: kernel-only (no userspace yet); identity-mapped for the loader's region; high-half map for the kernel's load address.
3. Loader jumps to the kernel entry; CR3 already loaded.
4. Kernel discovers NUMA topology from ACPI SRAT.
5. Kernel allocates per-domain free lists; populates from the memory map.
6. Kernel sets up the critical-structures region (descriptor table base, per-CPU areas, IDT, GDT).
7. Kernel constructs per-CPU NUMA direct maps as each CPU comes online.
8. Kernel constructs the root task's AS via retype-from-memory.
9. Kernel hands control to the root task.

---

## 13. Performance budget

| Operation | Budget | Substrate |
|---|---|---|
| Kernel direct-map access (local NUMA) | ~1 cycle (post-TLB-hit) | bare-metal Sapphire Rapids |
| Cross-NUMA direct-map miss (rare) | ~200 cycles (cross-socket DRAM) | bare-metal dual-socket |
| Page-table install (one entry) | ~50 ns | bare-metal |
| Retype memory → page table | ~150 ns | bare-metal |
| Page fault round-trip to warm pager | ≤ 1 µs | bare-metal |
| Cold page fault (allocation + map + resume) | ≤ 5 µs | bare-metal |
| CoW write fault | ≤ 3 µs (copy + remap) | bare-metal, 4 KiB page |
| PCID-switching context switch | ≤ 300 cycles | bare-metal |
| KPTI CR3 switch overhead | ≤ 150 cycles | bare-metal |
| TLB shootdown (one-page invalidate, cross-core) | ≤ 500 ns | bare-metal |
| NUMA migrate_cap (4 KiB, cross-socket) | ≤ 1 µs | bare-metal |

Aspirational; baselines come from `design/kernel/mm-perf-baselines.md` (future).

---

## 14. Verification strategy

### 14.1 Layer A: TLA+ spec

`design/kernel/mm.tla` (future) formalizes:
- Page-table capability lifecycle.
- The PageFault effect dispatch protocol.
- The CoW emergence from substructural sharing.
- The memory-pressure escalation chain.

### 14.2 Layer B: property-based testing

The PBT harness exercises:
- Random retype sequences; verify alignment, kind discipline.
- Random map / unmap patterns; verify page-table consistency.
- Random share / write patterns; verify CoW occurs at expected times.
- Adversarial pager: tests of MemoryPressure escalation.

### 14.3 Layer C: feature-masked CI lanes

Per `02-development-environment.md` §10.5:
- 4-level vs 5-level paging both exercised.
- LAM vs software-LAM both exercised (impacts the LAM tag in descriptors).
- NUMA topologies (2-domain, 4-domain) exercised.
- KPTI vs relax-mitigations both exercised.

### 14.4 Layer D: bare-metal stress

Multi-process memory torture on real hardware:
- Concurrent retype on same memory region (must serialize).
- Cross-NUMA migration under load.
- CoW under heavy write contention.
- TLB shootdown storm.

---

## 15. Open issues

| ID | Issue | Resolution location |
|---|---|---|
| MEM-O1 | TLA+ spec for the page-table capability protocol — phase-1 deliverable. | `design/kernel/mm.tla` (future) |
| MEM-O2 | Critical-structures region size budget (~64 GiB) — is this enough as the per-CPU area count grows on many-CPU systems? Verify with a calculation for 128-CPU NUMA systems. | `design/kernel/critical-structures.md` (future) |
| MEM-O3 | The interaction of NUMA migration with linear capabilities — does `migrate_cap` consume the original cap (linear semantics) or duplicate? Phase-2 detail. | `design/kernel/numa-migration.md` (future) |
| MEM-O4 | 5-level paging support — when is it tested vs. 4-level? Default is 4-level; per-process opt-in needs a clear test matrix. | `design/kernel/5-level-testing.md` (future) |
| MEM-O5 | The `MemoryPressure` escalation interaction with capability revocation — if the supervisor revokes a capability whose holder is mid-IPC, what happens to in-flight messages? | TLA+ spec |
| MEM-O6 | Page-table page reclamation timing — when does an unmapped page-table page actually return to the memory pool? Race with concurrent maps. | TLA+ spec |
| MEM-O7 | CoW correctness under multi-share scenarios — when N processes share, the first writer triggers copy; what if multiple writers fault simultaneously on different CPUs? | TLA+ spec |
| MEM-O8 | The 1G page kind — phase-2 enablement requires the supervisor to know which physical regions are 1G-aligned (a NUMA layout property). | `design/kernel/huge-pages.md` (future) |
| MEM-O9 | TME-MK key-id management — who issues key-ids, how are they recycled, how is the descriptor's key-id verified at runtime. | `design/security/memory-encryption.md` (future) |
| MEM-O10 | Persistent-memory recovery on power-fail — pager's policy for re-attaching surviving PMem regions on next boot. | `design/kernel/pmem-recovery.md` (future) |
| MEM-O11 | CXL.mem bias-mode transitions — coherence-protocol cost on the host CPU; performance characterization. | `design/kernel/cxl.md` (future) |
| MEM-O12 | Disaggregated memory — D12 architectural hooks here are minimal; the actual implementation in `design/network/far-memory.md` (future) is deferred. | `design/network/far-memory.md` (future) |
| MEM-O13 | Phase-1 fallback API — which subset of phase-2 memory ops is available with kernel-internal page tables. | `design/kernel/phase1-mm-api.md` (future) |
| MEM-O14 | Performance baselines (§13) are aspirational; first bare-metal measurements drive `mm-perf-baselines.md`. | `design/kernel/mm-perf-baselines.md` (future) |

---

## 16. References

### 16.1 OS memory management

- Klein, G. et al. *seL4: Formal Verification of an OS Kernel*. SOSP 2009. (Page-table-as-capability lineage.)
- Elphinstone, K., Heiser, G. *From L3 to seL4*. SOSP 2013.
- Bonwick, J. *The Slab Allocator: An Object-Caching Kernel Memory Allocator*. USENIX 1994. (Per-kind slab pools.)
- Lameter, C. *SLUB: The Unqueued Slab Allocator*. (Linux SLUB design.)
- Lozi, J.-P., Lepers, B., Funston, J., Gaud, F., Quéma, V., Fedorova, A. *The Linux Scheduler: a Decade of Wasted Cores*. EuroSys 2016. (NUMA-blindness cautionary tale.)

### 16.2 Address-space isolation and KPTI

- Gruss, D. et al. *KAISER: Defeating Meltdown* (KPTI foundational). DIMVA 2017.
- Lipp, M. et al. *Meltdown: Reading Kernel Memory from User Space*. USENIX Security 2018.

### 16.3 Copy-on-write and shared memory

- Rashid, R. et al. *Mach: A Foundation for Open Systems*. Workstation Operating Systems, 1989. (CoW in Mach.)

### 16.4 NUMA and many-core

- Boyd-Wickizer, S. et al. *An Analysis of Linux Scalability to Many Cores*. OSDI 2010.
- Linux NUMA documentation, `Documentation/admin-guide/mm/numa_memory_policy.rst`.

### 16.5 CXL and persistent memory

- Compute Express Link Specification, current revision. (CXL.mem semantics.)
- Intel Optane DC Persistent Memory documentation.
- SNIA NVM Programming Model.
- Volos, H. et al. *Mnemosyne: Lightweight Persistent Memory*. ASPLOS 2011.

### 16.6 Intel documentation

- Intel® 64 and IA-32 Architectures Software Developer's Manual, Vol. 3A ch. 4 (paging), ch. 6 (interrupts/exceptions for page fault), Vol. 3B ch. 11 (memory cache control), Vol. 3C ch. 19 (PCID + INVPCID).
- Intel® 5-Level Paging and 5-Level EPT White Paper, rev. 1.1, 2017.

---

*End of document.*
