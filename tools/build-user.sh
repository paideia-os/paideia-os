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

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Build all .pdx files to objects
ALL_OBJECTS=()
SHELL_OBJECTS=()
INIT_OBJECTS=()
CHILD_HELLO_OBJECTS=()
LIBS_OBJECTS=()

while IFS= read -r -d '' pdx; do
    rel="${pdx#"${USER_SRC}"/}"
    obj="${BUILD_DIR}/${rel%.pdx}.o"
    mkdir -p "$(dirname "${obj}")"
    echo "[build-user] paideia-as ${rel} -> ${obj#"${BUILD_DIR}"/}"
    "${PAIDEIA_AS}" build --emit elf64 "${pdx}" -o "${obj}"
    ALL_OBJECTS+=("${obj}")

    # Separate init / child_hello from shell objects; shared libraries go to both
    # shell and init but NOT to child_hello (child_hello is self-contained and
    # inlines its two syscalls to avoid pulling the shim's other 10 wrappers).
    if [[ "${rel}" == "init.pdx" ]]; then
        INIT_OBJECTS+=("${obj}")
    elif [[ "${rel}" == "child_hello.pdx" ]]; then
        CHILD_HELLO_OBJECTS+=("${obj}")
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
