#!/usr/bin/env bash
# tools/verify-no-frame-forbidden.sh -- forbid @no_frame from src/kernel.
#
# Fix #1606: paideia-as::emit_visit_lambda short-circuits on body_is_unsafe
# BEFORE consulting is_lambda_no_frame. Every hand-written asm function in
# the kernel is an `unsafe`-bodied lambda, so no frame prologue is ever
# emitted regardless of `@no_frame`. The annotation therefore documented
# an intent the compiler never enforced -- a false-load-bearing invariant,
# worse than absent per this repo's convention.
#
# The R41.M4 sweep removed all 3173 occurrences. This gate refuses any
# reintroduction of the literal string `@no_frame` under src/kernel/**.
# If a specific unsafe lambda ever needs a real frame prologue in the
# future, the compiler behaviour is already correct -- no annotation
# needed. If the compiler ever begins to consult is_lambda_no_frame on
# unsafe bodies (a paideia-as change), REVIEW THIS GATE FIRST.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
KERNEL_SRC="${REPO_ROOT}/src/kernel"

HITS=$(grep -rn --include='*.pdx' -- '@no_frame' "${KERNEL_SRC}" || true)

if [[ -n "${HITS}" ]]; then
    echo "[no-frame-forbidden] FAIL: @no_frame reintroduced under src/kernel/**" >&2
    echo "" >&2
    echo "${HITS}" >&2
    echo "" >&2
    echo "See #1606: @no_frame is a no-op on unsafe-bodied lambdas" >&2
    echo "(paideia-as::emit_visit_lambda short-circuits on body_is_unsafe" >&2
    echo "before consulting is_lambda_no_frame). Every asm function in" >&2
    echo "this kernel is unsafe-bodied; the annotation documents intent" >&2
    echo "the compiler never enforces. Remove the annotation; the frame" >&2
    echo "prologue is already suppressed." >&2
    exit 1
fi

echo "[no-frame-forbidden] no @no_frame occurrences under src/kernel/**"
