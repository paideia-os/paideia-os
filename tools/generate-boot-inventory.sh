#!/usr/bin/env bash
# R49.M1-001 (#1571) — mechanical boot-message inventory generator.
#
# Writes build/boot-message-inventory.tsv with one row per emit site
# under src/kernel/**, src/user/** and tools/boot_stub.S. Columns:
#
#   file<TAB>line<TAB>primitive<TAB>message_symbol<TAB>class
#
# Deterministic: the same commit produces the same TSV. Classification
# rules follow design/kernel/boot-message-inventory.md §4. Not run by
# tools/build.sh (a stale TSV does not break anything).
#
# Usage:
#   $ bash tools/generate-boot-inventory.sh
#   $ column -t -s$'\t' build/boot-message-inventory.tsv | less

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BUILD_DIR="${REPO_ROOT}/build"
OUT_TSV="${BUILD_DIR}/boot-message-inventory.tsv"

mkdir -p "${BUILD_DIR}"

echo "[inventory] scanning src/kernel + src/user + tools/boot_stub.S"

{
    printf 'file\tline\tprimitive\tmessage_symbol\tclass\n'

    # Source (1)+(2): klog_s1* and klog_emit_core sites.
    grep -rEn 'call (klog_emit_core|klog_s1(_(x|d)[0-9]+(_(x|d)[0-9]+)?)?)\b' \
        "${REPO_ROOT}/src/kernel" "${REPO_ROOT}/src/user" 2>/dev/null | \
        awk -F: '{
            file=$1; line=$2; rest="";
            for (i=3; i<=NF; i++) rest = rest (i==3 ? "" : ":") $i;
            prim=rest; sub(/^[^ ]* call /, "", prim); sub(/;.*$/, "", prim);
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", prim);
            print file "\t" line "\t" prim "\t-\tDEBUG";
        }'

    # Source (3): uart_puts sites under src/kernel/**.
    grep -rEn 'call uart_puts\b' "${REPO_ROOT}/src/kernel" 2>/dev/null | \
        awk -F: '{
            file=$1; line=$2;
            print file "\t" line "\tuart_puts\t-\tDEBUG";
        }'

    # Source (4): boot_stub.S message fixtures. Symbol name + first
    # line of its .ascii block. banner_art and banner_msg tag as
    # RELEASE (banner_msg is muted at the emit-site call level but
    # is the fixture the release banner spirit reuses); everything
    # else tags as DEBUG per §4.
    awk '
        /^\.global / { sym=$2; next }
        /^[a-zA-Z_][a-zA-Z0-9_]*:/ {
            gsub(/:/, "", $1);
            cur=$1;
            if (cur == sym) { pending=cur; }
            else { pending="" }
            next
        }
        /^\s*\.ascii/ && pending != "" {
            klass = (pending == "banner_art" || pending == "banner_msg") ? "RELEASE" : "DEBUG";
            print FILENAME "\t" NR "\tboot_stub_ascii\t" pending "\t" klass;
            pending="";
        }
    ' "${REPO_ROOT}/tools/boot_stub.S"

} > "${OUT_TSV}"

TOTAL=$(($(wc -l < "${OUT_TSV}") - 1))
RELEASE_COUNT=$(awk -F'\t' 'NR>1 && $5=="RELEASE"' "${OUT_TSV}" | wc -l)
DEBUG_COUNT=$(awk -F'\t' 'NR>1 && $5=="DEBUG"' "${OUT_TSV}" | wc -l)
REMOVE_COUNT=$(awk -F'\t' 'NR>1 && $5=="REMOVE"' "${OUT_TSV}" | wc -l)

echo "[inventory] wrote ${OUT_TSV} (rows=${TOTAL})"
echo "[inventory] release=${RELEASE_COUNT} debug=${DEBUG_COUNT} remove=${REMOVE_COUNT}"
