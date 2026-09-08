# R111.M2-005 — PCIe ECAM real-HW enumeration

**Issue:** paideia-os #2357 (part of R111 umbrella #2353 — T14 G4 bootable USB image).
**Wave:** R111.M2 real-HW substrate.
**Status:** implemented 2026-09-07.

## 1. Problem

The R22 PCIe walker in `src/kernel/core/pci/enum.pdx` was written against QEMU
q35's synthetic PCIe topology, which publishes a single MCFG segment covering
buses `0..0xFF` at `0xE0000000`. The walker seeded bus 0 unconditionally, then
descended Type-1 bridges via `secondary_bus` reads. That works on QEMU q35, on
i440fx, and on almost every consumer x86 board of the last decade — but it is
not sufficient for T14 G4 (Raptor Lake) real hardware:

- Insyde firmware on the T14 G4 publishes a single segment covering
  buses `0..0xFF` — the same shape as QEMU. **This case works today.**
- Multi-domain server / workstation layouts (2-socket EPYC, Ampere Altra
  Max) publish **two or more MCFG segments** each covering a partial
  bus range. The R22 walker only touched segment 0.
- Firmware that hard-partitions the bus space (some AMD I/O-die
  designs) publishes segments with `start_bus != 0`. The R22 walker
  seeded bus 0 unconditionally.
- Corrupted or malicious bridge headers with out-of-range
  `secondary_bus` values would send the R22 walker into ECAM addresses
  outside the segment's mapping, faulting or returning 0xFFFFFFFF.

R111.M2-005 makes the walker real-HW-capable while preserving byte-for-byte
compatibility on QEMU q35 and the existing R22 golden fixtures.

## 2. Design

Three new public entry points; the R22 `pci_enumerate_all(seg)` is preserved
unchanged for backward compatibility.

### 2.1 `mcfg_bus_range_for_segment(seg) -> u64`

Sibling of `mcfg_ecam_base_for_segment` and `mcfg_ecam_va_for_segment`
in `src/kernel/acpi/mcfg.pdx`. Returns the segment's `[start_bus, end_bus]`
range packed into a `u64`, with bit 32 set as a "hit" marker so a valid
`start=0,end=0` record does not collide with the plain-0 miss sentinel.

Wire form:
```
hit:  (1 << 32) | (start_bus << 8) | end_bus
miss:  0
```

Callers extract via:
```
start_bus = (rax >> 8) & 0xFF
end_bus   =  rax       & 0xFF
hit       = (rax >> 32) & 1
```

### 2.2 `pci_enumerate_segment_range(seg, start_bus, end_bus) -> u64`

Append-mode ECAM walker in `src/kernel/core/pci/enum.pdx`. Same
bus-drain / bridge-descent shape as `pci_enumerate_all`, with three
targeted differences:

1. Queue seeded with `start_bus` (arg1) rather than bus 0.
2. Each bridge's `secondary_bus` is bounds-checked against
   `[start_bus, end_bus]` before enqueue — malformed bridges cannot
   pull the walker outside the segment's ECAM window.
3. Does not zero `_pci_device_count` or `_pci_bus_visited`, and does
   not emit the `PCI ENUM SKIP no MCFG` or `PCI ENUM DONE` fingerprints —
   those are the multi-segment orchestrator's responsibility.

Per present function, two fingerprints emit:
- Legacy `PCI DEV bus=B dev=D vendor=V device=X` (unchanged, preserves
  the R22 golden fixture at `tests/r22/expected-pci-tree.txt`).
- New R111.M2-005 `PCIe BDF discovered [legacy: PCIE BDF]` carrying the
  fields the R22 emit dropped: seg, fn, class. Format:
```
[pci ] PCIe BDF discovered [legacy: PCIE BDF] --
  bdf=<seg16bus8dev8fn8> vid=<hex16> did=<hex16> class=<hex24>
```
  The `bdf` value packs `(seg<<32)|(bus<<16)|(dev<<8)|fn` so a single
  hex-formatted `u64` reads positionally as `<seg>:<bus>:<dev>.<fn>`,
  matching the M2-005 witness spec `PCIE BDF <seg>:<b>:<d>.<f>`.

### 2.3 `pci_enumerate_all_segments() -> u64`

Multi-segment orchestrator. Wired into `kernel_main.pdx` in place of the
old `pci_enumerate_all(0)` call. Sequence:

1. MCFG-absence guard identical to `pci_enumerate_all`.
2. One-shot zero of `_pci_device_count` and `_pci_bus_visited` (32 B).
3. For each segment in `_mcfg_segments[0.._mcfg_count)`: load
   `(seg, start_bus, end_bus)` from the segment record and call
   `pci_enumerate_segment_range`.
4. Emit one closing `PCI ENUM DONE devices=<N>` after the loop.
5. Return `_pci_device_count`.

On the 99% single-segment layout (QEMU q35, T14 G4 Insyde) the outer
loop runs exactly once and the observable behavior matches R22 at the
boot-transcript layer, except for the additional `PCIe BDF` line per
function.

## 3. Shared visited bitmap across segments

The R22 walker's `_pci_bus_visited` is a 256-bit bitmap (one bit per
bus number 0..255). Under R111.M2-005 the orchestrator zeros this bitmap
ONCE before iterating segments and then leaves it alone. Two segments
sharing a bus number would collide — but PCI Firmware Spec 3.3 §4.1.2
requires disjoint bus ranges across segments in the same MCFG table.
On well-formed firmware the shared bitmap is correct without per-segment
reset; the design would need a bitmap-per-segment refactor only if a
future spec permits overlapping segments.

## 4. Bridge bounds-check rationale

`pci_enumerate_segment_range` bounds-checks each bridge's `secondary_bus`
against `[start_bus, end_bus]` before enqueue. On well-formed hardware
this is defensive — a bridge in segment N only publishes secondaries in
segment N's range. But without the check, a corrupted or malicious
bridge header with `secondary_bus > end_bus` would cause the walker to
touch ECAM addresses outside the mapped window, faulting or returning
garbage. On Insyde-firmware boots we take this belt-and-braces posture
because the firmware itself is out of the trust boundary.

## 5. What R111.M2-005 explicitly does NOT do

- **BAR sizing against Insyde pre-programmed BARs.** The issue body
  mentions this as a scope item, but the R22 enumerator does not touch
  BARs — that is driver-attach work in R23. R111.M2-005 preserves that
  posture. BAR sizing under Insyde's "already sized" state is a
  driver-attach concern for the R23 driver plane and the R51/R111.M3-011
  NVMe / xHCI attach steps that already program BARs on real HW.
- **Extended-cap walking of DMAR / SR-IOV / ACS chains.** The
  `pcie_walk_ext_caps` primitive in `src/kernel/core/pci/ext_cap.pdx`
  already handles this, and the R111.M2-007 MSI-X / VT-d IR wave will
  wire it into the DMAR-consuming path. No change needed here.

## 6. Files touched

- `src/kernel/acpi/mcfg.pdx` — new `mcfg_bus_range_for_segment` helper.
- `src/kernel/core/pci/enum.pdx` — two new functions
  (`pci_enumerate_segment_range`, `pci_enumerate_all_segments`).
- `src/kernel/core/klog/keys.pdx` — new `tag_pcie_bdf`, `k_vid`,
  `k_did` (k_bdf reused from R22-M4 IOMMU block).
- `src/kernel/boot/kernel_main.pdx` — replace
  `pci_enumerate_all(0)` call with `pci_enumerate_all_segments()`.
- `design/kernel/pcie/enumeration-real-hw.md` — this document.

## 7. Fingerprint impact

- `PCI ENUM SKIP no MCFG` — unchanged. Fires under QEMU `-kernel` PVH
  boot when the RSDP is unavailable. Golden fixture at
  `tests/r22/expected-pci-tree.txt` (single-line match) preserved
  byte-for-byte.
- `PCI DEV bus=B dev=D vendor=V device=X` — unchanged shape, still
  emitted per present function. Preserves downstream log-parsing tool
  compat.
- `PCIe BDF discovered [legacy: PCIE BDF] -- bdf=<u64> vid=<u16>
  did=<u16> class=<u24>` — NEW. Emitted per present function alongside
  the legacy `PCI DEV` line.
- `PCI enumeration complete [legacy: PCI ENUM DONE] devices=<N>` —
  unchanged. Fires once after every segment is walked; the total
  count `N` now aggregates across all segments.

No existing golden fixture asserts the per-BDF line, so adding the
new `PCIe BDF` line is fixture-neutral. The
`tools/verify-fingerprint-coverage.sh` script will discover the new
`tag_pcie_bdf` emit site inside `pci_enumerate_segment_range` and the
matching orchestrator call inside `kernel_main.pdx`.
