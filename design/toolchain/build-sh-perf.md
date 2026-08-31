# tools/build.sh performance analysis

## Baseline measurement (main, HEAD `bef24fe`, 910 kernel .pdx sources)

```
$ time bash tools/build.sh   # no source changes
real    7m52.622s
user    7m24.203s
sys     0m40.814s
```

**On a no-op build (no `.pdx` recompiles), the script still spends 7:52.**
Almost none of that is `paideia-as`. It is verify + confinement + gate work.

## Structural shape

- **Compile phase** — `paideia-as build --emit elf64` per .pdx → .o. Already
  incremental (issue #1611): timestamps are checked against source, this
  script, and the compiler binary. A no-op rebuild recompiles zero objects.
- **Confinement phase** — `~30` distinct `_confine_*` functions,
  **~756 call sites**, **~44 `for … in "${OBJECTS[@]}"` loops** across the
  script — each is O(N=910). Every gate asks "which .o files reference
  symbol S?" over the whole object set.
- **Verify phase** — 15 standalone `tools/verify-*.sh` scripts (~5.5k LOC
  total), several re-parsing the same `src/kernel/**` tree, invoked serially.
- **Link phase** — one `ld` call over 910 objects. Fast (seconds).
- **Post-link verify** — 3 short scripts against `build/kernel.elf`. Fast.

Existing wins already landed: `obj_relocs_against` (#1612) caches raw
`objdump -r` output per object in a bash associative array; the
per-.pdx-compile incremental gate (#1611) skips paideia-as on unchanged
sources.

**What still dominates a no-op is the ~688 000 (756 × 910) cache lookups
inside the confinement phase and the 15 serial verify-sh scripts, not
compilation.**

---

## Recommendations (ordered by wall-clock impact)

### 1. Whole-build no-op fast-path — *saves ~7 min on true no-op*

At entry, if `build/kernel.elf` is newer than every `.pdx` under
`src/kernel/` and `tests/kernel/`, newer than `tools/build.sh` itself,
newer than the paideia-as binary, and a `build/.verified-stamp` marker
file exists, print `[ok]` and exit 0. Correctness comes from the marker
being written at the end of the last successful full run; any change
that could invalidate the gates (source edit, compiler bump, script
edit) invalidates the timestamp comparison.

**Estimated saving:** ~7:30 out of 7:52 on no-op. This is the single
biggest win and probably the most common case (main invokes builds
between unrelated turns).

### 2. Invert the confinement scan — *saves ~3-5 min on any real build*

`obj_relocs_against(obj, sym)` is called ~688k times per build. The
work each does is trivial (bash regex on a cached string), but the
per-call overhead multiplies.

Replace the O(N × G) scan (G ≈ 300 unique symbols across 756 gate
call sites, N = 910 objects) with a **one-pass inverse index**:

```bash
# Build once, at start of confinement phase
declare -A __SYM_OWNERS   # sym → space-separated object list
for obj in "${OBJECTS[@]}"; do
    while read sym; do
        __SYM_OWNERS[$sym]+=" $obj"
    done < <(objdump -r "$obj" | awk '/^[0-9a-f]+ / {print $3}')
done
```

Every `_confine_one sym owner` becomes an O(1) hash lookup plus a
string subtract of `owner` from `__SYM_OWNERS[$sym]`.

The one-pass build costs 910 `objdump` subprocesses (~9 s if serial,
~1 s with `xargs -P $(nproc)`). The 756 lookups are microseconds each.

**Estimated saving:** 3-5 minutes on any build that reaches the
confinement phase (i.e. every non-trivial rebuild).

### 3. Parallelize the compile loop — *saves ~4× on full rebuild*

The current `while IFS= read pdx; do … done` invokes paideia-as
sequentially. Each invocation is independent (one .pdx → one .o).

Convert to:

```bash
find "${KERNEL_SRC}" -name '*.pdx' -print0 \
  | xargs -0 -n1 -P "${PARALLEL_JOBS:-$(nproc)}" \
      "${REPO_ROOT}/tools/compile-one.sh"
```

where `compile-one.sh` does the incremental timestamp check + the
`paideia-as build` invocation. Keep OBJECTS[] assembly as a post-pass
`find … -name '*.o'`.

**Estimated saving:** on the true full-rebuild case (`NO_INCREMENTAL=1`
or first build after `git clean`), roughly `nproc`× on the compile
phase (which is ~5 min of a full rebuild on this tree).

**Not helpful for the common no-op case** since no .pdx recompiles.

### 4. Parallelize independent verify-*.sh scripts — *saves ~30-60 s*

15 sub-scripts run serially at end. Most touch only `src/kernel/**` and
have no cross-dependency. Group them into a single background-batch:

```bash
pids=()
"${REPO_ROOT}/tools/verify-fingerprint-coverage.sh" &   ; pids+=($!)
"${REPO_ROOT}/tools/verify-file-id-hardcodes.sh"    &   ; pids+=($!)
"${REPO_ROOT}/tools/verify-no-raw-mmio.sh"          &   ; pids+=($!)
# … etc
for p in "${pids[@]}"; do wait "$p" || exit 1; done
```

Post-link verify scripts (`verify-syscall-dispatch.sh`,
`verify-sched-guards.sh`, `verify-tty-read-wrapper.sh`) all depend on
`build/kernel.elf` and can also run in parallel with each other.

**Estimated saving:** 30-60 s on a no-op build, more on a full rebuild.

### 5. Cache confinement results by object-set fingerprint — *saves seconds on no-op*

After the confinement phase passes, record a fingerprint over the
sorted list of `mtime + path` of every .o. Reject the cache if any .o
mtime changes. Skip the phase when the cache hits.

Combined with recommendation #1, this becomes redundant. Recommend it
only if #1 is refused; independent of #1, it's mid-value.

**Estimated saving:** ~10 s on no-op (mostly the objdump-cache warmup).

### 6. Move source-only linters before compilation — *saves nothing but fails faster*

`lint-no-kernel-aml.sh`, `verify-file-id-hardcodes.sh`,
`verify-no-frame-forbidden.sh`, `verify-mutation-marker.sh`,
`verify-no-raw-mmio.sh` scan `.pdx` source; they don't need any `.o`.
They currently run mixed with the object-scanning gates.

Move them to the top of the script (before `paideia-as` invocations)
and run them in parallel per #4. A source-side violation then fails
the build before any compile time is spent.

**Estimated saving:** zero on a passing build; unbounded on a failing
one (compile time not wasted).

### 7. Convert bash-native regex to `grep -F -x -w` batch — *saves seconds*

The cached `__OBJDUMP_RELOC_CACHE[$obj]` string is scanned via a bash
regex `(^|[^a-zA-Z0-9_])sym([^a-zA-Z0-9_]|$)`. Bash regex is fine, but
the inverse index (#2) makes this obsolete. If #2 is not adopted, use
`grep -F -x -w` against a precomputed one-symbol-per-line reformat:

```bash
declare -A __OBJDUMP_SYMS  # obj → newline-separated symbol list
```

Populated once per obj; lookup with `grep -Fxq "$sym" <<< "${__OBJDUMP_SYMS[$obj]}"`.

**Estimated saving:** 10-30 s, subsumed by #2.

### 8. Share `find src/kernel -name '*.pdx'` output across verify scripts

Multiple `verify-*.sh` scripts individually invoke `find src/kernel -name
'*.pdx'`. On 910 files that's cheap (~100 ms each), but doing it 15
times still adds up. Export the list once from `build.sh` into
`build/.kernel-sources` and let each verify script `read` it if
present.

**Estimated saving:** 1-2 s. Low value on its own; only worth doing
alongside #4.

---

## Summary table

| # | Change | No-op saving | Full-rebuild saving | Effort |
|---|--------|--------------|---------------------|--------|
| 1 | Whole-build no-op fast-path (kernel.elf newer-than every dep + verified-stamp) | **~7:30** | 0 | S (30 LOC) |
| 2 | Symbol→owners inverse index for `_confine_*` gates | ~5 min | ~5 min | M (50 LOC, refactor of `obj_relocs_against` + confine_one contract) |
| 3 | `xargs -P nproc` parallel paideia-as compile | 0 | 3-4 min on 4-8 cores | S (rework the two compile loops + `compile-one.sh` helper) |
| 4 | Parallel verify-*.sh scripts | 30-60 s | 30-60 s | S (15 lines) |
| 5 | Confinement result cache (obsoleted by #1) | 10 s | 0 | S |
| 6 | Move source-only linters to pre-compile parallel batch | 0 | fail-fast | S |
| 7 | grep -F -x -w cache lookup (obsoleted by #2) | 10-30 s | 10-30 s | XS |
| 8 | Shared kernel-sources list across verify scripts | 1-2 s | 1-2 s | XS |

## Recommended sequencing

**Land #1 first.** Fastest to implement, highest hit rate (every build
that changes nothing under `src/kernel/**` becomes instant), and its
correctness is easy to reason about.

**Land #2 next.** Restructures the confinement contract but doesn't
change any confinement semantics. Same set of failures caught, one hash
lookup per gate instead of one linear scan.

**Land #3 + #4 together.** Both introduce parallelism; do them once
with a `PARALLEL_JOBS` env var so a single knob controls both.

**Land #6 alongside #4.** Zero cost, better fail-fast behaviour.

Skip #5, #7, #8 unless #1/#2 are refused.

## Correctness notes for #1 (fast-path)

The stamp file `build/.verified-stamp` **must** be `touch`-ed only at
the very end of the script (after `[ok]` prints). If any gate fails
mid-run, the stamp does not exist yet → next invocation cannot short-
circuit. This preserves the "no green build without every gate passing"
invariant.

Dependencies to check for staleness (newer than the stamp fails the
fast-path):
- every `src/kernel/**/*.pdx`
- every `tests/kernel/**/*.pdx`
- `tools/build.sh`
- every `tools/verify-*.sh` and `tools/lint-*.sh`
- `${PAIDEIA_AS}` binary
- `tools/paideia-as/` HEAD commit (via `git rev-parse HEAD:tools/paideia-as`)
- `src/kernel/link.ld`
- every `tools/*.S` (boot_stub, userbin_embed, ap_trampoline, ap_trampoline_embed)
- `tools/ap_trampoline.ld`, `tools/build-user.sh`, `build/user/shell.bin`

A shell one-liner:

```bash
NEWEST_DEP=$(find "${KERNEL_SRC}" "${REPO_ROOT}/tests/kernel" \
                  "${REPO_ROOT}/tools/build.sh" \
                  "${REPO_ROOT}/tools/build-user.sh" \
                  "${REPO_ROOT}/tools/verify-"*.sh \
                  "${REPO_ROOT}/tools/lint-"*.sh \
                  "${REPO_ROOT}/tools/"*.S \
                  "${REPO_ROOT}/tools/"*.ld \
                  "${KERNEL_SRC}/link.ld" \
                  "${PAIDEIA_AS}" \
             -type f -newer "${BUILD_DIR}/.verified-stamp" -print -quit 2>/dev/null)
if [[ -z "${NEWEST_DEP}" && -f "${BUILD_DIR}/kernel.elf" && -z "${NO_INCREMENTAL:-}" ]]; then
    echo "[ok] ${BUILD_DIR}/kernel.elf (no-op, stamp fresh)"
    exit 0
fi
```

Reject via `NO_INCREMENTAL=1` (already supported for compile) so a
suspicious operator can always force a full rebuild.
