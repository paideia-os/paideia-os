# PaideiaOS — Phase 2 Entry Conditions

**Status:** Phase-2 (capability system) entry checklist.
**Date:** 2026-06-21.
**Scope:** Resolutions for the open questions in `design/infrastructure/first-milestone.md` §6 — the three Phase-2 entry gating questions.

## Q1 — paideia-as struct surface

**Question:** Does Phase-2 wait for paideia-as struct build-side activation, or proceed with raw-byte cap encoding?

**Decision:** WAIT for paideia-as struct surface activation.

**Rationale:** The capability descriptor (`phase1_capability`, 32 bytes) has tagged-union semantics: kind field, rights bitmask, flags, object reference, LAM tag bits. Encoding it as raw bytes via manual offset arithmetic in every cap_ops function:
- Multiplies the unsafe-block surface tenfold.
- Loses type-checked field access.
- Makes the rights bitmask manipulation (per design/capabilities/rights-catalog.md) prohibitively verbose.

Cost of waiting: paideia-as Phase 6 work (already planned per Phase 5 retrospective §5).

## Q2 — Cap table size

**Question:** What's the cap table size? 256 entries is a placeholder.

**Decision:** **256 entries for Phase-2 placeholder; resizable in Phase-2.5.**

**Rationale:**
- Per `design/capabilities/phase1-api.md` P1CAP-D6: kernel-internal caps only; no userspace exposure. 256 entries is enough for: 
  - ~64 kernel subsystems (boot, MM, IPC, sched, drivers, etc.) each holding ~4 caps on average.
- Resize path: when Phase-3 introduces userspace, per-AS cap tables replace the global slab.
- Larger tables waste BSS; smaller risks early exhaustion.

## Q3 — LAM hardware path

**Question:** Does Phase-2 include the LAM hardware path or only the software-tag fallback per P1CAP-D2?

**Decision:** **Software-tag fallback ONLY in Phase 2.**

**Rationale:**
- LAM hardware support (CR3.LAM57 / CR3.LAM48) needs Sapphire Rapids (server) or Meteor Lake (client) silicon. Per `design/02-development-environment.md` §1, development happens on the Recommended tier which may or may not have LAM.
- Software fallback: encode the 4-bit tag in the high nibble of the handle (bits 60-63 of u64). Pure-software check on every cap_invoke.
- LAM hardware path enables in Phase-2.5 once dev hardware tier is firmed up.
- This matches P1CAP-D2 "hardware LAM only — phase 1 uses dev hardware with LAM" → relaxed to "software fallback for Phase 2; LAM in 2.5".

## Phase-2 entry gates

Phase-2 START blocks on the following:

1. **paideia-as struct surface end-to-end**: `struct Cap { ... }` declarations build to .rodata/.data symbols with field-access in unsafe blocks emitting real bytes.  
   **Status:** paideia-as Phase 5 substrate ships parse + check; build emit gates on Phase 6 walker activation. Filed in paideia-as scope.

2. **paideia-as #734 fix**: encoder routes `mov cr*, gpr` to MovCr encoder.  
   **Status:** Filed in paideia-as #734.

3. **paideia-as #736 fix**: U1606 doesn't fire on zero-operand instructions.  
   **Status:** Filed in paideia-as #736.

4. **Phase-1 QEMU smoke green**: `tools/run-smoke.sh` exits 0 (kernel boots cleanly).  
   **Status:** Gated on #734 + #736.

## Phase-2 start = Phase 6 paideia-as close OR explicit user override

The current discipline: do not start Phase-2 until paideia-as Phase 6 (or a Phase 6 subset addressing the gates above) closes.

User override option: proceed with raw-byte encoding NOW, accept the ugliness, refactor at struct activation. Cost: more unsafe block surface; less type checking; refactor later.

**Default position:** wait. Cost of waiting < cost of two-phase work + refactor.

## Forward links

- `design/capabilities/phase1-api.md` — the Phase-2 capability API spec.
- `design/capabilities/linearity-and-tags.md` §3 — kind enum + tag-bit semantics.
- `design/capabilities/rights-catalog.md` — rights bitmask catalog (16 base rights).
- `design/infrastructure/phase-1-closure.md` — Phase-1 closure + open gates.
- paideia-as `design/toolchain/phase-transition-5.md` §5 — Phase 6 carryover list.
