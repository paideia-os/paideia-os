#!/usr/bin/env bash
# tools/verify-elaborator-negatives.sh — R29-M2-002 (#1024)
#
# Runs paideia-as against the elaborator negative-and-positive fixture
# pair under tests/kernel/drivers/elaborator/ and asserts:
#
#   (a) mmio_effect_without_cap.pdx   FAILS elaboration
#       (exit != 0) AND stderr contains `C1301`
#       — the specific diagnostic code (paideia-as#1307,
#       cap_infer::C_EFFECT_REQUIRES_CAP) that names the missing cap.
#
#   (b) mmio_effect_with_cap.pdx      SUCCEEDS (exit 0)
#       AND stderr contains no `C1301` — the coupling walker must
#       discriminate precisely; a regression that started spuriously
#       rejecting the positive companion is as much a bug as one
#       that started silently accepting the negative.
#
# Wired into `.githooks/pre-push` as the `elaborator-negatives`
# step. Standalone-runnable so an operator can invoke it directly:
#
#   $ bash tools/verify-elaborator-negatives.sh
#   [elaborator-negatives] mmio_effect_without_cap: rejected with C1301 (expected)
#   [elaborator-negatives] mmio_effect_with_cap: accepted (expected)
#   [elaborator-negatives] PASS
#
# Design intent per `design/roadmap/next-wave-softarch.md` §3 R29
# Structural witness — every driver process' effect row is checked at
# link time; a driver claiming `!{mmio_read}` without holding an
# `MmioMemCap` fails elaboration. This script is the R29.M2-002
# in-repo verification of that guarantee.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PA_BIN="$(bash "${REPO_ROOT}/tools/find-paideia-as.sh")"
if [[ -z "${PA_BIN}" || ! -x "${PA_BIN}" ]]; then
    echo "[elaborator-negatives] cannot locate paideia-as binary" >&2
    exit 2
fi

REJECT_FIXTURE="${REPO_ROOT}/tests/kernel/drivers/elaborator/mmio_effect_without_cap.pdx"
ACCEPT_FIXTURE="${REPO_ROOT}/tests/kernel/drivers/elaborator/mmio_effect_with_cap.pdx"

for f in "${REJECT_FIXTURE}" "${ACCEPT_FIXTURE}"; do
    if [[ ! -f "${f}" ]]; then
        echo "[elaborator-negatives] missing fixture: ${f}" >&2
        exit 2
    fi
done

# ── (a) Negative fixture MUST fail with C1301 ────────────────────────
tmp_reject_err="$(mktemp)"
trap 'rm -f "${tmp_reject_err}" "${tmp_accept_err:-}"' EXIT
NO_COLOR=1 "${PA_BIN}" build --emit placeholder "${REJECT_FIXTURE}" \
    >/dev/null 2>"${tmp_reject_err}"
reject_rc=$?
if [[ "${reject_rc}" -eq 0 ]]; then
    echo "[elaborator-negatives] mmio_effect_without_cap: FAIL — expected non-zero exit, got 0" >&2
    echo "  paideia-as accepted a misdeclared driver — the coupling walker regressed." >&2
    echo "  fixture: ${REJECT_FIXTURE}" >&2
    exit 1
fi
if ! grep -Fq "C1301" "${tmp_reject_err}"; then
    echo "[elaborator-negatives] mmio_effect_without_cap: FAIL — expected C1301 in stderr" >&2
    echo "  paideia-as failed but with the wrong diagnostic — either a different check fired," >&2
    echo "  or C1301 was renumbered. Investigate paideia-as#1307." >&2
    echo "  stderr follows:" >&2
    sed 's/^/    /' "${tmp_reject_err}" >&2
    exit 1
fi
echo "[elaborator-negatives] mmio_effect_without_cap: rejected with C1301 (expected)"

# ── (b) Positive companion MUST elaborate clean ──────────────────────
tmp_accept_err="$(mktemp)"
NO_COLOR=1 "${PA_BIN}" build --emit placeholder "${ACCEPT_FIXTURE}" \
    >/dev/null 2>"${tmp_accept_err}"
accept_rc=$?
if [[ "${accept_rc}" -ne 0 ]]; then
    echo "[elaborator-negatives] mmio_effect_with_cap: FAIL — expected exit 0, got ${accept_rc}" >&2
    echo "  paideia-as rejected a correctly-declared driver — the coupling walker is over-strict." >&2
    echo "  fixture: ${ACCEPT_FIXTURE}" >&2
    echo "  stderr follows:" >&2
    sed 's/^/    /' "${tmp_accept_err}" >&2
    exit 1
fi
if grep -Fq "C1301" "${tmp_accept_err}"; then
    echo "[elaborator-negatives] mmio_effect_with_cap: FAIL — C1301 fired on the positive companion" >&2
    echo "  the coupling walker cannot see the paideia.mmio cap it should see." >&2
    echo "  stderr follows:" >&2
    sed 's/^/    /' "${tmp_accept_err}" >&2
    exit 1
fi
echo "[elaborator-negatives] mmio_effect_with_cap: accepted (expected)"

echo "[elaborator-negatives] PASS"
exit 0
