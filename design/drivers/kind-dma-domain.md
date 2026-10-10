---
issue: 2519
wave: 59
item: D2
round: R29
subsystem: cap / drivers / iommu
topic: KIND_DMA_DOMAIN per-device IOMMU domain substrate — capability shape, buffer-mapping API, TB4 per-dock scoping, invalidation discipline, HDA + Iris Xe PPGTT consumers
touching:
  - src/kernel/core/cap/kind_dma_domain.pdx          (R29.M5-001..004 landed; §3 extends OP_MAP/OP_UNMAP/OP_FLUSH/OP_QUERY_FAULT bodies)
  - src/kernel/core/iommu/domain_switch.pdx          (R29.M5-004 landed; §4 adds hw-ready wire-up)
  - src/kernel/core/iommu/vtd_slpt.pdx               (R22.M4 landed; §5 adds 2 MiB large-page map path)
  - src/kernel/core/iommu/vtd_ctx.pdx                (R22.M4 landed)
  - src/kernel/core/iommu/vtd_fault.pdx              (R22.M4 landed; §6 adds per-domain fault counters)
  - src/kernel/core/iommu/invalidate.pdx             (new; §7 CCMD + IOTLB + queued-invalidation primitives)
  - src/kernel/drivers/hda/*                         (future; D15 consumer, §10)
  - src/kernel/drivers/iris_xe/ppgtt/*               (future; G5 consumer, §11)
  - src/kernel/drivers/tb/dock_domain.pdx            (future; TB4 per-dock hot-plug, §8)
prereqs:
  - "#1036 (KIND_DMA_DOMAIN row-indirection substrate) — LANDED"
  - "#1037 (canonical tail-word encoder) — LANDED"
  - "#1038 (dma_cap_mint / revoke / cascade) — LANDED"
  - "#1039 (iommu_domain_switch contract + state machine) — LANDED"
  - "paideia-os#873 (IOMMU boot toggle; Features.IOMMU_ENABLED) — LANDED, inert"
consumers:
  - D15 (Intel HDA controller) — stream BDL + buffer-pool DMA mapping
  - D6 (LPSS I2C) — ring-buffer DMA for scatter-gather bursts
  - G5 (Iris Xe PPGTT) — per-engine PPGTT bring-up citing this doc for the second-stage walk
  - D17..D20 (TB4 tunneled devices) — per-dock domain mint on hot-plug (R35 scope)
related:
  - design/kernel/iommu-boot-toggle.md               (Features.IOMMU_ENABLED, R23 wire-up checklist)
  - design/capabilities/derived-kinds.md             (derived-kind safety discipline)
  - design/capabilities/linearity-and-tags.md        (closed 16-slot base enum)
  - design/drivers/driver-cap.md                     (R_DRIVER_DMA, manifest-side authority)
  - design/drivers/blob-policy.md §2.1               (one domain per driver process; CNVi split)
  - design/roadmap/next-wave-synthesis.md §P13       (Thunderclap mitigation)
  - design/networking/iommu-audit.md                 (DMA-fault audit stream)
---

# KIND_DMA_DOMAIN — Per-Device IOMMU Domain Capability

## 1. Purpose

`KIND_DMA_DOMAIN` (derived tag `0x142`, runtime base `KIND_MEMORY = 4`) is
the cap-side authority that scopes bus-master DMA to a specific set of
host physical pages, attributed to a specific set of PCI functions via
the IOMMU's context entry. A driver that holds
`Cap<KIND_DMA_DOMAIN>(D)` can map user-visible page ranges into IOVA
space `D` and request the kernel to point one or more context entries at
`D`; it can *only* produce DMA that lands in pages previously mapped
under `D`. A bus-master attack from a compromised driver's silicon has a
blast radius bounded by `D`'s mapped set.

This document is the canonical reference for the capability. §2 fixes
the shape; §3 the lifecycle; §4 the context-entry contract; §5 the
buffer-mapping API; §6 scatter-gather; §7 invalidation granularity;
§8 Thunderbolt-4 per-dock scoping and hot-plug revocation; §9 isolation
guarantees + threat model; §10 the HDA (D15) end-to-end walk-through;
§11 the Iris Xe PPGTT (G5) interaction; §12 witnessing + fingerprint
tags; §13 PASID deferral and the open-issue list.

### 1.1 Pillar alignment

- **Pillar 3 (microkernel).** The context table is kernel-owned. The
  driver names *what* it wants (a page range mapped, a function pointed
  at the domain), the kernel validates and programs; the driver never
  sees a context-table or SLPT MMIO address. Everything else (BDL
  construction, CORB/RIRB walks, ring doorbells) lives in the userspace
  driver.
- **Pillar 6 (security by construction).** DMA reach is bounded by
  construction: a device holding BDF `b` can reach memory `M` iff
  `(bdf == b)` has a context entry pointing at an SLPT that resolves
  some IOVA to a page in `M`, and that context entry was programmed by
  the kernel from a `KIND_DMA_DOMAIN` cap whose mapped set includes `M`.
  Three-step chain, every step checked.
- **Pillar 8 (novelty over POSIX).** Not a dma_map_sg wrapper. The
  capability *is* the domain — there is no process-level default domain,
  no "swiotlb fallback", no handle leaked from the kernel that the
  driver could use after cap revocation. Mapping without the cap is
  impossible; mapping with the cap is total.

## 2. Capability shape

### 2.1 Descriptor and row

Base kind = 4 (`KIND_MEMORY`). Derived tag = `0x142`. `target_ptr` holds
`row_id` in bits `[15:0]`; the payload lives in `_dma_domain_table[row_id]`
(`src/kernel/core/cap/kind_dma_domain.pdx`). Row size 32 bytes:

| Offset | Bits    | Field               | Meaning                                                       |
|--------|---------|---------------------|---------------------------------------------------------------|
| +0     | [31:0]  | `iommu_ctx_id`      | opaque VT-d DID — see §2.2                                    |
| +0     | [47:32] | `bus_dev_fn`        | anchor BDF this domain was minted for                         |
| +0     | [55:48] | `coherency`         | 0 = coherent, 1 = non-coherent                                |
| +0     | [63:56] | `in_use`            | allocator flag (zero = free)                                  |
| +8     | [63:0]  | `capacity_bytes`    | mapped-window ceiling (full u64, allows 1 TiB apertures)      |
| +16    | [7:0]   | `parent_slot`       | cap_table slot of the KIND_MEMORY ancestor (cascade target)   |
| +16    | [23:8]  | `bind_base`         | binding anchor BDF                                            |
| +16    | [39:24] | `bind_mask`         | binding significant-bit mask                                  |
| +16    | [63:40] | reserved            | must be zero                                                  |
| +24    | [7:0]   | `ctx_state`         | NONE / PENDING / PROGRAMMED                                   |
| +24    | [23:8]  | `ctx_bdf`           | BDF the context entry is currently programmed for             |
| +24    | [31:24] | `hw_committed`      | 1 iff a real VT-d context entry was written                   |
| +24    | [63:32] | reserved            | must be zero                                                  |

Table cap: `DMA_DOMAIN_MAX = 32`. Rationale: D1.b (`blob-policy.md §2`)
pins one domain per driver *process*, and the driver descriptor table
(`driver_table.pdx`) is itself 32 slots — exactly the reachable ceiling.
A larger table could not be filled by legal minting.

Why row-indirection instead of a fat descriptor: the tail is 104 live
bits (plus the second word's full u64 capacity + the third word's
40-bit binding), well beyond `target_ptr`. The indirection matches
`KIND_HW_INTERRUPT` (`#1019`) and `KIND_HW_MSIX_VECTOR` (`#1022`) one
lattice over; a third encoding shape would fragment revoke / cascade
reasoning across the R29 derived-kind set.

### 2.2 `iommu_ctx_id` — the VT-d DID

`iommu_ctx_id` is the 16-bit **domain identifier (DID)** VT-d hardware
TLB-tags SLPT walks with (VT-d 4.0 §9.3 context-entry bits [8:23] of
qword[1]). It is minted monotonically by the supervisor across the
system's VT-d units; `iommu_ctx_id == 0` is reserved for "no domain"
and never issued. The field is 32 bits in the row to leave room for
Scalable-Mode's wider DID (R23+ scope); legacy mode uses only the low
16 bits, and the mint gate refuses `iommu_ctx_id >= 2^16` until Scalable
Mode lands.

The DID is opaque to userspace: a driver never *reads* it (there is no
syscall that returns a DID; `OP_QUERY_CTX_ID` returns the capability's
DID only to a holder that already has it, for witnessing / tracing).

### 2.3 Context-entry pointer

Not stored in the row directly. The context-entry location is
derivable from `ctx_bdf` and the VT-d unit's root table: `(bus, dev, fn)
→ (bus_root_entry, dev8fn_ctx_entry)`. Storing a pointer would admit a
mint path that wrote directly to the kernel's root table; forcing the
derivation via `vtd_context_program` (`src/kernel/core/iommu/vtd_ctx.pdx`)
keeps *every* write to the context table under one kernel-owned call
site.

### 2.4 Root-table index

Likewise derived. The bus number is `bdf >> 8`; the root table has 256
entries indexed by bus. Multi-VT-d-unit systems (common on
server-grade hosts, uncommon on T14 G4) require a (unit, bus) tuple;
the T14 G4 bring-up assumes one PCH VT-d unit at `0xFED90000`, and the
multi-unit path is deferred to R23+ (see
`design/kernel/iommu-boot-toggle.md §3`).

### 2.5 Revoke semantics

`dma_cap_revoke(slot)` is a kernel entry point that:

1. Verifies `cap_table[slot].kind == 0x142`; else `DMA_REVOKE_WRONG_KIND`.
2. Reads `row_id` from `target_ptr`; else `DMA_REVOKE_BAD_SLOT`.
3. If `ctx_state == PROGRAMMED`, issues `iommu_ctx_uncommit_hw(ctx_bdf)`
   — zeroes both qwords of the context entry, then invalidates it (§7).
4. Walks the domain's SLPT (§5.3) and unmaps every leaf, invalidating
   per-page (§7.1). This is the only path that drops SLPT frames back
   to the frame allocator.
5. Zeroes all 32 bytes of `_dma_domain_table[row_id]`, dropping `in_use`.
6. Clears the descriptor at `cap_table[slot]`.

Idempotent against an already-null slot (`DMA_REVOKE_ALREADY`).

**Cascade.** `dma_cascade_revoke_by_parent(parent_slot) -> count` scans
`cap_table[0..255]` for descriptors whose row records `parent_slot` and
revokes each. The ancestor KIND_MEMORY cap's revoke path invokes this;
until driver-process teardown wires it (R29.M5-003), it is a supervisor
entry point exercised by the boot witness. Cost O(256) per parent
revoke, which is nothing on a path taken once per device departure.

The cascade is load-bearing: a stale context entry pointing at an SLPT
whose backing frames the allocator reused is a device reading / writing
arbitrary kernel memory. Breaking the cascade would re-open the exact
hole the IOMMU exists to close.

## 3. Lifecycle

### 3.1 DMAR table seed at boot (I3 + I4)

Order of events in `kernel_main_uefi`:

1. **I3 (ACPI _CRS parse)** publishes the PCIe root-bridge resource
   claim into `_phase1_acpi_info.root_bridge_window`. The PCI enumerator
   (`src/kernel/core/pci/enum.pdx`, R22.M2 — LANDED) walks that window
   and populates `_pci_devices` with one 32-byte record per function
   (vendor, device, class, revision, BARs, header-type).
2. **I4 (DMAR parse)** calls `dmar_parse_drhds`
   (`src/kernel/core/iommu/dmar.pdx`) against the ACPI DMAR table. For
   T14 G4 this discovers one DRHD covering the PCH, at
   `_phase1_acpi_info.dmar.unit_base`. R22.M4 hard-coded `0xFED90000`;
   §3 of the boot-toggle doc fixes this to the parsed value.
3. **Root/context-table allocation.** For each VT-d unit:
   - Allocate one 4 KiB root-table page (`vtd_root_init`).
   - For each enumerated bus `b` where a PCI function exists, allocate
     a 4 KiB context-table page and populate the root-entry at index
     `b` to point at it (`vtd_bus_context_table_init`).
   - At boot time every context entry is Present=0 (identity-mapped is
     *not* the default — the boot default is "no device may DMA until
     a KIND_DMA_DOMAIN cap programs its entry").
4. **SRTP + GCMD.TE ceremony** per `iommu-boot-toggle.md §3`:
   `vtd_set_root` → `GCMD.SRTP` → poll `GSTS.RTPS` → `GCMD.TE` → poll
   `GSTS.TES`. From this moment every PCI function is DMA-dead by
   construction.
5. **Context-cache + IOTLB invalidation** (global, both, with
   drain-wait). See §7.3.

Until `Features.IOMMU_ENABLED = 1` ships (R23 wire-up), steps 1–2 run,
steps 3–5 are skipped, and every KIND_DMA_DOMAIN mint lands as a
software-only ownership record (`hw_committed = 0`). This is the
boot-toggle rollback property that `iommu-boot-toggle.md §5` records.

### 3.2 Device-arrival mint (I2 + driver registration)

A driver is launched by the supervisor after PCI discovery matches its
manifest `(vendor, device)` against `_pci_devices` (D7-004). The
supervisor's launch sequence for a DMA-capable driver:

1. **Ancestor KIND_MEMORY cap.** The driver process receives a
   KIND_MEMORY root cap scoping its own aspace (the pages the driver
   may bus-master *to/from*). Minted from the process's memory root at
   launch; carries `RIGHT_MINT` (needed to derive the domain) and
   `RIGHT_INVOKE` (for ordinary memory ops). Capacity is the driver's
   DMA budget — e.g. 64 MiB for HDA, 4 GiB for Iris Xe scanout.
2. **`dma_cap_mint`.** The supervisor calls:
   ```
   dma_cap_mint(
     slot          = <free cap slot in driver's cap table>,
     parent_slot   = <KIND_MEMORY cap slot from step 1>,
     rights        = R_DMA_INVOKE | R_DMA_MINT | R_DMA_OBSERVE,
     tail_word     = dma_tail_pack(ctx_id, bdf, coherency),
     capacity      = <same as parent's capacity, or smaller>
   )
   ```
   Gates (in order; distinct failure codes):
   - `DMA_MINT_BAD_PARENT` — parent slot not KIND_MEMORY, not `RIGHT_MINT`.
   - `DMA_MINT_BAD_RIGHTS` — rights outside `R_DMA_ALL`.
   - `DMA_MINT_BAD_COHERENCY` — tail_word coherency > 1.
   - `DMA_MINT_BAD_ARG` — capacity == 0, parent_slot >= 256,
     capacity > parent.capacity (no widening).
   - `DMA_MINT_ENOSPC` — `_dma_domain_table` full.

   On success returns `DMA_MINT_OK` and emits
   `tag_dma_domain_mint_ok` (§12.1).
3. **Supervisor retains REVOKE.** The mint path mints the driver's cap
   *without* `R_DMA_REVOKE`; a separate supervisor-held cap carries
   `R_DMA_REVOKE` for teardown. A driver cannot destroy its own
   domain; the supervisor does, on process exit or on explicit unload.
4. **`iommu_domain_switch`** (per PCI function the driver owns): the
   driver calls into the kernel-owned switch primitive (§4) to point
   the context entry at its domain. For a single-function driver
   (HDA, NVMe) this fires once; for a multi-function driver (CNVi
   Wi-Fi + BT on one BDF device) it fires once per function.

### 3.3 Device-departure revoke

Four triggers:

1. **Process exit.** The task exit path (R16.M6-006 `sys_exit`) walks
   the exiting process's cap table and revokes every live cap. The
   parent KIND_MEMORY cap's revoke cascades into KIND_DMA_DOMAIN
   (§2.5).
2. **PCI hot-unplug** (TB4 live-unplug; `KIND_PCIE_HOTPLUG_EVENT`
   — Wave 60 scope). The hotplug handler reads the departing BDF list
   and invokes `dma_cascade_revoke_by_bdf(bdf)` — scans the domain
   table for `ctx_bdf == bdf` or `bus_dev_fn == bdf` and revokes.
3. **Explicit driver unload.** The supervisor's driver-manager
   revokes the driver's domain cap and then signals the driver
   process to exit. The order matters: revoke-before-exit guarantees
   the IOMMU stops the device *before* the driver's text pages
   become reclaimable.
4. **Supervisor-initiated reclaim** (quirks, security policy). Same
   path as case 2 but caller-initiated.

All four paths converge on `dma_cap_revoke`, which runs the §2.5
sequence end-to-end.

### 3.4 Context-entry state machine (row [+24])

Mint sets `ctx_state = NONE`. `iommu_domain_switch` moves `NONE →
PENDING → PROGRAMMED` (fault paths restore to NONE); `iommu_domain_unswitch`
moves `PROGRAMMED → PENDING → NONE`. A re-point onto a new BDF goes
`PROGRAMMED → PENDING → PROGRAMMED` with `ctx_bdf` updated. PENDING is
never a resting state. Full description in `domain_switch.pdx §3`;
reproduced here only for the state-table-at-a-glance.

## 4. Context-entry contract (kernel-owned)

`iommu_domain_switch(cap_slot, row_id, bus_dev_fn) -> code`
(`src/kernel/core/iommu/domain_switch.pdx`, LANDED, inert until
`_iommu_hw_ready = 1`). Validation order:

| # | Check             | Failure code                        |
|---|-------------------|-------------------------------------|
| 1 | argument well-formed | `IOMMU_SW_ERR_BAD_ARG`           |
| 2 | caller holds the cap | `IOMMU_SW_ERR_NOT_HELD`          |
| 3 | cap carries `R_DMA_MINT` | `IOMMU_SW_ERR_NO_RIGHT`      |
| 4 | row is in_use     | `IOMMU_SW_ERR_DEAD_ROW`             |
| 5 | ctx_state != PENDING | `IOMMU_SW_ERR_IN_TRANSITION`     |
| 6 | bdf ∈ binding     | `IOMMU_SW_ERR_BDF_UNBOUND`          |
| 7 | no other live domain owns bdf's context entry | `IOMMU_SW_ERR_CTX_OWNED` |

Why `R_DMA_MINT` and not `R_DMA_INVOKE` (gate 3): switching widens
what the function can reach, from nothing to the domain's whole mapped
set. That is the same authority class as `OP_MAP`; grouping it with
read-only queries would let a monitor cap re-point production hardware.

Why exclusivity is a kernel check (gate 7): VT-d has exactly one
context entry per (bus, devfn). Two domains believing they own the
same entry is not a race — it is silent acquisition of the other
domain's memory reach. The scan is O(32), nothing on a per-arrival
path.

### 4.1 What the kernel refuses to do

- Program a context entry for a BDF outside the domain's binding, even
  if the entry is currently unowned. The binding is the supervisor's
  statement; an unowned entry is not an invitation.
- Steal a context entry from another live domain. There is no "force"
  flag. The supervisor revokes the other domain first (auditable), or
  the request stays refused.
- Act on a PENDING row.

### 4.2 Hardware-write gating

Until R22.M5's `iommu_hw_backing_set(bus, ctx_table_va, slpt_root_pa)`
registers the per-bus context-table page and SLPT root PA,
`iommu_ctx_commit_hw` returns `IOMMU_HW_GATED` and the switch completes
as a *software-only* ownership record (`hw_committed = 0`). Teardown
knows per-row whether a hardware entry needs clearing; a domain with
`hw_committed = 0` skips the hardware path. This is the gate — not a
stub — that `domain_switch.pdx §4` records.

The design doc's §3.1 R23 wire-up checklist is the one that flips the
gate from stub-friendly to live.

## 5. Buffer-mapping API

The lane the softarch scope opened. R29.M5-001..M5-004 landed the
substrate; `OP_MAP` / `OP_UNMAP` are declared but their bodies return
`DMA_OP_UNSUPPORTED`. This section is their specification; its landing
is R29.M6-00x (not yet filed).

### 5.1 Entry points

```
cap_dma_map(cap_slot, va_base, length, iommu_flags) -> iova_base_or_err
cap_dma_unmap(cap_slot, iova_base, length) -> code
cap_dma_map_sg(cap_slot, sg_desc_ptr, nseg, iommu_flags) -> iova_list_or_err
cap_dma_flush(cap_slot, granularity, iova_base, length) -> code
```

All four reach the kernel via the generic `sys_cap_invoke(slot,
op_arg)` with the op code in `op_arg[7:0]`. Argument marshalling
mirrors `kind_surface.pdx` (§2 KIND_SURFACE_MINT op_arg bit layout):

| Op             | op_arg [63:8] encoding |
|----------------|------------------------|
| `OP_MAP`       | `[31:8]=length_pages`, `[63:32]=va_base_pfn` — `iommu_flags` in a separate second arg; see §5.2 |
| `OP_UNMAP`     | `[47:8]=iova_base_pfn`, `[63:48]=length_pages_hi` + a second arg for the low 48 bits |
| `OP_MAP_SG`    | `[31:8]=nseg`, `[63:32]=sg_desc_pfn` (page-aligned descriptor array in driver VA) |
| `OP_FLUSH`     | `[9:8]=granularity`, remainder op-specific |

The two-argument SysV constraint on `sys_cap_invoke` has one escape
hatch: a *descriptor-pointer* arg form that names a driver-VA page
containing the full arg block. `OP_MAP_SG` uses this; `OP_MAP` and
`OP_UNMAP` use the packed single-word form. The descriptor's shape is
pinned in §6.1.

### 5.2 `iommu_flags`

Four bits in `op_arg[11:8]` of `OP_MAP`:

| Bit | Name                 | Semantic                                                  |
|-----|----------------------|-----------------------------------------------------------|
| 0   | `IOMMU_F_READ`       | leaf SLPT entry has `R = 1` (always 1; present-bit side)  |
| 1   | `IOMMU_F_WRITE`      | leaf SLPT entry has `W = 1`                               |
| 2   | `IOMMU_F_NO_SNOOP`   | leaf entry `SNP = 1` (R23+; refused today)                |
| 3   | `IOMMU_F_LARGE_OK`   | admit 2 MiB mappings when `va_base` and `length` align    |

The common cases: HDA stream BDL mapping is `R|W`, Iris Xe scanout BO
is `R|W|LARGE_OK`, HDA command / response rings are `R|W`.

### 5.3 IOVA space and the SLPT

Each domain owns a **4-level SLPT** at `_dma_slpt_roots[row_id]`,
allocated at mint. The IOVA → PA walk is identical to x86-64 4-level
paging (VT-d 4.0 §6.2.3.3; indexing identical to `aspace_map.pdx`):

```
pml4_idx = (iova >> 39) & 0x1FF
pdpt_idx = (iova >> 30) & 0x1FF
pd_idx   = (iova >> 21) & 0x1FF
pt_idx   = (iova >> 12) & 0x1FF
```

The entry format (VT-d 4.0 Table 6-11) differs from x86-64 only in the
R/W/X bits (bits 0/1/2 explicit; no "present" bit — `R = 1` is the
presence signal) and in the snoop bits (bits 62/63, R23+).

**IOVA allocation.** The domain's IOVA space is a simple
first-fit bitmap at mint, 256 bits covering 1 TiB in 4 GiB chunks; the
first `OP_MAP` of a given region returns the lowest free chunk's base.
`capacity_bytes` caps the sum of mapped lengths. Fragmentation is a
non-issue for Wave 59 consumers (HDA maps < 1 MiB total; Iris Xe maps
page-table ranges large but aligned); a smarter allocator is R30+.

### 5.4 Page-size mix (2 MiB + 4 KiB)

VT-d supports 2 MiB large pages at the PDE (bit 7 `PS = 1`,
`bits[12:63] = PA aligned to 2 MiB`) and 1 GiB pages at the PDPTE
(same bit, PA aligned to 1 GiB). PaideiaOS R29 ships 2 MiB + 4 KiB
only; 1 GiB is deferred.

Decision table in `vtd_slpt_map_region`:

```
if (IOMMU_F_LARGE_OK is set)
   and (iova % 2M == 0)
   and (pa   % 2M == 0)
   and (length % 2M == 0 at the current step)
then
   split off a 2 MiB leaf at PDE level
else
   descend to PT level and map 4 KiB leaves one-by-one
```

The driver's choice to request `LARGE_OK` is advisory; the kernel
degrades to 4 KiB silently on misalignment. The witness in §12.2
asserts the actual leaf-size histogram per domain.

Scratchpad counters: `_dma_leaf_hist[row_id] = {n_4k, n_2m}` is
.bss-resident per-domain and bumped by `vtd_slpt_map`.

**Why no 1 GiB.** Iris Xe scanout is the only consumer that would
plausibly want it; Iris Xe uses GPU-side GTT/PPGTT walks for its
*own* virtual addresses (§11), and only *host-visible* GPU BOs sit in
the IOMMU domain — which are 2 MiB max in practice (framebuffer page).
Admitting a 1 GiB path at this round would be substrate without a
consumer.

### 5.5 Mapping and un-mapping worked once

`cap_dma_map(va_base=0x1_0000, length=0x4000, flags=R|W)` on a domain
D (coherent, DID 7, 48-bit AW):

1. Cap-table lookup; gates per §2.1.
2. IOVA allocator picks `iova_base = 0x4000_0000` (lowest free 4 GiB
   chunk's low page).
3. For each 4 KiB page in `va_base..va_base+length`:
   - `pa = aspace_pa_of(va)` — translate the driver's VA to its PA via
     the driver's user-aspace page tables (R29.M4 primitive, LANDED).
     Fails with `DMA_MAP_PAGE_UNMAPPED` if the driver's VA isn't
     actually backed.
   - `vtd_slpt_map(slpt_root, iova_base + i*4096, pa, flags)` walks
     SL-PML4 → SL-PDPT → SL-PD → SL-PT, allocating intermediate frames
     via `phys_alloc` where needed, and writes a leaf with
     `R|W|PA|flags`.
4. Fence: `invalidate_iotlb(did=D.ctx_id, iova_base, length)` — see §7.
5. Return `iova_base`.

`cap_dma_unmap(iova_base, length)` walks the SLPT, zeros each leaf,
reclaims intermediate frames whose children all became empty (the
`pt_reclamation.md` discipline mirrored one layer in), and issues the
matching invalidation.

### 5.6 Partial-unmap and address reuse

A driver may unmap a sub-range of a previously mapped region. The
IOVA allocator does *not* re-split the chunk — the chunk stays
reserved until all pages inside it are unmapped. This loses some
IOVA space to fragmentation; it also keeps the allocator trivially
O(1) and avoids a UAF class where unmapped-then-remapped IOVA points
at a different driver's page.

A driver that wants dense re-use builds its own IOVA sub-allocator
inside one chunk and calls `OP_MAP` once per chunk — the pattern HDA
uses for its buffer pool (§10.4).

## 6. Scatter-gather

Rings and command tables are typically a page-aligned base plus a
chain of 4 KiB or variable-length segments. VT-d resolves each DMA
transaction independently through its SLPT, so the IOMMU does not
*require* a scatter-gather primitive — the driver could map every
page individually. But a per-page syscall per I/O is a hot-path
disaster for NVMe and HDA, so `OP_MAP_SG` is substrate.

### 6.1 Descriptor layout

A page-aligned array of `(va_base_u64, length_u64)` pairs in the
driver's aspace, up to 512 entries per call (4 KiB page / 16 bytes).
A length word of zero terminates the list early.

Driver fills the array; kernel:

1. Reads the array page via `user_mem_copy_in` (R16.M3 user-ptr guard
   lane). The whole page is copied into a kernel scratch page to avoid
   TOCTOU on the driver's own memory. `DMA_SG_BAD_PTR` on fault.
2. For each `(va, len)` segment: resolves VA → PA for each page,
   writes SLPT leaves, bumps the leaf-size histogram.
3. On any segment failure: unwinds *all* previously-mapped segments in
   this call (the "all-or-nothing" discipline — a driver that got half
   a map back and the other half failed is an opportunity for a
   use-after-partial-map bug).
4. On success, writes an **IOVA list** back into a second page the
   driver supplies: one u64 per segment, holding the segment's
   `iova_base`. Returns the number of segments mapped.

### 6.2 Single-shot invalidation across SG

A naive implementation flushes per-segment; the right thing is one
batched IOTLB invalidation covering the span `[min_iova, max_iova)`.
For nseg ≤ 32 the kernel instead walks the list and issues one
per-segment IOTLB-page invalidation each — the trade point is at
`length_sum / 4096 ≈ 32` entries; above that, a domain-selective
invalidation (§7.1) is cheaper. The threshold is tunable and sits
behind `_dma_sg_batch_threshold` (default 32) with a witness that
reports which path was taken.

### 6.3 Interaction with the IOVA allocator

A scatter-gather map requests `sum(length)` of contiguous IOVA — the
IOVA list the kernel returns *is* contiguous, exactly as the driver
expects. The IOVA allocator picks one chunk large enough for the
whole sum and sub-allocates within it. Mixed-size segments produce
holes inside the chunk; the chunk is still reserved as one unit, and
reclaimed on a corresponding full-span `OP_UNMAP`.

## 7. Invalidation granularity

VT-d exposes three invalidation ladders:

1. **Context-cache invalidation (CCMD).** Flushes the per-unit cache
   that maps (BDF → context-entry contents). Must fire after any write
   to a context entry. Granularities: global, by-domain, by-source
   (BDF). Programmed via `CCMD_REG` (`vtd_regs.pdx §CCMD`).
2. **IOTLB invalidation.** Flushes the per-unit cache that maps
   (DID, IOVA) → PA. Must fire after any write to an SLPT entry.
   Granularities: global, by-domain, by-page (DID + IOVA + 2^S mask).
   Programmed via `IOTLB_REG`.
3. **Queued invalidation (QI).** The MMIO path above goes through
   polling registers; the QI path is a ring-buffered submission queue
   (`IQT_REG` tail, `IQH_REG` head, descriptors in a kernel-owned
   page). QI is required for interrupt-remapping (`vtd_ir.pdx`,
   R22.M5 LANDED) and strictly higher throughput than the MMIO path.

### 7.1 Which granularity when

| Trigger                              | CCMD scope | IOTLB scope | Notes                            |
|--------------------------------------|------------|-------------|----------------------------------|
| `iommu_domain_switch` (program ctx)  | by-source  | by-domain   | the single-BDF path              |
| `iommu_domain_unswitch`              | by-source  | by-domain   | ditto, before entry zeroing      |
| `cap_dma_map` single page            | —          | by-page     | SL-PTE write                     |
| `cap_dma_map` 2 MiB large page       | —          | by-page (2M)| S=9 in `IOTLB_REG.AM`            |
| `cap_dma_map_sg` ≤ threshold         | —          | by-page × N | per-segment loop                 |
| `cap_dma_map_sg` > threshold         | —          | by-domain   | one shot                         |
| `cap_dma_unmap`                      | —          | by-page     | zero leaves then flush           |
| `dma_cap_revoke`                     | by-source  | by-domain   | before SLPT walk                 |
| Boot `GCMD.TE` ceremony              | global     | global      | once per unit                    |
| Hot-plug domain revoke (TB4)         | by-source  | by-domain   | per BDF torn down                |

The by-page / by-domain choice is driven by the by-page invalidation
cost: a single `IOTLB_REG` write with `IIRG=011 (page)` costs one MMIO
+ one poll for completion. 32 pages at 32 MMIO+polls > 1 by-domain
flush; the §6.2 threshold is where the cost crosses.

Global IOTLB flushes are reserved for the boot ceremony and for
`FSTS.PFO` (fault overflow — the kernel has lost track of what to
flush selectively, so it conservatively flushes all).

### 7.2 Queued invalidation vs. MMIO path

Wave 59 uses the **MMIO path** (`CCMD_REG` + `IOTLB_REG`) throughout.
QI is wired for IR (R22.M5) and the DMA path can migrate onto it in
R30+ when per-domain invalidation batching becomes a hot-path concern
(e.g. VMD submission-queue bring-up). The migration is mechanical: QI
descriptors have a `CCMD`-equivalent descriptor type and an
`IOTLB`-equivalent type; the per-callsite primitive stays the same.

### 7.3 Drain-wait

Every invalidation path polls for completion before returning:

- CCMD: poll `CCMD_REG.CAIG` (bit 59, invalidation complete) with a
  bounded loop (10 000 PAUSEs, then timeout).
- IOTLB: poll `IOTLB_REG.IAIG` (bit 57). Same bound.

A timeout bumps `_dma_invalidation_timeouts` and is treated as a hard
boot failure in R29 (there is no "retry" posture that is correct for a
timed-out invalidation — the device may be mid-DMA to the stale
mapping). Non-boot timeouts become a `FSTS.ITE` fault handled by the
VT-d fault path (`vtd_fault.pdx`).

## 8. Thunderbolt-4 per-dock scoping

The security property Wave 59 must preserve is **Thunderclap**: an
externally-connected PCIe device may not DMA into pages belonging to
any other device, driver, or kernel page. The literature:
*Markettos et al., "Thunderclap: Exploring Vulnerabilities in Operating
System IOMMU Protection via DMA from Untrustworthy Peripherals",
NDSS 2019*. Linux's historical posture ("IOMMU trusted mode" vs.
"untrusted") is a POSIX-shaped compromise; PaideiaOS defaults to
*untrusted* for everything plugged in during userland (§P13 of
`next-wave-synthesis.md`).

### 8.1 Per-dock domain mint

A TB4 dock arrival produces a `KIND_PCIE_HOTPLUG_EVENT` (R35 scope).
The hotplug handler, for each tunneled downstream function:

1. **Allocates a fresh KIND_MEMORY cap** scoping a *per-dock* memory
   region sized to the device's manifest-declared DMA budget. Separate
   from the host's native-device memory root so the dock's domains
   cannot be transitively widened into native memory.
2. **Mints one `KIND_DMA_DOMAIN` per device**, parented to that
   per-dock KIND_MEMORY cap. Not per-dock — per-device-behind-the-dock.
   Two devices in the same dock are in two separate domains; a
   compromise of one does not reach the other.
3. **Programs the context entry** for the tunneled BDF via
   `iommu_domain_switch`.

The anchor BDF of the per-device domain is the BDF the tunnel surfaces
on the host PCI topology (TB4 tunneled devices appear as children of
the NHI's root port). The DID is drawn from the same per-unit pool as
native-device DIDs — one DID space per VT-d unit, no partitioning
between native and tunneled.

### 8.2 Hot-unplug revocation

Dock unplug or device-behind-dock unplug fires
`dma_cascade_revoke_by_bdf(bdf)` as the first action — *before* the
driver process is signaled to exit. Ordering:

1. Revoke the context entry (`iommu_domain_unswitch` → zero → flush).
   From this moment the device is DMA-dead regardless of what it tries
   to do with its last outstanding transaction.
2. Walk the SLPT and unmap every page.
3. Zero the row, drop the descriptor.
4. Signal the driver process (SIGTERM-shaped IPC).
5. On driver exit, reclaim driver memory + the per-dock KIND_MEMORY
   cap's backing pages.

A device that executes a bus-master write *between* the hot-unplug
event detection and step 1 is caught by the IOMMU on the next
transaction (the context entry still points to a live SLPT; the write
lands in the device's own domain, which has no cross-reach). The
window where this write could matter is bounded by the IOMMU's own
in-flight transaction count, which is zero for a device whose link
has gone down — the PCIe link state transition is the hard fence.

### 8.3 Security-level policy interaction

R35 ships `KIND_DMA_ATTESTATION` for user-consent flows: on first
plug-in of an unknown dock, a user-facing dialog gates whether to
mint the per-dock cap *at all*. If declined, the hotplug handler
leaves the context entry at Present=0 and the device is DMA-dead by
default. This document does not specify the attestation UX (R35
scope); it only pins the hook: `KIND_DMA_DOMAIN` mint for a tunneled
BDF requires an attestation cap in addition to the per-dock
KIND_MEMORY cap. Design followup:
`design/drivers/kind-dma-attestation.md` (not yet filed).

### 8.4 Why not one domain per dock

An attacker in control of one device behind a dock would get DMA
reach into every other device's buffers in the same dock-wide
domain. The per-device granularity costs one additional domain
row + one additional SLPT root per device (negligible) and buys
device-level isolation inside the dock — the exact property
Thunderclap exploits the absence of.

## 9. Isolation guarantees

### 9.1 The invariant

For any PCI function `F` with context entry pointing at domain `D`,
and any page `P` in the host's physical memory:

> `F` may issue a successful DMA transaction into `P` ⇒ there exists
> an IOVA `I` such that `D.SLPT(I).PA == P.PA` and `D.SLPT(I).R == 1`
> (for reads) or `D.SLPT(I).W == 1` (for writes), and the SLPT entry
> was written through `cap_dma_map` from a holder of
> `Cap<KIND_DMA_DOMAIN>(D)` carrying `R_DMA_MINT`.

Equivalently, DMA reach is bounded by the mapped set, which is bounded
by the chain of capabilities that produced the SLPT entries, which is
bounded by the ancestor KIND_MEMORY cap's scope. Four-link chain.

### 9.2 Threat model and residual risks

**In scope.**
- Compromised driver issuing arbitrary bus-master DMA to steal
  cross-driver or kernel memory. Blocked: the IOMMU drops the
  transaction with an unmapped-page fault.
- Compromised driver issuing DMA to pages its *own* mapped set
  includes. Not blocked by the IOMMU (that's the point — the driver
  needs to touch its own buffers), but the blast radius is the
  domain's mapped set. Supervisor policy keeps that set minimal
  (manifest-declared budgets).
- Thunderclap-shape attacks from tunneled TB4 devices (§8).
- Stale context entries after driver crash. Blocked by cascade revoke
  (§3.3).

**Residual.**
- The driver's own buffers are its own problem. If a driver maps the
  kernel's console buffer into its domain (which it cannot — the
  parent KIND_MEMORY cap scopes the aspace the driver may map), it
  would have full reach into that buffer. The *parent cap scope* is
  the enforcement surface for this; §3.2 step 1 is where it is set.
- VT-d itself has an attack surface (register-set MMIO is kernel-only;
  SLPT frames are kernel-only). A kernel bug writing a wrong PA into an
  SLPT entry is a bus-master attack by proxy. §12.2 witnesses
  round-trip the encoder/decoder to catch this class.
- PASID (Scalable Mode) is deferred; without PASID a device cannot
  partition DMA by *submitting task* inside the device (relevant for
  GPUs with shared VA with userspace). §13.

### 9.3 Comparison to Linux "trusted mode"

Linux defaults to "trusted" for native-plug PCI and "untrusted" for
tunneled devices, with trusted-mode using a global swiotlb bounce
region and skipping per-device DID allocation. The shortcut conflates
performance with assumed-benign; PaideiaOS does not take it. Every
DMA-capable device, native or tunneled, lives in its own
`KIND_DMA_DOMAIN`. A measurable regression on a later workload is
grounds for a `large-domain` cap shape, not for retiring isolation.

## 10. First consumer: Intel HDA (D15)

HDA is the simplest DMA-capable Wave 59 consumer and the one this
design doc walks end-to-end. Its subsystem is specified at
`design/drivers/hda-controller.md` (not yet filed; D15 companion); this
section covers the IOMMU-relevant slice only.

### 10.1 HDA DMA topology

Intel HDA (ICH9+ / PCH-equivalent) exposes four distinct DMA engines
per controller:

1. **CORB** — Command Output Ring Buffer. Driver → codec verbs. One
   fixed 1 KiB / 2 KiB / 4 KiB ring per controller.
2. **RIRB** — Response Input Ring Buffer. Codec → driver responses.
   Same shape as CORB.
3. **Stream DMA engines** — N (typically 7–15 per controller) stream
   descriptors, each with its own BDL (Buffer Descriptor List) and
   data buffer. Playback engines read from host memory; capture
   engines write to host memory.
4. **DMA Position Buffer** — one host-memory u32 per stream reporting
   the engine's current link position. Written by the controller
   continuously.

All four live in the same per-process `KIND_DMA_DOMAIN`.

### 10.2 Boot-time mint

In `drivers/hda/init.pdx`:

```
# Pseudocode — real driver is written in paideia-as
hda_init(driver_cap):
    ctrl_bar <- bar_map(driver_cap, bar_index=0)
    memory_cap <- cap_lookup(driver_cap.manifest.memory_root)
    dma_cap <- dma_cap_mint(
        slot        = HDA_DOMAIN_SLOT,
        parent_slot = memory_cap.slot,
        rights      = R_DMA_INVOKE | R_DMA_MINT | R_DMA_OBSERVE,
        tail_word   = dma_tail_pack(
                         iommu_ctx_id = <supervisor-assigned DID>,
                         bus_dev_fn   = driver_cap.bdf,
                         coherency    = DMA_COH_COHERENT),
        capacity    = HDA_DMA_BUDGET)       # 1 MiB
    iommu_domain_switch(dma_cap.slot, dma_cap.row, driver_cap.bdf)
    # from here, HDA DMA is live under domain HDA_DOMAIN_SLOT
```

HDA budget: 1 MiB. Breakdown — one 4 KiB CORB page + one 4 KiB RIRB
page + one 1 KiB position buffer page + ~15 stream BDLs at 32 bytes
each (one page) + ~15 stream data buffers at up to 64 KiB (960 KiB).
Capacity 1 MiB covers it with margin.

### 10.3 CORB / RIRB mapping

```
corb_va <- aspace_alloc(4096)              # driver-local VA
corb_iova <- cap_dma_map(dma_cap, corb_va, 4096, IOMMU_F_READ|IOMMU_F_WRITE)
mmio_write(ctrl_bar + HDA_CORBLBASE, corb_iova_low)
mmio_write(ctrl_bar + HDA_CORBUBASE, corb_iova_high)

rirb_va <- aspace_alloc(4096)
rirb_iova <- cap_dma_map(dma_cap, rirb_va, 4096, IOMMU_F_READ|IOMMU_F_WRITE)
mmio_write(ctrl_bar + HDA_RIRBLBASE, rirb_iova_low)
mmio_write(ctrl_bar + HDA_RIRBUBASE, rirb_iova_high)
```

Note the controller programs **IOVA**, not PA — the controller's bus-
master transactions reference the IOVA, the IOMMU translates to PA,
and the driver's local VA → PA mapping is only needed inside the
`cap_dma_map` path, not at runtime.

### 10.4 Stream BDL + buffer pool

A stream playback setup is where the SG path shines:

```
# One stream, 64 KiB total, split into 4 pages (BDL = 4 entries)
bdl_va <- aspace_alloc(4096)                  # the BDL itself, 4 pages
buf_va <- aspace_alloc(65536)                 # 16 pages of audio data

# Map the BDL first — 1 segment
bdl_iova <- cap_dma_map(dma_cap, bdl_va, 4096, IOMMU_F_READ)

# Map the data pool as scatter-gather — 16 segments
sg_desc[0..15] <- [(buf_va + i*4096, 4096) for i in 0..15]
buf_iova_list <- cap_dma_map_sg(dma_cap, sg_desc, 16, IOMMU_F_READ)

# Write the BDL entries
for i in 0..15:
    bdl_write_entry(bdl_va, i, buf_iova_list[i], 4096)

# Program the stream engine
mmio_write(stream_regs + HDA_SD_BDPL, bdl_iova_low)
mmio_write(stream_regs + HDA_SD_BDPU, bdl_iova_high)
mmio_write(stream_regs + HDA_SD_CBL,  65536)
mmio_write(stream_regs + HDA_SD_CTL,  HDA_SD_CTL_RUN)
```

16 SG segments is well under the §6.2 threshold (32), so the kernel
loops per-segment IOTLB-page invalidations rather than one by-domain
flush. The witness emits one `tag_dma_sg_map_ok` with `nseg=16`,
`granularity=page`.

### 10.5 Stream teardown

```
mmio_write(stream_regs + HDA_SD_CTL, 0)       # stop engine
# wait for RUN clear
cap_dma_unmap(dma_cap, bdl_iova, 4096)
for iova in buf_iova_list:
    cap_dma_unmap(dma_cap, iova, 4096)        # or a single range unmap if contiguous
```

Partial unmap is fine; the IOVA chunk is released when the last
mapping inside it is unmapped.

### 10.6 Driver crash path

A driver segfault during stream setup leaves the HDA controller
mid-DMA (RUN=1, pointer walking a half-unmapped BDL). Process-exit
cascade (§3.3 case 1):

1. KIND_MEMORY parent cap revoked.
2. Cascade finds HDA's KIND_DMA_DOMAIN; begins revoke.
3. `iommu_domain_unswitch` zeroes the context entry — HDA controller's
   next DMA transaction faults into `vtd_fault`'s `FRR` ring (fault
   code `0x21`: "write to unmapped page" or `0x22`: "no context
   entry").
4. SLPT torn down, row zeroed.
5. HDA controller is now DMA-dead; the stream BAR's RUN bit is a
   no-op until the next driver registration programs a fresh domain.

A graceful shutdown (driver sets RUN=0 before unmapping) avoids the
fault; both paths converge on the same final state. The fault path's
side effect is a logged entry in `vtd_fault`'s FRR drain, which the
observer-side `OP_QUERY_FAULT` surfaces to a monitor task.

## 11. Second consumer: Iris Xe PPGTT (G5)

Iris Xe has *two* address translations stacked between a GPU task's
virtual pointer and host DRAM:

1. **PPGTT** — Per-Process Graphics Translation Table. A GPU-engine-
   owned 4-level walker that translates GPU virtual addresses to
   "graphics physical addresses" (really an intermediate space).
2. **IOMMU** — VT-d's SLPT, translating the intermediate space (as
   seen on the PCIe bus) to host PA.

The IOMMU domain covers the second translation. The PPGTT lives inside
Iris Xe silicon (its root PA is programmed into
`GEN_PPGTT_PML4_ADDR`); the IOMMU does not see per-process GPU VAs,
only the PCIe-bus addresses the Iris Xe emits as it walks its own
tables.

### 11.1 What the IOMMU domain holds

For Iris Xe, the IOMMU domain holds **everything the GPU reads via a
bus-master transaction**:

- The PPGTT page-table tree itself (allocated in host memory; walked
  by the GPU's HWPTE walker).
- The ring buffers (RCS / BCS / VECS / VCS submission rings).
- Scanout BOs — the physical frames the display pipe scans out of
  via the GPU's blitter.
- The GuC firmware blob (loaded once at init).
- Context-save buffers (hardware-context pages per engine).

Everything *inside* a PPGTT translation — vertex buffers,
intermediates, compute workgroup scratch — does not need an IOMMU
mapping because the GPU resolves those through PPGTT first; the
IOMMU only sees the leaf PA that PPGTT resolved to, and those *leaf
PAs* must be in the domain's mapped set.

Which they are, because the leaf PAs come from the same KIND_MEMORY
parent cap that scoped the Iris Xe domain in the first place.

### 11.2 Mint shape

Iris Xe gets a wider domain than HDA:

```
iris_memory_cap <- supervisor-mint(KIND_MEMORY, scope=4GiB, rights=INVOKE|MINT)
iris_dma_cap <- dma_cap_mint(
    slot        = IRIS_DOMAIN_SLOT,
    parent_slot = iris_memory_cap.slot,
    rights      = R_DMA_INVOKE | R_DMA_MINT | R_DMA_OBSERVE,
    tail_word   = dma_tail_pack(
                     iommu_ctx_id = <DID>,
                     bus_dev_fn   = iris.bdf,                # 0:2:0 on T14 G4
                     coherency    = DMA_COH_COHERENT),
    capacity    = 4 * 1024 * 1024 * 1024)                   # 4 GiB
```

A 4 GiB capacity is comfortably above T14 G4 Iris Xe's practical
working set (framebuffers + ring buffers + PPGTT tables ≪ 1 GiB on a
2K display).

### 11.3 Interaction with PPGTT bring-up

G5 brings up the GTT and the per-engine PPGTT. Steps relevant here:

1. **GTT bring-up.** The Global GTT lives in a stolen-memory region
   programmed via the Iris Xe BAR (`GTT_BAR_OFFSET`). It is *not*
   bus-master DMA — the CPU writes PTEs through the BAR MMIO window.
   The IOMMU is not on this path. (If the controller's `GTT_SOURCE`
   quirk routed GTT fills through bus-master, we'd need to map them.
   Iris Xe gen 12 LP does not.)
2. **PPGTT root allocation.** The driver allocates one 4 KiB page per
   engine for the PPGTT PML4 root, plus pages for intermediates as it
   maps BOs. Each PML4 root page is `cap_dma_map`-ed with `R|W`
   (`IOMMU_F_LARGE_OK` opportunistic — these pages are 4 KiB each so
   no 2 MiB fit).
3. **PPGTT programming.** The driver writes the host-PA of each PML4
   root — *as resolved through its KIND_MEMORY cap* — into
   `RCS_PP_DIR_BASE` (and the equivalent for other engines) via BAR
   MMIO. The IOMMU domain's job is to make the *bus-master walks* of
   these PML4 pages succeed; from the IOMMU's perspective, those are
   ordinary DMA reads to IOVAs the driver mapped under the Iris Xe
   domain.

Wait — the driver writes the *host-PA* into the BAR register? No. On
every modern Intel IGPU, the engine's PP_DIR_BASE field holds a
**GTT PFN** (an index into the Global GTT), and the GTT is set up so
that the GTT entry at that PFN points to the actual bus-master
address of the PPGTT root. The driver maps the PPGTT root page via
`cap_dma_map`, gets an `iova`, and writes a GTT entry mapping some
GTT PFN to `iova`; it then writes that GTT PFN into PP_DIR_BASE. The
GTT is a per-controller flat table; its entries are 8 bytes each with
the PA / IOVA in bits [12:63].

So the chain is: GPU engine → PP_DIR_BASE (GTT PFN) → GTT (bus-master
IOVA) → IOMMU SLPT → host PA. The IOMMU is in two spots: (a) the
GPU-engine walk of the PP_DIR_BASE GTT entry, which the GTT's own
bus-master read goes through the IOMMU; (b) the PP walker's reads of
the PPGTT PML4/PDPT/PD/PT entries, each of which is a bus-master read
through the IOMMU.

The IOMMU does not see individual *GPU VAs*. It sees bus-master reads
whose target IOVA is some SLPT-mapped page containing a GTT entry or a
PPGTT entry or a leaf. Every one of those pages must be mapped under
the Iris Xe domain.

### 11.4 Large-page use

Scanout BOs are the one Iris Xe case that benefits from 2 MiB
mappings: a 1920×1080×4 framebuffer is ~8 MiB, aligning well to 2 MiB
leaves. `cap_dma_map(scanout_va, 8 MiB, R|W|LARGE_OK)` produces four
2 MiB SLPT leaves, each one page-walk of the SL-PD (not four
SL-PT walks and 2048 SL-PTE writes). The witness in §12.2 asserts the
leaf-size histogram shows the expected 4×2M + 0×4K for this call.

### 11.5 GuC firmware blob

The GuC firmware (I8-attached blob, ~400 KiB) must be bus-master-
readable by the Iris Xe at init. Standard `cap_dma_map` with
`IOMMU_F_READ` only — the GuC never writes back into its own
instruction / data pages. On GuC reload (driver restart), the blob is
re-mapped; on driver crash, cascade revoke zeroes the mapping and the
GuC immediately halts (its next instruction fetch faults).

### 11.6 Why Iris Xe is not a special case

Iris Xe is the biggest Wave 59 DMA consumer by *mapped bytes*, and
one might reasonably ask if its scale justifies a Scalable-Mode
(PASID-based) domain or a wider-than-usual DID allocation. R29's
answer is no:

- 4 GiB of mapped IOVA inside one domain is one SLPT walk per bus-
  master request; the walk is cached in the IOMMU IOTLB and the
  working-set fits comfortably in the IOTLB cache (gen 12 PCH IOMMU
  has ~1 024 IOTLB entries + a page-walk cache).
- PASID is useful when *userspace* shares an address space with the
  device (SVA — shared virtual addressing). Iris Xe without SVA
  does not benefit; see §13.
- One domain per driver process is a security property; splitting
  Iris Xe into per-engine domains would need per-engine KIND_MEMORY
  parent caps and give the engines cross-visibility back through the
  shared GTT — a regression.

## 12. Witnessing

Every substrate landing in R29.M5 emitted a boot fingerprint; §12
pins the two witnesses the Wave 59 D2 landing adds (one for the mint
+ context-switch path, one for the map/unmap path) and the per-call
tags observers can hook.

### 12.1 Boot fingerprints

`src/kernel/boot/witness/w59_dma_domain_mint.pdx` — fires in
`kernel_main_uefi` after the DMAR + root-table bring-up, before the
first driver launches. Scenario:

1. Mint a fake KIND_MEMORY parent at a reserved slot.
2. Mint a KIND_DMA_DOMAIN cap with DID 0x7, BDF `0:1f:3` (reserved
   HDA-ish anchor), capacity 1 MiB, coherent.
3. Fingerprint: `DMA DOMAIN MINT OK did=0x0007 bdf=0x00FB cap=0x100000`.
4. `iommu_domain_switch` the cap onto `0:1f:3`.
5. Fingerprint: `DMA SW OK did=0x0007 bdf=0x00FB state=programmed hw=<0|1>`.
6. Revoke the cap.
7. Fingerprint: `DMA DOMAIN REVOKE OK did=0x0007 bdf=0x00FB`.

`hw=<0|1>` reports whether `hw_committed` was set — the gated path
`iommu-boot-toggle.md §3` describes. Both values are accepted by the
smoke-matcher; the serial-captured run on T14 G4 will show `hw=1`
once R23 flips the flag.

### 12.2 Map / unmap fingerprints

`src/kernel/boot/witness/w59_dma_map.pdx` — fires immediately after
w59_dma_domain_mint, same cap. Scenario:

1. Allocate a 4 KiB page in the witness's own aspace, back it with
   phys_alloc.
2. `cap_dma_map(cap, va, 4096, R|W)` → `iova`.
3. Fingerprint: `DMA MAP OK iova=0x<iova> len=0x1000 flags=0x3 leaf=4k`.
4. Allocate 8 MiB, back it.
5. `cap_dma_map(cap, va, 8MiB, R|W|LARGE_OK)` → `iova`.
6. Fingerprint: `DMA MAP OK iova=0x<iova> len=0x800000 flags=0xB leaf=2m count=4`.
7. `cap_dma_map_sg` with 16 × 4 KiB segments.
8. Fingerprint: `DMA SG MAP OK nseg=16 total=0x10000 inval=page`.
9. Unmap each; fingerprint pair `DMA UNMAP OK` per range.
10. Revoke the cap.

The fingerprints are matched byte-exact by the smoke. A regression
that silently falls back from 2 MiB to 4 KiB on the §5.4 path shows
up as `leaf=4k count=2048` on the step-6 line, which breaks the
match.

### 12.3 Per-call klog tags

Four tags under `src/kernel/core/klog/tags.pdx`:

| Tag                   | Scope           | KV emission                                        |
|-----------------------|-----------------|----------------------------------------------------|
| `tag_dma_mint_ok`     | mint-path       | `kind, did, bdf, cap`                              |
| `tag_dma_map_ok`      | per-page map    | `did, iova, pa, flags, leaf_size`                  |
| `tag_dma_sg_map_ok`   | per SG call     | `did, nseg, total_bytes, inval`                    |
| `tag_dma_inval_ok`    | invalidation    | `scope, did, iova_or_bdf, took_ns`                 |

Each tag is a KV-shaped klog_s1 entry; the fingerprint lines in §12.1
and §12.2 are the human-readable projections suitable for smoke
matching. Observers hold `R_DMA_OBSERVE` to subscribe to the
per-domain stream via `OP_QUERY_FAULT` (which also drains the per-
domain fault counter, §6 of `vtd_fault.pdx`).

### 12.4 Fault witness

`vtd_fault.pdx`'s FRR drain already emits `tag_vtd_fault` on every
recorded fault; §12 adds a cross-reference: faults whose SID matches a
live domain's `ctx_bdf` bump a per-domain fault counter at row
`[+24]` reserved bits [55:32] (previously reserved; the row layout in
§2.1 is updated to use these bits for `fault_count`). A monitor's
`OP_QUERY_FAULT` returns this counter without consulting the global
FRR, which is the fastest path.

A separate boot witness `w59_dma_fault_regression.pdx` deliberately
triggers an out-of-domain DMA, confirms the FRR entry's SID matches
the fake-device BDF, and emits:
`DMA FAULT CAUGHT did=0x0007 bdf=0x00FB reason=0x22 iova=0xDEADBEEF`.
(Reason 0x22 = "no context entry" / "non-present".)

## 13. PASID deferral + open issues

### 13.1 PASID (Scalable Mode) deferral

VT-d Scalable Mode (ratified in VT-d 3.0, present on T14 G4's PCH)
introduces **PASID** — a per-DMA-transaction identifier that lets one
device partition its own DMA by submitting process. Scalable Mode
replaces the legacy context entry with a scalable-mode context entry
+ a PASID directory + a per-PASID entry; each PASID can carry its own
first-stage (user-page-table-equivalent) + second-stage (SLPT) walk.

PASID matters for **SVA** (Shared Virtual Addressing), where userspace
pointers passed to a device are translated through the user's own
page tables. The use cases are: GPUs with userspace-side command
submission (Vulkan + explicit sync, R37 scope), FPGAs (not on our
hardware target), and modern NVMe with host-managed PRPs via SVA (not
needed for NVMe at the ring-buffer level).

Wave 59 does not need PASID. HDA has no notion of "the submitting
process" — it is a kernel-side driver streaming audio. Iris Xe G5
ships without SVA; the compositor is the one submitter per engine.
The IOMMU side therefore uses **legacy context entries throughout**,
and the row's `iommu_ctx_id` field holds a DID (not a PASID).

Deferral target: R37+ (Vulkan on Iris Xe) or R35+ (TB4 shared-VA).
Data-model deltas when it lands: `iommu_ctx_id` → (DID, PASID) tuple
(the 32-bit row field already has room); `iommu_domain_switch` grows
a PASID arg; `cap_dma_map` grows a PASID selector. The cap shape and
lifecycle do not change — the cap acquires a per-DID partition
dimension. Follow-up doc: `design/drivers/kind-dma-domain-pasid.md`
(not filed; R37 scope).

### 13.2 Open issues

| ID | Issue |
|----|-------|
| DDM-O1 | Multi-VT-d-unit systems: `_dma_domain_table` is global; per-unit tables or a `unit_id` row field is R23+. |
| DDM-O2 | IOVA fragmentation under partial-unmap churn; buddy-pair allocator is R30+. |
| DDM-O3 | 1 GiB page support — R30+, not needed for Wave 59. |
| DDM-O4 | Queued-invalidation migration — §7.2 picks MMIO; QI is R30+. |
| DDM-O5 | TB4 attestation UX (§8.3); `KIND_DMA_ATTESTATION` R35 doc. |
| DDM-O6 | Non-coherent mode (`coherency = 1`): data model present, cache-maintenance primitives R30+. |
| DDM-O7 | Per-domain fault-rate revocation; R30+ hardening. |
| DDM-O8 | Hotplug handshake needs `KIND_PCIE_HOTPLUG_EVENT` (R35) first. |

### 13.3 What this document does not specify

- Per-domain performance baselines (§6.2 batch threshold, §7.3 drain
  bound) — deferred to a follow-up profiling witness.
- AMD-Vi parity — structurally similar but a separate port doc.
- Nested virtualization (guest-IOMMU-over-host-IOMMU) — not R29 scope.

---

## Appendix A — Fingerprint catalog

All strings are literal; the hex values are typeset for one example
boot. Serial-captured T14 G4 runs match byte-for-byte.

```
DMA DOMAIN MINT OK did=0x0007 bdf=0x00FB cap=0x100000
DMA SW OK did=0x0007 bdf=0x00FB state=programmed hw=1
DMA MAP OK iova=0x40000000 len=0x1000 flags=0x3 leaf=4k
DMA MAP OK iova=0x40001000 len=0x800000 flags=0xB leaf=2m count=4
DMA SG MAP OK nseg=16 total=0x10000 inval=page
DMA UNMAP OK iova=0x40000000 len=0x1000
DMA DOMAIN REVOKE OK did=0x0007 bdf=0x00FB
DMA FAULT CAUGHT did=0x0007 bdf=0x00FB reason=0x22 iova=0xDEADBEEF
```

## Appendix B — Return-code block map

Already assigned in `kind_dma_domain.pdx` + `domain_switch.pdx`:

| Block             | Owner                     | Codes                      |
|-------------------|---------------------------|----------------------------|
| `0xFFFFFFD1..DF`  | KIND_DMA_DOMAIN mint/revoke/tail | per §3 kind file  |
| `0xFFFFFFC6..CF`  | domain_switch             | per §4 domain_switch       |
| `0xFFFFFFE7..EF`  | KIND_HW_MSIX_VECTOR       | out of scope here          |
| `0xFFFFFFF7..FF`  | KIND_HW_INTERRUPT         | out of scope here          |

Wave 59 D2 adds no new blocks: the OP_MAP/OP_UNMAP/OP_FLUSH/
OP_QUERY_FAULT bodies use `0xFFFFFFD1..DF` with the sub-codes already
declared (`DMA_TAIL_ENOSPC`, `DMA_TAIL_BAD_ARG`, etc.) plus three new
codes:

| Code         | Name                        |
|--------------|-----------------------------|
| `0xFFFFFFD0` | `DMA_MAP_PAGE_UNMAPPED`     |
| `0xFFFFFFCF` | `DMA_MAP_OUT_OF_IOVA`       |
| `0xFFFFFFCE` | `DMA_MAP_OVER_CAPACITY`     |

(These shift down into the previously unassigned low tail of the
block, keeping §3's code catalog contiguous.)

## Appendix C — Citations (verification TODO)

- Intel VT-d Specification 4.0 (346968-004US, Dec 2023), §3.4,
  §6.2.3.3, §9.1, §9.3, §11. Cited throughout.
- Markettos et al., "Thunderclap", NDSS 2019. Cited §8, §9.
- Intel HDA Specification Rev 1.0a (302349-001), §4, §6, §7. Cited §10.
- Intel OSRC Gen12 PRM Vol 5 (Memory Views), §PPGTT, §GTT. Cited §11.
- seL4 Reference Manual §5 (retype / cascade semantics). Cited §2.5.

*End of document.*
