# PaideiaOS — Phase 8 planning seed

**Status:** Planning placeholder (no implementation work yet).
**Date:** 2026-06-21.
**Scope:** Stub for issue #186; this phase's detailed osarch/softarch plan will be
authored when Phase 7 closes and paideia-as substrate gates listed below pass.

## Subsystem focus

- **Phase 8**: Network stack (per design/network/*.md; user-space TCP/QUIC).

## Gates before authoring detailed plan

- **paideia-as Phase 7+ substrate**: real fn-body lowering through build path (Phase 6 m1-005 closed the unsafe-block zero-arity gap; Phase 7+ closes the rest: cmp/jcc/call inside real fn bodies, struct field access end-to-end, register allocator beyond the m3-003 4-slot scratch sequence).
- **Phase 7 closed**: predecessor phase work shipped + verified.
- **Design docs frozen**: any open design questions in design/<subsystem>/ resolved.

## Planning protocol (when gates pass)

1. Spawn osarch agent: produce `.plans/paideia-os-phase-8-osarch-plan.md` with milestone + task decomposition.
2. Spawn softarch agent: produce `.plans/paideia-os-phase-8-softarch-plan.md` with PR sizing + label scheme additions.
3. Create GitHub milestones + issues per the plans.
4. Enter the standard autonomous loop.

## References

- `design/00-feature-inventory.md` — feature catalogue (Phase 8 maps to its tier listing here).
- `design/01-foundational-decisions.md` — Q-decisions binding all phases.
- Phase-specific design docs (e.g., Phase 8: design/network/*.md).
