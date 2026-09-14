# Compositor unit-test cascade (Wave KKK matrix)

**Status:** DESIGN + first five landed. This doc records the state of
`tests/kernel/compositor/*.pdx` as of Wave KKK, the structural gap that
applies to every file in that directory (mine and every sibling wave's),
and a proposed 60-issue cascade to reach full coverage of
`src/user/compositor/`'s 35 modules.

---

## 1. Structural finding: this whole directory does not link yet

`tools/build.sh` globs `tests/kernel/**/*.pdx` (excluding
`drivers/elaborator/`) and links every resulting object into
**`kernel.elf`** (§"R18-M5-004 (#778)" in `tools/build.sh`). But every
symbol these compositor witnesses call — `lt_row_alloc`,
`damage_region_bbox_x`, `buffer_age_push`, `selection_owner_replace`,
`present_feedback_mint`, ... — is defined in `src/user/compositor/*.pdx`,
which `tools/build-user.sh` compiles as **standalone objects excluded
from every linked user binary** (the `#2344` branch: "Objects still
compile ... but do not link into any binary until their owning image
scaffold lands"). Kernel-side `KERNEL_SRC` (`src/kernel/`) never
includes `src/user/compositor/` either.

Net: a full `tools/build.sh` run will very likely fail `kernel.elf`'s
final link with undefined references to every compositor symbol these
witnesses name, for **all 20 files** currently under
`tests/kernel/compositor/` (5 pre-existing before Wave KKK, 10 landed by
concurrent sibling waves during this same session, 5 landed by this
wave) — not a defect introduced by Wave KKK specifically, but a
pre-existing, wave-wide gap this survey makes explicit for the first
time. `design/testing/compositor-qemu-smoke-plan.md` §1.2 independently
confirms the underlying fact: "`src/user/compositor/*.pdx` ... Library/
data-model modules ... **No entry point**."

**This needs one of, before the next full build is trusted:**

1. A dedicated compositor unit-test harness — a small standalone
   linked image (its own `_start`, no daemon) that pulls in
   `src/user/compositor/*.o` + `tests/kernel/compositor/*.o` and is
   built/run outside the `kernel.elf` link, mirroring how `libaml.a` is
   built-but-not-linked until `acpi_supervisor` exists
   (`tools/build-user.sh` comment on the `aml/*` branch).
2. OR an explicit exclusion of `tests/kernel/compositor/` from
   `tools/build.sh`'s `TESTS_KERNEL_DIR` sweep (object compiles for
   "does it encode" verification, as this wave did via direct
   `paideia-as build --emit elf64` invocations, but is never added to
   kernel.elf's `OBJECTS` array) until (1) exists.
3. OR promote the whole compositor library into `src/kernel/` (a much
   bigger architectural move that contradicts the ring-3/ring-0
   separation `design/compositor/pwp-spec-vocabulary.md` assumes).

(1) is the only option that does not either silently disable this
entire test class or violate the ring boundary. **Filed as a follow-up
issue: a `tools/build-compositor-tests.sh` (or equivalent) standalone
link target.** Until it lands, every file in this directory compiles
individually (`paideia-as build --emit elf64 <file> -o <obj>`) but
proves nothing beyond "this file's own syntax and register discipline
are correct" — cross-module linkage against the real
`src/user/compositor/*.pdx` bodies is unverified.

**Compiler note (orthogonal, but a real trap):** `paideia-as` is also
installed at `~/.cargo/bin/paideia-as` (v0.9.0, stale) and shadows the
project's real compiler
(`tools/find-paideia-as.sh` → `tools/paideia-as/target/release/paideia-as`,
v0.36.1 at this landing) on `$PATH`. The stale binary fails to parse
`module X = structure { ... }` at all (`P0100: expected item`) and
cascades into dozens of spurious `U160x` errors on every subsequent
line — it looks exactly like a broken test file. Always resolve via
`tools/find-paideia-as.sh` before invoking `paideia-as` directly outside
`tools/build.sh`.

---

## 2. Wave KKK: five landed (COMP-UT-01..05)

| ID | File | Real API exercised | Stub? |
|---|---|---|---|
| COMP-UT-01 | `test_layer_tree.pdx` | `lt_row_alloc`, `lt_pack_hdr_row`, `lt_pack_arena_ref`, `lt_arena_base` (mint-adjacent surface); arena header/node layout | YES — `tlt_attach`/`tlt_detach`/`tlt_get_at`/`tlt_count`. `layer_tree.pdx` exports no mutation op at all (Section 6: query-only) and has no mint body yet. |
| COMP-UT-02 | `test_damage_aggregate.pdx` | `damage_aggregate_from_tree` (the real fold+mint), `damage_region_bbox_x/y/w/h` | NO — the brief's `damage_aggregate_flush()` doesn't exist, but the real `damage_aggregate_from_tree` is a strictly better match and is exercised directly; only the tree's arena is hand-stamped (same layer_tree.pdx mint gap as COMP-UT-01). |
| COMP-UT-03 | `test_damage_kind.pdx` | none | YES, fully local. `damage_kind.pdx` is a rect-list cap (`KIND_DAMAGE_REGION`); a MOVE/RESIZE/CONTENT event-dispatch concept does not exist anywhere in the compositor tree. Exercises nothing shipping. |
| COMP-UT-04 | `test_clipboard.pdx` | none | YES, fully local, and a **design conflict**, not just a gap: the brief's seat-keyed ambient owner registry is exactly the X11 shape `clipboard.pdx`'s own Section 0 states it refuses to reproduce. Recommend retiring this test in favor of COMP-UT-05. |
| COMP-UT-05 | `test_selection_owner.pdx` | `selection_owner_replace`, `selection_owner_query` (both real rows, kind 0 and 1) | Partial — kinds 0/1 are 100% real; "seat 2" is a WEAK single-cell stub because `SO_KIND_MAX=2` is sealed by the module's own stated design (Section 2). |

All five compile clean under the correct `paideia-as` (0.36.1); none
have been through the standalone-link harness in §1 because it does not
exist yet.

---

## 3. Cascade to 60: remaining modules

35 modules live in `src/user/compositor/`. 20 now have at least one
`tests/kernel/compositor/test_*.pdx` (5 pre-Wave-KKK, 10 landed by
concurrent sibling waves during this session, 5 this wave — see the
directory listing at landing time). 15 have none:

`surface_buffer_bind`, `surface_commit`, `surface_geometry`,
`surface_kind`, `tiling_bsp`, `tiling_floating`, `tiling_gaps`,
`window_geometry`, `window_kind`, `workspace_kind`, `workspace_session`,
`workspace_switch`, `xdg_shell_geometry`, `xdg_shell_popup`,
`xdg_shell_states`.

Proposed cascade: **two** unit tests per uncovered module (one
functional round-trip through the module's real mint/query surface,
one boundary/negative — refusal taxonomy, sealed-enum edges, or
row-pool exhaustion) = 30 issues, plus a **second pass** of the same
shape over the 20 already-covered modules to add the negative/boundary
half where the landed test is functional-only (spot check: COMP-UT-02
above has no negative-path test at all) = up to 30 more. Total ceiling
60, trimmed at execution time to whichever half of each pair a
module's real refusal taxonomy actually supports (a module with no
distinct failure sentinels, e.g. a pure packer, does not get a
manufactured negative test just to hit a quota).

| Batch | Modules | Test shape |
|---|---|---|
| A (surface family, 4 modules) | surface_kind, surface_geometry, surface_commit, surface_buffer_bind | functional mint/geometry round-trip + refusal taxonomy (bad parent kind, bad rights subset — every module in this tree shares that gate shape) |
| B (window/workspace family, 5 modules) | window_kind, window_geometry, workspace_kind, workspace_session, workspace_switch | functional mint + z-order/session-slot round-trip; boundary at row-pool MAX |
| C (tiling family, 3 modules) | tiling_bsp, tiling_floating, tiling_gaps | functional split/insert round-trip; boundary (gap at 0, split past MAX depth) |
| D (xdg_shell family, 3 modules) | xdg_shell_geometry, xdg_shell_popup, xdg_shell_states | functional state-machine transition round-trip; illegal-transition refusal |
| E (second pass, 20 already-covered modules) | all of §2's table plus the 15 sibling-wave files | add the negative/boundary half wherever the landed test is functional-only |

Each batch's dispatch must repeat this wave's two lessons: (1) read the
real module before naming a test's calls — several of this wave's five
briefs named APIs that do not exist, and the honest response was a GAP
NOTE + closest-real-primitive substitution (COMP-UT-02) or an explicit
WEAK stub with a design-conflict callout (COMP-UT-04), never a silent
rename; (2) resolve `paideia-as` via `tools/find-paideia-as.sh`, never
bare `$PATH`, before trusting a compile result.

**Do not start Batch A-E execution until §1's standalone-link harness
exists** — the reasoning that makes GAP NOTEs credible ("this exercises
the real shipping call") is worthless if nothing in the repo ever
actually links and runs that call.
