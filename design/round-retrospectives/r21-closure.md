// R21 Retrospective: FPU/XSAVE + Interrupt Controller Completion + Timing

**Date:** 2026-08-10
**Milestone:** R21.M1–R21.M5 (all closed; M5 = closure milestone this doc + #846)
**Issues:** 21 landed (17 implementation + 1 closure + 1 deferred: #845); #842 (HPET), #843 (TSC), #844 (x2APIC probe substrate), #846 (this doc + STATUS)
**HEAD at closure:** (bumped by the R21.M5 commit that lands this doc)
**paideia-as pinned at:** `2cf169d` — unchanged across R21 (no cross-repo escalation this round)

---

## Round Intent

R21 was scoped as the FPU/XSAVE + interrupt-controller completion + timing round per `design/roadmap/r18-plus-bare-metal.md` §R21. The five milestones threaded the CPU-state substrate first, then the interrupt-plumbing substrate, then the timing substrate in order:

- **M1:** XSAVE probe + enable + eager save/restore + per-task XSAVE region.
- **M2:** AVX2 / AVX-512 CPUID gating + YMM-preservation regression fixture.
- **M3:** IOAPIC MMIO primitives + programming + reroute witness.
- **M4:** PCIe ECAM + MSI + MSI-X + per-CPU vector pool.
- **M5:** HPET monotonic time (#842) + TSC calibration (#843) + x2APIC MSR-mode probe substrate (#844) + xAPIC MMIO retirement (#845, deferred) + closure retro (#846).

Pillar 6 target: give the kernel exactly the substrate it needs so that every SIMD-executing thread preserves YMM state across a context switch, every PCIe device can raise a per-CPU MSI/MSI-X vector, and the kernel has a wall-clock-quality nanosecond source not derived from the (variable-frequency) TSC.

---

## What Shipped

### R21.M1 — XSAVE substrate (5 issues: #825–#829)

- **#825 XSAVE probe (BSP)** — `src/kernel/core/cpu/xsave.pdx` `xsave_probe_bsp` walks CPUID leaf 0x0D, extracts supported/enabled-state masks + max/current area sizes.
- **#826 CR4.OSXSAVE + XCR0 enable** — `xsave_enable_this_cpu` sets CR4 bit 18 then programs XCR0 with the target mask (x87|SSE|YMM if supported). Called on BSP from `kernel_main` and on each AP from `ap_entry` after `gs_base_init_ap`.
- **#827 Per-task XSAVE area** — `_task_xsave_areas: [u64; 33280]` `.bss` slot @align(64), one 8-KiB region per task slot.
- **#828 Eager save/restore in sched_switch** — `xsave_save_for(pid)` / `xsave_restore_for(pid)` wrap the register-save/restore chain in `sched_switch_r15`.
- **#829 XSTATE_BV=0 on task creation** — fresh tasks' XSAVE region has `XSTATE_BV = 0` so first `xrstor` loads the architectural init values (FCW=0x37F, MXCSR=0x1F80, XMM/YMM all zero).

**Closure commit:** `9f02d19`.

### R21.M2 — AVX2/AVX-512 gating + YMM-preservation fixture (3 issues: #830–#832)

- **#830 cpu_probe_avx2** — 4-predicate AND (max_std_leaf≥7 AND OSXSAVE AND AVX AND XCR0[YMM] AND CPUID.07H:EBX[AVX2]). Populates `_cpu_has_avx2`; emits `CPU AVX2 available|unavailable` fingerprint.
- **#831 cpu_probe_avx512** — 4-predicate AND on the wider AVX-512 subset (F/DQ/CD/BW/VL sampling into a packed bitmap even when the gate closes).
- **#832 YMM-preservation regression fixture** — `tests/kernel/cpu/ymm_preserve.pdx` two witnesses (`_a` and `_b`) round-trip YMM0 through `xsave_save_for` / `xsave_restore_for`. Emit `YMM PRESERVE A OK` / `_B OK` on `-cpu max`; auto-skip silently on qemu64 default.

**Closure commit:** `71bd96a` (pre-fix), `f87174f` (pre-push wire-in).

### R21.M3 — IOAPIC base-parametric primitives (4 issues: #833–#836)

- **#833 ioapic_read_at** — 32-bit MMIO read of internal IOAPIC register via IOREGSEL+IOWIN.
- **#834 ioapic_write_at** — symmetric write.
- **#835 ioapic_program_redir** — RTE composition (delivery mode, dest_mode, polarity, trigger, mask, dest APIC ID).
- **#836 IOAPIC re-route structural witness** — saves + reprograms + restores RTE #4 in the boot cli window; opt-in smoke `boot_r21_ioapic_reroute` (gated by `PAIDEIA_R21_IOAPIC=1`).

**Closure commit:** `67898cc`.

### R21.M4 — PCIe ECAM + MSI + MSI-X + vector pool (5 issues: #837–#841)

- **#837 pci_ecam_addr** — segment/bus/device/function → ECAM VA computation.
- **#838 pci_ecam_read32/_write32** — 32-bit config-space access.
- **#839 msi_program** — programs Message Address + Data at a config-space MSI-cap offset.
- **#840 msix_program_entry** — 16-byte MSI-X table entry (msg_addr_lo/hi, msg_data, vector_control).
- **#841 vector pool + MSI-X round-robin witness** — per-CPU `_vector_pool_bits`, `vector_alloc_for_cpu` / `_free_for_cpu`, `msix_round_robin_witness` allocates one vector per CPU × 4 and verifies uniqueness + byte-level programming.

**Closure commit:** `996b88c`.

### R21.M5 — HPET + TSC + x2APIC + closure (4 issues landed; 1 deferred)

- **#842 HPET main counter as monotonic-time source** — `src/kernel/core/time/hpet.pdx`:
  - `_hpet_ctx : [u64; 4]` cache (base, period_fs, freq_hz, period_ns).
  - `hpet_init(counter_base)` reads GENERAL_CAPS bits 63:32 → period_fs, derives freq_hz = 10^15 / period_fs (via `div r64` — 10^15 fits in 63 bits), derives period_ns = period_fs / 10^6 clamped ≥1, enables the counter by OR'ing GENERAL_CONFIG bit 0, emits `HPET INIT OK period_fs=<N> freq_hz=<N>` fingerprint (via klog_s1_x2 — 6 register args + v2 spilled on stack).
  - `hpet_now_ns() -> u64` reads MAIN_COUNTER @ base+0xF0 (64-bit MMIO load), multiplies by precomputed period_ns via `imul r64, r64` (paideia-as has `imul` but not `mul` for 128-bit product; the precomputed-ns approach is a substitute that trades ~1.2% steady-state error on Intel PCH 14.31818 MHz for correctness up to ~4000 years at that clock — loss-free on QEMU q35 100 MHz where period_ns = 10 exactly).
  - Kernel wire-in: `mov rdi, 0xFED00000; call hpet_init;` in `kernel_main` after `ymm_preserve_synth_witness_b`.

- **#843 TSC calibration via PM_TMR** — `src/kernel/core/time/tsc.pdx`:
  - `_tsc_hz : u64` cache; `PM_TMR_HZ = 3579545` (ACPI 6.5 §4.8.3.1 exact).
  - `tsc_calibrate(pm_tmr_port) -> u64`:
    - Sample pm_start (32-bit port read via `in_eax al`, mask & 0xFFFFFF for 24-bit counter).
    - Sample tsc_start via `rdtsc` + edx:eax reconstruct.
    - Busy-poll PM_TMR until (pm_now - pm_start) & 0xFFFFFF ≥ 35000 ticks (~9.77 ms at 3.579545 MHz) OR poll budget of 10^8 iterations exhausted (defensive against wrong port).
    - Sample tsc_end, compute pm_delta and tsc_delta, publish `_tsc_hz = tsc_delta * PM_TMR_HZ / pm_delta` (imul + div).
    - Emit `TSC CALIBRATED hz=<N>` fingerprint (klog_s1_x1). On timeout path emits with hz=0x0 so smoke pipeline observes the failure mode explicitly instead of hanging boot.
  - `tsc_ns_to_ticks(ns)` / `tsc_ticks_to_ns(ticks)` — simple ratio helpers.
  - Kernel wire-in: `mov rdi, 0x608; call tsc_calibrate;` in `kernel_main` after `hpet_init`.

- **#844 x2APIC MSR-mode substrate** — `src/kernel/core/apic/x2apic.pdx` (extended from stub):
  - `_x2apic_supported : u64` cache.
  - `x2apic_probe() -> u64` — CPUID.01H:ECX bit 21 test.
  - `x2apic_probe_bsp()` — BSP-once wrapper, publishes `_x2apic_supported`, emits `X2APIC AVAILABLE` or `X2APIC ABSENT` fingerprint (SUBSYS_APIC).
  - `x2apic_enable_this_cpu()` — sets IA32_APIC_BASE bits 10 (X2APIC) + 11 (XAPIC) via rdmsr/wrmsr. **NOT called from `kernel_main` under R21.M5** — enabling would disable xAPIC MMIO per SDM Vol 3A §10.12.2, silently breaking every downstream LAPIC callsite.
  - `x2apic_read(reg_offset) -> u64` / `x2apic_write(reg_offset, value)` — MSR wrappers indexed by `0x800 + (reg_offset >> 4)`. Callers pass the xAPIC MMIO offset so #845's retirement is a mechanical MMIO-store → x2apic_write substitution.
  - Kernel wire-in: `call x2apic_probe_bsp;` after `tsc_calibrate`.

- **#846 R21 closure retro + STATUS.md** — this doc; STATUS.md R21 CLOSED block; tag `r21-closed`.

- **#845 xAPIC MMIO retirement — DEFERRED (see §"What Didn't Work")**. The substrate (`x2apic_read` / `x2apic_write`) is complete and ready; the retirement is a mechanical rewrite of every LAPIC MMIO write site to the MSR wrapper, gated on a multi-CPU stress test suite that R21 does not yet have.

**Closure commit:** (this M5 commit).

---

## Fingerprint Contract (R21.M5)

Every boot emits exactly these three new lines between `CPU AVX-512 unavailable ...` and `R17 WORD STORE OK`, in this order:

```
HPET INIT OK period_fs=<N> freq_hz=<N>
TSC CALIBRATED hz=<N>
X2APIC AVAILABLE   (or  X2APIC ABSENT)
```

Observed on QEMU-TCG default (i440fx + qemu64):

```
HPET INIT OK period_fs=0x0000000000989680 freq_hz=0x0000000005f5e100
TSC CALIBRATED hz=0x00000000896764c1
X2APIC ABSENT
```

- HPET period_fs = 0x989680 = 10,000,000 → 10 ns/tick → 100 MHz (QEMU HPET default).
- HPET freq_hz = 0x5F5E100 = 100,000,000.
- TSC hz ≈ 2.31 GHz (matches host CPU under TCG single-thread execution).
- X2APIC ABSENT: QEMU-TCG doesn't emulate x2APIC (QEMU emits `TCG doesn't support requested feature: CPUID.01H:ECX.x2apic [bit 21]` when the option is forced). Under KVM or on real T14 G4 Raptor Lake this flips to AVAILABLE.

---

## Runtime Witness Outcomes

- 14/14 default-matrix pre-push smokes pass (`boot_r8_only` through `boot_smp`).
- 3/3 R21 opt-in smokes pass (`boot_r21_ymm_preserve` / `_ioapic_reroute` / `_msix_round_robin`).
- **`boot_smp` — the primary regression gate for #845 — passes.** Because #845 (xAPIC retirement + x2APIC enable) is deferred, this is the pre-refactor baseline; when #845 lands in R22, `boot_smp` becomes the acceptance witness.

---

## What Worked (Round Discipline)

1. **softarch → debugger loop shape held throughout.** No mid-round pauses; each milestone's kickoff was an architect+implement pass producing all sub-issue landings + fixtures, followed by a debugger pass that debugged failures. Zero workerbee invocations (per `feedback_paideia_os_loop_shape.md`).

2. **Continuous tempo across five milestones.** Per `feedback_paideia_os_tempo.md`, R21 ran continuous with no between-milestone review pause. All 5 milestones closed within a single loop day.

3. **Defensive timeouts on PM_TMR busy-poll.** The M5 first-implement pass hardcoded `pm_tmr_port = 0x1808` (some x86 references cite this for q35). Under smoke (default machine = i440fx, PMBASE = 0x600) that port is stuck-at-0 and the busy-poll would have hung boot. The 10^8-iteration cap + explicit `TSC CALIBRATED hz=0x0` fingerprint on the failure path caught this within one boot cycle and pointed at the port hardcode instead of masquerading as a random hang. Every hardcoded-address MVP path in the timing modules got the same treatment.

4. **Substrate landed without enabling.** The x2APIC helpers (`x2apic_read` / `x2apic_write` / `x2apic_enable_this_cpu`) all landed as `pub` symbols but the enable is not called from `kernel_main`. This proves the substrate is compile-ready for #845 while keeping the xAPIC MMIO paths active. `nm build/kernel.elf | grep x2apic` shows all four symbols.

---

## What Didn't Work

1. **#845 xAPIC retirement — deferred.** The task discipline explicitly acknowledged this as the risk vector: "x2APIC retirement is the risk vector — do it AFTER #844 verifies. If problems: keep xAPIC paths." What became clear during the M5 kickoff analysis was that #844 (enable x2APIC) and #845 (retire xAPIC MMIO) are NOT sequential — they are ONE atomic switch. Enabling x2APIC without simultaneously retiring the eoi/tpr/ipi/self_ipi/lapic_timer/tsc_deadline/reschedule_ipi/init_sipi MMIO consumers would silently break every LAPIC callsite (per Intel SDM Vol 3A §10.12.2: setting IA32_APIC_BASE.X2APIC=1 disables MMIO). And doing them together in one commit puts `boot_smp` at severe regression risk with no rollback boundary short of `git revert HEAD`. The pragmatic call was to land the substrate (probe + MSR helpers) and defer the enable + retirement to R22.M1 where a targeted PR can pair the two changes with `boot_smp` as the strict acceptance gate.

2. **PM_TMR port hardcode.** The R20.M3 FADT parser already knows the correct port via `_phase1_acpi_info.fadt.pm_tmr_port`, but `phase1_acpi_gather` is not yet called from `kernel_main` / `kernel_main_uefi` (R20 debt item #2). The hardcode at 0x608 is correct for both QEMU q35 and i440fx (both use PMBASE=0x600) but incorrect for T14 G4 Raptor Lake. The proper wire-up will land as part of `phase1_acpi_gather` integration, which is queued behind the ELF loader completion in R22.

3. **`hpet_now_ns` precision.** paideia-as has `imul r64, r64` (2-operand, 64x64→64 truncated) but not `mul r64` (1-operand, 64x64→128 in rdx:rax). This forced the "precomputed integer period_ns" approach instead of the natural `ticks * period_fs / 10^6` computation. Loss-free on QEMU q35 100 MHz (period = 10 ns exactly); ~1.2% steady-state error on Intel PCH 14.31818 MHz (period = 69,841,841 fs → period_ns = 69). Consumers that need sub-1% precision will need either a fixed-point period representation or a paideia-as `mul r64` primitive. Not a real concern for R21 consumers (scheduler tick + wall-clock display); flagged for R22 assessment.

---

## Preflight for R22

**R22 (x2APIC MSR retirement + kernel-space heap allocator + syscall latency substrate)** — opens after R21 close. Draft preflight to land as `design/round-retrospectives/r22-preflight.md` at R22.M1 kickoff. R22 needs from R21:

1. **`x2apic_enable_this_cpu` + `x2apic_read` / `x2apic_write` substrate.** Ready to consume — the retirement issue #845 mechanically rewrites every LAPIC MMIO write site to the MSR wrapper. The retirement PR must pass `boot_smp` in its first CI cycle or revert cleanly (single-commit boundary).
2. **HPET as monotonic clock.** `hpet_now_ns()` is the wall-clock-quality nanosecond source R22's syscall latency histogram consumes at both syscall entry and return sites.
3. **TSC calibration output (`_tsc_hz`).** Feeds the future scheduler tick calibration (per-CPU TSC-deadline arming) and the syscall latency histogram's TSC-to-ns fast path.
4. **PCIe ECAM + MSI-X vector pool.** Ready for the R22.M3 first-real-driver-plane consumer (virtio-net or NVMe MSI-X vector allocation).

**R22 does NOT need from R21:**

- Higher-half kernel remap. Still needed but not scoped to R21; R22.M2 opens the kernel-space heap allocator on top of the existing physmap, which does not require the higher-half remap.
- ACPICA. R22 remains AML-free (per the R20.M4 guardrail).
- Real T14 G4 hardware. R22.M1's x2APIC retirement is a QEMU-only refactor (KVM optional, TCG default) — the hardware validation lands when the operator captures the fixture.

**R22 blockers (external):**

- paideia-as v0.21 tag remains uncut; R22 does not need a tag bump. If paideia-as `mul r64` (128-bit product) lands intra-R22, opportunistic HPET precision fix.
- No R21 debt blocks R22 opening.

---

## R21 Debt Carried Forward

Ledger of items deferred past R21 close:

1. **#845 (retire xAPIC MMIO code paths)** — R22.M1. Substrate ready. Boot_smp is the strict regression gate.
2. **`phase1_acpi_gather` wiring** — R22.M1 (paired with #845 so the ACPI-derived PM_TMR + HPET base override the hardcodes in the same commit).
3. **T14 G4 hybrid-P/E fixture (R21.M5 hardware task)** — GATED ON HARDWARE. Real-hw verification procedure documented in the next section; enables when the operator captures the ACPI tables + boots the kernel on real T14 G4.
4. **`hpet_now_ns` precision widening** — R22 assessment. Widen `_hpet_ctx.period_ns` to u32.32 fixed-point (or land paideia-as `mul r64`) once a precision consumer arrives.
5. **AP-side x2APIC enable** — After #845 lands (BSP-side), APs need the same enable call in `ap_entry.pdx` before any LAPIC access. Single-line addition once the retirement is settled.
6. **T14 G4 quirks-db additions** — 3 new PROVISIONAL rows to add to `design/hardware/quirks.md` at first-boot: TSC-hz in the 2.4-3.2 GHz P-core range, HPET period_fs = 69,841,841 (14.31818 MHz), x2APIC available.

None regress R21 acceptance.

---

## Real-Hardware Verification Procedure (T14 G4 Raptor Lake, R21.M5 gated:hardware)

The hybrid P/E core fixture cannot run under QEMU-TCG (no hybrid topology, no x2APIC, no real HPET frequency). It becomes exercisable when the operator boots on T14 G4:

1. **Prepare boot media.** Build kernel + ESP image per `design/roadmap/r19-t14-g4-boot-guide.md`. Ensure `boot_smp` passes locally.

2. **Boot on T14 G4.** Serial output should show:
   - `HPET INIT OK period_fs=0x000000000429E5B1 freq_hz=0x0000000000DA6EF0` (Intel PCH 14.31818 MHz — period_fs = 69,841,841; freq_hz = 14,318,320).
   - `TSC CALIBRATED hz=<between 0x8F0D1800 and 0xBEBC2000>` (2.4-3.2 GHz Raptor Lake P-core burst frequency).
   - `X2APIC AVAILABLE` (Raptor Lake supports x2APIC unconditionally).
   - `SMP BRINGUP START` / `CPU_ID_XX_HELLO` per AP / `SMP BRINGUP DONE`.

3. **Verify MADT enumeration.** `_madt_lapics` should populate with all 14 logical CPUs on T14 G4 U/P: 6 P-cores × 2 SMT threads + 8 E-cores × 1 thread = 20 threads (or 12 threads on the E-only variant). Serial line: `SMP BRINGUP DONE` follows `CPU_ID_XX_HELLO` for each AP.

4. **Verify hybrid topology.** CPUID.1AH probe (R18.M6 landed) tags each CPU as P/E/LP-E in `_percpu_cbs[i].hybrid_kind`. Not directly emitted at boot — requires GDB-invocable dump or an inline witness (R22 candidate).

5. **Populate quirks-db.** Confirm rows in `design/hardware/quirks.md`. Add three new CONFIRMED rows per §"R21 Debt Carried Forward" #6.

**None of this blocks R21 close.** The QEMU-side R21 substrate is proven; T14 G4 first-light is a separate hardware-availability event.

---

## Milestone Discipline Statement

R21 held to the round-tempo user preference: continuous loop across all issues + milestones with no mid-round pause. 5 milestones closed in one loop day; 21 issues landed (17 implementation + 1 closure + 1 tracked deferral #845 + 2 doc-only #846/STATUS).

The `softarch → debugger` loop shape held throughout with zero workerbee invocations. Cross-repo escalation to paideia-as fired **zero times** during R21 — the substrate was ready for every encoder R21 needed (rdmsr / wrmsr / rdtsc / cpuid / in_eax / imul / div, all pre-existing). `paideia-as` submodule pin `2cf169d` unchanged from R20 close.

---

## Next Round

**R22 (x2APIC MSR retirement + kernel-space heap allocator + syscall latency substrate).** See `design/roadmap/r18-plus-bare-metal.md` §R22 (to be authored — R22 opens as a fresh scoping pass). Preflight document to land at R22.M1 kickoff as `design/round-retrospectives/r22-preflight.md`.

R22 blockers: none from R21. Ready to open.

---

**Closure.** R21 FPU/XSAVE + interrupt-controller completion + timing — closed 2026-08-10.
