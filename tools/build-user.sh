#!/usr/bin/env bash
# Build the PaideiaOS user shell, init, and child_hello binaries
# (R15-m1-003 / #515, R17-m2-001 / #616, R15-m6-009 / #560).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PAIDEIA_AS="$("${REPO_ROOT}/tools/find-paideia-as.sh")"
USER_SRC="${REPO_ROOT}/src/user"
BUILD_DIR="${REPO_ROOT}/build/user"
SHELL_LINK_SCRIPT="${USER_SRC}/link.ld"
INIT_LINK_SCRIPT="${USER_SRC}/init.ld"
CHILD_HELLO_LINK_SCRIPT="${USER_SRC}/child_hello.ld"
TRUE_LINK_SCRIPT="${USER_SRC}/true.ld"
CAT_LINK_SCRIPT="${USER_SRC}/cat.ld"
PS_LINK_SCRIPT="${USER_SRC}/ps.ld"
ECHO_SERVER_LINK_SCRIPT="${USER_SRC}/echo_server.ld"
ECHO_CLIENT_LINK_SCRIPT="${USER_SRC}/echo_client.ld"
ACPI_SUPERVISOR_LINK_SCRIPT="${USER_SRC}/acpi_supervisor.ld"
PCI_ENUMERATOR_LINK_SCRIPT="${USER_SRC}/pci_enumerator.ld"
AUDIO_SUPERVISOR_LINK_SCRIPT="${USER_SRC}/audio_supervisor.ld"
ELEVATE_BROKER_DAEMON_LINK_SCRIPT="${USER_SRC}/elevate_broker_daemon.ld"
LS_LINK_SCRIPT="${USER_SRC}/ls.ld"

if [[ ! -f "${SHELL_LINK_SCRIPT}" ]]; then
    echo "shell linker script missing: ${SHELL_LINK_SCRIPT}" >&2
    exit 1
fi

if [[ ! -f "${INIT_LINK_SCRIPT}" ]]; then
    echo "init linker script missing: ${INIT_LINK_SCRIPT}" >&2
    exit 1
fi

if [[ ! -f "${CHILD_HELLO_LINK_SCRIPT}" ]]; then
    echo "child_hello linker script missing: ${CHILD_HELLO_LINK_SCRIPT}" >&2
    exit 1
fi

if [[ ! -f "${TRUE_LINK_SCRIPT}" ]]; then
    echo "true linker script missing: ${TRUE_LINK_SCRIPT}" >&2
    exit 1
fi

if [[ ! -f "${CAT_LINK_SCRIPT}" ]]; then
    echo "cat linker script missing: ${CAT_LINK_SCRIPT}" >&2
    exit 1
fi

if [[ ! -f "${PS_LINK_SCRIPT}" ]]; then
    echo "ps linker script missing: ${PS_LINK_SCRIPT}" >&2
    exit 1
fi

if [[ ! -f "${ECHO_SERVER_LINK_SCRIPT}" ]]; then
    echo "echo_server linker script missing: ${ECHO_SERVER_LINK_SCRIPT}" >&2
    exit 1
fi

if [[ ! -f "${ECHO_CLIENT_LINK_SCRIPT}" ]]; then
    echo "echo_client linker script missing: ${ECHO_CLIENT_LINK_SCRIPT}" >&2
    exit 1
fi

if [[ ! -f "${ACPI_SUPERVISOR_LINK_SCRIPT}" ]]; then
    echo "acpi_supervisor linker script missing: ${ACPI_SUPERVISOR_LINK_SCRIPT}" >&2
    exit 1
fi

if [[ ! -f "${PCI_ENUMERATOR_LINK_SCRIPT}" ]]; then
    echo "pci_enumerator linker script missing: ${PCI_ENUMERATOR_LINK_SCRIPT}" >&2
    exit 1
fi

if [[ ! -f "${AUDIO_SUPERVISOR_LINK_SCRIPT}" ]]; then
    echo "audio_supervisor linker script missing: ${AUDIO_SUPERVISOR_LINK_SCRIPT}" >&2
    exit 1
fi

if [[ ! -f "${ELEVATE_BROKER_DAEMON_LINK_SCRIPT}" ]]; then
    echo "elevate_broker_daemon linker script missing: ${ELEVATE_BROKER_DAEMON_LINK_SCRIPT}" >&2
    exit 1
fi

if [[ ! -f "${LS_LINK_SCRIPT}" ]]; then
    echo "ls linker script missing: ${LS_LINK_SCRIPT}" >&2
    exit 1
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Build all .pdx files to objects
ALL_OBJECTS=()
SHELL_OBJECTS=()
INIT_OBJECTS=()
CHILD_HELLO_OBJECTS=()
TRUE_OBJECTS=()
CAT_OBJECTS=()
PS_OBJECTS=()
ECHO_SERVER_OBJECTS=()
ECHO_CLIENT_OBJECTS=()
ACPI_SUPERVISOR_OBJECTS=()
PCI_ENUMERATOR_OBJECTS=()
AUDIO_SUPERVISOR_OBJECTS=()
ELEVATE_BROKER_DAEMON_OBJECTS=()
LS_OBJECTS=()
LIBC_OBJECTS=()
AML_OBJECTS=()
LIBS_OBJECTS=()

while IFS= read -r -d '' pdx; do
    rel="${pdx#"${USER_SRC}"/}"
    obj="${BUILD_DIR}/${rel%.pdx}.o"
    mkdir -p "$(dirname "${obj}")"
    echo "[build-user] paideia-as ${rel} -> ${obj#"${BUILD_DIR}"/}"
    "${PAIDEIA_AS}" build --emit elf64 "${pdx}" -o "${obj}"
    ALL_OBJECTS+=("${obj}")

    # Separate init / child_hello / true from shell objects; shared libraries
    # go to both shell and init but NOT to the self-contained fixtures
    # (child_hello and true both inline their two syscalls to avoid pulling
    # the shim's other 10 wrappers — one .pdx file, one .elf pattern).
    if [[ "${rel}" == "init.pdx" ]]; then
        INIT_OBJECTS+=("${obj}")
    elif [[ "${rel}" == "child_hello.pdx" ]]; then
        CHILD_HELLO_OBJECTS+=("${obj}")
    elif [[ "${rel}" == "true.pdx" ]]; then
        TRUE_OBJECTS+=("${obj}")
    elif [[ "${rel}" == "cat.pdx" ]]; then
        # R57.M4-002 (paideia-os #1798): cat.pdx is self-contained
        # (inlines its five SC+ syscalls -- read/write/open/close/exit)
        # so its object goes to its own set only -- no library pull-in.
        # Same one-file-one-ELF discipline as child_hello / true /
        # echo_server / echo_client / acpi_supervisor / pci_enumerator.
        CAT_OBJECTS+=("${obj}")
    elif [[ "${rel}" == "ps.pdx" ]]; then
        # R57.M4-003 (paideia-os #1799): ps.pdx is self-contained
        # (inlines its three syscalls -- sys_write/sys_taskinfo/sys_exit)
        # so its object goes to its own set only -- no library pull-in.
        # Mirrors true.pdx / child_hello.pdx classification pattern.
        PS_OBJECTS+=("${obj}")
    elif [[ "${rel}" == "echo_server.pdx" ]]; then
        # R20b.M5-001 (#1563): echo_server.pdx is self-contained (inlines its
        # four IPC syscalls; same one-file-one-ELF discipline as child_hello /
        # true) so its object goes to its own set only — no library pull-in.
        ECHO_SERVER_OBJECTS+=("${obj}")
    elif [[ "${rel}" == "echo_client.pdx" ]]; then
        # R20b.M6-003 (#1566): echo_client.pdx is self-contained (inlines its
        # three syscalls — sys_ipc_send/recv + sys_exit) so its object goes
        # to its own set only — no library pull-in. Sidecar seeds TWO cap
        # slots (server + reply endpoints) for the dual-endpoint pattern.
        ECHO_CLIENT_OBJECTS+=("${obj}")
    elif [[ "${rel}" == "acpi_supervisor.pdx" ]]; then
        # R20-M4-002 (#820): acpi_supervisor.pdx is self-contained (inlines
        # its two IPC syscalls — sys_ipc_recv + sys_ipc_reply) so its object
        # goes to its own set only — no library pull-in. Sidecar seeds TWO
        # cap slots (KIND_IPC_ENDPOINT + KIND_ACPI) per the dispatch loop's
        # request/reply pattern.
        ACPI_SUPERVISOR_OBJECTS+=("${obj}")
    elif [[ "${rel}" == "audio_supervisor.pdx" ]]; then
        # R33.M5-001 (#1157): audio_supervisor.pdx is self-contained
        # (inlines its two IPC syscalls — sys_ipc_recv + sys_ipc_reply).
        # Sidecar seeds TWO cap slots (14 = RPC endpoint at endpoint_id=5,
        # 15 = reserved endpoint at endpoint_id=6).
        AUDIO_SUPERVISOR_OBJECTS+=("${obj}")
    elif [[ "${rel}" == "elevate_broker_daemon.pdx" ]]; then
        # R48-PREP-005.M2 (design/services/svc-elevate-broker-registration.md):
        # elevate_broker_daemon.pdx is self-contained (inlines its two IPC
        # syscalls + sys_debug_puts) so its object goes to its own set only
        # — no library pull-in. Sidecar seeds ONE cap slot (16, chosen as
        # the next free absolute slot per design/capabilities/loader-
        # seeded-slot-allocation.md §3 — the design doc's own draft named
        # slot 8, which collides with acpi_supervisor's live slot).
        ELEVATE_BROKER_DAEMON_OBJECTS+=("${obj}")
    elif [[ "${rel}" == "pci_enumerator.pdx" ]]; then
        # R22-M3-005 (#860): pci_enumerator.pdx is self-contained (inlines
        # its two IPC syscalls — sys_ipc_recv + sys_ipc_reply) so its object
        # goes to its own set only — no library pull-in. Sidecar seeds TWO
        # cap slots (KIND_IPC_ENDPOINT + KIND_PCI_DEV) per the dispatch
        # loop's request/reply pattern. Mirrors the acpi_supervisor.pdx
        # shape byte-for-byte modulo the endpoint_id (4 vs 3) and derived
        # cap kind (0x30 KIND_PCI_DEV vs 0x20 KIND_ACPI).
        PCI_ENUMERATOR_OBJECTS+=("${obj}")
    elif [[ "${rel}" == "ls.pdx" ]]; then
        # R57.M4-001 (#1797): /bin/ls user binary. Self-contained _start
        # (inlines its own sys_open / sys_write / sys_close / sys_exit /
        # sys_debug_puts syscalls -- same discipline as child_hello.pdx /
        # true.pdx), plus one linker-resolved `call sys_getdents` into the
        # libc/getdents.pdx wrapper below. Object routes to its own set
        # only; the ls.elf link consumes LS_OBJECTS + LIBC_OBJECTS so the
        # wrapper is NOT dragged into shell.elf / init.elf.
        LS_OBJECTS+=("${obj}")
    elif [[ "${rel}" == libc/* ]]; then
        # R57.M4-001 (#1797): src/user/libc/ -- userspace runtime library
        # for the growing R57 ring-3 surface (ls, cat, mkdir, ...). Each
        # module here is a thin syscall wrapper (or, later, a runtime
        # helper) linked ONLY into the binaries that call it. At R57.M4
        # only ls.elf consumes libc/, so LIBC_OBJECTS is appended to
        # LS_OBJECTS at link time (below); no libc/*.o falls through to
        # the shell.elf / init.elf link. A future round with more ring-3
        # binaries adds per-image consumption without re-linking the
        # frozen ring-2 substrate.
        LIBC_OBJECTS+=("${obj}")
    elif [[ "${rel}" == aml/* ]]; then
        # R30.M1-001..005 (#1049-#1053): the userspace AML tokenizer,
        # arena, opcode table, namespace parser, term parser and
        # resource-template decoder. Everything under src/user/aml/ is
        # globbed in, so a new module joins libaml.a by existing. These are a
        # LIBRARY, not a program — they have no _start and are consumed by
        # the acpi_supervisor process once the userspace ACPI bubble wires
        # up (R30.M2+). They get their own object set and are archived into
        # libaml.a rather than falling through to the catch-all `else`,
        # which would link them into shell.elf and drag a parser the shell
        # has no use for into every boot image.
        #
        # AML lives here and nowhere else: Pillar 3 forbids it in ring 0,
        # and tools/lint-no-kernel-aml.sh fails the push if it drifts into
        # src/kernel/**. See design/acpi/no-aml-in-kernel.md.
        AML_OBJECTS+=("${obj}")
    elif [[ "${rel}" == "syscall_shim.pdx" ]] || [[ "${rel}" == "errno.pdx" ]] || [[ "${rel}" == "string.pdx" ]]; then
        # These are library modules needed by both shell and init
        LIBS_OBJECTS+=("${obj}")
        SHELL_OBJECTS+=("${obj}")
        INIT_OBJECTS+=("${obj}")
    else
        SHELL_OBJECTS+=("${obj}")
    fi
done < <(find "${USER_SRC}" -name '*.pdx' -print0 | sort -z)

if [[ ${#ALL_OBJECTS[@]} -eq 0 ]]; then
    echo "no .pdx files found under ${USER_SRC}" >&2
    exit 1
fi

# Link shell.elf with all non-init objects
echo "[link-user] ld -T link.ld -> shell.elf"
ld -nostdlib --warn-common --fatal-warnings \
    -T "${SHELL_LINK_SCRIPT}" \
    -o "${BUILD_DIR}/shell.elf" \
    "${SHELL_OBJECTS[@]}"

echo "[objcopy-user] shell.elf -> shell.bin"
objcopy -O binary "${BUILD_DIR}/shell.elf" "${BUILD_DIR}/shell.bin"

echo "[verify-user] byte-pattern canary on shell.elf"
"${REPO_ROOT}/tools/verify-syscall-shim.sh" "${BUILD_DIR}/shell.elf"

echo "[verify-user] byte-shape canary on strlen/memcmp/memcpy/memset in shell.elf"
"${REPO_ROOT}/tools/verify-user-string.sh" "${BUILD_DIR}/shell.elf"

echo "[verify-user] symbol + shape canary on _user_errno/errno_get/errno_set/syscall_check in shell.elf"
"${REPO_ROOT}/tools/verify-user-errno.sh" "${BUILD_DIR}/shell.elf"

echo "[verify-user] symbol + call-site canary on puts_new/getline in shell.elf"
"${REPO_ROOT}/tools/verify-user-io.sh" "${BUILD_DIR}/shell.elf"

echo "[verify-libc-test] integration chain — all R17.M1 canaries"
"${REPO_ROOT}/tools/verify-libc-test.sh" "${BUILD_DIR}/shell.elf"

echo "[verify-shell] main loop skeleton for R17.M3-001 — prompt/getline/dispatch/loop"
"${REPO_ROOT}/tools/verify-user-shell.sh" "${BUILD_DIR}/shell.elf"

echo "[verify-tokenizer] in-place tokenization for R17.M3-003 — argv_buf/argc/whitespace/ordering"
"${REPO_ROOT}/tools/verify-user-tokenizer.sh" "${BUILD_DIR}/shell.elf"

echo "[verify-dispatch] builtin dispatch table for R17.M3-004 — echo/exit + runtime table + call rax"
"${REPO_ROOT}/tools/verify-user-dispatch.sh" "${BUILD_DIR}/shell.elf"

echo "[verify-builtins-m4] shell builtins batch for R17.M4 — pwd/help/env + dec_parse + cwd_init"
"${REPO_ROOT}/tools/verify-user-builtins-m4.sh" "${BUILD_DIR}/shell.elf"

echo "[verify-exec-child] fork/execve/wait4 for R17.M3-005 — fork+execve+wait4 + NULL-terminator + exit(127)"
"${REPO_ROOT}/tools/verify-user-exec-child.sh" "${BUILD_DIR}/shell.elf"

echo "[verify-path-resolve] /bin/ prefix path resolution for R17.M3-006 — resolve_path + exec_child wiring"
"${REPO_ROOT}/tools/verify-user-path-resolve.sh" "${BUILD_DIR}/shell.elf"

echo "[ok] ${BUILD_DIR}/shell.elf"
echo "[ok] ${BUILD_DIR}/shell.bin"

# Link init.elf with init objects only
if [[ ${#INIT_OBJECTS[@]} -gt 0 ]]; then
    echo "[link-user] ld -T init.ld -> init.elf"
    ld -nostdlib --warn-common --fatal-warnings \
        -T "${INIT_LINK_SCRIPT}" \
        -o "${BUILD_DIR}/init.elf" \
        "${INIT_OBJECTS[@]}"

    echo "[objcopy-user] init.elf -> init.bin"
    objcopy -O binary "${BUILD_DIR}/init.elf" "${BUILD_DIR}/init.bin"

    echo "[verify-user] byte-pattern canary on sys_open/sys_dup2/sys_close in init.elf"
    "${REPO_ROOT}/tools/verify-user-init.sh" "${BUILD_DIR}/init.elf"

    echo "[ok] ${BUILD_DIR}/init.elf"
    echo "[ok] ${BUILD_DIR}/init.bin"
fi

# Link child_hello.elf with child_hello objects only (R15-M6-009 / #560).
# Self-contained; no libs, no shim — the ELF pulls only child_hello.o.
if [[ ${#CHILD_HELLO_OBJECTS[@]} -gt 0 ]]; then
    echo "[link-user] ld -T child_hello.ld -> child_hello.elf"
    ld -nostdlib --warn-common --fatal-warnings \
        -T "${CHILD_HELLO_LINK_SCRIPT}" \
        -o "${BUILD_DIR}/child_hello.elf" \
        "${CHILD_HELLO_OBJECTS[@]}"

    echo "[objcopy-user] child_hello.elf -> child_hello.bin"
    objcopy -O binary "${BUILD_DIR}/child_hello.elf" "${BUILD_DIR}/child_hello.bin"

    if [[ -x "${REPO_ROOT}/tools/verify-user-child-hello.sh" ]]; then
        echo "[verify-user] byte-pattern canary on sys_write/sys_exit in child_hello.elf"
        "${REPO_ROOT}/tools/verify-user-child-hello.sh" "${BUILD_DIR}/child_hello.elf"
    fi

    echo "[ok] ${BUILD_DIR}/child_hello.elf"
    echo "[ok] ${BUILD_DIR}/child_hello.bin"
fi

# Link true.elf with true objects only (R17.M5 #638).
# Self-contained; no libs, no shim — mirrors child_hello.elf pattern.
if [[ ${#TRUE_OBJECTS[@]} -gt 0 ]]; then
    echo "[link-user] ld -T true.ld -> true.elf"
    ld -nostdlib --warn-common --fatal-warnings \
        -T "${TRUE_LINK_SCRIPT}" \
        -o "${BUILD_DIR}/true.elf" \
        "${TRUE_OBJECTS[@]}"

    echo "[objcopy-user] true.elf -> true.bin"
    objcopy -O binary "${BUILD_DIR}/true.elf" "${BUILD_DIR}/true.bin"

    echo "[ok] ${BUILD_DIR}/true.elf"
    echo "[ok] ${BUILD_DIR}/true.bin"
fi

# Link cat.elf with cat objects only (R57.M4-002 paideia-os #1798).
# Self-contained; no libs, no shim -- mirrors true.elf / child_hello.elf
# pattern. Inlines five SC+ syscalls (read=0, write=1, open=2, close=3,
# exit=60) directly in _start. The 4 KiB read buffer (cat_buf) lives in
# .bss; no .data content, so the R31.M2-1595 (#1595) contiguity rule is
# preserved by cat.ld verbatim.
if [[ ${#CAT_OBJECTS[@]} -gt 0 ]]; then
    echo "[link-user] ld -T cat.ld -> cat.elf"
    ld -nostdlib --warn-common --fatal-warnings \
        -T "${CAT_LINK_SCRIPT}" \
        -o "${BUILD_DIR}/cat.elf" \
        "${CAT_OBJECTS[@]}"

    echo "[objcopy-user] cat.elf -> cat.bin"
    objcopy -O binary "${BUILD_DIR}/cat.elf" "${BUILD_DIR}/cat.bin"

    echo "[ok] ${BUILD_DIR}/cat.elf"
    echo "[ok] ${BUILD_DIR}/cat.bin"
fi

# Link ps.elf with ps objects only (R57.M4-003 / paideia-os #1799).
# Self-contained; no libs, no shim -- mirrors child_hello.elf / true.elf
# pattern. Inlines sys_write / sys_taskinfo / sys_exit at their call
# sites; every emit routes through write_bytes so a future pipe or file
# stdout re-target composes without touching ps itself. See the source
# header of src/user/ps.pdx for the M0 vs. M1 posture (name-field
# rendering flips from synthesised `task<pid>` to record[16..32] when
# task_struct.comm[16] lands at M1).
if [[ ${#PS_OBJECTS[@]} -gt 0 ]]; then
    echo "[link-user] ld -T ps.ld -> ps.elf"
    ld -nostdlib --warn-common --fatal-warnings \
        -T "${PS_LINK_SCRIPT}" \
        -o "${BUILD_DIR}/ps.elf" \
        "${PS_OBJECTS[@]}"

    echo "[objcopy-user] ps.elf -> ps.bin"
    objcopy -O binary "${BUILD_DIR}/ps.elf" "${BUILD_DIR}/ps.bin"

    echo "[ok] ${BUILD_DIR}/ps.elf"
    echo "[ok] ${BUILD_DIR}/ps.bin"
fi

# Link echo_server.elf with echo_server objects only (R20b.M5-001 #1563).
# Self-contained (inlines its four IPC syscalls); mirrors child_hello.elf /
# true.elf pattern. Declares an `_init_caps` sidecar per
# design/loader/init-caps-sidecar.md §2 that a future loader-side symbol
# walker (Phase-2 of #1562) will pick up to auto-seed slot 0 with a
# KIND_IPC_ENDPOINT cap; at R20b.M5 the sidecar exists in .rodata but the
# kernel M5-001 witness drives the roundtrip kernel-side against init's
# user_pml4 rather than spawning echo_server as a userspace task (see the
# `R20b.M5 posture note` in the source header).
if [[ ${#ECHO_SERVER_OBJECTS[@]} -gt 0 ]]; then
    echo "[link-user] ld -T echo_server.ld -> echo_server.elf"
    ld -nostdlib --warn-common --fatal-warnings \
        -T "${ECHO_SERVER_LINK_SCRIPT}" \
        -o "${BUILD_DIR}/echo_server.elf" \
        "${ECHO_SERVER_OBJECTS[@]}"

    echo "[objcopy-user] echo_server.elf -> echo_server.bin"
    objcopy -O binary "${BUILD_DIR}/echo_server.elf" "${BUILD_DIR}/echo_server.bin"

    echo "[ok] ${BUILD_DIR}/echo_server.elf"
    echo "[ok] ${BUILD_DIR}/echo_server.bin"
fi

# Link echo_client.elf with echo_client objects only (R20b.M6-003 #1566).
# Self-contained (inlines its three syscalls — sys_ipc_send/recv + sys_exit);
# mirrors child_hello.elf / true.elf / echo_server.elf pattern. Declares an
# `_init_caps` sidecar with TWO entries: cap_slot 0 → server endpoint
# (endpoint_id=1, WRITE|INVOKE), cap_slot 1 → client's reply endpoint
# (endpoint_id=2, READ|INVOKE). At R20b.M6-003 the sidecar exists in
# .rodata and is shape-verified at build; the kernel M6-003 witness drives
# the dual-endpoint roundtrip kernel-side against init's user_pml4 rather
# than spawning echo_client as a userspace task (see the `R20b.M6 posture
# note` in the source header). Runtime spawn wires up post-R20b.
if [[ ${#ECHO_CLIENT_OBJECTS[@]} -gt 0 ]]; then
    echo "[link-user] ld -T echo_client.ld -> echo_client.elf"
    ld -nostdlib --warn-common --fatal-warnings \
        -T "${ECHO_CLIENT_LINK_SCRIPT}" \
        -o "${BUILD_DIR}/echo_client.elf" \
        "${ECHO_CLIENT_OBJECTS[@]}"

    echo "[objcopy-user] echo_client.elf -> echo_client.bin"
    objcopy -O binary "${BUILD_DIR}/echo_client.elf" "${BUILD_DIR}/echo_client.bin"

    echo "[ok] ${BUILD_DIR}/echo_client.elf"
    echo "[ok] ${BUILD_DIR}/echo_client.bin"
fi

# Link acpi_supervisor.elf with acpi_supervisor objects only (R20-M4-002 #820).
# Self-contained (inlines its two IPC syscalls — sys_ipc_recv + sys_ipc_reply);
# mirrors child_hello.elf / true.elf / echo_server.elf / echo_client.elf
# pattern. Declares an `_init_caps` sidecar with TWO entries: cap_slot 0 →
# RPC endpoint (endpoint_id=3, R_IPC_ALL for dispatch-loop request/reply),
# cap_slot 1 → KIND_ACPI (READ) for future ring-3 access to the ACPI static-
# table byte range. At R20-M4-002 the sidecar exists in .rodata and is
# shape-verified at build; the kernel M4-002 witness drives the four-op RPC
# round-trip kernel-side via the sup_* helpers in
# src/kernel/acpi/supervisor_dispatch.pdx rather than spawning
# acpi_supervisor as a userspace task (see the "Stub-reply posture" note
# in the source header). Runtime spawn wires up post-R20b.
if [[ ${#ACPI_SUPERVISOR_OBJECTS[@]} -gt 0 ]]; then
    echo "[link-user] ld -T acpi_supervisor.ld -> acpi_supervisor.elf"
    ld -nostdlib --warn-common --fatal-warnings \
        -T "${ACPI_SUPERVISOR_LINK_SCRIPT}" \
        -o "${BUILD_DIR}/acpi_supervisor.elf" \
        "${ACPI_SUPERVISOR_OBJECTS[@]}"

    echo "[objcopy-user] acpi_supervisor.elf -> acpi_supervisor.bin"
    objcopy -O binary "${BUILD_DIR}/acpi_supervisor.elf" "${BUILD_DIR}/acpi_supervisor.bin"

    echo "[ok] ${BUILD_DIR}/acpi_supervisor.elf"
    echo "[ok] ${BUILD_DIR}/acpi_supervisor.bin"
fi

# Link pci_enumerator.elf with pci_enumerator objects only (R22-M3-005 #860).
# Self-contained (inlines its two IPC syscalls — sys_ipc_recv + sys_ipc_reply);
# mirrors child_hello.elf / true.elf / echo_server.elf / echo_client.elf /
# acpi_supervisor.elf pattern. Declares an `_init_caps` sidecar with TWO
# entries: cap_slot 0 → RPC endpoint (endpoint_id=4, R_IPC_ALL for
# dispatch-loop request/reply — distinct from echo_server=1, echo_client
# reply_ep=2, acpi_supervisor=3), cap_slot 1 → KIND_PCI_DEV (0x30,
# R_DEV_CONFIG_READ) for future ring-3 access to the R22.M3-published
# device-cap tree. At R22-M3-005 the sidecar exists in .rodata and is
# shape-verified at build; the kernel M3-005 witness drives the three-op
# RPC round-trip kernel-side via the pci_enum_* helpers in
# src/kernel/core/pci/enumerator_dispatch.pdx rather than spawning
# pci_enumerator as a userspace task (see the "Stub-reply posture" note
# in the source header). Runtime spawn wires up post-R22.
if [[ ${#PCI_ENUMERATOR_OBJECTS[@]} -gt 0 ]]; then
    echo "[link-user] ld -T pci_enumerator.ld -> pci_enumerator.elf"
    ld -nostdlib --warn-common --fatal-warnings \
        -T "${PCI_ENUMERATOR_LINK_SCRIPT}" \
        -o "${BUILD_DIR}/pci_enumerator.elf" \
        "${PCI_ENUMERATOR_OBJECTS[@]}"

    echo "[objcopy-user] pci_enumerator.elf -> pci_enumerator.bin"
    objcopy -O binary "${BUILD_DIR}/pci_enumerator.elf" "${BUILD_DIR}/pci_enumerator.bin"

    echo "[ok] ${BUILD_DIR}/pci_enumerator.elf"
    echo "[ok] ${BUILD_DIR}/pci_enumerator.bin"
fi

# Link audio_supervisor.elf with audio_supervisor objects only (R33.M5-001 #1157).
# Self-contained (inlines its two IPC syscalls -- sys_ipc_recv + sys_ipc_reply);
# mirrors acpi_supervisor.elf / pci_enumerator.elf pattern. Declares an
# `_init_caps` sidecar with TWO entries: cap_slot 14 -> RPC endpoint
# (endpoint_id=5, R_IPC_ALL for dispatch-loop request/reply -- distinct from
# echo_server=1, echo_client reply_ep=2, acpi_supervisor=3, pci_enumerator=4),
# cap_slot 15 -> reserved endpoint (endpoint_id=6). At R33.M5-001 the sidecar
# exists in .rodata and is shape-verified at build; the kernel M5-004 crash
# isolation witness spawns audio_supervisor as a userspace task and kills it
# to observe the whole death cascade end-to-end.
if [[ ${#AUDIO_SUPERVISOR_OBJECTS[@]} -gt 0 ]]; then
    echo "[link-user] ld -T audio_supervisor.ld -> audio_supervisor.elf"
    ld -nostdlib --warn-common --fatal-warnings \
        -T "${AUDIO_SUPERVISOR_LINK_SCRIPT}" \
        -o "${BUILD_DIR}/audio_supervisor.elf" \
        "${AUDIO_SUPERVISOR_OBJECTS[@]}"

    echo "[objcopy-user] audio_supervisor.elf -> audio_supervisor.bin"
    objcopy -O binary "${BUILD_DIR}/audio_supervisor.elf" "${BUILD_DIR}/audio_supervisor.bin"

    echo "[ok] ${BUILD_DIR}/audio_supervisor.elf"
    echo "[ok] ${BUILD_DIR}/audio_supervisor.bin"
fi

# Link elevate_broker_daemon.elf with elevate_broker_daemon objects only
# (R48-PREP-005.M2, design/services/svc-elevate-broker-registration.md §4.M2).
# Self-contained (inlines sys_ipc_recv/sys_ipc_reply/sys_debug_puts); mirrors
# echo_server.elf / acpi_supervisor.elf pattern. Declares an `_init_caps`
# sidecar with ONE entry: cap_slot 16 -> RPC endpoint (endpoint_id=16 =
# ELEVATE_BROKER_ENDPOINT_ID, R_IPC_ALL). Unlike acpi_supervisor / pci_
# enumerator / audio_supervisor (still kernel-witness-driven at this round),
# this binary is spawned as a REAL ring-3 task by init's third fork+exec
# cycle (src/user/init.pdx) and embedded into tmpfs at /bin/
# elevate_broker_daemon by the kernel's tmpfs seed block (src/kernel/boot/
# witness/bin_seeds.pdx), mirroring how /bin/sh and /bin/child_hello are
# seeded + execve'd.
if [[ ${#ELEVATE_BROKER_DAEMON_OBJECTS[@]} -gt 0 ]]; then
    echo "[link-user] ld -T elevate_broker_daemon.ld -> elevate_broker_daemon.elf"
    ld -nostdlib --warn-common --fatal-warnings \
        -T "${ELEVATE_BROKER_DAEMON_LINK_SCRIPT}" \
        -o "${BUILD_DIR}/elevate_broker_daemon.elf" \
        "${ELEVATE_BROKER_DAEMON_OBJECTS[@]}"

    echo "[objcopy-user] elevate_broker_daemon.elf -> elevate_broker_daemon.bin"
    objcopy -O binary "${BUILD_DIR}/elevate_broker_daemon.elf" "${BUILD_DIR}/elevate_broker_daemon.bin"

    echo "[ok] ${BUILD_DIR}/elevate_broker_daemon.elf"
    echo "[ok] ${BUILD_DIR}/elevate_broker_daemon.bin"
fi

# Link ls.elf with ls.o + libc/*.o (R57.M4-001 #1797).
# Self-contained inline syscalls in ls.pdx (sys_open / sys_write / sys_close
# / sys_exit / sys_debug_puts) plus one linker-resolved `call sys_getdents`
# into libc/getdents.pdx's SC+ ID 78 wrapper. Mirrors the child_hello.elf /
# true.elf / echo_client.elf single-binary-plus-library shape; the libc/
# split means LS_OBJECTS + LIBC_OBJECTS ship together into ls.elf while
# shell.elf / init.elf remain unchanged. No `_init_caps` sidecar (sys_open
# / sys_getdents are fs-gated but not cap-seeded at this milestone -- ls
# reaches vops_readdir through fd_get -> vnode_slot, not through a per-task
# cap slot, so it does not need a KIND_* seed in the loader table).
if [[ ${#LS_OBJECTS[@]} -gt 0 ]]; then
    echo "[link-user] ld -T ls.ld -> ls.elf"
    ld -nostdlib --warn-common --fatal-warnings \
        -T "${LS_LINK_SCRIPT}" \
        -o "${BUILD_DIR}/ls.elf" \
        "${LS_OBJECTS[@]}" "${LIBC_OBJECTS[@]}"

    echo "[objcopy-user] ls.elf -> ls.bin"
    objcopy -O binary "${BUILD_DIR}/ls.elf" "${BUILD_DIR}/ls.bin"

    echo "[ok] ${BUILD_DIR}/ls.elf"
    echo "[ok] ${BUILD_DIR}/ls.bin"
fi

# R31.M2-1595 (#1595): PT_LOAD extent gate over every image linked above.
#
# Runs here rather than as a per-image step because two of its three rules
# are whole-tree properties: the page budget is a statement about what a
# spawn costs out of one shared 1024-frame pool, and the linker-script lint
# reads src/user/*.ld rather than any single ELF.
#
# This is the check that was missing while seven linker scripts drifted into
# putting a 1 MiB hole inside a single PT_LOAD. Nothing looked, so nothing
# found them; the trigger for the latent form going live is adding one
# initialised mutable to a .pdx under src/user/.
echo "[verify-user] PT_LOAD extent + page budget + linker-script lint (#1595)"
"${REPO_ROOT}/tools/verify-user-image-extent.sh"

# R31.M2-1596/1597 (#1596, #1597): _init_caps sidecar gate over every image
# linked above. Reads each sidecar the way the loader does (symtab + section
# headers) and asserts (a) every kind it names is in KIND_SEEDABLE_TABLE, so
# an image cannot be built that the loader will refuse to seed, and (b) no
# two images name the same absolute cap slot, so the runtime
# LOADER_SEED_SLOT_TAKEN refusal is unreachable from a tree that builds.
echo "[verify-user] _init_caps sidecar kinds + slot disjointness (#1596/#1597)"
"${REPO_ROOT}/tools/verify-user-cap-sidecars.sh"

# Archive the AML modules (R30.M1-001..005, #1049-#1053).
#
# An archive rather than a linked ELF because there is no entry point:
# this is the parser library the acpi_supervisor process will link against
# when the userspace ACPI bubble lands. Publishing it as libaml.a now means
# the modules are built and their cross-module symbol graph is resolved on
# every push, so a signature drift between the lexer, the arena and the
# parser is caught here rather than in R30.M2.
#
# Behavioural verification is tools/verify-aml-parser.sh, which runs the
# byte-fixture corpus against these same objects; it is a separate pre-push
# step so its failures name the fixture rather than the link.
if [[ ${#AML_OBJECTS[@]} -gt 0 ]]; then
    echo "[archive-user] ar rcs -> libaml.a"
    rm -f "${BUILD_DIR}/libaml.a"
    ar rcs "${BUILD_DIR}/libaml.a" "${AML_OBJECTS[@]}"
    echo "[ok] ${BUILD_DIR}/libaml.a"
fi
