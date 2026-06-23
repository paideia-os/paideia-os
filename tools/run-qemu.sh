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
exec qemu-system-x86_64 \
    -kernel "${KERNEL}" \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -serial stdio \
    -display none \
    -no-reboot \
    -no-shutdown \
    -m 256M \
    "$@"
