#!/usr/bin/env bash
# R31.M1 / #1608 — active mutation markers must not survive into a
# committed source tree.
#
# WHAT THIS POLICES
#
# When someone is intentionally MUTATING production code to test a
# gate, a witness, or the build itself — the power-button-inversion
# incident cited in #1608 is the canonical case — the mutation lives
# in an unsafe block that looks legitimate at a glance. The
# convention around this tree, and every other tree that has taken
# this class of defect seriously, is: mark the mutation with a
# string a grep will always find, so an honest cleanup pass cannot
# forget it. This gate is the automated form of that pass. It fails
# the build if ANY of a small set of active-mutation markers appears
# in a source file under src/ or tests/.
#
# WHAT MARKERS
#
# Six literal strings. Each has to be a phrase a reader who is
# NOT already looking for it would never write by accident, and each
# has to be short enough that leaving it in is embarrassing
# rather than easy to explain:
#
#     MUTATION-ACTIVE:
#     MUTATION_ACTIVE
#     // MUTATION:
#     // MUTATE:
#     TODO(mutation)
#     FIXME(mutation)
#
# The tree currently has ZERO of these strings — verified at the
# time this gate landed — so the normal path is silent success.
# Adding one triggers the gate; removing it clears it.
#
# WHAT MARKERS DELIBERATELY EXCLUDED
#
# `mov r11, 3` is the specific instruction the power-button-inversion
# mutation used, and the task that filed #1608 asks about it by name.
# It is NOT in the marker set, because `mov r11, 3` is a legitimate
# constant-load pattern used in ~40 places across the tree (register
# widths, magic numbers, class ids). A gate that flagged it would
# have a false-positive rate near 100% and every one of its failures
# would be dismissed as noise — which is how you build a gate that
# is silently disabled by everyone's `.gitignore of the mind`. The
# discipline the gate WOULD enforce is enforced by the marker
# strings above instead: an intentional mutation carries a marker
# that could only ever be a mutation, and a stray `mov r11, 3` in
# the middle of one is caught by the marker's `MUTATION-ACTIVE:`
# neighbour rather than by pattern-matching the instruction.
#
# SELF-TEST HOOK
#
# The gate's normal path passes silently, so a change that broke its
# fail path would be invisible. Set the environment variable
#
#     PDX_MUTATION_MARKER_SELFTEST=1
#
# to force a synthetic violation at a fake source location. The
# build should then FAIL with the standard error message, proving
# the gate's fail path is still wired. Never ship this variable set
# in CI or in tools/*.sh; it exists so a developer can verify the
# gate at a bench and nowhere else.
#
# Exit 0 = no active mutation marker in src/ or tests/.
# Exit 1 = at least one marker found, or the self-test hook is on.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TAG="[mutation-marker]"

# Self-test hook. See header. When set, emit the same failure shape a
# real hit produces, so an operator can verify the fail path is wired
# without perturbing the tree. Never ship this on.
if [[ "${PDX_MUTATION_MARKER_SELFTEST:-0}" == "1" ]]; then
    echo "${TAG} SELFTEST — synthesising an active-marker hit." >&2
    echo "${TAG} ACTIVE MARKER FOUND in tools/verify-mutation-marker.sh:1: MUTATION-ACTIVE: <self-test payload>" >&2
    exit 1
fi

# The marker set. Each pattern is a plain literal (grep -F) so a
# regex misread cannot silently disarm the gate. -w is not usable
# with -F, so we rely on the leading '// ' or the '-' / ')' /
# '_ACTIVE' punctuation to make the substrings non-idiomatic.
MARKERS=(
    "MUTATION-ACTIVE:"
    "MUTATION_ACTIVE"
    "// MUTATION:"
    "// MUTATE:"
    "TODO(mutation)"
    "FIXME(mutation)"
)

hits=0
for pat in "${MARKERS[@]}"; do
    # --include restricts to source-shaped files; --exclude-dir excludes
    # the vendored paideia-as submodule (which has its own hygiene rules)
    # and the build tree (its own generated files are not source).
    if hits_this=$(grep -rnF \
                        --include='*.pdx' --include='*.rs' \
                        --include='*.S' --include='*.c' --include='*.h' \
                        --exclude-dir='paideia-as' \
                        --exclude-dir='build' \
                        --exclude-dir='target' \
                        --exclude-dir='.git' \
                        -- "$pat" src/ tests/ 2>/dev/null); then
        while IFS= read -r line; do
            echo "${TAG} ACTIVE MARKER FOUND in ${line}" >&2
            hits=$((hits + 1))
        done <<< "$hits_this"
    fi
done

if [[ $hits -gt 0 ]]; then
    echo "" >&2
    echo "  Active mutation markers must not survive into a committed source" >&2
    echo "  tree. Each hit is a piece of code someone marked as being under" >&2
    echo "  deliberate mutation and then forgot to unmark. Remove the marker" >&2
    echo "  string AND revert whatever mutation it was documenting. If the" >&2
    echo "  code is genuinely staying, remove only the marker — but a marker" >&2
    echo "  in committed code is a defect in either direction." >&2
    exit 1
fi

echo "${TAG} no active mutation markers in src/ or tests/"
