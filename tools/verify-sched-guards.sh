#!/usr/bin/env bash
# Verifies #663 guards are present in the compiled sched module.
set -uo pipefail

KERNEL_ELF="${1:-build/kernel.elf}"

[[ -f "${KERNEL_ELF}" ]] || {
    echo "[verify-sched-guards] ${KERNEL_ELF} missing (build first)"
    exit 2
}

# 1. sched_wake has cmp $0x1,%ecx or $0x1,%rcx (RUNNABLE check)
DISASM=$(objdump -d "${KERNEL_ELF}" --disassemble=sched_wake 2>/dev/null)
echo "$DISASM" | grep -E 'cmp[[:space:]]+\$0x1,%[er]cx' > /dev/null || {
    echo "[FAIL] sched_wake missing cmp \$0x1,%(r|e)cx guard"
    exit 1
}

# 2. sched_block has a jne branch (precond fail)
DISASM=$(objdump -d "${KERNEL_ELF}" --disassemble=sched_block 2>/dev/null)
echo "$DISASM" | grep -E 'jne' > /dev/null || {
    echo "[FAIL] sched_block missing jne guard branch"
    exit 1
}

# 3. precond_fail_msg symbol exists in the binary
NM_OUT=$(nm "${KERNEL_ELF}" 2>/dev/null)
echo "$NM_OUT" | grep 'sched_block_precond_fail_msg' > /dev/null || {
    echo "[FAIL] sched_block_precond_fail_msg symbol not found"
    exit 1
}

echo "[verify-sched-guards] SCHED GUARDS OK"
