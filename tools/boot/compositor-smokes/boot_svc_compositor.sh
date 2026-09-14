#!/usr/bin/env bash
# tools/boot/compositor-smokes/boot_svc_compositor.sh -- COMP-QM-02
#
# DESIGN-STAGE STUB. NOT RUNNABLE. Wave SSS (paideia-os).
# Authority: design/testing/compositor-qemu-smoke-plan.md.
#
# Intended eventual behavior: boot the kernel through COMP-QM-01's
# gate, then have init spawn the svc-compositor userspace daemon;
# assert the serial log contains the fingerprint in
# expected-boot_svc_compositor.txt.
#
# Original brief fingerprint was "SVC-COMP READY host_id=<n>" -- revised
# here to "SVC-COMP READY OK host_id=0" for two reasons (plan doc Sec 2):
#   1. tools/verify-fingerprint-coverage.sh requires an "OK" whole-word
#      token in every asserted marker; the brief's string had none.
#   2. run-smoke.sh's --fingerprint matcher does literal ordered-
#      substring matching, not pattern matching, so "<n>" cannot survive
#      as a literal -- pinned to host_id=0 for a single-host QEMU boot.
#
# Blocked on (see plan doc Sec 3):
#   G1 -- R102 vs R113 compositor lineage unreconciled (which daemon
#         shape actually owns this responsibility is undecided).
#   G2 -- svc-compositor has zero source anywhere in this monorepo;
#         R102 specs it only as an uncreated satellite repo.
#   G7 -- no confirmed ring-3-reachable sys_cap_mint path for
#         KIND_SURFACE that a spawned daemon could call on client
#         connect.
#
# Exit code 77 matches tools/run-smoke.sh's "environment/prerequisite
# not met -- skip cleanly" convention. This is a scope marker, not a
# test failure.

set -euo pipefail

echo "COMP-QM-02 (boot_svc_compositor): design-stage stub, not runnable." >&2
echo "See design/testing/compositor-qemu-smoke-plan.md Sec 3 (gaps G1, G2, G7)." >&2
exit 77
