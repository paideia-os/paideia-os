# Compositor golden fingerprint corpus — Wave VVV (COMP-IMPL-15)

Status: DOCUMENTATION ONLY. Source of truth: the five `expected-*.txt`
goldens under `tools/boot/compositor-smokes/` and
`design/testing/compositor-qemu-smoke-plan.md` (Wave SSS,
2026-09-13). None of these fixtures are wired into
`tools/run-smoke.sh`'s `MODE` dispatcher yet — every `.sh` stub exits
77 (skip) per the Wave SSS prerequisite-gap list (G1–G8 in the plan
doc). This doc collects the corpus in one place per the
`<smoke-name>: <regex-or-literal-fingerprint>` format requested for
Wave VVV; all entries below are **literal** substrings (`run-smoke.sh
--fingerprint` does literal ordered-substring matching, not regex —
see the plan doc §2), matched in the order listed, per fixture.

## Corpus

```
boot_r113_compositor:    COMP INIT OK

boot_svc_compositor:     COMP INIT OK
                         SVC-COMP READY OK host_id=0

boot_svc_wm:             COMP INIT OK
                         SVC-COMP READY OK host_id=0
                         SVC-WM REGISTER OK

boot_postui_desktop:     COMP INIT OK
                         SVC-COMP READY OK host_id=0
                         SVC-WM REGISTER OK
                         PU-DT UP status_bar=OK terminal=OK

boot_compositor_full:    COMP INIT OK
                         SVC-COMP READY OK host_id=0
                         SVC-WM REGISTER OK
                         PU-DT UP status_bar=OK terminal=OK
                         COMPOSITOR E2E OK client=1 surface=1 frames=60
```

Each fixture's marker set is a strict superset of the previous one's
(the sequenced-rollout shape in the plan doc §4: SSS-01 ⊂ SSS-02 ⊂
SSS-03 ⊂ SSS-04 ⊂ SSS-05), so the goldens above compound rather than
diverge as the stack matures.

## Provenance / revisions from the original brief

Two markers were revised from the wave's original brief text to
satisfy `tools/verify-fingerprint-coverage.sh`'s "every asserted
marker contains `OK` as a whole word" gate and `run-smoke.sh`'s
literal-substring matcher (no wildcards, no inequality operators):

| Brief text | Golden (this corpus) | Why |
|---|---|---|
| `SVC-COMP READY host_id=<n>` | `SVC-COMP READY OK host_id=0` | missing `OK` token; `<n>` is a placeholder, not a literal — fixed to a concrete single-host value |
| `COMPOSITOR E2E OK client=1 surface=1 frames>=60` | `COMPOSITOR E2E OK client=1 surface=1 frames=60` | `>=` cannot be a literal substring; revised so the (future) client emits a fixed sentinel exactly once at the 60th frame instead of encoding an inequality |

## Relationship to live kernel-side fingerprints (this wave's other items)

The five markers above belong to daemons/services that do not exist
yet (`svc-compositor`, `svc-wm`, `postui-desktop`'s spawn wire — see
the plan doc §1.2 / gaps G1–G4). They are distinct from the
kernel-substrate fingerprints verified elsewhere in this Wave VVV pass
(`SEAT CREATE OK id=0 session=0` — `r113-m5-025-verify.md`;
`VBLANK TICK counter=<n>` / `SURFACE PRESENT OK` /
`FRAME CAPTURE EMIT OK` ordering — `r113-m4-021-verify.md`; ring-wrap
safety of `FRAME CAPTURE EMIT OK` — `r113-m6-frame-capture-ring-
verify.md`; `COMPOSITOR GPU OK` completion fence — `r113-m4-018-
verify.md`), which are live, reachable-in-principle kernel emitters
already on `tools/verify-fingerprint-coverage.sh`'s allowlist. Those
are asserted today via the kernel boot-witness chain; the corpus in
this doc is asserted only once the Wave SSS prerequisite gaps close
and the fixtures are un-skipped.

## Maintenance

When a Wave SSS gap (G1–G8) closes and a fixture's script is un-
skipped (removed from the `exit 77` stub state and wired into
`tools/run-smoke.sh`), update this doc's corpus entry only if the
emitted string changes from what's listed here — the goldens in
`tools/boot/compositor-smokes/expected-*.txt` remain the executable
source of truth; this file is the human-readable index over them.
