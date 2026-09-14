# Compositor test runner — a `--compositor-tests` build.sh flag

**Status:** Design (wave α-02). Docs-only, proposes a flag; does not implement it.
**Date:** 2026-09-14.
**Grounds in:** `tools/build.sh` (TESTS_KERNEL_DIR loop, ~L509-524), `tools/build-user.sh` (~L326-345, compositor/* exclusion, paideia-os #2344), `tests/kernel/compositor/*.pdx` (20 files), `src/user/compositor/*.pdx` (35 files).

## 1. What exists today, precisely

`tools/build.sh` already compiles every `.pdx` under `tests/kernel/`
(compositor included) and links the resulting objects **into
`kernel.elf` itself**:

```
# tools/build.sh ~L509
TESTS_KERNEL_DIR="${REPO_ROOT}/tests/kernel"
if [[ -d "${TESTS_KERNEL_DIR}" ]]; then
    find "${TESTS_KERNEL_DIR}" -name '*.pdx' \
        -not -path '*/drivers/elaborator/*' -print0 \
      | xargs -0 ... "${REPO_ROOT}/tools/compile-one.sh" "{}" ...
    # objects appended to OBJECTS[], which becomes kernel.elf's link set
fi
```

This is a kernel-image build, not a standalone test ELF. It works for
most `tests/kernel/*` subdirectories because their witnesses are
self-contained (they call kernel-internal functions already being
linked into `kernel.elf` anyway).

**It does not work the way `tests/kernel/compositor/*.pdx` needs.**
Those tests exist to validate `src/user/compositor/*.pdx` — a
**userspace** module library, compiled by `tools/build-user.sh`, not by
`tools/build.sh`. The two build passes never share an object namespace,
so a compositor test that wanted to call a real function from
`layer_tree.pdx` (say) has no link path to it today. Confirmed by
reading `tests/kernel/compositor/test_layer_tree.pdx`: rather than
calling the module under test, it ships four local WEAK-stub helpers
(`tlt_attach`/`tlt_detach`/`tlt_get_at`/`tlt_count`) that reimplement
the arena arithmetic `layer_tree.pdx`'s own header documents, because
"there is also no mint body yet... so there is no shipping way to
populate a tree" through the real API. The test suite is testing byte
layouts it copied out of comments, not the module.

Separately, `tools/build-user.sh` excludes `compositor/*` (and five
sibling scaffold directories) from `SHELL_OBJECTS`/`INIT_OBJECTS` —
deliberately, per the #2344 fix, so `shell.elf` doesn't balloon past
`EXECVE_IMAGE_MAX` (65536 bytes) with rodata tables no shipping binary
uses yet. That exclusion is correct for `shell.elf`/`init.elf`. It is
irrelevant to — and currently blocks nothing about — a hypothetical
third link target, because no such target exists yet. The wave brief's
framing ("blocked because build-user.sh excludes compositor/*") is
slightly imprecise: the real blocker is the *absence* of a build path
that treats `compositor/*` objects as consumable by anything other
than `shell.elf`/`init.elf`, not the exclusion itself. This document
proposes that path.

## 2. Proposed flag: `bash tools/build.sh --compositor-tests`

A new, opt-in flag (default off — this must never become part of the
standing `bash tools/build.sh` / `bash tools/run-qemu.sh` pair per
`feedback_paideia_os_test_defaults`) that:

1. **Compiles `src/user/compositor/*.pdx`** using the same
   `compile-one.sh` invocation `build-user.sh` already uses for that
   directory today (the objects are already produced; they just aren't
   linked into anything). No change to `build-user.sh`'s exclusion
   list — this flag reads the same `.o` outputs, it does not change
   what gets excluded from `shell.elf`.
2. **Compiles `tests/kernel/compositor/*.pdx`** the same way
   `tools/build.sh`'s existing `TESTS_KERNEL_DIR` loop does.
3. **Links both object sets into a new standalone ELF**,
   `build/tests/compositor_tests.elf`, using a dedicated link script
   distinct from `kernel.elf`'s and from `shell.elf`'s — it needs
   `kernel.elf`'s test-witness calling convention (since the test
   bodies are written kernel-side, per the existing
   `tests/kernel/*` idiom) while resolving symbols against the
   userspace-ABI `compositor/*.o` objects. This is the one genuinely
   new piece of build machinery: today every `tests/kernel/*` witness
   assumes its callees are also kernel-linked. A cross-ABI link needs
   an explicit trampoline layer or a build-time assertion that the two
   sides agree on calling convention for the specific functions under
   test (SysV throughout, per `paideia-as`, so this may be a non-issue
   in practice — worth a spike before committing to the flag's
   implementation, not before documenting it).
4. **Runs nothing by itself.** The flag only builds
   `compositor_tests.elf`; execution is a QEMU or native-run concern
   left to `tools/run-smoke.sh` (or a future
   `tools/run-compositor-tests.sh`) exactly the way other kernel
   artifacts are exercised — this document does not propose a new
   execution harness, only the build-side link path.

## 3. Why gate it behind a flag rather than making it standard

- `compositor/*.pdx` and its test suite are mid-flight (α-01):
  linking them into every build by default would slow every developer
  build for a module library with no shipping consumer yet.
- The cross-ABI link path is new, unproven machinery. It should not
  gate the standing `bash tools/build.sh` invocation's exit code until
  it has run clean across a few real iterations.
- This mirrors how `tools/verify-elaborator-negatives.sh`
  (`tools/build.sh`'s own `-not -path '*/drivers/elaborator/*'`
  exclusion) already keeps an intentionally-special test class out of
  the default object-emitting path and verifies it via a separate,
  explicitly-invoked script.

## 4. Payoff

Once `--compositor-tests` exists, `tests/kernel/compositor/*.pdx` can
be rewritten to call the *real* `layer_tree.pdx`/`surface_commit.pdx`/…
functions instead of shipping local reimplementations of their byte
layouts — closing the exact gap `test_layer_tree.pdx`'s own header
comment names ("Requires layer_tree.pdx ... to export real
attach/detach/get_at/count primitives before this stub can be
retired"). This becomes the regression gate `compositor-split-decision.md`
(α-01) Phase 1 assigns to the in-tree library's reference/test-oracle
role.

No code changes accompany this document; it specifies the flag's
contract for a future softarch/osarch implementation pass.
