#!/usr/bin/env bash
# tools/boot/compositor-smokes/boot_r113_compositor.sh -- COMP-QM-01
#
# DESIGN-STAGE STUB. NOT RUNNABLE. Wave SSS (paideia-os).
# Authority: design/testing/compositor-qemu-smoke-plan.md.
#
# Intended eventual behavior (once wired as a tools/run-smoke.sh MODE):
# boot the kernel with COMPOSITOR_INIT_ENABLE=1 so an init-time gate
# runs the src/user/compositor/*.pdx module self-checks (or a kernel-
# side init probe over them), then assert the serial log contains the
# fingerprint in expected-boot_r113_compositor.txt (ordered-substring
# match, matching run-smoke.sh's --fingerprint convention).
#
# Blocked on (see plan doc Sec 3): G5 -- tools/run-qemu.sh and
# kernel_main.pdx have no COMPOSITOR_INIT_ENABLE gate or equivalent
# init-time compositor bring-up sequencing today.
#
# This is the wave's ONE fixture with no userspace-daemon dependency
# (kernel-only), so it is first in the SSS-01..05 rollout order.
#
# Exit code 77 matches tools/run-smoke.sh's "environment/prerequisite
# not met -- skip cleanly" convention. This is a scope marker, not a
# test failure.

set -euo pipefail

echo "COMP-QM-01 (boot_r113_compositor): design-stage stub, not runnable." >&2
echo "See design/testing/compositor-qemu-smoke-plan.md Sec 3 (gap G5)." >&2
exit 77
