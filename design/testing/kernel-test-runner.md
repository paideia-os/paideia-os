# Kernel-linked test-harness pattern (Wave π / π-03)

**Status:** DESIGN + one reference implementation. The pattern below is
fully realized by the compositor test runner (`tools/build.sh
--compositor-tests`, see `design/testing/compositor-test-runner.md`
for that concrete instance) and partially realized by the pre-existing
`tests/kernel/postui-desktop/*.pdx` witnesses (§4 records the gap).

**Scope:** the general shape any future `tests/kernel/<subsystem>/`
battery should follow to get a linked, QEMU-bootable test-runner ELF
with a grep-able summary fingerprint, without inventing a new pattern
per subsystem.

---

## 1. Why a pattern doc, not just the compositor implementation

This monorepo already has two independent test-witness lineages under
`tests/kernel/`:

* **compositor** (20 files at Wave π) — each exports a single
  `pub let test_<subsystem>_run : () -> u64`, pure-compute
  (`!{mem} @{}` or `!{} @{}`, no syscalls), designed from the start to
  be link-included alongside the library it exercises
  (`src/user/compositor/*.pdx`) and run to completion inside one
  process with no kernel cooperation beyond `sys_write` for the
  summary.
* **postui-desktop** (5 files) — each exports its own witness name
  (`test_desktop_init_witness`, etc.), performs real syscalls
  (`!{mem, sysreg} @{cap, sched}`), and was written as a kernel-side
  witness in the R113/postui-desktop lineage rather than against this
  pattern.

Without a written-down target shape, a THIRD subsystem's test battery
would either copy compositor's shape, copy postui-desktop's shape, or
invent a fourth — and the next `tools/run-qemu-tests.sh`-style
consumer would need bespoke logic per subsystem forever. This doc
freezes the target shape; §4 tracks which existing batteries already
conform.

---

## 2. The pattern

### (a) Test files live under `tests/kernel/<subsystem>/`

One `.pdx` file per behavior under test, named `test_<behavior>.pdx`.
Each file is a self-contained `module` that may declare its own WEAK
stub helpers when the library under test does not yet export a real
mutation primitive (see `tests/kernel/compositor/test_layer_tree.pdx`'s
GAP NOTE for the canonical example of this — stubs are named with a
distinct prefix from the witness itself, and the file header records
what real primitive would retire the stub).

### (b) Each file exports exactly one `_run()` entry point

Signature: `pub let test_<behavior>_run : () -> u64 !{mem} @{}` (widen
the effect/capability row only if the behavior under test genuinely
needs `sysreg`/`cap`/`sched` — most library-level unit witnesses do
not). Return convention:

* `0` — every stage passed.
* `N` (`N >= 1`) — the 1-based ordinal of the first stage that failed.
  Stage numbering is per-file (the runner does not interpret stage
  meaning, only whether the result is zero).

This is a **pure function call**, not a process: the runner calls it
directly (`call test_<behavior>_run`) and reads the return value in
`rax`. No forking, no IPC, no scheduler involvement — the whole battery
runs inside one ring-3 process's straight-line control flow.

### (c) A subsystem-specific runner ELF collects results

One `tests/kernel/<subsystem>/test_harness/main.pdx` per subsystem,
providing:

* a common `_start` that calls every `test_*_run` in the directory, in
  a flat explicit sequence (`call test_X_run` immediately followed by
  a tally/emit helper — see `compositor-test-runner.md` §3 for the
  exact shape);
* two tally counters (`_th_pass` / `_th_fail` or equivalent);
* a summary line on fd 2 of the shape `"<SUBSYSTEM> TESTS: N passed /
  M failed\n"`;
* `sys_exit(fail_count)` — zero iff every witness passed, so a shell
  or CI wrapper can gate on the process exit code alone without
  parsing the summary line.

The runner links against **the library under test** (e.g.
`src/user/compositor/*.pdx`) so a real cross-object `call` proves
genuine linkage into that library's own object code, not a fabricated
always-true check — the same principle
`src/user/compositor/selftest.pdx`'s own header already states for its
one-function boot-smoke sibling.

**Naming collision hazard (learned the hard way at Wave π):** `pub let
NAME : T = <literal>` compiles to a real global ELF symbol regardless
of whether `T` is a function or a scalar constant (`paideia-as`'s
`pub` keyword marks `STB_GLOBAL`, plain `let` marks `STB_LOCAL` — see
`tools/paideia-as/crates/paideia-as/tests/codegen/
pub_cross_module_link.rs`). A subsystem's library files that were
never before linked together can carry duplicate `pub let` scalar
constants (harmless as long as nothing links two of them into one
object) that surface as multiple-definition errors the FIRST time a
test harness tries to link the whole library. `design/testing/
compositor-test-runner.md` §2 documents the concrete instance (13
names across 5 files); grep the target library's `pub let` names for
duplicates (`grep -hoE '^\s*pub let(\s+mut)?\s+[A-Za-z_][A-Za-z0-9_]*'`
over every file about to enter one link unit, `sort | uniq -c`) before
wiring a new subsystem's runner, not after the link fails.

### (d) `run-qemu.sh` boots the runner and greps fingerprints

`tools/run-qemu-tests.sh` (Wave π / π-04) is the thin wrapper: it does
not reimplement QEMU invocation, it calls `tools/run-qemu.sh` per
runner ELF and greps the resulting serial log for that runner's
summary-line prefix, reporting per-suite pass/fail and exiting
non-zero on any failure or any missing/unbuilt runner ELF. See that
script's own header for the exact contract.

---

## 3. Non-goals

* This pattern is for **library-level unit witnesses** with no
  meaningful cross-process or cross-task behavior — a runner is one
  ring-3 process making straight-line function calls. A witness that
  needs two cooperating processes (like `echo_client.pdx` /
  `echo_server.pdx`) is a different shape entirely (a boot-smoke
  fixture under `tools/boot/`, not a `tests/kernel/<subsystem>/test_
  harness/`) and out of scope here.
* No claim that every existing `tests/kernel/**` witness must be
  migrated to this shape immediately — §4 tracks the gap honestly
  rather than silently asserting conformance.

---

## 4. Conformance tracker

| Subsystem | Witness count | `_run()` naming | Effects | Runner ELF | Status |
|---|---|---|---|---|---|
| `compositor` | 20 | `test_<name>_run` (uniform) | `!{mem}@{}` / `!{}@{}` | `tests/kernel/compositor/test_harness/main.pdx` → `build/tests/compositor-runner.elf` | **Conforms** (Wave π π-01/π-02, reference implementation) |
| `postui-desktop` | 5 | per-file bespoke (`test_desktop_init_witness`, etc.) | `!{mem, sysreg}@{cap, sched}` (real syscalls) | none | **Gap.** Pre-dates this doc; needs a naming pass (`_run()` uniform entry point) and a decision on whether real-syscall witnesses can share a single ring-3 process safely (a failed `sys_*` call in witness N must not corrupt state for witness N+1) before a `test_harness/main.pdx` can be written for it. Tracked as follow-up, not blocking this wave. |

A new subsystem's test battery should target the `compositor` row's
shape from its first file, not the `postui-desktop` row's.
