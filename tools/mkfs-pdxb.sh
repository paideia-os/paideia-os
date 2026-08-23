#!/usr/bin/env bash
# tools/mkfs-pdxb.sh — R53.M1-002 (#1731)
#
# Dev-host wrapper around the paideia-as-compiled `mkfs-pdxb` binary
# (R53.M1-001, sibling issue #1730). Path A of §3.1 of
# design/tooling/volume-lifecycle-mechanism.md — a host-side pre-format
# that writes a deterministic PDXB layout to a plain file the QEMU
# invocation will attach as an NVMe drive.
#
# Wrapper responsibilities (thin — the binary owns all layout logic):
#
#   1. Materialise the backing file at the requested MiB size via
#      `dd if=/dev/zero`. Only creates the file if it does not already
#      exist; `--force` re-`dd`s from scratch. Never destroys an
#      existing file without --force — a developer's `pdxb-root.img`
#      is their working state.
#   2. Locate the `mkfs-pdxb` binary that #1730 stages under
#      build/tools/mkfs-pdxb (or the design §3.1 layout at
#      build/mkfs-pdxb — either resolves). If the tool has not been
#      built yet, exit with a clear diagnostic that names both search
#      paths and points at the R53.M1-001 issue — this wrapper is
#      installable ahead of the binary, and its M1-002/-001 split is
#      deliberate so a partial checkout does not break either side.
#   3. Invoke the binary with `--file`, `--size-mib`, and — if the
#      corresponding env vars are set — `--uuid` (PDXB_UUID) and
#      `--sig-key` (PDXB_SIG_KEY). All three env vars keep the
#      wrapper stateless; the smoke orchestrator (R53.M4-002) sets
#      them from its own configuration.
#   4. Emit `MKFS PDXB WRAPPER OK` on success. The smoke witness
#      greps for this fingerprint to distinguish wrapper-level
#      success from tool-level (`MKFS PDXB OK`, emitted by the
#      binary itself once M1-001 lands).
#
# Env vars (all optional):
#   PDXB_IMAGE_SIZE_MIB   Backing-image size in MiB. Default: 64.
#   PDXB_UUID             32-char hex UUID (dashes optional). If unset,
#                         the binary derives one deterministically from
#                         the repo HEAD (R53.M1-005).
#   PDXB_SIG_KEY          Path to ML-DSA-65 private key for signing the
#                         superblock. If unset, the binary writes a
#                         zero signature + SIG_UNSIGNED flag (dev-mode,
#                         accepted under PAIDEIA_DEV_UNSIGNED_ACCEPT=1).
#
# Exit status: 0 on success; 2 on argument or config error; 3 if the
# mkfs-pdxb binary is not built yet; whatever the binary returns on
# tool failure.

set -euo pipefail

usage() {
  cat <<'USAGE'
mkfs-pdxb.sh — dev-host wrapper for the mkfs-pdxb binary.

Usage:
  tools/mkfs-pdxb.sh <image-path> [--force]

Args:
  <image-path>          Destination image file. Created if missing.

Options:
  --force               Truncate <image-path> if it already exists and
                        re-`dd` a fresh zero-filled backing file before
                        running mkfs. Default: existing file is left
                        alone (mkfs-pdxb overwrites its regions in
                        place; the tail data region is preserved).
  -h, --help            Print this help and exit.

Environment:
  PDXB_IMAGE_SIZE_MIB   Backing-image size in MiB. Default: 64.
  PDXB_UUID             32-char hex UUID (dashes optional).
  PDXB_SIG_KEY          Path to ML-DSA-65 private key.

Exit status: 0 on success, non-zero on any error.
USAGE
}

# ---------------------------------------------------------------------------
# CLI parse.
# ---------------------------------------------------------------------------

IMAGE_PATH=""
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --force)   FORCE=1; shift ;;
    --)        shift; break ;;
    --*)
      echo "mkfs-pdxb.sh: unknown flag: $1" >&2
      usage >&2
      exit 2 ;;
    *)
      if [[ -n "$IMAGE_PATH" ]]; then
        echo "mkfs-pdxb.sh: unexpected extra positional arg: $1" >&2
        usage >&2
        exit 2
      fi
      IMAGE_PATH="$1"; shift ;;
  esac
done

if [[ -z "$IMAGE_PATH" ]]; then
  echo "mkfs-pdxb.sh: <image-path> is required" >&2
  usage >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Config from env.
# ---------------------------------------------------------------------------

SIZE_MIB="${PDXB_IMAGE_SIZE_MIB:-64}"
if ! [[ "$SIZE_MIB" =~ ^[0-9]+$ ]] || (( SIZE_MIB < 1 )); then
  echo "mkfs-pdxb.sh: PDXB_IMAGE_SIZE_MIB must be a positive integer" \
       "(got '$SIZE_MIB')" >&2
  exit 2
fi

if [[ -n "${PDXB_SIG_KEY:-}" && ! -r "${PDXB_SIG_KEY}" ]]; then
  echo "mkfs-pdxb.sh: PDXB_SIG_KEY points at unreadable file:" \
       "${PDXB_SIG_KEY}" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Locate the mkfs-pdxb binary. #1730 lands the paideia-as source at
# src/tools/mkfs-pdxb/main.pdx; the compile stage puts the binary at
# build/tools/mkfs-pdxb (mirrors how R48+ tools land). Fall back to
# build/mkfs-pdxb — the exact path the design §3.1 snippet uses — so
# either layout resolves without a follow-up wrapper edit.
# ---------------------------------------------------------------------------

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MKFS_BIN=""
for candidate in \
    "${REPO_ROOT}/build/tools/mkfs-pdxb" \
    "${REPO_ROOT}/build/mkfs-pdxb"; do
  if [[ -x "$candidate" ]]; then
    MKFS_BIN="$candidate"
    break
  fi
done

if [[ -z "$MKFS_BIN" ]]; then
  {
    echo "mkfs-pdxb.sh: mkfs-pdxb binary not found."
    echo "  Looked for:"
    echo "    ${REPO_ROOT}/build/tools/mkfs-pdxb"
    echo "    ${REPO_ROOT}/build/mkfs-pdxb"
    echo "  Land R53.M1-001 (#1730 — src/tools/mkfs-pdxb/main.pdx) then"
    echo "  re-run 'bash tools/build.sh'."
  } >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# Materialise the backing file.
# ---------------------------------------------------------------------------

IMAGE_DIR="$(dirname -- "$IMAGE_PATH")"
if [[ ! -d "$IMAGE_DIR" ]]; then
  mkdir -p -- "$IMAGE_DIR"
fi

if [[ -f "$IMAGE_PATH" && ${FORCE} -eq 1 ]]; then
  rm -f -- "$IMAGE_PATH"
fi

if [[ ! -f "$IMAGE_PATH" ]]; then
  dd if=/dev/zero of="$IMAGE_PATH" bs=1M count="$SIZE_MIB" status=none
fi

# ---------------------------------------------------------------------------
# Invoke mkfs-pdxb.
# ---------------------------------------------------------------------------

MKFS_ARGS=( --file "$IMAGE_PATH" --size-mib "$SIZE_MIB" )

if [[ -n "${PDXB_UUID:-}" ]]; then
  MKFS_ARGS+=( --uuid "$PDXB_UUID" )
fi
if [[ -n "${PDXB_SIG_KEY:-}" ]]; then
  MKFS_ARGS+=( --sig-key "$PDXB_SIG_KEY" )
fi

"$MKFS_BIN" "${MKFS_ARGS[@]}"

echo "MKFS PDXB WRAPPER OK"
exit 0
