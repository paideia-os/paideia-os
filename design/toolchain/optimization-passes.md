# PaideiaOS — paideia-as Optimization Pass Catalog

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Detailed catalog of optimization passes available in paideia-as. Each pass is opt-in via annotation; the default is no optimization beyond elaborator evaluation (per `custom-assembler.md` Q-A9). Addresses AS5 from `custom-assembler.md`.

**Hard inputs:**
- `custom-assembler.md` §6.4, §10 — opt-pass discipline (annotation-driven, per-block, catalog-governed).
- `custom-assembler.md` Q-A9 — base behavior is elaborator evaluation only; optimization passes are opt-in.

---

## 0. Catalog discipline

Every pass:
- Operates only on the function or block where its annotation is present.
- Is documented in this catalog with the exact rewrite rules it performs.
- Has its own regression-test corpus at `tests/opt-regression/<name>/`.
- Reports its actions in the diagnostic stream so a programmer can see exactly which rewrites fired.

Adding a new pass:
- Design note in this catalog.
- Implementation in `src/toolchain/asm/opt-passes/<name>/`.
- Test corpus.
- Two reviewer signatures.

Modifying or removing a pass: same review burden.

---

## 1. `#[peephole]` — peephole rewrites

### 1.1 Annotation

```paideia-as
#[peephole]
fn hot_loop() : ... = { ... }
```

### 1.2 Rules (initial catalog)

| Before | After | Rationale |
|---|---|---|
| `mov reg, 0` | `xor reg, reg` | Smaller encoding (3B vs 5B); breaks reg dependency |
| `mov reg, -1` | `or reg, -1` (sign-extended imm8) | Smaller |
| `add reg, 1` | `inc reg` | Smaller; only when flags don't matter |
| `sub reg, 1` | `dec reg` | Same |
| `cmp reg, 0` | `test reg, reg` | Same length; better fusion candidate |
| `mov [mem], imm; mov [mem], imm2` (same addr) | second store | Dead-store-equivalent within block |
| `lea reg, [reg2 + 0]` | `mov reg, reg2` | Cleaner |
| `lea reg, [reg + imm]` | `add reg, imm` (when reg = lea dest) | Smaller in some encodings |
| `shl reg, 1` | `add reg, reg` | Same speed, dependency-friendly |

### 1.3 Constraints

- Does not change semantics (validation: PBT corpus compares emitted-byte behavior to source).
- Does not reorder instructions (that's `#[schedule]`).
- Does not change register choices.

### 1.4 Diagnostics

Each rewrite emits:

```
O1500 info: peephole rewrote `mov reg, 0` to `xor reg, reg` at line 142.
```

---

## 2. `#[schedule(latency)]` — instruction scheduling

### 2.1 Annotation

```paideia-as
#[schedule(latency)]
fn matrix_multiply() : ... = { ... }
```

### 2.2 Behavior

Reorders independent instructions within a basic block to hide latency. Specifically:
- Loads with high latency are scheduled earlier when an independent computation can fill the gap.
- Floating-point and vector operations with high cycle counts are interleaved.
- Memory operations are not reordered across barriers (LOCK, MFENCE, SFENCE, LFENCE).

### 2.3 Constraints

- Does not change instruction selection (per-instruction byte-identical).
- Does not change register choices.
- Respects all memory-ordering constraints.
- Honors `#[noschedule]` on individual instructions.

### 2.4 Use cases

- Vector-heavy code (PQ crypto, BLAKE3, AVX-512 routines).
- Tight loops where ILP matters.

### 2.5 Diagnostics

```
O1503 info: schedule reordered 3 instructions in basic block at line 89; 
expected latency reduction: 14 cycles.
```

---

## 3. `#[dse]` — dead-store elimination

### 3.1 Annotation

```paideia-as
#[dse]
fn write_heavy() : ... = { ... }
```

### 3.2 Behavior

Eliminates stores to memory that is immediately overwritten with no intervening read. Scope: basic block.

### 3.3 Example

```paideia-as
[mem], 0       // store 0
[mem], 1       // overwrite with 1; first store dead
read [mem]     // reads 1
```

After DSE: only the second store remains.

### 3.4 Constraints

- Within a basic block only (cross-block requires data-flow analysis; deferred).
- Volatile MMIO writes are *never* eliminated (the MMIO type marker prevents DSE).
- LOCK-prefixed atomic operations are barriers.

---

## 4. `#[macro-fusion]` — macro-fusion-aware emission

### 4.1 Annotation

```paideia-as
#[macro-fusion]
fn branchy() : ... = { ... }
```

### 4.2 Behavior

When emitting comparison-then-branch sequences, ensure the pair is fusable per Intel SDM Vol. 3, Optimization Reference Manual, "Macro-fusion" chapter (TODO: verify exact section).

Fusable pairs on modern Intel (Sandy Bridge+):
- `CMP` + `Jcc` (most conditions).
- `TEST` + `Jcc`.
- `INC`/`DEC` + `Jcc` (some conditions).
- `ADD`/`SUB` + `Jcc` (Haswell+).

### 4.3 Specific rewrites

- Insert no-ops or align the comparison so the pair shares a 16-byte fetch boundary.
- Avoid REX prefixes that break fusion eligibility.
- Avoid jumping over 32-bit immediates that disable fusion.

### 4.4 Diagnostics

```
O1500 info: macro-fusion-aware emission aligned cmp+je pair at line 67.
```

---

## 5. `#[encode-tight]` — REX/EVEX prefix tightening

### 5.1 Annotation

```paideia-as
#[encode-tight]
fn small_code() : ... = { ... }
```

### 5.2 Behavior

When multiple encodings exist for the same instruction, prefer the smallest:
- `ADD reg32, reg32` over `ADD reg64, reg64` when high bits unused.
- VEX-encoded SSE over legacy SSE when AVX available.
- EVEX over VEX when AVX-512 is needed but the EVEX is the same size.
- Short branches over long when range permits.

### 5.3 Constraints

- Never changes semantics.
- Never changes register choices.
- Respects programmer's `reg64` declaration when present.

### 5.4 Use case

Code-size optimization. Useful for L1 i-cache-bound kernels.

---

## 6. `#[unroll(n)]` — loop unrolling

### 6.1 Annotation

```paideia-as
#[unroll(8)]
for i in 0..1024 {
   body
}
```

### 6.2 Behavior

Unroll the annotated loop by factor `n`. Explicit count; no heuristics.

```paideia-as
// After unroll(8):
for i in 0..1024 step 8 {
   body[i]
   body[i+1]
   body[i+2]
   body[i+3]
   body[i+4]
   body[i+5]
   body[i+6]
   body[i+7]
}
```

If loop trip count is not divisible by `n`, the toolchain emits a remainder loop.

### 6.3 Constraints

- Trip count must be known at unroll time, or the unroll is suppressed with a warning.
- Body must be small enough that unrolled body fits in L1 i-cache (~32 KiB).

### 6.4 Use cases

- Hot inner loops with small body and high trip count.
- Vector-heavy code where unrolling exposes ILP.

---

## 7. `#[branch-hint(likely)]` / `#[branch-hint(unlikely)]`

### 7.1 Annotation

```paideia-as
if #[branch-hint(unlikely)] error {
   error_path
} else {
   happy_path
}
```

### 7.2 Behavior

Lay out the basic block to make the hinted branch the fall-through (more cache-friendly) path. The unhinted branch becomes the taken (jump-required) path.

### 7.3 Constraints

- Does not change semantics.
- Affects code layout only.
- On modern CPUs with sophisticated branch predictors, hints have moderate effect. Useful primarily for code layout.

---

## 8. `#[align(n)]` — alignment

### 8.1 Annotation

```paideia-as
#[align(64)]
fn cache_line_aligned() : ... = { ... }
```

### 8.2 Behavior

Pad before the function entry (or loop head) to align to `n` bytes. `n` must be a power of 2; typical: 16, 32, 64 (cache line), 4096 (page).

### 8.3 Use cases

- Function entry alignment for branch-target buffers.
- Loop head alignment for prefetcher efficiency.
- Page alignment for code that must be the start of an executable page.

---

## 9. `#[pool-constants]` — constant table pooling

### 9.1 Annotation

```paideia-as
#[pool-constants]
fn constants_heavy() : ... = { ... }
```

### 9.2 Behavior

Lift repeated large immediates into a read-only constant pool; reference via RIP-relative load.

### 9.3 Use case

- AVX-512 mask constants used multiple times in a function.
- Large 64-bit immediates used more than once.

### 9.4 Trade-off

Saves code size; adds a load.

---

## 10. `#[tailcall]` — tail-call elimination

### 10.1 Annotation

```paideia-as
#[tailcall]
fn recursive_step() : ... = {
   if base_case { return result }
   recursive_step()    // tail call eliminated
}
```

### 10.2 Behavior

Replace a final `call`+`ret` pair with a `jmp` when the ABI permits:
- Same calling convention.
- Callee's frame fits within the caller's allocation.
- Caller has no frame remnants the callee would need.

### 10.3 Constraints

- Cannot eliminate across capability-boundary calls (the linearity discipline forbids).
- Cannot eliminate across effect-handler-installing calls.
- Toolchain emits diagnostic if it cannot eliminate when annotated.

---

## 11. Composition

Multiple opt-pass annotations on the same function compose in catalog order (the order in this document):

1. peephole (rewrites instructions)
2. schedule (reorders, no rewrites)
3. dse (eliminates dead stores)
4. macro-fusion (alignment for fusion)
5. encode-tight (smallest legal encoding)
6. unroll (already happened in IR, but tighten encoding after)
7. branch-hint (code layout)
8. align (final alignment)
9. pool-constants (data layout)
10. tailcall (final emission)

A function annotated `#[peephole, schedule, encode-tight]` runs these passes in catalog order.

---

## 12. No default optimization

Per `custom-assembler.md` Q-A9, there is no global "release build" toggle. Every optimization is per-block opt-in. A "release build" is therefore *not* the same code as "debug build with `-O0`" — they are literally the same code. This is a deliberate choice for predictability.

---

## 13. Future passes (not in initial catalog)

| Annotation | Description | Phase |
|---|---|---|
| `#[strength-reduce]` | Replace `*` by power-of-2 with `<<` | Phase 3 |
| `#[common-subexp]` | Common subexpression elimination within block | Phase 3 |
| `#[invariant-hoist]` | Loop-invariant code motion | Phase 3 |
| `#[prefetch-insert]` | Insert software prefetches based on access pattern | Phase 3 |
| `#[register-rename-aware]` | Avoid false dependencies via register choices | Phase 3 |
| `#[bypass-cost]` | Optimize for bypass-network latency (AVX-512 ↔ FP) | Phase 4 |

Each requires its own catalog entry (per §0).

---

## 14. Open issues

| ID | Issue |
|---|---|
| OPT-O1 | The exact macro-fusion catalog per Intel generation — needs revisiting with Optimization Reference Manual. |
| OPT-O2 | DSE across basic blocks — phase 3+ data-flow analysis. |
| OPT-O3 | The `#[schedule]` algorithm — list scheduling vs. trace scheduling; choice deferred. |
| OPT-O4 | Cross-pass interaction — when `#[unroll]` and `#[schedule]` both apply, the order matters. The order in §11 is initial; tuning may follow. |
| OPT-O5 | Performance regression testing — every pass must show measurable benefit on its target workload; the test infrastructure for this is not yet built. |

---

*End of document.*
