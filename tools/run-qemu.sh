#!/usr/bin/env bash
# Boot the built kernel under QEMU. Serial output goes to stdout.
#
# Extra args after the script name pass through to qemu-system-x86_64,
# e.g.: tools/run-qemu.sh -d int,cpu_reset

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
KERNEL="${REPO_ROOT}/build/kernel.elf"

if [[ ! -f "${KERNEL}" ]]; then
    echo "kernel not built; run tools/build.sh first" >&2
    exit 1
fi

# PVH ELF Note emitted by paideia-as PA10-001; QEMU -kernel works directly.
# Real bootloader integration (GRUB multiboot2 or Limine) is a Phase-12 work item.
# R10-m2-002: QEMU TCG does not support TSC-DEADLINE. Using periodic timer mode instead.
# Per design/audit/entries/r10-timer-delivery-diagnosis-001.md, P3 identified but
# QEMU TCG limitation requires fallback to LAPIC periodic mode.
# R11-m1-002: Add -cpu max to expose CPUID.01H:ECX[24] (TSC-DEADLINE support flag).
# This enables LAPIC SVR and allows for future TSC-DEADLINE mode support.
exec qemu-system-x86_64 \
    -cpu max \
    -kernel "${KERNEL}" \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -serial stdio \
    -display none \
    -no-reboot \
    -no-shutdown \
    -m 256M \
    "$@"
