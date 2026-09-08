#!/usr/bin/env bash
# tools/capture-t14-boot.sh -- R111.M7-027 (paideia-os #2379)
#
# Hardware-in-loop capture flow: drive a real Lenovo ThinkPad T14 G4
# boot from the mkimage.sh USB stick, capture serial output over a
# USB-TTL adapter at 115200 8N1, timestamp each line, save to
# build/mvp/T14G4-capture-<UTC>.log, then compare against
# tests/expected-t14-fidelity.golden (the same ordered-substring
# contract tools/run-qemu-t14fidelity.sh uses).  The only currently
# available paideia smoke that produces the SHELL START witness on
# genuine T14 G4 hardware -- run-qemu-t14fidelity.sh reaches the same
# witness under QEMU/OVMF, and this recipe closes the loop by asserting
# the wire-shape survives the transition to real firmware.
#
# =============================================================================
# ROLE + DIVISION OF LABOR
# =============================================================================
#
# This script does NOT drive the T14 boot itself: firmware handoff +
# Startup + UEFI + kernel come up under the physical machine's clock
# and are not scriptable from the operator's dev box.  What this script
# DOES:
#
#   1. Validates the operator-supplied USB-TTL device path
#      (--device /dev/ttyUSB0 by default) is present + accessible.
#   2. Configures the tty for 115200 8N1, raw, no flow control
#      (matching R16.M4 kernel COM1 init -- see
#      design/kernel/serial-console-fallback.md).
#   3. Prints an actionable "cold-power the T14 NOW" banner + waits
#      up to --timeout seconds (default 120) for serial bytes to arrive.
#   4. Timestamps every complete line with a UTC ISO-8601 wall-clock
#      prefix and appends to
#      build/mvp/T14G4-capture-YYYYMMDDTHHMMSSZ.log.
#   5. Runs the ordered-substring golden fingerprint compare against
#      tests/expected-t14-fidelity.golden (same shape + same Python
#      matcher as tools/run-qemu-t14fidelity.sh) and emits an OK /
#      FAIL summary listing any missing lines.
#
# The operator's job is orthogonal: on the "waiting for serial output"
# banner, cold-power the T14 G4 with the USB stick inserted, tap F12
# at the Lenovo splash to reach the boot menu, pick the paideia USB
# entry.  Wiring + `dd` recipe + boot-menu walk live at
# design/boot/t14-hw-in-loop.md.
#
# --replay <path> skips the capture window entirely and runs the
# fingerprint compare against an existing capture log -- for
# post-mortem re-scoring after a golden update, or for CI-adjacent
# consumers that keep a corpus of prior captures under
# tests/hw-fixtures/.
#
# =============================================================================
# SUCCESS CRITERION
# =============================================================================
#
# Every line in tests/expected-t14-fidelity.golden appears as an
# ordered substring of the captured serial log.  Currently six lines:
#
#     UEFI EBS OK
#     UEFI BRIDGE OK
#     UEFI PML4 OK
#     ACPI RSDP HANDOFF OK
#     FB CONSOLE OK
#     SHELL START
#
# Golden file is the single source of truth; do not duplicate the
# literals here.  A tightening of the golden (adding a line, tightening
# a substring) automatically tightens this smoke without a script
# edit.
#
# =============================================================================
# EXIT STATUS
# =============================================================================
#
#   0    every golden line observed in order
#   1    one or more golden lines missing (silent regression, or a
#        boot chain that did not reach the shell)
#   2    dependency missing (stty / timeout / python3 / etc.) OR
#        --device path missing / not readable-writable OR
#        --replay path missing / empty
#   3    zero serial bytes captured in --timeout seconds (adapter
#        attached but T14 never booted, or wrong device path, or
#        wrong baud, or TX/RX crossed wrong on the cable)
#   4    argument / invocation error
#
# =============================================================================
# USAGE
# =============================================================================
#
#   # Live capture from /dev/ttyUSB0 with default 120s timeout:
#   bash tools/capture-t14-boot.sh
#
#   # Alternate device + longer timeout (slow BIOS POST):
#   bash tools/capture-t14-boot.sh \
#       --device /dev/ttyACM0 \
#       --timeout 240
#
#   # Re-score an existing capture (no live capture; --device ignored):
#   bash tools/capture-t14-boot.sh \
#       --replay build/mvp/T14G4-capture-20260908T171200Z.log
#
# See also:
#   design/boot/t14-hw-in-loop.md          (the operator recipe)
#   tools/mkimage.sh                        (USB image builder)
#   tools/run-qemu-t14fidelity.sh           (QEMU-side counterpart)
#   tests/expected-t14-fidelity.golden      (fingerprint contract)
#   tools/run-smoke-hw.sh                   (older per-mode HW harness)

set -uo pipefail

# ---------------------------------------------------------------------------
# Constants + paths.  Every path is derived from git rev-parse so an
# operator running this from any subdirectory gets the same anchor.
# ---------------------------------------------------------------------------

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null \
    || { echo "capture-t14-boot: not inside a git tree" >&2; exit 4; })"
BUILD_DIR="${REPO_ROOT}/build"
MVP_DIR="${BUILD_DIR}/mvp"
GOLDEN_PATH="${REPO_ROOT}/tests/expected-t14-fidelity.golden"

# UTC timestamp for the log filename -- ISO-8601 basic form so the
# stem sorts lexicographically by capture time.  The `T`/`Z` separators
# survive every filesystem paideia builds on (FAT32 rejects ':').
CAPTURE_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

# ---------------------------------------------------------------------------
# Defaults (per issue spec + design/boot/t14-hw-in-loop.md §5).
# ---------------------------------------------------------------------------

DEVICE="/dev/ttyUSB0"
BAUD=115200
TIMEOUT=120
REPLAY_PATH=""

# ---------------------------------------------------------------------------
# CLI parsing.  Long-form only (no ambiguity with short flags in an
# operator-facing script).
# ---------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
capture-t14-boot -- HW-in-loop boot capture + golden fingerprint check
                    for the Lenovo ThinkPad T14 Gen 4.

Usage:
  tools/capture-t14-boot.sh [options]

Options:
  --device <path>      USB-TTL serial device on the operator dev box.
                       Default /dev/ttyUSB0.  Common alternates:
                       /dev/ttyUSB1 (multiple adapters), /dev/ttyACM0
                       (CDC-ACM variants).
  --baud <rate>        Serial baud rate.  Default 115200.  Must match
                       the kernel COM1 init (R16.M4); do not change
                       unless src/kernel/boot/uart.pdx is retuned.
  --timeout <sec>      Capture window in seconds.  Default 120.  T14 G4
                       cold-boot to SHELL START is typically ~15-40 s
                       (OVMF init + PCIe enum + NVMe attach + xHCI +
                       userland dispatch); 120 s leaves headroom for
                       a slow POST (e.g. Insyde firmware SETUP menu
                       transiently attached, cold TB4 controller wake).
  --replay <path>      Skip live capture; re-score an existing log
                       against the golden.  --device / --baud /
                       --timeout are ignored when --replay is given.
                       Useful for post-mortem after a golden update.
  -h, --help           Print this help and exit.

Output:
  build/mvp/T14G4-capture-<UTC>.log
      Timestamped capture log.  Every complete line from the wire is
      prefixed with a UTC ISO-8601 wall-clock stamp
      (YYYY-MM-DDTHH:MM:SS.mmmZ) so a post-hoc reader can correlate
      the boot timeline (POST -> UEFI -> kernel -> shell) against
      external events.  --replay reads THIS file's format back
      (fingerprint compare tolerates the timestamp prefix -- it is a
      substring search).

Exit status:
  0    every golden line observed in order
  1    one or more golden lines missing
  2    dependency / device / replay path error
  3    zero serial bytes captured in --timeout seconds
  4    argument / invocation error

Operator workflow (live capture):
  1. Build the image:  bash tools/mkimage.sh build --fw-dir=<path>
  2. Write to USB:     sudo dd if=build/mvp/T14G4.img of=/dev/sdX \
                            bs=4M conv=fsync status=progress; sync
  3. Wire the USB-TTL adapter to the T14 (see
     design/boot/t14-hw-in-loop.md §3 for the pinout).
  4. Run:              bash tools/capture-t14-boot.sh
  5. On "waiting for serial output" banner: insert USB stick into
     the T14, cold-power (or reset), tap F12 at the Lenovo splash,
     pick the USB entry.
  6. Wait for the golden summary at the end.

See also:
  design/boot/t14-hw-in-loop.md            (operator recipe + wiring)
  tools/mkimage.sh                          (USB image builder)
  tools/run-qemu-t14fidelity.sh             (QEMU-side counterpart)
  tests/expected-t14-fidelity.golden        (fingerprint contract)
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)    DEVICE="${2:?}"; shift 2 ;;
        --device=*)  DEVICE="${1#--device=}"; shift ;;
        --baud)      BAUD="${2:?}"; shift 2 ;;
        --baud=*)    BAUD="${1#--baud=}"; shift ;;
        --timeout)   TIMEOUT="${2:?}"; shift 2 ;;
        --timeout=*) TIMEOUT="${1#--timeout=}"; shift ;;
        --replay)    REPLAY_PATH="${2:?}"; shift 2 ;;
        --replay=*)  REPLAY_PATH="${1#--replay=}"; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)
            echo "capture-t14-boot: unknown argument: $1" >&2
            echo "capture-t14-boot: run 'tools/capture-t14-boot.sh --help' for usage" >&2
            exit 4
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Prerequisite tool check.  python3 is required in both live and replay
# modes because the timestamp + fingerprint stages both use inline
# Python (bash cannot reliably emit sub-second UTC stamps, and the
# ordered-substring matcher is verbatim-shared with
# run-qemu-t14fidelity.sh's PYEOF block).
# ---------------------------------------------------------------------------

check_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "capture-t14-boot: missing prerequisite: $1" >&2
        exit 2
    fi
}

check_tool python3

if [[ -z "${REPLAY_PATH}" ]]; then
    # Live capture only: stty + timeout are needed.
    check_tool stty
    check_tool timeout
fi

# ---------------------------------------------------------------------------
# Golden file readiness.  A missing golden is a repo-state error, not
# a HW error -- exit 2 rather than 1 or 3.
# ---------------------------------------------------------------------------

if [[ ! -f "${GOLDEN_PATH}" ]]; then
    echo "capture-t14-boot: golden file missing at ${GOLDEN_PATH}" >&2
    echo "capture-t14-boot: (repo checkout appears incomplete)" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Compare helper -- ordered-substring match, shape-identical to the
# PYEOF block in tools/run-qemu-t14fidelity.sh.  Reused verbatim so
# a golden update tightens both smokes simultaneously.
#
# Prints a "PASS" line on match; on miss, prints "FAIL: N missing" +
# a bulleted list, and returns 1 via `sys.exit(1)`.
# ---------------------------------------------------------------------------

run_fingerprint_compare() {
    local log_path="$1"
    python3 - "${log_path}" "${GOLDEN_PATH}" <<'PYEOF'
import sys

log_path, golden_path = sys.argv[1], sys.argv[2]

with open(log_path, 'rb') as f:
    log = f.read()

with open(golden_path, 'r', encoding='utf-8') as f:
    golden = [ln.rstrip('\n') for ln in f
              if ln.strip() and not ln.startswith('#')]

cursor = 0
missing = []
matched = []
for line in golden:
    needle = line.encode('utf-8')
    idx = log.find(needle, cursor)
    if idx < 0:
        missing.append(line)
    else:
        matched.append(line)
        cursor = idx + len(needle)

total = len(golden)
if missing:
    sys.stderr.write(
        f"[capture-t14-boot] FAIL: "
        f"{len(missing)}/{total} golden fingerprints missing:\n")
    for m in missing:
        sys.stderr.write(f"  - {m}\n")
    if matched:
        sys.stderr.write(
            f"[capture-t14-boot]        {len(matched)}/{total} matched:\n")
        for m in matched:
            sys.stderr.write(f"  + {m}\n")
    sys.exit(1)

sys.stdout.write(
    f"[capture-t14-boot] OK: all {total} golden fingerprints observed\n")
for m in matched:
    sys.stdout.write(f"  + {m}\n")
sys.exit(0)
PYEOF
}

# ===========================================================================
# --replay path -- skip live capture, jump straight to the golden compare.
# ===========================================================================

if [[ -n "${REPLAY_PATH}" ]]; then
    if [[ ! -f "${REPLAY_PATH}" ]]; then
        echo "capture-t14-boot: --replay path does not exist: ${REPLAY_PATH}" >&2
        exit 2
    fi
    if [[ ! -s "${REPLAY_PATH}" ]]; then
        echo "capture-t14-boot: --replay path is empty: ${REPLAY_PATH}" >&2
        exit 2
    fi

    echo "[capture-t14-boot] replay: ${REPLAY_PATH}"
    echo "[capture-t14-boot] golden: ${GOLDEN_PATH}"
    run_fingerprint_compare "${REPLAY_PATH}"
    exit $?
fi

# ===========================================================================
# Live capture path.
# ===========================================================================

# ---------------------------------------------------------------------------
# Serial device presence + permission check.
# ---------------------------------------------------------------------------

if [[ ! -e "${DEVICE}" ]]; then
    cat >&2 <<MSG
capture-t14-boot: no serial adapter detected at ${DEVICE}.

Attach a USB-TTL adapter (FT232 / CP2102 / CH340) to the operator dev
box, wired to the T14 side per design/boot/t14-hw-in-loop.md §3.  Then
re-run.  If the adapter enumerated elsewhere:

    dmesg | tail -20             # right after plugging in
    ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null

Override with --device <path>:

    bash tools/capture-t14-boot.sh --device /dev/ttyACM0
MSG
    exit 2
fi

if [[ ! -r "${DEVICE}" || ! -w "${DEVICE}" ]]; then
    cat >&2 <<MSG
capture-t14-boot: ${DEVICE} not readable/writable by this user.

Add your user to the dialout group (Debian/Ubuntu) or uucp (Arch) and
re-log:

    sudo usermod -a -G dialout \$USER    # then log out + log back in

Verify with:  groups | grep -E 'dialout|uucp'
MSG
    exit 2
fi

# ---------------------------------------------------------------------------
# Configure the tty: <baud> 8N1, no flow control, raw.
#
# Rationale: kernel COM1 init (src/kernel/boot/uart.pdx +
# src/kernel/core/uart/rx_init.pdx) leaves the line in 8-bit words, no
# parity, 1 stop bit, no hardware handshake.  `raw` disables host-side
# line-cooking so binary-clean bytes reach the log.  `stty` is the
# operator-side mirror of the kernel's UART init; the two must agree
# byte-for-byte or the log fills with framing errors.
# ---------------------------------------------------------------------------

if ! stty -F "${DEVICE}" \
        "${BAUD}" \
        cs8 -cstopb -parenb \
        -crtscts -ixon -ixoff \
        raw -echo \
        >/dev/null 2>&1; then
    echo "capture-t14-boot: stty configuration failed on ${DEVICE} at ${BAUD}" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Prepare the capture log path.
# ---------------------------------------------------------------------------

mkdir -p "${MVP_DIR}"
CAPTURE_LOG="${MVP_DIR}/T14G4-capture-${CAPTURE_STAMP}.log"

# Truncate (do not clobber) so the caller can tail -F it from another
# terminal while the capture runs.
: > "${CAPTURE_LOG}"

# ---------------------------------------------------------------------------
# Banner + wait cue.  The operator triggers the boot AFTER this prints.
# ---------------------------------------------------------------------------

cat <<MSG
[capture-t14-boot] waiting for serial output on ${DEVICE}
[capture-t14-boot]   baud=${BAUD} timeout=${TIMEOUT}s
[capture-t14-boot]   log=${CAPTURE_LOG}
[capture-t14-boot]   golden=${GOLDEN_PATH}

*** Insert the T14G4.img USB stick and cold-power (or reset) the T14 NOW.
    Tap F12 at the Lenovo splash, select the USB entry.
    Firmware -> UEFI stub -> kernel_main_uefi -> kernel_main_64 -> INIT
    -> shell should stream over the wire within ${TIMEOUT} seconds.
    See design/boot/t14-hw-in-loop.md for the full recipe.
MSG

# ---------------------------------------------------------------------------
# Capture window.
#
# Shape:  timeout <sec> cat <device> | python3 <timestamper> > <log>
#
# The Python timestamper reads bytes from stdin unbuffered, splits on
# LF, and prefixes every complete line with a UTC ISO-8601 stamp
# (millisecond precision).  Partial trailing bytes (no LF yet) are
# held until the next byte or EOF -- on EOF they are flushed with
# a `(no-EOL)` suffix so no bytes are silently dropped.
#
# `timeout --preserve-status` propagates SIGTERM to `cat` after the
# window; SIGPIPE from the closed downstream python is caught in the
# outer shell.  Exit codes we treat as "capture window closed cleanly":
#     0   cat returned normally (unlikely; serial usually only EOFs on
#         adapter unplug)
#   124   GNU timeout raised SIGTERM after window (expected)
#   143   SIGTERM propagated through --preserve-status (expected)
# ---------------------------------------------------------------------------

CAT_BIN="cat"
if command -v stdbuf >/dev/null 2>&1; then
    # -oL: line-buffered stdout so partial lines reach the timestamper
    # promptly (matters when the kernel emits a slow byte-at-a-time
    # UART trickle during panic).
    CAT_BIN="stdbuf -oL cat"
fi

# The Python timestamper.  Kept inline (rather than as a sibling
# script) so the file is self-contained -- an operator on a fresh
# checkout runs it without a "install this helper" chase.
set +e
# shellcheck disable=SC2086
timeout --preserve-status "${TIMEOUT}" ${CAT_BIN} "${DEVICE}" \
  | python3 -u -c '
import sys
import datetime

def stamp():
    # UTC ISO-8601 with millisecond precision, Z suffix.
    now = datetime.datetime.now(datetime.timezone.utc)
    return now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"

buf = bytearray()
out = sys.stdout.buffer
while True:
    chunk = sys.stdin.buffer.read1(4096)
    if not chunk:
        # Flush any partial trailing bytes (no LF) with a marker so
        # nothing is silently dropped on adapter unplug / EOF.
        if buf:
            out.write(f"[{stamp()}] ".encode("utf-8"))
            out.write(bytes(buf))
            out.write(b" (no-EOL)\n")
            out.flush()
        break
    buf.extend(chunk)
    while True:
        nl = buf.find(b"\n")
        if nl < 0:
            break
        line = bytes(buf[:nl])
        del buf[:nl + 1]
        # Strip a trailing CR to normalize CRLF wires.
        if line.endswith(b"\r"):
            line = line[:-1]
        out.write(f"[{stamp()}] ".encode("utf-8"))
        out.write(line)
        out.write(b"\n")
        out.flush()
' > "${CAPTURE_LOG}"
CAP_RC=$?
set -uo pipefail

case ${CAP_RC} in
    0|124|143) ;;  # clean close (see above)
    *)
        echo "capture-t14-boot: serial capture pipeline failed rc=${CAP_RC}" >&2
        # Do not exit -- fall through so the operator still gets the
        # log tail dumped if it captured partial useful bytes.
        ;;
esac

# ---------------------------------------------------------------------------
# Post-capture: zero-bytes = "adapter attached but nothing came in".
# ---------------------------------------------------------------------------

if [[ ! -s "${CAPTURE_LOG}" ]]; then
    cat >&2 <<MSG
capture-t14-boot: no serial bytes captured in ${TIMEOUT}s.

Likely causes:
  * T14 G4 never booted (BIOS boot-order not scanning USB?  Secure
    Boot still enabled?  See design/boot/t14-hw-in-loop.md §7 BIOS
    setup checklist).
  * TX/RX crossed wrong on the adapter -> T14 side.
  * Wrong tty device path (${DEVICE}); some adapters enumerate as
    /dev/ttyACM0 instead of /dev/ttyUSB0.
  * Wrong baud (${BAUD}); the kernel COM1 init is 115200 8N1 -- do
    not change unless src/kernel/boot/uart.pdx is retuned.

Log path: ${CAPTURE_LOG} (empty)
MSG
    exit 3
fi

# ---------------------------------------------------------------------------
# Fingerprint compare -- ordered-substring match against the golden.
# ---------------------------------------------------------------------------

echo ""
echo "[capture-t14-boot] capture window closed; scoring against golden"
echo "[capture-t14-boot]   log:    ${CAPTURE_LOG} ($(stat -c %s "${CAPTURE_LOG}") bytes)"
echo "[capture-t14-boot]   golden: ${GOLDEN_PATH}"
echo ""

run_fingerprint_compare "${CAPTURE_LOG}"
CMP_RC=$?

if [[ ${CMP_RC} -ne 0 ]]; then
    echo "" >&2
    echo "[capture-t14-boot] last 60 lines of ${CAPTURE_LOG}:" >&2
    tail -n 60 "${CAPTURE_LOG}" >&2 || echo "  (log unreadable)" >&2
fi

exit ${CMP_RC}
