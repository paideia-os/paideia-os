#!/usr/bin/env bash
# tools/lint-no-kernel-aml.sh — R20-M4-004 / #822
#
# Enforce the "no AML in kernel" architectural boundary.
#
# Scans every source file under src/kernel/** for AML-related identifiers
# and refuses the build if any are found.
#
# See design/acpi/no-aml-in-kernel.md for the full rationale.
#
# Enforcement (§3 of the design doc):
#   Case-insensitive forbidden token set (comment-stripped):
#     aml, amlvm, amlparse, dsdt, ssdt, \_SB_/\_SB., acpica
#   Identifier form (comment-stripped, word-boundaried):
#     \baml_[a-zA-Z0-9_]*\b, \bacpica\b, \bamlvm\b, \bamlparse\b
#
# Comment-stripping: for each source line we strip a `//`-to-EOL and
# `#`-to-EOL suffix before matching so the kernel comment
# "// AML lives in the userspace bubble" is exempt while
# "let AML_STATE = ..." is caught.
#
# Performance: one composite regex per pass, one grep per file.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
KERNEL_SRC="${REPO_ROOT}/src/kernel"

if [[ ! -d "${KERNEL_SRC}" ]]; then
    echo "[no-aml-lint] FAIL: ${KERNEL_SRC} not found" >&2
    exit 1
fi

# Composite regex. Kept as ERE (grep -E).
#
# Case-insensitive. Leading `\b` word boundary anchors matches at
# identifier start. Two shapes:
#   - LOOSE : `\baml`, `\bdsdt`, `\bssdt` — start-of-identifier match
#     with no trailing constraint, so both `dsdt` and `dsdt_ptr`
#     catch. Pure substrings inside another identifier (e.g.
#     `param_lower` — `aml` at position 2) do NOT match because `\b`
#     requires the preceding character to be non-word.
#   - TIGHT : `\bacpica(?![a-zA-Z])` — start of identifier PLUS a
#     non-letter immediately after `acpica`. Catches `acpica`,
#     `acpica_init`, `acpica.o` — but does NOT trigger on `AcpiCap`
#     or `AcpiCache` (which naturally start with the six chars
#     `acpica` case-insensitively but continue with a letter, so are
#     clearly a different identifier). ERE has no lookahead, so we
#     use the `[^a-zA-Z]|$` alternation form.
#
# `\_SB_` and `\_SB\.` are the ACPI root-scope symbols; leading
# backslash is intentional (that is how they appear in AML source).
FORBIDDEN='(\baml|\bdsdt|\bssdt|\bacpica([^a-zA-Z]|$)|\\_SB_|\\_SB\.)'

FAIL=0

# Enumerate scan targets; skip build artefacts and self-references.
while IFS= read -r -d '' path; do
    case "${path}" in
        */tools/lint-no-kernel-aml.sh) continue ;;
        */design/acpi/no-aml-in-kernel.md) continue ;;
    esac

    # sed pipeline:
    #   1) strip `//`-to-EOL      : s|//.*$||
    #   2) strip `#`-to-EOL       : s|#.*$||
    #   Preserve line numbers for grep -n via -E on the sed output.
    #
    # We run grep twice against the same stripped stream to keep the
    # error message specific about which pattern class matched.
    stripped=$(sed -e 's|//.*$||' -e 's|#.*$||' "${path}")

    while IFS=: read -r lineno content; do
        [[ -z "${lineno}" ]] && continue
        rel="${path#${REPO_ROOT}/}"
        echo "[no-aml-lint] FORBIDDEN: ${rel}:${lineno}: ${content}" >&2
        FAIL=1
    done < <(printf '%s\n' "${stripped}" | grep -niE -- "${FORBIDDEN}" || true)
done < <(find "${KERNEL_SRC}" -type f \
              \( -name '*.pdx' -o -name '*.S' -o -name '*.s' -o -name '*.ld' \
                 -o -name '*.md' -o -name '*.sh' -o -name '*.c' -o -name '*.h' \) \
              -print0)

if [[ ${FAIL} -ne 0 ]]; then
    echo "[no-aml-lint] FAIL: AML-related identifiers detected in src/kernel/**" >&2
    echo "[no-aml-lint] See design/acpi/no-aml-in-kernel.md §3 for the forbidden set." >&2
    exit 1
fi

echo "[no-aml-lint] OK — no AML identifiers in src/kernel/**"
exit 0
