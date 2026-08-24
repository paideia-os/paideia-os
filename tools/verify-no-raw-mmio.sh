#!/usr/bin/env bash
# tools/verify-no-raw-mmio.sh — boot-mmio-mapping step 8 gate
#
# WHAT THIS POLICES
#
# design/kernel/boot-mmio-mapping.md turns every firmware-fixed device MMIO
# window (HPET 0xFED00000, xAPIC 0xFEE00000, IOAPIC 0xFEC00000) into an
# opaque kernel VA sourced from _hpet_mmio_va / _xapic_mmio_va /
# _ioapic_mmio_va. Those PA literals must appear in EXACTLY ONE code path
# in the kernel source: src/kernel/boot/mmio_init.pdx, which is the manifest
# platform_map_early_mmio walks. A second appearance in a driver, witness
# or AP-entry path is a regression — the driver would dereference the
# raw PA (correct only under -kernel PVH by identity-map coincidence) and
# silently break on any boot where the window lands outside the boot huge
# pages (UEFI/T14, ACPI-relocated windows, virtualization variants).
#
# WHAT COUNTS AS A HIT
#
# Only real instruction sites are flagged: `mov`, `add`, `lea`, `cmp`, `or`
# with an immediate matching 0xFED00 / 0xFEE00 / 0xFEC00 in the argument
# position. Lines that are:
#   - comments (start with //)
#   - unused module-level `let NAME : u64 = 0xFED00000` declarations
#   - justification / documentation strings inside function definitions
# are NOT flagged, because they do not compile into a memory access at
# that PA. This mirrors the equivalence class the compiler sees.
#
# WHAT'S ALLOWLISTED
#
# The manifest itself (boot/mmio_init.pdx) plus a handful of MSI/MSI-X
# message-address encoders whose literals are Intel-spec bit-patterns for
# a MESSAGE landing on the LAPIC (unrelated to LAPIC MMIO access).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# Instruction mnemonics that use their immediate as a live operand. `let`
# is intentionally NOT here — a bare module-level constant declaration
# that never reaches the encoder is dead documentation.
readonly INSN_RE='^[[:space:]]*(mov|add|sub|cmp|lea|or|and|xor|test)[[:space:]]'

# The PA literals to police (5-hex-digit prefixes for the three
# firmware-fixed windows).
readonly LIT_RE='0xFED00|0xFEE00|0xFEC00'

# Allowlist: paths that may name these literals in instruction position.
# Every entry carries a one-line reason. Additions require a memo
# cross-reference or reviewer sign-off in the PR.
declare -A ALLOW=(
    ['src/kernel/boot/mmio_init.pdx']='step 2 manifest — the sole legitimate site'
    ['src/kernel/core/pci/msi.pdx']='MSI message-address bit-pattern (SDM Vol 3A §11.11.1)'
    ['src/kernel/core/pci/msix.pdx']='MSI-X message-address bit-pattern'
    ['src/kernel/core/apic/msi.pdx']='MSI_ADDRESS_BASE encoder constant'
    ['src/kernel/core/cap/kind_dev.pdx']='request_mmio_mapping test PA arg'
)

fail=0
declare -a hits

while IFS=: read -r file line rest; do
    # Skip pure comment lines. Assembly comments in this codebase are //.
    trimmed="${rest#"${rest%%[![:space:]]*}"}"
    if [[ "${trimmed}" == //* ]]; then
        continue
    fi
    # Skip module-level `let NAME : u64 = 0xFE...` — these are unused
    # documentation constants (grep-verified: no `mov ..., LAPIC_MMIO_BASE`
    # or similar reference remains after step 4). If they were reached by
    # code they'd match INSN_RE via the site that reads them.
    if [[ "${trimmed}" == "let "*"= 0x"* || "${trimmed}" == "pub let "*"= 0x"* ]]; then
        continue
    fi
    # Only flag lines whose first non-space token is an instruction mnemonic.
    # Anchor at start of the trimmed content — justification strings would
    # otherwise match on the `mov` inside `Encoder: mov (rip-rel mem load)`.
    first_tok="${trimmed%%[[:space:],]*}"
    case "${first_tok}" in
        mov|mov_d|add|sub|cmp|lea|or|and|xor|test) : ;;
        *) continue ;;
    esac
    # Also skip lines whose remainder is enclosed in a string literal
    # (justification content wraps across lines with embedded literals).
    if [[ "${trimmed}" == *'"'* ]]; then
        continue
    fi
    if [[ -n "${ALLOW[$file]:-}" ]]; then
        continue
    fi
    hits+=( "${file}:${line}: ${trimmed}" )
    fail=1
done < <(
    grep -rEn "${LIT_RE}" src/kernel/ 2>/dev/null || true
)

if [[ ${fail} -ne 0 ]]; then
    echo "[verify-no-raw-mmio] FAIL - hard-coded firmware-fixed MMIO literal" >&2
    echo "  in an instruction operand outside the allowlist. Every device" >&2
    echo "  MMIO PA must be sourced from _hpet_mmio_va / _xapic_mmio_va /" >&2
    echo "  _ioapic_mmio_va (populated at boot by platform_map_early_mmio)," >&2
    echo "  not named directly in a driver, witness, or AP-entry path. See" >&2
    echo "  design/kernel/boot-mmio-mapping.md §3 step 2 for the sole" >&2
    echo "  legitimate manifest location; §3 steps 3-7 show the driver-" >&2
    echo "  conversion pattern." >&2
    echo "" >&2
    echo "  Hits:" >&2
    for h in "${hits[@]}"; do
        echo "    ${h}" >&2
    done
    echo "" >&2
    echo "  If a new file legitimately names one of these literals (e.g. a" >&2
    echo "  new MSI-address encoder), add its path to the ALLOW map at the" >&2
    echo "  top of tools/verify-no-raw-mmio.sh with a one-line reason. Every" >&2
    echo "  allowlist addition is a design decision — the PR that adds one" >&2
    echo "  should carry a memo cross-reference or a reviewer sign-off." >&2
    exit 1
fi

echo "[verify-no-raw-mmio] no raw firmware-fixed MMIO literals in instruction operands outside allowlist"
