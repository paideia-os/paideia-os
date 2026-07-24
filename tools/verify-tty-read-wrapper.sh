#!/usr/bin/env bash
# Verifies #667 tty_read wrapper structural body against build/kernel.elf.
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
KERNEL_ELF="${REPO_ROOT}/build/kernel.elf"

[ -f "$KERNEL_ELF" ] || { echo "verify-tty-read-wrapper: $KERNEL_ELF missing"; exit 2; }

DISASM=$(objdump -d "$KERNEL_ELF" --disassemble=tty_read)

fail() { echo "verify-tty-read-wrapper: FAIL — missing $1"; exit 1; }

echo "$DISASM" | grep -qE 'push[[:space:]]+%rbx' || fail 'push rbx'
echo "$DISASM" | grep -qE 'push[[:space:]]+%r12' || fail 'push r12'
echo "$DISASM" | grep -qE 'call.*<tty_read_try>' || fail 'call tty_read_try'
echo "$DISASM" | grep -qE '\bcli\b' || fail 'cli guard'
echo "$DISASM" | grep -qE 'call.*<uart_rx_notify_set_waiter>' || fail 'call uart_rx_notify_set_waiter'
echo "$DISASM" | grep -qE 'call.*<sched_block>' || fail 'call sched_block'
echo "$DISASM" | grep -qE 'pop[[:space:]]+%r12' || fail 'pop r12'
echo "$DISASM" | grep -qE 'pop[[:space:]]+%rbx' || fail 'pop rbx'

echo "TTY READ WRAPPER OK"
