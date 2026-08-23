# R51 unified-BDEV hardware smoke — operator recipe (T14 G4 internal NVMe)

**Owner issue:** #1680 (R51.M8-006, `gated:hardware`). Closes R51.M8 and
the R51 round.
**Status:** **UNSEEDED.** Every procedure below is written to be run on
a real ThinkPad T14 Gen 4 against its internal NVMe device, and no
expected fingerprint values are recorded, because recording an expected
value nobody measured is the failure this file exists to avoid.

This follows the discipline of `tools/hw-smoke-r47-vmd.md`,
`tools/hw-smoke-r35-hotplug.md`, `tools/hw-smoke-r34-isoch.md` and
`tools/nvme-hw-smoke.md`: the recipe lands before first light, and the
expectations are filled in from a real capture, at which point the
corresponding check promotes from SKIP to LIVE.

---

## 0. Scope

This document is the operator-run recipe that promotes the R51 unified
BDEV substrate (M1–M8, issues #1651-#1680) from a QEMU `-device nvme`
/ `-device ahci` structural witness to a real-hardware acceptance
witness on the T14 G4. It exercises the **full unified BDEV path**:
`sys_mount` → `KIND_BLKDEV` mint → `BDEV_OP_QUERY_GEOM` →
journaled write + `FLUSH` barrier → clean unmount → remount → WAL
replay → snapshot digest compare, run against the T14 G4's internal
NVMe device (family byte `1` = `NVME`; the T14 G4 has no on-board AHCI
controller, so the AHCI leg of the unified path stays QEMU + optional
SATA-dock-only — see `tools/nvme-hw-smoke.md` §1.2 for the VMD-off BIOS
posture this recipe reuses verbatim).

Since QEMU/TCG cannot emulate the T14 G4's real Iris Xe / Raptor Lake
platform, `tools/run-smoke.sh` (the QEMU smoke driver) never runs this
witness. `tools/run-smoke-hw.sh` (the real-hardware smoke driver) gains
a new `r51_m8_bdev` mode for it, gated by `PAIDEIA_R51_M8_HW=1` on top
of the script-wide `PAIDEIA_HW_SMOKE=1` — a second, issue-specific gate
because this mode is destructive (it mounts, writes, and unmounts a
real volume) in a way the read-mostly `boot`/`pdxfs`/`net`/`usb` modes
are not, so an operator running the composite `all` mode should never
trigger it by accident. The kernel-side placeholder witness at
`tests/kernel/drivers/nvme/hw_smoke_r51_t14g4_bdev_placeholder.pdx`
stays dormant (returns 0, unregistered by any boot witness) until the
promotion checklist in §5 is worked through by an operator standing in
front of the machine — the live acceptance path for #1680 is this
recipe's §2 (an operator typing at the shell prompt) plus the
`r51_m8_bdev` fingerprint check, not a kernel boot-time call.

The wires this smoke exercises (see
`design/hardware/nvme-ahci-tail-milestones.md` §M8-006 for the
authoritative anchor):

- `src/kernel/core/cap/blkdev_cap_request.pdx` — R51.M8-001 (#1675)
  `sys_mount` wire through `KIND_BLKDEV`.
- `src/kernel/core/cap/bdev_barrier.pdx` — R51.M8-002 (#1676) journaled
  write + `FLUSH` barrier order.
- `src/kernel/core/cap/mount_replay_digest.pdx` — R51.M8-003 (#1677)
  unmount + remount + WAL replay + snapshot digest.
- `tests/kernel/nvme/bdev_cross_family_soak_synth.pdx` — R51.M8-004
  (#1678) cross-family soak (QEMU-only at R51; this recipe is the HW
  promotion of the same mount/write/unmount/remount/read loop shape).
- `src/kernel/core/fs/pdxfs/superblock.pdx` (`sb_mount_gen`) and
  `src/kernel/core/cap/kind_blkdev.pdx` (`blkdev_row_family`) — the two
  fingerprint fields unique to this HW witness (see §4).

None of the above requires new kernel wiring for this issue — #1680's
scope is the operator recipe + a dormant placeholder witness that gets
promoted to live once an operator captures a real run.

---

## 1. Prerequisites

### 1.1 Hardware

- T14 G4 physical unit (Intel Raptor Lake, MVP target).
- Internal NVMe SSD (factory Micron 2400 / Kioxia BG5) with a
  **scratch** data volume — this recipe mounts, mkfs's, writes, and
  unmounts a volume; do not point it at a partition holding data you
  want to keep.
- USB-serial adapter + DB-9 null-modem cable + Lenovo Universal USB-C
  Dock Gen 2 (or equivalent), per `tools/run-smoke-hw.sh` and
  `design/hardware/t14-g4-first-boot.md` §4.

### 1.2 BIOS Setup

- **Intel VMD Controller = Disabled** (per
  `design/hardware/quirks.md` §2.4 and `tools/nvme-hw-smoke.md` §1.2 —
  this recipe reuses the VMD-off posture, not the R47 VMD-on posture).
- Secure Boot Disabled, CSM Disabled, UEFI Only — same as every other
  T14 G4 recipe (`design/hardware/t14-g4-first-boot.md` §3).

### 1.3 Software

- A build of paideia-os that includes every R51.M1–M8 landing (mint
  gates through M4, AHCI I/O + hot-plug through M6, tail extension
  through M7, mount/journal/soak/hot-remove through M8).
- A UEFI-bootable USB with the loader + rootfs, per
  `design/hardware/t14-g4-first-boot.md` §1–2.

---

## 2. Procedure

1. Boot the T14 G4 from USB with VMD **Disabled**, per
   `design/hardware/t14-g4-first-boot.md` steps 0–5 (cold power → USB
   stick → serial cable → first-light kernel message → `kernel_main`
   reaches userspace, i.e. the `$ ` shell prompt).
2. At the prompt, drive the R51.M8-003 (#1677) sequence against the
   internal NVMe device's scratch volume:
   1. `mount` — `sys_mount` claims a `KIND_BLKDEV` slot via
      `blkdev_cap_request`; watch for `BDEV_OP_QUERY_GEOM` returning a
      non-zero `(lba_size, block_count)` pair matching the physical
      drive's reported capacity.
   2. Take the pre-write snapshot digest (superblock + itable + WAL
      head + data-region hash — same shape as #1677's `D_pre`).
   3. Write 32 journaled records with the six-step barrier order
      (`WRITE` journal payload → `FLUSH` → `WRITE` CSUM → `FLUSH` →
      `WRITE` data blocks → `FLUSH` on `JOP_COMMIT`).
   4. `unmount` cleanly (last op before unmount is a `BDEV_OP_FLUSH`).
   5. `mount` again (remount).
   6. Let WAL replay walk the on-disk JBNL blocks.
   7. Take the post-replay snapshot digest (`D_post`).
   8. Assert `D_pre == D_post`.
   9. `unmount`.
3. Record the fingerprint fields listed in §4 from the serial capture.

---

## 3. Fingerprint check

```
PAIDEIA_HW_SMOKE=1 PAIDEIA_R51_M8_HW=1 \
    PAIDEIA_HW_SMOKE_LOG=/tmp/paideia-r51-bdev.log \
    tools/run-smoke-hw.sh r51_m8_bdev
```

`run-smoke-hw.sh`'s `r51_m8_bdev` mode requires BOTH `PAIDEIA_HW_SMOKE=1`
(the script-wide real-hardware gate) and `PAIDEIA_R51_M8_HW=1` (an
issue-specific gate, since this mode writes to the internal NVMe
volume — see §0). It checks the captured log against
`tests/hw/r51-nvme-t14g4.golden` and, absent that file, soft-skips
(exit 77) with the same "SKIP — fingerprint file not seeded yet"
message every other `run-smoke-hw.sh` mode gives before its first
capture (see §5). The eventual golden file is expected to be a no-diff baseline on
first landing per the design doc — regressions are diffs against it,
not against a hand-picked "expected" value invented before first
light.

---

## 4. Expected fingerprints (all UNSEEDED)

- `T14 G4 HW BDEV BEGIN`
- `T14 G4 HW BDEV OK` — closing fingerprint; source (once promoted):
  `tests/kernel/drivers/nvme/hw_smoke_r51_t14g4_bdev_placeholder.pdx`.
- Superblock digest (post-mkfs) — **TODO on first light**: record the
  16-byte digest.
- Itable digest (post-write) — **TODO on first light**.
- WAL-head LBA — **TODO on first light**.
- `mount_gen` counter (`sb_mount_gen`) — **TODO on first light**:
  expect `1` on a freshly-mkfs'd volume's first mount, incrementing on
  each subsequent mount per `superblock_fmt.pdx`'s documented layout.
- `blkdev_row_family` byte — **must read back `1` (NVME)** on the T14
  G4's internal drive; a `2` (AHCI) or any other value here is itself
  a fail, since the whole point of running on the T14 G4 is to prove
  the NVME leg of the unified dispatch on real silicon.

### 4.1 Redaction

Per the design doc, serial numbers, wall-clock timestamps, and MSI-X
vector indices (dependent on APIC init order, not reproducible) must
be stripped before fingerprinting. The design doc names
`tools/hw-smoke-normalize.sh` (attributed to R28.M2) as the redaction
script; **that script does not exist in this tree** — R28.M2 landed
`tools/run-smoke-hw.sh`'s own in-order contains-check (which already
tolerates unredacted noise between fingerprint lines) but never a
standalone normalize script. This is a documentation gap in the design
doc, not something #1680 closes; until a real `hw-smoke-normalize.sh`
lands, redaction is manual (strip serial numbers / timestamps / MSI-X
indices from the captured log by hand before diffing against §4 or
the eventual golden file).

---

## 5. Promotion checklist

- [ ] Fill in superblock digest, itable digest, WAL-head LBA,
      `mount_gen` from a real capture.
- [ ] Confirm `blkdev_row_family == 1` (NVME) from the real capture.
- [ ] Seed `tests/hw/r51-nvme-t14g4.golden` (currently absent — no
      `tests/hw/` directory exists in this tree yet; every other
      `tests/hw/expected-hw-*.txt` file referenced by
      `tools/run-smoke-hw.sh` is in the same UNSEEDED state) from the
      captured, redacted log.
- [ ] (Optional) Promote
      `tests/kernel/drivers/nvme/hw_smoke_r51_t14g4_bdev_placeholder.pdx`
      from a dormant stub to a live kernel-side witness, if a future
      round wants the kernel itself (rather than the operator at the
      shell prompt) to drive the mount/write/flush/unmount/remount/read
      sequence. `tools/run-smoke-hw.sh`'s `r51_m8_bdev` mode already
      exists and needs no further wiring — only the golden file above.
- [ ] Write `tools/hw-smoke-normalize.sh` if MSI-X/timestamp/serial
      noise turns out to actually land inside a fingerprint line
      (it may not, if the fingerprint fields chosen in §4 are already
      noise-free digests/counters).
- [ ] Close #1680 with the capture attached. This closes R51.M8 and
      the R51 round.

Until each item above is checked, #1680 stays open with the
`gated:hardware` label, the placeholder returns 0, and
`tests/hw/r51-nvme-t14g4.golden` does not exist.

---

## 6. Cross-references

- `design/hardware/nvme-ahci-tail-milestones.md` §M8-006 — design
  authority for this recipe.
- `design/hardware/t14-g4-first-boot.md` §6 — steps 0–5 (cold power to
  shell prompt) this recipe's §2 step 1 builds on.
- `tools/nvme-hw-smoke.md` — R24.M6 (#908) NVMe HW witness; VMD-off
  BIOS posture reused verbatim by §1.2 above.
- `tools/run-smoke-hw.sh` — R28.M2 (#1002) serial-fingerprint
  verifier; no dedicated mode for this witness yet (see §3).
- `tools/hw-smoke-r47-vmd.md` — sibling UNSEEDED recipe for the R47
  VMD-on posture; this file follows the same promotion discipline.
