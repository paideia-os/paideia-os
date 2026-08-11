# PaideiaOS — Hardware Regression Matrix

**Owner issue:** paideia-os #1007 (R28.M3-003 — HW regression
matrix — T14 G4 primary, Framework 13 secondary post-MVP,
QEMU-OVMF primary CI-like).
**Status:** Seed v0.1 (R28.M3). Rows for R18-R27 substrates
populated; T14 G4 physical columns are `PROVISIONAL` until first-
light execution.

---

## 0. Purpose

paideia-os has no continuous-integration pipeline
(per `feedback_paideia_os_no_cicd.md` — no GitHub Actions). All
regression discipline is local, executed by a developer or an
autonomous loop before push. This document is the ground-truth
inventory of **which smoke tests run on which target** and **what
the expected outcome is per target x per capability**.

Two audiences:

1. **The pre-push hook / `tools/build.sh` + `tools/run-smoke.sh`
   authors** — the QEMU column of this matrix is the acceptance
   surface for the local pipeline. Any test that regresses on
   QEMU-OVMF blocks the push.
2. **The T14 G4 first-light operator** — the T14 G4 column is the
   acceptance surface for the periodic HW smoke run
   (`tools/run-smoke-hw.sh`, #1002). Any test that regresses on real
   HW blocks the round close and files a hardware-quirk row in
   `design/hardware/quirks.md`.

**Non-goals.** Per-test-case pass/fail bookkeeping (that lives in
`tests/kernel/**` and `tests/hw/**`). Cross-architecture matrices
(paideia-os is x86_64-only through the MVP window per
`design/roadmap/r18-plus-bare-metal.md §0`). Pre-R18 substrate rows
(R00-R17 predate the bare-metal roadmap and are historical).

---

## 1. Targets

### 1.1 QEMU-TCG (historical baseline; no UEFI)

- Boot path: `-kernel` PVH (Multiboot2-adjacent). No `_boot_env`, no
  GOP, no fb subsystem, no NVMe surface, no MCFG-backed PCI
  enumeration.
- Purpose: the pre-R28 regression floor. All substrate that does not
  require UEFI runs here — the `tools/run-smoke.sh` matrix's default
  modes.
- Reproducibility: fully deterministic (no host clock, no host
  entropy). Byte-for-byte identical output run to run when the
  kernel + userland ELF hashes are unchanged.

### 1.2 QEMU-OVMF (primary CI-like surface)

- Boot path: OVMF firmware loads `EFI\BOOT\BOOTX64.EFI` (the R19
  UEFI stub) which hands off to the kernel with a populated
  `_boot_env` (GOP + memory map + ACPI RSDP pointer).
- Purpose: the CI-like surface for R19+ substrate — fb console,
  UEFI physmap, NVMe (with `-device nvme`), xHCI (with `-device
  qemu-xhci`), e1000e (with `-device e1000e`).
- Reproducibility: deterministic modulo OVMF firmware state
  (variables in the pflash var-store). The `tools/run-uefi-ovmf.sh`
  harness resets the var-store per run.
- Cadence: pre-push (`tools/build.sh` + `tools/run-smoke.sh`) covers
  what the harness knows about; extended UEFI matrix runs on demand
  via `bash tools/run-uefi-ovmf.sh`.

### 1.3 T14 Gen 4 Intel (Raptor Lake — primary HW / MVP target)

- Boot path: Lenovo Insyde BIOS → UEFI → USB stick ESP →
  `EFI\BOOT\BOOTX64.EFI` → R19 stub → kernel.
- Purpose: the MVP demo target and the definitive acceptance
  surface for R28 close.
- Reproducibility: non-deterministic (real hardware timing, real
  ACPI, real DMA). Fingerprints are checked in-order-contains, not
  byte-for-byte.
- Cadence: periodic (round-close + HW-relevant substrate changes),
  not per-push. Run via `PAIDEIA_HW_SMOKE=1 tools/run-smoke-hw.sh
  all` per #1002.

### 1.4 Framework 13 (secondary post-MVP)

- Boot path: coreboot-based UEFI → USB stick ESP.
- Purpose: secondary HW target to catch T14-G4-specific quirks
  during hardening. Post-MVP (R33+); rows are placeholders until
  bring-up.
- Reproducibility: same non-determinism story as T14 G4.
- Cadence: after R33+ once the T14 G4 baseline is stable. Not on
  the MVP critical line.

---

## 2. Capability columns

Each capability is a coarse-grained substrate landmark: a test the
matrix asks "does this target execute this substrate cleanly?" The
answer per cell is one of:

| Cell code | Meaning |
|-----------|---------|
| `GREEN`   | Fingerprint present, run-to-run stable, no known regression. |
| `GATED`   | Substrate depends on a hardware-only knob (BIOS toggle, real device); QEMU covers structurally, T14 G4 covers end-to-end. |
| `TODO`    | Substrate landed but this target's fingerprint has not been captured yet. Blocks acceptance until captured. |
| `SKIP`    | Substrate is not exercised on this target by design (e.g. Wi-Fi on the MVP path). |
| `N/A`     | Capability does not apply to this target (e.g. eDP framebuffer on QEMU-TCG PVH). |

| # | Capability | Substrate anchor | What passes |
|---|------------|------------------|-------------|
| C1 | UEFI boot handoff | R19 UEFI stub (#750-#772) | `_boot_env` populated; kernel entry executes; `PDX BOOT` fingerprint reaches wire. |
| C2 | ACPI static table parse | R20 (#807-#824) | `HPET`, `MCFG PRESENT`, `MADT LAPIC N`, `FADT reset_port` fingerprints reach wire. |
| C3 | PCIe enumeration | R22 (#845-#874) | `PCI DEV`, `PCI ENUM DONE` fingerprints; expected device class codes for the target's PCH. |
| C4 | fb-console visible | R23 (#875-#889) | `FB CONSOLE INIT OK`; visible glyph rendering on the target's display surface. |
| C5 | NVMe controller probe | R24 (#890-#910) | `NVME PROBE N>=1`; admin queues bring up; identify controller/namespace clean. |
| C6 | PdxFS-lite mount | R25 (#911-#940) | `PDXFS SB OK`; `MOUNT OK /paideia/rootfs.pdxfs`; `LOOKUP /bin/sh` succeeds. |
| C7 | xHCI keyboard input | R26 (#941-#970) | `XHCI PROBE N>=1`; `XHCI SLOT N=1 ADDR OK`; `HID BOOT PROTO OK`; keystroke traversal to `_tty_line_buf`. |
| C8 | e1000e/i219 NIC + ping | R27 (#971-#997) | `NIC PROBE OK`; ARP request/reply; ICMP Echo Reply on port-0 ping; UDP port-7 echo. |
| C9 | Shell prompt at `/bin/sh` | R28.M1 (#998-#1000) | `SHELL PROMPT`; `echo hello` roundtrip; `shutdown` exits QEMU cleanly (isa-debug-exit). |
| C10 | Panic FB readable | R23.M3-002 (#884) + R28.M3-001 (#1005) | `*** PANIC ***` banner + ring dump BEGIN/END render; photograph transcribable. |

---

## 3. Matrix

Rows are targets, columns are capabilities. Cells cite the smoke
mode / witness that certifies the cell.

| Target \ Cap        | C1 UEFI | C2 ACPI | C3 PCIe | C4 fb-console | C5 NVMe | C6 PdxFS-lite mount | C7 xHCI kbd | C8 NIC ping | C9 Shell prompt | C10 Panic FB |
|---------------------|---------|---------|---------|---------------|---------|---------------------|-------------|-------------|-----------------|--------------|
| **QEMU-TCG (`-kernel`)** | N/A     | GREEN   | GREEN (no MCFG surface — enumerator drains empty; see quirks §2.4 VMD notes) | N/A (no GOP) | SKIP (no MCFG on PVH; nvme_probe returns 0) | GREEN (in-memory mount via seed image mkfs bytes) | N/A | N/A (network devices not attached by default) | GREEN (`boot_r17_shell_*` modes in `tools/run-smoke.sh`) | GATED (fb subsystem dormant on PVH — banner emit path is a load+compare no-op) |
| **QEMU-OVMF**       | GREEN   | GREEN   | GREEN   | GREEN (window via `--display gtk`) | GATED (add `-device nvme,drive=nv0`) | GREEN | GATED (add `-device qemu-xhci`) | GATED (add `-device e1000e,netdev=n0`) | GREEN | GREEN (screenshot proxy per `design/testing/panic-fb-photograph-recovery.md §3`) |
| **T14 G4 (primary)**    | TODO    | TODO    | TODO (VMD-off gate; see quirks §2.4) | TODO (first-panel-output moment) | TODO (VMD off; run `tools/nvme-hw-smoke.md`) | TODO (via `PAIDEIA_HW_SMOKE=1 run-smoke-hw.sh pdxfs`) | TODO (`tools/xhci-keyboard-smoke.md`) | TODO (`PAIDEIA_HW_SMOKE=1 run-smoke-hw.sh net`) | TODO (`design/hardware/t14-g4-first-boot.md §7`) | TODO (physical photograph per `design/testing/panic-fb-photograph-recovery.md §4`) |
| **Framework 13 (post-MVP)** | TODO    | TODO    | TODO    | TODO          | TODO    | TODO                | TODO        | TODO        | TODO            | TODO         |

**Note on TODO cells for the T14 G4 row.** The substrate is landed
kernel-side (`build/kernel.elf` links all the R19-R28 symbols); the
`TODO` reflects that no physical fingerprint has been captured yet.
Each TODO promotes to `GREEN` when the operator lands the first
captured fingerprint blob under `tests/hw/expected-hw-<capability>.txt`
per `tools/run-smoke-hw.sh` conventions, and updates the
corresponding row in `design/hardware/quirks.md` from `PROVISIONAL`
to `CONFIRMED` or `WORKED-AROUND` per §5 discipline.

---

## 4. Cadence

| Cadence | Trigger | Target(s) | Enforcement |
|---------|---------|-----------|-------------|
| Per-push | `git push` | QEMU-TCG default matrix (all `boot_*` smoke modes in `tools/run-smoke.sh`) | `.githooks/pre-push` — blocks push on failure. |
| On-demand | Developer runs it | QEMU-OVMF (`bash tools/run-uefi-ovmf.sh`) | Advisory only; failure blocks the developer but not the push (until a UEFI-covering pre-push mode lands). |
| Round-close | Round-close commit | T14 G4 for HW-relevant substrate; QEMU-OVMF for UEFI-relevant substrate | `design/round-retrospectives/rNN-closure.md` § "Real-Hardware Verification Procedure" must document the run outcome. |
| Periodic | Whenever the T14 G4 is on the bench | T14 G4 full smoke (`PAIDEIA_HW_SMOKE=1 tools/run-smoke-hw.sh all`) | Operator-triggered; on failure, file a quirks-db row + fix issue. |
| Post-MVP | R33+ | Framework 13 secondary target bring-up | Round R33+ scope. |

---

## 5. Regression discipline

When a cell regresses:

1. **Reproduce locally.** Confirm the failure is deterministic on
   the QEMU targets, or is a stable capture on real HW.
2. **Bisect.** `git bisect` across the last known green commit range;
   the pre-push hook's history bounds the bisect window on the
   QEMU columns.
3. **File.** Open a GitHub issue with the smoke mode name + the
   captured-vs-expected diff, labelled `regression:` + the round
   label of the substrate that broke.
4. **Quarantine (rare).** If the fix will take more than one loop
   iteration and blocks unrelated work, add a `SKIP` cell entry in
   this matrix with a link to the issue, then re-close via the
   normal round-close cadence.
5. **Root-cause + fix.** No `SKIP` cell survives past the next round
   close without an explicit deferral rationale.

Quirks-db rows (per `design/hardware/quirks.md §3`) are the
converse discipline: when a real-HW behavior deviates from spec-
nominal, the row lands `PROVISIONAL` at discovery, promotes to
`CONFIRMED` at first-witness, and to `WORKED-AROUND` when the
handling code ships.

---

## 6. Round-by-round substrate inventory (R18-R28)

This §6 is the historical audit trail: for each R18-R28 round, which
capability cell(s) it advanced.

| Round | Substrate landmark | Capability advanced | Post-round state (QEMU-TCG / QEMU-OVMF / T14 G4) |
|-------|--------------------|---------------------|-----|
| R18   | Multicore SMP bring-up (#750-#772 prep) | (foundation for C2, C3) | GREEN / GREEN / TODO |
| R19   | UEFI PE32+ stub + `_boot_env` handoff | C1 UEFI boot | N/A / GREEN / TODO |
| R20   | ACPI static-table parsers (HPET, MCFG, MADT, FADT) | C2 ACPI | GREEN / GREEN / TODO |
| R21   | Timer substrate (HPET, TSC calibrated) | (feeds C3-C10) | GREEN / GREEN / TODO |
| R22   | PCIe MCFG enumeration | C3 PCIe | GREEN (no MCFG — drains empty) / GREEN / TODO |
| R23   | Framebuffer via GOP direct; klog_panic fb-mirror | C4 fb-console; C10 panic FB substrate | GATED / GREEN / TODO |
| R24   | NVMe userspace driver | C5 NVMe | SKIP / GATED / TODO |
| R25   | PdxFS-lite v0 on-disk + VFS wire | C6 PdxFS-lite mount | GREEN / GREEN / TODO |
| R26   | xHCI substrate + HID Boot keyboard | C7 xHCI kbd | N/A / GATED / TODO |
| R27   | e1000e/i219 NIC + IPv4/ARP/ICMP/UDP | C8 NIC ping | N/A / GATED / TODO |
| R28.M1 | MVP demo image assembly | C9 Shell prompt (end-to-end via image) | GREEN / GREEN / TODO |
| R28.M2 | HW smoke harness + serial fallback + T14 first-boot recipe | (verification tooling for C1-C9 on T14 G4) | — / — / — |
| R28.M3 | Panic-FB photograph recovery verify + quirks db seed + this matrix | C10 promotion to acceptance-tracked; matrix landed | — / — / — |

---

## 7. Related documents

- `design/hardware/quirks.md` — per-machine quirks database; the
  provenance of every GATED cell.
- `design/hardware/t14-g4-first-boot.md` — T14 G4 first-full-MVP-boot
  recipe (R28.M2 #1004).
- `design/testing/panic-fb-photograph-recovery.md` — C10 acceptance
  procedure (R28.M3 #1005).
- `design/kernel/serial-console-fallback.md` — serial-capture recipes
  underneath the C1-C9 fingerprint checks on real HW (R28.M2 #1003).
- `tools/run-smoke.sh` — QEMU-TCG matrix runner.
- `tools/run-smoke-hw.sh` — real-HW serial-fingerprint verifier
  (R28.M2 #1002).
- `tools/run-uefi-ovmf.sh` — QEMU-OVMF launcher.
- `tools/nvme-hw-smoke.md` — GDB-driven NVMe HW witness (R24.M6
  #908).
- `tools/xhci-keyboard-smoke.md` — xHCI + HID keyboard HW witness
  (R26.M6 #969).
- `tools/panic-fb-recovery-smoke.md` — panic-FB photograph quick-
  reference (R28.M3 #1005).
- `feedback_paideia_os_no_cicd.md` — the constitutional decision
  that this matrix + local pre-push is the entire regression
  posture.
- `design/roadmap/r18-plus-bare-metal.md` — round-by-round scope
  the matrix's §6 tracks.

---

*Landed 2026-08-11 at R28.M3 close (#1007).*
