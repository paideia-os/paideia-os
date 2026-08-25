# Getting started with PaideiaOS

This guide walks a new operator through cloning the repository, building the
kernel, booting it under QEMU (both without and with a real NVMe-backed
disk), initializing a PdxFS-on-block volume, mounting it, installing a
package with `pkg`, and driving the shell. Every step is a shell command
you can copy-paste, and every "success" claim names a literal fingerprint
you can grep in the serial log.

The design contracts behind each step are pinned in
`design/tooling/volume-lifecycle-mechanism.md`,
`design/tooling/volume-tooling-ux.md`,
`design/filesystem/volume-fs-substrate.md`, and
`design/tooling/r49-r50-plan.md`. When this guide and those docs disagree,
the design docs win.

---

## 1. Prerequisites

Host: any recent Linux distribution. PaideiaOS is verified only on Linux
hosts; other UNIX-family hosts may work but are unattested.

Packages the host must provide:

- `git` (with submodule support)
- `bash` (4.x or newer)
- `python3` (used by `tools/bootstrap_r7.py` and by build helpers)
- `qemu-system-x86_64` (any version supporting `-machine q35` and the
  emulated NVMe device)
- `binutils` (for GNU `ld`; PaideiaOS links its own ELF)
- Rust toolchain (>= 1.80) to build the in-house assembler
- `nasm` — only if you rebuild the boot stub from source; the tree ships
  prebuilt objects and this is not required for a normal cycle

Debian / Ubuntu:

```sh
sudo apt install git build-essential binutils qemu-system-x86 rustup
```

Fedora:

```sh
sudo dnf install git binutils qemu-system-x86 rust cargo
```

A reproducible dev shell is defined at `nix/flake.nix` for Nix users.

The assembler `paideia-as` is vendored as a git submodule at
`tools/paideia-as/`. If you need to bump it later:

```sh
bash tools/update-paideia-as.sh
```

`tools/find-paideia-as.sh` is the strict resolver used by every build
step; it currently pins `v0.4.0+` and refuses to link an older binary.

---

## 2. Cloning and the first build

```sh
git clone --recurse-submodules https://github.com/paideia-os/paideia-os.git
cd paideia-os
```

If you forgot `--recurse-submodules`:

```sh
git submodule update --init --recursive
```

Build the assembler once:

```sh
(cd tools/paideia-as && cargo build --release -p paideia-as)
```

Build the kernel:

```sh
bash tools/build.sh
```

Expected output (trailing lines):

```
[fingerprint-coverage] tools/verify-fingerprint-coverage.sh
[init-handoff] tools/verify-init-handoff.sh
[file-id-hardcodes] tools/verify-file-id-hardcodes.sh
[build] paideia-as boot/entry.pdx -> boot/entry.o
[link]  ld -T link.ld -> kernel.elf
[ok]    build/kernel.elf
```

`tools/build.sh` runs roughly forty confinement and audit gates before it
lets a link succeed. The four you will hit most often are:

- `ec_confine_one` — one-writer-per-symbol static enforcement; a link that
  would let two modules write the same symbol is refused.
- Fingerprint-coverage gate (`#1578`, in
  `tools/verify-fingerprint-coverage.sh`) — every literal `... OK` string
  the kernel emits must be pinned in a boot-mode golden file OR appear in
  the script's allowlist. Failure prints `[FAIL] unwitnessed boot
  fingerprint (#1578 gate)`.
- `verify-file-id-hardcodes.sh` — no hand-written file-id integers.
- `verify-init-handoff.sh` — the ring-3 handoff contract stays intact.

A green build ends with `[ok] build/kernel.elf`. Everything below assumes
that file exists.

---

## 3. Boot without a disk (substrate mode)

The hero smoke boots to shell, reaps it, and shuts down cleanly:

```sh
bash tools/run-smoke.sh boot_r17_shell_shutdown
```

To see the tmpfs-fallback path exercised end-to-end (no PdxFS-block
volume present, so `mount_bootstrap` falls back to tmpfs), pick any boot
mode that does not pass `--with-disk`. Grep the resulting serial log for:

```
PDXB NO DISK FALLBACK OK
PDXB ROOT FALLBACK TMPFS
```

Those are the exact strings; both come from
`src/kernel/boot/witness/pdxb_no_disk_witness.pdx` and
`src/kernel/core/fs/pdxfs/mount_bootstrap.pdx` respectively. The root
selector's precedence is documented in step 6.

Exit an interactive QEMU with `Ctrl-A` then `X`.

---

## 4. Boot with a real NVMe-backed disk

R53.M4 added two leading flags to `tools/run-smoke.sh` that attach a
persistent raw image to an emulated NVMe controller:

- `--with-disk` — attach a raw image as `-drive
  file=<DISK_IMAGE_PATH>,if=none,id=nvme0,format=raw` and wire it to a
  `-device nvme`. If the image does not exist, it is created and mkfs'd
  through `tools/mkfs-pdxb.sh` before QEMU launches.
- `--wipe` — force a `mkfs-pdxb.sh --force` re-mkfs of the backing image
  even when it already exists. No-op unless `--with-disk` is also passed.
  Omitting `--wipe` preserves image contents across invocations, which is
  what lets the two-phase round-trip smoke (step 7) compose.

The image path is resolved as `${CLAUDE_JOB_DIR}/tmp/pdxb-smoke.img` when
`CLAUDE_JOB_DIR` is set, and `/tmp/paideia-pdxb-smoke.img` otherwise.
Override with the `DISK_IMAGE_PATH` env var.

Environment variables that flow into `tools/mkfs-pdxb.sh`:

- `PDXB_IMAGE_SIZE_MIB` — image size in MiB. The wrapper defaults to 64
  MiB, but `run-smoke.sh` forces 128 MiB (the design §2.1 floor) when it
  drives the wrapper itself. Override on the smoke path with
  `DISK_IMAGE_SIZE_MIB` if you need larger.
- `PDXB_UUID` — 32-hex-char UUID for the superblock. Unset: the mkfs
  binary derives one from repo HEAD.
- `PDXB_SIG_KEY` — path to an ML-DSA-65 signing key. Unset: the binary
  writes a zero signature with the `SIG_UNSIGNED` flag; the kernel
  accepts that only under `PAIDEIA_DEV_UNSIGNED_ACCEPT=1`. The tree
  ships a placeholder public key at
  `tests/qemu/keys/pdxb-dev.mldsa65.pub` (see `tests/qemu/keys/README.md`
  — the files are placeholders with `PDXB_DEV_PUB_KEY_v0` /
  `PDXB_DEV_PRIV_KEY_v0` headers and zero-fill bodies, dev-only).

Bring up a live disk on the first-mount smoke:

```sh
bash tools/run-smoke.sh --with-disk boot_r53_first_mount
```

Fingerprints the operator should see (defined in
`tests/r53/first-mount.golden`, and each is the literal string as
emitted):

- `PDXFS MKFS SMOKE OK` — mkfs witness closed.
- `PDXB PROBE OK` — probe walked the NVMe queues and found a PDXB
  superblock.
- `PDXFS BOOT MOUNT OK` — the on-block PdxFS was mounted at boot.
- `PDXB VOLUME MOUNTED` — from `mount_pdxfs_block` in
  `src/kernel/core/fs/pdxfs/mount_block.pdx`.
- `PDXB ROOT SELECTED` — root selector picked a volume; see step 6.
- `FIRST MOUNT OK` — closer for `boot_r53_first_mount`, emitted by
  `src/kernel/boot/witness/pdxfs_first_mount.pdx`.

If any of those are missing, dump the log directly rather than trusting
the golden's ordered-substring diagnostic; a hang usually means one
fingerprint earlier in the chain silently failed.

---

## 5. Initializing a volume manually with `mkfs-pdxb`

To pre-make an image the smoke will then reuse:

```sh
bash tools/mkfs-pdxb.sh /tmp/my-vol.img
```

Or with all knobs set:

```sh
PDXB_IMAGE_SIZE_MIB=256 \
PDXB_UUID=00112233445566778899aabbccddeeff \
PDXB_SIG_KEY=tests/qemu/keys/pdxb-dev.mldsa65.pub \
  bash tools/mkfs-pdxb.sh /tmp/my-vol.img
```

Under paideia-as 0.21 the BLAKE3 primitive has not yet landed, so the
mkfs binary emits this stderr line and continues:

```
SIG KEY HASH STUB: BLAKE3 primitive not landed; sig_key_hash left all-zero
```

This is expected. The wrapper exits 0 with:

```
MKFS PDXB WRAPPER OK
```

and the mkfs binary itself writes `MKFS PDXB OK` (from
`src/tools/mkfs-pdxb/main.pdx`) to stdout on success.

The superblock the tool lays down carries:

- Magic `PDXB` (`0x42584450` little-endian).
- The 128-bit volume UUID.
- The `sig_key_hash` field (zero-filled under the STUB above).
- Region descriptors: the arena, journal, and free-space bitmap ranges
  that the kernel's `sb_read` walks on mount.

Wrapper exit codes: `0` ok, `2` arg or config error, `3` mkfs binary is
not built (build the tool via `bash tools/build-user.sh` first).

---

## 6. Mounting the volume

There are two mount surfaces: the boot-time selector and the runtime
syscall.

### 6.1 Boot-time: root selection

`src/kernel/boot/root_select.pdx` picks a root volume by precedence:

1. **Hint** — a UUID stashed by loader/config (`_root_sel_hint_uuid_ptr`,
   currently a stub returning 0).
2. **Flag** — a UUID passed via kernel command line
   (`_root_sel_flag_uuid_ptr`, stub returning 0).
3. **Single** — if exactly one probed PdxFS-block volume exists, pick it.
4. **Fallback** — `ROOT_SEL_NONE = 0xFFFFFFFFFFFFFFFF`, and
   `mount_bootstrap` mounts tmpfs at `/` instead, emitting `PDXB ROOT
   FALLBACK TMPFS`.

A success prints `PDXB ROOT SELECTED`.

### 6.2 Runtime: `sys_mount` / `sys_umount`

The R53.M2-001 syscall realloc puts mount at syscall **75** and umount at
**76**. Signatures:

```
sys_mount(dev_path_ptr, dev_path_len,
          mount_point_ptr, mount_point_len,
          backend_id) -> u64
sys_umount(mount_point_ptr, mount_point_len, flags) -> u64
```

Backend IDs (from `src/kernel/core/fs/mount.pdx`):

- `0` → `MOUNT_BACKEND_TMPFS` (the boot fallback).
- `5` → `MOUNT_BACKEND_PDXFS_BLOCK` (on-block PdxFS).

Umount flags:

- `UMOUNT_LAZY = 0x1` — do not fail on busy vnodes; complete the umount
  when the last reference drops.

Error codes worth recognising (from `sys_mount.pdx` /
`sys_umount.pdx`):

- `0xFFFFED60` — bad backend id (not 0 or 5).
- `0xFFFFED61` — mount-point length 0 or > 256.
- `0xFFFFED63` — PdxFS-block backend still unimplemented at that call
  site.
- `0xFFFFED65` — EFAULT on user-pointer copy.
- `0xFFFFED68`..`0xFFFFED6E` — umount errors (bad flags, bad path,
  ENOENT, ENOTMOUNT, EROOT, EPENDING, EFAULT).

The maximum path length is `SYS_UMOUNT_PATH_MAX = 256`.

---

## 7. The two-phase round-trip smoke

The interesting question for a persistent filesystem is not "can I mount
it" but "can I mount it, write to it, unmount cleanly, reboot, remount,
and read back what I wrote". `boot_r53_round_trip` is that end-to-end
witness:

```sh
bash tools/run-smoke.sh boot_r53_round_trip
```

The meta-mode internally runs:

```
tools/run-smoke.sh --with-disk --wipe boot_r53_round_trip_phase1
tools/run-smoke.sh --with-disk        boot_r53_round_trip_phase2
```

Phase 1 (from `tests/r53/round-trip-phase1.golden`):

```
PDXFS MKFS SMOKE OK
PDXB PROBE OK
PDXFS BOOT MOUNT OK
PDXFS PKG INSTALL OK
PDXFS UMOUNT CLEAN OK
ROUND TRIP PHASE1 OK
```

Phase 2 (from `tests/r53/round-trip-phase2.golden`):

```
PDXB PROBE OK
PDXFS BOOT MOUNT OK
PDXFS REBOOT VERIFY OK
ROUND TRIP PHASE2 OK
```

Success closer:

```
smoke: boot_r53_round_trip meta-mode passed (phase1+phase2 clean)
```

The pre-push hook opts into the round-trip only when the operator sets:

```sh
export PAIDEIA_R53_DISK=1
```

Without that env, pre-push runs the substrate arms and skips the
disk-attached ones. Set it in your shell profile once you have real NVMe
smoke passing locally.

---

## 8. The tool ecosystem

The R49/R50 plan (`design/tooling/r49-r50-plan.md`) partitions the P0
userland surface into **fourteen** repositories, each MIT-licensed and
each at `github.com/paideia-os/<name>`.

Five libraries:

- `libpdx-cap` — capability handles, derivation, revocation helpers.
- `libpdx-semantic-pipe` — session-typed record streams (the semantic
  shell's transport).
- `libpdx-argv` — typed argument parsing.
- `libpdx-audit` — write-side of the audit journal.
- `libpdx-elevate` — client for the R48 elevate broker.

Nine tools:

- `pkg` — install / remove / list packages.
- `shell` — the interactive semantic shell.
- `doc` — semantic documentation reader.
- `ls`, `cat`, `cp`, `mv`, `rm`, `mkdir` — POSIX-shaped filesystem
  utilities over the typed VFS.

The volume-tooling contract in `design/tooling/volume-tooling-ux.md`
adds three more (`mkfs.pdxfs`, `mount.pdxfs`, `umount.pdxfs`) and a
`libpdx-volume` for a total of four volume repos beyond the P0 fourteen.

R49 lands the pkg + shell + doc + 5 libs slice; R50 lands the six
coreutils.

---

## 9. Installing a package with `pkg`

Fetch and build `pkg` outside the paideia-os tree so its dependency graph
stays clean:

```sh
mkdir -p ~/scratch/paideia-tools
cd ~/scratch/paideia-tools
git clone https://github.com/paideia-os/pkg.git
cd pkg
bash tools/build.sh
```

The pkg build uses `paideia-as 0.21.0` — the same assembler the
paideia-os submodule pins.

`pkg`'s op surface (see `src/dispatch.pdx` in the pkg repo):

- `pkg install <name>` — resolve, verify, and install a package under
  `/pkg/`.
- `pkg list` — enumerate installed packages.
- `pkg remove <name>` — uninstall.

The install path relies on two kernel primitives that landed in R48 and
R52.M6:

- The **elevate broker** at `ELEVATE_BROKER_ENDPOINT_ID = 16`
  (`src/kernel/core/ipc/elevate_broker.pdx`) with its userspace daemon at
  `src/user/elevate_broker_daemon.pdx`. `pkg` acquires the elevated
  capability set for `/pkg/` writes through this broker rather than
  running as root; the audit journal records every elevation.
- **Journalled writes** through `KIND_PDXFS_TXN = 0x196` with
  `PXT_OP_CREATE = 9` (`src/kernel/core/cap/kind_pdxfs_txn.pdx`). Every
  file `pkg install` creates goes through a `PXT_OP_CREATE` transaction
  that either commits atomically or aborts (`PXT_OP_ABORT = 8`). Renames
  and unlinks during upgrades use `PXT_OP_RENAME = 10` and
  `PXT_OP_UNLINK = 11`.

A completed install emits `PDXFS PKG INSTALL OK` (from
`src/kernel/boot/witness/pdxfs_pkg_install_smoke.pdx`) — that is the
same string round-trip phase 1 asserts.

---

## 10. Using the shell and the POSIX-shaped tools

Init (`src/user/init.pdx`, wired in R17.M2) forks the shell binary and
inherits fds 0/1/2 pointing at the TTY vnode. Once the shell prompt
appears you can drive it exactly like a text-mode shell for the common
operations:

```sh
ls /
cat /etc/motd
pkg install hello
hello
```

Redirection uses the standard `<`, `>`, `>>` forms; each redirect is a
`sys_dup2` onto fd 0/1 against the target vnode's fd.

The shell's semantic layer (records, session-typed pipes, the embedded
Datalog resolver) is available but is not required for basic file work;
the design contract is in `design/terminal/semantic-shell.md`.

---

## 11. Troubleshooting

**`M0305 module name mismatch`.** paideia-as enforces
`PascalCase(basename)` for `.pdx` module names. A file named `x_y.pdx`
must declare `module XY = structure { ... }`. Fix the module header;
this is not a build-system bug.

**`[FAIL] unwitnessed boot fingerprint (#1578 gate)`.** Every literal
`... OK` string the kernel emits must be either pinned in a boot-mode
golden under `tests/r*/` or added to the allowlist in
`tools/verify-fingerprint-coverage.sh`. New witnesses always come with a
new golden line; new debug prints get an allowlist entry.

**Symbol collision at link time.** Two modules are writing the same
symbol. Rename with a unique per-module prefix; the historical example
is the `mbs_*` prefix collision between `mount_bootstrap.pdx` and the
MBIM WWAN driver, resolved by renaming the mount-bootstrap symbols to
`mbot_*` (commit `6a9e653`). `MBOT_ROOT_VOLUME_CAP_SLOT = 176` is the
current, uncollided name for the boot mount's cap slot.

**`run-smoke.sh` hangs.** The runner asserts fingerprints
contain-in-order, so a hang usually means an earlier fingerprint did not
fire and the runner is waiting for a later one. Do not trust the golden's
diagnostic in this case — grep the raw serial log directly. Kill QEMU
with `Ctrl-A X` and dump the last hundred lines.

**`smoke: --with-disk requested but mkfs-pdxb binary is not built yet`.**
The userspace mkfs tool at `src/tools/mkfs-pdxb/` has not been built.
Run `bash tools/build-user.sh` (or a full `bash tools/build.sh`) so
`build/tools/mkfs-pdxb` exists, then retry.

**`SIG KEY HASH STUB`.** Expected under paideia-as 0.21 — the BLAKE3
primitive is not yet available so the mkfs binary writes an all-zero
`sig_key_hash`. Boot proceeds under
`PAIDEIA_DEV_UNSIGNED_ACCEPT=1`. This warning goes away when BLAKE3
lands.

---

## 12. UEFI/OVMF path (R19.M5)

Separate from the `-kernel` PVH path used everywhere else in this guide,
PaideiaOS also ships a paideia-native UEFI PE32+ stub
(`src/boot/uefi_*.pdx`, frozen at R19.M5 close). It boots as a real EFI
application under OVMF instead of QEMU's PVH direct-kernel-boot shortcut.
Full narrative + real-hardware (Thinkpad T14 G4) bring-up steps live in
`design/roadmap/r19-t14-g4-boot-guide.md`; this section covers only the
QEMU+OVMF loop.

Build the ESP image (each step re-runs the previous one if its output is
missing, so `bash tools/build-uefi-image.sh` alone is usually enough
once `build/kernel.elf` exists):

```sh
bash tools/build.sh              # → build/kernel.elf
bash tools/build-uefi-stub.sh    # → build/uefi/uefi_stub.efi
bash tools/build-uefi-image.sh   # → build/uefi/paideia-esp.img (64 MiB FAT32)
```

Boot it under QEMU + OVMF:

```sh
bash tools/run-uefi-ovmf.sh
```

The script auto-discovers OVMF firmware across distro layouts (Debian's
split `OVMF_CODE_4M.fd`/`OVMF_VARS_4M.fd`, Fedora's `edk2-ovmf` paths, a
merged `OVMF.fd`, or `PAIDEIA_UEFI_OVMF_CODE`/`_VARS` overrides for a
custom edk2 build). If no firmware is found it exits 77 (SKIP) rather
than failing — install it with:

```sh
sudo apt install ovmf          # Debian / Ubuntu
sudo dnf install edk2-ovmf     # Fedora
sudo pacman -S edk2-ovmf       # Arch
```

**Current expected fingerprint (R19.M5):** the single line
`paideia boot: entry ok`, pinned in `tests/expected-r19-ovmf.golden` and
read by `run-uefi-ovmf.sh` as its default `EXPECTED_MARKER`. This is
`efi_main`'s `ConOut->OutputString` banner — proof the stub loaded and
ran under OVMF's boot services. The stub's finalizer then jumps to the
LMA-resolved `kernel_main_uefi`, but at M5 nothing has loaded
`kernel.elf` into memory at that physical address (the ESP carries the
ELF at `/paideia/kernel.elf` for the *future* R20 loader to consume, not
M5 itself), so the CPU runs off the rails into firmware data and OVMF's
own exception handler eventually catches a `#UD`/`#GP`/`#PF`. That is
the correct, fully-expected M5 outcome — not a regression. Once the R20
ELF loader lands, re-run with the deeper marker:

```sh
PAIDEIA_UEFI_OVMF_MARKER="UEFI kernel_main entered" bash tools/run-uefi-ovmf.sh
```

To additionally exercise the R19.M3 TCG2 measured-boot path against a
software TPM:

```sh
bash tools/run-uefi-swtpm.sh
```

This is opt-in in the pre-push hook (`.githooks/pre-push`) behind
`PAIDEIA_UEFI_OVMF=1` — set it before pushing to gate on the OVMF
fixture; unset (the default), OVMF is skipped so a host without the
firmware package installed is never blocked. `run-uefi-swtpm.sh` is not
hooked into pre-push at all: a known OVMF+swtpm handshake hang on some
hosts (§6 of the T14 guide) makes it exploratory rather than a gate.

---

## 13. Where to go next

- `design/roadmap/next-wave-synthesis.md` — the full R29–R49 + G1–G6
  substrate roadmap, and the R50+ work that follows.
- `design/tooling/plan.md` — the canonical build order for the
  ~95-tool userland; start here before adding a new tool.
- `design/tooling/r49-r50-plan.md` — the fourteen-repo P0 slice
  covered in this guide.
- `design/tooling/volume-lifecycle-mechanism.md` and
  `design/tooling/volume-tooling-ux.md` — the volume UX contract
  operators should read before scripting against `mkfs-pdxb.sh`.
- `design/filesystem/volume-fs-substrate.md` — the on-block PdxFS
  substrate contract, including the superblock layout summarised in §5.
- `tools/hw-smoke-*.md` — recipes for the hardware-smoke tasks. Real
  T14 G4 execution is a separate, physical-device-only track; twelve
  hw-smoke issues are open in the paideia-os repo and cannot be
  discharged under QEMU.
