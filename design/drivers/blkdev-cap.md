# PaideiaOS — Block Device Capability (KIND_BLKDEV)

**Status:** Draft v0.1 (R24.M5 scaffolding)
**Date:** 2026-08-11
**Issue:** #905 (r24-m5-003)
**Sibling:** `design/ipc/blkdev-rpc-schema.md` (wire format)
**Scope:** Rights model + revocation semantics for the per-namespace
block-device capability minted by the NVMe driver.

## 1. Kind assignment

`KIND_BLKDEV` is a *derived* kind (per
`design/capabilities/linearity-and-tags.md §3.1`), riding the base kind
`KIND_PAGE` (=4). The underlying resource is a set of logical blocks
projected onto host pages via NVMe PRP transfers; the byte-addressable-
range analogy that motivated the KIND_ACPI and KIND_PCI_DEV rides holds
here too.

Derived tag values (all outside the 4-bit LAM range so audits at the
descriptor tail can disambiguate):

| Derived kind         | Tag  | Base kind |
|----------------------|------|-----------|
| KIND_DRIVER          | 0x15 | KIND_DEVICE (10) |
| KIND_ACPI            | 0x20 | KIND_PAGE (4) |
| KIND_PCI_DEV         | 0x30 | KIND_PAGE (4) |
| KIND_INTERRUPT_CAP   | 0x40 | KIND_INTERRUPT (9) |
| KIND_NOTIFICATION_CAP| 0x41 | KIND_NOTIFICATION (12) |
| KIND_BLKDEV          | 0x42 | KIND_PAGE (4) |

## 2. Rights lattice

| Bit | Right          | Grants |
|-----|----------------|--------|
| 0   | `R_BLK_READ`   | `read_sectors` RPC |
| 1   | `R_BLK_WRITE`  | `write_sectors` RPC |
| 2   | `R_BLK_ADMIN`  | `get_capacity` (though any non-empty right suffices) + namespace mgmt (R25+) |

`R_BLK_ALL = 0x07` is the "root" cap held only by the `nvme_supervisor`
process at boot. Every downstream mint is a strict subset (typed via
the `Rights` lattice from `src/kernel/core/cap/rights.pdx`, which is
already substructural under the FP discipline of Pillar 4).

Default publication (per-namespace, minted by the driver on
`nvme_ns_list` completion, wire-up deferred to R25+ per `#1015`):
`R_BLK_READ | R_BLK_WRITE`. Filesystems that want an atomic
mount-then-restrict pattern receive `R_BLK_ALL` briefly, downgrade to
`R_BLK_READ` before spawning userland accessors.

## 3. Descriptor layout (32 B)

Mirrored from `src/kernel/core/cap/blkdev_cap.pdx §Descriptor payload
layout`:

| Offset | Size | Field           | Notes |
|--------|------|-----------------|-------|
| 0  | 1  | controller_idx  | index into `_nvme_devices` (0..7) |
| 1  | 1  | _pad0           | 0 |
| 2  | 2  | _pad1           | 0 |
| 4  | 4  | nsid            | NVMe namespace identifier (>0) |
| 8  | 4  | lba_size        | bytes per logical block (512 / 4096) |
| 12 | 4  | _pad2           | 0 |
| 16 | 8  | block_count     | NSZE (total addressable blocks) |
| 24 | 4  | rights          | subset of `R_BLK_ALL` |
| 28 | 4  | _pad3           | 0 |

The `controller_idx` field ties the cap to a specific enumerated NVMe
controller. Hot-remove invalidates every cap sharing that
`controller_idx` (R25+ hot-plug work — logic TBD).

## 4. Mint gate

`blkdev_cap_mint(controller_idx, nsid, rights) -> u64` in
`src/kernel/core/cap/blkdev_cap.pdx` validates:

- `controller_idx < BLK_CAP_CTRL_MAX (8)` — matches NVME_MAX_DEVS.
- `nsid != 0` — NVMe §3.1.14 forbids NSID=0 as a target.
- `rights & ~R_BLK_ALL == 0` — no bit outside the lattice.

Return codes: `BLK_CAP_MINT_OK (0)`, `BLK_CAP_MINT_BAD_CTRL (0xFFFFFFFE)`,
`BLK_CAP_MINT_BAD_NSID (0xFFFFFFFD)`, `BLK_CAP_MINT_BAD_RIGHTS (0xFFFFFFFF)`.

## 5. Revocation semantics

The kernel-side `cap_revoke` (currently a placeholder — see
`src/kernel/core/cap/revoke.pdx §R12-m5-001`) will:

1. Mark the descriptor invalid (bump generation counter).
2. Fault every outstanding in-flight NVMe request citing the cap
   (walk `_nvme_requests[128]`, match on stored cap handle — the
   `blocked_task` field is repurposed at R25+ to carry the handle
   for revocation-aware error propagation).
3. Deliver `EPERM` on the paired notification badge to unblock the
   holder's `read_blocking` / `write_blocking` call.
4. Return the slab entry to the free list.

The `#904` acceptance criterion "cap revocation cleanly detaches
driver" translates directly: revocation of the driver-server's
KIND_INTERRUPT_CAP triggers step (2) for every request table entry
whose completion notification points at the driver.

## 6. Fixture posture at R24.M5

- Mint gate: landed (this module).
- Real slab_alloc + descriptor write: deferred until `cap_revoke` has
  a real body.
- IPC RPC surface: designed (`design/ipc/blkdev-rpc-schema.md`); wire
  code deferred to `#1015` unblock.
- Publication (one mint per active namespace via `nvme_ns_list`
  results): deferred — the wiring lands with the driver-server round
  that follows `#1015`.

## 7. Cross-references

- `src/kernel/core/cap/blkdev_cap.pdx` — mint gate + descriptor spec.
- `src/kernel/core/cap/kind.pdx §Kind` — base-kind enum.
- `design/capabilities/linearity-and-tags.md §3.1` — closed-enum invariant.
- `src/kernel/core/cap/revoke.pdx §R12-m5-001` — revocation deferral.
- `design/ipc/blkdev-rpc-schema.md` — wire format.
- `design/drivers/driver-cap.md` — sibling per-driver-registration cap.
