# PaideiaOS — Block Device RPC Schema (KIND_BLKDEV)

**Status:** Draft v0.1 (R24.M5 scaffolding)
**Date:** 2026-08-11
**Issue:** #905 (r24-m5-003)
**Depends on:** #1015 (userspace-server substrate — see r20-closure blocker)
**Sibling:** `design/drivers/blkdev-cap.md` (cap rights model)
**Scope:** Wire format for `read_sectors` / `write_sectors` / `get_capacity`
RPCs exchanged between a KIND_BLKDEV holder (userspace filesystem, `dd`,
`fsck`, `mkfs`) and the NVMe driver-server.

## Pillar alignment

- **Pillar 3 (microkernel).** All block I/O leaves the kernel over a
  named-endpoint IPC to the NVMe driver-server. The kernel path
  (`src/kernel/core/drivers/nvme/sync.pdx §nvme_read_blocking`, landed
  at R24.M5) is kernel-only glue and never exposed to ring-3.
- **Pillar 6 (security by construction).** Every RPC frame carries a
  KIND_BLKDEV capability handle. The driver-server validates the
  handle's rights on receive (READ for read_sectors, WRITE for
  write_sectors, ADMIN for get_capacity) via `blkdev_cap_verify`
  (lands with #1015 unblock). Handle revocation invalidates every
  outstanding RPC citing it.

## 1. Transport (post-#1015)

The transport is the wait-free dataflow IPC substrate from
`design/ipc/wait-free-dataflow.md`, framed via `design/ipc/typed-handoff.md`.
Each RPC is a request/reply pair over a per-client endpoint minted by
the NVMe driver-server.

Until #1015 lands the substrate is not in the syscall table (no
`sys_ipc_recv` / `sys_ipc_reply`), so wire code is intentionally absent
from R24.M5. The kernel-side sync helper `nvme_read_blocking` is the
proxy the eventual driver-server will call once it exists.

## 2. RPC methods

### 2.1 `read_sectors(nsid, lba, count, out_buf_cap) -> u16`

Wire request frame (32 B):

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0  | 4 | magic         | `0x424C4B52` ("BLKR") |
| 4  | 2 | op            | `0x0001` = read_sectors |
| 6  | 2 | flags         | reserved (0) |
| 8  | 4 | nsid          | NVMe namespace identifier |
| 12 | 4 | count         | number of logical blocks (1-based) |
| 16 | 8 | lba           | starting LBA |
| 24 | 8 | out_buf_cap   | KIND_PAGE cap handle for the destination |

Wire reply frame (16 B):

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0  | 4 | magic         | `0x424C4B52` |
| 4  | 2 | status        | 16-bit CQE status; 0 = success |
| 6  | 2 | flags         | reserved |
| 8  | 8 | bytes_read    | count × lba_size on success, 0 on error |

Rights required on the KIND_BLKDEV handle: `R_BLK_READ` (bit 0).

### 2.2 `write_sectors(nsid, lba, count, in_buf_cap) -> u16`

Wire request frame (32 B): same layout as `read_sectors`, `op = 0x0002`,
`in_buf_cap` in place of `out_buf_cap`. Rights required: `R_BLK_WRITE`
(bit 1).

Wire reply frame (16 B): same layout as `read_sectors` reply, with
`bytes_read` reinterpreted as `bytes_written`.

### 2.3 `get_capacity() -> (block_count, lba_size)`

Wire request frame (16 B):

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0  | 4 | magic         | `0x424C4B52` |
| 4  | 2 | op            | `0x0003` = get_capacity |
| 6  | 2 | flags         | reserved |
| 8  | 4 | nsid          | NVMe namespace identifier |
| 12 | 4 | _pad          | 0 |

Wire reply frame (24 B):

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0  | 4  | magic         | `0x424C4B52` |
| 4  | 2  | status        | 0 = success |
| 6  | 2  | flags         | reserved |
| 8  | 8  | block_count   | NSZE from Identify Namespace |
| 16 | 4  | lba_size      | bytes per block |
| 20 | 4  | _pad          | 0 |

Rights required: any of `R_BLK_READ | R_BLK_WRITE | R_BLK_ADMIN`
(capacity is not a secret; the check is that the cap is not revoked).

## 3. Capability semantics

Every RPC frame carries the KIND_BLKDEV cap handle in the IPC's
capability slot (not in the payload — the transport already carries a
capability alongside the byte frame). The driver-server:

1. Fetches the descriptor via `cap_lookup(handle)`.
2. Rejects with `EPERM` (status = 0xFFFD) if the cap is revoked.
3. Rejects with `EPERM` if the required-right bit is missing.
4. Rejects with `ENOENT` (status = 0xFFFC) if the descriptor's
   `nsid` doesn't match the frame's `nsid` (defense-in-depth against
   handle-confusion attacks).

Descriptor field access via helpers landing with #1015:
- `blkdev_cap_controller_idx(handle)` — the NVMe controller slot (0..7).
- `blkdev_cap_nsid(handle)`.
- `blkdev_cap_lba_size(handle)`.
- `blkdev_cap_block_count(handle)`.

## 4. Buffer-cap discipline

`out_buf_cap` / `in_buf_cap` are KIND_PAGE handles (not raw addresses).
The driver-server translates handle → PA via `page_cap_pa(handle)` and
verifies:

- The buffer is at least `count × lba_size` bytes.
- The buffer PA is DMA-capable (for R25+: has an IOMMU DTE mapping).
- The transfer fits in a single 4 KiB page at R24.M5 (see
  `src/kernel/core/drivers/nvme/sync.pdx §nvme_read_blocking §Body`);
  multi-page transfers via PRP list land with `nvme_prp_encode` (already
  present at R24.M4) becoming reachable from the driver-server.

## 5. Backpressure and concurrency

The kernel-side request table is `_nvme_requests[128]` (16 B stride, 2
KiB total) — 128 in-flight CIDs per controller. The driver-server
partitions this budget per client (fair-queue on connection) via a
per-cap in-flight counter. A `read_sectors` call that would exceed the
per-client budget returns `EAGAIN` (status = 0xFFFB) — the client
retries after `wait_notif()` on the driver-server's back-pressure
notification cap.

The acceptance criterion "concurrent 64 in-flight OK (matches SQ depth)"
from #906 is satisfied by this budget: even one client can saturate a
single IO SQ; two clients each running 32 in-flight parallel reads is
the fixture the driver-server round will validate.

## 6. Error codes (u16 wire values)

| Value | Name | Meaning |
|-------|------|---------|
| 0x0000 | OK        | Success |
| 0xFFFB | EAGAIN    | Per-client in-flight budget exhausted |
| 0xFFFC | ENOENT    | NSID / cap mismatch |
| 0xFFFD | EPERM     | Cap revoked or missing right |
| 0xFFFE | EIO       | NVMe controller error (see status.SC/SCT) |
| 0xFFFF | ETIMEDOUT | Completion did not arrive within budget |

Values in `[0x0001, 0x7FFF]` are NVMe-native CQE.Status codes (bits
1..15 of the CQE.Status field, shifted right by one to remove the Phase
Tag). Applications should treat any non-zero value as a failure and only
consult the value for diagnostic messages.

## 7. R24.M5 posture

- Wire code: not present. Requires `sys_ipc_recv` / `sys_ipc_reply` in
  the syscall table.
- Kernel-side scaffolding: `blkdev_cap_mint` gate landed at
  `src/kernel/core/cap/blkdev_cap.pdx`. Descriptor slab-write deferred
  until `cap_revoke` has a real body (see `cap/revoke.pdx §R12-m5-001`).
- The kernel-side sync helper `nvme_read_blocking(nsid, lba, count,
  buf_pa) -> u16` landed at `src/kernel/core/drivers/nvme/sync.pdx`
  covers the eventual driver-server's own read path.
- Request table `_nvme_requests[128]` landed at
  `src/kernel/core/drivers/nvme/sync.pdx`; walked by
  `nvme_irq_handler_qid` in `src/kernel/core/drivers/nvme/irq.pdx`.

## 8. Sequencing to unblock

1. #1015 lands the userspace-server substrate (named endpoints, framed
   IPC, blocking receive, cap-seed on process spawn).
2. A subsequent round (R25+ per `design/roadmap/r18-plus-bare-metal.md`)
   ships the NVMe driver-server as a userspace binary against the
   substrate.
3. The driver-server hosts the RPC frames defined here, minting one
   KIND_BLKDEV per active namespace via `blkdev_cap_mint`.
4. Filesystem and block-user clients receive their caps via the
   supervisor's introduction protocol; every read/write flows through
   the frames above.

## 9. Cross-references

- `design/drivers/blkdev-cap.md` — rights model, revocation semantics.
- `design/ipc/wait-free-dataflow.md` — transport substrate.
- `design/ipc/typed-handoff.md` — framing.
- `design/ipc/acpi-supervisor-schema.md` — sibling supervisor RPC schema
  (structurally identical framing).
- `src/kernel/core/cap/blkdev_cap.pdx` — mint gate.
- `src/kernel/core/drivers/nvme/sync.pdx` — kernel-side sync API.
- `src/kernel/core/drivers/nvme/irq.pdx` — CQ walker + request-table
  wake path.
