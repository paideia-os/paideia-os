#!/usr/bin/env bash
# tools/boot/compositor-smokes/boot_svc_wm.sh -- COMP-QM-03
#
# DESIGN-STAGE STUB. NOT RUNNABLE. Wave SSS (paideia-os).
# Authority: design/testing/compositor-qemu-smoke-plan.md.
#
# Intended eventual behavior: boot through COMP-QM-02's gate, then have
# svc-wm register against the running svc-compositor; assert the serial
# log contains the fingerprint in expected-boot_svc_wm.txt.
#
# Fingerprint "SVC-WM REGISTER OK" already carries an OK token and is
# a literal, so no revision was needed per plan doc Sec 2 -- but note
# it collides in spirit (not guaranteed string-identical intent) with
# the fingerprint of the same name already specced in
# design/graphics/r102-user-plan.md's own svc-wm issue list. Reconcile
# against that doc rather than treat this as an independent contract
# (plan doc Sec 3, gap G6).
#
# Blocked on (see plan doc Sec 3):
#   G1 -- compositor lineage unreconciled.
#   G2 -- svc-compositor (this fixture's dependency) has zero source.
#   G3 -- svc-wm has zero source and no freeze doc comparable to
#         design/graphics/r113-m1-substrate.md.
#   G7 -- no confirmed ring-3-reachable mint path (inherited from
#         COMP-QM-02).
#
# Exit code 77 matches tools/run-smoke.sh's "environment/prerequisite
# not met -- skip cleanly" convention. This is a scope marker, not a
# test failure.

set -euo pipefail

echo "COMP-QM-03 (boot_svc_wm): design-stage stub, not runnable." >&2
echo "See design/testing/compositor-qemu-smoke-plan.md Sec 3 (gaps G1, G2, G3, G7)." >&2
exit 77
