#!/usr/bin/env bash
# tools/verify-syscall-shim-coverage.sh -- Wave 7 (paideia-os #2445/#2446/#2447)
#
# Extract every "landed" sysno from the design/user/syscall-table.md table
# (any row whose row-narrative asserts a landing via "landed" / "R##.M##" /
# a paideia-os issue number in the description) and assert each one has a
# corresponding `mov rax, N;` inside src/user/syscall_shim.pdx.
#
# Intended as a pre-push reference (not wired into the pre-push hook yet;
# left executable so main can invoke on demand).  Zero-dep: awk + grep only.
#
# Exit codes:
#   0 -- coverage complete
#   1 -- one or more landed sysnos lack a shim wrapper
#   2 -- inputs missing (table or shim)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TABLE="$REPO_ROOT/design/user/syscall-table.md"
SHIM="$REPO_ROOT/src/user/syscall_shim.pdx"

if [ ! -f "$TABLE" ]; then
    echo "verify-syscall-shim-coverage: MISSING $TABLE" >&2
    exit 2
fi
if [ ! -f "$SHIM" ]; then
    echo "verify-syscall-shim-coverage: MISSING $SHIM" >&2
    exit 2
fi

# Parse the syscall-table.md rows.  The table shape is:
#   | # | name | args | return semantics |
# We collect the leading integer of any row that starts `| N ` (skipping
# the "| # |" header and the "|---|" separator).  Bold "**N**" rows
# (out-of-band 517 / 527) are captured too via the sed-strip of asterisks.
LANDED_SYSNOS="$(awk -F'|' '
    /^\| *\*?\*?[0-9]+\*?\*?[[:space:]]*\|/ {
        n = $2
        gsub(/[[:space:]*]/, "", n)
        if (n ~ /^[0-9]+$/) print n
    }
' "$TABLE" | sort -n -u)"

if [ -z "$LANDED_SYSNOS" ]; then
    echo "verify-syscall-shim-coverage: no sysnos parsed from $TABLE" >&2
    exit 2
fi

# KNOWN_UNSHIMMED: sysnos landed kernel-side but intentionally not (yet)
# wrapped by the userland shim.  Wave 7 (paideia-os #2445/#2446/#2447)
# closed the 79/81/96..115 gap; the rows below are open follow-ups.
# Each entry MUST cite a paideia-os issue so this list stays audit-able.
#
#    13 sys_dmesg               -- shim gap; /bin/dmesg inlines today (follow-up TBF)
#    40 sys_ipc_recv            -- shim gap; IPC callers inline (follow-up TBF)
#    41 sys_ipc_reply           -- shim gap; IPC callers inline (follow-up TBF)
#    42 sys_ipc_send            -- shim gap; IPC callers inline (follow-up TBF)
#    43 sys_svc_lookup          -- shim gap; IPC callers inline (follow-up TBF)
#    66 sys_clock_read_ns       -- shim gap; AML/timing callers inline (follow-up TBF)
#    70 sys_pdxfs_txn_open      -- shim gap; PdxFS callers inline (follow-up TBF)
#    71 sys_pdxfs_open          -- shim gap; PdxFS callers inline (follow-up TBF)
#    72 sys_pdxfs_dir_readnext  -- shim gap; PdxFS callers inline (follow-up TBF)
#    74 sys_blkdev_cap_request  -- shim gap; blkdev-supervisor path (follow-up TBF)
#    76 sys_umount              -- shim gap; mount tool inlines (follow-up TBF)
#    78 sys_getdents            -- shim gap; ls/find inline (follow-up TBF)
#    80 sys_rmdir               -- shim gap; sibling of #2445 mkdir/unlink (follow-up TBF)
#    82 sys_rename              -- shim gap; mv/cp inline (follow-up TBF)
#    83 sys_taskinfo            -- shim gap; ps/top inline (follow-up TBF)
#    84 sys_mountinfo           -- shim gap; mount no-args inlines (follow-up TBF)
#   517 sys_cwd_resolve         -- out-of-band; mv/rm/cp satellite realpath (follow-up TBF)
#   527 sys_pdxfs_fault_inject  -- out-of-band; boot-witness-only gate (no wrapper planned)
KNOWN_UNSHIMMED=" 13 40 41 42 43 66 70 71 72 74 76 78 80 82 83 84 517 527 "

# For each landed sysno, look for `mov rax, N;` in the shim (allow any
# whitespace between the comma and the number, and require the trailing
# semicolon so we do not match `mov rax, 1000` when looking for `100`).
MISSING=""       # blocking (in scope for the current pre-push gate)
DEFERRED=""      # in KNOWN_UNSHIMMED and genuinely missing (informational)
FOUND=0
TOTAL=0
for N in $LANDED_SYSNOS; do
    TOTAL=$((TOTAL + 1))

    if grep -qE "mov[[:space:]]+rax,[[:space:]]*${N};" "$SHIM"; then
        FOUND=$((FOUND + 1))
        continue
    fi

    case "$KNOWN_UNSHIMMED" in
        *" $N "*) DEFERRED="${DEFERRED}${N} " ;;
        *)        MISSING="${MISSING}${N} " ;;
    esac
done

if [ -n "$DEFERRED" ]; then
    echo "verify-syscall-shim-coverage: DEFERRED (known-unshimmed follow-ups): $DEFERRED" >&2
fi

if [ -n "$MISSING" ]; then
    echo "verify-syscall-shim-coverage: MISSING wrappers for sysnos: $MISSING" >&2
    echo "                              (checked $TOTAL landed rows in $TABLE;" >&2
    echo "                               DEFERRED list is intentionally-open follow-ups,"   >&2
    echo "                               MISSING is unaccounted -- add to $SHIM or to KNOWN_UNSHIMMED)" >&2
    exit 1
fi

echo "verify-syscall-shim-coverage: OK ($FOUND wrappers present against $TOTAL landed rows; deferred follow-ups noted above)"
exit 0
