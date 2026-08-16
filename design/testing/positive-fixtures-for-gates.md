# R31.M2-1601 — a guard that cannot prove it still checks anything

Issue: #1601. Companion to `design/testing/fingerprint-coverage.md`.

## 1. The specific defect

`tools/verify-user-image-extent.sh` rule 3 lints `src/user/*.ld` for a
location-counter jump between two output sections that share one program
header. It had two working vacuity guards — `no-output-sections-parsed` and
`no-section-carries-a-phdr` — and neither of them caught the failure that
actually happened.

Re-introduce the exact bug rule 3 shipped with in #1595 — anchor the
DOT-statement regex against the whole accumulated buffer rather than its last
line — and the gate emits `LINT-DONE 8 scripts`, no `HOLE` line, exit 0. It
passes a script with a genuinely restored hole.

The vacuity guards do not fire because nothing is *empty*. Every script still
parses, every output section still carries its `:phdr`, and the extractor
still finds one location-counter statement per file: the first, at the top of
`SECTIONS`. The match merely stops happening where it matters. A
presence-based guard cannot see that.

## 2. Why rule 3 specifically

The ELF-level rules (1 and 2) cannot cover for it. With `.data` empty, `ld`
drops the zero-size section, and the resulting program header shows no hole
at all — `init.elf: 2/16 pages OK`. The defect is **latent in the binary and
visible only in the script**. Rule 3 reading the script source is the only
protection against that form, it shipped broken once, and it was caught by a
mutation test rather than by any guard.

## 3. The fix: a positive self-test

A checked-in known-bad fixture that the rule **must** flag on every run.

- Fixture: `tests/linker/fixtures/rule3/intra-segment-hole.ld`. Follows the
  existing `tests/<area>/fixtures/<tag>/` convention. It is not a build
  input: `tools/build-user.sh` names every link script explicitly and there
  is no `*.ld` glob in the build path.
- The fixture is *discriminating*, not merely dirty. It carries two location
  jumps: one crossing `text` → `data` (legal, must NOT be flagged) and one
  between two `:data` sections (the defect, must be flagged). So it also
  proves the rule is not degenerating to "any dot statement is a hole".
- Real scripts and fixtures go through the **same** `scan()`/`holes()`
  functions. That is what makes the self-test load-bearing rather than a
  parallel implementation that can drift.

Plus a counted floor, `RULE3_MIN_DOT_STATEMENTS = 16`, because whole-buffer
anchoring changes the match *count* (8 real scripts × 1 spurious match = 8,
against a true 16). Two independent detections of one regression.

### New tags

| Tag | Fires when |
| --- | --- |
| `rule3-selftest-no-fixtures` | fixture dir missing, or no `*.ld` in it |
| `rule3-selftest-fixture-unparsable` | fixture hit a per-script vacuity guard instead of being analysed |
| `rule3-selftest-fixture-not-flagged` | fixture parsed but produced no HOLE — the extractor regression |
| `rule3-dot-statement-floor` | fewer depth-1 `. =` statements than the pinned minimum |
| `rule3-dot-count-missing` | the counter itself did not report |

All five were mutation-confirmed to fire. The failure dispatch was changed
from an `elif` chain to independent `if` blocks so a real HOLE and a
self-test failure are both reported rather than one masking the other.

### Mutation results

| mutation | result |
| --- | --- |
| `stmt = buf.rsplit("\n",1)[-1]` → `stmt = buf` (the original bug) | FAIL, exit 1: `rule3-selftest-fixture-not-flagged` **and** `rule3-dot-statement-floor` (extracted 8, floor 16) |
| fixture file deleted / fixture dir removed | FAIL, exit 1: `rule3-selftest-no-fixtures` |
| fixture *repaired* (hole removed) | FAIL, exit 1: `rule3-selftest-fixture-not-flagged` |
| floor raised to 17 | FAIL, exit 1: `rule3-dot-statement-floor` |
| fixture stripped of `SECTIONS` | FAIL, exit 1: `rule3-selftest-fixture-unparsable` |

Known maintenance edge: `RULE3_MIN_DOT_STATEMENTS` is pinned at the exact
current count, not below it, so legitimately deleting a `. =` from a real
script fails the gate and requires a deliberate re-pin. That tightness is
intended.

## 4. The class, named

#1601 is the fifth instance this loop has produced of one defect class:

| issue | shape |
| --- | --- |
| #1577 | a guardrail that intermittently stopped checking |
| #1578 | fingerprints asserted nowhere |
| #1585 | a verifier no path ever invoked |
| #1592 | a defence deletable with no test failing |
| #1601 | a rule silently vacuous while reporting success |

The mechanisms differ. The shared property is exact and worth stating in one
sentence:

> **The guard's own liveness was never asserted. Every one of these five
> passes just as happily when it is checking nothing.**

A shared vacuity-floor helper — the obvious response — would address only
the subclass where a count can reach zero. It would not have caught #1585 (a
verifier that is never invoked has no count to floor) or #1592 (a defence
whose deletion breaks nothing). The generalisation that covers all five is a
**meta-check over the gates themselves**, asserting for every
`tools/verify-*.sh` that:

1. it is **reachable** — invoked from `tools/build.sh`, `.githooks/pre-push`
   or `tools/run-smoke.sh` (closes #1585's form);
2. it declares **at least one positive fixture** it must flag, and running it
   against that fixture fails (closes #1592's and #1601's form — a defence
   with a positive fixture cannot be deleted or hollowed out silently).

The cheap version is a header declaration (`# SELFTEST-FIXTURE: <path>`) plus
a `--selftest` mode per gate, and an enumerator that refuses any gate lacking
either. The recursion terminates: the meta-check's own positive fixture is a
deliberately-unreachable dummy verify script it must reject.

Retrofitting ~18 existing gates is the expensive part, which is why this is
recorded here as **worth its own issue** rather than built speculatively
inside #1601.
