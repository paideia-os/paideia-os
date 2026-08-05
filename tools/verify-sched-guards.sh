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

# 2. sched_block has kassert_fail call (#697 conversion from old guard)
DISASM=$(objdump -d "${KERNEL_ELF}" --disassemble=sched_block 2>/dev/null)
echo "$DISASM" | grep -E 'call[[:space:]]+.*kassert_fail' > /dev/null || {
    echo "[FAIL] sched_block missing kassert_fail call (#697)"
    exit 1
}

echo "[verify-sched-guards] SCHED GUARDS OK"
