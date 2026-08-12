#!/usr/bin/env bash
# Verification canary for src/kernel/core/syscall/dispatch.pdx (R17-M0-668 / #668).
# Verifies syscall_dispatch function wires IDs {0,1,2,3,32,39,56,60,61} to real bodies.
# Exits with "KERNEL SYSCALL DISPATCH OK" or "KERNEL SYSCALL DISPATCH FAIL".
#
# #1013 (2026-08-09): de-flake.
#
# Root cause of the pre-#1013 flake: every check used
#     if echo "$DISPATCH" | grep -q "..."
# under `set -o pipefail`. `grep -q` closes stdin on the first match, so a
# sufficiently-scheduled `echo` returns EPIPE / exits 141, pipefail promotes
# that to a pipeline failure, and the `if` reads as false — a check that
# actually matched is reported as [FAIL]. This is fully independent of
# kernel.elf's contents (md5sum-identical elves flaked at ~16%), and the
# failing check ID drifts run-to-run because the race is scheduler-driven.
#
# Fix: (1) extract the syscall_dispatch disassembly into a tempfile once and
# grep the file directly — no `echo "$var" | ...` pipeline at all, so no
# SIGPIPE race is possible; (2) for the two multi-stage checks that used
# `grep -A N | grep -qE ...`, collapse to a single-pass `awk` so no
# grep-to-grep pipe exists either; (3) cache the "OK" verdict keyed on
# (kernel.elf md5 + this script's md5) under build/.verify-cache/ so
# repeated invocations against an identical elf skip re-verification
# entirely — dropping the flake window for cache-hit calls to zero.
set -euo pipefail

ELF="${1:-build/kernel.elf}"
FAIL=0
CHECKS_PASSED=0
TOTAL_CHECKS=19

if [[ ! -f "$ELF" ]]; then
    echo "KERNEL SYSCALL DISPATCH FAIL" >&2
    echo "ELF file not found: $ELF" >&2
    exit 1
fi

# ---- md5-keyed cache -------------------------------------------------------
# The dispatch verifier is a pure function of (kernel.elf contents, this
# script's own text). If both md5s match a prior success, the result is
# guaranteed to match too — skip the whole extraction+grep pipeline.
ELF_MD5=$(md5sum "$ELF"   | awk '{print $1}')
SCRIPT_MD5=$(md5sum "$0"  | awk '{print $1}')
CACHE_DIR="$(dirname "$ELF")/.verify-cache/syscall-dispatch"
CACHE_FILE="${CACHE_DIR}/${ELF_MD5}-${SCRIPT_MD5}.ok"
if [[ -f "$CACHE_FILE" ]]; then
    echo "[verify] cache hit (${ELF_MD5:0:12} / script ${SCRIPT_MD5:0:8}) — skipping re-verification"
    echo "Verification: ${TOTAL_CHECKS} / ${TOTAL_CHECKS} checks passed (cached)"
    echo "KERNEL SYSCALL DISPATCH OK"
    exit 0
fi

# ---- extract syscall_dispatch to a tempfile --------------------------------
# One extraction, then every check greps the file. No `echo "$DISPATCH" | grep`
# pipelines, so no SIGPIPE-under-pipefail race.
DISPATCH_FILE=$(mktemp -t verify-syscall-dispatch.XXXXXX)
trap 'rm -f "$DISPATCH_FILE"' EXIT

objdump -d -M intel "$ELF" 2>/dev/null | \
    awk '/^[0-9a-f]+ <syscall_dispatch>:$/,/^[0-9a-f]+ <sys_close_body>:$/ {print}' | \
    head -n -1 > "$DISPATCH_FILE"

if [[ ! -s "$DISPATCH_FILE" ]]; then
    echo "KERNEL SYSCALL DISPATCH FAIL" >&2
    echo "syscall_dispatch function not found" >&2
    exit 1
fi

echo "[verify] syscall_dispatch function found"

# Check 1: Bounds check at 61
if grep -q "cmp.*0x3d" "$DISPATCH_FILE"; then
    echo "[ok]   Bounds check: cmp rdi, 61"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] Bounds check missing"
    FAIL=1
fi

# Check 2: ID 0 route and sys_read_body call
if grep -q "cmp.*0x0" "$DISPATCH_FILE" && grep -q "sys_read_body" "$DISPATCH_FILE"; then
    echo "[ok]   ID 0 (read): routed to sys_read_body"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 0 (read): missing routing or sys_read_body call"
    FAIL=1
fi

# Check 3: ID 1 route and dispatch_write_uart OR sys_write_body
if grep -q "cmp.*0x1" "$DISPATCH_FILE" && \
   { grep -q "sys_write_body" "$DISPATCH_FILE" || grep -q "uart_putc" "$DISPATCH_FILE"; }; then
    echo "[ok]   ID 1 (write): routed (fast-path or sys_write_body present)"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 1 (write): missing routing or body"
    FAIL=1
fi

# Check 4: ID 2 route and sys_open_body
if grep -q "cmp.*0x2" "$DISPATCH_FILE" && grep -q "sys_open_body" "$DISPATCH_FILE"; then
    echo "[ok]   ID 2 (open): routed to sys_open_body"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 2 (open): missing routing or sys_open_body call"
    FAIL=1
fi

# Check 5: ID 3 route and sys_close_body
if grep -q "cmp.*0x3" "$DISPATCH_FILE" && grep -q "sys_close_body" "$DISPATCH_FILE"; then
    echo "[ok]   ID 3 (close): routed to sys_close_body"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 3 (close): missing routing or sys_close_body call"
    FAIL=1
fi

# Check 6: ID 32 (0x20) route and sys_dup2_body
if grep -q "cmp.*0x20" "$DISPATCH_FILE" && grep -q "sys_dup2_body" "$DISPATCH_FILE"; then
    echo "[ok]   ID 32 (dup2): routed to sys_dup2_body"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 32 (dup2): missing routing or sys_dup2_body call"
    FAIL=1
fi

# Check 7: ID 39 (0x27) route and inline getpid
if grep -q "cmp.*0x27" "$DISPATCH_FILE"; then
    # Look for the inline getpid pattern: 8b 00 is mov eax, [rax]
    # The instruction appears after the dispatch_getpid label in the extracted section
    if grep -q "8b 00" "$DISPATCH_FILE"; then
        echo "[ok]   ID 39 (getpid): inline dispatch present"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        echo "[FAIL] ID 39 (getpid): inline dispatch missing"
        FAIL=1
    fi
else
    echo "[FAIL] ID 39 (getpid): cmp missing"
    FAIL=1
fi

# Check 8: ID 56 (0x38) route and sys_fork_body
if grep -q "cmp.*0x38" "$DISPATCH_FILE" && grep -q "sys_fork_body" "$DISPATCH_FILE"; then
    echo "[ok]   ID 56 (fork): routed to sys_fork_body"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 56 (fork): missing routing or sys_fork_body call"
    FAIL=1
fi

# Check 9: ID 59 (0x3b) route to sys_execve_shim (R17-M0-671 / #671).
# Prior to #671 this checked for routing to dispatch_enosys; the shim now
# owns sysno 59, so we require both the cmp gate AND a call to
# sys_execve_shim in the dispatcher body.
if grep -q "cmp.*0x3b" "$DISPATCH_FILE" && grep -q "sys_execve_shim" "$DISPATCH_FILE"; then
    echo "[ok]   ID 59 (execve): routes to sys_execve_shim"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 59 (execve): cmp missing or sys_execve_shim call missing"
    FAIL=1
fi

# Check 10: ID 60 (0x3c) route and sys_exit_body
if grep -q "cmp.*0x3c" "$DISPATCH_FILE" && grep -q "sys_exit_body" "$DISPATCH_FILE"; then
    echo "[ok]   ID 60 (exit): routed to sys_exit_body"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 60 (exit): missing routing or sys_exit_body call"
    FAIL=1
fi

# Check 11: ID 60 has hlt loop or klog_panic (M4-002: #693)
# Single-pass awk: seed a 10-line countdown on `sys_exit_body`, then look for
# hlt|klog_panic within that window. Collapsing what used to be
# `grep -A 10 | grep -qE` avoids any grep-to-grep SIGPIPE race under pipefail.
if awk '/sys_exit_body/ {c=10} c-->0 && /hlt|klog_panic/ {found=1; exit} END {exit !found}' "$DISPATCH_FILE"; then
    echo "[ok]   ID 60 (exit): halt loop present after body"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 60 (exit): halt loop missing"
    FAIL=1
fi

# Check 12: ID 61 (0x3d second occurrence) route and sys_wait_body
if grep -q "sys_wait_body" "$DISPATCH_FILE"; then
    echo "[ok]   ID 61 (wait4): routed to sys_wait_body"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 61 (wait4): missing routing or sys_wait_body call"
    FAIL=1
fi

# Check 13: ID 61 has wstatus writeback.
# #737 fix: the raw `mov [rsi], edx` under kernel CR3 (which hit the boot
# PML4's low identity map instead of init's user PML4 frame) has been
# replaced with a `call user_write_u32_via_walk` — a strict-KPTI-safe
# helper that walks _current_tcb.user_pml4_va per byte and stores via the
# kernel higher-half identity map. Same defect class as #724 D4 / #730
# D10c / #730 D10d. Any of the three acceptable discipline shapes counts
# as a valid writeback:
#   (a) legacy raw store (pre-#737) — either DWORD or QWORD, per #1251
#   (b) #737 helper call — `call ... user_write_u32_via_walk`
# #724 D5a widened the window between the sys_wait_body call and the
# writeback: on the rax==0 branch the dispatcher now performs sched_block
# + wait_result_{pid,status} reads + push/pop discipline before the
# writeback, so a 40-line window comfortably covers both the direct-return
# (reap or ECHILD) path and the block-then-resume path.
#
# Single-pass awk replaces the pre-#1013 `grep -A 40 | grep -qE` pipeline
# to eliminate the residual grep-to-grep SIGPIPE-under-pipefail race.
if awk '
    /sys_wait_body/ {c=40}
    c-->0 && (/mov[[:space:]]+(DWORD|QWORD) PTR \[rsi\]/ || /call.*user_write_u32_via_walk/) {found=1; exit}
    END {exit !found}
' "$DISPATCH_FILE"; then
    echo "[ok]   ID 61 (wait4): wstatus writeback present"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 61 (wait4): wstatus writeback missing"
    FAIL=1
fi

# Check 14: _current_tcb referenced enough times
tcb_count=$(grep -c "_current_tcb" "$DISPATCH_FILE" || echo "0")
if [[ $tcb_count -ge 5 ]]; then
    echo "[ok]   _current_tcb: referenced $tcb_count times (>=5 expected)"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] _current_tcb: referenced only $tcb_count times (need >=5)"
    FAIL=1
fi

# Check 15: dispatch_enosys returns -38 (0xFFFFFFFFFFFFFFDA)
if grep -q "0xffffffffffffffda" "$DISPATCH_FILE"; then
    echo "[ok]   dispatch_enosys: returns correct ENOSYS value"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] dispatch_enosys: does not return correct ENOSYS value"
    FAIL=1
fi

# Check 16: ID 40 (0x28) route to sys_ipc_recv_body (R20b.M3-001 / #1558).
# The dispatch shim performs two user_ptr_ok gates on user_hdr_va +
# user_payload_va (per design/ipc/userspace-server-substrate.md §4.3 and
# the #741 defense-in-depth pattern used by dispatch_read / dispatch_write
# / dispatch_dmesg), then calls sys_ipc_recv_body with the raw endpoint_id
# (cap-lookup deferred to R20b.M4 loader_seed_caps). Requires both the
# cmp gate AND a call to sys_ipc_recv_body in the dispatcher body.
if grep -q "cmp.*0x28" "$DISPATCH_FILE" && grep -q "sys_ipc_recv_body" "$DISPATCH_FILE"; then
    echo "[ok]   ID 40 (ipc_recv): routes to sys_ipc_recv_body"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 40 (ipc_recv): cmp missing or sys_ipc_recv_body call missing"
    FAIL=1
fi

# Check 17: ID 41 (0x29) route to sys_ipc_reply_body (R20b.M3-002 / #1559).
# The dispatch shim mirrors dispatch_ipc_recv's user_ptr_ok gate pair
# (hdr_va, payload_va) — the reply body's bit-7 pre-check + delegation
# to sys_ipc_send_body is a body-layer concern; the shim only validates
# user VAs and marshals the SysV args.
if grep -q "cmp.*0x29" "$DISPATCH_FILE" && grep -q "sys_ipc_reply_body" "$DISPATCH_FILE"; then
    echo "[ok]   ID 41 (ipc_reply): routes to sys_ipc_reply_body"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 41 (ipc_reply): cmp missing or sys_ipc_reply_body call missing"
    FAIL=1
fi

# Check 18: ID 42 (0x2a) route to sys_ipc_send_body (R20b.M3-002 / #1559).
# Same shim shape as dispatch_ipc_recv / dispatch_ipc_reply — two
# user_ptr_ok gates + marshal + body call. Cap-lookup deferred to R20b.M4.
if grep -q "cmp.*0x2a" "$DISPATCH_FILE" && grep -q "sys_ipc_send_body" "$DISPATCH_FILE"; then
    echo "[ok]   ID 42 (ipc_send): routes to sys_ipc_send_body"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 42 (ipc_send): cmp missing or sys_ipc_send_body call missing"
    FAIL=1
fi

# Check 19: ID 43 (0x2b) route to sys_svc_lookup_body (R20b.M3-003 / #1560).
# The dispatch shim performs a single user_ptr_ok gate on (user_name_va,
# name_len) — the body then owns the KPTI-safe name-buffer bounce via
# user_read_bytes_via_walk and the client cap-slot mint. Closes the
# R20b.M3 (server-process model) milestone (last of sysnos 40..43).
# Requires both the cmp gate AND a call to sys_svc_lookup_body in the
# dispatcher body.
if grep -q "cmp.*0x2b" "$DISPATCH_FILE" && grep -q "sys_svc_lookup_body" "$DISPATCH_FILE"; then
    echo "[ok]   ID 43 (svc_lookup): routes to sys_svc_lookup_body"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 43 (svc_lookup): cmp missing or sys_svc_lookup_body call missing"
    FAIL=1
fi

# Summary
echo ""
echo "Verification: $CHECKS_PASSED / $TOTAL_CHECKS checks passed"

if [[ $FAIL -eq 0 ]]; then
    # Success — memoize this (elf_md5, script_md5) so a re-invocation against
    # the same kernel.elf under the same verifier code short-circuits.
    mkdir -p "$CACHE_DIR"
    : > "$CACHE_FILE"
    echo "KERNEL SYSCALL DISPATCH OK"
    exit 0
else
    echo "KERNEL SYSCALL DISPATCH FAIL"
    exit 1
fi
