# T14 G4 NVMe scratch-device R/W hardware smoke

**Owner issue:** #908 (R24.M6-001, `gated:hardware`).
**Prereqs to run:** T14 G4 physical unit + a **scratch** NVMe drive (data
loss on sector 0 during the write-back step is expected — do not use a
drive that holds anything you want to keep).
**Status:** Harness landable at R24 close; **live run gated on
first-boot on the T14 G4**.

---

## 0. Scope

This document is the operator-run recipe that promotes the NVMe
substrate landed across R24 (M1–M5) from a QEMU-TCG structural
witness to a real-hardware acceptance witness on the T14 G4.

The wire that this smoke exercises:

- **R22** PCIe enumeration finds a class `01/08 prog-if 02` device on
  the root bus (VMD-off; see §1.2 below).
- **R24.M1** `nvme_probe` records the controller in `_nvme_devices`
  and emits `NVME PROBE N=1`.
- **R24.M2** admin queues bring up + `nvme_identify_ctrl` +
  `nvme_identify_ns` populate `_nvme_id_ctrl_buf`, `_nvme_lba_size`,
  `_nvme_ns_blocks`.
- **R24.M3** per-CPU IO queues get created via `nvme_create_all_io_cqs`
  / `..._sqs`; the current CPU's IO SQ/CQ pair is live.
- **R24.M4** PRP encoding + DMA allocator + MDTS clamp — the buffer
  passed to the read/write helpers is a page-aligned scratch page.
- **R24.M5** `nvme_read_blocking` (kernel-side helper landed at
  `src/kernel/core/drivers/nvme/sync.pdx`) issues one 4 KiB read;
  the write path uses the same SQE-build path with `OPC = 0x01`.

This smoke is **not** an end-to-end regression — it is a one-off
promotion pass to move `design/hardware/quirks.md §2.4` VMD row
+ NVMe-class rows from `PROVISIONAL → CONFIRMED / WORKED-AROUND`.

---

## 1. Preflight

### 1.1 Kernel build

Build the paideia-os kernel per `BUILDING.md`. Confirm the pre-push
matrix passes clean on the host that produces the image:

```
bash tools/build.sh                   # 15/15 gates
bash .githooks/pre-push               # 15 default modes
```

The build produces `build/kernel.elf` linked with every R24 symbol
present (verify via `nm build/kernel.elf | grep -E
'nvme_probe|nvme_identify_ctrl|nvme_identify_ns|nvme_read_blocking'`).

### 1.2 BIOS setup on the T14 G4

Boot into BIOS Setup (F1 at Lenovo splash). Confirm each row
matches the R24 acceptance shape:

| BIOS row | Required value | Reason |
|----------|---------------|--------|
| Security → Secure Boot | Disabled | R33 signing lands later; the R24 kernel is unsigned. |
| Storage → **Intel VMD Controller** | **Disabled** | See §1.2.1. |
| Startup → CSM Support | Disabled | paideia-os is UEFI-only (R19 substrate). |
| Startup → UEFI/Legacy Boot | UEFI Only | Same as above. |

**#### 1.2.1 The VMD toggle is the load-bearing knob**

Per `design/hardware/quirks.md §2.4` VMD row, the Lenovo Insyde BIOS
on T14 G4 ships with **Intel VMD Controller = Enabled** by default,
which hides the NVMe controller behind a proprietary VMD indirection
that the R22 PCI enumerator cannot see through. With VMD enabled,
`nvme_probe` sees zero class-`01/08` devices and emits
`NVME PROBE N=0` — the driver never wires up, every downstream step
is unreachable.

Manual verification after toggling VMD off: on next boot, the T14
G4's UEFI shell (F12 → UEFI Shell if present, or the R19 kernel
early trace) should show the NVMe controller at approximately
`00:0E.0` as a bare PCIe endpoint rather than an
Intel-Volume-Management-Device container.

### 1.3 Boot media

Prepare the R19 UEFI ESP boot media per
`design/roadmap/r19-t14-g4-boot-guide.md`. The ESP contains
`\EFI\BOOT\BOOTX64.EFI` (the R19 loader stub) which handoffs to the
paideia-os kernel with a populated `_boot_env` (GOP + framebuffer +
memory map).

Insert the boot media into the T14 G4 boot order via F12 boot menu at
splash.

---

## 2. Live run

### 2.1 Boot and confirm probe

Power on. Watch either COM1 (Intel DCI over USB-C dongle) or the
framebuffer console (R23 substrate — dormant under `qemu -kernel`,
live on this UEFI boot). Expect the following fingerprints in order:

```
HPET ...                          # R21 timer substrate
X2APIC ENABLED BSP                # R22 xAPIC retirement
MCFG PRESENT ...                  # R22 PCIe substrate
PCI DEV ...                       # per device (~10-30 lines)
PCI ENUM DONE devices=N           # R22 enumerator drain
NVME PROBE N=1                    # <-- R24.M1 target
```

If the last line reads `NVME PROBE N=0`, VMD is still enabled (or the
BIOS toggle did not persist). Return to §1.2.

### 2.2 Attach GDB

The kernel currently halts after the R23/R24 wire-up milestones since
the driver-attach path (probe → identify → io_queues → issue reads)
is not yet wired into `kernel_main` — the M5 acceptance surface is
symbol existence + build-time link verification (see
`design/round-retrospectives/r24-m5-partial.md` § "IDT wire deferral
for #903"). To exercise the driver on live hardware, attach GDB via
the Intel DCI channel:

```
# On the host (with a DCI-capable debug dongle attached):
xdb -a t14g4               # Intel XDB attach; substitute your DCI toolchain
(xdb) target remote :1234
(xdb) symbol-file build/kernel.elf
(xdb) break kernel_main
(xdb) continue
```

Once the kernel is halted at any post-boot point:

### 2.3 Invoke the hardware smoke witness

The witness function `nvme_hw_smoke_witness` lives at
`tests/kernel/drivers/nvme/hw_smoke.pdx`. It is linked into
`kernel.elf` but not called from `kernel_main` — it exists as a GDB
call target. Invoke it under GDB (all steps assume `_nvme_devices[0]`
holds the scratch drive; on a T14 G4 with one M.2 slot there is only
one drive):

```
(xdb) print _nvme_device_count
$1 = 1

(xdb) call nvme_hw_smoke_witness()
NVME HW SMOKE BEGIN
NVME HW SMOKE IDENTIFY-CTRL OK MDTS=<n>
NVME HW SMOKE IDENTIFY-NS OK lba_size=<n> blocks=<n>
NVME HW SMOKE WRITE OK lba=0 bytes=512
NVME HW SMOKE READ OK lba=0 bytes=512
NVME HW SMOKE COMPARE OK
NVME HW SMOKE END
$2 = 0
```

Return value `0` = pass. Non-zero = the failing step's index (1 =
identify_ctrl fail, 2 = identify_ns fail, 3 = write fail, 4 = read
fail, 5 = readback compare fail).

### 2.4 Confirm no CFS after the run

After the witness returns, poll the controller CSTS register to
confirm no fatal-status bit set:

```
(xdb) call nvme_csts_check(_nvme_devices[0].bar0_pa)
$3 = 0
```

`0` = CSTS.CFS unset (healthy). Non-zero = controller entered a
fatal-error state during the run — capture the register value and
attach to a bug report.

---

## 3. Quirks-db promotion pass

After a clean run per §2:

1. **`design/hardware/quirks.md §2.4` VMD row.** Promote status
   `PROVISIONAL → CONFIRMED`. Set `Round observed = R24.M6`. Cite
   the git SHA at which this smoke was run + the drive
   manufacturer/model. If Handling should promote to
   `WORKED-AROUND`, that requires the driver-attach path to wire
   probe → identify → io_queues into `kernel_main` (deferred to R25+
   per `design/round-retrospectives/r24-m5-partial.md` "IDT wire
   deferral").

2. **New rows discovered.** Any behavior that surprises the operator
   during §2 gets a fresh row under `§2.4 Storage + peripherals`:
   - Wrong `class/subclass/prog-if` triple (spec is `01/08/02`).
   - MDTS = 0 (unlimited transfer size) surprising the M4 clamp.
   - Non-4096-byte LBA size (T14 G4 typically ships 512 B logical /
     4096 B physical; drives that surface 4096 B logical may need
     `_nvme_lba_size` widening tests).
   - CSTS.CFS after a clean Identify (indicates firmware bug).

3. **UART bring-up cross-check.** Since T14 G4 has no debug UART on
   the chassis (§2.5 quirk row), the operator should also confirm
   the R23 framebuffer console rendered every fingerprint legibly.
   If the framebuffer stayed black during boot, the R23 substrate
   has a T14 G4 GOP handoff gap that pre-empts the R24 acceptance
   pass — file against `design/round-retrospectives/r23-closure.md`
   § "Real-Hardware Verification Procedure" first.

---

## 4. Cross-references

- `src/kernel/core/drivers/nvme/probe.pdx` — R24.M1 probe body.
- `src/kernel/core/drivers/nvme/identify.pdx` +
  `src/kernel/core/drivers/nvme/identify_ns.pdx` — R24.M2 identify
  build + NS discovery.
- `src/kernel/core/drivers/nvme/io_queue.pdx` — R24.M3 per-CPU IO
  queue lifecycle.
- `src/kernel/core/drivers/nvme/sync.pdx` — R24.M5 kernel-side
  blocking read (`nvme_read_blocking`).
- `src/kernel/core/drivers/nvme/errors.pdx` — R24.M5 CSTS check +
  timeout + abort helpers (`nvme_csts_check`).
- `tests/kernel/drivers/nvme/hw_smoke.pdx` — witness symbol invoked
  under GDB per §2.3.
- `design/hardware/quirks.md §2.4` — VMD row + NVMe rows that this
  smoke promotes.
- `design/roadmap/r19-t14-g4-boot-guide.md` — UEFI boot media
  preparation.
- `design/round-retrospectives/r24-m5-partial.md` — the driver-attach
  wire-up deferral that makes GDB-call the current invocation path.

---

*Landed 2026-08-11 at R24.M6 (#908). Live-run pending physical
hardware access.*
