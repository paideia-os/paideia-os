# HW smoke fingerprints — per-subsystem catalogue (R28.M4 #1008)

**Owner issue:** paideia-os #1008 (R28.M4-001 — `boot_r28_hw_smoke` per-subsystem
fingerprint catalogue).
**Complements:** `tools/run-smoke-hw.sh` (R28.M2 #1002 — serial-fingerprint
verifier); `design/hardware/t14-g4-first-boot.md` (R28.M2 #1004 — cold-boot
walkthrough); `design/testing/mvp-demo-script.md` (R28.M4 #1009 — operator MVP
demo script).
**Status:** Landable pre-first-light — fingerprint definitions only. Every
`tests/hw/expected-hw-*.txt` file remains absent until seeded from a real
T14 G4 boot capture, at which point `tools/run-smoke-hw.sh` promotes from
SKIP (rc=77) to LIVE (rc=0/1).

---

## 0. Scope

`tools/run-smoke-hw.sh` (R28.M2 #1002) accepts four modes today: `boot`,
`pdxfs`, `net`, `all`. R28.M4 #1008 adds a fifth mode, `boot_r28_hw_smoke`,
which walks every subsystem fingerprint the MVP demo depends on in one
capture window. This document is the authoritative catalogue of what each
fingerprint contains and why each line is on the acceptance surface.

Every fingerprint below is:

1. **Grep-substring.** `tools/run-smoke-hw.sh` uses the same in-order
   contains-check as `tools/run-smoke.sh` — each line must appear
   somewhere in the captured serial log, in the order listed, but need
   not appear at column 0.
2. **Kernel-emitted (unless annotated).** Every fingerprint is a
   deterministic klog line the R18–R27 substrate emits under a specific
   boot condition. No fingerprint depends on `-cpu max`, `-smp N`, or a
   host-side clock — every line is scheduled by the kernel itself.
3. **Seeded lazily.** A fingerprint that references a subsystem whose
   driver-attach is post-R28 (PdxFS-lite mount, e1000e attach, xHCI
   attach, USB HID stream) is documented here as the *expected* line
   even though `run-smoke-hw.sh` currently SKIPs the corresponding mode.
   Seeding happens when the R28+ driver-attach ceremony wires the
   corresponding walker into `kernel_main_uefi`.

---

## 1. Boot (M1 fingerprints — always required)

**Mode:** `boot`
**File:** `tests/hw/expected-hw-boot.txt`
**Timeout default:** 45 s
**Substrate:** R18 (SMP) + R19 (UEFI PE32+) + R23 (fb console) + R17 (shell).
**Purpose:** Prove cold-boot reaches the shell prompt through the whole
firmware/kernel/init chain. This is the R28.M2 primary acceptance surface —
kernel boots + shell prompts.

Expected line-in-order fingerprint:

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

**Notes.**
- `PaideiaOS R8` is the earliest `klog_puts` after `boot_stub` transitions
  into the higher-half kernel entry.
- `CPU_ID_00_HELLO` and `GS_OK_00` are R18.M1/M2 witnesses (BSP-only; APs
  emit `_01/_02/_03` under `-smp N` but the T14 G4 topology sequencing is
  post-R28 driver-attach and does not gate boot acceptance).
- `SHELL START` is the R17.M4 shell-init witness.
- `$` (dollar-plus-space) is the shell's first prompt emission from
  `sh_repl_print_prompt`.

---

## 2. PdxFS-lite (mount — deferred to post-R28 driver-attach)

**Mode:** `pdxfs`
**File:** `tests/hw/expected-hw-pdxfs.txt`
**Timeout default:** 60 s
**Substrate:** R25 (PdxFS-lite) + R24 (NVMe).
**Purpose:** Prove the rootfs blob (`tools/mkfs-pdxfs-lite-seed.sh` output,
embedded per `design/hardware/t14-g4-first-boot.md §rootfs`) mounts and the
seed file `/etc/hello` is readable from userspace after `cat /etc/hello`.

Expected line-in-order fingerprint:

```
NVME PROBE N=1
NVME READY
PDXFS MOUNT OK
$ cat /etc/hello
hello from paideia
$
```

**Notes.**
- `NVME PROBE N=1` is the R24.M1 (#900-family) enumerator witness under
  UEFI/OVMF PCI walk. Under `-kernel` this line never fires (no MCFG
  surface); it appears only on real HW or under OVMF.
- `NVME READY` is the R24.M2 controller-init settle-poll witness.
- `PDXFS MOUNT OK` is the R25.M7 e2e mount witness (`pdxfs_lite_mount`
  success path). Currently deferred — `pdxfs_lite_e2e_witness` symbol
  exists but the boot path does not call it until R28+ driver-attach
  wires the NVMe blkdev into `pdxfs_lite_mount(root_blkdev_cap)`.
- The `cat /etc/hello` roundtrip requires:
  1. Operator typed `cat /etc/hello` at the prompt (echoed by shell).
  2. Shell's `sh_builtin_cat` (R17.M5) invoked `sys_open`+`sys_read`+
     `sys_write(stdout)` on the mounted PdxFS-lite backing.
- `echo demo > /tmp/mvp` and rebooted `cat /tmp/mvp` (the MVP demo full
  script — see `design/testing/mvp-demo-script.md §step-5..8`) requires
  `nvme_write_blocking` + `commit_dirty_metadata` — R25 debt items — and
  is documented for M4 aspirationally only.

---

## 3. Network (e1000e probe + link + ARP — deferred to post-R28 driver-attach)

**Mode:** `net`
**File:** `tests/hw/expected-hw-net.txt`
**Timeout default:** 60 s
**Substrate:** R27 (e1000e / ARP / IPv4 / ICMP / UDP).
**Purpose:** Prove the i219-LM comes up, e1000e resets cleanly, an ARP
request from the peer host resolves 10.0.0.2 (T14 static IP), and a
`ping -c 3 10.0.0.2` from the peer host lands three ICMP Echo Replies.

Expected line-in-order fingerprint:

```
E1000E PROBE N=1
E1000E RESET
E1000E LINK UP
ARP CACHE
[NET_] L2 RX ARP
[NET_] L2 RX IPV4
[NET_] L3 RX IPV4
[NET_] L3 RX ICMP
```

**Notes.**
- `E1000E PROBE N=1` is the R27.M1 (#971) enumerator witness under UEFI
  PCI walk. `N=1` on the T14 G4 (single on-board i219-LM); higher counts
  are chassis-with-add-in-card configurations.
- `E1000E RESET` is the R27.M1 (#973) CTRL.RST settle-poll witness.
- `E1000E LINK UP` requires the R28+ driver-attach ceremony to enable the
  MSI-X vector 0 walker and the peer host to have negotiated link.
- `ARP CACHE` is the R27.M4 (#986) `arp_cache_add` fingerprint on the
  first `arp_rx_handle` sender-learning path.
- The `[NET_] L2 RX ARP`/`IPV4`/`L3 RX IPV4`/`L3 RX ICMP` sequence is the
  R27.M3–M5 rx-path klog documented in `design/round-retrospectives/
  r27-closure.md §T14 ping demo`.

---

## 4. USB HID (xHCI + Boot Protocol keyboard — deferred to post-R28 driver-attach)

**Mode:** `usb`
**File:** `tests/hw/expected-hw-usb.txt`
**Timeout default:** 60 s (waits for operator keypress).
**Substrate:** R26 (xHCI + HID Boot Protocol keyboard).
**Purpose:** Prove the T14 G4 xHCI controller enumerates, an attached USB
keyboard resolves through the Boot Protocol path, and per-keypress HID
reports translate into ASCII bytes into the shell line buffer.

Expected line-in-order fingerprint:

```
XHCI PROBE N=1
XHCI RESET
XHCI SLOT ENABLED
XHCI CONFIGURE_EP OK
HID BOOT PROTOCOL
HID KEY h
HID KEY e
HID KEY l
HID KEY l
HID KEY o
```

**Notes.**
- `XHCI PROBE N=1` is the R26.M1 (#941) enumerator witness under UEFI PCI
  walk. `N=1` on the T14 G4 (single on-board xHCI at 00:14.0).
- `XHCI RESET` is the R26.M1 (#945) HCRST + CNR-clear witness.
- `XHCI SLOT ENABLED` is the R26.M3 (#953) slot-lifecycle enable witness.
- `XHCI CONFIGURE_EP OK` is the R26.M4 (#958) EP1 IN Interrupt configure
  witness with boot-HID defaults.
- `HID BOOT PROTOCOL` is the R26.M5 (#962) `SET_PROTOCOL(0)` witness.
- `HID KEY <ascii>` is the R26.M6 (#967) HID -> TTY bridge fingerprint.
  Operator is expected to type the ASCII string `hello` on the USB
  keyboard during the capture window; each keypress emits one line.
- The R28+ driver-attach ceremony wires the MSI-X vector 0 walker into
  the IDT so per-keystroke events actually stream. Without that wire,
  the `HID KEY` lines never fire even with a keyboard attached.

---

## 5. Composite (boot_r28_hw_smoke — new in R28.M4 #1008)

**Mode:** `boot_r28_hw_smoke`
**File:** `tests/hw/expected-hw-r28-composite.txt`
**Timeout default:** 240 s
**Substrate:** R18–R27 aggregated (union of §1–§4 above).
**Purpose:** One-shot per-subsystem walk after a single cold-power event.
Used by the operator during the MVP demo (see `design/testing/
mvp-demo-script.md`) to confirm that every subsystem the demo requires
came up in the expected order. This is the acceptance surface for R28
close on real HW.

The composite fingerprint is the concatenation of §1 through §4
fingerprints in order:

```
# From §1 (boot):
PaideiaOS R8
CPU_ID_00_HELLO
GS_OK_00
IDT LOADED
SCHED READY
INIT START
SHELL START
$
# From §2 (pdxfs-lite):
NVME PROBE N=1
NVME READY
PDXFS MOUNT OK
# From §3 (network):
E1000E PROBE N=1
E1000E RESET
# From §4 (USB):
XHCI PROBE N=1
XHCI RESET
XHCI SLOT ENABLED
XHCI CONFIGURE_EP OK
HID BOOT PROTOCOL
```

**What is NOT in the composite fingerprint:**

- The `cat /etc/hello` roundtrip (§2 second half) — requires the operator
  to type at the shell prompt inside the capture window, which the
  single-shot composite mode does not orchestrate.
- The `[NET_] L2 RX ARP`/`ICMP` sequence (§3 rx-path lines) — requires a
  peer host to `ping 10.0.0.2` inside the capture window, orthogonal to
  the composite-boot fingerprint.
- The `HID KEY <ascii>` sequence (§4 keypress lines) — requires operator
  keypresses inside the capture window.

The individual `pdxfs`/`net`/`usb` modes retain the interactive-tail
fingerprints (`cat /etc/hello`, ICMP rx-path, `HID KEY`) for the full
MVP demo (`design/testing/mvp-demo-script.md`).

**Rationale for the composite/interactive split.** The composite mode
answers "did the cold-boot substrate come up correctly?" without demanding
operator interaction inside the capture window. The individual modes
answer "does subsystem X respond to a stimulus?" and require operator
choreography during capture. Both classes of check are needed for the
MVP demo; splitting them lets the operator run the composite mode first
(a no-touch fingerprint check) and follow up with the interactive modes.

---

## 6. Seeding a fingerprint file

Once a T14 G4 cold-boot produces a serial log, the operator seeds each
`tests/hw/expected-hw-*.txt` file as follows:

1. Capture the serial log with `PAIDEIA_HW_SMOKE=1 tools/run-smoke-hw.sh
   boot` (or the composite mode). The capture lands at `/tmp/paideia-hw-
   smoke.log` by default.
2. Extract the deterministic klog lines the kernel emitted for that
   subsystem — one grep-substring per line, in appearance order.
3. Write the extracted lines to `tests/hw/expected-hw-<mode>.txt`,
   one per line, `#`-prefix for annotations, blank lines ignored.
4. Re-run `PAIDEIA_HW_SMOKE=1 tools/run-smoke-hw.sh <mode>` and verify
   the fingerprint check now returns rc=0 (pass) instead of rc=77 (skip).
5. Commit the fingerprint file into the tree. Subsequent regressions
   on the same HW re-anchor to the seeded fingerprint.

---

## 7. Cross-reference

- `tools/run-smoke-hw.sh` — the verifier that reads the fingerprint files.
- `tools/run-smoke.sh` — QEMU-side fingerprint verifier (default pre-push).
- `design/hardware/t14-g4-first-boot.md` — cold-boot walkthrough.
- `design/testing/mvp-demo-script.md` — R28.M4 #1009 operator demo script.
- `design/kernel/serial-console-fallback.md` — screen/tio/picocom recipes.
- `design/round-retrospectives/r27-closure.md §T14 ping demo` — the peer
  host ARP + ICMP capture flow (§3 above interactive companion).
- `tools/xhci-keyboard-smoke.md` — the R26.M6 HID keyboard operator
  recipe (§4 above interactive companion).

*Landed 2026-08-11 at R28.M4 (#1008). Fingerprint file seeding pending
first successful T14 G4 cold-boot.*
