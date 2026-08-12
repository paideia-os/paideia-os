#!/usr/bin/env bash
# tools/sign-efi.sh — R28-M1-004 (#1001)
#
# Self-hosted PE32+ signing for PaideiaOS UEFI loaders. Takes an unsigned
# PE32+ `.efi` produced by paideia-as (typically build/uefi/uefi_stub.efi)
# and appends three synthesized PE sections — `.pdxsgn`, `.pdxpk`,
# `.pdxsig` — that carry the sign-and-verify pipeline the kernel-side
# self-verify path (src/kernel/boot/verify_self.pdx) consumes at boot.
#
# -----------------------------------------------------------------------------
# What "signing" means at R28
# -----------------------------------------------------------------------------
#
# The signing SUBSTRATE is intentionally scaffolding-level here, matching
# the R25.M5 PdxFS-lite dev-bypass discipline:
#
#   * The signature bytes are ML-DSA-65-shaped (3309 bytes per NIST FIPS
#     204 §5.4 sigma_bytes column) but populated with all zeros.
#   * The public-key bytes are ML-DSA-65-shaped (1952 bytes per FIPS 204
#     pk_bytes column) and taken from assets/keys/paideia-root-dev.pub
#     (all zeros — swapped for a real key at R32).
#   * Kernel-side verify accepts an all-zero signature under the dev-
#     bypass rule (see src/kernel/boot/verify_self.pdx) — the SAME rule
#     PdxFS-lite mount uses today (verify.pdx pdxfs_sb_verify_sig).
#
# What this tool DOES land at R28:
#
#   * The full pipeline shape — hash computation, section layout,
#     verifier lookup, PK/sig placement in the PE image — so the R32
#     retrofit is a one-line swap (compute real sig; leave everything
#     else unchanged). The dev-bypass convention lets us prove the
#     shape without the crypto substrate.
#   * A distinguishable "unsigned" vs "signed" state: an .efi that has
#     not been through this tool has no .pdxsgn/.pdxpk/.pdxsig sections
#     at all; the kernel-side verify sees "no section" and logs
#     "R28 EFI UNSIGNED (R33-gate off)". A signed image has the three
#     sections + magic and logs "R28 EFI SIGNATURE OK".
#
# -----------------------------------------------------------------------------
# Section layout (fixed VMAs — kernel-side verify_self.pdx hardcodes these)
# -----------------------------------------------------------------------------
#
#   .pdxsgn  VMA=0xd000  size=32 B   trailer (magic + metadata)
#   .pdxpk   VMA=0xe000  size=1952 B ML-DSA-65 public key
#   .pdxsig  VMA=0xf000  size=3309 B ML-DSA-65 signature (all-zero @ R28)
#
# The VMAs are chosen to sit past the uefi_stub's existing .rdata @ 0xc000
# (size 0x110) with a 4 KiB gap per section — well within the PE
# SectionAlignment of 0x1000. Firmware LoadImage maps them into memory at
# image_base + VMA and the kernel-side verify path reads them there.
#
# .pdxsgn trailer layout (32 bytes):
#
#     +0   u8[8]   magic = "PDXSGN01"
#     +8   u32     version              (1)
#     +12  u32     hash_algo_id         (1 = SHA3-256)
#     +16  u32     sig_algo_id          (1 = ML-DSA-65)
#     +20  u32     pk_size_bytes        (1952)
#     +24  u32     sig_size_bytes       (3309)
#     +28  u32     signed_range_end     (image file size at signing time)
#
# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
#
#   tools/sign-efi.sh --in PAIDEIA.EFI --out PAIDEIA.EFI.signed \
#                     [--pk assets/keys/paideia-root-dev.pub]
#
# --pk defaults to assets/keys/paideia-root-dev.pub. At R25.M5 both key
# bytes and sig bytes are all zero (dev-bypass); the --pk knob exists so
# R32 can drop a real 1952-byte ML-DSA-65 public-key file without
# editing this script.
#
# Exit codes:
#   0  ok
#   1  bad arguments / missing input
#   2  objcopy not found or PE modification failed
#   3  input file is not a PE32+ EFI application

set -euo pipefail

# -----------------------------------------------------------------------------
# ML-DSA-65 fixed sizes per NIST FIPS 204 §5.4 "Parameter Sets".
# -----------------------------------------------------------------------------

PDX_PK_BYTES=1952
PDX_SIG_BYTES=3309
PDX_TRAILER_BYTES=32

# -----------------------------------------------------------------------------
# Section VMAs — MUST stay in lockstep with verify_self.pdx constants:
#   VERIFY_SELF_PDXSGN_RVA / VERIFY_SELF_PDXPK_RVA / VERIFY_SELF_PDXSIG_RVA
# -----------------------------------------------------------------------------

PDXSGN_VMA=0xd000
PDXPK_VMA=0xe000
PDXSIG_VMA=0xf000

# -----------------------------------------------------------------------------
# CLI parse.
# -----------------------------------------------------------------------------

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$(pwd)")"
DEFAULT_PK="${REPO_ROOT}/assets/keys/paideia-root-dev.pub"

IN=""
OUT=""
PK="${DEFAULT_PK}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --in)  IN="${2:?}"; shift 2 ;;
        --out) OUT="${2:?}"; shift 2 ;;
        --pk)  PK="${2:?}"; shift 2 ;;
        -h|--help)
            sed -n '1,/^set -euo pipefail/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "[sign-efi] unknown argument: $1" >&2
            exit 1 ;;
    esac
done

if [[ -z "${IN}" || -z "${OUT}" ]]; then
    echo "[sign-efi] usage: $0 --in <unsigned.efi> --out <signed.efi> [--pk <pk-file>]" >&2
    exit 1
fi

if [[ ! -f "${IN}" ]]; then
    echo "[sign-efi] FAIL: input .efi does not exist: ${IN}" >&2
    exit 1
fi

if [[ ! -f "${PK}" ]]; then
    echo "[sign-efi] FAIL: public-key file does not exist: ${PK}" >&2
    exit 1
fi

if ! command -v objcopy >/dev/null 2>&1; then
    echo "[sign-efi] FAIL: objcopy not found — install binutils" >&2
    exit 2
fi

if ! command -v sha3sum >/dev/null 2>&1 && ! command -v openssl >/dev/null 2>&1; then
    echo "[sign-efi] WARN: neither sha3sum nor openssl found — hash log will be sha256 only" >&2
fi

# -----------------------------------------------------------------------------
# Precheck: input must be PE32+ EFI application.
# -----------------------------------------------------------------------------

FILE_KIND="$(file -b "${IN}")"
case "${FILE_KIND}" in
    *"PE32+ executable (EFI application) x86-64"*) ;;
    *)
        echo "[sign-efi] FAIL: ${IN} is not a PE32+ EFI application" >&2
        echo "[sign-efi]       file(1): ${FILE_KIND}" >&2
        exit 3
        ;;
esac

# -----------------------------------------------------------------------------
# Precheck: PK file must be exactly PDX_PK_BYTES.
# -----------------------------------------------------------------------------

PK_SIZE="$(stat -c %s "${PK}")"
if [[ "${PK_SIZE}" -ne "${PDX_PK_BYTES}" ]]; then
    echo "[sign-efi] FAIL: PK file size ${PK_SIZE} != expected ${PDX_PK_BYTES} (ML-DSA-65 pk_bytes)" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Stage the three blobs in a scratch dir.
# -----------------------------------------------------------------------------

TMP="$(mktemp -d -t sign-efi.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

PK_BLOB="${TMP}/pdxpk.bin"
SIG_BLOB="${TMP}/pdxsig.bin"
SGN_BLOB="${TMP}/pdxsgn.bin"

cp "${PK}" "${PK_BLOB}"

# ML-DSA-65 signature — all zeros at R25.M5 dev-bypass. R32 replaces this
# `head -c ... /dev/zero` with a `pdx-sign --alg ml-dsa-65 --key <priv> --in <hash>`
# invocation and pipes the raw signature bytes into ${SIG_BLOB}.
head -c "${PDX_SIG_BYTES}" /dev/zero > "${SIG_BLOB}"

# -----------------------------------------------------------------------------
# Compute the signed range: everything from file offset 0 up to but NOT
# including the appended sections. Since objcopy prepends the three new
# section HEADERS into the section table (bumping subsequent PointerTo-
# RawData values by 40 bytes each × 3 = 120 bytes) but the .text/.data/
# .rdata BYTES themselves shift accordingly, "the signed range" for
# reproducibility purposes is the ORIGINAL file size — the size before
# any modification. Signature validation at R32 will recompute the
# Authenticode hash over the mapped image, not the file bytes, so this
# scalar is informational at R28.
# -----------------------------------------------------------------------------

INPUT_SIZE="$(stat -c %s "${IN}")"

# -----------------------------------------------------------------------------
# Compute a structural hash of the input for the sign-run log. This is NOT
# the hash that R32 real crypto will consume (that is the PE Authenticode
# hash, per Microsoft PE image-hash spec §3.1). It is a reproducibility
# fingerprint: identical input .efi → identical hash.
# -----------------------------------------------------------------------------

if command -v sha3sum >/dev/null 2>&1; then
    INPUT_HASH="$(sha3sum -a 256 "${IN}" | awk '{print $1}')"
    HASH_KIND="sha3-256"
elif command -v openssl >/dev/null 2>&1 && openssl help dgst 2>&1 | grep -q sha3-256; then
    INPUT_HASH="$(openssl dgst -sha3-256 -r "${IN}" | awk '{print $1}')"
    HASH_KIND="sha3-256"
else
    INPUT_HASH="$(sha256sum "${IN}" | awk '{print $1}')"
    HASH_KIND="sha256 (sha3-256 unavailable — install libdigest-sha3-perl or a modern openssl)"
fi

# -----------------------------------------------------------------------------
# Build the .pdxsgn trailer blob (32 bytes) — see file preamble for layout.
# -----------------------------------------------------------------------------

# printf's %b interprets \OOO octal escapes; we build the fixed bytes with
# python-free portable shell arithmetic via `printf` on hex escapes.
# Layout: 8-byte magic + 5x u32 + 1x u32 signed_range_end = 32 bytes.

python3 - "${SGN_BLOB}" "${INPUT_SIZE}" <<'PY'
import struct, sys
out_path = sys.argv[1]
input_size = int(sys.argv[2])
magic = b"PDXSGN01"
version = 1
hash_algo_id = 1     # SHA3-256
sig_algo_id  = 1     # ML-DSA-65
pk_size = 1952
sig_size = 3309
signed_range_end = input_size
trailer = magic + struct.pack("<IIIIII", version, hash_algo_id, sig_algo_id,
                              pk_size, sig_size, signed_range_end)
assert len(trailer) == 32, f"trailer size {len(trailer)} != 32"
with open(out_path, "wb") as f:
    f.write(trailer)
PY

# -----------------------------------------------------------------------------
# objcopy: append three sections with fixed VMAs.
# -----------------------------------------------------------------------------

# Section flags: alloc + load + contents + readonly + data = "READ-only
# initialized data section that firmware LoadImage MUST map into memory".
# This maps to PE Characteristics = IMAGE_SCN_CNT_INITIALIZED_DATA (0x40) |
# IMAGE_SCN_MEM_READ (0x40000000).

echo "[sign-efi] input:     ${IN} (${INPUT_SIZE} bytes, ${HASH_KIND}=${INPUT_HASH})"
echo "[sign-efi] output:    ${OUT}"
echo "[sign-efi] pk:        ${PK} (${PK_SIZE} bytes)"
echo "[sign-efi] sig:       (all-zero @ R25.M5 dev-bypass; R32 substitutes real ML-DSA-65 bytes)"
echo "[sign-efi] adding .pdxsgn/.pdxpk/.pdxsig via objcopy"

mkdir -p "$(dirname "${OUT}")"

objcopy \
    --add-section .pdxsgn="${SGN_BLOB}" \
    --set-section-flags .pdxsgn=alloc,readonly,load,contents,data \
    --change-section-vma .pdxsgn="${PDXSGN_VMA}" \
    --change-section-lma .pdxsgn="${PDXSGN_VMA}" \
    --add-section .pdxpk="${PK_BLOB}" \
    --set-section-flags .pdxpk=alloc,readonly,load,contents,data \
    --change-section-vma .pdxpk="${PDXPK_VMA}" \
    --change-section-lma .pdxpk="${PDXPK_VMA}" \
    --add-section .pdxsig="${SIG_BLOB}" \
    --set-section-flags .pdxsig=alloc,readonly,load,contents,data \
    --change-section-vma .pdxsig="${PDXSIG_VMA}" \
    --change-section-lma .pdxsig="${PDXSIG_VMA}" \
    "${IN}" "${OUT}"

# -----------------------------------------------------------------------------
# Post-check: output must still be a valid PE32+ EFI application with the
# three new sections present at the expected VMAs.
# -----------------------------------------------------------------------------

OUT_KIND="$(file -b "${OUT}")"
case "${OUT_KIND}" in
    *"PE32+ executable"*"EFI application"*) ;;
    *"PE32+ executable"*) ;;   # objcopy may drop the "EFI application" hint
    *)
        echo "[sign-efi] FAIL: output ${OUT} is not PE32+: ${OUT_KIND}" >&2
        exit 2
        ;;
esac

# Verify each new section is present at its expected VMA. objdump -h output
# formatting: 6-column table with Idx / Name / Size / VMA / LMA / File off.
verify_section() {
    local name="$1" expected_vma="$2" expected_size="$3"
    local hex_vma actual_size line
    hex_vma="$(printf '%016x' "${expected_vma}")"
    line="$(objdump -h "${OUT}" 2>/dev/null | awk -v n="${name}" '$2 == n')"
    if [[ -z "${line}" ]]; then
        echo "[sign-efi] FAIL: section ${name} not found in ${OUT}" >&2
        exit 2
    fi
    if ! grep -q " ${hex_vma} " <<<"${line}"; then
        echo "[sign-efi] FAIL: section ${name} VMA not ${hex_vma}: ${line}" >&2
        exit 2
    fi
    actual_size="$(awk '{print $3}' <<<"${line}")"
    if [[ "$((0x${actual_size}))" -ne "${expected_size}" ]]; then
        echo "[sign-efi] FAIL: section ${name} size 0x${actual_size} != ${expected_size}" >&2
        exit 2
    fi
    echo "[sign-efi]   ${name}: VMA=0x${hex_vma} size=${expected_size} OK"
}

verify_section .pdxsgn "${PDXSGN_VMA}" "${PDX_TRAILER_BYTES}"
verify_section .pdxpk  "${PDXPK_VMA}"  "${PDX_PK_BYTES}"
verify_section .pdxsig "${PDXSIG_VMA}" "${PDX_SIG_BYTES}"

OUT_SIZE="$(stat -c %s "${OUT}")"
echo "[sign-efi] OK: ${OUT} (${OUT_SIZE} bytes)"
