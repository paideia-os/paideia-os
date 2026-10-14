#!/usr/bin/env bash
# tools/run-pdxfs-smoke.sh — PFS-16 corpus harness
#
# PaideiaOS pdxfs CLI integration smoke. Boots build/kernel.elf under
# QEMU, injects a per-fixture shell script through the chardev-pipe
# stdin bridge (same UART-RX pattern tools/run-smoke.sh uses for
# every shell-interactive mode), captures the serial log, and
# validates the ordered golden lines each fixture pins. This is the
# acceptance smoke for the PFS-10..PFS-15 wave and the ONE place in
# the tree where mount.pdxfs + umount.pdxfs are exercised end-to-end
# through the real interactive shell (no kernel-side witness; no
# in-process test harness).
#
# Fixtures live at tests/fixtures/pdxfs/<name>/. Each is a directory
# containing:
#
#   desc.txt         (required)  — one-line description.
#   cmdline.txt      (required)  — raw bytes injected into the shell
#                                  stdin bridge after SHELL START.
#                                  Interpreted by `printf %b` so
#                                  `\n` embeds literal newlines.
#                                  MUST end with `exit\n` to unblock
#                                  init's second wait4 (the standard
#                                  shell-reap chain all interactive
#                                  smokes rely on).
#   expected.golden  (required unless blocked.txt is present) —
#                                  ordered contains-substring list,
#                                  same shape as every other
#                                  tests/expected-*.golden. Each
#                                  line of the golden must appear
#                                  in the serial log, in order,
#                                  with later lines appearing after
#                                  earlier ones.
#   blocked.txt      (optional)  — one-line gap note citing the
#                                  substrate wave that unblocks the
#                                  fixture. When present, the
#                                  harness SKIPs the fixture with
#                                  rc=0 (reported in the summary as
#                                  BLOCKED) and does not launch
#                                  QEMU. Mutually exclusive with
#                                  expected.golden (if both present,
#                                  blocked wins and expected is
#                                  ignored with a notice).
#
# Usage:
#   tools/run-pdxfs-smoke.sh                     # run every fixture
#   tools/run-pdxfs-smoke.sh <name>              # run one fixture
#   tools/run-pdxfs-smoke.sh --list              # list fixtures
#   tools/run-pdxfs-smoke.sh -h | --help         # usage
#
# Build posture:
#   This harness does NOT invoke tools/build.sh. It validates that
#   build/kernel.elf exists before launching QEMU and bails with a
#   pointer at the main-side build step otherwise. Builds are
#   main-only (per the paideia-os loop-shape rule: softarch
#   authors, main builds, debugger verifies).
#
# Exit codes:
#   0   — every fixture passed (or SKIP/BLOCKED), no FAIL.
#   1   — one or more fixtures FAILED.
#   2   — build/kernel.elf missing OR fixture not found.
#   77  — qemu-system-x86_64 not installed (test skipped cleanly).
#
# Per-fixture timeouts: 25s wall-clock cap on QEMU + 20s INJECT_HOLD
# (matches tools/run-smoke.sh's boot_r65_persistent_home envelope,
# which is the closest precedent — same shell-interactive shape, same
# mount.pdxfs + umount.pdxfs chain, same TMPFS_MAX=256 inode budget).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname -- "$0")/.." && pwd)"
FIXTURE_ROOT="${REPO_ROOT}/tests/fixtures/pdxfs"
KERNEL="${REPO_ROOT}/build/kernel.elf"

QEMU_TIMEOUT="${QEMU_TIMEOUT:-25}"
INJECT_HOLD="${INJECT_HOLD:-20}"
INJECT_DELAY="${INJECT_DELAY:-0.3}"
INJECT_WAIT_FOR="${INJECT_WAIT_FOR:-SHELL START}"
INJECT_WAIT_TIMEOUT="${INJECT_WAIT_TIMEOUT:-15}"

usage() {
    cat <<'EOF'
tools/run-pdxfs-smoke.sh — PFS-16 corpus harness

usage:
  tools/run-pdxfs-smoke.sh                 # run every fixture under tests/fixtures/pdxfs/
  tools/run-pdxfs-smoke.sh <name>          # run one fixture (basename of its dir)
  tools/run-pdxfs-smoke.sh --list          # list fixtures with their desc.txt
  tools/run-pdxfs-smoke.sh -h | --help     # show this message

Each fixture directory holds:
  desc.txt         one-line description
  cmdline.txt      raw shell-stdin bytes (`printf %b`; ends with `exit\n`)
  expected.golden  ordered contains-substring golden
  blocked.txt      optional gap note (when present, fixture is SKIPped)

Exit codes:
  0  every fixture PASS or BLOCKED
  1  one or more fixtures FAIL
  2  build/kernel.elf missing OR fixture name not found
 77  qemu-system-x86_64 not installed

Build posture: this harness does NOT invoke tools/build.sh. Builds are
main-only — main invokes `bash tools/build.sh`, THEN re-invokes this
harness. See CLAUDE.md (loop-shape memory).
EOF
}

list_fixtures() {
    if [[ ! -d "${FIXTURE_ROOT}" ]]; then
        echo "pdxfs-smoke: no fixtures at ${FIXTURE_ROOT}" >&2
        return 2
    fi
    local name desc
    for dir in "${FIXTURE_ROOT}"/*/; do
        [[ -d "${dir}" ]] || continue
        name="$(basename "${dir}")"
        if [[ -f "${dir}/desc.txt" ]]; then
            desc="$(head -n 1 "${dir}/desc.txt")"
        else
            desc="(no desc.txt)"
        fi
        local tag="GREEN  "
        [[ -f "${dir}/blocked.txt" ]] && tag="BLOCKED"
        printf "  %-7s  %-26s  %s\n" "${tag}" "${name}" "${desc}"
    done
}

# One fixture → PASS / FAIL / BLOCKED. Prints a status line and returns:
#   0 PASS, 0 BLOCKED, 1 FAIL.
run_one_fixture() {
    local fixture_dir="$1"
    local name
    name="$(basename "${fixture_dir}")"

    if [[ ! -d "${fixture_dir}" ]]; then
        echo "pdxfs-smoke: fixture dir not found: ${fixture_dir}" >&2
        return 1
    fi

    local desc_file="${fixture_dir}/desc.txt"
    local cmdline_file="${fixture_dir}/cmdline.txt"
    local golden_file="${fixture_dir}/expected.golden"
    local blocked_file="${fixture_dir}/blocked.txt"

    local desc=""
    [[ -f "${desc_file}" ]] && desc="$(head -n 1 "${desc_file}")"

    # Blocked path: cite the gap, do not launch QEMU, report as BLOCKED
    # (counts as 0 under the summary — the whole point of the gap note
    # is that today's substrate does not yet reach the fixture).
    if [[ -f "${blocked_file}" ]]; then
        local reason
        reason="$(head -n 1 "${blocked_file}")"
        printf "  BLOCKED  %-26s  %s\n" "${name}" "${reason}"
        return 0
    fi

    if [[ ! -f "${cmdline_file}" ]]; then
        printf "  FAIL     %-26s  missing cmdline.txt\n" "${name}"
        return 1
    fi
    if [[ ! -f "${golden_file}" ]]; then
        printf "  FAIL     %-26s  missing expected.golden (and no blocked.txt)\n" "${name}"
        return 1
    fi

    local inject_string
    inject_string="$(cat "${cmdline_file}")"
    if [[ -z "${inject_string}" ]]; then
        printf "  FAIL     %-26s  empty cmdline.txt\n" "${name}"
        return 1
    fi

    # Per-fixture serial log + chardev-pipe FIFOs. Named-pipe discipline
    # mirrors tools/run-smoke.sh's UART_RX_MODE branch byte-for-byte:
    # QEMU opens .in for READ and .out for WRITE, both opens block
    # until the host side is attached, so the reader + writer must be
    # live BEFORE QEMU launches.
    local fifo_base="/tmp/paideia-pdxfs-smoke-$$-${name}"
    local fifo_in="${fifo_base}.in"
    local fifo_out="${fifo_base}.out"
    local log="/tmp/paideia-pdxfs-smoke-$$-${name}.log"
    rm -f "${fifo_in}" "${fifo_out}" "${log}"
    mkfifo "${fifo_in}" "${fifo_out}"

    # Background reader: drain guest TX into LOG. line-buffered via
    # stdbuf so the writer's INJECT_WAIT_FOR grep on LOG sees the
    # SHELL START marker without waiting for cat's ~4KB stdio buffer
    # to fill.
    if command -v stdbuf >/dev/null 2>&1; then
        stdbuf -oL cat "${fifo_out}" > "${log}" &
    else
        cat "${fifo_out}" > "${log}" &
    fi
    local reader_pid=$!

    # Background writer: hold .in open for QEMU's 16550 read side.
    # Polls for INJECT_WAIT_FOR (SHELL START) before injecting so the
    # bytes do not race the earlier tty stdin bridge sub-tests into
    # consuming them. INJECT_HOLD keeps the pipe alive long enough for
    # the shell to process the full cmdline sequence through its
    # sys_read → dispatch → execve/wait4 round trip.
    (
        local wait_start=${SECONDS}
        while (( SECONDS - wait_start < INJECT_WAIT_TIMEOUT )); do
            if [[ -s "${log}" ]] && grep -q "${INJECT_WAIT_FOR}" "${log}" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done
        sleep "${INJECT_DELAY}"
        printf '%b' "${inject_string}"
        sleep "${INJECT_HOLD}"
    ) > "${fifo_in}" &
    local writer_pid=$!

    # QEMU launch. Flags mirror tools/run-smoke.sh's UART_RX_MODE branch
    # (see run-smoke.sh L2825-2836 — isa-debug-exit for the kernel's
    # clean-exit handshake, chardev pipe for the stdin bridge, -serial
    # chardev:char0 for the TX drain, -display none for headless, -m 32M
    # matching every other interactive smoke). No -smp (single-CPU is
    # the pdxfs tooling baseline), no -vga (no GUI exercise), no NVMe
    # drive attach (pdxfs tooling is still dry-run-dominated at this
    # wave — the real --with-disk path lands with PFS-N follow-up).
    timeout "${QEMU_TIMEOUT}" qemu-system-x86_64 \
        -kernel "${KERNEL}" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -chardev pipe,id=char0,path="${fifo_base}" \
        -serial chardev:char0 \
        -display none \
        -no-reboot \
        -no-shutdown \
        -m 32M \
        >/dev/null 2>&1
    local qemu_rc=$?

    # Tear down the chardev-pipe background procs. Both may already
    # have exited (reader on EOF when QEMU closed TX; writer on
    # INJECT_HOLD elapse).
    kill "${writer_pid}" 2>/dev/null || true
    kill "${reader_pid}" 2>/dev/null || true
    wait "${writer_pid}" 2>/dev/null || true
    wait "${reader_pid}" 2>/dev/null || true
    rm -f "${fifo_in}" "${fifo_out}"

    # QEMU exit-code taxonomy: 124 = timeout (expected — the kernel
    # idles after init's sys_exit); 0 = clean (unlikely under -no-
    # shutdown + no isa-debug-exit byte from this path); 35 = panic
    # exit (isa-debug-exit byte 0x11 << 1 | 1). Every other rc is a
    # fail. Matches tools/run-smoke.sh L2927-2931.
    if [[ ${qemu_rc} -ne 0 && ${qemu_rc} -ne 124 && ${qemu_rc} -ne 35 ]]; then
        printf "  FAIL     %-26s  qemu rc=%d (log=%s)\n" "${name}" "${qemu_rc}" "${log}"
        return 1
    fi

    # Ordered golden check — same contains-in-order algorithm
    # tools/run-smoke.sh uses for every tests/expected-*.golden
    # (run-smoke.sh L2945-2977). Each non-empty line of the golden
    # must appear in the serial log after the previous match's
    # position. Empty lines are skipped.
    if [[ ! -s "${log}" ]]; then
        printf "  FAIL     %-26s  empty serial log (qemu rc=%d, log=%s)\n" "${name}" "${qemu_rc}" "${log}"
        return 1
    fi
    local log_content
    log_content="$(cat "${log}" 2>/dev/null || echo "")"
    local line_num=0
    local search_offset=0
    local line remaining prefix

    while IFS= read -r line || [[ -n "${line}" ]]; do
        ((line_num++)) || true
        if [[ -z "${line}" ]]; then
            continue
        fi
        remaining="${log_content:search_offset}"
        if [[ "${remaining}" == *"${line}"* ]]; then
            prefix="${remaining%%"${line}"*}"
            search_offset=$((search_offset + ${#prefix} + ${#line}))
        else
            printf "  FAIL     %-26s  golden line %d NOT found after offset %d: '%s' (log=%s)\n" \
                "${name}" "${line_num}" "${search_offset}" "${line}" "${log}"
            return 1
        fi
    done < "${golden_file}"

    printf "  PASS     %-26s  %s\n" "${name}" "${desc}"
    rm -f "${log}"
    return 0
}

# ------------------------------------------------------------
# argv entry
# ------------------------------------------------------------
case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    --list)
        list_fixtures
        exit $?
        ;;
esac

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "pdxfs-smoke: qemu-system-x86_64 not found; skipping" >&2
    exit 77
fi

if [[ ! -f "${KERNEL}" ]]; then
    echo "pdxfs-smoke: ${KERNEL} not found" >&2
    echo "pdxfs-smoke: builds are main-only — run 'bash tools/build.sh' then re-invoke this harness" >&2
    exit 2
fi

if [[ ! -d "${FIXTURE_ROOT}" ]]; then
    echo "pdxfs-smoke: fixture root not found: ${FIXTURE_ROOT}" >&2
    exit 2
fi

# Single-fixture path.
if [[ -n "${1:-}" ]]; then
    fixture_dir="${FIXTURE_ROOT}/$1"
    if [[ ! -d "${fixture_dir}" ]]; then
        echo "pdxfs-smoke: fixture '$1' not found at ${fixture_dir}" >&2
        echo "pdxfs-smoke: use --list to enumerate." >&2
        exit 2
    fi
    echo "pdxfs-smoke: running fixture '${1}'"
    if run_one_fixture "${fixture_dir}"; then
        exit 0
    else
        exit 1
    fi
fi

# Full matrix.
echo "pdxfs-smoke: PFS-16 corpus harness — mount.pdxfs + umount.pdxfs matrix"
echo "pdxfs-smoke: kernel=${KERNEL}"
echo "pdxfs-smoke: fixtures=${FIXTURE_ROOT}"
echo

pass=0
fail=0
blocked=0
failed_names=()

for dir in "${FIXTURE_ROOT}"/*/; do
    [[ -d "${dir}" ]] || continue
    name="$(basename "${dir}")"
    if [[ -f "${dir}/blocked.txt" ]]; then
        if run_one_fixture "${dir}"; then
            ((blocked++)) || true
        else
            ((fail++)) || true
            failed_names+=("${name}")
        fi
        continue
    fi
    if run_one_fixture "${dir}"; then
        ((pass++)) || true
    else
        ((fail++)) || true
        failed_names+=("${name}")
    fi
done

echo
echo "pdxfs-smoke: summary — pass=${pass} fail=${fail} blocked=${blocked}"
if (( fail > 0 )); then
    echo "pdxfs-smoke: failed fixtures:"
    for n in "${failed_names[@]}"; do
        echo "  - ${n}"
    done
    exit 1
fi
exit 0
