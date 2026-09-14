# R113 GPU composite readback fence — Wave VVV verification (COMP-IMPL-11)

Status: VERIFIED-GAP-FILLED (Wave VVV, 2026-09-13). Umbrella: R113 (#2380).

## 0. Task mapping note

The dispatch for this item cited "R113.M4-018 GPU composite readback
fence (was #2401)". Neither half of that citation resolves as given:

- `#2401` is `R113.M4-021 — VBlank sync` (see
  `r113-m4-021-verify.md`), not a composite-readback item.
- `R113.M4-018` is `src/kernel/core/graphics/scanout.pdx` (#2398),
  the direct-scanout gate. Direct scanout never composites — there is
  nothing to "read back" on that path — so a readback fence does not
  belong there.

The GPU composite pass that a readback fence would gate is
**R113.M4-019** (`composite_gpu.pdx`, #2399), the GPU-native fallback
blend orchestrator `composite_gpu_blend()` that `M4-018`'s own file
header names as the sibling that owns compositing. This doc verifies
and gap-fills against that file.

## 1. Grep result (pre-fix)

```
$ grep -rn "composite readback fence\|M4-018" src/kernel/gpu src/user/compositor
(no hits — src/kernel/gpu/ does not exist; compositor/ hits are
unrelated present-feedback files)
$ grep -in "fence" src/kernel/core/graphics/composite_gpu.pdx
237:// M4 present-fence hook) is a separate follow-on landing; the
```

Confirmed: no fence of any kind existed in the GPU composite path.
The file's own header explicitly deferred it ("a separate follow-on
landing"). This is a real gap, not a documentation omission.

## 2. Gap filled

Added to `src/kernel/core/graphics/composite_gpu.pdx`:

- `_composite_gpu_fence : u64` (.bss, zero-init) — monotonic
  completion counter.
- `composite_gpu_blend()` step (5.5): bumps the fence unconditionally
  (even when `batches == 0`) immediately after the batch has been
  committed to `_composite_gpu_scratch` and BATCHES/DIRTY stats are
  folded in, and before the `COMPOSITE GPU OK` fingerprint emits.
- `composite_gpu_fence_get() -> u64`: a new non-blocking leaf accessor
  a readback client (or the R36 scanout-side present-fence wire) polls
  to detect that the most recent GPU composite fallback frame has
  fully landed.

This is a software fence (a memory-visible counter), matching the
substrate's current maturity — there is no physical GPU submit-ring
wire yet (`kgsub_note` is itself a documented stand-in per the same
file's §RATIONALE). When the R36 atomic-commit landing wires the real
`KIND_GPU_SUBMIT` submission, `composite_gpu_fence_get` becomes the
CPU-side complement to that hardware fence, not a replacement for it.

## 3. Encoder-pitfall compliance

No `test rN,rN`; no 2-op `imul r,imm`; no `and reg,imm64`; no
`cmp reg,[mem]`; single-line string literals unaffected (no new
strings added); module name unchanged (`CompositeGpu` already matches
`composite_gpu.pdx`). Both new blocks are load-inc-store leaves
identical in shape to the file's existing stats bumpers.
