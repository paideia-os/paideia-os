# Post-R60 daily-use roadmap (rows 1-25)

**Date:** 2026-08-25
**HEAD at authoring:** paideia-os 5778fd0
**Sources:** osarch + softarch survey outputs 2026-08-25.
**Scope:** All 25 substantive rows from the daily-use ranking; row 26
(higher-level language design) excluded because it needs a design doc
before implementation planning.

This document is the authoritative mapping from the 25 daily-use
milestones to (a) GitHub milestone numbers, (b) their target repos, and
(c) their per-issue breakouts. Every row here becomes one GitHub
milestone in the named repo, with the listed sub-issues filed against
it. The bulk creation is executed by the parallel worker agents
described in `§Execution` below; this doc is what those agents read.

## Repo mapping

Each row lands in one repo. The paideia-os monorepo carries every
kernel-side change (rows 1, 2 kernel-halves, 5, 7-9, 12, 14-18, 21-24);
existing tool/lib repos carry the userland changes that belong to
already-published binaries (rows 3-4, 6, 10-11, 13, 19-20, 25); new
repos are created only for the two rows whose deliverables don't fit
an existing home.

| Row | Milestone label | Target repo(s) | Effort |
|-----|-----------------|----------------|--------|
| 1 | R61 tmpfs-seed real ELF extension | paideia-os | S |
| 2 | R62 execve argv/envp marshalling | paideia-os | M |
| 3 | R63 line editor MVP | **new: `line`** | S-M |
| 4 | R64 volume tooling completion | mkfs.pdxfs + mount.pdxfs + umount.pdxfs + libpdx-volume | L |
| 5 | R65 persistent home mount | paideia-os | L |
| 6 | R66 shell polish tier 1 | shell | S-M |
| 7 | R67 T14 G4 real-HW first boot | paideia-os | L |
| 8 | R68 disk-path debt discharge | paideia-os | S |
| 9 | R69 SMP scheduler real dispatch | paideia-os | M |
| 10 | R70 pkg MVP | pkg | L |
| 11 | R71 vi-like TUI editor `edit` | **new: `edit`** | XL |
| 12 | R72 TCP + BSD-ish sockets | paideia-os | XL |
| 13 | R73 shell tier 2 (job control + completion) | shell | M |
| 14 | R74 /etc configuration substrate | paideia-os + libpdx-config (new lib) | M |
| 15 | R75 ACPI S3 sleep/resume | paideia-os | L |
| 16 | R76 USB mass-storage + HID live | paideia-os | M |
| 17 | R77 Iris Xe display/modeset | paideia-os | L |
| 18 | R78 ACPICA/AML interpreter | paideia-os | L |
| 19 | R79 documentation viewer | doc | M |
| 20 | R80 networking client tools | **new: `ping`** + **new: `fetch`** | L |
| 21 | R81 HDA/ALC287 live audio | paideia-os | S-M |
| 22 | R82 kernel PQ crypto + TPM | paideia-os | XL |
| 23 | R83 Wi-Fi + Bluetooth live | paideia-os | L |
| 24 | R84 Thunderbolt 4 / USB4 live | paideia-os | XL |
| 25 | R85 ssh/remote secure shell | **new: `remote`** | XL |

New repos to create: `line`, `edit`, `ping`, `fetch`, `remote`. All
five are MIT-licensed under the paideia-os org per
`memory/project_license_and_extensions.md`.

The `R6N` numbering picks up from R60 (last landed round in
paideia-os) — dependent rows in the softarch-first block (rows 1-6)
take R61-R66, then osarch-first (7-9) take R67-R69, then the rest
interleave in ranking order.

## Per-row milestone + issue breakouts

Every milestone lists 4-8 M-numbered sub-issues; each becomes one
GitHub issue. Titles use the compact `RNN.MK-LLL <topic>` shape from
prior rounds. Bodies are 8-15 lines with **Scope**, **Files touched**,
**Fingerprint** (when applicable), **Effort**, **Deps** sections
matching `.plans/issue-map.tsv` conventions.

---

### R61 — tmpfs-seed real ELF extension (paideia-os)

**Intent:** Extend `bin_seeds.pdx` beyond `sh` + `true` so every built
`/bin/*` ELF actually reaches tmpfs at boot. Single-milestone round.

- **R61.M1-001** Inventory current `userbin_embed.S` symbol pairs; add
  `_ls_bin_start/end`, `_cat_bin_start/end`, `_ps_bin_start/end`,
  `_rm_bin_start/end`, `_mv_bin_start/end`, `_cp_bin_start/end`,
  `_mkdir_bin_start/end`, `_touch_bin_start/end`, `_dmesg_bin_start/end`.
- **R61.M1-002** Extend `witness_bin_seeds` to embed the 9 new
  binaries into tmpfs at `/bin/ls`, `/bin/cat`, ..., `/bin/dmesg` via
  the existing `bin_sh_seed`/`bin_true_seed` shape.
- **R61.M1-003** Fingerprint discipline — one `bin seed ok --
  file=/bin/<name> bytes=<N>` per binary via klog_s1_x2, per the
  bin_seeds.pdx pattern.
- **R61.M1-004** Boot-transcript regression: verify `bash
  tools/run-qemu.sh` reaches SHELL START and 9 new seed fingerprints
  appear in order. No new user-side changes required.
- **R61.M1-005** Round closure: STATUS block + retrospective at
  `design/round-retrospectives/r61-closure.md` + `r61-closed` tag.

### R62 — execve argv/envp marshalling (paideia-os)

**Intent:** Real argv[]/envp[] through `sys_execve_shim` so tools stop
hardcoding M0 paths. Unblocks 5+ R58 tools + pkg + editors.

- **R62.M1-001** Freeze argc/argv/envp ABI: user `_start` receives
  argc in rdi, argv in rsi, envp in rdx (SysV-ish); document in
  `design/user/execve-abi.md`.
- **R62.M1-002** `sys_execve_shim.pdx`: copy caller argv + envp
  vectors into a kernel scratch (bounded 4 KiB each), unmap+remap old
  user stack, splice argc/argv/envp onto new user stack per the
  frozen ABI.
- **R62.M1-003** `sys_execve_shim` §Non-Scope comments retired;
  fingerprint `sys execve argv ok -- argc=<N> envc=<M>` on the
  argv-populated path.
- **R62.M1-004** Migrate `/bin/ls` first: replace hardcoded `/` with
  argv[1] fallback; verify boot-through-shell exercise works.
- **R62.M1-005** Migrate `/bin/cat`, `/bin/rm`, `/bin/mv`, `/bin/cp`,
  `/bin/mkdir`, `/bin/touch`, `/bin/dmesg` to read argv (batch commit
  once #001-#004 land).
- **R62.M1-006** Update `design/user/rootfs-seed-inventory.md` argv
  posture note.
- **R62.M1-007** Round closure retro + `r62-closed` tag.

### R63 — line editor MVP (new repo: `line`)

**Intent:** `ed`-style scriptable line editor for the smallest daily-use
unlock. Category C tier-1 per `design/tooling/plan.md`.

- **R63.M1-001** Repo bootstrap: `line/` with README, MIT LICENSE,
  `Cargo.toml`-analog build integration into paideia-os build-user.sh.
- **R63.M1-002** Command grammar: `a`, `i`, `d`, `c`, `p`, `w`, `q`,
  `Q`, `.`, `,`, `$`, address-range parser.
- **R63.M1-003** Buffer state: line-array with cursor position; edit
  operations (insert, delete, replace) at 1-based line addresses.
- **R63.M1-004** File I/O: `w <path>` writes buffer to file via
  sys_open(O_CREAT|O_WRONLY|O_TRUNC) + sys_write; `e <path>` reads
  file into buffer.
- **R63.M1-005** Interactive loop: prompt (`:` per ed convention),
  read line via existing `puts_new`/`getline` from libc, dispatch.
- **R63.M1-006** Fingerprint `line ok -- lines=<N>` on `q`; error
  markers `LINE READ FAIL`, `LINE WRITE FAIL`, `LINE PARSE FAIL`.
- **R63.M1-007** paideia-os `bin_seeds.pdx` extension (extends R61)
  to embed `line.elf` at `/bin/line`.
- **R63.M1-008** Round closure retro at `design/round-retrospectives/
  r63-closure.md` in paideia-os; `r63-closed` tag on `line` repo.

### R64 — volume tooling completion (mkfs.pdxfs + mount.pdxfs + umount.pdxfs + libpdx-volume)

**Intent:** Finish the four volume tools per
`design/tooling/volume-tooling-ux.md`. Prerequisite for R65 persistent
home.

- **R64.M1-001** `libpdx-volume`: KIND_VOLUME helper API (open, mint,
  release), PDXB superblock codec (parse + emit + validate), signature
  bytes read/write over Kyber/Dilithium keypair.
- **R64.M1-002** `mkfs.pdxfs`: argv-driven `mkfs.pdxfs /dev/nvme0 [-k
  <keypair>]`; writes PDXB superblock + WAL header + free-space
  bitmap + root inode; fingerprint `mkfs ok -- volume=/dev/nvme0
  size=<N> root_ino=<K>`.
- **R64.M1-003** `mount.pdxfs`: `mount.pdxfs /dev/nvme0
  /mnt/pdxvol0`; sys_mount + PdxFsMountRecord audit; fingerprint
  `mount ok -- src=<d> mp=<p> backend=PDXFS_BLOCK`.
- **R64.M1-004** `umount.pdxfs`: sys_umount + WAL CLEAN checkpoint;
  fingerprint `umount ok -- mp=<p>`.
- **R64.M1-005** paideia-os `bin_seeds.pdx` seeds `mkfs.pdxfs.elf`,
  `mount.pdxfs.elf`, `umount.pdxfs.elf` under `/bin/`.
- **R64.M1-006** Doc: `doc/user-guide/volume-tools.md` walkthrough:
  mkfs → mount → write → unmount → remount → readback.
- **R64.M1-007** Round closure retro + `r64-closed` tag across all 4
  repos.

### R65 — persistent home mount (paideia-os)

**Intent:** Init mounts a PdxFS-block volume at `/home/operator`
before shell start; state survives reboot.

- **R65.M1-001** `src/user/init.pdx` extension: after `rootfs_seed`,
  call `sys_stat(/dev/nvme0)`; if present + PDXB-superblock-valid,
  sys_mount to `/home/operator`; otherwise skip.
- **R65.M1-002** Init `PATH=/bin:/usr/bin` + `HOME=/home/operator`
  environment prep (blocked on R62 envp landing; sequence AFTER R62).
- **R65.M1-003** Shell `cd` builtin: on entry, chdir to `HOME` if
  set; fingerprint `shell cwd init ok -- cwd=<path>`.
- **R65.M1-004** Boot smoke `boot_r65_persistent_home`: cold boot →
  mount → cd $HOME → touch /home/operator/hello → unmount → reboot →
  remount → stat /home/operator/hello succeeds.
- **R65.M1-005** `PAIDEIA_R65_PERSIST=1` pre-push gate on smoke.
- **R65.M1-006** Design doc `design/user/persistent-home.md`.
- **R65.M1-007** Round closure retro + `r65-closed` tag.

### R66 — shell polish tier 1 (shell)

**Intent:** Backspace + cursor keys + up-arrow history. Makes the
shell tolerable for sustained use.

- **R66.M1-001** Raw-mode tty input path: extend `shell_read_line` to
  read one byte at a time with ESC-sequence recognition (CSI A / CSI
  B / CSI C / CSI D for arrow keys, 0x7F for backspace).
- **R66.M1-002** Backspace: delete last byte, emit `\b \b` to erase
  on screen.
- **R66.M1-003** History ring: `[u8; 4096]` circular buffer of past
  commands, indexed by newline; up-arrow recalls prev, down-arrow
  recalls next; fingerprint `shell history ok -- entries=<N>`.
- **R66.M1-004** Cursor-left / cursor-right within current line;
  in-place edit + redraw.
- **R66.M1-005** Design doc `design/user/shell-line-editing.md`.
- **R66.M1-006** Round closure retro (in paideia-os retros dir since
  smoke lives there) + `r66-closed` tag on `shell` repo.

### R67 — T14 G4 real-HW first boot (paideia-os)

**Intent:** Execute the paideia-native UEFI PE32+ stub on physical
hardware; promote every `design/hardware/quirks.md` `PROVISIONAL` row
to `CONFIRMED` / `WORKED-AROUND`. Only path to leaving QEMU.

- **R67.M1-001** UEFI stub sanity: verify `src/boot/uefi_*.pdx`
  builds a signed PE32+ that FastBoot-compatible UEFI accepts.
- **R67.M1-002** GOP first-light: kernel writes to GOP LFB before any
  driver; fingerprint via COM1 fallback if serial is enabled in
  firmware.
- **R67.M1-003** ACPI table discovery: locate RSDP via UEFI
  ConfigurationTable, walk XSDT, extract MADT/FADT/DSDT addresses.
- **R67.M1-004** VMD probe (blocking NVMe on VMD-enabled hardware):
  wire the R47 VMD driver into the boot path.
- **R67.M1-005** Quirks table sweep — for every `PROVISIONAL` row in
  `design/hardware/quirks.md` on T14 G4, execute the described
  observation on real hw + promote to `CONFIRMED` or `WORKED-AROUND`.
- **R67.M1-006** Boot-transcript real-hw pass: serial log captured to
  `tests/hw/expected-r67-t14-first-boot.golden`.
- **R67.M1-007** Design doc `design/hardware/t14-g4-first-boot-hw-
  observations.md` — what actually happened, deltas from QEMU.
- **R67.M1-008** Round closure retro + `r67-closed` tag.

### R68 — disk-path debt discharge (paideia-os)

**Intent:** Land the cross-repo paideia-as fix blocking mkfs-pdxb
round-trip witnesses + run the deferred `boot_r5{4,5,6}` composite
smokes with `--with-disk`.

- **R68.M1-001** paideia-as encoder gap for mkfs-pdxb round-trip:
  identify the exact failing shape, file paideia-as issue, land fix,
  bump submodule.
- **R68.M1-002** `boot_r54_disk_bdev_roundtrip` composite smoke +
  golden.
- **R68.M1-003** `boot_r55_write_e2e` composite smoke run with
  `PAIDEIA_R55_DISK=1`, capture golden.
- **R68.M1-004** `boot_r56_meta` composite smoke run with real disk,
  capture golden.
- **R68.M1-005** `PAIDEIA_R68_DISK=1` pre-push gate covering all
  three composite smokes.
- **R68.M1-006** Round closure retro + `r68-closed` tag.

### R69 — SMP scheduler real dispatch (paideia-os)

**Intent:** APs currently wake, init a per-CPU runqueue, then park in
`cli/hlt`. Wire IPI-driven preemption + cross-core enqueue/steal.

- **R69.M1-001** Runqueue restructure: split BSP-only runqueue into
  per-CPU runqueues; verify `sched/ap_bringup.pdx` initializes each
  correctly.
- **R69.M1-002** Cross-CPU enqueue: `sched_wake` on a task with
  affinity to CPU N sends an IPI to CPU N; the target CPU's
  `handle_ipi_wake` moves the task to its runqueue and preempts.
- **R69.M1-003** Work-stealing: idle AP that finds its runqueue
  empty scans sibling runqueues (round-robin) and steals half the
  work from the fullest.
- **R69.M1-004** SMP fairness smoke `boot_r69_smp_dispatch`: spawn
  8 CPU-bound tasks, verify all cores tick.
- **R69.M1-005** `PAIDEIA_R69_SMP=1` pre-push gate.
- **R69.M1-006** Round closure retro + `r69-closed` tag.

### R70 — pkg MVP (pkg)

**Intent:** `pkg install <name>` against a local filesystem-path repo
per `design/tooling/plan.md` §6. First real package-manager use.

- **R70.M1-001** Repo bootstrap for pkg: source tree, build
  integration, README.
- **R70.M1-002** Manifest format: JSON-ish schema for
  `<name>-<version>.pdxpkg` with fields `{name, version, files[],
  deps[], signature}`.
- **R70.M1-003** Repo index: `<repo>/index.pdxpkg` listing available
  packages; `pkg list` walks it.
- **R70.M1-004** `pkg install <name>`: fetch manifest, verify
  signature (stub-to-trust-local at v0), extract files to their
  target paths, register in `/var/pkg/installed.pdxpkg`.
- **R70.M1-005** `pkg remove <name>`: reverse; undo record via
  libpdx-audit.
- **R70.M1-006** `pkg upgrade <name>`: install newer version,
  atomic swap via mkdir tempdir + rename.
- **R70.M1-007** Design doc `design/tooling/pkg-mvp.md`.
- **R70.M1-008** Round closure retro + `r70-closed` tag.

### R71 — vi-like TUI editor `edit` (new repo: edit)

**Intent:** Category C P0 primary editor. Modeless, full-screen. Daily
driver replacement for `line`.

- **R71.M1-001** Repo bootstrap: `edit/` with README, LICENSE, build
  integration.
- **R71.M1-002** Raw-mode tty: enter alt-screen, cursor addressing
  via ANSI CSI, restore-on-exit.
- **R71.M1-003** Buffer model: gap buffer or piece-table (small file
  cap 64 KiB M0).
- **R71.M1-004** Rendering: viewport walker; redraw dirty lines only.
- **R71.M1-005** Basic editing: insert, delete char, delete line,
  cursor motion (arrow keys + hjkl aliases), file open + save.
- **R71.M1-006** Modal command line (`:w`, `:q`, `:wq`, `:e <file>`).
- **R71.M1-007** Fingerprint `edit ok -- file=<path> bytes=<N>` on
  save; `edit exit -- unsaved-changes=<0|1>` on quit.
- **R71.M1-008** paideia-os `bin_seeds.pdx` seeds `edit.elf` at
  `/bin/edit`.
- **R71.M1-009** Round closure retro + `r71-closed` tag on `edit`.

### R72 — TCP + BSD-ish sockets (paideia-os)

**Intent:** Build TCP on the existing l2/arp/ipv4/icmp/udp files;
extend socket KIND caps. `curl`/`ssh`/package-fetch depend on this.

- **R72.M1-001** TCP state machine: 11 states (CLOSED, LISTEN,
  SYN_SENT, SYN_RECEIVED, ESTABLISHED, FIN_WAIT_1, FIN_WAIT_2,
  CLOSE_WAIT, CLOSING, LAST_ACK, TIME_WAIT).
- **R72.M1-002** TCP handshake: 3-way SYN/SYN-ACK/ACK; SYN cookies
  for LISTEN.
- **R72.M1-003** TCP retransmit: RTO, RFC 6298 Karn's algorithm;
  slow-start CWND.
- **R72.M1-004** TCP congestion control: Reno-analog (cwnd,
  ssthresh, fast retransmit).
- **R72.M1-005** Socket API: `sys_socket`, `sys_bind`, `sys_listen`,
  `sys_accept`, `sys_connect`, `sys_send`, `sys_recv`, `sys_shutdown`.
- **R72.M1-006** KIND_TCP_SOCKET + KIND_TCP_LISTENER cap kinds; wire
  through cap_table.
- **R72.M1-007** Boot smoke `boot_r72_tcp_echo`: loopback TCP echo
  server + client fingerprint sequence.
- **R72.M1-008** Design doc `design/kernel/tcp-substrate.md`.
- **R72.M1-009** Round closure retro + `r72-closed` tag.

### R73 — shell tier 2 (job control + tab completion) (shell)

**Intent:** `^Z`/`bg`/`fg` + PATH-aware tab completion.

- **R73.M1-001** SIGSTOP/SIGCONT syscalls (`sys_kill(pid, signum)`)
  + kernel-side state transitions on stopped tasks.
- **R73.M1-002** Shell process-group tracking; `^Z` in raw-mode
  stops foreground, prints `[<n>]+ Stopped   <cmd>`.
- **R73.M1-003** `bg [<n>]` continues stopped job in background;
  `fg [<n>]` reattaches.
- **R73.M1-004** `jobs` builtin lists tracked stopped/running-bg
  jobs.
- **R73.M1-005** Tab completion: on TAB, tokenize prefix, if at
  argv[0] position walk PATH prefixes and enumerate matching /bin
  entries; if in argv[1..] position, enumerate cwd entries.
- **R73.M1-006** Fingerprints: `shell job ok -- n=<N> pid=<P>
  state=<S>`, `shell complete ok -- prefix=<X> matches=<M>`.
- **R73.M1-007** Round closure retro + `r73-closed` tag on `shell`.

### R74 — /etc configuration substrate (paideia-os + new lib libpdx-config)

**Intent:** sysctl-equivalent + defaults that survive reboot.

- **R74.M1-001** `libpdx-config` repo bootstrap.
- **R74.M1-002** `/etc` layout: define `/etc/hostname`,
  `/etc/paideia.conf`, `/etc/motd`, `/etc/passwd`-analog.
- **R74.M1-003** Config file format: line-oriented `key = value` with
  section headers `[<section>]`; parser in libpdx-config.
- **R74.M1-004** `sysctl`-analog tool: `sysctl <key>` reads,
  `sysctl <key>=<value>` writes; persists to `/etc/paideia.conf`.
- **R74.M1-005** Init reads `/etc/paideia.conf` at boot, sets kernel
  parameters (log level, per-cpu runqueue depth, ...).
- **R74.M1-006** Doc `doc/user-guide/etc-configuration.md`.
- **R74.M1-007** Round closure retro + `r74-closed` tag.

### R75 — ACPI S3 sleep/resume (paideia-os)

**Intent:** Laptop actually suspends. Table-stakes for daily use.

- **R75.M1-001** `_PTS(3)` invocation via AML (depends on R78
  ACPICA/AML — but can M0-stub with FADT PM1a_CNT direct write).
- **R75.M1-002** Device state save: iterate active drivers, invoke
  each's `suspend()` op (needs new driver-model callback).
- **R75.M1-003** Cache flush + write final PM1a_CNT (SLP_TYPa | SLP_EN).
- **R75.M1-004** Wake path: firmware jumps to waking vector
  (installed pre-sleep in FADT); kernel resumes from that entry.
- **R75.M1-005** `_WAK` + device state restore.
- **R75.M1-006** Lid-close detection via EC → sleep entry (needs R31
  EC + a new lid-event dispatcher).
- **R75.M1-007** Boot smoke `boot_r75_s3_cycle`: enter S3, wake via
  RTC alarm, verify state restored (real HW only).
- **R75.M1-008** Round closure retro + `r75-closed` tag.

### R76 — USB mass-storage + full HID live (paideia-os)

**Intent:** BOT/UAS mass-storage + touchpad/TrackPoint/fingerprint —
drivers written under R34 but never live-exercised.

- **R76.M1-001** Real-hw exercise of BOT (Bulk-Only Transport) mass
  storage: enumerate USB drive, mount its FAT/exFAT partition, read
  a file.
- **R76.M1-002** UAS (USB Attached SCSI) exercise: same for UAS-mode
  drive.
- **R76.M1-003** Synaptics touchpad: real-hw HID descriptor walk,
  two-finger scroll observed on `boot_r32_m5_004` on T14 G4.
- **R76.M1-004** ELAN touchpad live exercise on candidate T14 SKUs.
- **R76.M1-005** TrackPoint HID live exercise.
- **R76.M1-006** Goodix fingerprint reader live: enumerate + start-
  session + capture-sample; fingerprint match verify.
- **R76.M1-007** Boot smoke `boot_r76_usb_devices` composite.
- **R76.M1-008** Round closure retro + `r76-closed` tag.

### R77 — Iris Xe display/modeset (paideia-os)

**Intent:** CDCLK/pipes/planes/DDI atomic modeset. Only cap/IPC stubs
exist today. Prerequisite for any compositor.

- **R77.M1-001** CDCLK programming: init, PLL lock, verify against
  DPLL spec.
- **R77.M1-002** Pipe programming: PIPE_MISC, PIPE_CONF, plane
  attach.
- **R77.M1-003** Plane programming: primary plane bind BO, format
  (RGB8), scaler config.
- **R77.M1-004** Transcoder programming: TRANS_HTOTAL/VTOTAL/HSYNC/
  VSYNC/HBLANK/VBLANK; timing from EDID DTD.
- **R77.M1-005** DDI/eDP link training: TP1/TP2/TP3 sequences,
  channel-equalization.
- **R77.M1-006** Modeset composition over the GOP handoff LFB: seamless
  transition from GOP framebuffer to native scanout.
- **R77.M1-007** Boot smoke `boot_r77_modeset_native`: switch away
  from GOP FB to native scanout, verify a solid color displays.
- **R77.M1-008** Round closure retro + `r77-closed` tag.

### R78 — ACPICA/AML interpreter (paideia-os)

**Intent:** Vendor `_Qxx` methods (Fn-keys, thermal, backlight) need
real AML — static parsing structurally cannot run them.

- **R78.M1-001** AML tokenizer: opcode + prefix + package length +
  name-string parsing.
- **R78.M1-002** AML term parser: build AML-op tree from tokens.
- **R78.M1-003** AML namespace: walk DSDT/SSDTs, populate
  `\_SB.*`, `\_TZ.*`, `\_PR.*` nodes.
- **R78.M1-004** AML interpreter: evaluate `Method`, `If`, `While`,
  `Return`, `Store`, `And`, `Or`, `Add`, `Subtract`, `Package`,
  `Buffer`, `Field`.
- **R78.M1-005** Operation region I/O: SystemIO (port), SystemMemory
  (MMIO), Embedded Controller (via R31 EC path).
- **R78.M1-006** Method invocation: `_STA`, `_INI`, `_CRS`, `_Qxx`,
  `_PSR`, `_BAT` per T14 G4 DSDT.
- **R78.M1-007** GPE dispatcher wired through AML `_Lxx`/`_Exx`.
- **R78.M1-008** Boot smoke `boot_r78_aml_fn_keys`: press Fn+F5 →
  brightness decreases; press Fn+F6 → increases.
- **R78.M1-009** Round closure retro + `r78-closed` tag.

### R79 — documentation viewer (doc)

**Intent:** `doc <tool>` opens `.pdxdoc` shipped with each tool.
Replaces "read the design/ markdown in a host editor."

- **R79.M1-001** `.pdxdoc` format spec: markdown-lite subset
  (headers, code blocks, lists, bold, italic).
- **R79.M1-002** `doc` binary: opens `/share/doc/<name>.pdxdoc`,
  renders to tty with ANSI styling.
- **R79.M1-003** Pager: page-up / page-down / `/` search / `q` quit.
- **R79.M1-004** Content: `.pdxdoc` for each of shell, ls, cat, ps,
  rm, mv, cp, mkdir, touch, dmesg, line, edit, pkg, sysctl.
- **R79.M1-005** paideia-os `bin_seeds.pdx` seeds `doc.elf` + `/share/
  doc/*.pdxdoc` bundle.
- **R79.M1-006** Round closure retro + `r79-closed` tag on `doc`.

### R80 — networking client tools (new repos: ping + fetch)

**Intent:** Userland wrappers over the R72 TCP + existing UDP/ICMP
substrate. Enables `pkg` repo-add over network.

- **R80.M1-001** `ping` repo bootstrap.
- **R80.M1-002** `ping <host>`: DNS resolve (needs kernel
  `sys_gethostbyname` or client-side stub-resolver), ICMP echo, loop
  with RTT reporting.
- **R80.M1-003** `fetch` repo bootstrap.
- **R80.M1-004** `fetch <url>`: HTTP/1.1 GET over TCP (R72), write
  body to stdout or `-o <file>`; HTTPS deferred to R82 crypto.
- **R80.M1-005** paideia-os `bin_seeds.pdx` seeds `ping.elf` + `fetch.elf`.
- **R80.M1-006** Round closure retro + `r80-closed` tag on `ping` +
  `fetch`.

### R81 — HDA/ALC287 live audio (paideia-os)

**Intent:** Operator hears sound. Controller + codec + CORB/RIRB + BDL
all written under R33; exercise real PCM + jack-detect.

- **R81.M1-001** HDA controller live init on T14 G4 (or QEMU
  ich9-hda for CI): CORB/RIRB rings live, MSI-X wire.
- **R81.M1-002** ALC287 codec discovery + node graph walk.
- **R81.M1-003** BDL programming for a single output stream (44.1
  kHz stereo).
- **R81.M1-004** Sine-wave test tone playback via `/bin/sinetone`
  (new tiny binary).
- **R81.M1-005** Jack-detect via unsolicited response → HP/SPK
  switch (paideia-os R33.M4 driver exists; wire to real ISR).
- **R81.M1-006** Boot smoke `boot_r81_audio_playback`.
- **R81.M1-007** Round closure retro + `r81-closed` tag.

### R82 — kernel PQ crypto + TPM (paideia-os)

**Intent:** Real ML-KEM-768 + ML-DSA-65 + SLH-DSA-128f + entropy pool.
TPM 2.0 CRB/PTT driver. FS sigs become real, not placeholder.

- **R82.M1-001** Entropy pool: RDSEED / RDRAND fallback; kernel-side
  `/dev/urandom`-analog via sys_random(buf, len).
- **R82.M1-002** ML-KEM-768 keypair generation + encap + decap
  primitives per FIPS-203.
- **R82.M1-003** ML-DSA-65 keypair + sign + verify per FIPS-204.
- **R82.M1-004** SLH-DSA-128f sign + verify per FIPS-205 (stateless
  hash-based fallback).
- **R82.M1-005** Sig-verify replacement: PdxFS sig-verify stub →
  real ML-DSA-65 verify.
- **R82.M1-006** TPM 2.0 CRB driver: base register discovery via
  ACPI, command/response protocol, PCR read/extend.
- **R82.M1-007** TPM 2.0 PTT (Platform Trust Technology — Intel
  firmware TPM) discovery + init on T14 G4.
- **R82.M1-008** UEFI TCG2 log consumption: replay event log into
  TPM PCRs at boot.
- **R82.M1-009** Boot smoke `boot_r82_crypto_pcr` (real hw only).
- **R82.M1-010** Round closure retro + `r82-closed` tag.

### R83 — Wi-Fi + Bluetooth live (paideia-os)

**Intent:** Extensive AX211/WPA3-SAE/net80211/hci_cnvi/gatt/a2dp/hfp
driver corpus exists; live-exercise against real radios/firmware.

- **R83.M1-001** AX211 firmware load real-hw path: locate
  `iwlwifi-ty-*.ucode`, upload via existing driver.
- **R83.M1-002** Wi-Fi scan: active + passive scan, AP list.
- **R83.M1-003** WPA3-SAE association: 4-way handshake, PTK/GTK
  install.
- **R83.M1-004** 802.11ax data path live: send/receive real frames;
  ping over Wi-Fi.
- **R83.M1-005** CNVi Bluetooth firmware handoff (shared radio).
- **R83.M1-006** HCI + L2CAP + GATT live: discover paired device,
  read characteristic.
- **R83.M1-007** A2DP audio sink (paired-speaker) live playback.
- **R83.M1-008** HFP handsfree profile live (paired-headset).
- **R83.M1-009** LE Audio live (paired-earbuds).
- **R83.M1-010** Round closure retro + `r83-closed` tag.

### R84 — Thunderbolt 4 / USB4 live (paideia-os)

**Intent:** 29-file scaffold (NHI + CM FSM + tunnels + per-dock
IOMMU domain) written but never live-exercised.

- **R84.M1-001** NHI probe live: TB4 controller enumeration on T14.
- **R84.M1-002** CM FSM live: connect docking station, verify router
  discovery.
- **R84.M1-003** PCIe tunnel live: dock's PCIe device (e.g. NIC)
  appears in tunneled bus.
- **R84.M1-004** DP tunnel live: external display via TB4 to dock DP
  output.
- **R84.M1-005** USB3 tunnel live: USB peripheral on dock port
  enumerates via tunneled xHCI.
- **R84.M1-006** Per-dock IOMMU domain isolation: verify DMA from
  tunneled device confined.
- **R84.M1-007** Hot-plug live: connect/disconnect dock, verify
  clean teardown.
- **R84.M1-008** Round closure retro + `r84-closed` tag.

### R85 — ssh/remote secure shell (new repo: remote)

**Intent:** Remote administration without physical console. ML-KEM
key exchange over TCP; Category B `remote` + `rcopy` per plan.

- **R85.M1-001** Repo bootstrap `remote`.
- **R85.M1-002** ML-KEM-768 key exchange over TCP (needs R82 crypto).
- **R85.M1-003** Encrypted channel: ChaCha20-Poly1305 (session key
  from ML-KEM secret).
- **R85.M1-004** `remote <host>`: authenticate, spawn remote shell,
  bridge local tty to remote pty via encrypted channel.
- **R85.M1-005** `rcopy <local> <host>:<remote>`: file transfer over
  the same channel.
- **R85.M1-006** Fingerprint `remote ok -- host=<H> peer_key=<hex8>`.
- **R85.M1-007** paideia-os `bin_seeds.pdx` seeds `remote.elf` +
  `rcopy.elf`.
- **R85.M1-008** Round closure retro + `r85-closed` tag on `remote`.

## Execution

The `.plans/post-r60-milestone-fanout.sh` script (created by the
first worker; committed to paideia-os) drives the mechanical
create-milestone + create-issue steps. Each worker takes ownership of
a contiguous row range and runs:

```
# For each row in [start..end]:
#   gh api repos/<owner>/<repo>/milestones -f title=... -f description=...
#   for each M-numbered sub-issue in this doc:
#     gh issue create --repo <owner>/<repo> --milestone "..." --title ... --body ...
```

Worker split (5 workers, chosen so each takes ~5 milestone rows and
~30-40 issues):

- **Worker A**: rows 1-5 (R61-R65)
- **Worker B**: rows 6-10 (R66-R70)
- **Worker C**: rows 11-15 (R71-R75)
- **Worker D**: rows 16-20 (R76-R80)
- **Worker E**: rows 21-25 (R81-R85)

Each worker reads this doc, opens its assigned rows in
`design/roadmap/post-r60-daily-use-roadmap.md`, then runs the
mechanical `gh` sequence. Repo creation for the 6 new repos (line,
edit, ping, fetch, remote, libpdx-config) is Worker C's opening step
since it holds the first new-repo landing (R71 edit).

Total expected: 25 milestones, ~155 issues, 6 new repos.
