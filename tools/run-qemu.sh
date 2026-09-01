#!/usr/bin/env bash
# Boot the built kernel under QEMU. Serial output goes to stdout.
#
# Extra args after the script name pass through to qemu-system-x86_64,
# e.g.: tools/run-qemu.sh -d int,cpu_reset
#
# Environment variables:
#   PAIDEIA_NIC=<e1000e|virtio|rtl8139|none>
#       Attach an emulated NIC to the guest. Default: none (no -netdev / -device
#       NIC flags are added, preserving bit-identical args for non-network smokes).
#       - e1000e : -netdev user,id=net0,hostfwd=tcp::0-:0
#                  -device e1000e,netdev=net0
#       - virtio : -netdev user,id=net0,hostfwd=tcp::0-:0
#                  -device virtio-net-pci,netdev=net0
#       - rtl8139: -netdev user,id=net0
#                  -device rtl8139,netdev=net0
#       - none   : (default) no NIC flags emitted.
#       R91.M2-004: added so R91 NIC-probe smokes can enable e1000e without
#       affecting other boot smokes. tools/run-smoke.sh's boot_r91_nic_probe
#       mode (issue #2031) will set PAIDEIA_NIC=e1000e.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
KERNEL="${REPO_ROOT}/build/kernel.elf"

if [[ ! -f "${KERNEL}" ]]; then
    echo "kernel not built; run tools/build.sh first" >&2
    exit 1
fi

# R91.M2-004: compose optional NIC flags based on PAIDEIA_NIC. Default 'none'
# keeps QEMU's arg list bit-identical to pre-R91.M2-004 behavior for every
# smoke that does not exercise the network stack.
NIC_ARGS=()
case "${PAIDEIA_NIC:-none}" in
    none)
        ;;
    e1000e)
        NIC_ARGS=(-netdev user,id=net0,hostfwd=tcp::0-:0 \
                  -device e1000e,netdev=net0)
        ;;
    virtio)
        NIC_ARGS=(-netdev user,id=net0,hostfwd=tcp::0-:0 \
                  -device virtio-net-pci,netdev=net0)
        ;;
    rtl8139)
        NIC_ARGS=(-netdev user,id=net0 \
                  -device rtl8139,netdev=net0)
        ;;
    *)
        echo "PAIDEIA_NIC='${PAIDEIA_NIC}' invalid; expected one of: e1000e, virtio, rtl8139, none" >&2
        exit 2
        ;;
esac

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
    ${NIC_ARGS[@]+"${NIC_ARGS[@]}"} \
    "$@"
