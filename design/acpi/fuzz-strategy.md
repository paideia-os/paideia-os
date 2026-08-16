# PaideiaOS — AML Fuzz Strategy

**Status:** v1.0
**Date:** 2026-08-16
**Issue:** R30.M9-001 (#1085)
**Code:** `tests/fuzz/aml/aml_fuzz.c`, `tools/verify-aml-fuzz.sh`, `tests/fuzz/aml/corpus/`

---

## 1. What is being fuzzed, and against what threat

The AML interpreter in `src/user/aml/` consumes **firmware-supplied
bytes**. The supplier is a vendor BIOS: not malicious in the usual sense,
but not trustworthy either — it is a large body of machine-generated code
that no one on this project can read, review, or fix, that differs between
machines and between BIOS revisions of the same machine, and that has
historically shipped tables which crash other operating systems.

That makes the threat model unusual. The realistic adversary is not
someone crafting an exploit; it is a **BIOS update** that emits a
construct the interpreter mishandles. The consequence is the same either
way, because the interpreter holds `KIND_OP_REGION` windows onto the
embedded controller and the LPSS buses: an interpreter that can be walked
outside its arena by a malformed table is an interpreter that can be
walked into the EC.

So the fuzzer's job is not to find crashes. It is to establish that the
**resource contract holds for every input**, including inputs no vendor
would ever emit.

---

## 2. Why the mutation is structured, and why that is the whole design

A fuzzer that flips random bytes in an AML stream produces inputs that are
overwhelmingly invalid. Such a fuzzer exercises the *reject* path
thousands of times and the *evaluate* path almost never. It measures the
tokenizer's error handling — which is real, but shallow, and already
covered by the 3542-assertion corpus in `tests/user/aml/aml_harness.c`.

The guards that matter — fuel, depth, the frame pool, the arenas — can
only be pressed by input that **survives the parser**. Every byte spent
generating an input that dies at the first opcode is a byte not spent
testing the evaluator.

Hence every mutation is chosen to keep the stream plausible. The five
operators, all driven by an actual parse of the buffer being mutated:

| # | Operator | What it targets |
|---|---|---|
| **M1** | PkgLength perturbation, re-encoded in the **same number of bytes** | declared extent vs. actual content |
| **M2** | Opcode substitution within the same **arity class**, **class**, and **encoding length** | the evaluator, not the parser |
| **M3** | NameString edits — 4-character padding, lead-char class, Dual/Multi/root/parent prefixes | namespace resolution |
| **M4** | Truncation at an **object boundary** (`aml_node_src_off`), not a random offset | incomplete-object handling |
| **M5** | Generated deep nesting straddling the depth cap | the caps themselves |

Two of these deserve their reasoning written down.

### 2.1 M1, and the direction that is actually a defect

ACPI 6.5 **§20.2.5.4** makes a package whose initialiser list is *shorter*
than its declared element count **legal** — the remainder is uninitialised,
not malformed. So "the declared extent disagrees with the content" is
**not by itself a defect**, and a fuzzer that asserted it as one would
produce a permanently red corpus that says nothing. This repository has
been corrected on exactly this point once already; the correction is
recorded here so it is not made a second time.

The sound check is the **other direction**: a PkgLength that reaches
*beyond* the enclosing extent or beyond the buffer must be refused, and
refused **without having read past the end**. Both directions are
generated; only the overrun direction carries an expectation, and that
expectation is invariant I7 (no over-read) plus *some* latched error —
never a specific error code, because several are legitimate depending on
where the overrun is noticed.

The re-encoding preserves the byte width deliberately. A PkgLength
re-encoded into a different number of bytes would shift every following
offset, which is a *truncation* wearing a disguise — and M4 already covers
truncation, better, by cutting at boundaries the parser agrees with.

### 2.2 M2, and why arity is the thing to preserve

In AML the byte following an operator is an argument or a statement
**depending solely on the operator's argument count**. A substitution that
changed the count desynchronises the stream from that point on, and every
subsequent byte becomes noise — which puts us back to fuzzing the reject
path. Matching `argc` is what keeps the parse alive past the edit so the
*evaluator* is what meets the change. Matching the encoding length (one
byte, or a `0x5B` escape plus one) keeps every later offset where the
structure map says it is.

The candidate set is drawn from the **real `aml_optab`**, not from a
hand-written list, so the mutator cannot drift away from the parser's own
notion of what an opcode is.

---

## 3. Invariants, not "did not crash"

"It did not crash" is a weak oracle. It passes for an evaluator that
silently corrupts its arena, and it passes for one whose depth guard has
been deleted. Every input is therefore checked against the resource
contract.

| # | Invariant | Why it is checkable |
|---|---|---|
| **I1** | `fuel_remaining <= budget <= 1000000`, and fuel never rises across a call | a wrap surfaces as `remaining > budget` |
| **I2** | **peak** evaluation depth `<= 48`; depth unwinds to 0 | see §3.1 |
| **I3** | **peak** frame index `<= 8`; frames unwind to 0 | see §3.1 |
| **I4** | every arena cursor inside its fixed capacity | cursors are monotonic, so they *are* the high-water marks |
| **I5** | **no torn record** — every index a node or object holds is inside the arena it refers to | see §3.2 |
| **I6** | **quiescence** — once the error latch is set, further evaluation allocates nothing | see §3.2 |
| **I7** | no read past the end of the input buffer | enforced by a `PROT_NONE` guard page, not by inspection |
| **I8** | parser depth unwinds to 0 | |

### 3.1 Why the peaks had to be added

Depth and frames both unwind to zero on every path — that is the property
the existing corpus asserts, and it is correct. It is also exactly what
makes "the cap was never exceeded" **unobservable from outside**. A host
harness calls `aml_eval_method`, sees 0 before and 0 after, and an
assertion written as `aml_eval_depth() <= 48` is asserting `0 <= 48`. It
would keep passing if the guard were deleted outright.

So `aml_eval_depth_peak()` and `aml_eval_frames_peak()` were added
(`aml_eval_state` +112 and +120, previously reserved). They are written at
the increment — *after* the cap test, so a peak can never record a depth
the guard refused — never decremented, and cleared only by
`aml_eval_reset`.

This is not bookkeeping for its own sake. The corpus shows both caps being
reached **exactly**: `c007-nest50.aml` records `peak_depth = 48` with
`eval_err = 32`, and `c005-recursive.aml` records `peak_frames = 8` with
`eval_err = 33`. Those entries also keep `aml_eval.pdx`'s documented claim
— that a self-recursive method trips **frames before depth** — under test
rather than merely asserted in a comment.

**But be precise about what the `<=` comparisons catch.** Because each
peak is recorded *after* the cap test admits the increment, the peak can
never exceed the cap the `.pdx` actually implements — so
`peak_depth <= 48` cannot fail on any input. It is a **cross-check between
two declarations of the bound**: the immediate in `aml_eval.pdx` and the
constant in `aml_fuzz.c`. Raise the former and the peak climbs past the
latter and the assertion fires (that is mutation M6, §3.4). That is a real
and wanted regression check — it is what catches a guard being loosened or
deleted — but it is not a per-input check that the evaluator stayed inside
its bound, and describing it as one would be the same vacuity this section
exists to remove, one level up.

The instrument doing per-input work on depth and frames is the **MANIFEST
exact-match**: every entry pins `peak_depth` and `peak_frames` to the value
it produced, so any drift in either is a failed replay.

The original formulation was worse in a different way: `aml_eval_depth()`
read *after* the call is always 0, so `0 <= 48` passed regardless of what
happened and would have passed with the guard deleted outright. The peaks
moved the check from "unfalsifiable and blind" to "unfalsifiable per input,
but sensitive to the bound itself moving" — which is a real gain, stated
at its actual size.

### 3.2 "No partial mutation survives an error" — stated correctly

There is **no rollback anywhere in this subsystem**, by design. The arena
cursors are monotonic within a session and nothing is ever freed. So the
literal reading — *a failed evaluation leaves nothing behind* — is false
here, and asserting it would produce a red corpus that teaches nothing.

It is also the wrong thing to want. ACPI methods have real side effects. A
`Store` that completed before a later fault **genuinely completed**;
unwinding it would be a lie told to firmware, and firmware would go on
believing the write happened because, at the hardware, it did.

The property that must hold is narrower and sharper, and splits in two:

- **I5 — no torn record.** A committed side effect is legitimate. A
  *half-constructed object reachable from the arena* is not: a node whose
  `first_child` names an index that was never allocated because the error
  unwound first is a dangling index, and dangling indices in a structure
  fed by firmware are a memory-safety bug. The sweep examines every
  allocated node and object after **every** input, error or not.

- **I6 — quiescence.** Once the error latch is set, further evaluation
  must allocate **nothing**. `aml_eval_spend` refuses on a latched error
  without consuming fuel, and every node, statement and `While` iteration
  passes through it; I6 is the assertion that this check has no hole. A
  post-error allocation would mean some path reaches the arena without
  passing the gate.

Together these are what "no half-written object survives" can honestly
mean in a subsystem that deliberately has no transactions.

**I6 needed a fixture built for it.** The invariant compares arena
cursors across method boundaries *after* the latch closes, so it can only
observe anything on an input with at least two methods where an early one
fails — and every original seed declared exactly one. The `twometh` seed
exists for this: `MBAD` divides by zero at **evaluation** time (a parse
failure would stop the session before any method ran, leaving no "after
the latch" to observe), and `MGD0` returns a **Package**.

The Package is not arbitrary. An arithmetic body allocates no object
records, so I6's comparison would hold trivially whether the gate worked
or not. A Package allocates an object record *and* element slots, so if
the gate ever stopped blocking, the cursors move and I6 says so. This was
established by mutation, not by inspection — see §3.4.

### 3.4 Mutation results — every new guardrail was made to fail

Each invariant added here was verified non-vacuous by breaking the thing
it guards and confirming the exact assertion that fires.

| Mutation | Fires |
|---|---|
| **M5** — peak depth never recorded | `peak_depth = 0, expected 3` on 5+ entries |
| **M6** — depth cap raised 48 → 480 | **`peak evaluation depth = 53 exceeds bound 48`** (I2) |
| **M7** — `aml_eval_spend` no longer refuses on a latched error | **`post-error object arena is quiescent = 3, expected 1`** and `post-error element table is quiescent = 5, expected 1` (I6) |

**M6 is the one that justifies the peaks existing at all.** Raising the
depth cap by a factor of ten is a guard that has stopped guarding, and
under the old post-unwind formulation (`aml_eval_depth() <= 48`, read
after the call, always 0) it would have passed silently. With the peak it
fails on the first corpus entry that nests.

M7 is the one that justifies `twometh`: before that seed existed, M7 was
caught only indirectly, by cost-vector drift on unrelated entries. I6
itself did not fire, because no fixture gave it anything to compare.

**A procedural hazard worth recording, because it nearly produced a false
finding.** Mutation testing edits a `.pdx`, rebuilds, observes the
failure, and restores the *source* — which leaves a **mutant object tree**
on disk. A soak launched afterwards against `build/aml-fuzz/aml_fuzz`
directly, rather than through `tools/verify-aml-fuzz.sh`, runs the
mutant. During this work that produced **479 corpus entries all reporting
I6 quiescence violations**, which read exactly like a real and serious
defect: allocation continuing after the error latch closed.

It was not. Disassembling the object showed `aml_eval_spend`'s
`call aml_eval_err / cmp / jne` missing from `build/` while present in
`src/` — the M7 mutant, never rebuilt away. A clean rebuild restored the
check and the trips vanished.

The lesson is not "be careful". It is that **a fuzzer's findings are only
as trustworthy as the provenance of the binary that produced them**, and
that a plausible-looking mass of failures deserves a disassembly before it
deserves a bug report. `tools/verify-aml-fuzz.sh` rebuilds every module on
entry for this reason, and its header now says so.

---

## 4. The corpus, and what makes an entry permanent

An input is promoted to a permanent corpus entry when it:

1. **trips an invariant** — always, unconditionally; or
2. **reaches an outcome signature** — the `(parse_err, eval_err)` pair —
   that no existing entry reaches.

Seeds are promoted **unconditionally**, exempt from the signature filter.
Several of them share the signature `(0, 0)` — *evaluated cleanly* — which
is precisely the signature a coverage filter discards; filtering them
would silently produce a corpus made entirely of failures, with no
well-formed fixture left to notice a regression in the success path.

Each entry records its full outcome vector in `MANIFEST.tsv`:

```
name  parse_err  eval_err  peak_depth  peak_frames  fuel_spent  nodes  objs  budget
```

Replay asserts **every field exactly**. That is what makes an entry a
regression test forever: a change that alters any field fails the gate and
has to be explained rather than absorbed.

The three cost columns are simultaneously the recorded performance
baseline that R30.M9-003 (#1087) gates on — see
`design/acpi/perf-methodology.md`.

### 4.1 Replay is the gate; soak is not

A gate must be deterministic. A soak promotes entries, which would leave
the working tree dirty on a plain `git push`; and a soak seeded from the
clock would make the verdict depend on when it ran. Replay has neither
property: same corpus, same verdict, always.

`tools/verify-aml-fuzz.sh` therefore runs **replay** as the gate, plus a
short fixed-seed soak against a **scratch copy** of the corpus so that
promotion cannot dirty the tree. The short soak exists to keep the
*mutators themselves* under test: a mutator that silently stopped
producing parseable output would otherwise never be noticed, and the
fuzzer would degrade into a no-op while still reporting PASS.

---

## 5. Reproducibility

The PRNG is splitmix64, seeded from the command line. A soak that finds
something is reproducible from its seed alone:

```
tools/verify-aml-fuzz.sh soak <iters> <seed>
```

The tripping input is written into the corpus directory at the moment it
trips, before the run continues, so a long soak that later wedges still
leaves its finding on disk.

---

## 6. Seeding — what this corpus is NOT

The issue asks for a corpus **seeded from T14 G4**. This corpus is seeded
from **synthetic, structurally-valid fixtures built by `aml_fuzz.c`**, and
no entry in it is a hardware capture.

Real-table seeding is **#1088**, which requires physical access to the
target laptop across three BIOS revisions. That is not available in this
environment and the gap is not papered over: a synthetic fixture labelled
as a captured DSDT would poison every downstream test that trusted it.
See the assessment on #1088.

The consequence is a real and named limitation. Synthetic seeds cover the
constructs *we thought to write*. Vendor AML contains constructs nobody on
this project would think to write — that is the entire reason ACPICA
carries 25 years of quirk workarounds. Until #1088 lands, this fuzzer's
reach is bounded by the imagination of the seed set, and the honest claim
is "the resource contract holds across tens of millions of structured
mutations of eight synthetic seeds", not "the interpreter handles real
firmware".

---

## 7. What a clean 24-hour run would and would not prove

The issue requires "≥ 24 h clean run for green". At the measured rate
(~39 000 iterations/second) that is on the order of 3×10⁹ inputs.

**It would prove:** the resource contract held across that many structured
mutations of this seed set.

**It would not prove:** that the interpreter is correct. The invariants are
about *bounds*, not about *results* — an evaluator that returned the wrong
integer for every `Add` would pass all eight. Result correctness is the
3542-assertion corpus's job; the two are complementary and neither
substitutes for the other.

**It would also not prove** anything about inputs the mutators cannot
reach. Coverage here is structural, not measured: there is no
instrumentation counting which branches of `aml_eval.pdx` were executed.
Adding coverage feedback would make the search markedly better and is the
obvious next increment.

---

## 8. Status

- Corpus committed under `tests/fuzz/aml/corpus/` with recorded outcomes.
- `tools/verify-aml-fuzz.sh` wired into `.githooks/pre-push`.
- Both evaluator caps witnessed at their exact value by dedicated entries.
- **The 24-hour run has not been performed.** The soak actually run for
  this issue is recorded in the commit message; anything longer is an
  operator action, not a build-time gate.
