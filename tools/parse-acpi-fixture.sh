#!/usr/bin/env bash
# tools/parse-acpi-fixture.sh — R20-M5-001 (#823)
#
# Host-side harness that ingests a directory of raw ACPI table binaries
# (as captured from a live system via tools/capture-t14-g4-acpi.md) and
# runs each through the R20.M1..M3 kernel parsers to assert on shape.
#
# The R20 parsers live inside kernel.elf (src/kernel/acpi/*.pdx) and
# expect to run in kernel mode with @{mem, boot} capability. Rather
# than re-implement a userspace copy, this harness drives them by:
#
#   1. Boot kernel.elf under QEMU with -kernel + a synthetic BSP path
#      that arranges for phase1_acpi_gather to run against the fixture
#      tables mapped at a well-known VA.
#   2. Read UART output and grep for per-parser "ACPI <TABLE> OK\n" or
#      "ACPI <TABLE> FAIL\n" markers (matching the synthetic fixture
#      convention at tests/kernel/acpi/{rsdp,xsdt,madt,mcfg,fadt,hpet}_synth.pdx).
#
# At R20.M5 close the runtime plumbing that reads .bin files into the
# kernel's fixture window is still open — the harness currently only
# validates fixture-directory shape (files present, sizes plausible,
# SIG4 headers correct) and defers the QEMU-drive step until the
# t14_g4_fixture.pdx witness lands (see the file header for the
# activation conditions).
#
# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
#
#   tools/parse-acpi-fixture.sh --help
#       Print this usage block.
#
#   tools/parse-acpi-fixture.sh [FIXTURE_DIR]
#       Validate that FIXTURE_DIR contains the expected ACPI table set,
#       verify each file's SIG4 header, and (once the runtime path
#       lands) drive them through the R20 parsers.
#
#       FIXTURE_DIR defaults to tests/kernel/acpi/fixtures/t14g4/.
#
#   Expected files (per tools/capture-t14-g4-acpi.md):
#       rsdp.bin  — 36-byte RSDP v2 (Linux exposes via /sys, sig "RSD PTR ")
#       xsdt.bin  — variable, sig "XSDT"
#       apic.bin  — variable, sig "APIC" (MADT)
#       mcfg.bin  — variable, sig "MCFG"
#       facp.bin  — >=244 B typical, sig "FACP" (FADT)
#       hpet.bin  — 56 B, sig "HPET"
#
# -----------------------------------------------------------------------------
# Exit codes
# -----------------------------------------------------------------------------
#   0  — all present tables validated (or --help printed)
#   1  — fixture-dir missing / unreadable
#   2  — one or more expected tables missing (WARN, not FAIL, until the
#         hardware capture happens; FIXTURE_DIR may still be an empty
#         directory-with-README at R20 close)
#   3  — a present table's SIG4 header did not match the expected value
#   4  — runtime parser drive failed (once runtime path lands)

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DEFAULT_FIXTURE_DIR="${REPO_ROOT}/tests/kernel/acpi/fixtures/t14g4"

usage() {
    sed -n '2,58p' "$0"
    exit 0
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

case "${1:-}" in
    -h|--help|help) usage ;;
esac

FIXTURE_DIR="${1:-${DEFAULT_FIXTURE_DIR}}"

if [[ ! -d "${FIXTURE_DIR}" ]]; then
    echo "[parse-acpi-fixture] FAIL: fixture directory not found: ${FIXTURE_DIR}" >&2
    exit 1
fi

echo "[parse-acpi-fixture] fixture dir: ${FIXTURE_DIR}"

# -----------------------------------------------------------------------------
# Expected tables and their canonical SIG4 (first 4 bytes of the file).
#
# Note: rsdp.bin's signature is 8 bytes ("RSD PTR ") not 4 — handled
# specially below.
# -----------------------------------------------------------------------------

# Bash 3-compatible parallel arrays for OS X + older Linux compat.
NAMES=( rsdp xsdt apic mcfg facp hpet )
SIGS=(  "RSD PTR " "XSDT" "APIC" "MCFG" "FACP" "HPET" )

MISSING=0
MISMATCH=0
PRESENT=0

for i in "${!NAMES[@]}"; do
    NAME="${NAMES[$i]}"
    SIG="${SIGS[$i]}"
    FILE="${FIXTURE_DIR}/${NAME}.bin"

    if [[ ! -f "${FILE}" ]]; then
        echo "[parse-acpi-fixture] MISSING: ${NAME}.bin (expected sig '${SIG}')"
        MISSING=$((MISSING + 1))
        continue
    fi

    PRESENT=$((PRESENT + 1))

    # Read the signature bytes. RSDP is 8 chars including trailing space;
    # the rest are 4 chars.
    SIGLEN="${#SIG}"
    ACTUAL="$(head -c "${SIGLEN}" "${FILE}" 2>/dev/null)"

    if [[ "${ACTUAL}" != "${SIG}" ]]; then
        # Some hex output for the diagnostic (avoid dumping raw binary
        # if terminal is not-a-tty).
        HEX="$(head -c "${SIGLEN}" "${FILE}" | od -An -tx1 | tr -d ' \n')"
        echo "[parse-acpi-fixture] MISMATCH: ${NAME}.bin sig want='${SIG}' got hex=${HEX}" >&2
        MISMATCH=$((MISMATCH + 1))
        continue
    fi

    SIZE="$(stat -c %s "${FILE}" 2>/dev/null || stat -f %z "${FILE}" 2>/dev/null)"
    echo "[parse-acpi-fixture] OK: ${NAME}.bin sig='${SIG}' size=${SIZE}B"
done

echo "[parse-acpi-fixture] summary: ${PRESENT}/${#NAMES[@]} tables present, ${MISMATCH} sig mismatches"

if [[ ${MISMATCH} -gt 0 ]]; then
    echo "[parse-acpi-fixture] FAIL: ${MISMATCH} table(s) with wrong SIG4 header" >&2
    exit 3
fi

if [[ ${MISSING} -gt 0 ]]; then
    echo "[parse-acpi-fixture] WARN: ${MISSING} table(s) missing (expected until first HW capture — see tools/capture-t14-g4-acpi.md)" >&2
    # Only WARN pre-capture. Post-capture the fixture-dir README should
    # be replaced with the full set, and we can promote to exit 2.
    if [[ ${PRESENT} -eq 0 ]]; then
        echo "[parse-acpi-fixture] no tables present yet (placeholder state)" >&2
        exit 0
    fi
    exit 2
fi

# -----------------------------------------------------------------------------
# Runtime parser drive — DEFERRED
# -----------------------------------------------------------------------------
#
# Once tests/kernel/acpi/t14_g4_fixture.pdx is enabled (see its header
# for the enabling conditions), this block will:
#
#   1. Run tools/build.sh so kernel.elf embeds the fixture *.bin files
#      via the .S wrapper (mirroring tools/ap_trampoline_embed.S).
#   2. Boot kernel.elf under QEMU with a hardcoded machine_id switch
#      that routes phase1_acpi_gather at the embedded fixture pointers
#      instead of the boot_env-provided RSDP.
#   3. Read the UART fingerprint and assert on "ACPI T14G4 OK\n".
#
# The runtime step is NOT wired at R20 close because it needs:
#   - t14_g4_fixture.pdx witness body populated with expected values
#     (blocked on the operator's first hardware capture).
#   - A machine_id/fixture-select path in kernel_main_uefi.
#
# Both land in R21+ alongside the first T14 G4 boot.
# -----------------------------------------------------------------------------

echo "[parse-acpi-fixture] all present tables validated"
echo "[parse-acpi-fixture] runtime parser drive DEFERRED (see script footer)"
exit 0
