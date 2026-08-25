# R67 Retrospective (PARTIAL): T14 G4 real-hardware first boot

**Date:** 2026-08-25
**Milestone:** R67.M1 (single-milestone round; PARTIAL close by this
doc)
**Issues:** 2 witnessed under QEMU (#1841 UEFI-stub sanity, #1848 ACPI
discovery — both via pre-existing R19 work) + 1 closure (this doc,
#1857); 5 deferred to a physical T14 G4 session (#1844 GOP first-light,
#1853 VMD probe, #1854 quirks sweep, #1855 boot-transcript real-HW
pass, #1856 HW-observations doc).
**HEAD at closure:** bumped by the commit that lands this doc.
**paideia-as pinned at:** unchanged.
**Release tag:** `r67-closed` applied to the paideia-os HEAD
acknowledging QEMU-side coverage only; real-hardware promotion is a
separate, physically-gated work item (see below).

---

## Round Intent

R67 scoped the T14 G4 real-hardware first-boot milestone: UEFI stub
sanity (#1841), ACPI table discovery via the UEFI ConfigurationTable
(#1848), GOP first-light framebuffer proof-of-life (#1844), VMD probe
wiring for NVMe (#1853), a quirks-table sweep promoting `PROVISIONAL`
rows to `CONFIRMED`/`WORKED-AROUND` (#1854), a full real-hardware boot
transcript (#1855), an HW-observations design doc (#1856), and this
closure (#1857).

Every one of #1841/#1844/#1848/#1853/#1854/#1855 is, by its own
`Deps:` line and file list, a **real-hardware verification step** — it
names artifacts (`src/boot/uefi_*.pdx`, `design/hardware/quirks.md`)
that mostly already exist from earlier rounds, and its job is to
*confirm they behave correctly on physical T14 G4 firmware*, not to
write new code. That distinction drives the disposition below.

---

## R67 Landed / Witnessed (QEMU-side)

- **#1841 R67.M1-001 — UEFI stub sanity.** The signed-PE32+ acceptance
  path this issue asks to verify was already wired and exercised under
  QEMU/OVMF at R19 (commit `b3316b3`, "R19 UEFI/OVMF smoke
  integration + build-uefi-stub SIGPIPE fix"), gated behind the
  `PAIDEIA_UEFI_OVMF=1` opt-in pre-push flag
  (`tools/run-uefi-ovmf.sh` / `tools/verify-fingerprint-coverage.sh`).
  This is real, exercised QEMU/OVMF coverage of the *mechanism*
  #1841 asks about (a FastBoot-compatible UEFI firmware accepting and
  executing the signed image) — it is not, and cannot be, a
  confirmation that the T14 G4's specific physical firmware behaves
  identically. That confirmation is what remains open on real hardware.
- **#1848 R67.M1-003 — ACPI table discovery via UEFI
  ConfigurationTable.** Already implemented, predating this round: the
  RSDP-via-ConfigurationTable walk #1848 asks for is
  `efi_find_rsdp` at `src/boot/uefi_acpi.pdx:67`, landed at R19-M3-003
  (#794) — it matches the ACPI 2.0 GUID, latches `_efi_rsdp_addr`, and
  is documented in that file's own header comment as the R19.M4
  kernel-handoff point. Same caveat as #1841: implemented and QEMU/OVMF
  reachable, but not yet exercised against real T14 G4
  firmware-provided `ConfigurationTable` contents.
- **#1857 (this doc)** — partial closure retro + `r67-closed` tag on
  the paideia-os HEAD acknowledging the above QEMU-side coverage.

## R67 Deferred to a physical T14 G4 session

- **#1844 R67.M1-002 — GOP first-light.** Requires a real UEFI GOP
  linear framebuffer and physical display (or COM1 fallback) — cannot
  be exercised meaningfully under QEMU/OVMF's virtual GOP in a way that
  proves anything about real firmware. Genuinely deferred to hardware.
- **#1853 R67.M1-004 — VMD probe wired into boot path.** Depends on
  #1848 (satisfied above) plus the real R47 VMD driver actually
  encountering VMD-remapped NVMe on physical T14 G4 firmware — no VMD
  remapping exists in the QEMU model. Deferred to hardware.
- **#1854 R67.M1-005 — Quirks table sweep.** By definition an in-situ
  activity: every `PROVISIONAL` row in `design/hardware/quirks.md`
  needs a real observation on real hardware to promote to `CONFIRMED`
  or `WORKED-AROUND`. Cannot be satisfied any other way. Deferred to
  hardware.
- **#1855 R67.M1-006 — Boot-transcript real-hardware pass +
  golden.** Depends on #1844/#1853/#1854 all being exercised in
  sequence on the same physical boot. Deferred to hardware.
- **#1856 R67.M1-007 — HW-observations design doc.** Depends on #1855
  as its primary source material (deltas from QEMU behavior, quirks
  rows touched). Deferred to hardware.

## Cross-Repo Escalations to paideia-as (R67)

**None.** R67's paideia-os-side landed portion touched no code — it
verified pre-existing R19-era implementations already witnessed under
QEMU/OVMF.

## Observable Proof

- `src/boot/uefi_acpi.pdx:67` (`efi_find_rsdp`) exists, is documented,
  and is reachable via the R19.M4 kernel-handoff path.
- `tools/run-uefi-ovmf.sh` + the `PAIDEIA_UEFI_OVMF=1` pre-push gate
  (from R19, `b3316b3`) exercise UEFI-stub PE32+ acceptance under
  OVMF today; `bash tools/verify-fingerprint-coverage.sh` allowlists
  its fingerprint the same way it allowlists R69's opt-in SMP markers.
- No real-T14-G4 serial transcript exists yet — that is precisely
  what #1844/#1853/#1854/#1855/#1856 remain open to produce.

## Quirks Discovered on Real Hardware

None — R67's landed portion is QEMU/OVMF-only by construction (it
confirms mechanisms that predate this round); the entire point of the
five deferred issues above is that quirks discovery only happens once
someone runs the boot on a physical unit, which has not occurred in
this session.

## Debt Inventory at R67 Close

1. **#1844** — GOP first-light. Real hardware required.
2. **#1853** — VMD probe. Real hardware required.
3. **#1854** — Quirks sweep. Real hardware required.
4. **#1855** — Boot-transcript real-HW pass + golden. Real hardware
   required.
5. **#1856** — HW-observations doc. Depends on #1855.

All five share one root gate: a physical T14 G4 unit, USB-serial
adapter, and null-modem cable session — the same hardware prerequisite
`design/hardware/t14-g4-first-boot.md` (R28.M2) already documents in
full for the MVP-image boot recipe. R67's real-HW promotion is not a
paideia-os code-writing task; it is an operator physically running the
existing, already-built artifacts against real firmware and recording
what happens.

**Next Round:** R67 stays open at the real-hardware layer until a
physical T14 G4 session runs #1844→#1856 in order. Nothing in this
monorepo's ordinary (QEMU-only) development loop is blocked by that —
`bash tools/run-qemu.sh` continues to exercise every other round's
substrate unaffected.
