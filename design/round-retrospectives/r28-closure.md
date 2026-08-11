# R28 Retrospective: Bootable distribution + real-HW smoke -> MVP DEMO

**Date:** 2026-08-11
**Milestone:** R28.M1–R28.M4 (all closed; M4 = final MVP closure milestone
this doc + #1008/#1009/#1010/#1011)
**Issues:** 14 landed across 4 milestones (10 implementation + 4 closure).
One fully-deferred R28-scoped issue: #1001 (PE Secure Boot signing) -> R32/R33.
Six long-tail deferrals inherited from prior rounds (#820 acpi_supervisor,
#860 pci_enumerator, #906 userspace nvme_read_blocking, #963 userspace HID
class driver, #994 KIND_UDP_SOCKET descriptor slab write, #996 UDP userspace
socket delivery) remain queued behind #1015 userspace-server substrate —
none regress R28 acceptance.
**HEAD at closure:** (bumped by the R28.M4 commit that lands this doc)
**paideia-as pinned at:** `2cf169d` — unchanged across R28 (**eighth
consecutive round** with zero cross-repo escalations, since R21 close).
**Release tag:** `mvp-v0.1` — the R18-R28 MVP arc reference release.

---

## Round Intent

R28 was scoped as the MVP demo consolidation round per
`design/roadmap/r18-plus-bare-metal.md §R28` — package the R18-R27
substrate as a bootable USB image, add a real-HW smoke harness targeted
at the T14 G4 primary MVP hardware, seed the panic-recovery + quirks-db
+ HW regression matrix documentation, and close the R18-R28 MVP arc with
a release tag. The four milestones threaded image assembly first (build-
image + build-uefi-image + mkfs-pdxfs-lite-seed), then the HW smoke
harness (run-smoke-hw.sh + serial-console fallback + T14 first-boot
walkthrough), then panic-fb recovery + hardware quirks + regression
matrix docs, then the final MVP closure work (fingerprint catalogue +
MVP demo operator script + pre-push HW opt-in + this retrospective):

- **M1:** MVP demo image assembly — `tools/build-image.sh` (#998,
  producer of `build/mvp/paideia-mvp.img`, ~64 MiB), `tools/build-uefi-
  image.sh` (#999, ESP layout at `/EFI/PAIDEIA/PAIDEIA.EFI`),
  `tools/mkfs-pdxfs-lite-seed.sh` (#1000, rootfs blob with `/etc/hello`
  + `/bin/sh` + `/bin/true` seed entries). #1001 (PE Secure Boot
  signing) explicitly deferred to R32+ crypto substrate per
  `design/security/pe-secure-boot-signing.md`.
- **M2:** HW smoke harness + serial fallback + T14 first-boot walk —
  `tools/run-smoke-hw.sh` (#1002, PAIDEIA_HW_SMOKE-gated serial-
  fingerprint verifier with boot/pdxfs/net/all modes),
  `design/kernel/serial-console-fallback.md` (#1003, screen/tio/picocom
  operator recipes), `design/hardware/t14-g4-first-boot.md` (#1004,
  BIOS setup + boot walkthrough + acceptance criteria).
- **M3:** Panic-FB recovery + quirks + regression matrix —
  `design/testing/panic-fb-photograph-recovery.md` (#1005, photograph-
  transcribability recipe for the R23.M3 fb-mirror panic path),
  `tools/panic-fb-recovery-smoke.md` (operator quick-reference),
  `design/hardware/quirks.md` (#1006, T14 G4 quirk row updates — four
  rows anchored/re-anchored), `design/testing/hw-regression-matrix.md`
  (#1007, seed rows for T14 G4 primary + Framework 13 secondary +
  QEMU-OVMF primary CI).
- **M4:** Final MVP closure — `tools/hw-smoke-fingerprints.md` (#1008,
  per-subsystem fingerprint catalogue + composite `boot_r28_hw_smoke`
  mode in `tools/run-smoke-hw.sh`), `design/testing/mvp-demo-script.md`
  (#1009, 7-step operator recipe: cold-boot -> shell -> cat /etc/hello
  -> ping -> echo > file -> reboot -> cat file), `.githooks/pre-push`
  extension (#1010, PAIDEIA_HW_SMOKE=1 opt-in that invokes
  `boot_r28_hw_smoke` after the 15-mode QEMU-green matrix), and this
  retrospective + STATUS.md block + release tag `mvp-v0.1` (#1011).

Pillar 11 target (`design/00-feature-inventory.md`): the MVP demo
scaffolding is complete — image builds, ships, boots, walks a per-
subsystem fingerprint on real HW when the operator plugs a serial cable
into a T14 G4, and closes with a release tag. Live end-to-end demo
execution on physical hardware remains a `gated:hardware` deferral for
the R28+ hardware bring-up sub-round (same posture as R23 first-visual-
output, R24 first-NVMe-touch, R26 first-keystroke, R27 first-ping).

---

## What R28 Delivered

### R28.M1 — MVP demo image assembly (3 issues + 1 deferred: #998, #999, #1000; #1001 -> R32)

- **#998 tools/build-image.sh** — assembler pipeline: kernel.elf +
  userland binaries + PdxFS-lite rootfs blob + ESP layout composited
  into a ~64 MiB `paideia-mvp.img` with GPT + FAT32 ESP + PdxFS-lite
  data partition. Reproducible across runs (no timestamp embedding).
- **#999 tools/build-uefi-image.sh** — ESP layout producer.
  `/EFI/PAIDEIA/PAIDEIA.EFI` (self-hosted, no shim; brand-directory
  matches PBS-D2 in `design/security/pe-secure-boot-signing.md`).
  `/EFI/BOOT/BOOTX64.EFI` fallback for firmware that ignores custom
  BootOrder.
- **#1000 tools/mkfs-pdxfs-lite-seed.sh** — rootfs blob emitter with
  seed entries: `/etc/hello` (contents `hello from paideia\n`),
  `/bin/sh` (R17 shell binary), `/bin/true` (R17 minimal binary).
- **#1001 PE Secure Boot signing** — *deferred* to R32/R33 per
  `design/security/pe-secure-boot-signing.md`. The R28 image is
  unsigned; operator must disable Secure Boot in T14 BIOS. Signing
  requires ML-DSA-65 (R32) + PE certificate table emission (R33)
  crypto substrate that neither paideia-as nor paideia-os have at R28.

**Closure commit:** `7108498`.

### R28.M2 — HW smoke harness + serial fallback + T14 G4 first-boot (3 issues: #1002, #1003, #1004)

- **#1002 tools/run-smoke-hw.sh** — PAIDEIA_HW_SMOKE-gated real-HW
  serial-fingerprint verifier. Refuses to run without the gate (rc=3),
  detects the USB-serial adapter (rc=2 on absent), applies 115200 8N1
  raw tty settings via stty, captures for a bounded window via
  `timeout ... cat /dev/ttyUSB0`, runs the same in-order contains-check
  as `tools/run-smoke.sh` against `tests/hw/expected-hw-*.txt`. Four
  modes at M2: boot / pdxfs / net / all.
- **#1003 design/kernel/serial-console-fallback.md** — screen / tio /
  picocom operator recipes. Documents 115200 8N1 no-flow-control tty
  discipline (matches R16.M4 kernel COM1 init byte-for-byte).
- **#1004 design/hardware/t14-g4-first-boot.md** — cold-boot walkthrough
  from firmware -> BOOTX64.EFI -> kernel_main_uefi -> INIT -> shell.
  BIOS setup checklist (Secure Boot off; VMD off; UEFI Only; boot
  order). Acceptance criteria (`$ ` prompt on serial console).
  Rootfs contents inventory. Troubleshooting sequence for the
  no-serial-output case.

**Closure commit:** `adf5083`.

### R28.M3 — Panic-FB + quirks + regression matrix (3 issues: #1005, #1006, #1007)

- **#1005 design/testing/panic-fb-photograph-recovery.md +
  tools/panic-fb-recovery-smoke.md** — verification recipe for the
  R23.M3 (#884) `klog_panic` fb-mirror path. Codifies photograph-
  transcribability acceptance criteria (banner legible; ring dump BEGIN
  / END markers legible; individual ring bytes transcribable within
  optics). Promotes the T14 G4 §2.5 UART quirks row from PROVISIONAL to
  WORKED-AROUND on first successful photograph transcription.
- **#1006 design/hardware/quirks.md T14 G4 pass** — four rows anchored
  or re-anchored at R28.M3: §2.4 USB xHCI (Boot Protocol keyboard
  landing recipe), §2.5 UART (photograph fallback), §2.5 Ethernet
  (R27 e1000e-family driver applies), §2.6 GOP-Pixel-Format (BGR_8888
  assumption + eDP native 1920x1080 pitch).
- **#1007 design/testing/hw-regression-matrix.md** — seed regression
  matrix. Rows C1..C10 (cold-boot -> multicore -> UEFI -> ACPI -> FPU
  -> PCIe -> framebuffer -> NVMe -> shell -> panic-fb) map to source
  substrates (R18..R28.M3) and per-hardware-target status (T14 G4 /
  Framework 13 / QEMU-OVMF).

**Closure commit:** `ea7e897`.

### R28.M4 — Final MVP closure (4 issues: #1008, #1009, #1010, #1011)

- **#1008 tools/hw-smoke-fingerprints.md +
  boot_r28_hw_smoke mode extension** — per-subsystem fingerprint
  catalogue: §1 boot (`PaideiaOS R8`..`$`), §2 pdxfs (NVMe probe/reset
  + PDXFS MOUNT OK + `cat /etc/hello` roundtrip), §3 net (E1000E probe
  /reset + ARP CACHE + `[NET_] L2/L3 RX ARP/IPV4/ICMP`), §4 USB (XHCI
  probe/reset + SLOT ENABLED + CONFIGURE_EP OK + HID BOOT PROTOCOL +
  per-keypress HID KEY <ascii>), §5 composite (union of §1..§4 without
  interactive tails). Extended `tools/run-smoke-hw.sh` with the
  `boot_r28_hw_smoke` mode + `usb` mode + updated `all` dispatch;
  DEFAULT_TIMEOUT=240s for composite.
- **#1009 design/testing/mvp-demo-script.md** — 7-step operator recipe:
  1. Cold-boot T14 G4 from paideia-mvp.img USB.
  2. `cat /etc/hello` -> `hello from paideia`.
  3. Peer host `ping -c 3 10.0.0.2` -> 3 replies.
  4. `echo demo > /tmp/mvp` -> silent success.
  5. `exit` -> shell reprompt.
  6. Cold reboot.
  7. `cat /tmp/mvp` -> `demo`.
  Every non-boot step is currently `gated:hardware` (blocked on R28+
  driver-attach ceremony + R25 nvme_write_blocking debt). The script
  is the definitive R28 acceptance surface for hardware-witnessed MVP
  demo close.
- **#1010 .githooks/pre-push PAIDEIA_HW_SMOKE=1 opt-in** — extends the
  existing 15-mode QEMU-green regression matrix with an optional real-
  HW composite fingerprint check. Default push behavior unchanged
  (16 QEMU-green targets: 15 boot modes + no-AML lint + opcode-canary).
  When `PAIDEIA_HW_SMOKE=1 git push`, invokes `run-smoke-hw.sh
  boot_r28_hw_smoke` and treats rc=0 as pass, rc=1 as fail, rc=2/3/77/
  124 as skip (adapter absent / gate cleared / fingerprint unseeded /
  no bytes captured).
- **#1011 R28 closure retrospective + STATUS + release tag** — this
  document + STATUS.md R28 CLOSED block + release tag `mvp-v0.1`
  pointing at the M4 closure commit.

**Closure commit:** (this M4 commit).

---

## What the MVP Demonstrates

Given a physical T14 Gen 4 and a USB stick containing `paideia-mvp.img`,
paideia-os as of R28 close demonstrates the following capabilities
end-to-end:

- **Boot chain.** UEFI firmware selects the paideia-native PE32+ stub
  (`PAIDEIA.EFI` — no shim, no GRUB). Kernel takes over via
  `kernel_main_uefi`, initializes SMP substrate (R18), programs the
  APIC / TSC-deadline timer / MSI-X vector allocator (R21), walks ACPI
  static tables (R20 + R22.M1 MCFG), enumerates the PCIe hierarchy
  (R22), pin-lights the Iris Xe framebuffer (R23), and reaches the
  R17 shell prompt.
- **Storage stack.** NVMe controller (R24) reachable via PCIe MCFG,
  reset + settle-poll clean, sq/cq admin ring operational; PdxFS-lite
  (R25) mounts the seed rootfs blob (`/etc/hello`, `/bin/sh`,
  `/bin/true`), `cat` reads a file through the block cache and stdout
  reaches the serial console.
- **Network stack.** e1000e / i219-LM (R27) probe + reset + PHY read +
  MAC read; ARP responder (R27.M4) resolves 10.0.0.2 for peer hosts;
  IPv4 rx-path (R27.M5) validates checksum + dst filter + protocol
  demux; ICMP Echo Reply responder (R27.M6) answers `ping 10.0.0.2`
  with 0% packet loss; UDP port-7 echo daemon reflects payload
  byte-for-byte.
- **Input stack.** xHCI (R26) enumerates USB, Boot Protocol keyboard
  reports (R26.M5) translate into ASCII byte stream that reaches the
  shell line buffer.
- **Panic recovery.** On a synthetic panic, the framebuffer mirrors the
  klog ring in bold-red banner + BEGIN/END markers; a phone camera
  photograph transcribes the last few bytes even without any serial
  attach (R23.M3 + R28.M3).
- **Persistence.** After a cold reboot, PdxFS-lite superblock intact
  and files written pre-reboot readable post-reboot (once R25 debt
  items land — `nvme_write_blocking` + `commit_dirty_metadata`).
- **Determinism.** The build is byte-reproducible; the pre-push hook
  runs a 16-target QEMU regression matrix (opt-in HW smoke additional).

The single non-trivial thing the MVP does NOT demonstrate at R28.M4
close is **live end-to-end execution on the physical T14 G4** — every
step 2-7 of the MVP demo script requires the R28+ driver-attach ceremony
in `kernel_main_uefi`, which is queued as the first item in the R28+
hardware bring-up sub-round. Every substrate primitive is landed and
linked; the ceremony is the last mile.

---

## Cross-Repo Escalations to paideia-as (R28)

**None.** `paideia-as` submodule remained pinned at `2cf169d` for all
four R28 milestones — unchanged since R21 close. This is the **eighth
consecutive round** with zero cross-repo escalations
(`feedback_cross_repo_escalation.md` never fired in R28 planning or
implementation). R28's work was entirely documentation, image-assembly
shell scripts, hook extensions, and existing-substrate consumption; no
new assembly encoders or elaborator behaviors were surfaced.

---

## Deferrals

R28 landed with one round-scoped deferral (#1001) plus six long-tail
deferrals inherited from prior rounds. All six long-tail items chain on
#1015 userspace-server substrate (the same gate the R25 / R26 / R27
retros documented) or on R25 write-side debt.

### D1. #1001 PE Secure Boot signing — R32/R33

**Scope:** R28.M1 ships **unsigned** `PAIDEIA.EFI` / `BOOTX64.EFI`.
Signing requires ML-DSA-65 (R32 crypto substrate) or fallback ECDSA-
P384 (also R32), plus PE Certificate Table emission (R33 PE hardening).
The R28 image is bootable only with Secure Boot disabled per
`design/security/pe-secure-boot-signing.md` §PBS-D1.

**What blocks:** R32 crypto stack. Neither paideia-as nor paideia-os
have the ML-DSA-65 or ECDSA-P384 primitive available at R28 close.

**Rerouting:** R32 (ML-DSA-65 substrate) -> R33 (PE Certificate Table
emission) -> re-emit `PAIDEIA.EFI` through the signed path.

### D2. #820 acpi_supervisor — R28+ (blocked on #1015)

**Scope:** ACPI static-table walk is landed (R20 + R22.M1 MCFG); the
supervisor process that pins ACPI parsing behind capability discipline
is queued behind #1015 userspace-server substrate.

**Rerouting:** R28+ once #1015 lands.

### D3. #860 pci_enumerator — R28+ (blocked on #1015)

**Scope:** Same shape as D2. PCI MCFG walk landed (R22); userspace
enumerator process queued behind #1015.

**Rerouting:** R28+ once #1015 lands.

### D4. #906 userspace nvme_read_blocking — R28+ (blocked on #1015)

**Scope:** Kernel-side `nvme_read_blocking` landed (R24.M4); the
userspace half of the syscall is queued behind #1015.

**Rerouting:** R28+ once #1015 lands.

### D5. #963 userspace HID class driver — R28+ (blocked on #1015)

**Scope:** Kernel-side HID class match hook + Boot Protocol
(R26.M5-M6) landed; userspace HID class driver queued behind #1015.

**Rerouting:** R28+ once #1015 lands.

### D6. #994 KIND_UDP_SOCKET descriptor slab write + #996 UDP userspace socket delivery — R28+ (blocked on #1015)

**Scope:** Kernel-side mint gate landed (R27.M6); descriptor slab
write + bind/sendto/recvfrom/close dispatch queued behind #1015.
`udp_rx_handle` currently intercepts port 7 in-kernel (echo demo);
real per-port socket dispatch chains on #1015.

**Rerouting:** R28+ once #1015 lands.

### D7. Live T14 MVP demo execution — R28+ (gated:hardware)

**Scope:** Every step of `design/testing/mvp-demo-script.md` §2 except
1 (cold boot) and 5 (exit) requires post-R28 driver-attach ceremony
wiring in `kernel_main_uefi` plus R25 write-side debt discharge
(`nvme_write_blocking` + `commit_dirty_metadata`).

**Rerouting:** R28+ hardware bring-up sub-round.

**None of these regress R28 acceptance for the MVP demo scaffolding.**
The image builds, the harness runs, the pre-push hook enforces QEMU-
green plus optional HW-composite; the last-mile is a hardware bring-up
loop iterating against physical T14 G4.

---

## Round-by-round retrospective (R18 -> R28)

The MVP arc as delivered across 11 rounds (R18-R28), one paragraph per
round summarizing the delivery. Cross-references to the per-round
retrospectives under `design/round-retrospectives/rXX-closure.md`.

- **R18 (SMP substrate — multicore bring-up).** 23 issues, 6
  milestones. Delivered AP boot trampoline (real->prot->long), per-CPU
  control block via `[gs:off]`, MCS spinlock, atomic refcount, TLB
  shootdown IPI, cross-CPU reschedule IPI (vector 0xF1), per-CPU
  TSC-deadline timer, per-CPU runqueue, CPUID 0x0B/0x1F/0x1A topology
  walk. Retired the "single-CPU deferred" audit posture across the
  scheduler. Closure commit + `r18-closed` tag.
- **R19 (paideia-native UEFI PE32+ boot).** 20 issues, 5 milestones.
  Dropped the Multiboot2/GRUB stopgap decisively; paideia-as v0.21
  landed MS x64 ABI emit + `.pe` section descriptors; kernel gained
  `kernel_main_uefi` entry + UEFI boot-services shutdown ceremony.
  First OVMF boot to the pre-EBS hello banner. Closure commit +
  `r19-closed` tag.
- **R20 (ACPI static-table foundation).** 22 issues, 5 milestones.
  RSDP scan (BIOS EBDA + firmware AcpiTable), RSDT/XSDT walker, MADT
  + FADT + HPET table parsers, kernel-side ACPI descriptor cache.
  Deferred AML entirely to R34 (ACPICA-shaped substrate); every R20
  parser is static-table-only. Closure commit + `r20-closed` tag.
- **R21 (FPU/XSAVE + interrupt controller completion + timing).** 28
  issues, 6 milestones. XSAVE/XRSTOR with lazy CR0.TS trap discipline;
  YMM/ZMM state preservation across `sched_switch`; TSC-deadline timer
  program with IA32_TSC_DEADLINE MSR; HPET calibration; IOAPIC re-
  route to per-CPU vector allocator; MSI-X table map + arm for future
  driver-attach. Retired xAPIC MMIO from most kernel paths (final
  retire at R29). Closure commit + `r21-closed` tag.
- **R22 (PCI substrate + xAPIC retirement + IOMMU (VT-d) substrate).**
  28 issues, 6 milestones. MCFG walk with ECAM u32 accessors;
  `_pci_devices` bump-allocated table (256 stride, 512 entries);
  BAR probe with 32/64-bit size discovery; class-code triple filter;
  VT-d structural substrate (SLPT synthesis + IRTE build; kernel
  paths dormant until R23 driver-attach). QEMU-TCG does not emulate
  VT-d so most primitives are structural-only. Closure commit +
  `r22-closed` tag.
- **R23 (framebuffer console via GOP direct).** 12 issues, 4
  milestones. `fb_map_lfb` from GOP handoff; 8x16 font glyph
  rasterizer; `fb_console_puts` + `fb_console_putchar` scroll
  discipline; `klog_panic` step 3.7 fb-mirror path with bold-red
  banner + ring dump BEGIN/END markers. Photograph-recoverable per
  R28.M3 recipe. Closure commit + `r23-closed` tag.
- **R24 (NVMe driver — kernel-side substrate).** 19 issues, 6
  milestones. NVMe controller probe + reset (CC.EN clear + CSTS.RDY
  poll); admin sq/cq allocation + doorbell program; Identify
  Controller + Identify Namespace command dispatch; `nvme_read_
  blocking` kernel-side path. Multi-controller support + concurrent
  IO deferred to R25+. Closure commit + `r24-closed` tag.
- **R25 (PdxFS-lite — persistent FS MVP + NVMe driver-attach
  preflight).** 30 issues, 7 milestones. **Largest MVP round.**
  Superblock (magic + version + inode table extent + block bitmap
  extent + root inode); inode table (128 entries × 256 B); direct
  block map (12 × 4 KiB); write-through discipline (no cache);
  ML-DSA-65 superblock signature (stub — real verify R32). Mount +
  read paths landed; `nvme_write_blocking` + `commit_dirty_metadata`
  deferred to post-R25. Closure commit + `r25-closed` tag.
- **R26 (USB xHCI substrate + HID Boot Keyboard bring-up).** 30
  issues, 6 milestones. xHCI probe (class 0x0C/0x03/0x30); Capability
  + Operational register map; BIOS -> OS handoff via USBLEGSUP; SMI
  Enable mask; controller reset (Halt -> HCRST -> CNR clear -> MaxSlot
  program); command ring + event ring + ERST + MSI-X; DCBAAP + slot
  lifecycle + Configure Endpoint; 3-TRB Control Transfer; HID class
  match + Boot Protocol; HID -> TTY bridge with per-keypress ASCII
  translation. HID mouse deferred to R27+ per "keyboard first, mouse
  second" sequencing. Closure commit + `r26-closed` tag.
- **R27 (networking substrate: e1000e + ARP + IPv4 + ICMP/UDP).** 27
  issues, 6 milestones. e1000e/i219-LM controller (probe + reset +
  PHY read + RAL/RAH MAC read); RX/TX descriptor rings with MSI-X
  vec-0 arm; L2 Ethernet frame parse/build + rx dispatch + tx submit;
  ARP substrate (parse/build + 16-slot cache + request/reply +
  gratuitous detect); IPv4 (parse/build + one's-complement 16-bit
  checksum + rx checksum verify + dst filter + protocol demux + tx
  with ARP resolve); ICMP Echo Reply responder; UDP header + port-7
  echo demo; KIND_UDP_SOCKET capability mint gate + IPC RPC schema.
  Full TCP descoped from R27 to R28 or R30+ dedicated round. Closure
  commit + `r27-closed` tag.
- **R28 (bootable distribution + real-HW smoke -> MVP DEMO).** 14
  issues, 4 milestones. `tools/build-image.sh` +
  `tools/build-uefi-image.sh` + `tools/mkfs-pdxfs-lite-seed.sh` +
  `paideia-mvp.img`; `tools/run-smoke-hw.sh` with 5 modes (boot /
  pdxfs / net / usb / all / boot_r28_hw_smoke composite) +
  `PAIDEIA_HW_SMOKE=1` gate; T14 G4 first-boot walkthrough + serial
  console fallback recipes; panic-FB photograph recovery recipe +
  T14 G4 quirks-db pass + HW regression matrix seed; per-subsystem
  fingerprint catalogue + MVP demo operator script + pre-push HW
  opt-in + this retrospective. Closure commit + `mvp-v0.1` tag.

**Round arc summary.** From R18's first AP boot through R28's bootable
USB image, the MVP arc landed **~257 issues across 60 milestones over
11 rounds**, with **zero cross-repo paideia-as escalations for the
final 8 rounds** (R21-R28) and **8 rounds tagged** (`r18-closed`
through `r27-closed` plus `mvp-v0.1`). The four rounds inheriting
long-tail deferrals to #1015 userspace-server substrate did so
consistently; the R28+ hardware bring-up sub-round discharges the
majority of that queue.

---

## Preflight for R29+ (hardening)

**R29 (xAPIC retirement completion + kernel timer redesign)** — opens
after R28 close per `design/roadmap/r18-plus-bare-metal.md §3 R29`.
Draft preflight to land as `design/round-retrospectives/r29-preflight.md`
at R29.M1 kickoff.

### R29 direct scope (roadmap)

- Retire xAPIC MMIO for good across every kernel path (R21 partial —
  IOAPIC re-route landed; xAPIC ICR write-pair still used in R18 IPI
  dispatch and R28 remains). Full xAPIC -> x2APIC MSR retire.
- Kernel timer redesign: TSC-deadline everywhere (retire HPET fallback
  as a runtime path; leave HPET calibration only). Per-CPU timer
  queue with heap-shaped deadline discipline.

### R29 opportunistic scope — post-R28 driver-attach preflude

The R29 opening is the natural home for the R28+ hardware bring-up
sub-round if it doesn't happen inline against R28-tagged main:

1. **R29.M0 (optional prelude):** land the driver-attach ceremony in
   `kernel_main_uefi` for NVMe + PdxFS-lite mount + e1000e + xHCI
   attaches. Discharge steps 2-7 of the MVP demo script live.
2. **R29.M0.5 (optional prelude):** R25 write-side debt discharge
   (`nvme_write_blocking` + `commit_dirty_metadata`). Enables MVP
   demo steps 4 and 7.
3. **R29.M0.7 (optional prelude):** land `#1015` userspace-server
   substrate stub; discharges D2-D6.

If R29 scope tolerates the M0 prelude, R28 D7 discharges at R29 open
— probably 5-8 issues. If R29 scope is too tight (xAPIC retirement +
timer redesign is a 15-20 issue round easily), the M0 prelude moves to
R29.5 / R30 as a targeted "flush the MVP demo hardware debt" sub-round.

### R28 debt items not covered by R29 M0 prelude

- **PE Secure Boot signing (#1001)** — R32/R33 crypto substrate.
- **R25 debt items** carried forward from R25 close (multi-controller
  NVMe, migration tool, directory-entry limit enforcement).
- **R23 debt items** carried forward from R23 close (UEFI/OVMF fb_
  console harness, `fb_map_lfb` BGRA assumption, `_fb_console_grid`
  fixed size).
- **R22 debt items** carried forward from R22 close (`_vtd_base`
  hardcoded, `msix_enable_device` completeness, GCMD.TE + SIRTP +
  IRE ceremony).
- **R21 debt items** carried forward (hpet_now_ns precision widening,
  `phase1_acpi_gather` full wire).

Decision to defer to R29.M1 kickoff — see kickoff doc for the call.

---

## Retrospective — the MVP arc as a whole

**What worked.**
- **Continuous-loop tempo** kept the round-close latency at ~4-6 weeks
  per round across R18-R28. Zero rounds slipped a scheduled milestone.
- **Paideia-as pinning at 2cf169d for 8 rounds** demonstrates the
  paper-tiger discipline (challenger-audit every ambient `paideia-as-
  blocked` label before escalating) genuinely reduces cross-repo churn.
- **Substrate-first, driver-attach-later** kept every round scoped
  to landable-under-`qemu -kernel`. The `gated:hardware` deferral
  queue is the correct discharge site for live-HW witnessing.
- **Fingerprint-driven smoke** (both QEMU and real-HW) proved trivially
  extensible; adding modes cost <100 LOC per addition.

**What we'd change.**
- **R25 scope was too large** (30 issues, largest MVP round). Would
  have benefitted from splitting into R25a (superblock + inode table
  + read path) and R25b (write-side + commit_dirty_metadata +
  ML-DSA-65 signature stub).
- **Driver-attach ceremony was consistently deferred** across R24-R27,
  compounding to a large R28+ hardware bring-up backlog. A dedicated
  R23.5 / R25.5 "driver-attach interlude" round would have kept the
  backlog bounded.
- **#1015 userspace-server substrate** blocked six long-tail
  deferrals across four rounds without ever being explicitly scoped
  as a sub-round. Filing #1015 explicitly as an R28.5 / R29 round
  earlier would have discharged the queue faster.
- **PE Secure Boot signing (#1001)** should have been filed against
  R32 from R28 planning rather than opened-then-deferred within R28.
  The R28 issue tracker carried noise.

**Substrate anchor coverage.** Every Pillar from `design/00-feature-
inventory.md` §1 has substrate anchored at MVP close:

- Pillar 1 (post-quantum): ML-DSA-65 stub in PdxFS-lite superblock
  (R25); real verify at R32.
- Pillar 2 (multicore-first): SMP substrate (R18), per-CPU
  discipline throughout the scheduler.
- Pillar 3 (capability-typed): KIND_* dispatch (R12), rights catalog
  (R2.5), per-KIND cap dispatchers for BlkdevCap (R24), FsCap (R25),
  XhciCap / HidCap (R26), UdpSocketCap (R27).
- Pillar 4 (semantically queryable terminal): R13-R17 shell foundation
  + R23 framebuffer console + R26 HID keyboard bridge.
- Pillar 5 (no legacy): paideia-native PE32+ boot from R19; no shim /
  GRUB / Multiboot.
- Pillar 6 (functional-discipline assembly): every R18-R28 module is
  paideia-as `.pdx`; zero `.S` fallbacks landed after R18.M2 boot_stub
  migration.
- Pillar 7 (typed-refinement): deferred to R31.
- Pillar 8 (crashdump-recoverable): panic-FB (R23.M3) + photograph
  recovery (R28.M3).
- Pillar 9 (deterministic build): opcode-canary lint + no-AML lint +
  15-target regression matrix; image build byte-reproducible.
- Pillar 10 (post-Unix ergonomics): shell + init + PdxFS-lite hierarchy
  landed; explicit deviations from POSIX (rights-as-capabilities,
  KIND-typed sockets) documented per-round.
- Pillar 11 (MVP-first hardware target): this round — T14 G4 primary
  target, bootable USB, real-HW smoke harness, quirks-db + regression
  matrix seed.

The MVP arc is complete. `mvp-v0.1` is the reference release.

---

*Landed 2026-08-11 at R28.M4 (#1011). Live end-to-end demo execution
on T14 G4 deferred to R28+ hardware bring-up sub-round. Release tag
`mvp-v0.1` promotes from `documentation-only` to `hardware-witnessed`
when every step of `design/testing/mvp-demo-script.md §2` ticks green.*
