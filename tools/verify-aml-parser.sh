#!/usr/bin/env bash
# tools/verify-aml-parser.sh — R30.M1-001 (#1049) / R30.M1-002 (#1050)
#
# Build-time verification of the userspace AML tokenizer and namespace
# parser. Wired into `.githooks/pre-push` as the `aml-parser` step, in the
# same slot and the same style as tools/verify-elaborator-negatives.sh.
#
# WHY BUILD-TIME AND NOT A BOOT WITNESS
# ------------------------------------
# At R30.M1 there is no runtime path that hands a DSDT to this code — the
# acpi_supervisor process does not yet receive one, and the KIND_ACPI
# mapping is not exposed to ring 3. A QEMU witness could therefore only
# assert that the objects link, which the ordinary build already proves.
# What IS worth asserting is behaviour, and the tokenizer and parser are
# pure computation over a byte buffer (no syscalls, no MMIO, no
# capabilities), so the very same paideia-as-emitted machine code links
# against a native SysV harness and runs against a real corpus. That is
# strictly more evidence than a dormant boot path, so this check is wired
# build-time rather than as an invented runtime witness.
#
# WHAT IT CHECKS
# --------------
#   1. PLACEMENT. No AML source under src/kernel/**. This is belt and
#      braces alongside tools/lint-no-kernel-aml.sh: that script polices
#      identifiers, this one polices files.
#
#   2. COMPILATION. All four modules build with the pinned paideia-as.
#
#   3. STORAGE ENCAPSULATION. Checked with `objdump -r`, which is the only
#      way to prove it mechanically: a module's private .bss must be
#      relocated against from that module's object and NO OTHER. Namely
#      `aml_lex_state` only from aml_lex.o, the four arena arrays only
#      from aml_arena.o, and `aml_optab` only from aml_optab.o.
#
#      This is not tidiness. The lexer's bounds-check invariant is that
#      EVERY read of the untrusted AML buffer goes through aml_lex_u8 or
#      aml_lex_peek_u8, both of which compare pos against len before
#      forming an address. That invariant holds only for as long as no
#      other module can reach the buffer pointer, and the buffer pointer
#      lives in aml_lex_state. A future issue that "just peeks" at the
#      state from the parser would quietly void the guarantee; this check
#      fails the push instead.
#
#   4. THE CORPUS. tests/user/aml/aml_harness.c is compiled against the
#      objects and run. Every fixture is loaded so its last byte abuts a
#      PROT_NONE guard page, so an out-of-bounds read is a SIGSEGV rather
#      than a silent over-read; the harness first proves that trap is
#      armed, then runs the well-formed and malformed corpora.
#
# Standalone-runnable:
#
#   $ bash tools/verify-aml-parser.sh
#   [aml-parser] placement: no AML sources under src/kernel/**
#   [aml-parser] compiled 4 module(s)
#   [aml-parser] encapsulation: aml_lex_state confined to aml_lex.o
#   [aml-parser] encapsulation: arena storage confined to aml_arena.o
#   [aml-parser] encapsulation: aml_optab confined to aml_optab.o
#   [aml-corpus] NNN assertions PASS
#   [aml-parser] PASS
#
# Exit codes:
#   0 — all checks pass
#   1 — a check failed
#   2 — the environment is unusable (no paideia-as, no C compiler)

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
AML_SRC="${REPO_ROOT}/src/user/aml"
HARNESS="${REPO_ROOT}/tests/user/aml/aml_harness.c"
OUT="${REPO_ROOT}/build/aml"

MODULES=(aml_lex aml_arena aml_optab aml_ns)

# ── environment ──────────────────────────────────────────────────────
PA_BIN="$(bash "${REPO_ROOT}/tools/find-paideia-as.sh")"
if [[ -z "${PA_BIN}" || ! -x "${PA_BIN}" ]]; then
    echo "[aml-parser] cannot locate paideia-as binary" >&2
    exit 2
fi

CC_BIN="${CC:-cc}"
if ! command -v "${CC_BIN}" >/dev/null 2>&1; then
    echo "[aml-parser] no C compiler (${CC_BIN}) — cannot run the corpus" >&2
    exit 2
fi
if ! command -v objdump >/dev/null 2>&1; then
    echo "[aml-parser] objdump not found — cannot check encapsulation" >&2
    exit 2
fi

if [[ ! -f "${HARNESS}" ]]; then
    echo "[aml-parser] missing corpus: ${HARNESS}" >&2
    exit 2
fi

# ── 1. placement ─────────────────────────────────────────────────────
# The no-AML guardrail forbids AML identifiers in the kernel; this
# forbids AML FILES there, which is the failure mode a well-meaning
# refactor would produce.
stray="$(find "${REPO_ROOT}/src/kernel" -type f -name 'aml*' -print 2>/dev/null || true)"
if [[ -n "${stray}" ]]; then
    echo "[aml-parser] FAIL — AML sources found under src/kernel/**:" >&2
    printf '  %s\n' ${stray} >&2
    echo "  AML must never execute in ring 0. See design/acpi/no-aml-in-kernel.md." >&2
    exit 1
fi
echo "[aml-parser] placement: no AML sources under src/kernel/**"

# ── 2. compilation ───────────────────────────────────────────────────
rm -rf "${OUT}"
mkdir -p "${OUT}"
for m in "${MODULES[@]}"; do
    src="${AML_SRC}/${m}.pdx"
    if [[ ! -f "${src}" ]]; then
        echo "[aml-parser] FAIL — missing module: ${src}" >&2
        exit 1
    fi
    if ! "${PA_BIN}" build --emit elf64 "${src}" -o "${OUT}/${m}.o" >"${OUT}/${m}.log" 2>&1; then
        echo "[aml-parser] FAIL — ${m}.pdx did not compile" >&2
        sed 's/^/    /' "${OUT}/${m}.log" >&2
        exit 1
    fi
done
echo "[aml-parser] compiled ${#MODULES[@]} module(s)"

# ── 3. storage encapsulation ─────────────────────────────────────────
# reloc_count <object> <extended-regex>
reloc_count() {
    objdump -r "$1" 2>/dev/null | grep -cE "$2" || true
}

check_confined() {
    local label="$1" owner="$2" pattern="$3"
    local m rc
    if [[ "$(reloc_count "${OUT}/${owner}.o" "${pattern}")" -eq 0 ]]; then
        echo "[aml-parser] FAIL — ${label}: owner ${owner}.o does not reference it" >&2
        echo "  Either the symbol was renamed or the module was gutted; the" >&2
        echo "  encapsulation check would then pass vacuously, so it fails instead." >&2
        exit 1
    fi
    for m in "${MODULES[@]}"; do
        [[ "${m}" == "${owner}" ]] && continue
        rc="$(reloc_count "${OUT}/${m}.o" "${pattern}")"
        if [[ "${rc}" -ne 0 ]]; then
            echo "[aml-parser] FAIL — ${label}: ${m}.o has ${rc} relocation(s) against it" >&2
            echo "  Only ${owner}.o may touch this storage directly; everything else" >&2
            echo "  must go through the accessor API. See tools/verify-aml-parser.sh" >&2
            echo "  and the invariant note in src/user/aml/aml_lex.pdx." >&2
            objdump -r "${OUT}/${m}.o" | grep -E "${pattern}" | sed 's/^/    /' >&2
            exit 1
        fi
    done
    echo "[aml-parser] encapsulation: ${label}"
}

check_confined "aml_lex_state confined to aml_lex.o" aml_lex 'aml_lex_state'
check_confined "arena storage confined to aml_arena.o" aml_arena \
               'aml_node_arena|aml_name_arena|aml_u64_arena|aml_arena_state|aml_node_last'
check_confined "aml_optab confined to aml_optab.o" aml_optab 'aml_optab$|aml_optab_len'

# ── 4. the corpus ────────────────────────────────────────────────────
OBJS=()
for m in "${MODULES[@]}"; do OBJS+=("${OUT}/${m}.o"); done

if ! "${CC_BIN}" -std=c11 -O1 -Wall -Wextra -no-pie -z noexecstack \
        -o "${OUT}/aml_harness" "${HARNESS}" "${OBJS[@]}" \
        >"${OUT}/harness.log" 2>&1; then
    echo "[aml-parser] FAIL — corpus harness did not build" >&2
    sed 's/^/    /' "${OUT}/harness.log" >&2
    exit 1
fi

if ! "${OUT}/aml_harness"; then
    echo "[aml-parser] FAIL — corpus assertions failed" >&2
    exit 1
fi

echo "[aml-parser] PASS"
exit 0
