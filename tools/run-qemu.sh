#!/usr/bin/env bash
# Boot the built kernel under QEMU. Serial output goes to stdout.
#
# Extra args after the script name pass through to qemu-system-x86_64,
# e.g.: tools/run-qemu.sh -d int,cpu_reset
#
# Environment variables:
#   PAIDEIA_NIC=<e1000e|virtio|rtl8139|none>
#       Attach an emulated NIC to the guest. Default: virtio (R91.M5-002
#       #2030 -- superseding the earlier `none` default so the boot_r91_
#       nic_probe witness has a live NIC to attest against without every
#       invocation naming a PAIDEIA_NIC value explicitly).
#       - e1000e : -netdev user,id=net0,hostfwd=tcp::0-:0
#                  -device e1000e,netdev=net0
#       - virtio : -netdev user,id=net0,hostfwd=tcp::0-:0
#                  -device virtio-net-pci,netdev=net0
#       - rtl8139: -netdev user,id=net0
#                  -device rtl8139,netdev=net0
#       - none   : no NIC flags emitted (opt-in for bit-identical
#                  pre-R91 arg lists on non-network smokes).
#       R91.M2-004 introduced the switch itself with a `none` default so
#       R91-adjacent smokes could enable e1000e without perturbing other
#       modes; R91.M5-002 flips the default to `virtio` now that the
#       full three-NIC probe cascade + attach step lands (issue #2030).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
KERNEL="${REPO_ROOT}/build/kernel.elf"

if [[ ! -f "${KERNEL}" ]]; then
    echo "kernel not built; run tools/build.sh first" >&2
    exit 1
fi

# R91.M2-004 / R91.M5-002: compose optional NIC flags based on PAIDEIA_NIC.
# Default 'virtio' (R91.M5-002 #2030) gives the boot_r91_nic_probe witness
# a live NIC to attest against on every default boot. Opt-in `none` keeps
# QEMU's arg list bit-identical to pre-R91.M2-004 behavior for smokes that
# must not carry a NIC (rare -- most smokes tolerate the extra `-device`).
NIC_ARGS=()
case "${PAIDEIA_NIC:-virtio}" in
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
