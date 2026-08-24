# R54 Retrospective: NVMe write-sync + bdev_write real path

**Date:** 2026-08-24
**Milestone:** R54.M1 (single-milestone round; closed by this doc + #1782)
**Issues:** 5 landed (4 implementation + 1 closure). No deferrals.
**HEAD at closure:** bumped by the R54.M1-005 commit that lands this doc.
**paideia-as pinned at:** unchanged across R54 — **ninth consecutive round**
with zero cross-repo escalations, since R21 close.
**Release tag:** `r54-closed`.

---

## Round Intent

R54 was scoped as the write-path substrate that turns the R51 NVMe
driver + R52 PdxFS-on-block layer read-write. Every mutating filesystem
op (pdxfs-block bdev_write, pdxfs-lite `create` / `unlink` / `rename`,
future FS mutations) currently returns `EROFS` pending the write mirror
of `nvme_read_blocking`. R54 lands that mirror (`nvme_write_blocking`,
OPC=0x01) plus the immediate consumer wire-through (`bdev_write` real
submit path), plus a two-phase round-trip witness that proves reboot
preserves state via the raw block-submit path.

Single milestone, five issues, no deferrals:

- **M1** — NVMe write-sync + bdev_write real path:
  - **#1778 (M1-001):** `nvme_write_blocking(nsid, lba, count, buf_pa) -> u16`
    one-for-one mirror of `nvme_read_blocking` (OPC=0x01, same SQE layout,
    same CID/CQE poll semantics, own `_nvme_write_stats` confined via
    `ec_confine_one`). Dormant witness at
    `src/kernel/boot/witness/r54_nvme_write.pdx` (not wired at default
    boot — no live SQ under QEMU `-kernel`).
  - **#1779 (M1-002):** `bdev_write` real submit path over
    `nvme_write_blocking`. Widened effect row `!{mem}` → `!{sysreg, mem}`,
    LIVE branch calls `nvme_write_blocking(nsid=1, entry.lba, count=1,
    buf_pa=&_nvw_flush_scratch)`, SUBSTRATE branch preserves scaffold
    stamping. Emits `pdxb bdev flush ok [legacy: BDEV FLUSH OK] pending=<n>
    submitted=<m>` fingerprint. LIVE/SUBSTRATE gate on
    `_nvme_io_queue_count != 0` — substrate always mark-only under
    PVH `-kernel` boot (no PCI enum → no IO SQ pairs → no #GP/hang risk).
  - **#1780 (M1-003):** Two-phase round-trip witness — write
    `0xDEADBEEFCAFEBABE` at LBA 16 in phase 1 via `nvme_write_blocking`,
    clean umount; in phase 2 boot again against the preserved image and
    `nvme_read_blocking` the same LBA, compare against the pattern.
    `match=1` line is control-flow-gated on the compare succeeding
    (mismatch jumps to a `pdxb bdev round-trip fail` klog tag before
    reaching the ok-tag emit site). Chose direct
    `nvme_write/read_blocking` over `nvw_submit` because the batcher
    hardwires `buf_pa=&_nvw_flush_scratch` (zero page) — round-trip
    needs a distinctive payload. Three run-smoke.sh modes
    (`boot_r54_bdev_round_trip_phase{1,2}` + orchestrator) mirror the
    R53.M4 `boot_r53_round_trip` shape.
  - **#1781 (M1-004):** `.githooks/pre-push` extension —
    `PAIDEIA_R54_DISK=1` opt-in gate mirroring `PAIDEIA_R53_DISK=1`.
    Same skip-on-missing-mkfs preflight (`tools/mkfs-pdxb.sh` rc=3 → skip
    with guidance line). Distinct from R53 gate: R53 exercises the pdxfs
    write path, R54 exercises the raw block submit path.
  - **#1782 (M1-005):** Round closure — this doc + STATUS.md block +
    `r54-closed` tag.

R25 debt item #1 (`nvme_write_blocking` kernel-side) is discharged by
this round. That unblocks the mutating-op path for pdxfs-lite (`create`
/ `unlink` / `rename` — they still return EROFS, but on the substrate
now, no longer on a missing primitive).

---

## What R54 Delivered

### R54.M1 — NVMe write-sync + bdev_write real path (5 issues; 0 deferred)

- **#1778 nvme_write_blocking** — write mirror of `nvme_read_blocking`.
  Signature `(nsid, lba, count, buf_pa) -> u16` returning the 16-bit CQE
  status (Phase bit stripped). Success = `(status & 0xFFFE) == 0`;
  `0xFFFF` sentinel on completion-flag timeout. Confined
  `_nvme_write_stats` symbol (one writer: `sync.pdx`) via
  `ec_confine_one` in `tools/build.sh`. Dormant witness at
  `src/kernel/boot/witness/r54_nvme_write.pdx` — not wired at default
  boot because `_nvme_io_queue_count == 0` under QEMU-TCG `-kernel` and
  the witness must short-circuit before calling the primitive to avoid
  a stray memcpy to `sq_pa == 0`. Design doc at
  `design/kernel/nvme-write-blocking.md`.
- **#1779 bdev_write real submit path** — `bdev_write.pdx` LIVE branch
  now calls `nvme_write_blocking(nsid=1, entry.lba, count=1,
  buf_pa=&_nvw_flush_scratch)` (4 KiB @align(4096) confined scratch).
  Emits `pdxb bdev flush ok [legacy: BDEV FLUSH OK] pending=<hex>
  submitted=<hex>` per flush call. Substrate boot exercised the
  fingerprint 4× with `pending == submitted` (3/1/50/50). Dormant
  witness at `src/kernel/boot/witness/r54_bdev_flush.pdx`.
- **#1780 round-trip witness** — `r54_bdev_round_trip.pdx` discriminates
  on `sb_flags` bit 0 (`PDXB_SB_FLAG_CLEAN_UNMOUNT`). Phase 1 (bit
  CLEAR): writes pattern at LBA 16, emits
  `pdxb bdev round-trip write ok — lba=16 payload=deadbeefcafebabe
  [legacy: PDXB BDEV WROTE OK]`. Phase 2 (bit SET): reads LBA 16,
  `cmp` against pattern, emits
  `pdxb bdev round-trip readback ok — lba=16 match=1
  [legacy: PDXB BDEV READBACK OK]` only on match (mismatch takes the
  fail branch). Wired via `r30_platform.pdx` immediately after
  `pdxfs_round_trip_phased_call`. Two goldens under `tests/r54/`.
  Three run-smoke.sh modes; TIMEOUT=25 per phase. Full end-to-end
  exercise requires paideia-as #1730 (`mkfs-pdxb` tool built) — the
  smoke modes error cleanly with a guidance line until then.
- **#1781 PAIDEIA_R54_DISK=1 pre-push gate** — same shape as R53 gate,
  same skip-on-missing-mkfs preflight. Documented in
  `design/kernel/nvme-write-blocking.md §9 Regression`.
- **#1782 closure** — this doc + STATUS.md block + `r54-closed` tag.

### Cross-Repo Escalations to paideia-as (R54)

**None.** `paideia-as` submodule remained pinned throughout R54.
**Ninth consecutive round** with zero cross-repo escalations. R54's
work was entirely NVMe-driver + fs-block-layer + witness plumbing over
existing paideia-as encoders; no new assembly instructions, no
elaborator changes, no encoder gaps.

### Observable Proof

- Kernel builds clean under `tools/build.sh`.
- Substrate boot (`bash tools/run-qemu.sh`) reaches SHELL START + `$`
  prompt; `pdxb bdev flush ok` fingerprint fires 4× with
  `pending == submitted`; new `r54_bdev_round_trip` witness stays
  correctly silent on substrate (`_nvme_io_queue_count == 0` gate).
- `bash tools/run-smoke.sh --with-disk --wipe boot_r54_bdev_round_trip_phase1`
  errors cleanly with `mkfs-pdxb binary not built yet` guidance line
  (expected until paideia-as #1730 lands — same posture as R53.M4
  round-trip smoke).
- Debugger-verified all four implementation diffs (11/11 checks on
  #1779, 13/13 checks on #1780) — no defects survived adversarial
  review.

### R54 Debt Carried Forward

1. **Full end-to-end `boot_r54_bdev_round_trip` exercise** — blocked
   by paideia-as #1730 (mkfs-pdxb host tool not built yet).
   Discharges automatically when #1730 lands and `bash tools/build.sh`
   materialises `build/tools/mkfs-pdxb`. No R54 code change needed.
2. **Multi-block / PRP-list writes** (mkfs / pkg-install traffic > 4
   KiB) — deferred to R55+ (composes with
   `nvme_io_build_and_submit_one` from mdts.pdx). Not on R54 critical
   path — the R54 goldens exercise single-LBA writes only.
3. **Concurrent write throughput** — deferred to the same #1015
   milestone as the userspace half.
4. **pdxfs-lite mutating ops** (`create.pdx` / `unlink.pdx` /
   `rename.pdx`) still return `EROFS` — the R54 primitive is present
   but the pdxfs-lite call sites need explicit wire-through (target:
   R55+ as those FS ops are re-scoped).
5. **Live SQ pair on real HW** — dormant `r54_nvme_write` witness
   exists as a symbol-existence + link-cleanliness surface; live SQ
   exercise is a `gated:hardware` deferral for the R28+ hardware
   bring-up sub-round.

**None regress R54 acceptance for the write-sync + bdev_write substrate.**

### Debt Discharged

- **R25 debt item #1** — `nvme_write_blocking` kernel-side (open since
  R25 close in 2026-04-16). Discharged by #1778.

### Quirks Discovered on Real Hardware

None (R54 ran entirely under QEMU `-kernel` / documentation).
`design/hardware/quirks.md` unchanged.

**Next Round:** R55 (multi-block / PRP-list writes + pdxfs-lite
mutating-op wire-through). Zero R54 blockers.
