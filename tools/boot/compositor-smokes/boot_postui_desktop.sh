#!/usr/bin/env bash
# tools/boot/compositor-smokes/boot_postui_desktop.sh -- COMP-QM-04
#
# DESIGN-STAGE STUB. NOT RUNNABLE. Wave SSS (paideia-os).
# Authority: design/testing/compositor-qemu-smoke-plan.md.
#
# Intended eventual behavior: boot through COMP-QM-03's gate, then have
# init spawn postui-desktop; assert the serial log contains the
# fingerprint in expected-boot_postui_desktop.txt.
#
# Blocked on (see plan doc Sec 3):
#   G1, G2, G3, G7 -- inherited from COMP-QM-02/03.
#   G4 -- src/user/postui-desktop/entry.pdx is explicitly
#         "LIFECYCLE-SKELETON SCOPE... not yet a linked, spawned
#         process" (its own header comment). tools/build-user.sh has
#         an active exclusion branch for postui-desktop/*, and init
#         never forks/execves it.
#
# Exit code 77 matches tools/run-smoke.sh's "environment/prerequisite
# not met -- skip cleanly" convention. This is a scope marker, not a
# test failure.

set -euo pipefail

echo "COMP-QM-04 (boot_postui_desktop): design-stage stub, not runnable." >&2
echo "See design/testing/compositor-qemu-smoke-plan.md Sec 3 (gaps G1-G4, G7)." >&2
exit 77
