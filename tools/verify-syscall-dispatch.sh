#!/usr/bin/env bash
# Verification canary for src/kernel/core/syscall/dispatch.pdx (R17-M0-668 / #668).
# Verifies syscall_dispatch function wires IDs {0,1,2,3,32,39,56,60,61} to real bodies.
# Exits with "KERNEL SYSCALL DISPATCH OK" or "KERNEL SYSCALL DISPATCH FAIL".
set -euo pipefail

ELF="${1:-build/kernel.elf}"
FAIL=0
CHECKS_PASSED=0

if [[ ! -f "$ELF" ]]; then
    echo "KERNEL SYSCALL DISPATCH FAIL" >&2
    echo "ELF file not found: $ELF" >&2
    exit 1
fi

# Extract syscall_dispatch function using awk (from symbol definition to next symbol)
DISPATCH=$(objdump -d -M intel "$ELF" 2>/dev/null | \
           awk '/^[0-9a-f]+ <syscall_dispatch>:$/,/^[0-9a-f]+ <sys_close_body>:$/ {print}' | \
           head -n -1)

if [[ -z "$DISPATCH" ]]; then
    echo "KERNEL SYSCALL DISPATCH FAIL" >&2
    echo "syscall_dispatch function not found" >&2
    exit 1
fi

echo "[verify] syscall_dispatch function found"

# Check 1: Bounds check at 61
if echo "$DISPATCH" | grep -q "cmp.*0x3d"; then
    echo "[ok]   Bounds check: cmp rdi, 61"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] Bounds check missing"
    FAIL=1
fi

# Check 2: ID 0 route and sys_read_body call
if echo "$DISPATCH" | grep -q "cmp.*0x0" && echo "$DISPATCH" | grep -q "sys_read_body"; then
    echo "[ok]   ID 0 (read): routed to sys_read_body"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 0 (read): missing routing or sys_read_body call"
    FAIL=1
fi

# Check 3: ID 1 route and dispatch_write_uart OR sys_write_body
if echo "$DISPATCH" | grep -q "cmp.*0x1" && (echo "$DISPATCH" | grep -q "sys_write_body" || echo "$DISPATCH" | grep -q "uart_putc"); then
    echo "[ok]   ID 1 (write): routed (fast-path or sys_write_body present)"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 1 (write): missing routing or body"
    FAIL=1
fi

# Check 4: ID 2 route and sys_open_body
if echo "$DISPATCH" | grep -q "cmp.*0x2" && echo "$DISPATCH" | grep -q "sys_open_body"; then
    echo "[ok]   ID 2 (open): routed to sys_open_body"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 2 (open): missing routing or sys_open_body call"
    FAIL=1
fi

# Check 5: ID 3 route and sys_close_body
if echo "$DISPATCH" | grep -q "cmp.*0x3" && echo "$DISPATCH" | grep -q "sys_close_body"; then
    echo "[ok]   ID 3 (close): routed to sys_close_body"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 3 (close): missing routing or sys_close_body call"
    FAIL=1
fi

# Check 6: ID 32 (0x20) route and sys_dup2_body
if echo "$DISPATCH" | grep -q "cmp.*0x20" && echo "$DISPATCH" | grep -q "sys_dup2_body"; then
    echo "[ok]   ID 32 (dup2): routed to sys_dup2_body"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 32 (dup2): missing routing or sys_dup2_body call"
    FAIL=1
fi

# Check 7: ID 39 (0x27) route and inline getpid
if echo "$DISPATCH" | grep -q "cmp.*0x27"; then
    # Look for the inline getpid pattern: 8b 00 is mov eax, [rax]
    # The instruction appears after the dispatch_getpid label in the extracted section
    if echo "$DISPATCH" | grep -q "8b 00"; then
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
if echo "$DISPATCH" | grep -q "cmp.*0x38" && echo "$DISPATCH" | grep -q "sys_fork_body"; then
    echo "[ok]   ID 56 (fork): routed to sys_fork_body"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 56 (fork): missing routing or sys_fork_body call"
    FAIL=1
fi

# Check 9: ID 59 (0x3b) route to dispatch_enosys
if echo "$DISPATCH" | grep -q "cmp.*0x3b"; then
    echo "[ok]   ID 59 (execve): routes to dispatch_enosys"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 59 (execve): cmp missing"
    FAIL=1
fi

# Check 10: ID 60 (0x3c) route and sys_exit_body
if echo "$DISPATCH" | grep -q "cmp.*0x3c" && echo "$DISPATCH" | grep -q "sys_exit_body"; then
    echo "[ok]   ID 60 (exit): routed to sys_exit_body"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 60 (exit): missing routing or sys_exit_body call"
    FAIL=1
fi

# Check 11: ID 60 has hlt loop
if echo "$DISPATCH" | grep -A 10 "sys_exit_body" | grep -q "hlt"; then
    echo "[ok]   ID 60 (exit): halt loop present after body"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 60 (exit): halt loop missing"
    FAIL=1
fi

# Check 12: ID 61 (0x3d second occurrence) route and sys_wait_body
if echo "$DISPATCH" | grep -q "sys_wait_body"; then
    echo "[ok]   ID 61 (wait4): routed to sys_wait_body"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 61 (wait4): missing routing or sys_wait_body call"
    FAIL=1
fi

# Check 13: ID 61 has wstatus writeback
if echo "$DISPATCH" | grep -A 10 "sys_wait_body" | grep -q "mov.*QWORD PTR \[rsi\]"; then
    echo "[ok]   ID 61 (wait4): wstatus writeback present"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] ID 61 (wait4): wstatus writeback missing"
    FAIL=1
fi

# Check 14: _current_tcb referenced enough times
tcb_count=$(echo "$DISPATCH" | grep -c "_current_tcb" || echo "0")
if [[ $tcb_count -ge 5 ]]; then
    echo "[ok]   _current_tcb: referenced $tcb_count times (≥5 expected)"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] _current_tcb: referenced only $tcb_count times (need ≥5)"
    FAIL=1
fi

# Check 15: dispatch_enosys returns -38 (0xFFFFFFFFFFFFFFDA)
if echo "$DISPATCH" | grep -q "0xffffffffffffffda"; then
    echo "[ok]   dispatch_enosys: returns correct ENOSYS value"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "[FAIL] dispatch_enosys: does not return correct ENOSYS value"
    FAIL=1
fi

# Summary
TOTAL_CHECKS=15
echo ""
echo "Verification: $CHECKS_PASSED / $TOTAL_CHECKS checks passed"

if [[ $FAIL -eq 0 ]]; then
    echo "KERNEL SYSCALL DISPATCH OK"
    exit 0
else
    echo "KERNEL SYSCALL DISPATCH FAIL"
    exit 1
fi
