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

# The Phase-1 kernel.elf has no multiboot2 / PVH ELF Note (BP-D3 deferral),
# so QEMU's `-kernel` flag rejects it. Load the raw bytes at the entry address
# via `-device loader` and let the CPU jump into them. Real bootloader
# integration (GRUB multiboot2 or Limine) is a Phase-12 work item.
exec qemu-system-x86_64 \
    -device loader,file="${KERNEL}",addr=0x100000,cpu-num=0 \
    -serial stdio \
    -display none \
    -no-reboot \
    -no-shutdown \
    -m 256M \
    "$@"
