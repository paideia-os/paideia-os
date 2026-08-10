// R19 Preflight: Paideia-Native UEFI PE32+ Boot

**Date:** 2026-08-10 (opened at R18 close)
**Round:** R19 — Paideia-native UEFI PE32+ boot (Multiboot2 dropped)
**Roadmap:** `design/roadmap/r18-plus-bare-metal.md` §R19
**Est. issues / dev-weeks:** 22 / 12

---

## What R19 Needs (Substrate Preconditions)

### From paideia-as

1. **`v0.21` tag cut** — bundle MS x64 ABI emit + PE32+ emitter. Current substrate carries the pieces piecewise (`ded3d48` + #1011 CLOSED — MS x64 callee prologue emitter landed); v0.21 tag itself is gated on:
   - **paideia-as #1290** (elaborator T0540 — 2+ arg trait-method call at lambda-body position). OPEN at R18 close. Blocks `PerCpuOps` trait consumption; forces every kernel `[gs:off]` site to use raw rdmsr+indirect (13 sites in R18). R19 does not consume PerCpuOps directly but the tag hygiene rule (workspace.version + git tag + CHANGELOG in one motion) is paused until #1290 lands.
   - **PE32+ emitter** — must produce `MZ` DOS stub + `PE\0\0` COFF header + optional header magic 0x20B (PE32+) + section table + reloc directory suitable for UEFI's `LoadImage` per UEFI 2.10 §II-2.1.1. Filed as `pa-r19-XXX` (issue number to open at R19.M1 kickoff).
   - **`.note.paideia_uefi` section** — carries the typed `boot_env_t` schema fingerprint so the stub's exit-boot-services handoff is version-checked against the kernel it hands to.

2. **MS x64 ABI carrier discipline** — every UEFI Boot Services callsite (`GetMemoryMap`, `AllocatePages`, `LocateProtocol`, `ExitBootServices`, `EFI_TCG2_PROTOCOL::HashLogExtendEvent`) is a Microsoft-ABI callable, not SysV. paideia-as `MsX64Regs` typed carrier (delivered by #1011) is the mechanism; R19.M1 lands the wrappers.

### From R18 (delivered)

- Multicore-safe kernel entry. UEFI hands off BSP-first; R18's SIPI machinery brings APs up unchanged after `ExitBootServices`.
- Per-CPU CB + GS_BASE discipline. AP-side per-CPU CB is programmed by the same `gs_base_init_ap` path R18 landed.
- LAPIC IPI + TLB shootdown. Post-UEFI-handoff kernel already has these.

**No R18 debt blocks R19.** The AP-side IDT gap (Category C-5 in the R18 retrospective) is R21's problem; UEFI Boot Services run BSP-only.

---

## What R19 Delivers

Per roadmap §R19:

- `src/boot/uefi_stub.pdx` — PE32+ EFI application entry `(EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable)`.
- `src/boot/uefi_bs.pdx` — GetMemoryMap / AllocatePages / LocateProtocol wrappers (with map-key retry per hwman §1).
- `src/boot/uefi_gop.pdx` — GOP framebuffer discovery (base + pitch + bpp cached for R23 framebuffer console).
- `src/boot/uefi_acpi.pdx` — RSDP discovery via `EFI_CONFIGURATION_TABLE` (staged for R20 ACPI consumption).
- `src/boot/uefi_measured.pdx` — TPM 2.0 `EFI_TCG2_PROTOCOL` PCR-extend for the kernel-image hash (measured-boot seed; deepens at R33).
- `src/boot/handoff.pdx` — typed `boot_env_t` struct (memmap, framebuffer descriptor, RSDP*, TPM log*).
- `src/boot/exit_bs.pdx` — ExitBootServices + jump to `kernel_main_uefi`.
- `src/kernel/boot/kernel_main_uefi.pdx` — new entry replacing legacy PVH entry.
- `tools/build-uefi-image.sh` — .efi image + ESP layout + ISO/USB assembly.

**Testing sequence:**
1. QEMU `-bios OVMF.fd` — first light on virtual UEFI.
2. `dd` to USB — boot the T14 G4 → **"hello from real hardware"** moment.
3. SwTPM under QEMU — measured-boot PCR-extend fixture.

Milestones scoped at ~5 (M1: PE32+ emit + entry stub; M2: Boot Services wrappers; M3: GOP + ACPI + TPM discovery; M4: ExitBootServices + kernel handoff; M5: USB image assembly + T14 G4 first-light).

---

## R18 Debt Carried Forward (not blocking R19)

For completeness — the R18 debt ledger (see `r18-closure.md` §"What Was Deferred") that R19 explicitly does NOT touch:

- AP-side IDT install + LAPIC config + per-CPU TSS → R21.
- INVPCID upgrade → R29.
- PerCpuOps trait consumers → R29 (after paideia-as #1290).
- Per-CPU magazine slots → R29.
- frame_meta atomic incref → R29.
- Preempt-tail on syscall-return + #PF-return → R21.
- swapgs discipline on all trampolines → R30 (gated on #679).
- MCS lock 8-core contention witness → R20 (composite with MADT).

**Soft cleanup queued for R19 preflight PR (not blocking):**
- `core/sched/idle.pdx:6` — stale reference `#566 extends to per-CPU`; per-CPU idle actually landed via #774 (R18-M4-004). One-line comment fix.

---

## Constitutional Reminders (User Decision Locks)

Per `design/roadmap/r18-plus-bare-metal.md` §0:

1. **T14 Gen 4 is target hardware.** Not Framework 13.
2. **UEFI-native from day 1.** No Multiboot2 stopgap. R19 is where this decision meets first hardware.
3. **PdxFS-lite at R25, PdxFS v1 (CoW-PQ) at R40.** R19 does not touch filesystem; the ESP layout uses FAT32 per UEFI 2.10 §12.3, which is a UEFI conformance requirement not a design choice.
4. **Wi-Fi deferred to R41+.** R19 does not touch networking.

---

## Round Tempo

Per `feedback_paideia_os_tempo.md`: continuous loop across all R19 issues + milestones with no mid-round pause. `softarch → debugger` loop shape per `feedback_paideia_os_loop_shape.md`.

Cross-repo escalations to paideia-as expected: PE32+ emitter is a substantive addition; expect 2-4 encoder gaps to surface during R19.M1. Escalation protocol per `feedback_cross_repo_escalation.md`: file issue + fix + push there, bump submodule, resume.

---

## Opening Sequence (R19.M1 kickoff prep)

Before R19.M1-001 is filed:

1. **Cut paideia-as v0.21 tag** or reconfirm the tag-cutting decision. If #1290 remains open, land the v0.21 bundle *without* PerCpuOps consumability (encoder-side ready, consumer-side deferred).
2. **Draft `boot_env_t` schema** in `design/boot/uefi-handoff.md` — typed struct fields, note-section fingerprint algorithm, kernel-side validation shape.
3. **Choose entry-point name convention** — `_start_uefi` (matches `_start` PVH convention) vs. `_efi_entry` (matches EDK2 idiom). Pin in preflight decision block before M1 opens.
4. **OVMF pinning** — pin an `OVMF.fd` blob (or build-from-source recipe) at a known commit so R19 first-light is reproducible.

---

**Opened:** 2026-08-10 at R18 close. Ready to enter R19.M1 planning.
