# PdxFS-lite end-to-end R/W across reboot smoke

**Owner issue:** #937 (R25.M7-001, `gated:hardware` + `gated:substrate`).
**Prereqs to run:**
- T14 G4 (or any UEFI x86_64 machine with a scratch NVMe drive), OR a
  QEMU host with an NVMe drive image (`-drive if=none,file=disk.img,format=raw
  -device nvme`).
- A **scratch** NVMe drive / image (all sectors are overwritten during
  mkfs and the write-persistence step — do not use a drive that holds
  anything you want to keep).
**Status:** Harness landable at R25 close; **live end-to-end run gated
on the substrate items called out in §0.1 below** (all pieces exist in
isolation; the wire that threads them together is R26+).

---

## 0. Scope

This document is the operator-run recipe that promotes the PdxFS-lite
substrate landed across R25 (M1–M6) from a QEMU-TCG structural witness
to a real-hardware acceptance witness on either QEMU-with-NVMe or the
T14 G4. It is the sibling of `tools/nvme-hw-smoke.md` (R24.M6, #908) —
one level up the stack: R24 proved the NVMe controller can be
identified + read from + written to under GDB; R25 proves the
PdxFS-lite superblock + inode table + extent map can be materialised
on disk by `mkfs.pdxfs-lite`, mounted from the running kernel, walked
by `ls`, read by `cat`, WRITTEN to (**#906 unblock**), unmounted +
rebooted, and re-read to prove persistence across the boot boundary.

### 0.1 Substrate wire this promotes

The live pipeline this smoke exercises threads these R24 + R25 pieces:

- **R22** PCIe enumeration finds a class `01/08 prog-if 02` device on
  the root bus.
- **R24.M1** `nvme_probe` records the controller in `_nvme_devices`.
- **R24.M2** admin queues bring up + `nvme_identify_ctrl` +
  `nvme_identify_ns` populate `_nvme_id_ctrl_buf`, `_nvme_lba_size`,
  `_nvme_ns_blocks`.
- **R24.M3** per-CPU IO queues get created.
- **R24.M4** PRP encoding + DMA allocator + MDTS clamp.
- **R24.M5** `nvme_read_blocking` (landed) — read paths live.
- **R24 debt #906** `nvme_write_blocking` (**NOT yet landed** —
  kernel-side sibling of `nvme_read_blocking` with `OPC = 0x01`).
- **R25.M1** `pdxfs_lite_read_superblock` + `sb_validate` — mount-time
  superblock read and structural verify.
- **R25.M2** inode + inline-extent walker — `get_inode` + directory
  walker + extent read helpers.
- **R25.M3** `mkfs.pdxfs-lite` host tool — materialises a valid v0
  image against a raw block device or a raw image file.
- **R25.M4** VFS wire-up — `pdxfs_lite_mount` publishes the root
  vnode; `pdxfs_lite_ops` table exposes `open` / `read` / `readdir`
  through the R16 VFS surface.
- **R25.M5** ML-DSA-65 sig-verify substrate — dev-mode-bypass at
  R25.M5 (per `design/filesystem/pdxfs-lite-format.md` §5.4); real
  verify lands at R32.
- **R25.M6** CREATE / UNLINK / RENAME return `EROFS` at MVP (per
  #933/#934/#935 module headers). Write persistence lands with
  `nvme_write_blocking` (**#906 kernel-side sibling**) plus a
  `commit_dirty_metadata` pass that stamps the modified inode + dirent
  block + extent-map bitmap back to disk. Both of these are the
  substrate items §0.1 calls out as gates.

### 0.2 What this smoke IS NOT

- **Not a regression check on QEMU `-kernel`.** Under `-kernel`, the
  QEMU q35 machine surfaces no MCFG, so `nvme_probe` returns 0,
  `pdxfs_lite_mount` never runs, and the witness takes its SKIP
  branch. The R25.M6 SKIP-echo pre-push opt-in
  (`PAIDEIA_R25_PDXFS_E2E=1 boot_r25_pdxfs_e2e`) documents this as a
  substrate probe, not a live pipeline test.
- **Not a benchmark.** The R28 MVP-demo round adds a throughput row
  (`iops`, `MB/s`, `p99 latency`); R25 close only cares about
  binary correctness (bytes read after reboot match bytes written
  before it).
- **Not a fuzz harness.** Corruption at every level (bit-flip in
  sig, bit-flip in inode, bit-flip in extent) is tested per-layer by
  R25.M5's `pdxfs_lite_corrupt_sb_witness` and by the R32 crypto
  round; the E2E smoke assumes an honest disk.

---

## 1. Preflight

### 1.1 Kernel build

Build the paideia-os kernel per `BUILDING.md`. Confirm the pre-push
matrix passes clean on the host that produces the image:

```
bash tools/build.sh                   # 15/15 gates
bash .githooks/pre-push               # 15 default modes + any opt-ins
```

The build produces `build/kernel.elf` linked with every R24 + R25
symbol present. Verify the R25 pieces:

```
nm build/kernel.elf | grep -E \
    'pdxfs_lite_read_superblock|pdxfs_lite_mount|pdxfs_lite_read|pdxfs_lite_e2e_witness'
```

### 1.2 Materialise a PdxFS-lite image

Use the R25.M3 host tool at `tools/mkfs-pdxfs-lite.sh` (or the
paideia-native `mkfs.pdxfs-lite` binary once it lands per #921) to
create a valid v0 image on a raw file:

```
truncate -s 128M /tmp/pdxfs-lite.img
tools/mkfs-pdxfs-lite.sh /tmp/pdxfs-lite.img \
    --label=paideia-r25 \
    --seed-file=README.md         # optional seed content, becomes /README
```

For real hardware, replace `/tmp/pdxfs-lite.img` with the block device
node (`/dev/nvme0n1` — VERIFY THIS IS THE SCRATCH DRIVE; getting it
wrong destroys data).

### 1.3 Boot media

For a QEMU acceptance pass:

```
qemu-system-x86_64 \
    -kernel build/kernel.elf \
    -drive if=none,id=nvme0,file=/tmp/pdxfs-lite.img,format=raw \
    -device nvme,drive=nvme0,serial=paideia-r25 \
    -serial file:/tmp/pdxfs-lite-boot1.log \
    -m 128M \
    -no-reboot -no-shutdown \
    -display none
```

For T14 G4 real hardware: prepare the R19 UEFI ESP boot media per
`design/roadmap/r19-t14-g4-boot-guide.md`; ensure BIOS Intel VMD
Controller = **Disabled** per `tools/nvme-hw-smoke.md §1.2.1`.

---

## 2. Live run — first boot (write phase)

### 2.1 Boot and confirm probe + mount

Power on / launch QEMU. Watch either COM1 or the framebuffer console.
Expected fingerprints in order:

```
X2APIC ENABLED BSP                # R22 xAPIC retirement
MCFG PRESENT ...                  # R22 PCIe substrate
PCI ENUM DONE devices=N           # R22 enumerator drain
NVME PROBE N=1                    # <-- R24.M1 target
PDXFS_MOUNT uuid=... itable=...   # <-- R25.M4 target (via pdxfs_lite_mount)
PDXFS E2E BEGIN                   # R25.M7 witness entry
```

If the last line is `PDXFS E2E SKIP not mounted`, the driver-attach
path did not thread probe → identify → io_queues → mount. That is
expected under `-kernel` today; on the real-HW UEFI path it means
the R25.M6 debt item ("driver-attach ceremony not yet wired into
`kernel_main_uefi`") has not been closed yet.

### 2.2 Shell interaction — write phase

After the shell prompt appears (R17 substrate), issue:

```
$ ls /
README
$ cat /README
# paideia-os
[... file contents ...]
$ echo "R25 write-persistence probe" > /r25-probe.txt
$ cat /r25-probe.txt
R25 write-persistence probe
$ sync                    # forces commit_dirty_metadata + nvme_write_blocking flush
$ shutdown                # or ACPI power-off via #639's shutdown wire
```

Confirm on the framebuffer / COM1 log:

```
PDXFS_WRITE ino=... bytes=28 lba=... status=0     # nvme_write_blocking OK
PDXFS_META_COMMIT ino=... blk=...                 # dirty inode + dirent flushed
```

### 2.3 Fault tags to watch for

If any of these appear during the write phase, the run failed; capture
the log and file against the debt item:

```
PDXFS WRITE FAIL ino=... status=<n>       # nvme_write_blocking returned non-zero
PDXFS META COMMIT FAIL                     # extent bitmap or inode block flush failed
NVME FAULT csts=<n>                        # controller CFS trip
```

---

## 3. Reboot and read phase

### 3.1 Power-cycle (QEMU) or full reset (T14 G4)

Do NOT re-invoke `mkfs.pdxfs-lite`. The image file / block device MUST
carry over the writes from §2 for the read phase to be meaningful.

Reboot into the same kernel image against the same drive:

```
qemu-system-x86_64 \
    -kernel build/kernel.elf \
    -drive if=none,id=nvme0,file=/tmp/pdxfs-lite.img,format=raw \
    -device nvme,drive=nvme0,serial=paideia-r25 \
    -serial file:/tmp/pdxfs-lite-boot2.log \
    -m 128M \
    -no-reboot -no-shutdown \
    -display none
```

### 3.2 Shell interaction — read phase

After `PDXFS_MOUNT` fires again, issue:

```
$ ls /
README
r25-probe.txt
$ cat /r25-probe.txt
R25 write-persistence probe
```

If the second command's output matches the string written in §2.2,
**PdxFS-lite persistence works end-to-end**. Promote the quirks-db
rows in §4.

If `r25-probe.txt` is missing from `ls`, the write completed but the
directory-entry commit didn't flush (parent dirent block dirty, never
written). File against R25.M6 debt "directory entry commit path".

If `r25-probe.txt` is in `ls` but `cat` shows garbage or an empty file,
the inode block committed but the extent-map bitmap did not flush.
File against R25.M6 debt "extent-map commit path".

---

## 4. Quirks-db promotion pass

After a clean §3.2 run on real T14 G4 hardware:

1. **`design/hardware/quirks.md §2.4` VMD row.** If not already
   promoted by `tools/nvme-hw-smoke.md §3`, promote status
   `PROVISIONAL → CONFIRMED` here. Cite git SHA + drive
   manufacturer/model.
2. **New rows discovered.** Any behavior that surprised the operator:
   - Persistence across reboot dropped bytes (rare but documented for
     some consumer NVMe firmwares).
   - LBA size drift between mkfs (typically 512 B / 4096 B) and
     mount-observed `_nvme_lba_size`.
   - Write-cache flushing quirks — some Samsung / WD Blue drives need
     `nvme flush` or an explicit `EnableWriteCache=0` at Identify time
     for the sync to actually reach persistent media.

---

## 5. Wire-up posture at R25.M7 close

The `pdxfs_lite_e2e_witness` symbol at
`tests/kernel/fs/pdxfs_lite_e2e_witness.pdx` is:

- **Linked** into `build/kernel.elf` (verify via `nm`).
- **Not wired** into `kernel_main` — same posture as
  `pdxfs_lite_corrupt_sb_witness` (R25.M5, #931),
  `concurrent_io_witness` (R24.M6, #909),
  `msix_ir_round_robin_witness` (R22.M6, #869).
- **Callable under GDB** on the real-HW UEFI path (§2 uses `call
  pdxfs_lite_e2e_witness()` after the shell prompt appears).
- **Emits a SKIP fingerprint** under QEMU-TCG `-kernel` because
  `pdxfs_lite_is_mounted()` returns 0 (mount was never invoked — no
  NVMe controller, no driver attach).

The R25.M7 acceptance surface is symbol existence + link verification
+ the SKIP-echo opt-in smoke (`PAIDEIA_R25_PDXFS_E2E=1
boot_r25_pdxfs_e2e`). Live end-to-end promotion — the actual first
successful reboot-persistence run — is queued for R26+ hardware
bring-up alongside the R23 first-visual-output moment and the R24
first-NVMe-touch moment (which also have not fired).

---

## 6. Cross-references

- `src/kernel/core/fs/pdxfs_lite/mount.pdx` — R25.M1 superblock read.
- `src/kernel/core/fs/pdxfs_lite/mount_op.pdx` — R25.M4 mount +
  sig-verify gate.
- `src/kernel/core/fs/pdxfs_lite/vops.pdx` — `_pdxfs_lite_mount_ctx`.
- `src/kernel/core/fs/pdxfs_lite/read.pdx` — R25.M2 file-read path.
- `src/kernel/core/fs/pdxfs_lite/create.pdx` — R25.M6 CREATE (returns
  EROFS until #906 unblock).
- `tools/mkfs-pdxfs-lite.sh` — R25.M3 host tool.
- `tools/nvme-hw-smoke.md` — R24.M6 sibling recipe (level below).
- `tests/kernel/fs/pdxfs_lite_e2e_witness.pdx` — this smoke's witness
  symbol.
- `design/filesystem/pdxfs-lite-format.md` — v0 on-disk format spec.
- `design/round-retrospectives/r25-closure.md` — R25 debt ledger
  including the #906 unblock chain that gates §2.2 write phase.

---

*Landed 2026-08-11 at R25.M7 (#937). Live end-to-end run pending #906
kernel-side `nvme_write_blocking` + driver-attach wire-up in
`kernel_main_uefi`.*
