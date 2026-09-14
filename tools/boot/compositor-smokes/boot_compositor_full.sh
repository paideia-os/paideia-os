#!/usr/bin/env bash
# tools/boot/compositor-smokes/boot_compositor_full.sh -- COMP-QM-05
#
# DESIGN-STAGE STUB. NOT RUNNABLE. Wave SSS (paideia-os).
# Authority: design/testing/compositor-qemu-smoke-plan.md.
#
# Intended eventual behavior: boot through COMP-QM-04's gate, then
# launch one demo client against the live stack; assert the serial log
# contains the fingerprint in expected-boot_compositor_full.txt after
# roughly 1s of steady-state frame production.
#
# Original brief fingerprint was
# "COMPOSITOR E2E OK client=1 surface=1 frames>=60" -- revised here to
# "COMPOSITOR E2E OK client=1 surface=1 frames=60" (plan doc Sec 2):
# run-smoke.sh's --fingerprint matcher does literal ordered-substring
# matching, so an inequality clause (">=60") cannot be expressed as a
# golden line. The revised contract asks the eventual demo client to
# emit this marker exactly once, at the 60th frame, rather than
# encoding the inequality in the golden.
#
# Blocked on (see plan doc Sec 3):
#   G1-G4, G7 -- inherited from COMP-QM-02/03/04.
#   G8 -- no reference demo client exists that speaks whatever wire
#         protocol wins the G1 lineage decision.
#
# Exit code 77 matches tools/run-smoke.sh's "environment/prerequisite
# not met -- skip cleanly" convention. This is a scope marker, not a
# test failure.

set -euo pipefail

echo "COMP-QM-05 (boot_compositor_full): design-stage stub, not runnable." >&2
echo "See design/testing/compositor-qemu-smoke-plan.md Sec 3 (gaps G1-G4, G7, G8)." >&2
exit 77
