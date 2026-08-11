# PaideiaOS MVP demo script — operator walkthrough (R28.M4 #1009)

**Owner issue:** paideia-os #1009 (R28.M4-002 — MVP demo script).
**Round:** R28 (MVP demo consolidation) — the final MVP milestone.
**Target hardware:** ThinkPad T14 Gen 4 (primary MVP target per
`design/roadmap/r18-plus-bare-metal.md §7`).
**Boot media:** `build/mvp/paideia-mvp.img` produced by
`tools/build-image.sh` (R28.M1 #998).
**Status:** Landable pre-first-light — operator recipe. Live end-to-end
execution deferred to physical T14 G4 in the lab (`gated:hardware`).
**Complements:** `design/hardware/t14-g4-first-boot.md` (cold-boot
walkthrough), `tools/hw-smoke-fingerprints.md` (fingerprint catalogue),
`design/round-retrospectives/r28-closure.md` (round retrospective).

---

## 0. Scope

The MVP demo is the acceptance surface for R28 close and, transitively,
for the R18–R28 MVP arc as a whole. It answers: *given a physical T14 G4
and a USB stick containing `paideia-mvp.img`, can an operator take the
laptop from cold-power to a shell that reads a file, receives a network
packet, and survives a reboot with its filesystem intact?*

If every step in §2 completes successfully on the T14 G4, the MVP demo
is DONE and the `mvp-v0.1` release tag is promotable from
`documentation-only` to `hardware-witnessed`.

**Non-goals.** Sustained multi-tenant workload; secure-boot signature
verification (deferred to R32 per `design/security/pe-secure-boot-
signing.md`); accelerated GPU output; wireless networking; suspend /
resume; ACPI-driven fan control. Every one of these is post-MVP
hardening (R29–R40) or deferred (R41+).

---

## 1. Preconditions

Before running the demo:

1. **Image built.** `bash tools/build-image.sh` completes clean and
   produces `build/mvp/paideia-mvp.img` (~64 MiB). Verify:
   ```
   ls -la build/mvp/paideia-mvp.img
   ```
2. **USB stick flashed.** Write the image to a USB stick with
   `dd if=build/mvp/paideia-mvp.img of=/dev/sdX bs=4M status=progress
   conv=fsync` (where `/dev/sdX` is the USB device — verify with `lsblk`
   BEFORE the `dd` call; wrong target destroys the wrong disk).
3. **T14 G4 BIOS configured per `design/hardware/t14-g4-first-boot.md §3`:**
   - Secure Boot: **disabled** (R28 image is unsigned per PBS-D1).
   - VMD: **disabled** (NVMe visible as plain PCIe).
   - Boot mode: **UEFI Only** (Legacy CSM off).
   - Boot order: USB HDD **first**.
4. **Serial console attached** per `tools/run-smoke-hw.sh` file-header
   §Hardware-attachment. USB-C dock DB-9 -> null-modem -> operator dev
   box USB-serial adapter -> `/dev/ttyUSB0` (or override via
   `PAIDEIA_HW_SERIAL_DEV`).
5. **Peer host on same subnet.** For step 4 (network ping): a second
   machine, same L2 network as the T14 G4 wired ethernet, configured
   with `10.0.0.3/24` on its NIC:
   ```
   sudo ip addr add 10.0.0.3/24 dev enp1s0    # adapt device name
   sudo ip link set enp1s0 up
   ```
6. **Notebook / camera ready.** For panic recovery (out of scope for the
   MVP demo happy path but present as a fallback) — a phone camera to
   photograph the eDP framebuffer if the demo trips a panic.

---

## 2. Demo walkthrough

Follow each step in order. The operator's dev-box terminal (serial
capture) is where every observable klog line lands.

### Step 1 — Cold boot from paideia-mvp.img

**Action.** Insert the USB stick into a USB-A port on the T14 G4 (or via
a USB-C -> USB-A adapter). Power on the laptop. If BIOS boot-order is
correct, firmware selects `/EFI/PAIDEIA/PAIDEIA.EFI` from the USB ESP
and hands off to the kernel.

**Expected serial output within 45 s** (per `tools/hw-smoke-
fingerprints.md §1`):

```
PaideiaOS R8
CPU_ID_00_HELLO
GS_OK_00
IDT LOADED
SCHED READY
INIT START
SHELL START
$
```

**Success criterion.** The `$ ` prompt appears on the serial console.

**Failure paths.**
- No serial output within 45 s: firmware never selected the USB, or
  UEFI PE loader rejected the PAIDEIA.EFI stub. See
  `design/hardware/t14-g4-first-boot.md §4-troubleshooting`.
- Kernel boot banner appears but no shell prompt: R17 shell init trip.
  Capture full log via `screen /dev/ttyUSB0 115200` for post-mortem.
- Panic banner (`*** PANIC ***`): photograph the screen per
  `design/testing/panic-fb-photograph-recovery.md §4`; transcribe the
  ring dump into the failure report.

### Step 2 — `cat /etc/hello`

**Action.** Type `cat /etc/hello` at the shell prompt, press Enter.

**Expected serial output** (per `tools/hw-smoke-fingerprints.md §2`):

```
$ cat /etc/hello
hello from paideia
$
```

**Success criterion.** The literal bytes `hello from paideia` appear on
the console followed by a fresh prompt.

**What this proves.**
- NVMe controller reachable (R24.M1 probe + R24.M2 reset).
- PdxFS-lite mounted rootfs from the seed blob (R25.M7 e2e).
- Shell `cat` builtin (R17.M5) drove `sys_open` + `sys_read` +
  `sys_write(stdout)`.
- The whole R24+R25 stack served a real file byte-for-byte.

**Current status (R28.M4 close).** This step requires the R28+ driver-
attach ceremony to wire NVMe into `kernel_main_uefi` + call
`pdxfs_lite_mount` with the root blkdev cap. Until that ceremony lands,
this step trips at the `cat` invocation (no filesystem mounted -> shell
prints "cat: /etc/hello: no such file"). Deferred per §5.

### Step 3 — `ping 10.0.0.1` (or peer-host initiated ping to 10.0.0.2)

**Action.** From the peer host (10.0.0.3):
```
ping -c 3 10.0.0.2
```

**Expected serial output on the T14 G4 side** (per `tools/hw-smoke-
fingerprints.md §3`):

```
[NET_] L2 RX ARP
[NET_] L2 RX IPV4
[NET_] L3 RX IPV4
[NET_] L3 RX ICMP
[NET_] L2 RX IPV4
[NET_] L3 RX IPV4
[NET_] L3 RX ICMP
[NET_] L2 RX IPV4
[NET_] L3 RX IPV4
[NET_] L3 RX ICMP
```

**Expected peer-host output:**

```
3 packets transmitted, 3 received, 0% packet loss
```

**Success criterion.** Three ICMP Echo Replies land on the peer host.

**What this proves.**
- e1000e/i219-LM probe + reset (R27.M1).
- MSI-X vector 0 walker enabled (R27.M2 + R28+ driver-attach).
- ARP request/reply (R27.M4 arp_rx_handle + arp_reply).
- IPv4 rx-path with checksum verify + dst filter + protocol demux
  (R27.M5 ipv4_rx_handle).
- ICMP Echo Reply responder (R27.M6 #995 icmp_rx_handle).

**Current status (R28.M4 close).** Same R28+ driver-attach gate as
step 2. Deferred per §5. Kernel-side `ping 10.0.0.1` from the shell
(reverse direction) requires an ICMP Echo *Request* sender path which
is post-R28 scope.

### Step 4 — `echo demo > /tmp/mvp`

**Action.** At the shell prompt: `echo demo > /tmp/mvp`, Enter.

**Expected serial output.** Fresh prompt (no error).

```
$ echo demo > /tmp/mvp
$
```

**What this proves.**
- Shell parses `>` redirect (R17.M5 redirect substrate).
- PdxFS-lite `create` + `write_through` path (R25.M6).
- NVMe `nvme_write_blocking` (R25 debt item — kernel side).
- `commit_dirty_metadata` pass (R25 debt item).

**Current status (R28.M4 close).** This step requires nvme_write_blocking
plus commit_dirty_metadata. Both are R25 debt items still open (see
`design/round-retrospectives/r25-closure.md §Debt`). Under the current
substrate the redirect will trip at the write-through path. Deferred
per §5.

### Step 5 — `exit`

**Action.** Type `exit`, Enter.

**Expected serial output.** Shell prints exit line + reprompts init.

```
$ exit
INIT: shell exited (0). Reprompt.
$
```

**Success criterion.** New shell prompt appears. INIT re-exec'd the
shell.

**What this proves.**
- R17.M5 shell exit path.
- INIT (`init_main`) supervises shell lifecycle and re-exec on exit.

### Step 6 — Cold reboot

**Action.** Power off the T14 G4 (long-press power). Wait 5 s. Power on
again. USB stick still inserted.

**Expected serial output.** Same as step 1 — clean boot to `$ ` prompt.

**What this proves.**
- Cold-boot path is deterministic across reboots.
- PdxFS-lite superblock survived power-cycle (needed for step 7).

### Step 7 — `cat /tmp/mvp`

**Action.** At the fresh shell prompt after reboot: `cat /tmp/mvp`,
Enter.

**Expected serial output:**

```
$ cat /tmp/mvp
demo
$
```

**Success criterion.** The literal bytes `demo\n` (the payload written
in step 4) appear on the console.

**What this proves — the R28 acceptance surface climax.**
- PdxFS-lite persistence across power-cycle.
- NVMe read from the block previously written by step 4.
- End-to-end round-trip: userspace write -> block cache -> NVMe write
  -> power cycle -> boot -> mount -> read -> userspace read -> stdout.

**Current status.** Deferred per §5 with step 4 (both need
`nvme_write_blocking` + `commit_dirty_metadata`).

---

## 3. Composite fingerprint check (no-touch acceptance)

For a no-touch acceptance surface that does not require operator
interaction during the capture window, use the composite mode:

```
PAIDEIA_HW_SMOKE=1 tools/run-smoke-hw.sh boot_r28_hw_smoke
```

Reads the fingerprint file `tests/hw/expected-hw-r28-composite.txt`
which walks per-subsystem boot lines (see `tools/hw-smoke-
fingerprints.md §5`). Passes when every subsystem's boot-time klog
lines land within the 240-second capture window.

The composite mode does NOT cover steps 2 (cat /etc/hello),
3 (ping), 4 (echo > file), or 7 (cat post-reboot) — those are
interactive tails covered by the individual `pdxfs`/`net` modes,
each demanding operator choreography during their respective capture
windows.

**Recommended ordering.**

1. Run `boot_r28_hw_smoke` composite (no-touch, 240 s) — proves cold-
   boot substrate.
2. Run `PAIDEIA_HW_SMOKE=1 tools/run-smoke-hw.sh pdxfs` and type
   `cat /etc/hello` at the prompt inside the capture window.
3. Run `PAIDEIA_HW_SMOKE=1 tools/run-smoke-hw.sh net` and from the peer
   host, issue `ping -c 3 10.0.0.2` inside the capture window.
4. Run `PAIDEIA_HW_SMOKE=1 tools/run-smoke-hw.sh usb` and type `hello`
   on the attached USB keyboard inside the capture window.

---

## 4. Success criteria for R28 close

The MVP demo is **complete** when:

- [x] `bash tools/build.sh` produces `build/kernel.elf` clean.
- [x] `bash tools/build-image.sh` produces `build/mvp/paideia-mvp.img`.
- [x] `bash tools/run-smoke.sh <all default modes>` — 15 QEMU-green.
- [ ] Step 1 (cold boot to `$ ` prompt) executes on T14 G4.
- [ ] Step 2 (`cat /etc/hello` -> `hello from paideia`) executes.
- [ ] Step 3 (peer-host ping -> 3 replies received) executes.
- [ ] Step 4 (`echo demo > /tmp/mvp` -> silent success) executes.
- [ ] Step 5 (`exit` -> shell reprompt) executes.
- [ ] Step 6 (cold reboot -> `$ ` prompt) executes.
- [ ] Step 7 (`cat /tmp/mvp` -> `demo`) executes.

Every unchecked box is a `gated:hardware` deferral. As each step ticks
green on real HW, the `design/hardware/quirks.md` corresponding row
promotes from `PROVISIONAL` to `CONFIRMED`.

---

## 5. Deferrals (post-R28 driver-attach)

Every step in §2 except 1 and 5 requires post-R28 driver-attach
ceremony wiring in `kernel_main_uefi`. The R28.M1–M3 milestones landed
the image assembly + fingerprint harness + panic recovery; R28.M4
lands this operator recipe + the composite fingerprint mode + the
pre-push HW hook + this retrospective. The **live end-to-end demo
execution** is the R28+ hardware bring-up sub-round.

**Ordered discharge queue:**

1. `kernel_main_uefi` driver-attach ceremony wires NVMe (R24 blkdev),
   PdxFS-lite (R25 mount), e1000e (R27 attach with MSI-X vec-0 IRQ
   walker into IDT), xHCI (R26 attach with MSI-X vec-0 event-ring
   walker into IDT).
2. R25 `nvme_write_blocking` + `commit_dirty_metadata` (kernel-side).
3. `#1015` userspace-server substrate resolves for `net_supervisor`
   (DHCP boot; retires hardcoded `_ipv4_my_ip = 10.0.0.2`).
4. Post-R28 hardening rounds R29+ per `design/roadmap/r18-plus-bare-
   metal.md §3`.

None of these regress R28 acceptance for the MVP demo scaffolding —
they gate steps 2, 3, 4, 7 from ticking green on real HW.

---

## 6. Cross-reference

- `tools/build-image.sh` — the image producer.
- `tools/mkfs-pdxfs-lite-seed.sh` — the rootfs blob producer with
  `/etc/hello` seed.
- `tools/build-uefi-image.sh` — ESP layout with `/EFI/PAIDEIA/
  PAIDEIA.EFI`.
- `tools/run-smoke-hw.sh` — the fingerprint verifier.
- `tools/hw-smoke-fingerprints.md` — the fingerprint catalogue.
- `design/hardware/t14-g4-first-boot.md` — cold-boot walkthrough +
  BIOS setup.
- `design/kernel/serial-console-fallback.md` — screen/tio/picocom
  recipes.
- `design/testing/panic-fb-photograph-recovery.md` — panic recovery
  operator recipe.
- `design/round-retrospectives/r28-closure.md` — R28 closure retro.
- `design/security/pe-secure-boot-signing.md` — why the R28 image is
  unsigned.

*Landed 2026-08-11 at R28.M4 (#1009). Live end-to-end execution on
T14 G4 pending hardware bring-up sub-round.*
