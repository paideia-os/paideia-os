# PdxFS-lite — Mount signature-verify performance

**Status:** Design target
**Date:** 2026-08-11
**Round:** R25 (PdxFS-lite persistent FS MVP)
**Milestone:** R25.M5 — sig-verify substrate close
**Issues:** #929 (verify shim), #930 (embedded pubkey), #931 (corrupt-sb fixture), #932 (this doc)

**Related:** `design/filesystem/pdxfs-lite-format.md` §5.4 (signature scope), `src/kernel/core/fs/pdxfs_lite/verify.pdx` (implementation), `src/kernel/core/config/features.pdx` (flag registry).

---

## 0. Purpose

Fix a numeric target and measurement methodology for the PdxFS-lite superblock signature-verify path so R32 (which introduces the real ML-DSA-65 crypto primitive) has an unambiguous pass/fail bar and the R25 substrate has a measurable baseline.

At R25.M5 the substrate ships in **dev-bypass mode** (`Features.PDXFS_DEV_KEY_ONLY = 1`, `Features.CRYPTO_ML_DSA_ENABLED = 0`) — verify is a 3400-byte memcmp against zero. The real cryptographic verify lands at R32, at which point this document's targets become live acceptance criteria.

---

## 1. Target

| Mode | Path | Target (per mount) |
|------|------|--------------------|
| Dev-bypass (R25.M5 default) | Memcmp sig[0..3400] against zero | ≤ **1 µs** on Raptor Lake |
| Real ML-DSA-65 verify (R32+) | NIST FIPS 204 §5.5 `ML-DSA.Verify` on sig[0..3400] + msg=sb[0..696] + pk | ≤ **5 ms** on Raptor Lake |

Reference hardware: **Intel Core i7-13700H** (Raptor Lake mobile), boosted single-core at ~5.0 GHz, 4 KiB pages, AVX2 on.

### 1.1 Why 5 ms

ML-DSA-65 verify on a modern x86_64 core is ~1–3 ms in the reference C implementation (`liboqs` `pqc_dilithium3_ref`) and drops to ~0.5–1 ms with AVX2 (`pqc_dilithium3_aesni`). Budgeting **5 ms** gives:

- Headroom for a paideia-as codegen path that does not initially exploit AVX2 (the SIMD primitives land on a separate schedule).
- Room for a witness-envelope layer at R40 (see `design/filesystem/pdxfs-lite-format.md` §1.3 slack rationale) that adds a second verify hop.
- A per-mount latency invisible to interactive workflows (mounts are one-shot at boot + on hot-plug, not on the read/write path).

If the R32 implementation lands over 5 ms, either the AVX2 emitter (paideia-as #1004+) must land alongside or the sig field format is revisited.

### 1.2 Why 1 µs (dev-bypass)

Dev-bypass is 425 aligned qword loads + OR + one branch. On Raptor Lake this fits inside one L1-cache-warm loop iteration budget (~1 cycle per load + minimal add/dec/jne overhead), for a wall time of ~500 ns. The 1 µs headroom accommodates:

- One cold cacheline stall if the fake superblock is not pre-touched (mount always stages through `_pdxfs_sb` which the NVMe read has just written, so warm is the typical case).
- Codegen surprises from paideia-as's straight-line loop shape.

Missing the 1 µs target signals a paideia-as codegen regression (not an algorithm bug) and blocks R25.M5 close.

---

## 2. Measurement methodology

### 2.1 Instrumentation site

Add an `rdtsc`-bracket around the `call pdxfs_sb_verify_sig` site in `src/kernel/core/fs/pdxfs_lite/mount_op.pdx` step (1.5). Emit the delta as a klog line `"PDXL VERIFY t=<cycles>\n"` behind a compile-time `PDXL_PERF_INSTR` gate.

Pseudo-body (drop-in for the M5 wire block starting at the `call pdxfs_lite_pubkey_ptr` in `pdxfs_lite_mount`):

```
// Around the verify call:
rdtsc              // t0_lo=rax, t0_hi=rdx
shl rdx, 32
or  rax, rdx
mov r12_perf, rax  // stash

<verify call>

rdtsc
shl rdx, 32
or  rax, rdx
sub rax, r12_perf  // delta cycles
mov rdi, rax
call klog_perf_verify
```

### 2.2 Cycle → time conversion

Raptor Lake's invariant TSC ticks at the base clock (~2.4 GHz on i7-13700H P-cores, per `cpuid.16h.eax`). Convert cycles → ns as:

```
ns = cycles * 1000 / (tsc_khz_from_cpuid_16h / 1000)
   ≈ cycles / 2.4    (base-clock approximation; boost-clock skew is <20 %)
```

At the base clock:

- 1 µs = 2400 cycles → dev-bypass target.
- 5 ms = 12,000,000 cycles → real ML-DSA target.

The witness at `tests/kernel/fs/pdxfs_lite_corrupt_sb.pdx` can be extended at R32 to also assert `verify_cycles < 12_000_000` as a pass/fail gate.

### 2.3 Sampling discipline

Run the verify path 100 times back-to-back inside a single measurement session; take the **P50** (median) as the reported figure. Rationale:

- Cold-cache first sample can skew a mean by 2–3×.
- Boost-clock stepping causes bimodal distributions; median is robust.
- 100 samples fit inside 500 ms even at the 5 ms target — no observer effect on thermal throttling.

An outlier greater than 2× P50 signals either a preemption event (should be impossible during the boot-window verify) or a paideia-as instruction-cache miss (worth investigating separately).

---

## 3. Acceptance test (R32+)

When the R32 flip lands, add a new opt-in smoke gate `PAIDEIA_R32_VERIFY_PERF=1` in `.githooks/pre-push` that:

1. Boots `-kernel build/kernel.elf` with `PDXL_PERF_INSTR=1` compile-time flag on.
2. Wires `pdxfs_lite_corrupt_sb_witness` (extended with a 100-iteration timing loop) into the kernel bringup `-kernel` boot path.
3. Captures the emitted `"PDXL VERIFY t=<cycles>"` lines from the UART log.
4. Asserts the **median** cycle count is under 12,000,000 (5 ms at 2.4 GHz base).
5. Emits `PDXFS VERIFY PERF OK median=<cycles>\n` on pass or `PDXFS VERIFY PERF FAIL median=<cycles>\n` on regression.

The fingerprint file is `tests/r32/expected-pdxfs-verify-perf.txt` (created at R32 landing).

The acceptance is **not** a hard-real-time bound — a single outlier over 12M cycles does not fail the smoke. Only the P50 gates.

---

## 4. R25.M5 baseline (dev-bypass mode)

Not measured on hardware at R25.M5. The estimate below is analytic:

| Component | Cycles | Notes |
|-----------|-------:|-------|
| `add r10, 696` | 1 | base + offset |
| `xor r11, r11` + `mov rcx, 425` | 2 | setup |
| Loop iteration (`mov rax,[r10]; or r11,rax; add r10,8; dec rcx; jne`) | ~5 | Fused uops + branch predicted taken |
| Loop total | 425 × 5 = 2125 | |
| Tail (`cmp r11,0; jne; mov rax,1; ret`) | ~4 | |
| **Total (warm cache)** | **~2132** | **≈ 890 ns @ 2.4 GHz** |

Well within the 1 µs target. First-sample cold-cache cost (worst case one L1 miss per cacheline; 3400 B / 64 = 53 lines) is bounded at ~53 × 4 cycles (L1 miss to L2 latency) = ~212 cycles extra, still under 1 µs.

Warm-cache hardware measurement is deferred until the R25.M5 fixture wires into a real boot path (currently a symbol-only close, matching the R22.M6 `msix_ir_round_robin_witness` posture).

---

## 5. R32 preflight checklist

Before flipping `Features.CRYPTO_ML_DSA_ENABLED = 1`:

- [ ] Real ML-DSA-65 verify primitive lands at `src/kernel/core/crypto/ml_dsa/verify.pdx` under the symbol `ml_dsa_verify(sb, msg, msg_len, pk_pa) -> u64` (returns 1 on pass, 0 on fail).
- [ ] `src/kernel/core/fs/pdxfs_lite/verify.pdx` `pdxfs_sb_verify_sig` body revised: leading `call ml_dsa_verify` branch, dev-bypass path removed (or gated inside a `#ifdef DEV_KEY_ONLY` if we grow one).
- [ ] `src/kernel/core/fs/pdxfs_lite/pubkey.pdx` asset file `assets/keys/pdxfs-lite-dev.pub` regenerated from a real ML-DSA-65 keypair.
- [ ] `tools/mkfs-pdxfs-lite.sh` grows `--sign-with <priv-key>` producing real signatures (see the existing `#R32 signing not implemented` fatal in `tools/mkfs-pdxfs-lite.sh`).
- [ ] `tests/kernel/fs/pdxfs_lite_corrupt_sb.pdx` revised: case (B) (bit-flip in signed region) now expects **rax == 0** (real verify catches the tampering). Case (C) (non-zero byte in sig) still expects rax == 0.
- [ ] `Features.PDXFS_DEV_KEY_ONLY` flipped to 0 in the same commit as the CRYPTO flag flip.
- [ ] Perf smoke `PAIDEIA_R32_VERIFY_PERF=1` added to `.githooks/pre-push` and passes on Raptor Lake reference hardware.

---

## 6. Open items

- **O1.** AVX2 codegen in paideia-as (issue #1004+ tracking). If the real ML-DSA verify lands without AVX2, expect P50 ≥ 3 ms — still under budget but leaves little headroom. Prefer landing AVX2 emitters before flipping the flag.
- **O2.** TSC frequency detection. At R25.M5 no code reads `cpuid.16h.eax`. The acceptance test at §3 needs it — R32 preflight includes a `tsc_khz_from_cpuid_16h()` accessor addition (parallel to `hpet_now_ns`).
- **O3.** Boot-window `rdtsc` availability. TSC is on since R11 (post-init); the verify path runs mid-mount which is well after that. No blocker.
- **O4.** Cache-warmup discipline. The 100-sample methodology at §2.3 assumes the second-through-Nth samples are warm; if the sig-field is 3400 B > L1D (32 KiB) minus other pressure, one sample per mount is not enough to warm. Acceptable at R32 landing; revisit if measurements are noisy.

---

*End of R25.M5 (#932) target document.*
