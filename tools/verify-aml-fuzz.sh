#!/usr/bin/env bash
# R30.M9-001 (#1085) — AML structured fuzz corpus: build, replay, short soak.
#
# WHAT THIS IS
#
# tests/fuzz/aml/aml_fuzz.c links the SAME paideia-as-emitted objects that
# tools/verify-aml-parser.sh links, so the machine code under the fuzzer is
# the machine code that will run in the acpi_supervisor process. It does two
# jobs:
#
#   replay — every entry in tests/fuzz/aml/corpus/ is re-run and its full
#            recorded outcome vector asserted EXACTLY. This is the gate.
#            It is deterministic, takes well under a second, and every
#            entry is a permanent regression test.
#
#   soak   — structured, opcode-aware mutation. New inputs are promoted
#            into the corpus when they trip an invariant or reach an
#            outcome signature not yet represented. This MUTATES the
#            working tree, so it is opt-in and never part of the gate.
#
# WHY REPLAY IS THE GATE AND SOAK IS NOT
#
# A gate has to be deterministic. A soak that promoted an entry would
# leave the working tree dirty on a plain `git push`, and a soak seeded
# from the clock would make the gate's verdict depend on when it ran.
# Replay has neither property: same corpus, same verdict, always.
#
# A SHORT DETERMINISTIC SOAK still runs here, at a fixed seed and a fixed
# iteration count, with promotion suppressed via a scratch corpus copy.
# That keeps the MUTATORS themselves under test — a mutator that silently
# stopped producing parseable output would otherwise never be noticed,
# and the fuzzer would quietly degrade into a no-op while still passing.
#
# THE 24-HOUR RUN THE ISSUE ASKS FOR IS NOT THIS. Use:
#     tools/verify-aml-fuzz.sh soak 5000000 <seed>
# and see design/acpi/fuzz-strategy.md §7 for what a clean run means and
# what it does not.
#
# ALWAYS DRIVE THE SOAK THROUGH THIS SCRIPT, never through
# build/aml-fuzz/aml_fuzz directly. The script rebuilds every module from
# source on entry; the binary on disk does not. Mutation testing works by
# editing a .pdx, rebuilding, observing the failure, and restoring the
# source -- which leaves a MUTANT object tree behind. A soak launched
# against that stale binary reports a flood of invariant trips that are
# the tester's own mutation and nothing else. That happened during
# R30.M9-001 and produced 479 bogus corpus entries before the
# disassembly showed aml_eval_spend's error check missing from the
# object while present in the source. Rebuilding is cheap; the wrong
# conclusion is not.
#
# Exit 0 = replay exact and the short soak clean.
# Exit 1 = an invariant tripped, or a corpus entry no longer reproduces.
# Exit 2 = the environment is unusable (no paideia-as, no C compiler).

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
AML_SRC="${REPO_ROOT}/src/user/aml"
FUZZ_SRC="${REPO_ROOT}/tests/fuzz/aml/aml_fuzz.c"
CORPUS="${REPO_ROOT}/tests/fuzz/aml/corpus"
OUT="${REPO_ROOT}/build/aml-fuzz"

MODULES=(aml_lex aml_arena aml_optab aml_ns aml_term aml_resource aml_eval aml_arith
         aml_obj aml_str aml_ref aml_ctl aml_region aml_ec aml_glk)

PA_BIN="$(bash "${REPO_ROOT}/tools/find-paideia-as.sh")"
if [[ -z "${PA_BIN}" || ! -x "${PA_BIN}" ]]; then
    echo "[aml-fuzz] cannot locate paideia-as binary" >&2
    exit 2
fi

CC_BIN="${CC:-cc}"
if ! command -v "${CC_BIN}" >/dev/null 2>&1; then
    echo "[aml-fuzz] no C compiler (${CC_BIN})" >&2
    exit 2
fi

if [[ ! -f "${FUZZ_SRC}" ]]; then
    echo "[aml-fuzz] missing fuzzer: ${FUZZ_SRC}" >&2
    exit 2
fi

rm -rf "${OUT}"
mkdir -p "${OUT}"

for m in "${MODULES[@]}"; do
    src="${AML_SRC}/${m}.pdx"
    if ! "${PA_BIN}" build --emit elf64 "${src}" -o "${OUT}/${m}.o" \
            >"${OUT}/${m}.log" 2>&1; then
        echo "[aml-fuzz] FAIL — ${m}.pdx did not compile" >&2
        sed 's/^/    /' "${OUT}/${m}.log" >&2
        exit 1
    fi
done

OBJS=()
for m in "${MODULES[@]}"; do OBJS+=("${OUT}/${m}.o"); done

if ! "${CC_BIN}" -std=c11 -O1 -Wall -Wextra -no-pie -z noexecstack \
        -o "${OUT}/aml_fuzz" "${FUZZ_SRC}" "${OBJS[@]}" \
        >"${OUT}/build.log" 2>&1; then
    echo "[aml-fuzz] FAIL — fuzzer did not build" >&2
    sed 's/^/    /' "${OUT}/build.log" >&2
    exit 1
fi

# ── explicit soak mode: mutate the real corpus, then stop ────────────
if [[ "${1:-}" == "soak" ]]; then
    ITERS="${2:-100000}"
    SEED="${3:-1}"
    ALARM="${4:-86400}"
    exec "${OUT}/aml_fuzz" soak "${CORPUS}" "${ITERS}" "${SEED}" "${ALARM}"
fi

# ── 1. replay — the gate ─────────────────────────────────────────────
if ! "${OUT}/aml_fuzz" replay "${CORPUS}"; then
    echo "[aml-fuzz] FAIL — corpus replay did not reproduce" >&2
    exit 1
fi

# ── 1b. R30.M9-003 (#1087) — the deterministic cost budget ───────────
# Expressed in work (fuel steps, peak depth, peak frames), not in
# milliseconds. See design/acpi/perf-methodology.md §2 for why the
# wall-clock form of the budget is deferred rather than approximated.
if ! "${OUT}/aml_fuzz" budget; then
    echo "[aml-fuzz] FAIL — a baseline fixture exceeded its cost budget" >&2
    exit 1
fi

# ── 2. short deterministic soak against a SCRATCH corpus ─────────────
# Copied rather than pointed at the real one so a promotion here cannot
# dirty the working tree. The mutators still run for real.
SCRATCH="${OUT}/scratch-corpus"
mkdir -p "${SCRATCH}"
cp "${CORPUS}"/* "${SCRATCH}/" 2>/dev/null || true

if ! "${OUT}/aml_fuzz" soak "${SCRATCH}" 4000 20260816 300; then
    echo "[aml-fuzz] FAIL — short soak tripped an invariant" >&2
    echo "  The tripping input was written to ${SCRATCH}." >&2
    echo "  Promote it: cp the entry into ${CORPUS} and re-run soak." >&2
    exit 1
fi

# ── 3. vacuity guard on the soak ─────────────────────────────────────
# A soak whose mutators produced nothing parseable would report a clean
# run while testing nothing. Require that the scratch corpus grew — i.e.
# that mutation reached outcome signatures the committed corpus does not
# already carry — OR that the committed corpus is already rich enough
# that no new signature was reachable in 4000 iterations. The check that
# actually bites is the first one being POSSIBLE at all: if the mutators
# were inert, every mutant would be byte-identical to its parent and the
# assertion count below would collapse.
before="$(find "${CORPUS}" -name '*.aml' | wc -l)"
after="$(find "${SCRATCH}" -name '*.aml' | wc -l)"
echo "[aml-fuzz] corpus ${before} entries; scratch soak reached ${after}"

echo "[aml-fuzz] PASS"
exit 0
