# R53 — Volume Lifecycle Mechanism (osarch half: QEMU wiring + kernel-side mount)

**Status.**  Draft v0.1 — HW+kernel half of the R53 planning wave (2026-08-22).
**Companion (parallel).**  softarch's user-facing tooling design (`mkfs.pdxfs`,
`mount.pdxfs`, semantic-pipe integration) — same round, extends this
document at §5 (mount syscall shape) and §10 (coordination points).
Overlap surface is deliberately narrow: the on-disk format is frozen in
R52 (`design/filesystem/volume-fs-substrate.md` §2) and this document
does not restate it; the mount syscall ordinals are agreed here and
consumed by softarch's `mount.pdxfs` tool.
**Depends on.**
- R42 PdxFS v1 scaffolds at `src/kernel/core/fs/pdxfs/*` (WAL, CoW,
  snapshot walker) — the layer this round wires to a real block device.
- R48b `KIND_PDXFS_FILE = 0x195`, `KIND_PDXFS_TXN = 0x196` (`kind.pdx`) —
  the caps R52.M6 turns from STUB into real journaled mutations.
- R51 unified block-device substrate (`design/hardware/nvme-and-disk-substrate.md`)
  — `KIND_BLKDEV = 0x42` retained as `KIND_BLOCK_DEVICE`, extended tail,
  new families NVMe/AHCI, ops `BDEV_OP_READ_LBA` / `WRITE_LBA` / `FLUSH`
  / `TRIM` / `QUERY_GEOM` / `QUERY_FAMILY` / `QUERY_FEATURES`.  Also new
  KINDs: `KIND_NVME_CONTROLLER = 0x198`, `KIND_NVME_NAMESPACE = 0x199`,
  `KIND_AHCI_CONTROLLER = 0x19A`, `KIND_AHCI_PORT = 0x19B`.
- R52 volume-fs substrate (`design/filesystem/volume-fs-substrate.md`)
  — PDXB superblock at LBA 0 (magic `0x42584450`), inode table,
  bitmap allocator, on-disk journal (JBNL blocks), block cache, four
  new KINDs `KIND_VOLUME = 0x1A0`, `KIND_BLOCK_CACHE = 0x1A1`,
  `KIND_INODE_HANDLE = 0x1A2`, `KIND_SIG_KEY = 0x1A3`.
- R16.M1 mount table at `src/kernel/core/fs/mount.pdx` — 8-slot static
  table, backend discriminants 1..4, TMPFS is the sole live backend
  today.  R52.M5 adds `MOUNT_BACKEND_PDXFS_BLOCK = 5`; R53 wires the
  boot-time volume-probe + mount into it.
- Current syscall ceiling at `src/kernel/core/syscall/dispatch.pdx`:
  `cmp rdi, 72; ja dispatch_enosys` (sysno 72 = `sys_pdxfs_dir_readnext`,
  R42-PREP-008 #1630).  R53 extends the ceiling to 74.
- `tools/run-smoke.sh` — 60+ smoke modes, all currently `-kernel`-boot
  with no `-drive` attachments.  R53.M4 adds a `--with-disk` variant.
- `tools/build.sh` — kernel-only build today; no fresh-image bootstrap
  step lands until R53.M1.

**Scope of this doc.**  §1–§10 as scoped in the round brief.  The
symmetric split with softarch:

| Concern | Owned by |
|:--------|:---------|
| QEMU CLI shape (drive/device flags, image path, size, block size)     | osarch (§2)  |
| Fresh-image bootstrapping (host-side vs kernel-side vs userspace)     | osarch (§3), primary path softarch owns tool (§10) |
| Boot-time volume probe + handoff record + root selection              | osarch (§4)  |
| `sys_mount` / `sys_umount` syscall ordinals + mint-gate + rights      | osarch (§5), softarch consumes ordinals |
| Extension of R16 mount_table for a block-backed backend               | osarch (§6)  |
| `run-smoke.sh --with-disk` flag + first round-trip golden             | osarch (§7)  |
| Kernel-side failure modes + audit fingerprints                        | osarch (§8)  |
| Milestone breakdown for the HW+kernel half                            | osarch (§9)  |
| Handshakes with softarch (mkfs.pdxfs, mount.pdxfs, cap-rights model)  | shared (§10) |
| Userspace `mkfs.pdxfs` / `mount.pdxfs` internals + semantic pipe wiring | softarch (parallel doc — not restated here) |

Everything below the syscall boundary is HW/kernel; everything above
(the tool binaries, their CLI, their exit-code posture, their
semantic-terminal cap-narrowing) is softarch's.

---

## 0. Reading order

- §1 relationship to R51/R52; the shape of the "green build → mounted
  volume" chain; first-boot vs re-boot flow diagrams.
- §2 QEMU device model — the two supported topologies (NVMe first,
  AHCI second), image location, size, block size, persistence rules,
  coexistence with the existing ramdisk boot.
- §3 fresh-image bootstrapping — three paths (Path A host pre-format,
  Path B kernel in-place mkfs, Path C userspace mkfs from rescue).
  Recommendation matrix.
- §4 boot-time volume-probe + mount — where it fires in the boot
  sequence, root selection, handoff extension, no-valid-volume fallback.
- §5 kernel-side mount syscall — `sys_mount` / `sys_umount` (sysnos 73
  / 74), rights model, dispatch wiring, bounds-check update.
- §6 mount_table extension — `mount_kind` byte, backend-dispatch
  arm, coexistence with R16 tmpfs backend.
- §7 `run-smoke.sh --with-disk` — image lifecycle, fingerprint
  additions, round-trip smoke (write → umount → remount → read-back).
- §8 failure modes + recovery — superblock-invalid, WAL-corruption,
  disk-unplug mid-run, ENOSPC.  Audit-event fingerprints.
- §9 R53 milestone breakdown — M1..M5, one commit-scale chunk each,
  4–6 issue titles per milestone.
- §10 softarch coordination points — ordinals, rights model, CLI
  shape agreements.

---

## 1. Scope + relationship to R51 / R52

### 1.1 The chain we are closing

R51 delivered the block-device substrate: NVMe namespace / AHCI port
minted as `KIND_BLOCK_DEVICE`, DMA-attested, dispatchable via
`BDEV_OP_*`.  R52 delivered the on-disk format and the walker that
mutates it: PDXB superblock, JBNL journal, CoW blocks, mount-table
discriminant `MOUNT_BACKEND_PDXFS_BLOCK = 5`.

R53 is the missing wire: **given a green build, how does the developer
reach a mounted, writable, persistent PdxFS-on-block volume under
QEMU?**  Every prior smoke mode boots off a ramdisk; every mutation
is discarded on reboot.  R53 makes "reboot preserves state" a routine
observation.

### 1.2 First-boot vs re-boot flow

**First-boot.**  The developer runs `tools/build.sh` (green kernel).
`tools/run-smoke.sh --with-disk` (R53.M4) then:

1. Notices `tests/qemu/disks/pdxb-root.img` is absent.
2. Invokes `tools/mkfs-pdxb.sh` (R53.M1) which runs a host-side
   `mkfs-pdxb` binary compiled from paideia-as source (Path A, §3.1).
   Output: a 128 MiB raw image with a valid PDXB superblock, empty
   allocator bitmap, empty journal (checkpoint = `journal_lba`), root
   inode 1 initialised as an empty directory.
3. Launches QEMU with `-drive file=...img,if=none,id=nvme0,format=raw
   -device nvme,drive=nvme0,serial=PDXB0001,logical_block_size=4096,physical_block_size=4096`
   in addition to `-kernel <build/kernel.elf>`.
4. Kernel boots.  After paging + IOMMU + PCI enumeration + R51 NVMe
   driver bring-up, the volume-probe module (R53.M3) reads block 0
   of every `KIND_BLOCK_DEVICE`, recognises the PDXB magic, mints a
   `KIND_VOLUME` cap, installs it in mount slot 0 as root.
5. Fingerprint emitted: `PDXB VOLUME MOUNTED uuid=<hex> slot=0`.

**Re-boot.**  The image file survives.  Steps 1 and 2 are skipped;
step 3 attaches the same image; step 4 finds a non-empty superblock
whose `clean_unmount` flag (§8.2) is set — probe is fast, WAL replay
is a no-op, mount reaches slot 0 as before.  If any content was
mutated in the previous boot and committed, it is observable now.

### 1.3 Constraints inherited from R51/R52

- **Ordinals are settled.**  This round allocates no new derived-kind
  ordinals.  It consumes `KIND_VOLUME`, `KIND_BLOCK_DEVICE`,
  `KIND_SIG_KEY` and does not touch the 0x1A4..0x1AF reserved band.
- **The on-disk format is settled.**  A change to superblock,
  inode-table, or journal layout requires a superblock `version` bump
  and lives in R52-follow-up, not here.  R53 owns the *lifecycle*, not
  the *format*.
- **The block-device wire is settled.**  R53 issues `BDEV_OP_*` but
  does not redesign them; a family-blind FS-side caller is the
  invariant R51 §4.5 pinned.

### 1.4 Explicitly NOT in R53

- **Multi-volume mount via userspace `sys_mount`.**  R52 mounts root
  only (via boot-time probe).  R53 introduces `sys_mount` (§5) but
  the M4 smoke only exercises root; non-root userspace mounts are a
  soft-launch item and gain a golden line only if it fits in M4-M5's
  scope.
- **BIOS / UEFI boot from the volume.**  The kernel is still loaded
  by `-kernel` (multiboot-ish path).  Booting off the PDXB volume
  itself is R54+ (needs a `KIND_LOADER_IMAGE` and a signed loader
  chain that the R11 bootloader does not yet own).
- **AHCI attach in the smoke matrix.**  §2.2 documents the AHCI CLI
  shape but the M4 smoke uses NVMe only — R51 has both drivers but
  smoke-time attention is best spent on one; AHCI parity is a
  witness-add for R54.
- **`mount.pdxfs` semantic pipe.**  Owned entirely by softarch's
  parallel doc; this document only guarantees that `sys_mount`
  returns a mount_id shape softarch can plumb through.
- **Snapshot-persistence smoke.**  R52 §7 kept snapshot-region
  wire-through for R53-later; this document's M1..M5 does not
  touch it.

---

## 2. QEMU device model

### 2.1 NVMe topology (primary)

**Fresh CLI additions** (concatenated with the current `-kernel`
launch, see `run-smoke.sh:1120`):

```
-drive file=tests/qemu/disks/pdxb-root.img,if=none,id=nvme0,format=raw \
-device nvme,drive=nvme0,serial=PDXB0001,logical_block_size=4096,physical_block_size=4096
```

Rationale for the flags, one per line:

- `if=none` decouples the drive from any bus so we can attach it
  explicitly to the `nvme` device (QEMU otherwise defaults it to
  IDE — wrong wire).
- `format=raw` — no qcow2 metadata; the image is a straight byte
  array.  Makes host-side `mkfs-pdxb` a plain-file writer.
- `serial=PDXB0001` — a stable serial the kernel logs at probe;
  greppable in smoke output.  Deterministic across boots.
- `logical_block_size=4096` — matches PDXB block size (R52 §2.6).
  Removes the 512-B translation the QEMU NVMe device would otherwise
  do.  The R51 driver reports this via `BDEV_OP_QUERY_GEOM` and the
  R52 mount refuses if the value differs from 4096.
- `physical_block_size=4096` — advertises 4K native; some FS-layer
  alignment heuristics (R52 §5.3 write-back) key off this.

**Image location.** `tests/qemu/disks/pdxb-root.img` — a new
directory under `tests/qemu/disks/`.  Added to `.gitignore` (never
committed; the image is regenerated deterministically by mkfs and
its content is boot-derivable).  The directory itself carries a
`.gitkeep` so `tools/mkfs-pdxb.sh` can `install -d` into a fresh
clone without a mkdir dance.

**Default size.**  **128 MiB.**  Sizing math:

- Superblock: 1 block = 4 KiB.
- Bitmap: 128 MiB / 4 KiB = 32K blocks → 32K bits = 4 KiB = 1 block.
- Journal: R52 default `journal_bcount = 1024` = 4 MiB = 1024 blocks.
- Inode table: default ratio `data_bcount / 256` (R52 §2.3) →
  `~32K / 256 = 128` inodes at absolute minimum, but the mkfs picks
  a floor of 8192 inodes → 256 blocks = 1 MiB.
- Data region: remainder ≈ 122 MiB → 31232 blocks.

Small enough to git-ignore, small enough for `mkfs` to finish in
under 100 ms on any dev host, small enough for a fresh QEMU snapshot
to fit in tmpfs.  Large enough for R49's `pkg install` self-test
(a few MB of source files) plus a comfortable margin for R50's
`cp` / `mv` witnesses.

**Environment override.**  `PDXB_IMAGE_SIZE_MIB` env var, honored
by `mkfs-pdxb.sh` — a developer working on the allocator can bump
to 1 GiB without editing the script.  Default remains 128.

**Block size.**  Fixed at 4096.  Not configurable at R53.  A future
round exploring 16 KiB blocks (for larger allocators) can revisit.

**Persistence.**  The `.img` file is a plain host file; QEMU mutates
it in-place unless `-snapshot` is passed.  `run-smoke.sh --with-disk`
does NOT pass `-snapshot` — the round-trip test requires mutations to
survive across `qemu` invocations.  A `--with-disk-ephemeral` variant
(passes `-snapshot`) is deferred; not needed for M4.

**Coexistence with ramdisk boot.**  The current kernel loads via
`-kernel`, uses a tmpfs-seeded root, and never touches a block
device.  R53 does not change that path.  When `--with-disk` is off,
the smoke behaves identically to today (no `-drive` attached, no
volume probed, tmpfs stays root).  When `--with-disk` is on, the
disk is an **additional** device: kernel still boots via `-kernel`,
tmpfs is still initialised, but the volume-probe (§4) discovers the
PDXB volume and re-parents the root over to it.  R54+ removes the
tmpfs fallback once the volume path is proven.

### 2.2 AHCI topology (secondary; documented, not smoke-wired at M4)

For completeness — the R51 AHCI driver is real and softarch's tests
may want to exercise both wire families:

```
-drive file=tests/qemu/disks/pdxb-ahci.img,if=none,id=ahci_hd0,format=raw \
-device ahci,id=ahci_ctl \
-device ide-hd,drive=ahci_hd0,bus=ahci_ctl.0,logical_block_size=4096,physical_block_size=4096
```

The three-step incantation (`if=none` + AHCI controller +
`ide-hd` bound to it) is what QEMU wants; a single `-drive
if=ahci,...` also works but leaves the AHCI controller nameless
which makes multi-port testing harder.  R53.M4 uses NVMe only; AHCI
parity is a witness-add tracked separately (see §9.M5-005).

**Multi-controller / multi-namespace tests.**  Both NVMe and AHCI
topologies compose — a smoke could attach one NVMe controller with
two namespaces and one AHCI controller with one port, giving three
`KIND_BLOCK_DEVICE` caps for probe-order testing.  Deferred to R54.

### 2.3 Persistence + `run-smoke.sh` semantics

Three cases the smoke runner distinguishes:

| Invocation                                             | Image existence | Behavior |
|:-------------------------------------------------------|:----------------|:---------|
| `run-smoke.sh --with-disk boot_r53_first_mount`        | absent          | mkfs → boot → assert mount fingerprint |
| `run-smoke.sh --with-disk boot_r53_first_mount`        | present         | boot only → assert mount fingerprint (re-boot path) |
| `run-smoke.sh --with-disk --wipe boot_r53_first_mount` | any             | delete image → mkfs → boot → assert |
| `run-smoke.sh --with-disk boot_r53_round_trip`         | any             | wipe → mkfs → boot → write file → clean umount → reboot → read file back → assert |

The `--wipe` flag exists to break stale-image debug sessions
without hand-deleting.  `boot_r53_round_trip` (M4) is the golden
that proves the closure.

---

## 3. Fresh-image bootstrapping — three paths

The question: *where does the first valid PDXB superblock come from?*
There are three candidate answers and R53 lands one as primary and
one as long-term production; the third is deliberately documented as
an anti-pattern.

### 3.1 Path A — Host-side pre-format (recommended primary for R53)

**Shape.**  `tools/mkfs-pdxb.sh` runs on the Linux dev host.  It
compiles (or, more likely, reuses a pre-built) `build/mkfs-pdxb`
binary from paideia-as source under `src/tools/mkfs-pdxb/` and
invokes it on a plain file:

```
build/mkfs-pdxb --file tests/qemu/disks/pdxb-root.img \
                --size-mib 128 \
                --uuid <deterministic-from-hash-of-repo-HEAD> \
                --sig-key tests/qemu/keys/pdxb-dev.mldsa65.priv \
                --set-root-flag
```

The binary opens the file, writes the four regions, signs the
superblock, closes.  Zero kernel involvement; zero QEMU
involvement; the image is byte-identical for a given
`(size, uuid, key)` triple.

**Why this is the R53 primary path.**

1. **Deterministic + checkable.**  A given repo state produces a
   byte-identical image.  The image hash can be committed to a
   golden file if we want to prove `mkfs` regressions.  Reproducible
   builds discipline.
2. **The kernel never runs mkfs.**  A blank-disk detection path in
   the kernel is a permanent security hazard: a device that gets
   its superblock zeroed (by a stray write, a controller firmware
   bug, or an attacker) would be re-formatted on next boot,
   silently destroying content.  Path A never has that failure
   mode.
3. **The tool is testable in isolation.**  `mkfs-pdxb` reads and
   writes a plain file — softarch can host-side unit-test it with
   a Python `struct.unpack` harness against the R52 §2.1 layout;
   no QEMU cycle needed.
4. **paideia-as coverage.**  Compiling a userspace binary from
   paideia-as source is precedent that the workspace already
   supports (R48+ has tools under `src/tools/`).  A new tool folder
   is not a substrate change; it is just a new build target.

**Cost.**

- The paideia-as `mkfs-pdxb` binary needs the ML-DSA-65 sign
  intrinsic (R52 §8.1 flagged this as a paideia-as blocker).  Until
  that lands, `mkfs-pdxb` writes a zero superblock signature and
  a `SIG_UNSIGNED` flag; the kernel accepts it under
  `PAIDEIA_DEV_UNSIGNED_ACCEPT=1` and rejects otherwise.  This is
  the tightest cross-repo dependency in R53.
- The image is host-artefact; a developer on macOS runs the same
  tool.  Cross-compiling paideia-as for macOS is out of scope; the
  fallback is a container.  This is a real ergonomic cost the
  primary developer (on Linux) does not see.

### 3.2 Path B — Kernel-side in-place mkfs (documented anti-pattern)

**Shape.**  Kernel boots, probe reads block 0 of a `KIND_BLOCK_DEVICE`,
observes the magic is absent, invokes an in-kernel
`pdxfs_mkfs_inplace(bdev_cap)` primitive that writes a fresh layout.

**Why NOT this for R53.**

- **Data-loss footgun.**  Any device whose superblock is unreadable
  (torn write, controller reset amnesia, honestly-blank spare disk
  the user attached) gets reformatted.  The security posture of
  the whole substrate collapses.
- **Attestation loop.**  `KIND_DMA_ATTESTATION` (R51 §5.4) requires
  a founder-user consent dialog before a bus-mastering device's
  cap is minted; mkfs-in-kernel would need to defer until that
  dialog completes, which means the kernel would need to wait for
  ring-3 to consent to write to a device the kernel already
  decided was uninteresting — the wrong ordering.
- **Signature material.**  A kernel-side mkfs would need to sign the
  superblock with the ML-DSA-65 private key; putting a private
  signing key in kernel space is the exact class of trust
  concentration the R48/R51 design explicitly avoids.

The primitive `pdxfs_mkfs_inplace` is NOT landed in R53.  Any future
proposal to add it must cite this section and explain what forecloses
the three failure modes above.

### 3.3 Path C — Userspace `mkfs.pdxfs` from a rescue initramfs (long-term production)

**Shape.**  Boot into a minimal rescue environment (existing
tmpfs-seeded shell over `/bin/sh` — R17 substrate).  User runs
`mkfs.pdxfs /dev/nvme0n1` (a softarch tool from R52.M2).  Kernel
opens the device via `KIND_BLOCK_DEVICE`, mkfs writes through the
device cap.

**Why this is the R54+ production path, not R53.**

- The rescue-initramfs shape needs `/dev` entries backed by
  `KIND_BLOCK_DEVICE` caps.  R51 delivers the cap; R53 does not
  wire it into a `/dev/nvme0n1`-style vnode surface.  `mount.pdxfs`
  in R52 sidesteps this by taking a cap slot number directly; a
  humane end-user `mkfs.pdxfs /dev/nvme0n1` requires a devfs
  extension that is out of R53 scope.
- The signing key is not in the rescue environment yet.  The dev
  key at `tests/qemu/keys/pdxb-dev.mldsa65.*` is a repo artefact
  used only by Path A; a production `mkfs.pdxfs` would need to
  prompt for or resolve a key from `KIND_SIG_KEY` chain — R55+.
- The R53 smoke round-trip needs a deterministic starting state;
  Path C would need the rescue environment to be scriptable
  enough for CI, which is more infrastructure than the smoke
  gains from it.

softarch's `mkfs.pdxfs` tool (R52.M2-003) is Path C's real
implementation; the R53.M1 `mkfs-pdxb` host binary is the same
logic packaged for Path A.  Sharing the core is §10.3.

### 3.4 Recommendation matrix

| Concern                     | Path A (host)   | Path B (kernel)     | Path C (userspace)  |
|:----------------------------|:----------------|:--------------------|:--------------------|
| R53.M1 primary              | **YES**         | no (anti-pattern)   | no (not until R54)  |
| Deterministic image         | yes             | no (kernel-varied)  | yes                 |
| Safe on real hardware       | yes             | **no** (data-loss)  | yes (with prompt)   |
| Needs paideia-as ML-DSA sign | at build time  | at kernel-boot      | at rescue-boot      |
| CI-friendly                 | yes             | possible            | possible (heavier)  |
| Long-term production        | dev tool only   | never               | **yes**             |

R53 lands Path A; R54+ shares the core with Path C's tool.  Path B
stays a documented refusal.

---

## 4. Boot-time volume-probe + mount

### 4.1 Where in the boot sequence

The kernel boot order today (`src/kernel/boot/kernel_main.pdx`,
paraphrased):

```
long_mode + gdt + idt + pagetables            [entry.pdx / boot/*]
zero_bss                                       [zero_bss.pdx]
uart_init + banner                             [banner.pdx]
paging_init (per-CPU + higher-half)            [R14B]
smp_bringup (BSP + 3 APs)                      [R18.M1]
acpi_gather + ioapic + lapic_timer             [R21]
pci_enumerate                                  [R22 gated on MCFG]
iommu_init (Features.IOMMU_ENABLED)            [R22.M6+]
nvme_probe + ahci_probe                        [R51.M1..M6]
r20b_ipc_witness chain                         [R20b]
r29_chaos_witness                              [R29]
r31_spawn_pair witness                         [R31]
tmpfs_init + vnode_pool + mount(BOOTSTRAP)     [R16.M1]
elf_lite_load(init) + init handoff             [R17.M0]
sti + return to init                           [R17]
```

The R53 volume-probe fires between `iommu_init`-plus-`nvme_probe`
(which produces `KIND_BLOCK_DEVICE` caps) and `tmpfs_init` (which
sets slot 0 to a tmpfs root).  Concretely, a new call
`pdxb_volume_probe_all_bdev()` slots in after nvme/ahci probes and
before mount_bootstrap.  If probe finds a valid PDXB volume, mount
bootstrap uses `MOUNT_BACKEND_PDXFS_BLOCK` for slot 0 with the
probed root inode; if it finds none, mount bootstrap falls back to
tmpfs and a fingerprint records "no PDXB volume found — tmpfs
fallback".

### 4.2 Probe algorithm

Per `KIND_BLOCK_DEVICE` cap the R51 driver family has minted:

1. Issue `BDEV_OP_QUERY_GEOM` → learn `(lba_size, block_count)`.
2. If `lba_size != 4096`, skip (PDXB v1 requires 4K).  Emit chatter
   `PDXB PROBE SKIP lba_size=<n> dev=<slot>`.
3. Allocate a 4 KiB DMA-safe buffer from the driver's
   `KIND_DMA_DOMAIN` (R29.M5) region.
4. Issue `BDEV_OP_READ_LBA(0, 1, buf_iova)`.  If it fails with
   any error, skip with chatter `PDXB PROBE READ_ERR err=<code>
   dev=<slot>`.
5. Parse magic at buf+0.  If `!= 0x42584450`, skip with chatter
   `PDXB PROBE BAD_MAGIC dev=<slot>` (this is the common
   "not-a-pdxb-device" case, not an error).
6. Parse `version`.  If `!= 1`, skip with chatter `PDXB PROBE
   BAD_VERSION version=<n> dev=<slot>`.
7. Parse `block_size`.  If `!= 4096`, skip with `PDXB PROBE
   BAD_BLOCK_SIZE bs=<n> dev=<slot>`.
8. Verify the superblock signature.  If `PAIDEIA_DEV_UNSIGNED_ACCEPT`
   is unset AND the superblock has SIG_UNSIGNED flag, skip with
   `PDXB PROBE UNSIGNED_REFUSED dev=<slot>`.  If the signature is
   present but does not verify against `KIND_SIG_KEY.key_hash`,
   skip with `PDXB PROBE SIG_MISMATCH dev=<slot>` — this is an
   audit-eventful failure (§8.1).
9. Parse the region descriptors (`itable_lba`, `alloc_lba`,
   `journal_lba`, `data_lba` and their `_bcount` siblings).  If
   any region overflows `block_count`, skip with `PDXB PROBE
   BAD_LAYOUT dev=<slot>` — also audit-eventful.
10. Mint a `KIND_VOLUME` row via `kind_volume_mint(dev_cap_slot,
    superblock_summary)`.  Add to `_pdxfs_volume_table`.
11. Emit fingerprint `PDXB PROBE OK uuid=<hex> dev=<slot>
    root_flag=<0|1>`.

The probe module lives at `src/kernel/core/fs/pdxfs/probe.pdx`
(named in R52 §7.5, landed at R52.M5-004).  R53.M3 wires it into
the boot sequence — the module exists, the call site does not.

### 4.3 Handoff record extension for root-volume hint

R11 bootloader today passes a minimal handoff record; the kernel
does not read it in `-kernel` boots (multiboot info is not
propagated end-to-end).  R53 introduces the field but does NOT
depend on it being populated — the `-kernel` smoke path uses the
fallback.

**New handoff field** in `src/kernel/boot/handoff.pdx` (create or
edit — the module today is embedded in `kernel_main.pdx` as
`_init_handoff_*` scalars; R53.M3 factors it out):

```
struct handoff_record {
    /* existing fields */
    /* ... */

    /* R53.M3 additions */
    uint8_t  root_volume_uuid[16];   // zero = no hint
    uint8_t  root_volume_uuid_valid; // 0 = ignore, 1 = binding
    uint8_t  _pad[7];
};
```

The kernel-side reader is a leaf function; no security discipline
new here — it is data the loader wrote before we sti.

### 4.4 Root selection order (R52 §3.3 restated + operationalised)

1. **Bootloader hint.**  If `root_volume_uuid_valid == 1`, scan
   the volume registry for a `uuid` match; if found, mount that
   volume at slot 0.  If not found: **panic** — a signed loader
   named a volume the probe did not find; something is wrong.
2. **Superblock ROOT flag.**  Scan the volume registry for exactly
   one volume with the `bit1 root-volume` superblock flag set; if
   exactly one, mount it.  If more than one, panic with `PDXB ROOT
   AMBIGUOUS multiple flagged`.
3. **Single-device disambiguation.**  If exactly one volume was
   probed and neither of the above yielded a choice, mount it.
4. **Fallback: tmpfs.**  If no volume was probed OR more than one
   was probed with no root-flag disambiguator, fall back to the
   R16 tmpfs bootstrap and emit fingerprint `PDXB ROOT FALLBACK
   TMPFS reason=<none|ambiguous>`.  This is a warning, not a
   failure — the kernel continues to serve an empty root.

The fallback is what keeps every existing smoke mode (which does
not pass `--with-disk`) working unchanged.

### 4.5 What the mount_table sees

Slot 0 gets:
```
mountpoint_vnode_idx = 0                   (root: no parent)
root_vnode_idx       = <newly-allocated root-directory vnode>
backend_type         = 5                   (MOUNT_BACKEND_PDXFS_BLOCK, R52.M5)
flags                = MOUNT_FLAG_VALID | MOUNT_FLAG_ROOT
_reserved            = <_pdxfs_volume_table row index>  (R52 §3.2)
```

The `_reserved` field holds the volume registry index; that is the
handle a future `sys_umount` reaches through to know which volume
to quiesce (§5.3).

---

## 5. Kernel-side mount syscall

### 5.1 Ordinal allocation

Current ceiling (see `src/kernel/core/syscall/dispatch.pdx:281`):
```
cmp rdi, 72;
ja  dispatch_enosys;
```

sysno 72 is `sys_pdxfs_dir_readnext` (R42-PREP-008 #1630).  R53
allocates:

- **sysno 73** = `sys_mount`
- **sysno 74** = `sys_umount`

Bounds update:
```
cmp rdi, 74;
ja  dispatch_enosys;
```

New jump-table arms:
```
cmp rdi, 73; je dispatch_mount;
cmp rdi, 74; je dispatch_umount;
```

`tools/verify-syscall-dispatch.sh` currently greps for
`cmp.*0x3d` (61 = wait4) as the fingerprint.  That grep does not
break because 61 is still in the chain.  The `TOTAL_CHECKS`
counter (currently 15 per the comment at dispatch.pdx line 297)
bumps to **17**.  Update in the same commit.

### 5.2 `sys_mount` — signature + semantics

```
sys_mount(volume_cap: u64,          /* KIND_VOLUME cap slot */
          mount_path_user_va: u64,   /* absolute path (must start with /) */
          mount_path_len: u64,       /* byte length, <= PATH_MAX = 256 */
          flags: u64)                /* MOUNT_FLAG_RO | MOUNT_FLAG_NOSUID | ... */
    -> mount_id: i64 (>=0) or -errno
```

Behavior:

1. **Sanitize.**  `mount_path_len < PATH_MAX`, path starts with `/`,
   `flags` in the allowed bitmask.  Return `-EINVAL` on any breach.
2. **User→kernel path copy.**  Use the R16.M3 KPTI-sweep dispatch
   scratch pattern (`_dispatch_open_path_scratch`, 256 B, see
   `dispatch.pdx:86`) to copy the path bytes.  Return `-EFAULT`
   if the user VA is not readable.
3. **Cap-slot resolve.**  Read the caller's cap table at slot
   `volume_cap`, confirm `kind == KIND_VOLUME (0x1A0)`.  Return
   `-EBADF` on wrong kind or empty slot.
4. **Rights check.**  Confirm `KIND_VOLUME.rights & VOL_RIGHT_MOUNT`.
   Return `-EPERM` on denial.
5. **Path resolve.**  Walk the current VFS from
   `mount_root_vnode()` to `mount_path`.  The final component must
   resolve to an existing directory; anything else returns
   `-ENOTDIR` / `-ENOENT`.  (No mount-on-file at R53.)
6. **Duplicate check.**  Scan mount_table for a live slot whose
   mountpoint_vnode_idx equals the resolved vnode; if found,
   return `-EBUSY`.  Also refuse if the volume's registry row is
   already mount_slot != 0xFFFF (a volume is single-mount at R53).
7. **Slot allocation.**  Find the first free slot in the 1..7
   range (slot 0 is root-reserved per R16); return `-ENOSPC` if
   full.  R53's 7-non-root cap is inherited from R16; R54 may
   widen.
8. **Backend init.**  Call `pdxfs_block_backend_attach(volume_slot)`
   which: (a) fetches the volume's superblock summary; (b) allocates
   a per-volume block cache slot (R52.M7's `KIND_BLOCK_CACHE`); (c)
   runs WAL replay from journal region (R52 §4.3).  Any failure
   propagates as `-EIO`.
9. **Vnode alloc.**  Fresh vnode for the mounted root; type=DIR;
   parent=VNODE_IDX_NONE; ops_ptr = &_pdxfs_block_vops; backend_ptr
   = volume registry index.
10. **Pack + write mount_table entry.**  `backend_type = 5`;
    `flags = MOUNT_FLAG_VALID`; `_reserved = volume_slot`.
11. **Volume registry update.**  Set the volume's `mount_slot` to
    the new slot index.
12. **Audit event.**  Emit `AUD_MOUNT id=<slot> vol_uuid=<hex>
    path=<canonical>` via the R48+ audit-schema pipeline.
13. **Return.**  `rax = mount_slot` (0..7 range; low 16 bits used).

**Rights model** (VOL_RIGHT_*).  Softarch owns the fine-grained
model in the volume-fs substrate; osarch's guarantee is that the
mint gate refuses to hand `VOL_RIGHT_MOUNT` to a caller whose
parent cap does not carry it, and that boot-time probe grants
`VOL_RIGHT_MOUNT` only to the founder user (R48b elevate policy).
See §10.2 for the coordination shape.

### 5.3 `sys_umount` — signature + semantics

```
sys_umount(mount_id: u64,     /* mount slot 1..7 */
           flags: u64)         /* UMOUNT_FLAG_FORCE (R54+), _LAZY (R54+) */
    -> 0 or -errno
```

Behavior:

1. **Sanitize.**  `mount_id != 0` (root umount is refused —
   R53 does not support unmounting root; that needs a shutdown
   protocol).  `flags == 0` at R53 (`FORCE`, `LAZY` reserved).
   Return `-EINVAL` otherwise.
2. **Slot read.**  Read `mount_table[mount_id]`.  Confirm
   `backend_type == 5 && flags & MOUNT_FLAG_VALID`.  Return
   `-EINVAL` otherwise.
3. **Rights check.**  Read the associated volume from
   `_reserved` field, confirm caller holds `VOL_RIGHT_UMOUNT` on
   its cap.  Return `-EPERM` on denial.
4. **Busy check.**  Walk fd_table for any open fd whose vnode
   belongs to this mount's vnode subtree.  Also walk vnode_pool
   for any refcount > 0 on this backend's vnodes.  If any found,
   return `-EBUSY`.  (Softarch may want to expose a "what is
   holding this mount?" query — deferred to §10.5.)
5. **Backend quiesce.**  Call
   `pdxfs_block_backend_detach(volume_slot)`: (a) flush block
   cache (writeback all dirty blocks); (b) issue `BDEV_OP_FLUSH`;
   (c) write JOP_COMMIT for any in-flight commit-pending txn (or
   abort them, R52 §4.4); (d) advance the checkpoint pointer;
   (e) rewrite the superblock with `clean_unmount` bit set (R52
   §2.1 flags field); (f) `BDEV_OP_FLUSH` again; (g) release the
   block cache slot.
6. **Mount_table clear.**  Write 0 to the slot's u64.
7. **Volume registry update.**  Clear the volume's `mount_slot`
   to 0xFFFF.
8. **Audit event.**  Emit `AUD_UMOUNT id=<slot>
   vol_uuid=<hex> clean=1`.
9. **Return.**  `rax = 0`.

### 5.4 Dispatch wiring

New file: `src/kernel/core/syscall/sys_mount.pdx` and
`src/kernel/core/syscall/sys_umount.pdx`, following the shape of
existing `sys_open.pdx` / `sys_close.pdx`.  Each hosts:

- The user-argument copy-in shim (`dispatch_mount` / `dispatch_umount`
  in `dispatch.pdx`) using per-syscall bounce scratch.
- The `sys_mount_body` / `sys_umount_body` core, `!{mem, sysreg}
  @{cap, sched}` effects/caps.
- The rights validators + audit emitters.

The dispatch shim in `dispatch.pdx` is <60 lines per syscall
following the pattern the R42-PREP-008 shims established.

### 5.5 Both syscalls are userspace-privileged

Meaning: they check caps, not ring level.  A ring-3 caller with a
valid `KIND_VOLUME` cap carrying `VOL_RIGHT_MOUNT` can mount;
kernel-side callers hold the same caps (the boot-time probe
holds all rights).  This is the R48/R51 discipline generalised —
"kernel-mode" is not a privilege; capability-holdership is.

---

## 6. Interaction with existing R16 tmpfs mount_table

### 6.1 `mount_kind` byte — do we need one?

R52.M5 extends `backend_type` in the mount_table entry from four
values (`NONE, TMPFS, DEVFS, PROCFS, TTY`) to five by adding
`MOUNT_BACKEND_PDXFS_BLOCK = 5`.  The 8-bit field has room for 251
more discriminants; a separate `mount_kind` byte would be
redundant.

**Recommendation: no new `mount_kind` field.**  The `backend_type`
byte at bits [32:40) is the discriminant — dispatch goes through
`backend_ops_table(backend_type)` which returns
`&_tmpfs_vops` for 1, `&_pdxfs_block_vops` for 5, etc.  R16 already
established this shape (`src/kernel/core/fs/backend_registry.pdx`).

This is a departure from the round brief's §6 sketch ("Add a
`mount_kind` enum to the mount_table row"), and it is the right
departure: the R16 field already carries the discrimination.  Adding
a second field would drift the row shape and require every existing
consumer to be updated.

### 6.2 Dispatch extension

`backend_registry.pdx`'s `backend_ops_table` gains one arm.
Existing:
```
cmp rdi, 1
je  bot_tmpfs
```

Add:
```
cmp rdi, 5
je  bot_pdxfs_block
```

Where `bot_pdxfs_block: mov rax, [rip + _pdxfs_block_vops]; ret`.

The `_pdxfs_block_vops` table lands at
`src/kernel/core/fs/pdxfs/block_vops.pdx` — a new file — following
the shape of `_tmpfs_vops`.  Its function-pointer entries wire to
the R52-substrate walker calls (which R52.M6 will have turned into
real journaled ops).

### 6.3 vfs_read / vfs_write already indirect

The R16 vfs paths already go through the vops function-pointer
table.  Zero read/write path changes; R52.M6 has done the underlying
walker work; R53 only registers the new vops table.

### 6.4 What R53 changes in mount.pdx itself

**Bounds update.**  Line 116: `cmp r14, 4; ja mount_fail;` widens
to `cmp r14, 5; ja mount_fail;`.  Line 41 gains the constant
`MOUNT_BACKEND_PDXFS_BLOCK = 5` (or references it via `use` from
the R52.M5 module that landed it).

That is the only edit `mount.pdx` needs.  The rest of the mount
primitive already handles the shape uniformly.

---

## 7. QEMU smoke integration — extending `run-smoke.sh`

### 7.1 New `--with-disk` flag

Add before the mode dispatcher (`case "${EXPECTED}"`):

```bash
WITH_DISK=0
WIPE_DISK=0
DISK_IMAGE_PATH="${REPO_ROOT}/tests/qemu/disks/pdxb-root.img"
DISK_IMAGE_SIZE_MIB="${PDXB_IMAGE_SIZE_MIB:-128}"

# Parse leading flags (before the mode name)
while [[ "${1:-}" =~ ^-- ]]; do
    case "$1" in
        --with-disk) WITH_DISK=1; shift ;;
        --wipe)      WIPE_DISK=1; shift ;;
        --) shift; break ;;
        *) echo "smoke: unknown flag $1" >&2; exit 2 ;;
    esac
done
EXPECTED="${1:-}"
```

### 7.2 Image lifecycle

Before the `qemu-system-x86_64` launch:

```bash
if [[ ${WITH_DISK} -eq 1 ]]; then
    if [[ ${WIPE_DISK} -eq 1 ]] || [[ ! -f "${DISK_IMAGE_PATH}" ]]; then
        mkdir -p "$(dirname "${DISK_IMAGE_PATH}")"
        if [[ -f "${DISK_IMAGE_PATH}" ]]; then rm -f "${DISK_IMAGE_PATH}"; fi
        PDXB_IMAGE_SIZE_MIB="${DISK_IMAGE_SIZE_MIB}" \
            "${REPO_ROOT}/tools/mkfs-pdxb.sh" --file "${DISK_IMAGE_PATH}" \
                                              --size-mib "${DISK_IMAGE_SIZE_MIB}" \
                                              --set-root-flag
    fi
    DISK_ARGS=(
        -drive "file=${DISK_IMAGE_PATH},if=none,id=nvme0,format=raw"
        -device "nvme,drive=nvme0,serial=PDXB0001,logical_block_size=4096,physical_block_size=4096"
    )
else
    DISK_ARGS=()
fi
```

Add `"${DISK_ARGS[@]}"` to both `timeout ${TIMEOUT} qemu-system-x86_64
\` invocations (there are two — the standard and the SMP variant).

### 7.3 New smoke modes

Add to the mode dispatcher case:

```bash
    boot_r53_first_mount)
        # R53.M4-001: first PDXB volume mount smoke.
        # Requires --with-disk.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r53/first-mount.golden"
        TIMEOUT=15
        EXPECTED=""
        [[ ${WITH_DISK} -eq 0 ]] && { echo "smoke: boot_r53_first_mount requires --with-disk" >&2; exit 2; }
        ;;

    boot_r53_round_trip)
        # R53.M4-005: full round-trip: write file → clean umount →
        # reboot → read file back → hash matches.  This is a
        # TWO-QEMU-INVOCATION smoke (see §7.4).  Requires --with-disk.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r53/round-trip.golden"
        TIMEOUT=30
        EXPECTED=""
        [[ ${WITH_DISK} -eq 0 ]] && { echo "smoke: boot_r53_round_trip requires --with-disk" >&2; exit 2; }
        ;;
```

### 7.4 The round-trip smoke — two-phase

`boot_r53_round_trip` is unusual: it needs two `qemu-system-x86_64`
invocations against the same image with a state check in the middle.
The runner scripts this as:

**Phase 1 (write + umount).**  Wipe image → mkfs → launch QEMU
with a boot-time witness that: (a) mounts the volume; (b) opens
`/test-file`; (c) writes a 4 KiB deterministic pattern (e.g.
`repeat_byte 0x5A × 4096`); (d) issues `sys_umount` (or, since
`sys_umount` may not be reachable from the boot witness without
ring-3 plumbing, calls `pdxfs_block_backend_detach` directly);
(e) emits fingerprint `PDXB ROUND TRIP PHASE1 WRITTEN hash=<hex>`;
(f) exits via `isa-debug-exit` clean.

**Phase 2 (reboot + read back).**  Do NOT wipe.  Launch QEMU again
with the same disk.  Boot witness: (a) mounts (re-boot path finds
the clean-unmount flag); (b) opens `/test-file`; (c) reads 4 KiB;
(d) hashes; (e) emits `PDXB ROUND TRIP PHASE2 READ hash=<hex>`; (f)
exits.

The golden asserts both fingerprints appear and both hashes match.
The runner glues the two logs together for the fingerprint check;
the second phase is guarded on the first phase exiting cleanly (rc
∈ {0, 33}).

Concretely, `run-smoke.sh boot_r53_round_trip` becomes:

```bash
# Phase 1
"$0" --with-disk --wipe boot_r53_round_trip_phase1 || exit $?
# Phase 2
"$0" --with-disk boot_r53_round_trip_phase2 || exit $?
# Combined-log golden check (already done by phase2 against its own golden;
# an additional combined-log check would be redundant).
```

Where `boot_r53_round_trip_phase1` and `_phase2` are subordinate
modes each pointing at its own boot witness + golden.

### 7.5 Golden additions

New files under `tests/r53/`:

- `first-mount.golden`
- `round-trip-phase1.golden`
- `round-trip-phase2.golden`

Fingerprint line shapes (for anchor grep):

```
PDXB PROBE OK uuid=deadbeef1234... dev=1 root_flag=1
PDXB VOLUME MOUNTED uuid=deadbeef1234... slot=0
PDXB ROOT SELECTED via=<hint|flag|single>
PDXB ROUND TRIP PHASE1 WRITTEN hash=<hex>
PDXB ROUND TRIP PHASE2 READ hash=<hex>
PDXB CLEAN UMOUNT slot=<n> vol_uuid=<hex>
```

Also append to the existing `tests/r17/shell-shutdown.golden` — the
non-`--with-disk` path stays unchanged, so no golden change is
required there.  The R53 fingerprints appear only when the disk is
attached.

### 7.6 Pre-push wiring

Add `boot_r53_first_mount` to the pre-push matrix behind a
`PAIDEIA_R53_DISK=1` env gate — matches the "opt-in until 5/5
consecutive passes" discipline (see the R20b_echo pattern at
run-smoke.sh:414+).  `boot_r53_round_trip` also opt-in.  Promote
to the default matrix after five green runs.

---

## 8. Failure modes + recovery

### 8.1 Superblock signature invalid on mount

**Cause.**  Bit-flip on the disk, tampering, wrong key at boot,
key rotation mid-life.
**Detection.**  `KIND_SIG_KEY` verify against superblock signature
in probe step 8 (§4.2).
**Response.**  Refuse mount.  Emit audit event
`AUD_VOLUME_SIG_MISMATCH uuid=<hex> dev=<slot>
key_hash=<expected> got=<observed>`.  If this was the intended
root volume, boot into tmpfs fallback (§4.4) with additional
fingerprint `PDXB ROOT REFUSED sig_mismatch uuid=<hex>`.

**Recovery.**  The developer either (a) rotates the key in
`tests/qemu/keys/` back to the one that signed the image, or (b)
regenerates the image with `--wipe`, or (c) sets
`PAIDEIA_DEV_UNSIGNED_ACCEPT=1` in the ephemeral shell (dev-only
escape hatch that logs a loud warning).

### 8.2 WAL journal replay finds corruption

**Cause.**  Torn write during last shutdown, disk corruption,
truncated journal.
**Detection.**  R52 §4.3 recovery walk finds a CSUM failure on a
journal block.
**Response.**  R52's §4.3 already specifies: "A CSUM failure
truncates the replay range at that block."  In practice this means
the torn record and everything after it in the replay window is
discarded.  R53 adds a fingerprint: `PDXB REPLAY TRUNCATED
at_seq=<n> discarded=<count>` — this is a WARNING, not an error;
the volume mounts.

**Softarch's call for the harsher case.**  If corruption is at
the checkpoint pointer itself (i.e. we cannot even find the
replay start), R52 does not have a clean fallback specified.
Softarch's parallel doc should decide between (i) refuse mount
entirely, requiring `pdxfsck`; (ii) mount read-only.  For R53's
smoke matrix we assume the (i) path — refuse — with fingerprint
`PDXB REPLAY CORRUPT REFUSED at=<lba>`.  If softarch prefers
(ii), the fingerprint becomes `PDXB REPLAY CORRUPT MOUNT_RO
at=<lba>`; the smoke golden is a one-line change.

### 8.3 Disk unavailable mid-run (QEMU device_del)

**Cause.**  User pulls the drive at the QEMU monitor
(`device_del nvme0`) — simulates a physical unplug.  Or PCIe
surprise-remove (R29 substrate handles the cap-side; this section
covers the FS-side).
**Detection.**  Next `BDEV_OP_READ_LBA` or `WRITE_LBA` returns
`BDEV_ERR_DEVICE_GONE` (a new error code — coordinate with R51
if not already defined).
**Response.**  Kernel-side: propagate `-EIO` from any in-flight
FS op.  Mark the mount slot as ZOMBIE (bit 2 in flags, new).
Any subsequent open/read/write to a vnode in this mount returns
`-EIO` immediately.  User tools handle by attempting umount (with
`FORCE` flag once R54 lands) or by rebooting.  Emit audit event
`AUD_VOLUME_LOST slot=<n> vol_uuid=<hex>`.

**Recovery.**  Reattach the drive (`device_add nvme,...`) at the
monitor; probe re-runs; new mount is a fresh slot.  The dead slot
stays ZOMBIE until reboot or explicit `sys_umount(FORCE)`.

**R53 note.**  R53 does not implement `FORCE` umount.  The dead
slot stays until reboot.  A future round with `UMOUNT_FLAG_FORCE`
retires this.

### 8.4 Full disk on write

**Cause.**  Data region exhausted; allocator bitmap has zero free
blocks.
**Detection.**  R52 allocator returns `PDXFS_ERR_NOSPC` on
`allocate_block` inside a WAL-mediated write.
**Response.**  Abort the current transaction (JOP_ABORT); the
write syscall returns `-ENOSPC`.  Data region and inode table
remain consistent; no torn state.  Emit audit event
`AUD_VOLUME_FULL slot=<n> vol_uuid=<hex> used=<n_blocks>
total=<n_blocks>`.

**Recovery.**  Unlink some files; the R52.M6 UNLINK path issues
`JOP_BITMAP_CLEAR` for every block on the removed inode's CoW
tree; a subsequent write succeeds.

### 8.5 Audit-event catalog for R53

New audit tags to add in
`src/kernel/core/audit/audit_schema.pdx`:

- `AUD_MOUNT`             — successful mount
- `AUD_UMOUNT`            — successful umount
- `AUD_VOLUME_SIG_MISMATCH` — probe rejected on signature
- `AUD_VOLUME_LOST`       — device gone mid-mount
- `AUD_VOLUME_FULL`       — allocator exhausted
- `AUD_MOUNT_REFUSED`     — generic mount refuse (with reason
                            code sub-field for BAD_MAGIC,
                            BAD_LAYOUT, UNSIGNED_REFUSED)
- `AUD_REPLAY_TRUNCATED`  — WAL replay found corruption

Bump `aud_kind_valid` upper bound accordingly.  These are the
audit-fingerprint anchors §7.5 already surfaces as boot-log
lines.

---

## 9. R53 milestone breakdown

Five commit-scale milestones.  M1 lands the host tool; M2 lands
the syscalls; M3 lands the boot-time probe; M4 lands the smoke
integration; M5 lands failure-mode audit fingerprints.  M1..M2
can run in parallel with M3.  M4 depends on M1+M3 (needs both
mkfs and probe wired); M5 depends on M2+M4 (needs syscalls +
smoke to hang audit fingerprints on).

### M1 — Host-side `mkfs-pdxb` + `mkfs-pdxb.sh` (Path A)

- `R53.M1-001 New src/tools/mkfs-pdxb/main.pdx (writes PDXB superblock + regions)`
- `R53.M1-002 Land tools/mkfs-pdxb.sh (dev-host wrapper; env PDXB_IMAGE_SIZE_MIB)`
- `R53.M1-003 Dev signing key at tests/qemu/keys/pdxb-dev.mldsa65.{pub,priv}`
- `R53.M1-004 Sig-key hash embed: mkfs writes sig_key_hash from --sig-key arg`
- `R53.M1-005 Deterministic UUID scheme: derive from --uuid or blake3(HEAD_hash)`
- `R53.M1-006 Host-side unit test: mkfs → parse via python struct.unpack → verify layout`

### M2 — `sys_mount` / `sys_umount` syscalls + mount_table dispatch

- `R53.M2-001 Widen dispatch.pdx bounds check cmp rdi, 72 → cmp rdi, 74`
- `R53.M2-002 New src/kernel/core/syscall/sys_mount.pdx (body + dispatch shim)`
- `R53.M2-003 New src/kernel/core/syscall/sys_umount.pdx (body + dispatch shim)`
- `R53.M2-004 Extend mount.pdx bounds: cmp r14, 4 → cmp r14, 5 (accept BACKEND_PDXFS_BLOCK)`
- `R53.M2-005 New src/kernel/core/fs/pdxfs/block_vops.pdx (_pdxfs_block_vops table wiring)`
- `R53.M2-006 Extend backend_registry.pdx: cmp rdi, 5; je bot_pdxfs_block`

### M3 — Boot-time volume-probe + root-volume handoff

- `R53.M3-001 New src/kernel/boot/handoff.pdx (factor _init_handoff_* + add root_volume_uuid[16])`
- `R53.M3-002 Wire pdxb_volume_probe_all_bdev() into kernel_main after nvme_probe`
- `R53.M3-003 Root-selection order (hint > flag > single > tmpfs-fallback)`
- `R53.M3-004 mount_bootstrap branch: PDXFS_BLOCK root or TMPFS fallback`
- `R53.M3-005 Fingerprint emit: PDXB PROBE OK / SKIP / VOLUME MOUNTED / ROOT SELECTED / ROOT FALLBACK`
- `R53.M3-006 Witness: probe with no-disk configuration emits FALLBACK TMPFS`

### M4 — `run-smoke.sh --with-disk` + first round-trip smoke

- `R53.M4-001 Add --with-disk / --wipe flag parsing to run-smoke.sh`
- `R53.M4-002 Image-lifecycle block: mkfs-on-missing + wipe honored`
- `R53.M4-003 Add boot_r53_first_mount mode + tests/r53/first-mount.golden`
- `R53.M4-004 Add boot_r53_round_trip_{phase1,phase2} modes + goldens`
- `R53.M4-005 Two-phase orchestrator: run-smoke.sh boot_r53_round_trip meta-mode`
- `R53.M4-006 Pre-push wiring: PAIDEIA_R53_DISK=1 env gate on the two modes`

### M5 — Failure-mode audit + audit-event fingerprints + rescue-shell fallback

- `R53.M5-001 Extend audit_schema.pdx with AUD_MOUNT / UMOUNT / SIG_MISMATCH / LOST / FULL / REFUSED / REPLAY_TRUNCATED`
- `R53.M5-002 sys_mount + sys_umount emit AUD_MOUNT / AUD_UMOUNT`
- `R53.M5-003 Probe emits AUD_VOLUME_SIG_MISMATCH + AUD_MOUNT_REFUSED on failure paths`
- `R53.M5-004 Boot-fallback tmpfs path emits PDXB ROOT FALLBACK TMPFS fingerprint`
- `R53.M5-005 R51 AHCI parity: probe walks AHCI KIND_BLOCK_DEVICE + witness fingerprint`
- `R53.M5-006 Bump aud_kind_valid upper bound + confine _pdxb_volume_table in tools/build.sh`

---

## 10. Softarch coordination points

Explicit handshakes.  Every item here is one this document commits
to on osarch's side; softarch's parallel doc restates its side.

### 10.1 Syscall ordinals (frozen at merge)

- **sysno 73 = `sys_mount`**  (osarch lands dispatch + body; softarch's
  `mount.pdxfs` tool consumes it)
- **sysno 74 = `sys_umount`** (same shape)

Bounds update in `dispatch.pdx`: `cmp rdi, 72 → cmp rdi, 74`.  Any
softarch tool that hardcodes `SYS_MOUNT` / `SYS_UMOUNT` numeric
values must use `73` and `74`.  If softarch's plan wants different
numbers (say, contiguous with an existing fs-family band), that is
negotiable — signal at merge time and osarch reallocates.

### 10.2 KIND_VOLUME rights model

R52 §6.1 registered `KIND_VOLUME = 0x1A0`.  Its rights bits are the
softarch design's, not osarch's, but the mount/umount syscall
consumes them:

- `VOL_RIGHT_MOUNT`   — required for `sys_mount`
- `VOL_RIGHT_UMOUNT`  — required for `sys_umount`
- `VOL_RIGHT_QUERY`   — required for volume-query ops (softarch's
                        `VOL_OP_QUERY_UUID` etc, R52 §6.1)
- `VOL_RIGHT_MINT_FILE` — required to derive `KIND_PDXFS_FILE`
                          caps (softarch's walker path)

The **mint gate for a volume cap the boot probe creates** hands
`(VOL_RIGHT_MOUNT | VOL_RIGHT_UMOUNT | VOL_RIGHT_QUERY |
VOL_RIGHT_MINT_FILE) = VOL_RIGHT_ALL` to the founder user (R48b
elevate policy).  A userspace mounter that receives the cap via
elevate can narrow it (drop MOUNT to prevent re-mounting) before
exec — the standard cap-narrowing discipline, no new mechanism.

Osarch requests: softarch's design should confirm the four right
bits above and either (a) match them or (b) propose the actual
right names + osarch renames its call sites in the same merge.

### 10.3 `mkfs` core sharing

R53.M1's host binary `mkfs-pdxb` and R52.M2-003's kernel-callable
`mkfs.pdxfs` tool are the same logic.  Proposal:

- Core logic lives at `src/tools/pdxb-mkfs-core/` — a paideia-as
  library with two entry points:
  - `mkfs_pdxb_format_file(fd, size_bytes, uuid, sig_key)` — Path A
    host use
  - `mkfs_pdxb_format_bdev(bdev_cap, uuid, sig_key)` — Path C
    userspace use (softarch wraps this in `mkfs.pdxfs`)
- The two wrappers differ only in whether they hold a plain-file
  fd or a `KIND_BLOCK_DEVICE` cap slot; the underlying block
  writer is behind an fd/cap-slot abstraction.
- R53.M1 lands the core + Path A wrapper; softarch's R52.M2-003
  (which pre-dates but was scaffolded) is retargeted to use the
  same core.

Softarch owns the R52.M2-003 retargeting; osarch owns the core
library layout.  Coordinate at merge whether the "abstraction"
is a static-dispatch entry-point pair or a function-pointer table.

### 10.4 CLI shape for `mount.pdxfs`

Softarch's `mount.pdxfs` tool calls `sys_mount(volume_cap,
mount_path, mount_path_len, flags)`.  The CLI shape it should
expose (osarch's suggestion, softarch owns):

```
mount.pdxfs <volume-cap-slot> <mount-path> [-o ro,nosuid,nodev,noexec,relatime]
```

- The `<volume-cap-slot>` is a small integer naming a slot in the
  caller's cap table; the shell resolves it (softarch's semantic-
  pipe substrate maps a `KIND_VOLUME` cap-holder identifier to a
  slot).  This matches the R49 `pkg install <cap-slot>` shape.
- `-o` flags parse to the `flags` bitmask; osarch's `sys_mount`
  accepts `MOUNT_FLAG_RO = 0x01` at R53; other flags are
  parsed-and-ignored (reserved).

### 10.5 "Who is holding this mount?" query

`sys_umount` returns `-EBUSY` when open fds or refcount>0 vnodes
belong to the mount subtree.  Softarch's `umount` tool needs to
tell the user *what* is holding it.  Proposal: **not R53's
problem.**  A future `sys_mount_query(mount_id) → JSON-ish
descriptor` is R54.  R53's `-EBUSY` is a naked errno; softarch's
tool prints "device busy; use lsof-equivalent (deferred to R54)".

### 10.6 Non-root mount smoke — soft-launch

Softarch may want a smoke that mounts a *second* volume via
`sys_mount` and reads a file from it.  Osarch's M4 does not
include this — it exercises boot-time root mount only.  If
softarch wants it in the same round, add M4-007 (a third smoke
mode `boot_r53_second_mount`).  Osarch is neutral; a boot-time
`sys_mount(volume_slot=1)` witness is trivial once M2 lands.

### 10.7 Bootloader change (deferred)

The `root_volume_uuid` handoff field is defined in R53 but not
wired at the R11 bootloader end (§4.3).  R53 works via the
superblock-flag or single-device fallback.  A bootloader-side
change is a separate deliverable, tracked as a follow-up issue
against paideia-os bootloader (not this round).

---

## Appendix A — Files R53 touches

**New files:**
- `design/tooling/volume-lifecycle-mechanism.md` (this document)
- `src/tools/mkfs-pdxb/main.pdx` (M1)
- `src/tools/pdxb-mkfs-core/format.pdx` (M1, shared with softarch)
- `tools/mkfs-pdxb.sh` (M1)
- `tests/qemu/keys/pdxb-dev.mldsa65.{pub,priv}` (M1)
- `tests/qemu/disks/.gitkeep` + gitignore for `*.img` (M4)
- `src/kernel/boot/handoff.pdx` (M3, factored out of kernel_main)
- `src/kernel/core/syscall/sys_mount.pdx` (M2)
- `src/kernel/core/syscall/sys_umount.pdx` (M2)
- `src/kernel/core/fs/pdxfs/block_vops.pdx` (M2)
- `src/kernel/boot/witness/r53_mount.pdx` (M3, M4 witnesses)
- `src/kernel/boot/witness/r53_round_trip_write.pdx` (M4)
- `src/kernel/boot/witness/r53_round_trip_read.pdx` (M4)
- `tests/r53/first-mount.golden` (M4)
- `tests/r53/round-trip-phase1.golden` (M4)
- `tests/r53/round-trip-phase2.golden` (M4)

**Modified files (edit, not replace):**
- `src/kernel/core/syscall/dispatch.pdx` — bounds bump + 2 dispatch arms (M2)
- `src/kernel/core/fs/mount.pdx` — bounds bump to accept backend 5 (M2)
- `src/kernel/core/fs/backend_registry.pdx` — dispatch arm for backend 5 (M2)
- `src/kernel/boot/kernel_main.pdx` — insert probe call site; call handoff factored module (M3)
- `src/kernel/core/audit/audit_schema.pdx` — new AUD_* tags + bump upper bound (M5)
- `tools/run-smoke.sh` — flag parsing + image lifecycle + 3 new modes (M4)
- `tools/build.sh` — `ec_confine_one` on `_pdxb_volume_table` and any new `_*_stats` (M5)
- `tools/verify-syscall-dispatch.sh` — bump `TOTAL_CHECKS` 15 → 17 (M2)
- `.gitignore` — add `tests/qemu/disks/*.img` (M4)

**No files retired.**

## Appendix B — Discipline sequence for a new R53 milestone commit

Mirrors R52 Appendix B; abbreviated for the HW+kernel side:

1. Land the module (`src/kernel/**/*.pdx`).
2. Wire dispatch (`dispatch.pdx`, `backend_registry.pdx`, or `mount.pdx` as applicable).
3. Add audit-event enum (`audit_schema.pdx`) if a new event fires.
4. Confine any new `_*_table` / `_*_stats` in `tools/build.sh`.
5. Add witness under `src/kernel/boot/witness/r53_*.pdx`.
6. Add fingerprint line to the milestone golden under `tests/r53/`.
7. Extend `run-smoke.sh` mode dispatcher if a new smoke mode is needed.
8. Cross-reference this document from the module's header comment.
9. Update `design/architecture/next-wave-derived-kinds.md` if a new KIND lands (R53 does not — it consumes R51+R52 KINDs only).
10. Softarch coordination check: if the change touches §10 items, ping softarch's parallel doc for the matching update in the same merge.
