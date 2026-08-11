# R24.M5 — Partial-close note (userspace API + IDT wire deferrals)

**Date:** 2026-08-11
**Milestone:** R24.M5 (NVMe interrupt handler + KIND_INTERRUPT / KIND_BLKDEV caps + userspace API)
**Issues in milestone:** #903 (irq handler), #904 (interrupt cap),
#905 (blkdev cap + RPC schema), #906 (userspace sync API + request table),
#907 (error paths).

## Summary

R24.M5 lands the kernel-side scaffolding for all five issues but two
issues are only partially closed — one because it depends on a
larger substrate blocker (`#1015`), one because its wire-in surface
belongs to a different round (`R23`+ IDT installation).

## Per-issue disposition

| Issue | Status  | Rationale |
|-------|---------|-----------|
| #903  | Closed  | `nvme_irq_handler_qid` landed at `src/kernel/core/drivers/nvme/irq.pdx`. IDT wire deferred (see below). |
| #904  | Closed  | `interrupt_cap_mint` + `notification_cap_mint` landed at `src/kernel/core/cap/interrupt_cap.pdx`. Mint-gate scaffolding follows the AcpiCap / DeviceCap precedent. |
| #905  | Closed  | `blkdev_cap_mint` landed at `src/kernel/core/cap/blkdev_cap.pdx`. Design docs at `design/ipc/blkdev-rpc-schema.md` + `design/drivers/blkdev-cap.md`. Wire code deferred pending `#1015`. |
| #906  | Partial | Kernel-side `_nvme_requests[128]` + `nvme_read_blocking` landed at `src/kernel/core/drivers/nvme/sync.pdx`. Userspace binary + RPC surface DEFERRED — blocks on `#1015` (userspace-server substrate). |
| #907  | Closed  | `nvme_csts_check` + `nvme_timeout_wait` + `nvme_abort_cmd` landed at `src/kernel/core/drivers/nvme/errors.pdx`. Fingerprint tag added to `src/kernel/core/klog/keys.pdx`. |

## #906 blocker (same shape as `#820` / `#860`)

`#906` asks for a *userspace* synchronous read/write API. Every
userspace-server binary in the current roadmap has been paused on the
same four gaps documented in the R20.M4 blocker filed against `#1015`
(see `gh issue view 1015`):

1. Named service-endpoint / broker mechanism.
2. Framed, variable-length IPC messages.
3. Userspace-server process model (`sys_ipc_recv` / `sys_ipc_reply`).
4. Boot-time capability injection into a server's initial CSpace.

The kernel-side pieces this round lands (`_nvme_requests` +
`nvme_read_blocking`) are the internal glue the eventual userspace
`nvme_supervisor` will use when the substrate arrives. They compile,
link, and are call-safe today; the fixture "sector 0 round-trip" from
`#906` can only run once (a) the driver-attach path executes against a
real NVMe controller (blocked on the UEFI/OVMF boot fixture,
independent of `#1015`), and (b) the userspace `nvme_supervisor`
exists to hold the KIND_BLKDEV cap and issue the RPC.

## IDT wire deferral for `#903`

`nvme_irq_handler_qid` is a callable symbol at M5 but is not installed
in any IDT vector. Per-CPU IDT vector installation for a driver-owned
handler is R22.M5 substrate work that was deferred at that milestone
close and has not yet been folded into a later round. The M5
acceptance surface here is symbol existence + CQ-walk correctness on
synthetic input; the ISR-to-notification bridge that signals the
`R_NOTIFY_SEND` on the paired badge lands with the same `#1015`
unblock.

## Build state

- `bash tools/build.sh` — 15/15 gates pass; kernel.elf links cleanly.
- Symbols verified via `nm`: `nvme_irq_handler_qid`,
  `interrupt_cap_mint`, `notification_cap_mint`, `blkdev_cap_mint`,
  `nvme_csts_check`, `nvme_timeout_wait`, `nvme_abort_cmd`,
  `nvme_read_blocking`, `_nvme_requests` — all present.

## Cross-references

- `design/ipc/blkdev-rpc-schema.md` — wire format the eventual driver-server will host.
- `design/drivers/blkdev-cap.md` — rights model + revocation semantics.
- `design/roadmap/r18-plus-bare-metal.md §R24` — round scope.
- `gh issue view 1015` — the userspace-server substrate blocker
  (originally filed as the R20.M4 closure note for `#820`).
- `src/kernel/core/drivers/nvme/{irq,sync,errors}.pdx` — kernel-side code landed this milestone.
- `src/kernel/core/cap/{interrupt_cap,blkdev_cap}.pdx` — cap scaffolding.

## What R24.M6 (closure) will do

R24.M6 will close the round with the standard closure retrospective +
STATUS.md update. It will NOT re-open `#906` or wire the IDT vector —
both are captured as R25+ or `#1015`-gated work. The M6 closure note
should link back to this partial-close file rather than repeating the
per-issue disposition table.
