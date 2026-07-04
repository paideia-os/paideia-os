#!/usr/bin/env bash
# tools/qemu-tripleft-debug.sh — R15.M2-007 (#528)
# Wraps QEMU with triple-fault diagnostic flags. Used for bisecting iretq /
# CR3-flip / GDT bugs where the CPU silently reboots. Emits interrupt +
# cpu_reset traces to stderr; suppresses reboot on triple-fault so the log
# ends in a diagnosable state.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
KERNEL="${REPO_ROOT}/build/kernel.elf"

if [[ ! -f "${KERNEL}" ]]; then
    echo "kernel image missing: ${KERNEL}" >&2
    echo "run tools/build.sh first" >&2
    exit 1
fi

exec qemu-system-x86_64 \
    -kernel "${KERNEL}" \
    -no-reboot -no-shutdown \
    -serial stdio \
    -d int,cpu_reset \
    -D "${REPO_ROOT}/qemu-tripleft.log" \
    -m 64M \
    -display none \
    "$@"
