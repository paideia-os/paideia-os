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
#
#   PAIDEIA_HOSTFWD=<qemu-hostfwd-spec>[,<spec>...]
#       R94.M6-003 (paideia-os #2075). Extends the -netdev user hostfwd
#       rule set for the boot_r94_tcp_offbox smoke and future off-box
#       TCP witnesses that need a specific forwarded port. Each spec
#       is passed VERBATIM as an additional `hostfwd=<spec>` fragment
#       appended to the -netdev arg (comma-separated). Ignored when
#       PAIDEIA_NIC=none. Example:
#           PAIDEIA_HOSTFWD='tcp::5555-:5555' tools/run-qemu.sh ...
#       yields:
#           -netdev user,id=net0,hostfwd=tcp::0-:0,hostfwd=tcp::5555-:5555
#       The default `hostfwd=tcp::0-:0` (a wildcard placeholder that
#       QEMU accepts but never binds) is retained so pre-R94 smokes see
#       byte-identical arg lists. Multiple hostfwd specs may be
#       comma-separated in a single PAIDEIA_HOSTFWD value; each is
#       expanded into its own `hostfwd=<spec>` fragment.
#
#   PAIDEIA_VGA=<std|virtio|none>
#       R101.M4-002 (paideia-os #2151). Attach an emulated display
#       adapter for the boot_r101_stdvga smoke and future GUI witnesses.
#       Default: `none` (bit-identical to pre-R101 boots so non-graphics
#       smokes keep their exact arg lists).
#       - std    : -vga std               (QEMU Bochs display, 0x1234/0x1111)
#       - virtio : -vga none -device virtio-gpu-pci  (deferred consumer:
#                                                     R103 virtio-gpu backend)
#       - none   : (no -vga / -device flags emitted; the R101 witness
#                   detects no Bochs device and takes the skip path)
#       Follows the PAIDEIA_NIC pattern above.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
KERNEL="${REPO_ROOT}/build/kernel.elf"

# R98.M3-001 (paideia-os #2104): --help. Consolidated networking-flag
# summary so a caller can discover PAIDEIA_NIC / PAIDEIA_HOSTFWD /
# PAIDEIA_NET_SMOKE from `tools/run-qemu.sh --help` without spelunking
# the header block. Pointer to design/networking/qemu-net-invocation.md
# for the full invocation catalogue.
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'HELPEOF'
tools/run-qemu.sh -- boot the built kernel under QEMU (serial -> stdout).

Usage: tools/run-qemu.sh [qemu args ...]

Networking environment variables:

  PAIDEIA_NIC=<e1000e|virtio|rtl8139|none>
    Attach an emulated NIC. Default: `virtio` (R91.M5-002 #2030). The
    dispatch cascade in src/kernel/core/net/nic_dispatch.pdx probes for
    all three; the driver whose PCI IDs match the -device attached here
    is the one that lands in the KIND_NIC row.

  PAIDEIA_HOSTFWD=<qemu-hostfwd-spec>[,<spec>...]
    Extra `hostfwd=` fragments appended to the SLIRP -netdev argument
    (R94.M6-003 #2075). Comma-separated for multiple rules. Ignored when
    PAIDEIA_NIC=none. Example:
      PAIDEIA_HOSTFWD='tcp::5555-:5555' tools/run-qemu.sh ...
    Yields `-netdev user,id=net0,hostfwd=tcp::0-:0,hostfwd=tcp::5555-:5555`.

  PAIDEIA_NET_SMOKE=<0|1>
    Read by tools/run-smoke.sh (NOT this script) as the opt-in gate for
    the networking-smoke lane -- boot_r91_nic + boot_r93_udp_dns +
    boot_r94_tcp_offbox refuse cleanly outside the lane (R98.M1-002
    #2101). The `boot_net_smoke` composite mode sets it for its child
    invocations. Setting it here has no direct effect on QEMU flags.

Full invocation catalogue (host prerequisites, SLIRP addressing, hostfwd
examples, IPv6 non-scope note): design/networking/qemu-net-invocation.md.

Extra positional args after any flag pass through verbatim to
qemu-system-x86_64: `tools/run-qemu.sh -d int,cpu_reset`.
HELPEOF
    exit 0
fi

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
# R94.M6-003 (paideia-os #2075): compose extra hostfwd fragments from
# PAIDEIA_HOSTFWD (comma-separated), appended to the -netdev user
# argument alongside the pre-R94 default hostfwd=tcp::0-:0 placeholder.
HOSTFWD_EXTRA=""
if [[ -n "${PAIDEIA_HOSTFWD:-}" ]]; then
    IFS=',' read -ra _paideia_hostfwd_specs <<< "${PAIDEIA_HOSTFWD}"
    for _spec in "${_paideia_hostfwd_specs[@]}"; do
        HOSTFWD_EXTRA="${HOSTFWD_EXTRA},hostfwd=${_spec}"
    done
    unset _paideia_hostfwd_specs _spec
fi

case "${PAIDEIA_NIC:-virtio}" in
    none)
        ;;
    e1000e)
        NIC_ARGS=(-netdev "user,id=net0,hostfwd=tcp::0-:0${HOSTFWD_EXTRA}" \
                  -device e1000e,netdev=net0)
        ;;
    virtio)
        NIC_ARGS=(-netdev "user,id=net0,hostfwd=tcp::0-:0${HOSTFWD_EXTRA}" \
                  -device virtio-net-pci,netdev=net0)
        ;;
    rtl8139)
        NIC_ARGS=(-netdev "user,id=net0${HOSTFWD_EXTRA}" \
                  -device rtl8139,netdev=net0)
        ;;
    *)
        echo "PAIDEIA_NIC='${PAIDEIA_NIC}' invalid; expected one of: e1000e, virtio, rtl8139, none" >&2
        exit 2
        ;;
esac

# R101.M4-002 (paideia-os #2151): compose optional VGA flags based on
# PAIDEIA_VGA. Default `none` keeps pre-R101 arg lists byte-identical
# for every non-graphics smoke. `std` attaches the QEMU Bochs display
# (PCI 0x1234/0x1111) the R101 witness probes. `virtio` is reserved
# for the R103 virtio-gpu 2D backend; consumed by that landing.
VGA_ARGS=()
case "${PAIDEIA_VGA:-none}" in
    none)
        ;;
    std)
        VGA_ARGS=(-vga std)
        ;;
    virtio)
        VGA_ARGS=(-vga none -device virtio-gpu-pci)
        ;;
    *)
        echo "PAIDEIA_VGA='${PAIDEIA_VGA}' invalid; expected one of: std, virtio, none" >&2
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
    ${VGA_ARGS[@]+"${VGA_ARGS[@]}"} \
    "$@"
