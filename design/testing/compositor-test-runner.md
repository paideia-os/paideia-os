# Compositor kernel-test-runner ELF (Wave π / π-02)

**Status:** LANDED. `tools/build.sh --compositor-tests` builds
`build/tests/compositor-runner.elf`; `tools/run-qemu-tests.sh
--compositor` boots it and checks the summary fingerprint. Not yet
wired into the default `tools/build.sh` / `tools/run-smoke.sh` flows
(opt-in flag only) — see §5.

**Co-located with:** `design/testing/kernel-test-runner.md` (the
general pattern this instance implements) and `design/testing/
compositor-qemu-smoke-plan.md` (the separate α-track compositor
boot-smoke design — see §5 for how the two relate). This file
**supersedes the Wave α-02 draft** that previously occupied this exact
path (docs-only, proposed the flag without implementing it) — §6
below reconciles what that draft proposed against what actually
landed, rather than silently discarding it.

---

## 1. What this is, and what it is not

This is a **unit-test harness**, not a boot-smoke fixture. It calls 20
pure-compute witness functions (`tests/kernel/compositor/test_*.pdx`)
against the compositor's library modules
(`src/user/compositor/*.pdx`) inside one ring-3 process, with no
scheduler, no IPC, no capability-system involvement, and no dependency
on any daemon (`svc-compositor` / `svc-wm`, both still zero-source per
`compositor-qemu-smoke-plan.md` §1.2). It answers "does the compositor
library's arena arithmetic / bitmask logic / state-machine code still
do what its own unit witness expects", not "does a compositor process
boot and composite a frame" (that is COMP-QM-01..05 in the sibling
smoke-plan doc, still gated on G1-G8 there).

## 2. Build

```
bash tools/build.sh --compositor-tests
```

produces `build/tests/compositor-runner.elf` by:

1. Compiling every `src/user/compositor/*.pdx` file **except
   `selftest.pdx`** (paideia-as, `--emit elf64`, one object per file).
   `selftest.pdx` is excluded because it declares its own `pub let
   _start`, competing with this harness's own `_start`
   (`test_harness/main.pdx`) — see §2.1 for why linking it in at all
   would be a mistake even setting the `_start` collision aside.
2. Compiling every `tests/kernel/compositor/test_*.pdx` witness (20 at
   landing).
3. Compiling `tests/kernel/compositor/test_harness/main.pdx`, the
   runner's own entry point.
4. Linking all of the above with `ld -T tests/kernel/compositor/
   test_harness/test.ld` (a dedicated linker script, byte-identical in
   shape to `src/user/link.ld` — same two-`PT_LOAD` layout at
   `0x00400000`/`0x00600000` every other user ELF in this tree uses).

### 2.1 A prerequisite fix this landing needed

Before this landing, no build ever linked more than TWO of the 36
`src/user/compositor/*.pdx` files into one object
(`compositor_selftest.elf` links `selftest.o` + `buffer_age.o` only —
`tools/build-user.sh`'s own comment explains this was deliberate, to
avoid ballooning `shell.elf` past its tmpfs size cap when an earlier
attempt pulled in the whole directory). Nothing had ever exercised
linking the *whole* library together.

Doing so surfaced a latent defect: three files
(`window_geometry.pdx`, `xdg_shell_geometry.pdx`,
`xdg_shell_states.pdx`) independently declare an identical,
deliberately byte-stable `RESIZE_EDGE_*` bitmask table (11 constants)
as `pub let`, and two more (`recovery_plane_reserve.pdx`,
`recovery_plane_takeover.pdx`) independently declare identical
`KIND_RECOVERY_PLANE` / `RESERVATION_HOLDER_KIND` constants the same
way. In `paideia-as`, `pub let NAME : u64 = <literal>` is not a
macro-style compile-time-only constant — it lowers to a real `Rodata`
ELF symbol, `STB_GLOBAL` because of the `pub` keyword (see
`tools/paideia-as/crates/paideia-as/tests/codegen/
pub_cross_module_link.rs`). Five files' worth of duplicate global
symbols is a multiple-definition link error the instant two of them
share a link unit — which had simply never happened until this file's
own build path tried to link all five together.

The fix, landed alongside this doc: demote the 13 duplicate names from
`pub let` to file-local `let` in all five files. This is safe because
every use site in the whole tree hardcodes the literal value directly
(`mov r11, 0x1D0; // RESERVATION_HOLDER_KIND`, not `mov r11,
RESERVATION_HOLDER_KIND`) — grep-verified zero symbol-name references
anywhere, including within the declaring file itself. The `pub`
declarations exist purely as named documentation of the contract (and,
for the `RESIZE_EDGE_*` table, an explicit "byte-stable across these
three files" cross-reference in each file's own header) — dropping
`pub` changes no emitted code, only symbol visibility. Each edited
file carries an inline comment recording this at the affected
declaration.

Any future subsystem's first-ever whole-library link should expect the
same class of surprise; `kernel-test-runner.md` §2(c) generalizes the
lesson (grep for duplicate `pub let` names before wiring the harness,
not after the link fails).

## 3. The runner's own shape (`test_harness/main.pdx`)

Twenty `call test_<name>_run` sites in `_start`, each immediately
followed by `call th_record(name_buf, name_len, result)` — a helper
that:

* tallies the result into one of two `.bss` counters (`_th_pass` /
  `_th_fail`, load-inc-store, no `add reg,[mem]`);
* emits one diagnostic line to fd 2 per witness: `"<name> PASS\n"` or
  `"<name> FAIL stage=<N>\n"`.

After all 20, `_start` emits the summary fingerprint and exits:

```
COMPOSITOR TESTS: <pass> passed / <fail> failed
```

on fd 2, then `sys_exit(fail_count)` (zero iff every witness passed).
`fd 2` is used because `src/kernel/core/syscall/dispatch.pdx`
documents "ID 1 (write) uses fast-path for fd∈{1,2}→UART" — fd 2
reaches the same serial wire as fd 1 under the default `-kernel` boot,
with no fd-table setup, no `_init_caps` sidecar, and no tmpfs
dependency (this ELF is self-contained, inlining `sys_write`/`sys_exit`
directly, matching `true.pdx`/`child_hello.pdx`/`selftest.pdx`
discipline).

The summary line deliberately carries no `OK` token. `tools/
verify-fingerprint-coverage.sh` only requires assertable-golden
coverage for markers containing the whole word `OK` (`design/testing/
fingerprint-coverage.md` §2); this line's counts are runtime-computed,
so no golden could pin it as an ordered substring regardless. Its
consumer is `tools/run-qemu-tests.sh` (§4 below), which greps the
fixed prefix `"COMPOSITOR TESTS: "` directly rather than going through
the coverage-gate machinery built for static fingerprints.

## 4. Consumption

`tools/run-qemu-tests.sh --compositor` (Wave π / π-04) boots
`build/tests/compositor-runner.elf` via `tools/run-qemu.sh`, greps the
serial log for `"COMPOSITOR TESTS: "`, parses the pass/fail counts, and
reports success iff `failed == 0`. See that script's own header for
the full contract, including how it also drives the (not-yet-built)
`postui-desktop` runner.

Not wired into `tools/run-smoke.sh`'s default matrix, and not invoked
by `tools/build.sh` without the explicit `--compositor-tests` flag —
same opt-in posture `compositor-qemu-smoke-plan.md` used for its own
stub fixtures, until this harness has run clean in QEMU at least once
(main builds/boots; this doc's authoring pass did not run QEMU per
this wave's no-background-builds discipline).

## 5. Relationship to `compositor-qemu-smoke-plan.md`

That doc's COMP-QM-01..05 fixtures are **boot-smoke** fixtures — full
QEMU boots that would (once G1-G8 close) prove a compositor daemon
composites frames end-to-end. This doc's runner is a **unit-test**
fixture that proves the compositor's own library code is internally
correct, entirely independent of whether any daemon (`svc-compositor`,
`svc-wm`, `postui-desktop`) ever spawns. The two are complementary, not
competing: COMP-QM-01 could plausibly boot THIS runner as its "module
self-checks" content once G5 (an init-time gate) lands, but that wiring
is not attempted here — this landing's runner is invoked only via the
opt-in `tools/run-qemu-tests.sh` path, not the default boot sequence
COMP-QM-01 would need to hook into.

## 6. Reconciliation with the Wave α-02 draft this file supersedes

The α-02 draft that previously lived at this path correctly identified
the core problem (`tests/kernel/compositor/*.pdx` witnesses have no
link path to the real `src/user/compositor/*.pdx` functions they claim
to test, so `test_layer_tree.pdx` and its siblings ship local WEAK-stub
reimplementations of byte layouts instead) and correctly proposed the
shape of the fix (a new opt-in `tools/build.sh --compositor-tests` flag
producing a standalone ELF via a dedicated linker script). Three things
changed between that proposal and what actually landed:

* **ELF name/path:** the draft guessed `build/tests/compositor_tests.elf`
  (underscore); this landing uses `build/tests/compositor-runner.elf`
  (hyphen), matching this wave's brief.
* **The "cross-ABI link" concern (draft §2 item 3) did not materialize.**
  The draft worried that `tests/kernel/*` witnesses are written against
  a kernel-linked calling convention that might not agree with
  `compositor/*.pdx`'s userspace ABI, needing "an explicit trampoline
  layer" — flagged as "worth a spike... may be a non-issue in practice"
  since both sides use SysV via `paideia-as`. It is in fact a non-issue:
  `tests/kernel/compositor/test_*.pdx` witnesses were ALREADY plain
  userspace-ABI `pub let test_X_run : () -> u64` functions with no
  kernel-linked assumptions (confirmed by reading all 20 at this
  landing) — they were simply never compiled with `--emit elf64` and
  linked as a userspace ELF before. No trampoline was needed.
* **The draft's §4 payoff (real functions retire the WEAK stubs) is
  NOT yet claimed here.** This landing makes the link path exist and
  proves it links (the RESIZE_EDGE_*/KIND_RECOVERY_PLANE fix in §2.1
  above is the direct evidence: a link that couldn't have failed that
  way before because it had never been attempted). It does not rewrite
  any of the 20 witnesses to stop using their WEAK stubs and start
  calling real mint/mutation primitives — `test_layer_tree.pdx`'s own
  GAP NOTE (no `layer_tree.pdx` mutation API exists yet) is still
  exactly as true today as it was when the α-02 draft described it.
  That rewrite is separate follow-on work, now unblocked rather than
  landed.
