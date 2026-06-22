# PaideiaOS — Driver-Registration Capability + Manifest (R7 / D7-004)

**Status:** Draft v0.1 (R7 groundwork)
**Date:** 2026-06-21
**Issue:** D7-004 (#262)
**Depends on:** R2.5 (cap subsystem reactivated), D7-001 (framework architecture)
**Scope:** The capability that authorises a userspace task to act as a driver,
and the manifest record that describes what device it drives and what it needs.

## Pillar alignment

- **Pillar 3 (microkernel).** A driver capability is the *only* authority a
  driver task starts with. It does not grant device access directly; it grants
  the *right to request* MMIO mappings (D7-005), an IRQ endpoint, and DMA
  buffers, each scoped to the manifest's declared device.
- **Pillar 6 (security by construction).** The supervisor mints the driver cap
  after matching the manifest's `(vendor, device)` against the enumerated device
  tree (D7-002). A driver can never request resources for a device it was not
  registered for, because every downstream request is checked against the
  manifest carried in the descriptor.

## 1. The KIND_DRIVER capability — and a spec conflict

`.plans` §3 D7-004 specifies "KIND_DRIVER (new cap kind, value 5)". **Value 5 is
already `KIND_IPC_ENDPOINT`** in the binding closed 16-kind enum
(`design/capabilities/linearity-and-tags.md` §3.1, mirrored in
`src/kernel/core/cap/kind.pdx`). The 4-bit base enum is full (slots 0..15, with
14/15 reserved). Reassigning slot 5 would break every IPC-endpoint capability.

**Resolution.** `KIND_DRIVER` is a **derived kind**, not a new base kind. At
runtime the descriptor carries base kind `KIND_DEVICE` (10) — a driver
fundamentally authorises device-memory + config access — and the "driver"
refinement lives in the descriptor's kind-specific tail (the manifest pointer).
This keeps the LAM 4-bit kind tag intact and avoids a major-version event. The
numeric `KIND_DRIVER = 0x15` is deliberately outside the 4-bit range to signal
"derived, not base." This decision is flagged for review at the next cap-system
design pass.

## 2. Manifest record format

A fixed 56-byte record (no allocator needed at probe time):

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0  | 4  | magic            | `0x44525659` ("DRVY") |
| 4  | 2  | version          | manifest format version |
| 8  | 2  | vendor_id        | PCI vendor |
| 10 | 2  | device_id        | PCI device |
| 12 | 4  | requested_rights | subset of R_DRIVER_* |
| 16 | 8  | irq_handler_entry| driver-local entry point |
| 24 | 32 | name             | NUL-padded ASCII |

A fixed record (rather than TOML) is chosen for R7 because the kernel cannot
parse text at mint time without a heap; a richer TOML manifest can be a
userspace-side build artifact that compiles down to this record.

## 3. Driver rights

| Right | Value | Grants |
|-------|-------|--------|
| R_DRIVER_PROBE | 0x1 | read config space (D7-003) |
| R_DRIVER_MMIO  | 0x2 | request MMIO region mappings (D7-005) |
| R_DRIVER_IRQ   | 0x4 | request an IRQ-endpoint capability |
| R_DRIVER_DMA   | 0x8 | request IOMMU-backed DMA buffers (Phase 7 proper) |

`cap_mint_driver(manifest_ptr, rights)` validates that `rights` is a subset of
`R_DRIVER_ALL` (0xF) before minting.

## 4. Example manifest — placeholder NVMe driver

```
magic            = 0x44525659
version          = 1
vendor_id        = 0x8086        # Intel
device_id        = 0x0953        # Intel DC P3700 NVMe (example)
requested_rights = R_DRIVER_PROBE | R_DRIVER_MMIO | R_DRIVER_IRQ | R_DRIVER_DMA
irq_handler_entry= <driver .text offset of its IRQ handler>
name             = "nvme0\0..."
```

The supervisor matches `(0x8086, 0x0953)` against the device tree; on a match it
mints a `KIND_DRIVER` cap (runtime base `KIND_DEVICE`) carrying this manifest and
hands it to the NVMe driver task, which then proceeds to `init`.

## 5. Citations (verification TODO)

- seL4 capability model (derived kinds, minting). **Verify** the derived-kind
  mechanism matches the seL4 retype/mint semantics referenced in
  `design/capabilities/linearity-and-tags.md`.
- NVMe Base Specification — vendor/device IDs used in the example are
  illustrative. **Verify** before using as a real driver target.
