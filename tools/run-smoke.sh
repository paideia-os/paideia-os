#!/usr/bin/env bash
# Phase-1 smoke regression: builds the kernel, runs under QEMU with a
# configurable timeout, captures serial output, and asserts deterministic
# bytes.
#
# Usage: tools/run-smoke.sh [--with-disk] [--wipe] [MODE | expected_marker | --fingerprint PATTERN]
#
# Leading flags (R53.M4-001 #1748):
#   --with-disk           Attach an emulated NVMe drive backed by a
#                         persistent raw image at the DISK_IMAGE_PATH
#                         resolved by the R53.M4-002 #1749 image
#                         lifecycle block (default:
#                         ${CLAUDE_JOB_DIR}/tmp/pdxb-smoke.img when
#                         CLAUDE_JOB_DIR is set, else
#                         /tmp/paideia-pdxb-smoke.img — overridable
#                         via DISK_IMAGE_PATH env). Missing images are
#                         mkfs'd through tools/mkfs-pdxb.sh (R53.M1-002
#                         #1731) before QEMU launch.
#   --wipe                Force re-mkfs (mkfs-pdxb.sh --force) of the
#                         backing image even when it already exists.
#                         No-op unless --with-disk is also passed.
#                         Default: keep existing image contents so a
#                         cross-invocation write → reboot → read-verify
#                         progression can compose (R53.M4-005 round-
#                         trip smoke).
#
# Backward compat: legacy NVME_MODE=1 env (R52.M8-001 #1721) still
# selects the tempfile-based raw-zero-fill path used by
# boot_r52_pdxfs_mkfs_nvme — it is independent of --with-disk /
# --wipe. Every legacy invocation without the new flags launches
# QEMU byte-for-byte as before.
#
#   - MODE: one of 'boot_min', 'boot_banner', 'boot_tick', 'boot_r8_only', 'boot_r10', 'boot_r11', 'boot_r12', 'boot_r12_denial', 'boot_r14b_hivma', 'boot_r14b_kpti', 'boot_r14b_ipi', 'boot_r14b_loader', 'boot_r14b_ud', 'boot_r15_ring3', 'boot_r15_process', 'boot_r16_uart_rx', 'boot_r17_init', 'boot_r17_shell_echo_hello', 'boot_r17_shell_multi_command', 'boot_r17_shell_child_process', 'boot_r17_shell_shutdown', 'boot_smp', 'boot_r31_spawn_pair', 'boot_r86_relative_path', 'boot_r64v2_tools', 'boot_r65_persistent_home', 'boot_panic', 'boot_release', 'prod' (mode dispatcher)
#     * boot_min: validates boot_min fingerprint, 5s timeout
#     * boot_banner: validates boot_banner fingerprint, 5s timeout
#     * boot_tick: validates boot_tick fingerprint (with timer TICKs), 5s timeout
#     * boot_r8_only: validates R8-only fingerprint (no timer, no IDT), 5s timeout
#     * boot_r10: validates R10 task alternation fingerprint (Task A/B cooperative yield), 10s timeout
#     * boot_r11: validates R11 softer task alternation fingerprint (Task A/B/A cooperative), 10s timeout
#     * boot_r12: validates R12 capability dispatch fingerprint (5 cap tags + 3 task lines), 8s timeout
#     * boot_r12_denial: validates R12 rights-denial witness (CAP DENIED between CAP INVOKE DEV and CAP DISPATCH OK), 8s timeout
#     * boot_r14b_hivma: validates R14B higher-half execution witness (HI VA FFFF8000), 5s timeout
#     * boot_r14b_kpti: validates R14B KPTI structural witness (KPTI OK), 5s timeout
#     * boot_r14b_ipi: validates R14B IPI structural witness (IPI OK), 5s timeout
#     * boot_r14b_loader: validates R14B LOADER witness, 8s timeout
#     * boot_r14b_ud: validates R14B undefined-instruction witness, 6s timeout
#     * boot_r15_ring3: validates R15 ring-3 + fd_table + single-task witness, 6s timeout
#     * boot_r15_process: validates R15 3-task pool witness with pids=1,2,3, 6s timeout
#     * boot_r16_uart_rx: validates R16.M4-666 real-IRQ UART RX end-to-end smoke, 10s timeout, injects 'abc' via QEMU chardev pipe
#     * boot_r17_init: validates R17 init load structural witness (task_new + elf_lite_load), 8s timeout
#     * boot_r17_shell_echo_hello: injects 'echo hello\nexit\n' after SHELL START, asserts echo + shell-reap chain, 12s timeout (R17.M5 #636/#751/#752)
#     * boot_r17_shell_multi_command: injects 'pwd\ncd /tmp\npwd\nhelp\nexit\n', asserts /tmp + help output + REAPED (R17.M5 #637)
#     * boot_r17_shell_child_process: injects 'true\nexit\n', asserts TRUE OK from /bin/true + shell-reap chain (R17.M5 #638)
#     * boot_r17_shell_shutdown: injects 'exit\n', asserts shell exit + init reap + init shutdown (R17.M5 #639)
#     * boot_r86_relative_path: injects 'mkdir /tmp\ncd /tmp\nmkdir ./sub\ncd ./sub\nmkdir ../peer\npwd\nexit\n', asserts cd/mkdir fingerprints + literal '/tmp/sub' + REAPED (R86.M1-008 #1961)
#     * boot_r64v2_tools: injects 'mkfs.pdxfs --dry-run /tmp/t.img\nexit\n', asserts sys execve argv ok + the mkfs.pdxfs dry-run preview line + REAPED (R64v2, paideia-os#1976/#1977)
#     * boot_r65_persistent_home: PHASE 1 ONLY (phase 2 deferred to R51/R52). Injects 'mkdir /home\nmkdir /home/operator\nmkfs.pdxfs --dry-run /var/pdxfs/home.img\nmount.pdxfs --dry-run cap:volume:0x0001 /home/operator\ntouch /home/operator/probe.txt\nexit\n', asserts the two mkdir fingerprints + both tools' dry-run preview lines + REAPED, 32s timeout. Opt-in via PAIDEIA_R65_PERSIST=1 (R65v2.M1-004/005, paideia-os#1982/#1983)
#     * boot_r72_tcp_echo: validates the R72 TCP substrate boot witness (self-connect handshake + port-7 echo + mutual orderly close), 10s timeout, no special QEMU flags (R72.M1-007 #1929)
#     * boot_r92_icmp: validates the R92.M3 off-box ICMP-ping cascade (route-table update witness + arp-pending retry + arp-resolve + icmp echo/reply against QEMU SLIRP's gateway 10.0.2.2), 15s timeout, requires PAIDEIA_NIC=virtio (default) so run-qemu.sh attaches -netdev user + -device virtio-net-pci giving SLIRP networking (R92.M3-003 paideia-os #2041)
#     * boot_r93_udp_dns: validates the R93 DHCP+DNS cascade -- DHCP DISCOVER/OFFER/REQUEST/ACK against QEMU SLIRP (10.0.2.15/24, gw 10.0.2.2, dns 10.0.2.3) followed by an A-record resolution of "example.com" against 10.0.2.3. Golden pins both lease-ok and dns-resolve-ok fingerprints. 20s timeout, requires PAIDEIA_NIC=virtio for SLIRP responsiveness. R98.M1-002 (#2101) added PAIDEIA_NET_SMOKE=1 gate (skips cleanly outside the lane) (R93.M4-001 paideia-os #2058)
#     * boot_r94_tcp_offbox: validates the R94 hardened TCP cascade against QEMU SLIRP's hostfwd. Fingerprint contract (R98.M2-002 #2103 tightened) pins the ok pair (handshake_ok + roundtrip_ok bytes=4 -- matches tools/net-smoke-httpd.sh's PAYLOAD=PONG default). 20s timeout, requires PAIDEIA_NET_SMOKE=1 + PAIDEIA_HOSTFWD='tcp::5555-:5555' + tools/net-smoke-httpd.sh listener on host tcp/5555. Skips cleanly outside the lane (R98.M1-002 #2101).
#     * boot_r91_nic: pins the R91.M5-003 NIC probe fingerprint `boot r91 nic probe ok` (retires R91.M6 deferred item #8). 10s timeout, PAIDEIA_NET_SMOKE=1 gated (R98.M1-001 #2100).
#     * boot_net_smoke: networking-smoke lane composite. Runs boot_r91_nic + boot_r93_udp_dns + boot_r94_tcp_offbox in sequence, starts+kills tools/net-smoke-httpd.sh around the R94 leg, aborts on first failure, emits a single rollup line. Sets PAIDEIA_NET_SMOKE=1 + PAIDEIA_HOSTFWD='tcp::5555-:5555' for its children (R98.M1-001/002 paideia-os #2100/#2101).
#     * boot_smp: validates R18.M1 SMP bring-up fingerprint on -smp 4; BSP wakes 3 APs (APIC IDs 1/2/3), each emits CPU_ID_XX_HELLO; bookended by SMP BRINGUP START / DONE (R18.M1 #764)
#     * boot_panic: validates M3-003 fake-panic emission chain witness, 8s timeout
#     * prod: expects exit code 2 (kernel didn't build), skips verification
#   - expected_marker: defaults to no-check (just confirms QEMU exits or
#     times out cleanly). Pass a string to grep the serial log for.
#   - --fingerprint PATTERN: validate serial output against tests/r8/expected-PATTERN.txt
#     file; checks that all lines from the fingerprint file appear in order in the log
#     (contains-in-order check, not strict equality).
#
# Exit codes:
#   0  — kernel built + booted + (optional) expected marker found
#   1  — kernel built but smoke failed (no marker / unexpected QEMU exit)
#   2  — kernel didn't build
#  33  — kernel graceful clean exit (isa-debug-exit byte 0x10 → QEMU exits (0x10 << 1) | 1 = 33)
#  35  — kernel failed exit (isa-debug-exit byte 0x11 → QEMU exits (0x11 << 1) | 1 = 35)
#  77  — QEMU not installed (test skipped)
# 124  — smoke timeout (5s runner timeout)
# 137  — kernel killed (OOM / other fatal signal)

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

# R53.M4-001 (#1748): leading flag parser for --with-disk / --wipe.
#
# Runs BEFORE `EXPECTED="${1:-}"` so the positional MODE / marker /
# --fingerprint slot is preserved once recognized flags are shifted
# off. Only `--with-disk` and `--wipe` are consumed here — any other
# leading double-dash token is either the existing `--fingerprint`
# form (handled after the mode dispatcher — kept intact) or an
# unknown flag (surfaced as an error). Bare positional args (mode
# names, expected markers) terminate the loop untouched.
#
# Backward compat: legacy invocations without either flag walk out of
# the loop with $@ unchanged, so `EXPECTED="${1:-}"` and every
# downstream `${2:-}` reference behave byte-for-byte as before.
# Legacy NVME_MODE=1 env stays supported (see NVMe attach block
# below) — it takes the tempfile path unchanged.
WITH_DISK=0
WIPE_DISK=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-disk)
            WITH_DISK=1
            shift
            ;;
        --wipe)
            WIPE_DISK=1
            shift
            ;;
        --fingerprint|--)
            # --fingerprint is handled by the existing post-dispatcher
            # parser (kept for backward compat). `--` terminates flag
            # parsing explicitly. Either way, stop consuming here.
            break
            ;;
        --*)
            echo "smoke: unknown flag $1" >&2
            echo "usage: $(basename "$0") [--with-disk] [--wipe] [MODE | marker | --fingerprint PATTERN]" >&2
            exit 2
            ;;
        *)
            break
            ;;
    esac
done

EXPECTED="${1:-}"
FINGERPRINT_MODE=0
FINGERPRINT_FILE=""
TIMEOUT=5
UART_RX_MODE=0
# R18-M1 #764: boot_smp knobs.
#   SMP_MODE               — enable multicore QEMU launch (`-smp N`).
#   SMP_CPU_COUNT          — how many CPUs QEMU exposes (BSP + APs).
#                            Kernel's AP list is hard-coded to 3 APs
#                            (ap_list.pdx), so 4 (= BSP + 3 APs) is the
#                            R18.M1 default. Raising it needs the AP list
#                            + N_APS to grow in lockstep (R20-M2 MADT
#                            work).
#   SMP_UNORDERED_HELLO    — treat CPU_ID_XX_HELLO fingerprint lines as
#                            presence-only (no cross-AP ordering).
#                            The BSP START / DONE bookends stay ordered.
SMP_MODE=0
SMP_CPU_COUNT=1
SMP_UNORDERED_HELLO=0
# R21-M2 #832: QEMU_CPU knob for smoke modes that need CPUID feature bits
# beyond qemu64-default (e.g. XSAVE, AVX2 for boot_r21_ymm_preserve).
# Empty (default): no `-cpu` flag → qemu64 default. Set to "max" for the
# widest advertised feature surface — enables XSAVE, AVX2, POPCNT, etc.
QEMU_CPU=""
# R52.M8-001 (#1721): NVME_MODE knob attaches a blank raw-format image
# backing an emulated NVMe controller to QEMU (-drive if=none + -device
# nvme). MCFG remains ABSENT under -kernel boot (no OVMF), so PCI
# enumeration still finds zero devices and the boot-witness path stays
# on the SUBSTRATE arm; the drive attach is what proves the QEMU wiring
# is in place for the LIVE arm once UEFI/OVMF wire-up lands (#1722-#1726).
# NVME_IMG defaults to a per-invocation tempfile created below when
# NVME_MODE=1; NVME_IMG_SIZE_MB defaults to 16 MB (>> mkfs geometry the
# witness attempts, which is 100 * 4096 B = 400 KB).
NVME_MODE=0
NVME_IMG=""
NVME_IMG_SIZE_MB=16
# #750 + #757: chardev-pipe injection knobs.
#
# Precedence:  caller env  >  mode-branch default  >  global fallback
#
# The case dispatcher below may set mode-specific defaults via
# `: "${VAR:=...}"` — those fire only when the caller did NOT export
# the var (or exported it empty). After the dispatcher, the "Global
# injection defaults" block fills in any remaining unset knobs with
# the historical boot_r16_uart_rx values, keeping that mode byte-for-
# byte unchanged.
#
# Knobs:
#   INJECT_STRING         — bytes to write into FIFO_IN. `printf %b`
#                           interprets escape sequences (`\n`, `\t`).
#   INJECT_DELAY          — seconds to sleep after WAIT_FOR (or on
#                           subshell entry if WAIT_FOR is empty).
#   INJECT_HOLD           — seconds to keep FIFO_IN open after writes
#                           complete, so QEMU's 16550 read side does
#                           not EOF mid-boot.
#   INJECT_WAIT_FOR       — #757: optional pattern; if set, the writer
#                           polls the serial log for this string
#                           before injecting, replacing the blind
#                           sleep-then-write timing. Closes the race
#                           where injection lands before the guest
#                           reaches the readiness state the injection
#                           is meant to exercise (observed ~5/6 failure
#                           rate on shell interactivity when bytes
#                           were written at t≈1s but the shell did not
#                           reach the read window until t≈4-5s, and
#                           earlier tty sub-tests consumed the bytes
#                           silently).
#   INJECT_WAIT_TIMEOUT   — max integer seconds to wait for
#                           INJECT_WAIT_FOR before falling through and
#                           injecting anyway (default 8).
#   INJECT_RETRIES        — number of times to write INJECT_STRING
#                           (default 1). >1 re-injects with
#                           INJECT_RETRY_INTERVAL between attempts;
#                           useful when a single write may not overlap
#                           the guest's read window.
#   INJECT_RETRY_INTERVAL — seconds between retry writes (default 0.5).
#
# `set -u` is on above; the `${VAR-}` form (no colon) is a
# safe-read that yields empty if unset, without triggering an
# unbound-variable error. Do NOT change to `${VAR}` here.
INJECT_STRING="${INJECT_STRING-}"
INJECT_DELAY="${INJECT_DELAY-}"
INJECT_HOLD="${INJECT_HOLD-}"
INJECT_WAIT_FOR="${INJECT_WAIT_FOR-}"
INJECT_WAIT_TIMEOUT="${INJECT_WAIT_TIMEOUT-}"
INJECT_RETRIES="${INJECT_RETRIES-}"
INJECT_RETRY_INTERVAL="${INJECT_RETRY_INTERVAL-}"

# Mode dispatcher: map boot_min/boot_banner/boot_tick/boot_r8_only/boot_r10/boot_r11/prod to fingerprint + timeout
case "${EXPECTED}" in
    boot_min)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r8/expected-boot-min.txt"
        TIMEOUT=5
        EXPECTED=""
        ;;
    boot_banner)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r8/expected-boot-banner.txt"
        TIMEOUT=5
        EXPECTED=""
        ;;
    boot_tick)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r9/expected-boot-tick.txt"
        TIMEOUT=5
        EXPECTED=""
        ;;
    boot_r8_only)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r9/expected-r8-only.txt"
        TIMEOUT=5
        EXPECTED=""
        ;;
    boot_r10)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r10/expected-boot-r10.txt"
        TIMEOUT=10
        EXPECTED=""
        ;;
    boot_r11)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r11/expected-boot-r11.txt"
        TIMEOUT=10
        EXPECTED=""
        ;;
    boot_r12)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r12/expected-boot-r12.txt"
        TIMEOUT=8
        EXPECTED=""
        ;;
    boot_r12_denial)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r12/expected-boot-r12-denial.txt"
        TIMEOUT=8
        EXPECTED=""
        ;;
    boot_r14b_hivma)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r14b/expected-boot-r14b-hivma.txt"
        TIMEOUT=5
        EXPECTED=""
        ;;
    boot_r14b_kpti)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r14b/expected-boot-r14b-kpti.txt"
        TIMEOUT=5
        EXPECTED=""
        ;;
    boot_r14b_ipi)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r14b/expected-boot-r14b-ipi.txt"
        TIMEOUT=5
        EXPECTED=""
        ;;
    boot_r14b_loader)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r14b/expected-boot-r14b-loader.txt"
        TIMEOUT=8
        EXPECTED=""
        ;;
    boot_r14b_ud)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r14b/expected-boot-r14b-ud.txt"
        TIMEOUT=6
        EXPECTED=""
        ;;
    boot_r15_ring3)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r15/expected-boot-r15-ring3.txt"
        TIMEOUT=6
        EXPECTED=""
        ;;
    boot_r15_process)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r15/expected-boot-r15-process.txt"
        TIMEOUT=6
        EXPECTED=""
        ;;
    boot_r16_uart_rx)
        # R16.M4-666 (#666): real IRQ-driven end-to-end UART RX smoke.
        # Kernel witness (kernel_main.pdx: uart_rx_wire_witness) `sti`s
        # briefly before lapic_timer_init, polls _uart_rx_ring for 3 bytes,
        # then emits "UART RX: abc\n" via uart_puts. Fingerprint requires
        # this second "UART RX: abc" line AFTER the #601 structural one.
        # QEMU serial is bridged through a named-pipe chardev so the smoke
        # driver can inject 'abc' after kernel boot has ERBFI armed.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r16/expected-boot-r16-uart-rx.txt"
        TIMEOUT=10
        UART_RX_MODE=1
        EXPECTED=""
        ;;
    boot_r17_init)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r17/expected-boot-r17-init.txt"
        # paideia-os #747: TIMEOUT reverted 20 → 8. Root cause of the flake
        # (uart_rx_wire_witness cycle-count-bound 200M-iteration busy-wait
        # scaling with host CPU contention) fixed in kernel_main.pdx by
        # replacing the countdown with an rdtsc-referenced ~2 s wall-clock
        # budget. See kernel_main.pdx uart_rx_wire_witness comment block
        # and paideia-os commit that pairs with this revert. The temporary
        # workaround landed at ce3a17f; this revert closes the loop.
        TIMEOUT=8
        EXPECTED=""
        ;;
    boot_r17_shell_echo_hello)
        # R17.M5 #636 / #751 / #752 (formerly `boot_r17_shell_interactive`
        # from #757): end-to-end shell interactivity smoke. Reuses the
        # boot_r17_init kernel (init forks child_hello then execs /bin/sh
        # from tmpfs seed). Injects `echo hello\nexit\n` via the chardev-
        # pipe path after the shell prints "SHELL START" (INJECT_WAIT_FOR
        # anchors on the shell-entry witness so injection cannot race the
        # earlier tty stdin bridge sub-test into consuming the bytes).
        # Fingerprint asserts the shell interactivity chain: SHELL START,
        # then the echo builtin's "hello" output, then init's second
        # wait4 reaping the shell (REAPED).
        #
        # Rename note: the R14B tactical plan (§Subsystem 20) names the
        # mode + golden per this R17.M5 form. The #757-era name
        # `boot_r17_shell_interactive` was a provisional placeholder that
        # predated the batched R17.M5 landing; it is renamed here so the
        # smoke inventory matches the design doc verbatim. The kernel
        # #758 fix (idle sti+hlt loop, landed pre-#757 close) makes the
        # chain deterministic (5/5 in the sandbox).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r17/shell-echo-hello.golden"
        TIMEOUT=12
        UART_RX_MODE=1
        # Defaults chosen for interactivity workload. Env overrides
        # (INJECT_STRING/DELAY/HOLD/WAIT_FOR) still win: the top-of-
        # file init leaves each knob empty when the caller did not
        # export it, so `${VAR:=default}` fires here for those, and
        # the global-defaults block below preserves boot_r16 behavior
        # for anything not explicitly set here or by the caller.
        : "${INJECT_STRING:=echo hello\nexit\n}"
        : "${INJECT_WAIT_FOR:=SHELL START}"
        : "${INJECT_DELAY:=0.3}"
        : "${INJECT_HOLD:=10}"
        EXPECTED=""
        ;;
    boot_r17_shell_multi_command)
        # R17.M5 #637: multi-command shell smoke. Injects the tactical-
        # plan's exact script `pwd\ncd /tmp\npwd\nhelp\nexit\n`. Golden
        # asserts, in order: SHELL START (shell entry), `/tmp` (from
        # the second `pwd` after cd), the `echo - echo text to stdout`
        # line (a distinctive fragment of `help`'s output that could
        # not appear elsewhere in the boot log), `hello world` (regression
        # for #1016 — space between multi-token echo args), REAPED (init's
        # second wait4 unblocking on the shell exit).
        #
        # INJECT_HOLD is bumped to 14s (vs echo_hello's 10s) so the
        # pipe stays open long enough for the shell to process six
        # sequential lines through the tty stdin bridge; each line
        # requires a full sys_read → dispatch → puts_new round trip.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r17/shell-multi-command.golden"
        TIMEOUT=17
        UART_RX_MODE=1
        : "${INJECT_STRING:=pwd\ncd /tmp\npwd\nhelp\necho hello world\nexit\n}"
        : "${INJECT_WAIT_FOR:=SHELL START}"
        : "${INJECT_DELAY:=0.3}"
        : "${INJECT_HOLD:=14}"
        EXPECTED=""
        ;;
    boot_r17_shell_child_process)
        # R17.M5 #638: shell fork+execve+wait4 of /bin/true. The shell
        # sees `true`, resolves to /bin/true via resolve_path, forks,
        # execves the trivial user binary (src/user/true.pdx). The
        # binary writes "TRUE OK\n" to fd 1 then sys_exit(0). Shell's
        # wait4 returns; shell reprompts. Then `exit` unblocks init's
        # second wait4.
        #
        # Golden asserts: SHELL START, sys execve argv ok (R62.M1-002/003
        # #1826/#1829 — proves the shell's argv=["true"], envp=NULL
        # marshalled through sys_execve_shim before /bin/true's image
        # loaded), TRUE OK (proves /bin/true was tmpfs-seeded,
        # path-resolved, ELF-loaded, ran in ring-3, and wrote to
        # shell-inherited stdout), REAPED (init reap of the shell — pid=3,
        # since /bin/true is pid=4 and is reaped by the shell, not init).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r17/shell-child-process.golden"
        TIMEOUT=15
        UART_RX_MODE=1
        : "${INJECT_STRING:=true\nexit\n}"
        : "${INJECT_WAIT_FOR:=SHELL START}"
        : "${INJECT_DELAY:=0.3}"
        : "${INJECT_HOLD:=12}"
        EXPECTED=""
        ;;
    boot_r17_shell_shutdown)
        # R17.M5 #639: shell shutdown smoke. Injects `exit\n` only —
        # the shortest script that exercises the full clean-shutdown
        # chain. Shell's exit_builtin calls sys_exit(0); init's second
        # wait4 unblocks with pid=3 status=0; init emits `WAIT: pid=3
        # status=0` + `REAPED` + calls sys_exit(0). Kernel drops back
        # to idle (no more runnable tasks). #639's stricter AC —
        # `qemu` exits with ACPI shutdown handshake — is deferred to
        # a later issue that lands the ACPI shutdown path; here we
        # assert the observable init side of the chain.
        #
        # R31.M5-001 (#1106) bumped this from 12s to 15s: the backlight
        # witness adds one more cluster (KIND_BACKLIGHT OK + BACKLIGHT
        # SCALE OK) plus its debug-print pass, which slid the tail of
        # the sequence past the previous 12s bound.
        #
        # R31.M6-#1580 bumped 15s -> 17s: global_lock_witness adds a
        # synthetic-FADT parse + ec_access_bind_arbitration end-to-end
        # exercise before ec_query_witness, and the added instructions
        # push the tail of the sequence far enough that COOLING SCALE OK
        # was landing after the previous 15s window closed on slower
        # runners.
        #
        # R32.M3-001/002 (#1125/#1126) bumped 17s -> 22s: the KIND_HID_
        # DEVICE and KIND_HID_EVENT witnesses each drive twelve stages
        # of mint / revoke / dispatch through cap_mint_write (which
        # emits an audit record per call) and end with a debug_print
        # KV-line pass, and the added instructions push the tail past
        # the previous 17s window on slower runners. The bump keeps the
        # smoke bound proportional to the ADDED work rather than to any
        # unrelated slowdown -- 5 seconds is roughly two witnesses'
        # worth of the same shape the R31.M5 backlight bump measured.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r17/shell-shutdown.golden"
        TIMEOUT=22
        UART_RX_MODE=1
        : "${INJECT_STRING:=exit\n}"
        : "${INJECT_WAIT_FOR:=SHELL START}"
        : "${INJECT_DELAY:=0.3}"
        : "${INJECT_HOLD:=13}"
        EXPECTED=""
        ;;
    boot_r86_relative_path)
        # R86.M1-008 (paideia-os #1961): relative-path substrate
        # composite smoke. Real ring-3 exercise of sys_chdir (sysno 85)
        # + sys_getcwd (sysno 86) + the cwd-threaded sys_mkdir (sysno
        # 79), through the ACTUAL shell (cd/pwd builtins, R86.M1-006/007
        # #1959/#1960) and the ACTUAL /bin/mkdir binary (src/user/
        # mkdir.pdx) -- not a kernel-side boot witness. A kernel-side
        # witness structurally cannot exercise these bodies: sys_chdir_
        # body / sys_getcwd_body / sys_mkdir_body all resolve their
        # path argument via user_read_str_via_walk / user_write_bytes_
        # via_walk, which validate the pointer against the CURRENT
        # task's real page tables -- exactly the limitation the R56.M3-
        # 006 dormant scaffold (src/kernel/boot/witness/r56_meta.pdx)
        # documents for the sibling VFS-metadata syscalls. Driving the
        # same syscalls through the real interactive shell (this smoke's
        # approach, mirroring boot_r17_shell_multi_command) sidesteps
        # the limitation entirely: the shell IS a real ring-3 task with
        # a real user aspace.
        #
        # Script: `mkdir /tmp` first (nothing seeds /tmp at boot), then
        # `cd /tmp`, `mkdir ./sub`, `cd ./sub`, `mkdir ../peer`, `pwd`,
        # `exit`. Every mkdir target after the first contains a '/'
        # (`./sub`, `../peer`) rather than a bare name -- sys_mkdir's
        # last-slash parent-path split has a known, pre-existing,
        # out-of-R86-scope gap that rejects a bare no-slash relative
        # name (see sys_mkdir.pdx's "no slash found -> ENOENT" branch);
        # this smoke does not exercise that path.
        #
        # Golden asserts, in order: SHELL START, `shell cd ok -- path=`
        # (cd_builtin's fingerprint after `cd /tmp`, proving sys_chdir
        # wrote TASK_OFF_CWD), `sys mkdir ok` (the `mkdir ./sub` call,
        # its parent-path "." resolving against the NEW cwd), a second
        # `shell cd ok -- path=` (after `cd ./sub`), a second `sys mkdir
        # ok` (the `mkdir ../peer` call, proving ".." walks back up via
        # vnode parent_idx to /tmp), the literal ASCII substring
        # `/tmp/sub` (pwd_builtin's sys_write of the sys_getcwd-composed
        # path -- the actual end-to-end proof that TASK_OFF_CWD
        # threading + the R86.M1-002/003 vnode name table + the parent-
        # chain walk all agree), and REAPED (shell exit unblocking
        # init's wait4).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/expected-r86-relative-path.golden"
        TIMEOUT=26
        UART_RX_MODE=1
        : "${INJECT_STRING:=mkdir /tmp\ncd /tmp\nmkdir ./sub\ncd ./sub\nmkdir ../peer\npwd\nexit\n}"
        : "${INJECT_WAIT_FOR:=SHELL START}"
        : "${INJECT_DELAY:=0.3}"
        : "${INJECT_HOLD:=20}"
        EXPECTED=""
        ;;
    boot_r64v2_tools)
        # R64v2 (paideia-os#1976/#1977): satellite volume-tool ELF
        # pipeline composite smoke. Real ring-3 exercise of
        # sys_execve_shim's path-based execve against the ACTUAL
        # /bin/mkfs.pdxfs binary (tools/user/mkfs.pdxfs submodule,
        # linked via tools/build.sh's r64v2-tools step, tmpfs-seeded by
        # bin_seeds.pdx's bs_mkfs_pdxfs_seed block) -- not a kernel-side
        # boot witness. See src/kernel/boot/witness/r64v2_tools.pdx for
        # why a kernel-side witness structurally cannot exercise
        # sys_execve_shim at this point in boot (same limitation
        # boot_r86_relative_path's own comment documents for
        # sys_chdir_body/sys_getcwd_body). Driving it through the real
        # interactive shell (mirroring boot_r17_shell_child_process's
        # 'true\nexit\n' precedent) sidesteps the limitation entirely.
        #
        # Script: `mkfs.pdxfs --dry-run /tmp/t.img\nexit\n`. --dry-run
        # against a TARGET_FILE (target starts with '/') never opens or
        # writes the target path, so no prerequisite `mkdir /tmp` is
        # needed (unlike boot_r86_relative_path's real mkdir/cd script).
        #
        # Golden asserts, in order: SHELL START, `sys execve argv ok`
        # (R62.M1-002/003 #1826/#1829 -- proves the shell's
        # argv=["mkfs.pdxfs","--dry-run","/tmp/t.img"] marshalled through
        # sys_execve_shim before mkfs.pdxfs's image loaded), the literal
        # `PdxFsFormatRecord@0.1 { target: /tmp/t.img` preview-line
        # fragment (mkfs.pdxfs's src/pipe_wire.pdx `mkfs_sp_emit_dry_run`
        # -> src/format_record.pdx `format_record_emit_dry_run`, proving
        # the ELF actually ran in ring-3, argv-parsed, and classified
        # /tmp/t.img as TARGET_FILE), and REAPED (shell exit unblocking
        # init's wait4).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r64v2/expected-tools-mkfs-dry-run.golden"
        TIMEOUT=30
        UART_RX_MODE=1
        : "${INJECT_STRING:=mkfs.pdxfs --dry-run /tmp/t.img\nexit\n}"
        : "${INJECT_WAIT_FOR:=SHELL START}"
        : "${INJECT_DELAY:=0.3}"
        : "${INJECT_HOLD:=20}"
        EXPECTED=""
        ;;
    boot_r65_persistent_home)
        # R65v2.M1-004 (paideia-os #1982): persistent-/home-operator
        # two-phase smoke, PHASE 1 ONLY. Gated behind PAIDEIA_R65_PERSIST=1
        # in tools/pre-push (R65v2.M1-005, #1983) — same opt-in shape as
        # PAIDEIA_R53_DISK for boot_r53_round_trip_phase1, since the real
        # persistence this smoke's NAME promises depends on hardware
        # (or R51/R52's pdxfs-block rootfs) this tree does not have yet.
        #
        # Real ring-3 exercise, same shape as boot_r64v2_tools /
        # boot_r86_relative_path: drives /bin/mkfs.pdxfs and
        # /bin/mount.pdxfs through the ACTUAL interactive shell rather
        # than a kernel-side witness (sys_execve_shim cannot be exercised
        # before a shell exists to invoke it — see boot_r64v2_tools's own
        # comment for why).
        #
        # Script: `mkdir /home\nmkdir /home/operator\nmkfs.pdxfs --dry-run
        # /var/pdxfs/home.img\nmount.pdxfs --dry-run cap:volume:0x0001
        # /home/operator\ntouch /home/operator/probe.txt\nexit\n`.
        #
        #   - `mkdir /home` + `mkdir /home/operator`: neither directory is
        #     tmpfs-seeded at boot (grep confirms rootfs_seed.pdx /
        #     bin_seeds.pdx / rootfs_dir_seeds.pdx seed /bin, /etc, /tmp,
        #     /share, /pkgs, /system, /journal — never /home), so the
        #     probe-file write below needs a real parent directory first.
        #     This is plain tmpfs mkdir, unrelated to and not a substitute
        #     for the pdxfs-block mount attempted next.
        #     FIXED at paideia-os #2004: the diagnosis matched — the
        #     64-slot tmpfs inode pool (TMPFS_MAX, core/fs/tmpfs/inode.
        #     pdx) was exhausted by the growing boot-seed inventory (16+
        #     /bin binaries, /share, /pkgs, /system/*, /journal/*, plus
        #     boot self-test witness allocations) by the time the shell
        #     reached the `mkdir /home` step, and tmpfs_create silently
        #     returned 0 on OOM which sys_mkdir mapped to -EIO with no
        #     kernel-side signal on the wire.  #2004 landed three
        #     changes together (fix + diagnostic + prevention): (1)
        #     raised TMPFS_MAX to 256 (matches VNODE_MAX; multi-word
        #     bitmap allocator rewrite adapted from vnode_alloc's shape);
        #     (2) instrumented tmpfs_create's three failure arms with a
        #     distinct `tmpfs create fail [legacy: TMPFS CREATE FAIL]
        #     reason=<code>` fingerprint (1=parent-not-dir, 2=collision,
        #     3=OOM) so the previously-silent three-way ambiguity now
        #     names its own failure mode on the wire; (3) added a
        #     `tmpfs inode alloc count -- count=<N>` snapshot immediately
        #     after each kernel-side seed batch in kernel_main.pdx so a
        #     future rise toward TMPFS_MAX=256 is visible before it
        #     re-runs this regression.  The golden below now asserts the
        #     ACTUAL post-fix wire (`sys mkdir ok [legacy: SYS MKDIR OK]`
        #     x2) — a persistent failure of this golden signals either a
        #     regression of the TMPFS_MAX widening or a new upstream OOM
        #     inflating the seed inventory past 256.
        #   - `mkfs.pdxfs --dry-run /var/pdxfs/home.img`: the exact path
        #     src/user/init.pdx's own R65v2.M1-001 (#1979) boot-time probe
        #     checks. --dry-run against a TARGET_FILE never opens/writes
        #     the target, so no /var/pdxfs prerequisite mkdir is needed
        #     (matches boot_r64v2_tools's own /tmp/t.img precedent).
        #   - `mount.pdxfs --dry-run cap:volume:0x0001 /home/operator`:
        #     `cap:volume:0x0001` is a syntactically-valid volume-cap URI
        #     (volume_cap_parse_slot only checks the "cap:volume:0x" prefix
        #     + hex digits — see tools/user/mount.pdxfs/src/volume_cap.pdx
        #     — vol_kind_narrow's own M2 body is a documented passthrough,
        #     so no real KIND_VOLUME needs to back this slot for the
        #     dry-run path to reach its preview emit). "/home/operator"
        #     classifies as MPC_USER_SUBTREE (elevate.pdx's elev_lit_home
        #     = "/home/") so no elevation stub is hit.
        #   - `touch /home/operator/probe.txt`: the "probe file" this
        #     issue's own task text asks for. Under today's tmpfs rootfs
        #     this write is real but ephemeral — it does NOT survive a
        #     reboot, which is exactly PHASE 2's assertion and exactly why
        #     phase 2 is not implemented here (see below).
        #
        # Golden asserts, in order: SHELL START, the child_hello reap
        # (`WAIT: pid=9 status=42` + `REAPED`), two `shell exec ok --
        # argv[0]=mkdir resolved=/bin/mkdir` + `sys mkdir ok [legacy:
        # SYS MKDIR OK]` pairs (one per mkdir — post-#2004 both succeed),
        # the mkfs.pdxfs dry-run
        # preview fragment `PdxFsFormatRecord@0.1 { target:
        # /var/pdxfs/home.img`, the mount.pdxfs dry-run preview fragment
        # `PdxFsMountRecord@0.1 { volume: cap:volume:0x0001`, the literal
        # `result_code: DRY_RUN }` (proves mount.pdxfs's own dry-run gate
        # fired rather than falling into an elevation/bad-cap/kernel-error
        # branch), and a final REAPED (shell exit unblocking init's
        # second wait4).
        #
        # PHASE 2 (deferred, NOT implemented by this mode): a second boot
        # that reads /home/operator/probe.txt back and asserts its
        # contents survived. Under tmpfs that assertion would correctly
        # FAIL every time (tmpfs is wiped on every QEMU relaunch — there
        # is no `--with-disk`-style backing image for tmpfs), which would
        # make this mode a permanently-red smoke rather than a real
        # regression signal. Phase 2 becomes a genuine assertion once
        # R51/R52 lands a real pdxfs-block rootfs (the same milestone
        # sys_mount.pdx's own backend_id=5 UNIMPL stub is waiting on) and
        # a `--with-disk`-shaped two-phase harness analogous to
        # boot_r53_round_trip_phase1/phase2 can be built for it. Tracked
        # in design/round-retrospectives/r65-closure-v2.md's debt
        # inventory; see design/user/persistent-home.md §2/§6.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r65v2/expected-persistent-home-phase1.golden"
        TIMEOUT=32
        UART_RX_MODE=1
        : "${INJECT_STRING:=mkdir /home\nmkdir /home/operator\nmkfs.pdxfs --dry-run /var/pdxfs/home.img\nmount.pdxfs --dry-run cap:volume:0x0001 /home/operator\ntouch /home/operator/probe.txt\nexit\n}"
        : "${INJECT_WAIT_FOR:=SHELL START}"
        : "${INJECT_DELAY:=0.3}"
        : "${INJECT_HOLD:=25}"
        EXPECTED=""
        ;;
    boot_smp)
        # R18-M1-005 (#764): SMP bring-up smoke.
        #
        # Kernel wire-in (src/kernel/boot/kernel_main.pdx, post
        # lapic_timer_init): BSP emits "SMP BRINGUP START", calls
        # ap_bring_up_all with the hard-coded AP list
        # (_ap_apic_ids = [1,2,3], _ap_count = 3), busy-waits ~333 ms
        # for the last-woken AP to reach _ap_entry's uart_puts, then
        # emits "SMP BRINGUP DONE". Each AP emits `CPU_ID_XX_HELLO`
        # from _ap_entry (src/kernel/core/smp/ap_entry.pdx) with XX =
        # 2-hex APIC ID (01/02/03 on `-smp 4`).
        #
        # QEMU topology: `-smp 4` = BSP (APIC ID 0) + 3 APs. Matches
        # the hard-coded AP list. Growing beyond 4 requires the kernel
        # AP list + N_APS in ap_stacks.pdx to bump together (R20.M2
        # MADT-driven enumeration retires the hard-code).
        #
        # Fingerprint order handling: the BSP bookends
        # (SMP BRINGUP START / DONE) are strictly ordered around the
        # AP hellos. The three CPU_ID_XX_HELLO lines are
        # presence-checked only — Intel MP-init spec allows the APs
        # to leave the wait-for-SIPI state at slightly different
        # times, and COM1 is unlocked (per ap_entry.pdx concurrency
        # note), so their emission order on the wire is not
        # guaranteed. SMP_UNORDERED_HELLO=1 tells the fingerprint
        # checker to skip cross-AP ordering while still enforcing the
        # bookends.
        #
        # NOT wired into pre-push yet (per #764 task discipline).
        # Promotes to gated smoke after 5/5 consecutive passes.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r18/expected-boot-smp.txt"
        TIMEOUT=10
        SMP_MODE=1
        SMP_CPU_COUNT=4
        SMP_UNORDERED_HELLO=1
        EXPECTED=""
        ;;
    boot_r69_smp_dispatch)
        # R69.M1 (#1877/#1883/#1888/#1894): SMP scheduler real-dispatch
        # witness. Kernel wire-in (src/kernel/boot/kernel_main.pdx,
        # immediately after witness_r33_audio_crash_isolation and before
        # present_boot_ready/sti): unconditional call to
        # witness_r69_smp_dispatch (src/kernel/boot/witness/
        # r69_smp_dispatch.pdx), which exercises cross-CPU sched_wake
        # dispatch (#1883) and idle-CPU work-steal (#1888) against
        # synthetic TCBs, then reports the resulting per-CPU runqueue
        # distribution as the #1894 fairness fingerprint.
        #
        # `-smp 4` (NOT `-smp 8` as this round's brief originally asked
        # for): Percpu.MAX_CPUS is 4 (src/kernel/core/smp/percpu.pdx),
        # matching ApStacks.N_APS and the hard-coded 3-entry AP list in
        # ap_list.pdx — the same real ceiling boot_smp already runs
        # under. There is no live path to more than 4 logical CPUs on
        # this tree today; requesting -smp 8 here would not exercise any
        # additional CPU, only leave 4 of the 8 QEMU vCPUs perpetually
        # unbooted. See witness/r69_smp_dispatch.pdx's header for the
        # full honest-scope note (this proves runqueue-residency
        # fairness, not execution-tick fairness — the latter needs
        # AP-side IDT install, which has never landed, #762).
        #
        # This witness runs unconditionally on every boot mode (not just
        # this one) — it is harmless under -smp 1 (its cross-CPU wake
        # targets simply resolve to .bss-zero, never-brought-up Percpu
        # CB slots, and the resulting "IPI" to apic_id 0 lands on the
        # BSP itself, which has a real vector-0xF1 handler). This mode
        # exists to run it under the -smp 4 topology it is meant for and
        # pin its three fingerprints against a golden.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/expected-r69-smp.golden"
        TIMEOUT=10
        SMP_MODE=1
        SMP_CPU_COUNT=4
        EXPECTED=""
        ;;
    boot_r87_ap_idt)
        # R87.M1 (#1965/#1966/#1971): AP-side descriptor-table bring-up
        # witness. Kernel wire-in (src/kernel/boot/kernel_main.pdx,
        # immediately after the AP-bring-up busy-wait and before the
        # IOAPIC/MSI-X witnesses): unconditional call to
        # witness_r87_ap_idt (src/kernel/boot/witness/r87_ap_idt.pdx),
        # which reads back each of the 3 per-AP TSS descriptors' busy
        # bit from the shared Gdt._gdt_new (proof that ap_tss.pdx's
        # ap_desc_tables_install actually ran lgdt/ltr/lidt on every AP)
        # and reports the count as a single BSP-observable rollup
        # fingerprint.
        #
        # `-smp 4`: same real ceiling as boot_r69_smp_dispatch above
        # (Percpu.MAX_CPUS = 4). See witness/r87_ap_idt.pdx's header for
        # the full honest-scope note — this proves per-CPU descriptor-
        # table correctness (lgdt/ltr/lidt actually landed on every AP),
        # not task dispatch or execution-tick fairness; those remain
        # blocked on the scheduler-global migration
        # design/kernel/ap-idt-strategy.md documents as this round's
        # ceiling.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/expected-r87-ap-idt.golden"
        TIMEOUT=10
        SMP_MODE=1
        SMP_CPU_COUNT=4
        EXPECTED=""
        ;;
    boot_r72_tcp_echo)
        # R72.M1-007 (#1929): TCP substrate boot witness. Runs
        # unconditionally in the default (-smp 1, no --with-disk) boot
        # path — witness_r72_tcp_echo (boot/witness/r72_tcp_echo.pdx)
        # drives a self-connect handshake + port-7 echo + mutual
        # orderly close entirely through net/tcp.pdx's TCB primitives,
        # with no e1000e device or link required (the loopback fast
        # path never reaches ipv4_tx_send for a self-addressed
        # segment). No special QEMU flags needed; this mode exists
        # only to pin the fingerprint sequence against a dedicated
        # golden separate from the 14-mode default matrix.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/expected-r72-tcp-echo.golden"
        TIMEOUT=10
        EXPECTED=""
        ;;
    boot_r94_tcp_offbox)
        # R94.M6-003 (paideia-os #2075): off-box TCP boot witness.
        # The witness at src/kernel/boot/witness/r94_tcp_offbox.pdx
        # connects out through QEMU SLIRP's virtio-net rings +
        # hostfwd tcp::5555-:5555 to a locally-started netcat
        # listener on host tcp/5555, sends 4 bytes of "PING", drains
        # the reply from the client TCB's rx_buf, and orderly-closes.
        #
        # R98.M1-002 (#2101): gated behind PAIDEIA_NET_SMOKE=1. This
        # mode requires a host-side responder to satisfy its (now
        # strict) golden -- exercising it outside the networking-smoke
        # lane would fail the strict `bytes=4` line every time. The
        # composite `boot_net_smoke` mode owns the responder lifecycle
        # (tools/net-smoke-httpd.sh) and sets PAIDEIA_NET_SMOKE=1 +
        # PAIDEIA_HOSTFWD before recursively invoking this mode.
        #
        # R98.M2-002 (#2103): fingerprint sequence tightened. Golden
        # at tests/expected-r94-tcp-offbox.golden now pins the ok pair
        #   `boot r94 offbox handshake ok --`
        #   `boot r94 offbox roundtrip ok -- bytes=4`
        # rather than the permissive substring `boot r94 offbox` that
        # would also match the skip variant. `bytes=4` matches
        # tools/net-smoke-httpd.sh's default PAYLOAD="PONG".
        #
        # Manual invocation outside the composite:
        #   PAIDEIA_NET_SMOKE=1 PAIDEIA_HOSTFWD='tcp::5555-:5555' \
        #     bash -c 'PAYLOAD=PONG tools/net-smoke-httpd.sh & \
        #              sleep 0.2; \
        #              tools/run-smoke.sh boot_r94_tcp_offbox'
        if [[ "${PAIDEIA_NET_SMOKE:-0}" != "1" ]]; then
            echo "smoke: boot_r94_tcp_offbox skipped (PAIDEIA_NET_SMOKE!=1; opt-in via composite boot_net_smoke or set the flag + start tools/net-smoke-httpd.sh)"
            exit 0
        fi
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/expected-r94-tcp-offbox.golden"
        TIMEOUT=20
        EXPECTED=""
        ;;
    boot_r93_udp_dns)
        # R93.M4-001 (paideia-os #2058): DHCP + DNS boot cascade.
        #
        # R98.M1-002 (#2101): gated behind PAIDEIA_NET_SMOKE=1 so it
        # composes with the networking-smoke lane rather than running
        # opportunistically. SLIRP's built-in DHCP + DNS servers serve
        # this witness without any host-side responder, but the gate
        # keeps all three lane members (R91 / R93 / R94) refusing
        # cleanly outside the lane so a single opt-in flag is the only
        # switch a caller needs to reason about.
        #
        # The witness lives at src/kernel/boot/witness/r93_udp_dns.pdx
        # and fires unconditionally on every boot (via kernel_main.pdx
        # after witness_r92_icmp_ping). Under PAIDEIA_NIC=virtio
        # (R91.M5-002 default) run-qemu.sh attaches SLIRP networking;
        # DHCP acquires 10.0.2.15/24 gw 10.0.2.2 dns 10.0.2.3 from
        # SLIRP's built-in server; the DNS witness then resolves
        # "example.com" against 10.0.2.3 (which SLIRP forwards to the
        # host resolver).
        #
        # Fingerprint sequence (contains-in-order):
        #   `boot r93 dhcp lease ok --`     (DHCP lease install)
        #   `boot r93 dns resolve ok --`    (A-record for example.com)
        #
        # A future golden that tightens the check to include the
        # specific ip=x.x.x.x bytes lands once TSC-cal-style RTT
        # variability is characterized. For now the substring match
        # is sufficient to prove both fingerprints reached the wire.
        if [[ "${PAIDEIA_NET_SMOKE:-0}" != "1" ]]; then
            echo "smoke: boot_r93_udp_dns skipped (PAIDEIA_NET_SMOKE!=1; opt-in via composite boot_net_smoke)"
            exit 0
        fi
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/expected-r93-udp-dns.golden"
        TIMEOUT=20
        EXPECTED=""
        ;;
    boot_r103_virtio_gpu)
        # R103.M5-002 (paideia-os #2168): pins the R103.M5-001 witness's
        # success fingerprint proving the virtio-gpu 2D backend pipeline
        # end-to-end (probe -> handshake -> ctrlq/cursorq init -> resource
        # create -> attach backing -> set scanout -> transfer -> flush ->
        # double-flip readback verify).
        #
        # Runs under PAIDEIA_VGA=virtio (forcing `-vga none -device
        # virtio-gpu-pci` in run-qemu.sh) so the virtio-gpu probe finds a
        # device to bind. Without PAIDEIA_VGA forced, the witness takes
        # the skip path and the golden fails -- pinning the invariant
        # that the smoke mode carries its own VGA env override, matching
        # PAIDEIA_VGA=std's boot_r101_stdvga posture.
        #
        # Golden (contains-in-order substring match):
        #   `boot r103 virtio_gpu double_flip ok`
        export PAIDEIA_VGA=virtio
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/expected-r103-virtio-gpu.golden"
        TIMEOUT=20
        EXPECTED=""
        ;;
    boot_r101_stdvga)
        # R101.M4-003 (paideia-os #2152): pins the R101.M4-001 witness's
        # success fingerprint proving KIND_DISPLAY_BACKEND + KIND_
        # FRAMEBUFFER + backend_flush end-to-end against QEMU's Bochs
        # stdvga LFB.
        #
        # Runs under PAIDEIA_VGA=std (forcing `-vga std` in run-qemu.sh)
        # so the Bochs probe finds a device to bind. Without PAIDEIA_VGA
        # forced, the witness takes the skip path and the golden fails
        # -- pinning the invariant that the smoke mode carries its own
        # VGA env override, matching PAIDEIA_NIC=virtio's boot_r91_nic
        # posture.
        #
        # Golden (contains-in-order substring match):
        #   `boot r101 stdvga ok -- w=1024 h=768`
        # This is the success line the r101_stdvga_checkerboard.pdx
        # witness emits after all 8 stages green. A skip / fail line
        # would fail the golden, which is the intended discipline.
        export PAIDEIA_VGA=std
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/expected-r101-stdvga.golden"
        TIMEOUT=15
        EXPECTED=""
        ;;
    boot_r102_first_pixel)
        # R102.MON-004 skeleton (paideia-os #2211): pins the ONE-line
        # skip fingerprint emitted by witness_r102_first_pixel every
        # boot. Skeleton because the underlying userland (svc-
        # compositor et al.) exists only as empty scaffolds on
        # github.com/paideia-os. See src/kernel/boot/witness/r102_first_
        # pixel.pdx header for the full disposition, and design/round-
        # retrospectives/r102-closure.md §"Deferred" for the roadmap
        # from skip to OK.
        #
        # Golden (contains-in-order substring match):
        #   `boot r102 first pixel skip reason=no-userland`
        # When svc-compositor.M4-001 lands and the .incbin embed pass
        # (R102.MON-003) fills in build/user/svc-compositor.elf, the
        # witness body flips to the real cascade and the golden line
        # flips to `boot r102 first pixel ok`. No PAIDEIA_VGA export
        # -- the skip path is device-independent (the OK path will need
        # PAIDEIA_VGA=std to reach a compositor-holdable scanout).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/expected-r102-first-pixel.golden"
        TIMEOUT=10
        EXPECTED=""
        ;;
    boot_r102_window_present)
        # R102.MON-005 skeleton (paideia-os #2212): pins the skip
        # fingerprint from witness_r102_window_present. Flips to
        # `boot r102 window present ok` when svc-compositor.M4-002 +
        # pdxclock.M4-* land and pdxclock's .elf is embedded (MON-003).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/expected-r102-window-present.golden"
        TIMEOUT=10
        EXPECTED=""
        ;;
    boot_r102_input_route)
        # R102.MON-006 skeleton (paideia-os #2213): pins the skip
        # fingerprint from witness_r102_input_route. Flips to
        # `boot r102 input route ok` when svc-compositor.M4-003 +
        # svc-wm.M4 + pdxpaint.M4-001 land AND R101's HID-injection
        # fixture (r102-user-plan.md §7.2.5) lands. Two independent
        # preconditions -- flag both in the follow-up issue that
        # activates this smoke.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/expected-r102-input-route.golden"
        TIMEOUT=15
        EXPECTED=""
        ;;
    boot_r102_pdxterm_hello)
        # R102.MON-007 skeleton (paideia-os #2214): pins the skip
        # fingerprint from witness_r102_pdxterm_hello. Flips to
        # `boot r102 pdxterm hello ok` when pdxterm.M4-002 lands (and
        # every downstream pdxterm dep -- see witness header).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/expected-r102-pdxterm-hello.golden"
        TIMEOUT=15
        EXPECTED=""
        ;;
    boot_r102_screenshot)
        # R102.MON-008 skeleton (paideia-os #2215): pins the skip
        # fingerprint from witness_r102_screenshot. Flips to
        # `boot r102 screenshot ok` when svc-compositor.M4-004 (screen-
        # shot-region query end-to-end) lands.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/expected-r102-screenshot.golden"
        TIMEOUT=10
        EXPECTED=""
        ;;
    boot_r105_flip_client_std)
        # R105.M6-001 (paideia-os R105 landing): pins the R105 flip-
        # client witness's success fingerprint proving sys_display_
        # enumerate / sys_framebuffer_create / sys_framebuffer_map /
        # sys_page_flip x 3 / sys_page_flip_wait x 3 / sys_display_
        # hotplug_subscribe end-to-end against QEMU's Bochs stdvga.
        #
        # Runs under PAIDEIA_VGA=std for the same reason as boot_r101_
        # stdvga. Without the env, the witness skips cleanly and the
        # golden fails.
        #
        # Golden (contains-in-order substring match):
        #   `boot r105 flip client ok -- flips=3`
        export PAIDEIA_VGA=std
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/expected-r105-flip-client.golden"
        TIMEOUT=20
        EXPECTED=""
        ;;
    boot_r105_flip_client_virtio)
        # R105.M6-001 virtio arm. At R105 the virtio-gpu backend has
        # not yet landed (R103 owns that scope); this mode is a
        # placeholder that pins the SKIP fingerprint under PAIDEIA_VGA=
        # virtio -- the witness detects no Bochs device (correctly)
        # and takes the clean-skip path. When R103 lands, the mode
        # flips to the OK fingerprint.
        export PAIDEIA_VGA=virtio
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/expected-r105-flip-client-virtio-skip.golden"
        TIMEOUT=20
        EXPECTED=""
        ;;
    boot_r105_flip_client_t14)
        # R105.M6-001 T14 arm. Gated on real-hardware presence per the
        # R51.M8-006 T14 witness pattern. Placeholder at R105 -- the
        # witness routes through the same Bochs skip path on a T14 UEFI
        # boot (no stdvga device), and the golden pins the skip line.
        # R104 lands the actual T14 modeset that this mode's OK line
        # will eventually track.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/expected-r105-flip-client-t14-skip.golden"
        TIMEOUT=30
        EXPECTED=""
        ;;
    boot_r104_iris_xe)
        # R104.M6-002 (paideia-os #2189): pins the R104 Iris Xe wire-up
        # cascade's SKIP fingerprints on QEMU. The full T14-gated cascade
        # (probe -> cdclk -> backend register -> guc -> edid -> mode -> modeset
        # -> vblank register -> vblank witness -> 30-flip witness) emits
        # one "r104 iris_xe <stage> skip not-t14" line per stage on any
        # boot without T14 iGPU presence. On a real T14 UEFI boot the
        # same stages emit their live-ok fingerprints; the golden file
        # would then flip to the live variants (a follow-on landing
        # produces a distinct expected-r104-iris-xe-t14.golden pinning
        # the live path).
        #
        # QEMU golden (contains-in-order substring match):
        #   `r104 t14_g4 absent ok`
        #   `r104 iris_xe probe skip not-t14`
        #   `r104 iris_xe cdclk skip not-t14`
        #   `r104 iris_xe backend register skip not-t14`
        #   `r104 iris_xe guc load skip not-t14`
        #   `r104 edid read skip not-t14`
        #   `r104 mode enum skip not-t14`
        #   `r104 iris_xe modeset skip not-t14`
        #   `r104 iris_xe vblank vector skip not-t14`
        #   `r104 iris_xe vblank skip not-t14`
        #   `r104 multi_scanout ok`
        #   `r104 iris_xe flip skip not-t14`
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/expected-r104-iris-xe.golden"
        TIMEOUT=20
        EXPECTED=""
        ;;
    boot_r91_nic)
        # R98.M1-001 (paideia-os #2100): retires the R91.M6 deferred
        # item #8 ("boot_r91_nic smoke mode + expected-r91-nic-probe.
        # golden was not landed with the round close-out"). The R91.M5-
        # 003 witness at src/kernel/boot/witness/r91_nic_probe.pdx
        # fires on every default boot; this mode pins the fingerprint.
        #
        # Fingerprint (contains-in-order, substring match):
        #   `boot r91 nic probe ok`
        # Matches the two emit variants (`kind=0` when no NIC attached,
        # `kind=<n> mac=<packed> link_up=<0|1>` otherwise) because
        # both share the same "boot r91 nic probe ok" prefix. See
        # design/round-retrospectives/r91-closed.md §"Observable proof"
        # for the full emission chain.
        #
        # R98.M1-002 (#2101): gated behind PAIDEIA_NET_SMOKE=1 like
        # the R93 / R94 lane members, so a single opt-in flag governs
        # the whole networking-smoke lane.
        if [[ "${PAIDEIA_NET_SMOKE:-0}" != "1" ]]; then
            echo "smoke: boot_r91_nic skipped (PAIDEIA_NET_SMOKE!=1; opt-in via composite boot_net_smoke)"
            exit 0
        fi
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r91/expected-r91-nic-probe.golden"
        TIMEOUT=10
        EXPECTED=""
        ;;
    boot_net_smoke)
        # R98.M1-001 (paideia-os #2100): networking-smoke composite
        # meta-mode. Runs the three lane members (boot_r91_nic +
        # boot_r93_udp_dns + boot_r94_tcp_offbox) in sequence, aborting
        # on the first failure, and emits a single rollup line so
        # pre-push / operator invocation gets one green/red for the
        # whole R91-R94 lane.
        #
        # This meta-mode OWNS three side-effects that the individual
        # modes do not:
        #   1. Sets PAIDEIA_NET_SMOKE=1 for each child invocation so
        #      the R98.M1-002 (#2101) gates in each lane member's own
        #      case arm open cleanly.
        #   2. Sets PAIDEIA_HOSTFWD='tcp::5555-:5555' so run-qemu.sh's
        #      hostfwd-extras block wires host tcp/5555 to guest
        #      tcp/5555 for the R94 witness's off-box connect.
        #   3. Starts tools/net-smoke-httpd.sh in the background on
        #      port 5555 with PAYLOAD="PONG" (4 bytes -- matches the
        #      R98.M2-002 (#2103) tightened golden line
        #      `roundtrip ok -- bytes=4`) before boot_r94_tcp_offbox
        #      launches, and kills it on exit.
        #
        # Ordering rationale: R91 first (cheapest, proves the NIC is
        # even attached before any wire traffic); R93 second (DHCP +
        # DNS against SLIRP built-ins, no external responder); R94
        # last (needs the host-side responder to be up and can leave
        # the responder in a half-drained state if the witness fails
        # -- runs last so a mid-lane abort doesn't strand responder
        # state that would confuse a later lane member).
        #
        # PAIDEIA_NIC defaults are honoured (per run-qemu.sh header,
        # `virtio` is the R91.M5-002 default so SLIRP wires up
        # correctly for every child); a caller that wants e1000e or
        # rtl8139 exports PAIDEIA_NIC before invoking.

        # Preflight: refuse if neither python3 nor nc is available --
        # net-smoke-httpd.sh would fail at start otherwise and the R94
        # child would then fail on the strict golden with a confusing
        # error rather than a clean skip.
        if ! command -v python3 >/dev/null 2>&1 && ! command -v nc >/dev/null 2>&1; then
            echo "smoke: boot_net_smoke skipped (neither python3 nor nc found -- see tools/net-smoke-httpd.sh)" >&2
            exit 0
        fi

        _netsmoke_rollup=""

        _netsmoke_run_child() {
            local _child="$1"
            echo "[net-smoke] running ${_child}"
            PAIDEIA_NET_SMOKE=1 "$0" "${_child}"
            local _rc=$?
            if [[ ${_rc} -ne 0 && ${_rc} -ne 33 ]]; then
                echo "smoke: boot_net_smoke FAILED at ${_child} (rc=${_rc})" >&2
                _netsmoke_rollup+="${_child}=FAIL "
                return ${_rc}
            fi
            _netsmoke_rollup+="${_child}=ok "
            return 0
        }

        # 1. R91 -- NIC probe fingerprint (cheapest, gates NIC attach).
        _netsmoke_run_child boot_r91_nic || exit $?

        # 2. R93 -- DHCP + DNS against SLIRP built-ins.
        _netsmoke_run_child boot_r93_udp_dns || exit $?

        # 3. R94 -- off-box TCP against host-side responder. Start the
        #    responder in the background first; PAIDEIA_HOSTFWD wires
        #    QEMU SLIRP host tcp/5555 -> guest tcp/5555 for the connect.
        _netsmoke_httpd_pid=""
        PORT=5555 PAYLOAD=PONG HANG=15 \
            "${REPO_ROOT}/tools/net-smoke-httpd.sh" &
        _netsmoke_httpd_pid=$!
        # Give the listener a fraction of a second to bind before the
        # guest boots + reaches the witness's connect (~1s minimum).
        sleep 0.3

        # Ensure the responder is reaped whether the R94 child passes,
        # fails, or the shell is interrupted mid-lane.
        _netsmoke_cleanup() {
            if [[ -n "${_netsmoke_httpd_pid}" ]]; then
                kill "${_netsmoke_httpd_pid}" 2>/dev/null || true
                wait "${_netsmoke_httpd_pid}" 2>/dev/null || true
            fi
        }
        trap _netsmoke_cleanup EXIT

        PAIDEIA_HOSTFWD='tcp::5555-:5555' \
            _netsmoke_run_child boot_r94_tcp_offbox
        _r94_rc=$?
        _netsmoke_cleanup
        trap - EXIT
        if [[ ${_r94_rc} -ne 0 && ${_r94_rc} -ne 33 ]]; then
            exit ${_r94_rc}
        fi

        echo "smoke: boot_net_smoke lane passed -- ${_netsmoke_rollup}"
        exit 0
        ;;
    boot_r92_icmp)
        # R92.M3-003 (paideia-os #2041): off-box ICMP-ping boot
        # witness. The witness lives at src/kernel/boot/witness/
        # r92_icmp_ping.pdx and fires unconditionally on every boot
        # from kernel_main.pdx (immediately after witness_r91_nic_
        # probe). Under PAIDEIA_NIC=virtio (R91.M5-002 default, live
        # here because run-qemu.sh honours PAIDEIA_NIC) the witness
        # ARP-resolves QEMU SLIRP's gateway (10.0.2.2) via the real
        # virtio-net TX/RX rings, sends an ICMP Echo Request with
        # ident=0xBEEF/seq=1/payload="paideia", polls RX until the
        # Echo Reply arrives (or a bounded ~40 ms budget expires),
        # and emits one of two fingerprints:
        #
        #   `boot r92 icmp ping ok -- rtt_us=<n>` on real success
        #   `boot r92 icmp skip -- reason=<code>` on precondition miss
        #     (code=1 no-nic, code=2 no-link)
        #
        # The golden at tests/expected-r92-icmp.golden pins the
        # substring `boot r92 icmp` (contains-in-order match) so the
        # smoke passes on EITHER the success or the skip line -- this
        # is deliberate: the ARP + ICMP polling budget depends on
        # QEMU SLIRP synchronous reply landing while the guest is
        # still in the poll loop, and no IDT wiring exists for
        # virtio-net ISR delivery (r91-closed.md deferred item #7).
        # The golden's leading `boot r92 route table ok` line pins
        # the R92.M1-003 witness, which does NOT depend on any NIC
        # state and is a hard invariant of the R92 landing.
        #
        # A future landing that tightens the golden to demand `boot
        # r92 icmp ping ok` will do so after the IDT-vector wiring
        # for virtio-net ISR delivery lands (making SLIRP replies
        # reap in a bounded time from within any long-running boot
        # code path).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/expected-r92-icmp.golden"
        TIMEOUT=15
        EXPECTED=""
        ;;
    boot_r20b_echo)
        # R20b.M5-001 (#1563): echo-server end-to-end closure witness —
        # closes R20b.M5, the R20b round, and the #1015 userspace-server
        # substrate blocker (unblocks #820 acpi_supervisor + #860
        # pci_enumerator + every post-R20 userspace daemon).
        #
        # Kernel wire-in (src/kernel/boot/kernel_main.pdx, immediately
        # after loader_seed_witness_done and before sti): unconditional
        # kernel-driven roundtrip against init's user_pml4 exercising ALL
        # M1..M4 primitives end-to-end — svc_register + sys_svc_lookup_body
        # (which internally cap_mint_writes) + sys_ipc_send_body +
        # sys_ipc_recv_body (server drain) + sys_ipc_reply_body (bit-7 flip)
        # + sys_ipc_recv_body (client drain of reply). Byte-exact hdr +
        # payload verify per hop. Emits "R20b ECHO ROUNDTRIP OK\n" on pass.
        #
        # Fingerprint contract (contains-in-order — matches every prior
        # R20b witness marker plus the M5 closure):
        #   R20b BROKER OK          (M1-003)
        #   R20b IPC BOUNCE OK      (M2-003 — M2 close)
        #   R20b SYS IPC RECV OK    (M3-001)
        #   R20b SYS IPC SEND OK    (M3-002)
        #   R20b SVC LOOKUP OK      (M3-003 — M3 close)
        #   R20b INIT CAPS FMT OK   (M4-001)
        #   R20b LOADER SEED OK     (M4-002 — M4 close)
        #   R20b ECHO ROUNDTRIP OK  (M5-001 — R20b + #1015 close)
        # Enforces ordering because M5 depends on M1..M4 having landed
        # cleanly first — a regression in any earlier witness surfaces as
        # a missing-line failure BEFORE the checker gets to the M5 line.
        #
        # Opt-in only (guarded by PAIDEIA_R20B_ECHO=1 in pre-push): the
        # M5 witness spawns a substantial new smoke path (~250 lines of
        # kernel-side orchestration + 4 syscall body calls per hop). The
        # OK fingerprint appears in EVERY boot log (the witness is
        # unconditionally wired) but only this mode asserts its presence;
        # promotes to the default matrix after 5/5 consecutive passes on
        # the standard R20b round.
        #
        # NOT SMP (echo witness is UP-only at R20b.M5 — the substrate is
        # single-flow per design/ipc/userspace-server-substrate.md §14 Q3).
        # NOT UART-RX (no chardev injection; the roundtrip is entirely
        # kernel-driven with no ring-3 involvement at this milestone).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r20b/expected-echo-roundtrip.txt"
        TIMEOUT=10
        EXPECTED=""
        ;;
    boot_r20b_rpc)
        # R20b.M6-003 (#1566): dual-endpoint RPC roundtrip witness —
        # closes R20b.M6 (substrate hardening; unblocks #820 acpi_supervisor
        # + #860 pci_enumerator as real userspace tasks).
        #
        # Kernel wire-in (src/kernel/boot/kernel_main.pdx §m6_rpc_witness,
        # immediately after m5_echo_witness_done and before sti): the
        # kernel-driven dual-endpoint roundtrip proves the substrate fix
        # documented in design/ipc/userspace-server-substrate.md §4.4
        # (Option A compact variant — flags field of the v1 hdr
        # repurposed as reply_endpoint_id; sys_ipc_reply_body reads it
        # and routes the reply to the client's reply endpoint instead
        # of the server's own endpoint, closing the same-endpoint
        # request/reply race).
        #
        # Fingerprint contract (contains-in-order — narrow slice of the
        # boot_r20b_echo matrix focused on the M6-003 closure):
        #   R20b ECHO ROUNDTRIP OK   (M5-001; anchors ordering)
        #   R20b RPC ROUNDTRIP OK    (M6-003 — R20b.M6 close)
        # Any regression that breaks M6-003 without breaking M5-001
        # surfaces here as the missing RPC line; the M5 line stays as
        # ordering anchor so a broken M5 witness is diagnosed by
        # boot_r20b_echo (the fuller fingerprint) instead.
        #
        # Opt-in only (guarded by PAIDEIA_R20B_RPC=1 in pre-push): the
        # M6-003 witness spawns ~350 lines of kernel-side orchestration
        # (2 endpoint allocs + 8-step client/server round trip + byte-
        # exact verify per hop + 3 endpoint_is_full state assertions).
        # The OK fingerprint appears in EVERY boot log (the witness is
        # unconditionally wired inside kernel_main) but only this mode
        # asserts its presence; boot_r20b_echo also asserts it as part
        # of the fuller M1..M6 fingerprint. Promotes to the default
        # matrix after 5/5 consecutive passes on the standard R20b round.
        #
        # NOT SMP (UP-only substrate at R20b per §14 Q3).
        # NOT UART-RX (kernel-driven; no ring-3 involvement at M6-003).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r20b/expected-rpc-roundtrip.txt"
        TIMEOUT=10
        EXPECTED=""
        ;;
    boot_r20b_acpi_rpc)
        # R20-M4-002 (#820): ACPI supervisor RPC witness — closes #820
        # (userspace acpi_supervisor server — accepts KIND_ACPI + serves
        # parse queries).
        #
        # Kernel wire-in (src/kernel/boot/kernel_main.pdx §m4_002_acpi_rpc_witness,
        # immediately after m6_rpc_witness_done and before sti): the
        # kernel-driven four-op RPC roundtrip proves the acpi_supervisor
        # server semantic end-to-end via the "Option B — kernel-side
        # witness driving the RPC" posture (per
        # design/ipc/userspace-server-substrate.md §4.4 Deferred and the
        # matching M5-001 / M6-003 pattern). Loops op ∈ {1, 2, 3, 4} —
        # ACPI_OP_ENUMERATE / GET_MADT / GET_MCFG / GET_HPET — through
        # sys_ipc_send_body → sys_ipc_recv_body (server drain) → kernel
        # dispatch via sup_* helpers (src/kernel/acpi/supervisor_dispatch.pdx)
        # → sys_ipc_reply_body → sys_ipc_recv_body (client drain). TSC
        # delta measured with kread_tsc bracketing each roundtrip; max
        # asserted < 2M ticks (~1 ms @ 2 GHz TSC, matching the AC
        # threshold). Op=1 additionally verifies n_tables >= 4 (q35
        # firmware always publishes at least FADT/MADT/MCFG/HPET).
        #
        # Fingerprint contract (contains-in-order — anchors on M6 and
        # extends with the M4-002 closure):
        #   R20b RPC ROUNDTRIP OK   (M6-003; anchors ordering)
        #   R20b ACPI RPC OK        (M4-002 — #820 close)
        # A regression that breaks M4-002 without breaking M6-003 surfaces
        # here as the missing ACPI line; the M6 line stays as ordering
        # anchor so a broken M6 witness is diagnosed by boot_r20b_rpc.
        #
        # Opt-in only (guarded by PAIDEIA_R20B_ACPI=1 in pre-push): the
        # M4-002 witness spawns ~350 lines of kernel-side orchestration
        # (2 endpoint allocs + 4 iters × 10-sub-step round trip + kernel
        # dispatch to 4 sup_* helpers + TSC gate + verification). The OK
        # fingerprint appears in EVERY boot log (the witness is
        # unconditionally wired inside kernel_main) but only this mode
        # asserts its presence.
        #
        # NOT SMP (UP-only substrate at R20b per §14 Q3).
        # NOT UART-RX (kernel-driven; no ring-3 involvement at M4-002).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r20b/expected-acpi-rpc-roundtrip.txt"
        TIMEOUT=10
        EXPECTED=""
        ;;
    boot_r20b_pci_rpc)
        # R22-M3-005 (#860): PCI enumerator RPC witness — closes #860
        # (userspace pci_enumerator server — walks tree via KIND_DEVICE
        # caps).
        #
        # Kernel wire-in (src/kernel/boot/kernel_main.pdx §m3_005_pci_rpc_witness,
        # immediately after m4_002_acpi_rpc_witness_done and before sti):
        # the kernel-driven three-op RPC roundtrip proves the pci_enumerator
        # server semantic end-to-end via the "Option B — kernel-side
        # witness driving the RPC" posture (per
        # design/ipc/userspace-server-substrate.md §4.4 Deferred and the
        # matching M5-001 / M6-003 / M4-002 pattern). Loops op ∈ {1, 2, 3}
        # — PCI_OP_LIST_DEVICES / DEVICE_INFO / GET_BAR_CAP — through
        # sys_ipc_send_body → sys_ipc_recv_body (server drain) → kernel
        # dispatch via pci_enum_* helpers
        # (src/kernel/core/pci/enumerator_dispatch.pdx) → sys_ipc_reply_body
        # → sys_ipc_recv_body (client drain). Op=1 additionally verifies
        # n_devices >= 4 against a witness-synthesized 4-entry _pci_devices
        # fixture (q35 device topology stand-in — under -kernel MCFG is
        # absent so real pci_enumerate_all returns 0 devices, forcing the
        # witness to seed _pci_devices deterministically before dispatch).
        #
        # Fingerprint contract (contains-in-order — anchors on the ACPI
        # RPC witness and extends with the M3-005 closure):
        #   R20b ACPI RPC OK        (M4-002; anchors ordering)
        #   R20b PCI RPC OK         (M3-005 — #860 close)
        # A regression that breaks M3-005 without breaking M4-002 surfaces
        # here as the missing PCI line; the ACPI line stays as ordering
        # anchor so a broken ACPI witness is diagnosed by
        # boot_r20b_acpi_rpc.
        #
        # Opt-in only (guarded by PAIDEIA_R22_PCI_RPC=1 in pre-push): the
        # M3-005 witness spawns ~300 lines of kernel-side orchestration
        # (2 endpoint allocs + 3 iters × 10-sub-step round trip + kernel
        # dispatch to 3 pci_enum_* helpers + TSC gate + verification). The
        # OK fingerprint appears in EVERY boot log (the witness is
        # unconditionally wired inside kernel_main) but only this mode
        # asserts its presence.
        #
        # NOT SMP (UP-only substrate at R20b per §14 Q3).
        # NOT UART-RX (kernel-driven; no ring-3 involvement at M3-005).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r20b/expected-pci-rpc-roundtrip.txt"
        TIMEOUT=10
        EXPECTED=""
        ;;
    boot_r21_msix_round_robin)
        # R21-M4-005 (#841): MSI-X round-robin structural smoke.
        #
        # Kernel wire-in (src/kernel/boot/kernel_main.pdx, immediately
        # after ioapic_reroute_witness): unconditional call to
        # msix_round_robin_witness (tests/kernel/apic/msix_round_robin.pdx).
        # The witness allocates one MSI-X vector per CPU (0..3) via
        # vector_alloc_for_cpu, programs a fabricated 16-entry MSI-X table
        # via msix_program_entry (through the msix_assign_at bookkeeping
        # wrapper), and verifies the 4 × u32 entry fields byte-for-byte.
        # Emits "MSIX ROUND ROBIN OK\n" on pass.
        #
        # Fingerprint contract:
        #   SMP BRINGUP DONE
        #   IOAPIC REROUTE STRUCT OK
        #   MSIX ROUND ROBIN OK
        # The two witnesses run back-to-back, both inside the boot cli
        # window; SMP BRINGUP DONE anchors the ordering.
        #
        # Zero real-MMIO side effects — writes only to the .bss-backed
        # _fake_msix_table.  Uses per-CPU vector-pool bitmaps that stay
        # populated post-witness (bit 0 of word 0 in each CPU's pool),
        # so a follow-up allocator call at boot time would hand out
        # vector 0x61.  This is not currently a problem because M4 has
        # no other MSI-X allocation call sites at boot; when driver-plane
        # MSI-X consumers land (R23+), the witness needs to either
        # release its allocations or run pre-driver-plane.
        #
        # Opt-in only (guarded by PAIDEIA_R21_MSIX=1 in pre-push): this
        # is targeted R21.M4 validation, not a core boot smoke.  The
        # OK fingerprint appears in EVERY boot log (the witness is
        # unconditionally wired) but only this mode asserts its presence.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r21/expected-msix-round-robin.txt"
        TIMEOUT=10
        SMP_MODE=1
        SMP_CPU_COUNT=4
        SMP_UNORDERED_HELLO=1
        EXPECTED=""
        ;;
    boot_r21_ioapic_reroute)
        # R21-M3-004 (#836): IOAPIC re-route structural smoke.
        #
        # Kernel wire-in (src/kernel/boot/kernel_main.pdx, immediately
        # after smp_bringup_done_msg): unconditional call to
        # ioapic_reroute_witness (tests/kernel/apic/ioapic_reroute_synth.pdx).
        # The witness saves RTE #4 LO/HI, reprograms IRQ 4 → CPU 1 via
        # ioapic_program_redir, reads back to verify vector + mask + dest,
        # then restores the original RTE via ioapic_write_at. Emits
        # "IOAPIC REROUTE STRUCT OK\n" on pass.
        #
        # Fingerprint contract:
        #   SMP BRINGUP DONE
        #   IOAPIC REROUTE STRUCT OK
        # SMP BRINGUP DONE anchors the ordering — the witness runs right
        # after that emit, so if the fingerprint appears without SMP
        # BRINGUP DONE preceding it, the wire-in has drifted.
        #
        # Runs on -smp 4 (matches boot_smp) so the reroute-to-CPU-1 target
        # is a valid APIC ID. The structural witness would also pass on
        # -smp 1 (dest=1 is a valid RTE bit-pattern regardless of receiver
        # existence, and no interrupt fires mid-witness because IF=0), but
        # -smp 4 keeps the parallel with boot_smp's topology.
        #
        # Opt-in only (guarded by PAIDEIA_R21_IOAPIC=1 in pre-push): this
        # is targeted R21.M3 validation, not a core boot smoke. The
        # OK fingerprint appears in EVERY boot log (the witness is
        # unconditionally wired) but only this mode asserts its presence.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r21/expected-ioapic-reroute.txt"
        TIMEOUT=10
        SMP_MODE=1
        SMP_CPU_COUNT=4
        SMP_UNORDERED_HELLO=1
        EXPECTED=""
        ;;
    boot_r21_ymm_preserve)
        # R21-M2-003 (#832): YMM-preservation regression fixture smoke.
        #
        # Kernel wire-in (src/kernel/boot/kernel_main.pdx, after
        # cpu_probe_avx512): unconditional calls to
        # ymm_preserve_synth_witness_a and ..._witness_b, both of which
        # SILENTLY SKIP if cpu_avx2_available() returns 0. On qemu64
        # default (no XSAVE, no AVX2) that means no fingerprint appears
        # — so this smoke mode uses `-cpu max` to expose XSAVE + AVX2
        # and force the fixture down its real code path.
        #
        # Fingerprint contract: two lines must appear in order —
        #   YMM PRESERVE A OK
        #   YMM PRESERVE B OK
        # Each witness round-trips YMM0 through xsave_save_for /
        # xsave_restore_for (the same machinery sched_switch_r15 uses)
        # with distinct pid slots (60 / 61) and distinct patterns (0xAA
        # / 0xBB fill). A "YMM PRESERVE FAIL" indicates either the
        # xsaveopt didn't persist YMM state to the area, the xrstor
        # didn't restore it, or the vpxor clobber failed to null YMM0.
        #
        # Opt-in only (guarded by PAIDEIA_R21_YMM=1 in pre-push): this
        # is a targeted validation, not a core boot smoke.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r21/expected-ymm-preserve.txt"
        TIMEOUT=8
        QEMU_CPU="max"
        EXPECTED=""
        ;;
    boot_r22_pci_tree)
        # R22-M2-005 (#855): PCI enumerator fingerprint.
        #
        # Kernel wire-in (src/kernel/boot/kernel_main.pdx, immediately
        # after r22m1_mcfg_done): unconditional call to
        # pci_enumerate_all(0). The enumerator gates on _mcfg_count:
        # if MCFG was NOT discovered by phase1_acpi_gather (the -kernel
        # boot path on QEMU q35), the enumerator emits
        # "PCI ENUM SKIP no MCFG" and returns 0 without touching config
        # space. If MCFG was discovered (UEFI/OVMF path, real hardware),
        # the enumerator walks bus 0 and every bridge descendant,
        # recording up to 256 devices in _pci_devices and emitting
        # "PCI DEV bus=B dev=D vendor=V device=X" per device followed by
        # "PCI ENUM DONE devices=N".
        #
        # Fingerprint (default -kernel path): "PCI ENUM SKIP no MCFG".
        # This is a health-check for the enumerator's skip path — the
        # UEFI/OVMF path with real device records requires the
        # PAIDEIA_UEFI_OVMF flow which is not wired into this smoke
        # yet.  When that wiring lands (R23), the fingerprint file
        # will grow the per-device lines and the DONE marker.
        #
        # Opt-in only (guarded by PAIDEIA_R22_PCI_TREE=1 in pre-push).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r22/expected-pci-tree.txt"
        TIMEOUT=8
        EXPECTED=""
        ;;
    boot_r22_msix_ir_round_robin)
        # R22-M6-005 (M5 debt fix): opt-in MSI-X-via-IR round-robin smoke.
        #
        # The R22.M5 witness at tests/kernel/iommu/msix_ir_round_robin.pdx
        # (symbol msix_ir_round_robin_witness) is NOT wired into
        # kernel_main at M5 close — same posture as vtd_slpt_synth_witness
        # (M4) and vtd_ir_program-only (M5): symbol existence + build-time
        # link-verification are the acceptance criterion, live invocation
        # is deferred to R23 when GCMD.TE + SIRTP + IRE ceremony wires
        # the IR unit for real dispatch.
        #
        # Under R22.M6, `PAIDEIA_R22_MSIX_IR=1 bash .githooks/pre-push`
        # previously failed because no `boot_r22_msix_ir_round_robin`
        # mode existed in this script — the fingerprint would be sought
        # against a nonexistent expected-file and the run would abort.
        # This SKIP-echo mode closes that gap: the pre-push env-gate
        # remains callable + the mode returns cleanly with a SKIP marker,
        # matching the `boot_r21_ymm_preserve` auto-skip pattern for
        # infra-not-yet-available witnesses.
        #
        # When R23 wires msix_ir_round_robin_witness into kernel_main
        # (behind Features.IOMMU_ENABLED=1 — see
        # design/kernel/iommu-boot-toggle.md §3 wire-up checklist), this
        # mode flips to FINGERPRINT_MODE=1 with a real
        # tests/r22/expected-msix-ir-round-robin.txt file matching the
        # `IR ROUND ROBIN OK\n` witness emit.
        echo "smoke: boot_r22_msix_ir_round_robin — SKIP (witness not wired at R22.M6; R23 dependency per design/kernel/iommu-boot-toggle.md)"
        exit 0
        ;;
    boot_r24_concurrent_io)
        # R24-M6-002 (#909): opt-in 4-CPU concurrent-IO throughput
        # scaffold, gated by PAIDEIA_R24_CONCURRENT_IO=1.
        #
        # The witness at tests/kernel/drivers/nvme/concurrent_io.pdx
        # (symbol concurrent_io_witness) is NOT wired into kernel_main
        # at M6 — same posture as msix_ir_round_robin_witness at
        # R22.M6: symbol existence + build-time link verification are
        # the R24-close acceptance criterion, live invocation is
        # deferred to R25+ when the driver-attach path wires
        # probe → identify → io_queues → sync_read into a boot-time
        # bring-up sequence AND the public sched_spawn substrate lands.
        #
        # QEMU-TCG default `-kernel` has no MCFG → PCI enumerator
        # drains empty → nvme_probe returns 0 → concurrent_io_witness
        # would take the SKIP branch even if it were invoked. So the
        # opt-in mode is a SKIP-echo at M6: the pre-push env-gate
        # stays callable (does not abort the push), the mode returns
        # cleanly with a SKIP marker, matching the R22.M6
        # msix_ir_round_robin pattern.
        #
        # When R25+ wires concurrent_io_witness into a boot-time
        # bring-up (behind PAIDEIA_R24_CONCURRENT_IO gating), this
        # mode flips to FINGERPRINT_MODE=1 with a
        # tests/r24/expected-concurrent-io.txt file matching the
        # "NVME CONCURRENT IO OK cpus=4 iops=<N>\n" witness emit.
        echo "smoke: boot_r24_concurrent_io — SKIP (witness not wired at R24.M6; R25+ dependency: driver-attach + public sched_spawn per design/round-retrospectives/r24-closure.md § Preflight for R25)"
        exit 0
        ;;
    boot_r25_pdxfs_corrupt_sb)
        # R25-M5-003 (#931): opt-in PdxFS-lite superblock corruption
        # fixture, gated by PAIDEIA_R25_PDXFS_CORRUPT=1.
        #
        # The witness at tests/kernel/fs/pdxfs_lite_corrupt_sb.pdx
        # (symbol pdxfs_lite_corrupt_sb_witness) is NOT wired into
        # kernel_main at R25.M5 — same posture as msix_ir_round_robin_
        # witness at R22.M6 close: symbol existence + build-time link
        # verification are the R25.M5 acceptance criterion, live
        # invocation is deferred to a later milestone when the FS
        # bring-up path exercises pdxfs_lite_mount from a real -kernel
        # boot fingerprint (blocked on the KIND_BLKDEV cap plumbing
        # already documented in mount_op.pdx as #1015).
        #
        # Under -kernel the QEMU boot has no NVMe controller → the
        # witness itself would still be callable (it operates on a
        # .bss-backed fake superblock, not a real device), but there
        # is no boot-path caller wired at R25.M5. This SKIP-echo mode
        # keeps the pre-push env-gate callable so PAIDEIA_R25_PDXFS_
        # CORRUPT=1 does not abort the push.
        #
        # When kernel_main wires pdxfs_lite_corrupt_sb_witness into
        # the boot-time bring-up (behind PAIDEIA_R25_PDXFS_CORRUPT
        # gating), this mode flips to FINGERPRINT_MODE=1 with a
        # tests/r25/expected-pdxfs-corrupt-sb.txt file matching
        # "PDXFS CORRUPT SB OK\n". At R32+ (when Features.CRYPTO_ML_
        # DSA_ENABLED=1 flips), the witness body itself is revised
        # to expect verify FAIL on the bit-flipped signed region —
        # see design/filesystem/pdxfs-lite-perf.md §5.
        echo "smoke: boot_r25_pdxfs_corrupt_sb — SKIP (witness not wired at R25.M5; caller wire-up deferred pending KIND_BLKDEV cap plumbing per src/kernel/core/fs/pdxfs_lite/mount_op.pdx header — #1015)"
        exit 0
        ;;
    boot_r25_pdxfs_e2e)
        # R25-M7-001 (#937): opt-in PdxFS-lite end-to-end mount-check
        # witness, gated by PAIDEIA_R25_PDXFS_E2E=1.
        #
        # The witness at tests/kernel/fs/pdxfs_lite_e2e_witness.pdx
        # (symbol pdxfs_lite_e2e_witness) is NOT wired into kernel_main
        # at R25.M7 — same posture as pdxfs_lite_corrupt_sb_witness at
        # R25.M5 close and concurrent_io_witness at R24.M6 close: symbol
        # existence + build-time link verification are the R25.M7
        # acceptance criterion, live invocation is deferred to R26+
        # when the driver-attach ceremony wires nvme_probe → identify →
        # io_queues → pdxfs_lite_mount into kernel_main_uefi (blocked
        # on the same #1015 userspace-server substrate as #820 acpi_
        # supervisor / #860 pci_enumerator / #906 userspace half of
        # nvme_read_blocking).
        #
        # Under -kernel the witness itself would take its SKIP branch
        # (pdxfs_lite_is_mounted returns 0 because no NVMe controller
        # ever surfaces via nvme_probe under q35 default), but at
        # R25.M7 there is no boot-path caller wired. This SKIP-echo
        # mode keeps the pre-push env-gate callable so
        # PAIDEIA_R25_PDXFS_E2E=1 does not abort the push.
        #
        # The full E2E promotion recipe (mkfs → boot → write → reboot
        # → read-verify) lives at tools/pdxfs-lite-e2e-smoke.md. Live
        # end-to-end promotion is queued for R26+ real-HW alongside
        # the R24 first-NVMe-touch moment.
        #
        # When kernel_main wires pdxfs_lite_e2e_witness into the boot-
        # time bring-up (behind PAIDEIA_R25_PDXFS_E2E gating), this
        # mode flips to FINGERPRINT_MODE=1 with a
        # tests/r25/expected-pdxfs-e2e.txt file matching
        # "PDXFS E2E OK mounted=1\n" (or "PDXFS E2E SKIP not mounted\n"
        # if the boot-time caller runs pre-mount for structural proof).
        echo "smoke: boot_r25_pdxfs_e2e — SKIP (witness not wired at R25.M7; live E2E deferred to R26+ per tools/pdxfs-lite-e2e-smoke.md — chained on #906 nvme_write_blocking + driver-attach)"
        exit 0
        ;;
    boot_r54_nvme_write)
        # R54.M1-001 (#1778): opt-in nvme_write_blocking (OPC=0x01)
        # round-trip witness, gated by PAIDEIA_R54_NVME_WRITE=1.
        #
        # The witness at src/kernel/boot/witness/r54_nvme_write.pdx
        # (symbol r54_nvme_write_witness) is NOT wired into
        # kernel_main at R54.M1 — same posture as pdxfs_lite_e2e_
        # witness at R25.M7 close and concurrent_io_witness at
        # R24.M6 close: symbol existence + build-time link
        # verification are the R54.M1 acceptance criterion, live
        # invocation is deferred to R55+ when the driver-attach
        # ceremony surfaces a real NVMe controller on the default
        # boot path (blocked on the same #1015 userspace-server
        # substrate as #820 acpi_supervisor / #860 pci_enumerator).
        #
        # Under -kernel the witness itself takes its SKIP branch
        # (_nvme_io_queue_count == 0 because nvme_probe drains
        # empty under absent MCFG), but at R54.M1 there is no boot-
        # path caller wired. This SKIP-echo mode keeps the pre-push
        # env-gate callable so PAIDEIA_R54_NVME_WRITE=1 does not
        # abort the push.
        #
        # When the driver-attach ceremony wires r54_nvme_write_
        # witness into kernel_main behind PAIDEIA_R54_NVME_WRITE
        # gating, this mode flips to FINGERPRINT_MODE=1 against
        # tests/r54/expected-r54-nvme-write.txt (three lines: probe
        # banner, "NVME WRITE OK", "NVME READBACK OK").
        echo "smoke: boot_r54_nvme_write — SKIP (witness not wired at R54.M1; live round-trip deferred to R55+ per design/kernel/nvme-write-blocking.md — chained on driver-attach + real NVMe controller on default boot path)"
        exit 0
        ;;
    boot_r54_bdev_flush)
        # R54.M1-002 (#1779): opt-in nvw_batch_flush live submit path
        # witness, gated by PAIDEIA_R54_BDEV_FLUSH=1.
        #
        # The witness at src/kernel/boot/witness/r54_bdev_flush.pdx
        # (symbol r54_bdev_flush_witness) is NOT wired into
        # kernel_main at R54.M1 — same posture as r54_nvme_write /
        # pdxfs_lite_e2e / concurrent_io / msix_ir_round_robin: symbol
        # existence + build-time link verification are the R54.M1
        # acceptance criterion, live invocation is deferred to R55+
        # when the driver-attach ceremony surfaces a real NVMe
        # controller on the default boot path.
        #
        # Under -kernel, nvw_batch_flush itself takes its substrate
        # branch (_nvme_io_queue_count == 0), so a wired invocation
        # would still emit the pdxb bdev flush ok fingerprint but
        # without touching the driver. The witness is dormant at
        # R54.M1 to keep the boot-transcript stable across the
        # substrate/live cutover; when it is wired the fingerprint
        # golden at tests/r54/expected-r54-bdev-flush.txt already
        # names the three ordered substrings to check.
        echo "smoke: boot_r54_bdev_flush — SKIP (witness not wired at R54.M1; live submit path deferred to R55+ per design/kernel/nvme-write-blocking.md — chained on driver-attach + real NVMe controller on default boot path)"
        exit 0
        ;;
    boot_r56_meta)
        # R56.M3-006 (#1795): composite smoke for the VFS-metadata
        # syscall block (mkdir/rmdir/stat/getdents/unlink/rename,
        # sysnos 77..82) landed by R56.M3-002..005 (#1791..#1794).
        #
        # The witness at src/kernel/boot/witness/r56_meta.pdx (symbol
        # r56_meta_witness) is NOT wired into kernel_main at R56.M3
        # — same posture as r54_bdev_flush / r55_write_e2e / pdxfs_
        # lite_e2e / concurrent_io / msix_ir_round_robin: symbol
        # existence + build-time link verification are the R56.M3
        # acceptance criterion, live invocation is deferred to R57
        # when a ring-3 harness (userspace mkdir(1)/stat(1)/rmdir(1)/
        # unlink(1)/rename(1) binaries) can exercise the six sysnos
        # through the syscall trap.
        #
        # The deferral is structural, not scheduling: every sys_*_body
        # in the R56.M3 wave walks its caller-supplied path via
        # `user_read_str_via_walk` on a user VA, which resolves the
        # address against the current task's page tables. A kernel-
        # side call handing the walker a .bss scratch buffer either
        # returns 0 (walker miss -> EFAULT) or faults on a kernel-
        # only page. Forging a synthetic user aspace around the call
        # sequence duplicates the KPTI cr3 dance without benefit
        # over the ring-3 harness path, so R56.M3-006 lands the
        # symbol scaffold + fingerprint contract and defers live
        # invocation.
        #
        # The individual per-body fingerprints (sys mkdir ok, sys
        # stat ok, sys getdents ok, sys rmdir ok, sys unlink ok, sys
        # rename ok) are already covered by the per-syscall goldens
        # at tests/r56/expected-r56-{mkdir-rmdir,stat,getdents,unlink-
        # rename}.txt landed by R56.M3-002..005. The R56.M3-006
        # composite golden at tests/r56/expected-r56-meta.txt names
        # the six ordered substrings the future FINGERPRINT_MODE=1
        # flip will consume once the ring-3 harness lands.
        echo "smoke: boot_r56_meta — SKIP (witness not wired at R56.M3; live composite deferred to R57+ per src/kernel/boot/witness/r56_meta.pdx module header — chained on ring-3 VFS-metadata userspace harness; each sys_*_body's own fingerprint is covered by the R56.M3-002..005 per-body goldens under tests/r56/)"
        exit 0
        ;;
    boot_r31_spawn_pair)
        # R31.M2-1590 (#1590): loader-side multi-task boot spawn — the
        # first time this kernel runs a userspace server as a distinct
        # ring-3 process rather than synthesizing both halves of its RPC
        # from ring 0.
        #
        # Kernel wire-in: src/kernel/boot/kernel_main.pdx, immediately
        # after r29_chaos_witness_done and before sti. Claims endpoint
        # rows 1 and 2 by id (endpoint_alloc_at), witnesses the losing
        # and winning service-lookup orders, then spawns echo_client and
        # echo_server through boot_spawn_user_task (task_new ->
        # elf_lite_load with the owning task -> user_stack_alloc ->
        # fresh-task trampoline -> runq_enqueue) and asserts both tasks'
        # seeded capabilities carry their own (pid, generation) in the
        # cap_owner column.
        #
        # Fingerprint contract (contains-in-order):
        #   SVC ORDER OK                 lookup before register is -ENOENT;
        #                                after register it resolves to the
        #                                registered endpoint.
        #   BOOT SPAWN OK                both tasks created and enqueued.
        #   SPAWN OWNER OK               cap_owner[slot] == pack(pid, gen)
        #                                for each spawned task's own cap.
        #   R31 ECHO CLIENT RING3 OK     printed BY the client, in ring 3.
        #   R31 ECHO SERVER RING3 OK     printed BY the server, in ring 3.
        #   R31 ECHO PAIR OK             printed by the client after it
        #                                verified the reply length and the
        #                                server's FRAME_OP_REPLY_BIT flip —
        #                                a round trip between two real
        #                                processes, driven by the scheduler.
        #   R31 SPAWN CAP SWEEP OK count=2
        #                                the client died and the owner sweep
        #                                MATCHED. The count is asserted, not
        #                                just the marker: a sweep that
        #                                matches zero is exactly the
        #                                signature of capabilities seeded
        #                                but never claimed, which is the bug
        #                                #1590 closes, and a bare marker
        #                                would accept it.
        #
        # Why count is 2, and why it used to be 1 (R31.M2-1596, #1596):
        #
        # echo_client's sidecar seeds slots 0 and 1, so 2 is the number of
        # capabilities it dies holding and always should have been. It read
        # 1 because R20b runs ONE GLOBAL cap_table and every image named
        # slot 0, so the server — spawned second — re-minted the client's
        # slot 0 and cap_mint_write cleared its owner column on the way past.
        # The client lost a capability to another process, silently, and
        # this golden recorded the loss as the expected value.
        #
        # The pair kept working only by coincidence: both slot-0 entries
        # named endpoint 1 and the server's rights were a superset of the
        # client's. Two images whose slot 0 named different objects would
        # have swapped authority with nothing reporting it.
        #
        # #1596 gave the images disjoint slot windows (client 0-1, server 2)
        # and made loader_seed_caps REFUSE to seed a slot a live task holds.
        # So the count is now the count, and a regression to 1 means the
        # overwrite is back.
        #
        # Client spawn order is deliberate: the CLIENT is spawned first,
        # i.e. the order in which a client can run to completion before its
        # server has ever been scheduled. It works because the kernel claims
        # both endpoint rows before either task exists, so the send lands in
        # a live buffer and the recv blocks until the server drains it. A
        # test that always spawns the server first proves nothing about the
        # order that arrives the moment scheduling changes.
        #
        # Opt-in only (PAIDEIA_R31_SPAWN=1 in pre-push) until it has run
        # 5/5 consecutive passes, matching the promotion discipline used
        # for boot_r20b_echo and boot_r20b_rpc. The markers appear in
        # EVERY boot log — the spawn is unconditionally wired — but only
        # this mode asserts them.
        #
        # NOT SMP (the substrate is single-flow per
        # design/ipc/userspace-server-substrate.md §14 Q3, and
        # _iretq_frame_scratch is still one global).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r31/expected-spawn-pair.txt"
        TIMEOUT=12
        EXPECTED=""
        ;;
    boot_panic)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/logging/expected-panic-dump.txt"
        TIMEOUT=8
        EXPECTED=""
        ;;
    boot_release)
        # R49.M3-001 (#1576): release-mode boot regression gate.
        #
        # Rebuilds the kernel with PAIDEIA_BUILD_MODE=release (see
        # tools/build.sh; regenerates src/kernel/core/config/build_mode.pdx
        # with _kernel_build_mode = 1), boots under QEMU, and asserts:
        #
        #   1. Fingerprint: every line in tests/release/expected-release-
        #      boot.txt appears in order (banner + copyright + a system-
        #      ready line). Same contains-in-order semantics every other
        #      mode uses.
        #
        #   2. Line-count budget: the release boot fits in
        #      RELEASE_LINE_BUDGET lines (default 40). A regression that
        #      unmuted the witness stream would blow through the budget
        #      immediately (test mode is ~530 lines).
        #
        #   3. Zero R__ / M__-___ identifiers: no line matches
        #      `\bR[0-9]+\b` or `\bM[0-9]+-[0-9]+\b`. The banner_art
        #      copyright includes a numeric year (2026) that must not
        #      match this pattern by construction, and the release
        #      preamble/ready lines are already free of round tags.
        #
        #   4. Zero raw hex TSC timestamps: no line contains a 16-hex-
        #      digit run followed by `|` (klog's TSC column format). A
        #      regression that unmuted klog's drain-to-UART would trip
        #      this immediately.
        #
        # Non-vacuousness (R49.M3-001 acceptance criterion): trip any
        # one of the four gates by re-emitting a raw uart_puts of a
        # dev message inside the release presentation and observe the
        # mode fail. See design/kernel/boot-presentation.md §7.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/release/expected-release-boot.txt"
        TIMEOUT=10
        EXPECTED=""
        BUILD_MODE_OVERRIDE=release
        CHECK_RELEASE_BUDGET=1
        : "${RELEASE_LINE_BUDGET:=40}"
        ;;
    boot_r52_pdxfs_mkfs_nvme)
        # R52.M8-001 (#1721): mkfs.pdxfs smoke on a QEMU-attached blank
        # NVMe device.
        #
        # Attaches a per-invocation raw-format tempfile as an emulated
        # NVMe namespace (see NVME_MODE knob near the top of this file):
        # `-drive file=<tmpfile>,if=none,id=nvme0,format=raw -device
        # nvme,drive=nvme0,serial=deadbeef`. Under -kernel boot MCFG
        # remains absent (see drivers/nvme/probe.pdx's own drain-empty
        # guard), so `_nvme_device_count` stays 0 and the pdxfs_mkfs_
        # smoke_witness (src/kernel/boot/witness/pdxfs_mkfs_smoke.pdx)
        # takes its SUBSTRATE arm: mints a real KIND_NVME_CONTROLLER +
        # dual-kind KIND_NVME_NAMESPACE/KIND_BLKDEV cap chain, calls
        # mkfs_run, catches the NVMEIO_PICK_NONE cascade forwarded as
        # MKFS_ZERO_FAIL, and emits "PDXFS MKFS SMOKE SUBSTRATE OK".
        #
        # The drive attach is what proves the QEMU wiring is in place
        # for the LIVE arm's later landing (sibling issues #1722-#1726
        # add UEFI/OVMF wire-up + probe + attach ceremony that makes
        # `_nvme_device_count` > 0 at boot-witness time, at which
        # point the SUBSTRATE line naturally gives way to the LIVE
        # "PDXFS MKFS SMOKE OK" line without any change to this mode's
        # QEMU launch shape).
        #
        # Golden: tests/r52/expected-pdxfs-mkfs-nvme.txt pins the same
        # SUBSTRATE line, anchored by "BLOCK CACHE SUBSTRATE OK" (the
        # witness immediately before ours in r30_platform.pdx) and
        # "PDXFS BOOT MOUNT SUBSTRATE OK" (the witness immediately
        # after). Any regression that reorders or drops the mkfs
        # witness surfaces as a missing golden line.
        #
        # Boots the same tree the default matrix builds; no chardev
        # injection is needed (the witness fires early during
        # boot_continue_after_ring3 -> witness_r30_platform, well
        # before shell/init would reach any interactive prompt).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r52/expected-pdxfs-mkfs-nvme.txt"
        TIMEOUT=20
        NVME_MODE=1
        EXPECTED=""
        ;;
    boot_r53_round_trip_phase1)
        # R53.M4-004 (#1751): phase-1 subordinate mode of the two-
        # phase round-trip smoke. Requires --with-disk.
        #
        # Sequence (host-side + kernel-side):
        #
        #   * Host-side (via the --with-disk / --wipe pipeline the
        #     leading-flag parser R53.M4-001 #1748 + image-lifecycle
        #     block R53.M4-002 #1749 already own): the caller passes
        #     --wipe so tools/mkfs-pdxb.sh materialises a fresh PDXB
        #     superblock at ${DISK_IMAGE_PATH} before QEMU launches.
        #     The two-phase orchestrator meta-mode (sibling
        #     boot_r53_round_trip #1752) invokes THIS mode with
        #     "--with-disk --wipe" for exactly that reason; a manual
        #     caller that omits --wipe against a stale image gets
        #     whatever prior state the file already carried (no
        #     defensive re-wipe here).
        #
        #   * Kernel-side (single QEMU boot against the freshly-mkfs'd
        #     device): the standard boot chain fires the M8 witnesses
        #     in order — pdxfs_mkfs_smoke_witness (M8-001 #1721),
        #     pdxfs_boot_mount_smoke (M8-002 #1722, PDXFS BOOT MOUNT
        #     OK + PDXB PROBE OK from probe.pdx), pdxfs_pkg_install_
        #     witness (M8-003 #1723), pdxfs_umount_smoke_witness
        #     (M8-004 #1724, which stamps PDXB_SB_FLAG_CLEAN_UNMOUNT
        #     on the persisted superblock). Terminal witness
        #     pdxfs_round_trip_phased (this issue's own body in src/
        #     kernel/boot/witness/pdxfs_round_trip_phased.pdx)
        #     branches on the just-observed sb_flags bit 0 and emits
        #     "ROUND TRIP PHASE1 OK" for phase 1 (bit CLEAR, per
        #     that witness's header — the phase 1 disk arrives with
        #     bit 0 in the not-yet-cleanly-umounted state its
        #     discriminator treats as PHASE1).
        #
        # Golden: tests/r53/round-trip-phase1.golden pins the six
        # LIVE-arm ordered lines (PDXFS MKFS SMOKE OK / PDXB PROBE
        # OK / PDXFS BOOT MOUNT OK / PDXFS PKG INSTALL OK / PDXFS
        # UMOUNT CLEAN OK / ROUND TRIP PHASE1 OK). Substrate boots
        # (no --with-disk) fail the golden at the first LIVE line
        # because the mkfs_smoke witness stays on its SUBSTRATE arm
        # under NVMEIO_PICK_NONE — the [[ ${WITH_DISK} -eq 0 ]]
        # guard below refuses that upfront to give the operator a
        # clean "requires --with-disk" diagnostic instead of an
        # inscrutable fingerprint miss.
        #
        # Timeout budget: 25 s accommodates the full M8 witness
        # cluster on a slow host without the boot chain racing
        # against timeout; matches the design doc's §7.3 TIMEOUT=30
        # ceiling for the meta-mode split across two phases.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r53/round-trip-phase1.golden"
        TIMEOUT=25
        EXPECTED=""
        if [[ ${WITH_DISK} -eq 0 ]]; then
            echo "smoke: boot_r53_round_trip_phase1 requires --with-disk" >&2
            exit 2
        fi
        ;;
    boot_r53_round_trip_phase2)
        # R53.M4-004 (#1751): phase-2 subordinate mode of the two-
        # phase round-trip smoke. Requires --with-disk; does NOT wipe.
        #
        # Sequence (host-side + kernel-side):
        #
        #   * Host-side: the caller passes --with-disk WITHOUT --wipe,
        #     so the image-lifecycle block reuses the exact bytes the
        #     phase-1 kernel left after clean umount (per §2.1 of
        #     design/tooling/volume-lifecycle-mechanism.md: no
        #     -snapshot ever, host file mutations persist). The two-
        #     phase orchestrator meta-mode (sibling boot_r53_round_
        #     trip #1752) invokes THIS mode second, guarded on
        #     phase 1's clean exit.
        #
        #   * Kernel-side: the standard boot chain fires the same M8
        #     witnesses against the persisted superblock. pdxfs_boot_
        #     mount_smoke re-mounts the volume (PDXFS BOOT MOUNT OK
        #     + PDXB PROBE OK), pdxfs_reboot_verify_smoke (M8-005
        #     #1725) drives the sig-verify walk and emits "PDXFS
        #     REBOOT VERIFY OK" for the bit-SET arm (the phase-1
        #     umount stamped PDXB_SB_FLAG_CLEAN_UNMOUNT before this
        #     boot). The terminal witness pdxfs_round_trip_phased
        #     branches on the observed sb_flags bit 0 and emits
        #     "ROUND TRIP PHASE2 OK" for phase 2 (bit SET — the
        #     persisted-volume-from-clean-umount discriminator).
        #
        # Golden: tests/r53/round-trip-phase2.golden pins the four
        # LIVE-arm ordered lines (PDXB PROBE OK / PDXFS BOOT MOUNT
        # OK / PDXFS REBOOT VERIFY OK / ROUND TRIP PHASE2 OK). No
        # MKFS / PKG INSTALL / UMOUNT lines — those are phase 1
        # concerns, and the contains-in-order check pins only what
        # the phase 2 pass is expected to demonstrate (the reboot +
        # remount + verify path, not the write path). The M8
        # witnesses that DO emit those lines (M8-001, M8-003,
        # M8-004) still fire in this boot too — the smoke check's
        # contains-in-order semantic ignores extra unpinned lines.
        #
        # Timeout budget matches phase 1 (25 s) — the read-back +
        # sig-verify walk fits well inside it on any host that
        # completes phase 1 in time.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r53/round-trip-phase2.golden"
        TIMEOUT=25
        EXPECTED=""
        if [[ ${WITH_DISK} -eq 0 ]]; then
            echo "smoke: boot_r53_round_trip_phase2 requires --with-disk" >&2
            exit 2
        fi
        ;;
    boot_r53_round_trip)
        # R53.M4-005 (#1752): two-phase orchestrator meta-mode.
        #
        # Sequences the fresh-disk write pass and the preserved-disk
        # read-back pass into a single invocation, giving pre-push a
        # one-shot green/red on "reboot preserves state" instead of
        # asking the operator (or the hook) to script the phase pair.
        #
        # The subordinate phase modes + goldens land in sibling #1751
        # (R53.M4-004); the --with-disk / --wipe flag parsing they rely
        # on lands in #1748 (R53.M4-001). This meta-mode owns only the
        # orchestration: it does NOT itself build, launch QEMU, or
        # inspect a fingerprint — the two recursive self-invocations do
        # all of that.
        #
        # Ordering + disk lifecycle:
        #
        #   1. Phase 1 is invoked with `--wipe`, so the image-lifecycle
        #      block (added by #1749) deletes any stale image and calls
        #      `tools/mkfs-pdxb.sh` to produce a fresh PDXB superblock
        #      before QEMU launches. The phase-1 boot witness writes
        #      /test-file (deterministic 4 KiB pattern) and issues a
        #      clean umount; its golden asserts the write + umount chain.
        #
        #   2. Phase 2 is invoked WITHOUT `--wipe`. Because the image is
        #      a plain host file and this script never passes `-snapshot`
        #      to QEMU (see design/tooling/volume-lifecycle-mechanism.md
        #      §2.1), the mutations from phase 1 survive. The phase-2
        #      boot witness re-mounts, reads /test-file back, and emits
        #      a hash line; its golden asserts the hash matches the one
        #      the phase-1 witness recorded.
        #
        #   3. Combined pass = both phase-mode invocations exited with
        #      rc ∈ {0, 33}, which means both fingerprint checks
        #      succeeded (each phase runs its own contains-in-order
        #      check against its own golden). Phase 2 is guarded on
        #      phase 1 clean exit per §7.4 — a failed phase 1 aborts
        #      immediately without launching a second QEMU that would
        #      only fail on an image the write pass never finished.
        #
        # Exit-code guard: rc 0 = normal success, rc 33 = kernel graceful
        # clean exit (isa-debug-exit byte 0x10 → (0x10 << 1) | 1 = 33).
        # Both are treated as clean by every fingerprint mode in this
        # script; the meta-mode uses the same set so it agrees with
        # what the underlying phase modes consider "green".
        #
        # See design/tooling/volume-lifecycle-mechanism.md §7.4 for the
        # two-phase closure specification.

        # Phase 1: wipe -> mkfs -> write /test-file -> clean umount.
        # `--wipe` is required (not just recommended) so the round-trip
        # starts from a determinate empty superblock every time,
        # independent of whatever a previous session may have left in
        # tests/qemu/disks/pdxb-root.img.
        "$0" --with-disk --wipe boot_r53_round_trip_phase1
        _r53_phase1_rc=$?
        if [[ ${_r53_phase1_rc} -ne 0 && ${_r53_phase1_rc} -ne 33 ]]; then
            echo "smoke: boot_r53_round_trip PHASE1 FAILED (rc=${_r53_phase1_rc})" >&2
            exit ${_r53_phase1_rc}
        fi

        # Phase 2: preserve disk -> reboot -> read back /test-file.
        # No `--wipe` — the disk image from phase 1 is exactly what this
        # pass reads back. If phase 2 fails, the image is left on disk
        # for post-mortem (matches the `--with-disk` non-ephemeral
        # posture — the developer can re-launch phase 2 by hand to
        # observe the re-mount without redoing the write pass).
        "$0" --with-disk boot_r53_round_trip_phase2
        _r53_phase2_rc=$?
        if [[ ${_r53_phase2_rc} -ne 0 && ${_r53_phase2_rc} -ne 33 ]]; then
            echo "smoke: boot_r53_round_trip PHASE2 FAILED (rc=${_r53_phase2_rc})" >&2
            exit ${_r53_phase2_rc}
        fi

        echo "smoke: boot_r53_round_trip meta-mode passed (phase1+phase2 clean)"
        exit 0
        ;;
    boot_r54_bdev_round_trip_phase1)
        # R54.M1-003 (#1780): phase-1 subordinate mode of the two-
        # phase NVMe-block payload round-trip smoke. Requires
        # --with-disk --wipe.
        #
        # Sequence (host-side + kernel-side):
        #
        #   * Host-side (via the R53.M4-001 (#1748) --with-disk / --wipe
        #     pipeline and R53.M4-002 (#1749) image-lifecycle block):
        #     the caller passes --wipe so tools/mkfs-pdxb.sh
        #     materialises a fresh PDXB superblock at
        #     ${DISK_IMAGE_PATH} before QEMU launches. The two-phase
        #     orchestrator meta-mode (sibling boot_r54_bdev_round_trip)
        #     invokes THIS mode with "--with-disk --wipe" for exactly
        #     that reason; a manual caller that omits --wipe against a
        #     stale image gets whatever prior state the file already
        #     carried.
        #
        #   * Kernel-side (single QEMU boot against the freshly-mkfs'd
        #     device): the standard boot chain fires every existing
        #     R52/R53 PdxFS witness through r30_platform.pdx, and
        #     terminally the R54.M1-003 witness (r54_bdev_round_trip.
        #     pdx, wired into r30_platform.pdx immediately after
        #     pdxfs_round_trip_phased_call) branches on sb_flags bit 0
        #     -- CLEAR (fresh mkfs) -> phase 1 arm: stages
        #     0xDEADBEEFCAFEBABE into _r54rt_write_scratch, calls
        #     nvme_write_blocking(nsid=1, lba=16, count=1,
        #                         buf_pa=&_r54rt_write_scratch),
        #     emits the R54.M1-003 write-ok tag via klog_s1.
        #
        # Golden: tests/r54/expected-r54-bdev-round-trip-phase1.txt
        # pins the single write-ok fingerprint line (contains-in-order
        # check). Substrate boots fail the golden because the LIVE-
        # gate (_nvme_io_queue_count != 0) is CLEAR and the witness
        # emits its "R54 BDEV ROUND TRIP SUBSTRATE" line (no OK token)
        # instead of the ok tag -- the [[ ${WITH_DISK} -eq 0 ]] guard
        # below refuses that upfront to give a clean diagnostic.
        #
        # Timeout budget: 25 s matches boot_r53_round_trip_phase{1,2}
        # -- the whole M8 witness cluster + the R54 round-trip fit in
        # the same envelope.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r54/expected-r54-bdev-round-trip-phase1.txt"
        TIMEOUT=25
        EXPECTED=""
        if [[ ${WITH_DISK} -eq 0 ]]; then
            echo "smoke: boot_r54_bdev_round_trip_phase1 requires --with-disk" >&2
            exit 2
        fi
        ;;
    boot_r54_bdev_round_trip_phase2)
        # R54.M1-003 (#1780): phase-2 subordinate mode of the two-
        # phase NVMe-block payload round-trip smoke. Requires
        # --with-disk; does NOT wipe.
        #
        # Sequence (host-side + kernel-side):
        #
        #   * Host-side: the caller passes --with-disk WITHOUT --wipe,
        #     so the image-lifecycle block reuses the exact bytes the
        #     phase-1 kernel left after clean umount (per §2.1 of
        #     design/tooling/volume-lifecycle-mechanism.md: no
        #     -snapshot ever, host file mutations persist). The two-
        #     phase orchestrator meta-mode (sibling boot_r54_bdev_
        #     round_trip) invokes THIS mode second, guarded on phase 1's
        #     clean exit.
        #
        #   * Kernel-side: the standard boot chain re-mounts the
        #     preserved volume. The R54.M1-003 witness branches on
        #     sb_flags bit 0 -- SET (clean umount preserved) -> phase 2
        #     arm: zeroes _r54rt_read_scratch[0], calls
        #     nvme_read_blocking(nsid=1, lba=16, count=1,
        #                        buf_pa=&_r54rt_read_scratch),
        #     compares _r54rt_read_scratch[0] against
        #     0xDEADBEEFCAFEBABE, emits the R54.M1-003 readback-ok tag
        #     (match=1) via klog_s1 on match. A mismatch takes the
        #     r54rt_fail_stage arm and emits a fail line instead of
        #     the ok tag -- the coverage gate stays honest either way.
        #
        # Golden: tests/r54/expected-r54-bdev-round-trip-phase2.txt
        # pins the single readback-ok fingerprint line (contains-in-
        # order check).
        #
        # Timeout budget matches phase 1 (25 s).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r54/expected-r54-bdev-round-trip-phase2.txt"
        TIMEOUT=25
        EXPECTED=""
        if [[ ${WITH_DISK} -eq 0 ]]; then
            echo "smoke: boot_r54_bdev_round_trip_phase2 requires --with-disk" >&2
            exit 2
        fi
        ;;
    boot_r54_bdev_round_trip)
        # R54.M1-003 (#1780): two-phase orchestrator meta-mode for the
        # NVMe-block payload round-trip smoke.
        #
        # Sequences the fresh-disk write pass and the preserved-disk
        # read-back pass into a single invocation, giving pre-push a
        # one-shot green/red on "reboot preserves LBA 16 payload" --
        # the R54.M1-003 acceptance criterion. Mirrors the shape of
        # boot_r53_round_trip (R53.M4-005 #1752) exactly: subordinate
        # phase modes carry the goldens + qemu launch; this meta-mode
        # owns only the orchestration.
        #
        # Ordering + disk lifecycle:
        #
        #   1. Phase 1 is invoked with `--wipe`, so the image-lifecycle
        #      block deletes any stale image and calls
        #      `tools/mkfs-pdxb.sh` before QEMU launches. The phase-1
        #      boot witness writes 0xDEADBEEFCAFEBABE to LBA 16 via
        #      nvme_write_blocking and its golden asserts the write-ok
        #      tag.
        #
        #   2. Phase 2 is invoked WITHOUT `--wipe`. The image is a
        #      plain host file and this script never passes `-snapshot`
        #      to QEMU (design/tooling/volume-lifecycle-mechanism.md
        #      §2.1), so the write from phase 1 survives. The phase-2
        #      boot witness reads LBA 16, compares, emits the readback-
        #      ok tag; its golden asserts that tag matches.
        #
        #   3. Combined pass = both phase-mode invocations exited with
        #      rc ∈ {0, 33}, which means both fingerprint checks
        #      succeeded. Phase 2 is guarded on phase 1's clean exit
        #      per §7.4 -- a failed phase 1 aborts immediately without
        #      launching a second QEMU that would only fail on an
        #      image the write pass never finished.
        #
        # Exit-code guard: rc 0 = normal success, rc 33 = kernel
        # graceful clean exit (isa-debug-exit byte 0x10 -> QEMU exits
        # (0x10 << 1) | 1 = 33). Both are treated as clean by every
        # fingerprint mode in this script; matches boot_r53_round_trip.

        # Phase 1: wipe -> mkfs -> write LBA 16.
        "$0" --with-disk --wipe boot_r54_bdev_round_trip_phase1
        _r54_phase1_rc=$?
        if [[ ${_r54_phase1_rc} -ne 0 && ${_r54_phase1_rc} -ne 33 ]]; then
            echo "smoke: boot_r54_bdev_round_trip PHASE1 FAILED (rc=${_r54_phase1_rc})" >&2
            exit ${_r54_phase1_rc}
        fi

        # Phase 2: preserve disk -> reboot -> read LBA 16 back.
        "$0" --with-disk boot_r54_bdev_round_trip_phase2
        _r54_phase2_rc=$?
        if [[ ${_r54_phase2_rc} -ne 0 && ${_r54_phase2_rc} -ne 33 ]]; then
            echo "smoke: boot_r54_bdev_round_trip PHASE2 FAILED (rc=${_r54_phase2_rc})" >&2
            exit ${_r54_phase2_rc}
        fi

        echo "smoke: boot_r54_bdev_round_trip meta-mode passed (phase1+phase2 clean)"
        exit 0
        ;;
    boot_r55_write_e2e_phase1)
        # R55.M2-005 (#1787): phase-1 subordinate mode of the two-
        # phase pdxfs-block composed write-then-reboot-then-read-back
        # smoke. Requires --with-disk --wipe.
        #
        # Sequence (host-side + kernel-side):
        #
        #   * Host-side (via the R53.M4-001 (#1748) --with-disk / --wipe
        #     pipeline and R53.M4-002 (#1749) image-lifecycle block):
        #     the caller passes --wipe so tools/mkfs-pdxb.sh
        #     materialises a fresh PDXB superblock at
        #     ${DISK_IMAGE_PATH} before QEMU launches. The two-phase
        #     orchestrator meta-mode (sibling boot_r55_write_e2e)
        #     invokes THIS mode with "--with-disk --wipe" for exactly
        #     that reason.
        #
        #   * Kernel-side (single QEMU boot against the freshly-mkfs'd
        #     device): the standard boot chain fires every existing
        #     R52/R53/R54 PdxFS witness through r30_platform.pdx, and
        #     terminally the R55.M2-005 witness (r55_write_e2e.pdx,
        #     wired into r30_platform.pdx immediately after
        #     r54_bdev_round_trip_witness_call) branches on sb_flags
        #     bit 0 -- CLEAR (fresh mkfs) -> phase 1 arm: stages the
        #     13-byte payload "hello world\n" (backslash+n literal)
        #     into _r55we_payload_scratch and calls the R55.M2-004
        #     composed primitive pdxfs_block_write(vol_row=0, ino=2,
        #     offset=0, len=13, in_pa=&_r55we_payload_scratch). That
        #     primitive's step-14 klog_s1_x3 emit fires tag_pdxb_
        #     write_ok with ino/offset/len k=v pairs -- THAT emit is
        #     the phase-1 golden fingerprint (this witness does NOT
        #     emit an additional phase-1 tag).
        #
        # Golden: tests/r55/expected-r55-write-e2e-phase1.txt pins the
        # single write-ok fingerprint line (contains-in-order check).
        # Substrate boots fail the golden because the LIVE-gate
        # (_nvme_io_queue_count != 0) is CLEAR and the witness
        # silently returns without touching pdxfs_block_write's path
        # -- so the tag_pdxb_write_ok line the golden pins never
        # fires. The [[ ${WITH_DISK} -eq 0 ]] guard below refuses
        # that upfront to give a clean diagnostic.
        #
        # Timeout budget: 25 s matches boot_r53_round_trip_phase{1,2}
        # and boot_r54_bdev_round_trip_phase{1,2} -- the whole M8
        # witness cluster + the R54 + R55 witnesses fit in the same
        # envelope.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r55/expected-r55-write-e2e-phase1.txt"
        TIMEOUT=25
        EXPECTED=""
        if [[ ${WITH_DISK} -eq 0 ]]; then
            echo "smoke: boot_r55_write_e2e_phase1 requires --with-disk" >&2
            exit 2
        fi
        ;;
    boot_r55_write_e2e_phase2)
        # R55.M2-005 (#1787): phase-2 subordinate mode of the two-
        # phase pdxfs-block composed write-then-reboot-then-read-back
        # smoke. Requires --with-disk; does NOT wipe.
        #
        # Sequence (host-side + kernel-side):
        #
        #   * Host-side: the caller passes --with-disk WITHOUT --wipe,
        #     so the image-lifecycle block reuses the exact bytes the
        #     phase-1 kernel left after clean umount (per §2.1 of
        #     design/tooling/volume-lifecycle-mechanism.md: no
        #     -snapshot ever, host file mutations persist). The two-
        #     phase orchestrator meta-mode (sibling boot_r55_write_
        #     e2e) invokes THIS mode second, guarded on phase 1's
        #     clean exit.
        #
        #   * Kernel-side: the standard boot chain re-mounts the
        #     preserved volume. The R55.M2-005 witness branches on
        #     sb_flags bit 0 -- SET (clean umount preserved) -> phase
        #     2 arm: itable_init(sb_ptr), inode_read(bdev_cap=175,
        #     ino=2) -> inode_ptr; extracts data_lba = inode_ptr[+48]
        #     & 0x0000FFFFFFFFFFFF (allocator §"Extent slot 0
        #     stamping"); zeroes readback_scratch[0..15]; issues
        #     nvme_read_blocking(nsid=1, lba=data_lba, count=1,
        #     buf_pa=&_r55we_readback_scratch). Compares the first
        #     two qwords against the expected pattern
        #     (0x6F77206F6C6C6568, 0x0000006E5C646C72 -- little-
        #     endian "hello wo" + "rld\n" + 3 zero pad). On both
        #     matches emits tag_pdxb_persist_ok exactly once via
        #     klog_s1 (no k=v pairs; payload literal baked into the
        #     tag string). On any mismatch or upstream error takes
        #     the silent fail arm -- no OK-token emit -- so the
        #     golden fails at the missing ok-line rather than a
        #     spurious extra fail-line.
        #
        # Golden: tests/r55/expected-r55-write-e2e-phase2.txt pins
        # the single readback-ok fingerprint line (contains-in-order
        # check).
        #
        # Timeout budget matches phase 1 (25 s).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r55/expected-r55-write-e2e-phase2.txt"
        TIMEOUT=25
        EXPECTED=""
        if [[ ${WITH_DISK} -eq 0 ]]; then
            echo "smoke: boot_r55_write_e2e_phase2 requires --with-disk" >&2
            exit 2
        fi
        ;;
    boot_r55_write_e2e)
        # R55.M2-005 (#1787): two-phase orchestrator meta-mode for
        # the pdxfs-block composed write-then-reboot-then-read-back
        # smoke.
        #
        # Sequences the fresh-disk composed-write pass and the
        # preserved-disk composed-readback pass into a single
        # invocation, giving pre-push a one-shot green/red on
        # "reboot preserves the composed-write payload through the
        # allocator + inode-row writeback + WAL fsync + bdev write
        # chain" -- the R55.M2-005 acceptance criterion. Mirrors the
        # shape of boot_r53_round_trip (R53.M4-005 #1752) and
        # boot_r54_bdev_round_trip (R54.M1-003 #1780) exactly:
        # subordinate phase modes carry the goldens + qemu launch;
        # this meta-mode owns only the orchestration.
        #
        # Ordering + disk lifecycle:
        #
        #   1. Phase 1 is invoked with `--wipe`, so the image-
        #      lifecycle block deletes any stale image and calls
        #      `tools/mkfs-pdxb.sh` before QEMU launches. The phase-1
        #      boot witness writes "hello world\n" (13 bytes,
        #      backslash+n literal) through pdxfs_block_write into
        #      inode 2 at offset 0; its golden asserts the write-ok
        #      tag emitted by pdxfs_block_write's own step-14 emit.
        #
        #   2. Phase 2 is invoked WITHOUT `--wipe`. The image is a
        #      plain host file and this script never passes
        #      `-snapshot` to QEMU (design/tooling/volume-lifecycle-
        #      mechanism.md §2.1), so the write from phase 1
        #      survives. The phase-2 boot witness re-mounts, resolves
        #      inode 2's extent[0] LBA, reads that LBA, compares
        #      byte-for-byte, and emits tag_pdxb_persist_ok on match.
        #
        #   3. Combined pass = both phase-mode invocations exited
        #      with rc in {0, 33}, which means both fingerprint
        #      checks succeeded. Phase 2 is guarded on phase 1's
        #      clean exit per §7.4 -- a failed phase 1 aborts
        #      immediately without launching a second QEMU that
        #      would only fail on an image the write pass never
        #      finished.
        #
        # Exit-code guard: rc 0 = normal success, rc 33 = kernel
        # graceful clean exit (isa-debug-exit byte 0x10 -> QEMU
        # exits (0x10 << 1) | 1 = 33). Both are treated as clean by
        # every fingerprint mode in this script; matches boot_r53_
        # round_trip / boot_r54_bdev_round_trip.

        # Phase 1: wipe -> mkfs -> composed pdxfs_block_write to
        # inode 2 -> boot chain umount (M8-004) stamps CLEAN_UNMOUNT
        # on the persisted superblock.
        "$0" --with-disk --wipe boot_r55_write_e2e_phase1
        _r55_phase1_rc=$?
        if [[ ${_r55_phase1_rc} -ne 0 && ${_r55_phase1_rc} -ne 33 ]]; then
            echo "smoke: boot_r55_write_e2e PHASE1 FAILED (rc=${_r55_phase1_rc})" >&2
            exit ${_r55_phase1_rc}
        fi

        # Phase 2: preserve disk -> reboot -> read inode 2's
        # extent[0] LBA back and compare against the phase-1 payload.
        "$0" --with-disk boot_r55_write_e2e_phase2
        _r55_phase2_rc=$?
        if [[ ${_r55_phase2_rc} -ne 0 && ${_r55_phase2_rc} -ne 33 ]]; then
            echo "smoke: boot_r55_write_e2e PHASE2 FAILED (rc=${_r55_phase2_rc})" >&2
            exit ${_r55_phase2_rc}
        fi

        echo "smoke: boot_r55_write_e2e meta-mode passed (phase1+phase2 clean)"
        exit 0
        ;;
    boot_r53_first_mount)
        # R53.M4-003 (#1750): first PDXB volume-mount smoke on a
        # QEMU-attached NVMe device the sibling R53.M4-001 (#1748)
        # --with-disk flag parser + R53.M4-002 (#1749) image-lifecycle
        # block already wire up.
        #
        # Requires --with-disk (design/tooling/volume-lifecycle-
        # mechanism.md §7.3): without a live NVMe device the LIVE-arm
        # fingerprints the golden pins (PDXB PROBE OK, PDXB VOLUME
        # MOUNTED, PDXFS BOOT MOUNT OK, PDXB ROOT SELECTED) never
        # appear — the same probe/mount/root_select witnesses take
        # their SUBSTRATE arms and emit different strings the golden
        # would then fail. The WITH_DISK gate exits 2 (mirroring
        # `prod` mode's "kernel didn't build" conventional exit for
        # smokes that structurally cannot run) with a diagnostic
        # pointing at the missing flag, matching sibling
        # boot_r53_round_trip_phase{1,2} one-for-one.
        #
        # Golden: tests/r53/first-mount.golden pins the five ordered
        # fingerprints the LIVE arm produces. Terminal closer line
        # "FIRST MOUNT OK" is emitted by pdxfs_first_mount_witness
        # (src/kernel/boot/witness/pdxfs_first_mount.pdx, wired into
        # r30_platform.pdx immediately after pdxb_root_select_
        # fingerprint_call and before pdxfs_round_trip_final_call).
        # The four upstream fingerprints already exist: probe.pdx
        # (#1706 + R53.M3-005 #1746 hook), mount_block.pdx (#1707 +
        # R53.M3-005 hook), pdxfs_boot_mount_smoke.pdx (#1722 LIVE
        # arm), root_select.pdx (#1744 + R53.M3-005 hook LIVE arm).
        #
        # Timeout: 15s — matches the design doc's §7.3 shape; the
        # mount + inode-read round-trip is bounded by an in-memory
        # volume registry walk plus one nested block-cache read
        # (§4.2 step 3), all comfortably under the timer budget.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r53/first-mount.golden"
        TIMEOUT=15
        EXPECTED=""
        if [[ ${WITH_DISK} -eq 0 ]]; then
            echo "smoke: boot_r53_first_mount requires --with-disk" >&2
            exit 2
        fi
        ;;
    prod)
        # prod mode: expects exit code 2 (kernel didn't build)
        # Skip verification, just exit with code 2
        exit 2
        ;;
esac

# Global injection defaults. Fills in any INJECT_* knob left unset by
# both the caller's env AND the mode-branch. These values are exactly
# the historical boot_r16_uart_rx defaults, so that mode's behavior is
# preserved byte-for-byte.
: "${INJECT_STRING:=abc}"
: "${INJECT_DELAY:=1.0}"
: "${INJECT_HOLD:=15}"
: "${INJECT_WAIT_FOR:=}"
: "${INJECT_WAIT_TIMEOUT:=8}"
: "${INJECT_RETRIES:=1}"
: "${INJECT_RETRY_INTERVAL:=0.5}"

# Parse arguments: check for --fingerprint flag (backward-compatible)
if [[ "${EXPECTED}" == "--fingerprint" && -n "${2:-}" ]]; then
    FINGERPRINT_MODE=1
    FINGERPRINT_FILE="${REPO_ROOT}/tests/r8/expected-${2}.txt"
    EXPECTED=""
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "smoke: qemu-system-x86_64 not found; skipping" >&2
    exit 77
fi

# Fix #1588: the boot_exc3 / boot_panic_halt reduced kernels + their
# build-{exc3,panic}.sh scripts were archived. The reduced kernels
# (16-25 line kernel_main variants atop a 1319-line alternate boot
# stub) linked against the full kernel tree, and their trees never
# defined the boot-witness rodata + AP-trampoline symbols the tree
# now references — so the scripts broke silently and stayed broken
# with nothing in the default pre-push matrix exercising them. The
# main boot_panic mode uses the FULL kernel and covers the panic-
# emission chain already; no coverage was lost.
# R49.M3-001 (#1576): pass PAIDEIA_BUILD_MODE through when the mode
# dispatcher sets BUILD_MODE_OVERRIDE (currently only boot_release).
# Every other mode inherits the caller's environment unchanged, so the
# 14-mode witness matrix keeps building in TEST mode as before.
BUILD_MODE_OVERRIDE="${BUILD_MODE_OVERRIDE:-}"
CHECK_RELEASE_BUDGET="${CHECK_RELEASE_BUDGET:-0}"
if [[ -n "${BUILD_MODE_OVERRIDE}" ]]; then
    if ! PAIDEIA_BUILD_MODE="${BUILD_MODE_OVERRIDE}" "${REPO_ROOT}/tools/build.sh" >/dev/null 2>&1; then
        echo "smoke: build failed (PAIDEIA_BUILD_MODE=${BUILD_MODE_OVERRIDE})" >&2
        exit 2
    fi
else
    if ! "${REPO_ROOT}/tools/build.sh" >/dev/null 2>&1; then
        echo "smoke: build failed" >&2
        exit 2
    fi
fi
KERNEL="${REPO_ROOT}/build/kernel.elf"

LOG="/tmp/paideia-os-smoke.log"
rm -f "${LOG}"

# R53.M4-002 (#1749): PDXB disk-image lifecycle. When --with-disk is
# set (WITH_DISK=1 — flag parser owned by sibling R53.M4-001 #1748),
# materialise the backing image before launching QEMU:
#
#   - image absent             → mkfs
#   - --wipe (WIPE_DISK=1)     → unconditional re-mkfs (delegated via
#                                mkfs-pdxb.sh --force)
#   - image present, no --wipe → use as-is (re-boot path)
#
# Delegates to tools/mkfs-pdxb.sh (R53.M1-002 #1731) which owns the
# actual dd + mkfs-pdxb binary invocation + layout. Its exit-3
# signal (the mkfs-pdxb binary from R53.M1-001 #1730 is not built
# yet) fails the smoke cleanly with a pointer at the missing
# dependency rather than launching QEMU against a zero-byte or
# absent image.
#
# All three knobs are read as `${VAR:-default}` so this block is a
# no-op (DISK_ARGS empty; every legacy mode's launch shape preserved
# byte-for-byte) whenever the caller did not set WITH_DISK=1. When
# #1748 lands its leading-flag parser it will populate WITH_DISK /
# WIPE_DISK / DISK_IMAGE_PATH before this point; the defaults here
# are the fallback for direct env-driven callers and for the pre-
# #1748 transition window.
#
# Default image path: per-job scratch under ${CLAUDE_JOB_DIR}/tmp so
# parallel Claude jobs cannot stomp each other's image, else a
# stable /tmp path for developer shells. Size default matches the
# design doc's 128 MiB floor (§2.1); PDXB_IMAGE_SIZE_MIB env
# override still wins (mkfs-pdxb.sh reads the same var).
WITH_DISK="${WITH_DISK:-0}"
WIPE_DISK="${WIPE_DISK:-0}"
if [[ -n "${CLAUDE_JOB_DIR:-}" ]]; then
    DISK_IMAGE_PATH="${DISK_IMAGE_PATH:-${CLAUDE_JOB_DIR}/tmp/pdxb-smoke.img}"
else
    DISK_IMAGE_PATH="${DISK_IMAGE_PATH:-/tmp/paideia-pdxb-smoke.img}"
fi
DISK_IMAGE_SIZE_MIB="${DISK_IMAGE_SIZE_MIB:-${PDXB_IMAGE_SIZE_MIB:-128}}"
DISK_ARGS=()
if [[ ${WITH_DISK} -eq 1 ]]; then
    mkfs_needed=0
    if [[ ${WIPE_DISK} -eq 1 ]]; then
        mkfs_needed=1
    elif [[ ! -f "${DISK_IMAGE_PATH}" ]]; then
        mkfs_needed=1
    fi
    if [[ ${mkfs_needed} -eq 1 ]]; then
        mkdir -p -- "$(dirname -- "${DISK_IMAGE_PATH}")"
        mkfs_flags=()
        if [[ ${WIPE_DISK} -eq 1 ]]; then
            mkfs_flags+=(--force)
        fi
        mkfs_stderr="$(mktemp -t paideia-mkfs-stderr-XXXXXX)"
        PDXB_IMAGE_SIZE_MIB="${DISK_IMAGE_SIZE_MIB}" \
            "${REPO_ROOT}/tools/mkfs-pdxb.sh" "${mkfs_flags[@]}" \
            "${DISK_IMAGE_PATH}" >/dev/null 2>"${mkfs_stderr}"
        mkfs_rc=$?
        if [[ ${mkfs_rc} -ne 0 ]]; then
            if [[ ${mkfs_rc} -eq 3 ]]; then
                echo "smoke: --with-disk requested but mkfs-pdxb binary is not built yet" >&2
                echo "smoke: land R53.M1-001 (#1730 — src/tools/mkfs-pdxb/main.pdx) then re-run 'bash tools/build.sh'" >&2
            else
                echo "smoke: tools/mkfs-pdxb.sh failed (rc=${mkfs_rc})" >&2
            fi
            [[ -s "${mkfs_stderr}" ]] && cat "${mkfs_stderr}" >&2
            rm -f "${mkfs_stderr}"
            exit 1
        fi
        rm -f "${mkfs_stderr}"
    fi
    # NVMe topology (§2.1 of design/tooling/volume-lifecycle-mechanism.md):
    # if=none decouples the drive from the default IDE bus; the nvme
    # device binds it explicitly. serial=PDXB0001 is grep-stable across
    # boots. logical/physical_block_size=4096 matches PDXB v1 (R52
    # §2.6) — the R52 mount refuses if geom.lba_size != 4096.
    DISK_ARGS=(
        -drive "file=${DISK_IMAGE_PATH},if=none,id=nvme0,format=raw"
        -device "nvme,drive=nvme0,serial=PDXB0001,logical_block_size=4096,physical_block_size=4096"
    )
fi

# R101.M4-003 (paideia-os #2152): PAIDEIA_VGA env-switch for the
# boot_r101_stdvga smoke (and future GUI smokes). Default `none` keeps
# every pre-R101 smoke's launch shape byte-for-byte identical -- no
# -vga / -device flags emitted. `std` attaches QEMU's Bochs display
# (PCI 0x1234/0x1111) the R101 witness probes; `virtio` reserved for
# the R103 virtio-gpu backend once that lands.
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
        echo "smoke: PAIDEIA_VGA='${PAIDEIA_VGA}' invalid; expected one of: std, virtio, none" >&2
        exit 2
        ;;
esac

if [[ ${UART_RX_MODE} -eq 1 ]]; then
    # R16.M4-666 (#666) end-to-end UART RX real-IRQ smoke.
    #
    # QEMU chardev pipe requires two pre-existing named FIFOs at
    # ${FIFO_BASE}.in and ${FIFO_BASE}.out. QEMU opens .in for READ
    # (guest RX) and .out for WRITE (guest TX). Both opens block
    # until the host side has a peer open — so we bring up the reader
    # and the writer BEFORE launching QEMU, in the background, and
    # let them keep the pipe alive for the full boot window.
    #
    # Injection timing: sleep 1.0s after QEMU launch, then write 'abc'.
    # The kernel witness (uart_rx_wire_witness) polls up to ~2s under
    # `sti` right before lapic_timer_init — that window straddles the
    # 1s injection either way (bytes arrive live under sti, or bytes
    # pre-queue in QEMU 16550 RBR and fire IRQ once ERBFI is set at
    # kernel uart_rx_init). See design/kernel/r16-m4-666-uart-rx-e2e-smoke.md §5.
    #
    # Trailing sleep on the writer keeps the pipe open so QEMU's
    # 16550 read side does not EOF mid-boot.
    FIFO_BASE="/tmp/paideia-os-uart-rx-$$"
    FIFO_IN="${FIFO_BASE}.in"
    FIFO_OUT="${FIFO_BASE}.out"
    rm -f "${FIFO_IN}" "${FIFO_OUT}"
    mkfifo "${FIFO_IN}" "${FIFO_OUT}"

    # Background reader: drain guest TX into LOG (matches the default
    # -serial file:${LOG} behavior every other mode relies on).
    # #757: line-buffer via stdbuf so INJECT_WAIT_FOR's grep on LOG
    # sees the readiness marker without waiting for cat's ~4KB stdio
    # buffer to fill. Falls back to bare cat if stdbuf is missing
    # (unlikely on Linux — ships with coreutils — but harmless).
    if command -v stdbuf >/dev/null 2>&1; then
        stdbuf -oL cat "${FIFO_OUT}" > "${LOG}" &
    else
        cat "${FIFO_OUT}" > "${LOG}" &
    fi
    READER_PID=$!

    # Background writer: hold .in open for QEMU's read side; inject
    # INJECT_STRING after INJECT_DELAY settle so the kernel reaches
    # uart_rx_init (and any wait-for-prompt state) before the bytes
    # hit the 16550. INJECT_HOLD keeps the pipe alive for the full
    # boot window so QEMU's 16550 read side does not EOF mid-boot.
    # #750: parameterized (was hardcoded 'abc' + 1.0s + 15s) so shell
    # smoke modes can specify e.g. "echo hello\nexit\n" + 4.0s + 20s.
    # #757: optional INJECT_WAIT_FOR replaces the blind sleep with a
    # log-poll for a readiness marker (e.g. "SHELL START"), plus
    # INJECT_RETRIES for cases where a single write may not land during
    # the guest's read window. Redirection `> ${FIFO_IN}` opens the
    # pipe at subshell entry and blocks until QEMU opens the read
    # side; the body only runs once QEMU is attached, so the wait/
    # inject sequence is anchored to QEMU-attached time, not host time.
    (
        if [[ -n "${INJECT_WAIT_FOR}" ]]; then
            # Poll the serial log for the readiness marker. LOG is
            # populated by the background `cat ${FIFO_OUT} > ${LOG}`
            # reader started just above, so it grows in real time as
            # the guest writes to serial.
            wait_start=${SECONDS}
            while (( SECONDS - wait_start < INJECT_WAIT_TIMEOUT )); do
                if [[ -s "${LOG}" ]] && grep -q "${INJECT_WAIT_FOR}" "${LOG}" 2>/dev/null; then
                    break
                fi
                sleep 0.1
            done
        fi
        # INJECT_DELAY still applies (post-ready settle when WAIT_FOR is
        # set; sole pre-write timing when it isn't — preserves the
        # boot_r16_uart_rx byte-for-byte default behavior).
        sleep "${INJECT_DELAY}"
        # Inject INJECT_STRING one or more times. `printf` here is the
        # bash builtin (write(2), no libc stdio buffering), so bytes
        # hit the FIFO promptly. Multiple attempts help when a single
        # write may not overlap the guest's read window (e.g. tty
        # bridge subtests may consume bytes before the shell reads).
        for _ in $(seq 1 "${INJECT_RETRIES}"); do
            printf '%b' "${INJECT_STRING}"
            if (( INJECT_RETRIES > 1 )); then
                sleep "${INJECT_RETRY_INTERVAL}"
            fi
        done
        sleep "${INJECT_HOLD}"
    ) > "${FIFO_IN}" &
    WRITER_PID=$!

    # R53.M4-001/002 (#1748/#1749): --with-disk splices the NVMe drive
    # into the UART-RX QEMU launch too (DISK_ARGS is empty when the
    # flag is not set, so the launch shape is byte-for-byte identical
    # for every legacy interactive-shell mode).
    timeout ${TIMEOUT} qemu-system-x86_64 \
        -kernel "${KERNEL}" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -chardev pipe,id=char0,path="${FIFO_BASE}" \
        -serial chardev:char0 \
        -display none \
        -no-reboot \
        -no-shutdown \
        -m 32M \
        "${DISK_ARGS[@]}" \
        "${VGA_ARGS[@]}" \
        >/dev/null 2>&1
    QEMU_RC=$?

    # Tear down background procs (may already be gone if writer sleep expired).
    kill "${WRITER_PID}" 2>/dev/null || true
    kill "${READER_PID}" 2>/dev/null || true
    wait "${WRITER_PID}" 2>/dev/null || true
    wait "${READER_PID}" 2>/dev/null || true
    rm -f "${FIFO_IN}" "${FIFO_OUT}"
else
    # R18-M1 #764: multicore launch when SMP_MODE=1. QEMU's `-smp N`
    # exposes N logical CPUs to the guest; the kernel BSP boots first,
    # then wakes SMP_CPU_COUNT-1 APs (assumes contiguous APIC IDs
    # 1..N-1 — matches the QEMU default topology). Passing `-smp 1`
    # (SMP_MODE=0 default) preserves the historical single-CPU launch
    # byte-for-byte for every legacy mode.
    SMP_ARGS=()
    if [[ ${SMP_MODE} -eq 1 ]]; then
        SMP_ARGS=(-smp "${SMP_CPU_COUNT}")
    fi
    # R21-M2 #832: opt-in `-cpu` override for smokes that need feature
    # bits beyond qemu64 default (boot_r21_ymm_preserve → `-cpu max`
    # for XSAVE + AVX2). Empty QEMU_CPU (default) leaves the QEMU
    # `-cpu` unset, preserving qemu64-default behavior for every legacy
    # mode byte-for-byte.
    CPU_ARGS=()
    if [[ -n "${QEMU_CPU}" ]]; then
        CPU_ARGS=(-cpu "${QEMU_CPU}")
    fi
    # R52.M8-001 (#1721): opt-in NVMe drive attach for boot_r52_pdxfs_
    # mkfs_nvme. Provisions a per-invocation raw-format tempfile of
    # NVME_IMG_SIZE_MB (default 16) MiB, exposes it as an emulated
    # NVMe namespace (`-drive file=<tmpfile>,if=none,id=nvme0,format=
    # raw -device nvme,drive=nvme0,serial=deadbeef`), and unlinks the
    # tempfile after QEMU exits. Empty NVME_MODE (default 0) leaves
    # NVME_ARGS unset, preserving every legacy mode's QEMU launch
    # byte-for-byte.
    #
    # R53.M4-001 (#1748) note: --with-disk / --wipe do NOT route
    # through this legacy path — they go through the separate DISK_ARGS
    # block above (R53.M4-002 #1749) which delegates to mkfs-pdxb.sh
    # instead of raw zero-fill. This block is the boot_r52_pdxfs_mkfs_
    # nvme entrypoint only (NVME_MODE=1 either from the mode dispatcher
    # or as an env override).
    NVME_ARGS=()
    NVME_CLEANUP=""
    if [[ ${NVME_MODE} -eq 1 ]]; then
        if [[ -z "${NVME_IMG}" ]]; then
            NVME_IMG="$(mktemp -t paideia-pdxfs-smoke-XXXXXX.img)"
            NVME_CLEANUP="${NVME_IMG}"
        fi
        # Provision the backing file. dd is used (vs. truncate) so the
        # file is zero-filled up front — an emulated NVMe namespace
        # reads back defined zeros from every unwritten LBA and mkfs
        # writes have a determinate target.
        dd if=/dev/zero of="${NVME_IMG}" bs=1M count="${NVME_IMG_SIZE_MB}" \
            status=none 2>/dev/null || {
            echo "smoke: failed to provision NVMe backing image ${NVME_IMG}" >&2
            [[ -n "${NVME_CLEANUP}" ]] && rm -f "${NVME_CLEANUP}"
            exit 1
        }
        NVME_ARGS=(
            -drive "file=${NVME_IMG},if=none,id=nvme0,format=raw"
            -device "nvme,drive=nvme0,serial=deadbeef"
        )
    fi
    # R53.M4-001/002 (#1748/#1749): --with-disk splices the NVMe drive
    # into the standard QEMU launch. DISK_ARGS is empty when the flag
    # is not set, so every legacy mode's launch shape is preserved
    # byte-for-byte. Sits alongside (not instead of) NVME_ARGS so
    # boot_r52_pdxfs_mkfs_nvme's env-driven tempfile path is unchanged.
    timeout ${TIMEOUT} qemu-system-x86_64 \
        -kernel "${KERNEL}" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -serial "file:${LOG}" \
        -display none \
        -no-reboot \
        -no-shutdown \
        -m 32M \
        "${CPU_ARGS[@]}" \
        "${SMP_ARGS[@]}" \
        "${NVME_ARGS[@]}" \
        "${DISK_ARGS[@]}" \
        "${VGA_ARGS[@]}" \
        >/dev/null 2>&1
    QEMU_RC=$?
    if [[ -n "${NVME_CLEANUP}" ]]; then
        rm -f "${NVME_CLEANUP}"
    fi
fi

# QEMU exit codes: 124 = timeout (expected for halt+stay-on); 0 = clean; 35 = panic exit
if [[ ${QEMU_RC} -ne 0 && ${QEMU_RC} -ne 124 && ${QEMU_RC} -ne 35 ]]; then
    echo "smoke: qemu exited with rc=${QEMU_RC}" >&2
    exit 1
fi

if [[ ${FINGERPRINT_MODE} -eq 1 ]]; then
    # Fingerprint mode: validate serial output against expected lines
    if [[ ! -f "${FINGERPRINT_FILE}" ]]; then
        echo "smoke: fingerprint file not found: ${FINGERPRINT_FILE}" >&2
        exit 1
    fi

    # Read fingerprint file and check each line appears in order in the log
    log_content="$(cat "${LOG}" 2>/dev/null || echo "")"
    line_num=0
    search_offset=0

    while IFS= read -r line; do
        ((line_num++))
        if [[ -z "${line}" ]]; then
            # Skip empty lines in fingerprint file
            continue
        fi
        # R18-M1 #764: boot_smp — CPU_ID_XX_HELLO lines are presence-
        # only (no cross-AP ordering). Intel MP-init lets APs leave
        # wait-for-SIPI at slightly different times, and COM1 is
        # unlocked (ap_entry.pdx concurrency note), so on-wire order
        # of the three AP HELLOs is not deterministic. Bookend lines
        # (SMP BRINGUP START / DONE) still go through the ordered
        # check below, anchoring the AP HELLOs between them.
        if [[ ${SMP_UNORDERED_HELLO} -eq 1 && "${line}" =~ ^CPU_ID_[0-9a-f][0-9a-f]_HELLO$ ]]; then
            if [[ "${log_content}" == *"${line}"* ]]; then
                # Presence confirmed; do NOT advance search_offset (unordered).
                continue
            else
                echo "smoke: unordered fingerprint line ${line_num} ('${line}') NOT found anywhere in serial log (log size: $(stat -c%s "${LOG}" 2>/dev/null || echo 0))" >&2
                exit 1
            fi
        fi
        # #673: search remaining log starting at search_offset (real ordered check)
        remaining="${log_content:search_offset}"
        if [[ "${remaining}" == *"${line}"* ]]; then
            # Line found; advance search_offset past this occurrence
            prefix="${remaining%%"${line}"*}"
            search_offset=$((search_offset + ${#prefix} + ${#line}))
        else
            echo "smoke: fingerprint line ${line_num} ('${line}') NOT found in serial log after position ${search_offset} (log size: $(stat -c%s "${LOG}" 2>/dev/null || echo 0))" >&2
            exit 1
        fi
    done < "${FINGERPRINT_FILE}"

    echo "smoke: fingerprint check passed (all ${line_num} lines found in order)"

    # R49.M3-001 (#1576): release-mode extended assertions. Runs ONLY
    # for modes that set CHECK_RELEASE_BUDGET (boot_release). All four
    # gates operate on the SAME serial log the fingerprint check just
    # ran against.
    if [[ ${CHECK_RELEASE_BUDGET} -eq 1 ]]; then
        release_line_count=$(wc -l < "${LOG}")
        if [[ ${release_line_count} -gt ${RELEASE_LINE_BUDGET} ]]; then
            echo "smoke: release-mode line budget exceeded (${release_line_count} > ${RELEASE_LINE_BUDGET}); see design/kernel/boot-presentation.md §6" >&2
            exit 1
        fi
        # Zero R__ / M__-___ round or milestone identifiers. Excludes
        # the banner_art copyright year (four digits, no leading R/M).
        if grep -Eq '\b(R[0-9]+|M[0-9]+-[0-9]+)\b' "${LOG}"; then
            echo "smoke: release log contains a round/milestone identifier — regression against R49.M2-002 (#1574)" >&2
            grep -Enm 3 '\b(R[0-9]+|M[0-9]+-[0-9]+)\b' "${LOG}" >&2 || true
            exit 1
        fi
        # Zero raw hex TSC timestamps. klog's TSC column is 16 hex
        # digits immediately followed by `|` — no other release-visible
        # line has that shape.
        if grep -Eq '[0-9a-f]{16}\|' "${LOG}"; then
            echo "smoke: release log contains a raw hex TSC timestamp — klog drain unmuted?" >&2
            grep -Enm 3 '[0-9a-f]{16}\|' "${LOG}" >&2 || true
            exit 1
        fi
        echo "smoke: release-mode gates passed (lines=${release_line_count}, budget=${RELEASE_LINE_BUDGET}, no round/hex tags)"
    fi
    exit 0
fi

if [[ -n "${EXPECTED}" ]]; then
    if [[ -s "${LOG}" ]] && grep -q "${EXPECTED}" "${LOG}"; then
        echo "smoke: marker '${EXPECTED}' found in serial log"
        exit 0
    else
        echo "smoke: marker '${EXPECTED}' NOT in serial log (log size: $(stat -c%s "${LOG}" 2>/dev/null || echo 0))" >&2
        exit 1
    fi
fi

echo "smoke: kernel built + booted (no marker check requested)"
exit 0
