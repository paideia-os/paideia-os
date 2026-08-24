---
issue: 1778
milestone: R54.M1 (NVMe write path — kernel-side)
subsystem: NVMe driver / block I/O
topic: nvme_write_blocking — the write mirror of nvme_read_blocking (OPC=0x01).
touching:
  - src/kernel/core/drivers/nvme/sync.pdx        (extend: add nvme_write_blocking + _nvme_write_stats)
  - src/kernel/boot/witness/r54_nvme_write.pdx   (new symbol-existence witness, not wired at default boot)
  - tests/r54/expected-r54-nvme-write.txt        (3-line spec golden)
  - tools/build.sh                               (ec_confine_one entry for _nvme_write_stats)
  - design/kernel/nvme-write-blocking.md         (this doc)
related:
  - src/kernel/core/drivers/nvme/sync.pdx        (nvme_read_blocking — mirrored one-for-one)
  - src/kernel/core/drivers/nvme/dispatch.pdx    (nvme_submit_io_cmd — opcode-agnostic; no dispatch change needed)
  - src/kernel/core/drivers/nvme/irq.pdx         (nvme_irq_handler_qid — completes both read and write CIDs)
---

# R54.M1-001 — `nvme_write_blocking` (#1778)

## 1. Scope

Land the write mirror of `nvme_read_blocking`. Every mutating FS op
(pdxfs-lite + pdxfs-block) currently returns EROFS pending this
symbol; landing it turns the block layer read-write.

Signature:

```
nvme_write_blocking(nsid: u64, lba: u64, count: u64, buf_pa: u64) -> u16
```

Returns the 16-bit CQE status (Phase bit stripped). Success is
`(status & 0xFFFE) == 0`; `0xFFFF` sentinel on completion-flag
timeout.

## 2. SQE layout (NVMe §5.15, Write)

| Field   | Offset | Value                              |
|---------|--------|------------------------------------|
| OPC     |     +0 | `0x01`                             |
| CID     |     +2 | round-robin `_nvme_next_cid & 127` |
| NSID    |     +4 | `nsid`                             |
| PRP1    |    +24 | `buf_pa`                           |
| CDW10   |    +40 | `LBA[31:0]`                        |
| CDW11   |    +44 | `LBA[63:32]`                       |
| CDW12   |    +48 | `(count - 1) & 0xFFFF`             |

PRP2 stays zero at M1 — single-page transfers only, per the same
posture `nvme_read_blocking`'s module header locks in. Multi-page
via a PRP list is a follow-on (paired with the read-side
`nvme_io_build_and_submit_one` PRP path in mdts.pdx).

## 3. CID reuse

Shares `_nvme_next_cid` and `_nvme_requests[128]` with
`nvme_read_blocking`. The M5 CID allocator is a monotonic bump
modulo 128 — one caller at a time, no cross-CID aliasing hazard
under the current single-kernel-caller posture. When the userspace
half (#1015) lands, a bitmap allocator with atomic reservation
replaces the bump; both directions inherit the swap.

## 4. CQE poll behaviour

Busy-waits on `_nvme_requests[cid].completion_flag` for up to
`NVME_SYNC_SPIN_MAX = 50_000_000` iterations (≈ 1.5 s wall-clock
on a 3 GHz box; comfortably above every NVMe Write latency the
platform will see). Timeout returns `NVME_SYNC_TIMEOUT (0xFFFF)`
— caller escalates to `nvme_abort_cmd` (errors.pdx) or resets the
controller.

Completion runs through the shared `nvme_irq_handler_qid` walker
(irq.pdx) — writes and reads use the same CQ / CID slot / status
plumbing. A regression on either side that skips the completion
handshake is visible to both.

## 5. PRP1 alignment

Per NVMe §4.5.2, PRP1 for a single-page transfer may point
anywhere within a page provided the transfer does not cross a
page boundary. For the current single-block (`count == 1`) callers
whose block size is 4096 B, PRP1 must be 4096-B aligned; smaller
LBA sizes lift that to "same-page as `buf_pa + count * lba_size`".

The witness (`src/kernel/boot/witness/r54_nvme_write.pdx`) sizes
its buffer as `[u64; 512] @align(4096)` to satisfy the tightest
case unconditionally. FS callers must obtain their PRP1 via
`bdev_read`/`bdev_write` helpers that already enforce
`page_aligned(buf_pa)` at the block layer boundary — see
`src/kernel/core/fs/pdxfs/bdev_write.pdx`.

## 6. Sequencing vs. FS writes

Callers must serialise writes to the same LBA range themselves —
this primitive has no journaling, no barrier, no MDTS-aware
split, and no fsync-on-completion semantic. It is one submitted
SQE, one CQE polled, one status returned. Higher-level ordering
guarantees are the block cache / journal writer's job (see
`design/filesystem/pdxfs-block-journal.md`).

Concurrent write and read on the same CID slot is prevented by
the shared bump allocator (`_nvme_next_cid`) — each submission
consumes a new CID before touching the SQE scratch. Cross-CID
concurrency (multiple in-flight ops from parallel callers) is
deferred to the R55+ bitmap allocator.

## 7. `_nvme_write_stats` — the one confined write-only surface

A `u64` counter bumped once per successful SQE fill (before the
submit call, after the write-slot bookkeeping). Sole writer is
`nvme_write_blocking`; sole readers are GDB / a future
`nvme_dump_stats` debug helper.

Confined via `ec_confine_one '_nvme_write_stats' 'core/drivers/
nvme/sync.o'` in `tools/build.sh` so a second writer is a
build-time refusal. This is the one write-only surface unique to
the write half — the shared `_nvme_next_cid` and `_nvme_requests`
allocator is multi-writer by design (irq.pdx completes both
directions).

## 8. What R54.M1 does NOT prove

- Live SQ pair on the default QEMU-TCG `-kernel` boot path. Under
  that posture `_nvme_io_queue_count == 0` and the witness must
  short-circuit BEFORE calling this primitive to avoid a stray
  memcpy to `sq_pa == 0`. The witness at
  `src/kernel/boot/witness/r54_nvme_write.pdx` is therefore not
  wired into the default `kernel_main` chain; it exists as a
  symbol-existence + link-cleanliness surface, invoked from GDB
  or from a future real-HW bring-up under
  `PAIDEIA_R54_NVME_WRITE=1`.
- Multi-block / PRP-list writes (mkfs / pkg install traffic > 4
  KiB). That path composes with `nvme_io_build_and_submit_one`
  (mdts.pdx) — R55+ work.
- Concurrent write throughput (deferred with the M5 bitmap
  allocator to the same #1015 milestone as the userspace half).

## 9. Regression — `PAIDEIA_R54_DISK=1` pre-push gate (#1781)

`.githooks/pre-push` carries an opt-in gate mirroring
`PAIDEIA_R53_DISK=1`. When set, the hook runs
`bash tools/run-smoke.sh boot_r54_bdev_round_trip` which drives
the two-phase orchestrator: phase 1 wipes + mkfs the disk image,
boots the kernel to write `0xDEADBEEFCAFEBABE` at LBA 16 via
`nvme_write_blocking` and clean umount; phase 2 boots again
(image preserved), `nvme_read_blocking`s the same LBA, and
`cmp`s against the pattern. Distinct from the R53 gate — R53
exercises the pdxfs write path, R54 exercises the raw block
submit path.

Off by default so unrelated pushes are not gated on the disk
posture. Preflight probes `tools/mkfs-pdxb.sh` and skips with a
guidance line if the paideia-as #1730 binary is not built yet
(same posture as R53) — the smoke cannot even reach the boot
phase without a real image, and a hard failure on that state
would gate every push on a condition that only clears when #1730
lands.

Fingerprints (contains-in-order, one per phase golden):

- Phase 1: `pdxb bdev round-trip write ok — lba=16 payload=deadbeefcafebabe [legacy: PDXB BDEV WROTE OK]`
- Phase 2: `pdxb bdev round-trip readback ok — lba=16 match=1 [legacy: PDXB BDEV READBACK OK]`

The `match=1` line is control-flow-gated on the compare succeeding
(mismatch jumps to a `pdxb bdev round-trip fail` klog tag before
reaching the ok-tag emit site) — the static `match=1` string is not
theatre.
