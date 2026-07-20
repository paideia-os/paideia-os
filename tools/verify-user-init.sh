#!/usr/bin/env bash
# Byte-pattern canary for src/user/init.pdx (R17-M2-004 / #619).
# Verifies init contains: sys_open, sys_dup2 (3x), sys_close, sys_fork, sys_execve,
# sys_wait4, sys_exit.
# Also verifies: bin_sh_path, reaped_msg rodata, wait_status .bss, cmp+je branching.
# Exits with "R17 INIT WAIT OK" or "R17 INIT WAIT FAIL".
set -euo pipefail

ELF="${1:-build/user/init.elf}"
FAIL=0

if [[ ! -f "$ELF" ]]; then
    echo "R17 INIT FD FAIL" >&2
    echo "ELF file not found: $ELF" >&2
    exit 1
fi

# Get objdump disassembly
DUMP=$(objdump -d -M intel "$ELF" 2>/dev/null || true)

# Function to extract bytes for a symbol
extract_bytes() {
    local sym="$1"
    # Find lines starting with the symbol, then collect hex bytes until next symbol
    local collecting=0
    local bytes=""
    while IFS= read -r line; do
        # Check if this is the symbol header
        if [[ $line =~ ^[0-9a-f]+\ \<$sym\>: ]]; then
            collecting=1
            continue
        fi
        # Check if we've hit the next symbol (stop collecting)
        if [[ $collecting == 1 ]] && [[ $line =~ ^[0-9a-f]+\ \< ]]; then
            break
        fi
        # If collecting, extract hex bytes
        if [[ $collecting == 1 ]] && [[ $line =~ ^[[:space:]]+[0-9a-f]+: ]]; then
            # Line format: "  400071:	48 c7 c0 00 00 00 00 	mov    rax,0x0"
            # Extract: everything after ':' and before the tab/space that precedes the mnemonic
            local after_colon="${line#*:}"
            # Split on tab (objdump uses tabs)
            IFS=$'\t' read -r hex_part mnemonic <<< "$after_colon"
            # Clean up the hex part
            hex_part=$(echo "$hex_part" | tr -s ' ')
            if [[ -n "$hex_part" ]]; then
                bytes="$bytes $hex_part"
            fi
        fi
    done <<< "$DUMP"
    echo "$bytes" | tr -s ' ' | sed 's/^ //' | sed 's/ $//'
}

# Expected byte patterns for the syscalls
# sys_open: mov rax, 2; syscall; ret
SYS_OPEN_PATTERN="48 c7 c0 02 00 00 00 0f 05 c3"
# sys_dup2: mov rax, 32; syscall; ret
SYS_DUP2_PATTERN="48 c7 c0 20 00 00 00 0f 05 c3"
# sys_close: mov rax, 3; syscall; ret
SYS_CLOSE_PATTERN="48 c7 c0 03 00 00 00 0f 05 c3"
# sys_fork: mov rax, 56; syscall; ret
SYS_FORK_PATTERN="48 c7 c0 38 00 00 00 0f 05 c3"
# sys_execve: mov rax, 59; syscall; ret
SYS_EXECVE_PATTERN="48 c7 c0 3b 00 00 00 0f 05 c3"
# sys_exit: mov rax, 60; syscall; ret
SYS_EXIT_PATTERN="48 c7 c0 3c 00 00 00 0f 05 c3"
# sys_wait4: mov r10, rcx; mov rax, 61; syscall; ret
SYS_WAIT4_PATTERN="49 89 ca 48 c7 c0 3d 00 00 00 0f 05 c3"

# Check sys_open
sys_open_bytes=$(extract_bytes "sys_open") || sys_open_bytes=""
if [[ "$sys_open_bytes" == "$SYS_OPEN_PATTERN" ]]; then
    echo "[ok]   sys_open found"
else
    echo "[FAIL] sys_open not found or incorrect"
    echo "       want: $SYS_OPEN_PATTERN"
    echo "       got : $sys_open_bytes"
    FAIL=1
fi

# Check sys_dup2 (should appear at least 3 times in _start, but we just verify it exists)
sys_dup2_bytes=$(extract_bytes "sys_dup2") || sys_dup2_bytes=""
if [[ "$sys_dup2_bytes" == "$SYS_DUP2_PATTERN" ]]; then
    echo "[ok]   sys_dup2 found"
else
    echo "[FAIL] sys_dup2 not found or incorrect"
    echo "       want: $SYS_DUP2_PATTERN"
    echo "       got : $sys_dup2_bytes"
    FAIL=1
fi

# Check sys_close
sys_close_bytes=$(extract_bytes "sys_close") || sys_close_bytes=""
if [[ "$sys_close_bytes" == "$SYS_CLOSE_PATTERN" ]]; then
    echo "[ok]   sys_close found"
else
    echo "[FAIL] sys_close not found or incorrect"
    echo "       want: $SYS_CLOSE_PATTERN"
    echo "       got : $sys_close_bytes"
    FAIL=1
fi

# Check sys_fork
sys_fork_bytes=$(extract_bytes "sys_fork") || sys_fork_bytes=""
if [[ "$sys_fork_bytes" == "$SYS_FORK_PATTERN" ]]; then
    echo "[ok]   sys_fork found"
else
    echo "[FAIL] sys_fork not found or incorrect"
    echo "       want: $SYS_FORK_PATTERN"
    echo "       got : $sys_fork_bytes"
    FAIL=1
fi

# Check sys_execve
sys_execve_bytes=$(extract_bytes "sys_execve") || sys_execve_bytes=""
if [[ "$sys_execve_bytes" == "$SYS_EXECVE_PATTERN" ]]; then
    echo "[ok]   sys_execve found"
else
    echo "[FAIL] sys_execve not found or incorrect"
    echo "       want: $SYS_EXECVE_PATTERN"
    echo "       got : $sys_execve_bytes"
    FAIL=1
fi

# Check sys_exit (R17-M2-004 #619)
sys_exit_bytes=$(extract_bytes "sys_exit") || sys_exit_bytes=""
if [[ "$sys_exit_bytes" == "$SYS_EXIT_PATTERN" ]]; then
    echo "[ok]   sys_exit found"
else
    echo "[FAIL] sys_exit not found or incorrect"
    echo "       want: $SYS_EXIT_PATTERN"
    echo "       got : $sys_exit_bytes"
    FAIL=1
fi

# Check sys_wait4 (R17-M2-004 #619)
sys_wait4_bytes=$(extract_bytes "sys_wait4") || sys_wait4_bytes=""
if [[ "$sys_wait4_bytes" == "$SYS_WAIT4_PATTERN" ]]; then
    echo "[ok]   sys_wait4 found"
else
    echo "[FAIL] sys_wait4 not found or incorrect"
    echo "       want: $SYS_WAIT4_PATTERN"
    echo "       got : $sys_wait4_bytes"
    FAIL=1
fi

# Count actual calls to sys_open, sys_dup2, sys_close in _start disassembly
# This verifies that init._start calls these functions (not just that they exist in the binary)
_START_DUMP=$(echo "$DUMP" | awk '/^[0-9a-f]+ <_start>:/{flag=1; next} /^[0-9a-f]+ <.*>:/{if(flag) exit} flag')

# Count call sys_open
CALL_OPEN=$(echo "$_START_DUMP" | grep -c "call.*sys_open" || true)
if [[ $CALL_OPEN -ge 1 ]]; then
    echo "[ok]   call sys_open found (count: $CALL_OPEN)"
else
    echo "[FAIL] call sys_open not found in _start"
    FAIL=1
fi

# Count call sys_dup2 (should be 3)
CALL_DUP2=$(echo "$_START_DUMP" | grep -c "call.*sys_dup2" || true)
if [[ $CALL_DUP2 -eq 3 ]]; then
    echo "[ok]   call sys_dup2 found (count: $CALL_DUP2)"
else
    echo "[FAIL] call sys_dup2 found (count: $CALL_DUP2), expected 3"
    FAIL=1
fi

# Count call sys_close
CALL_CLOSE=$(echo "$_START_DUMP" | grep -c "call.*sys_close" || true)
if [[ $CALL_CLOSE -ge 1 ]]; then
    echo "[ok]   call sys_close found (count: $CALL_CLOSE)"
else
    echo "[FAIL] call sys_close not found in _start"
    FAIL=1
fi

# Count call sys_fork
CALL_FORK=$(echo "$_START_DUMP" | grep -c "call.*sys_fork" || true)
if [[ $CALL_FORK -ge 1 ]]; then
    echo "[ok]   call sys_fork found (count: $CALL_FORK)"
else
    echo "[FAIL] call sys_fork not found in _start"
    FAIL=1
fi

# Count call sys_execve
CALL_EXECVE=$(echo "$_START_DUMP" | grep -c "call.*sys_execve" || true)
if [[ $CALL_EXECVE -ge 1 ]]; then
    echo "[ok]   call sys_execve found (count: $CALL_EXECVE)"
else
    echo "[FAIL] call sys_execve not found in _start"
    FAIL=1
fi

# Count call sys_wait4 (R17-M2-004 #619)
CALL_WAIT4=$(echo "$_START_DUMP" | grep -c "call.*sys_wait4" || true)
if [[ $CALL_WAIT4 -ge 1 ]]; then
    echo "[ok]   call sys_wait4 found (count: $CALL_WAIT4)"
else
    echo "[FAIL] call sys_wait4 not found in _start"
    FAIL=1
fi

# Count call sys_exit (R17-M2-004 #619)
CALL_EXIT=$(echo "$_START_DUMP" | grep -c "call.*sys_exit" || true)
if [[ $CALL_EXIT -ge 1 ]]; then
    echo "[ok]   call sys_exit found (count: $CALL_EXIT)"
else
    echo "[FAIL] call sys_exit not found in _start"
    FAIL=1
fi

# Verify bin_sh_path symbol exists in rodata
BIN_SH_PATH=$(echo "$DUMP" | grep -c "bin_sh_path" || true)
if [[ $BIN_SH_PATH -ge 1 ]]; then
    echo "[ok]   bin_sh_path symbol found in rodata"
else
    echo "[FAIL] bin_sh_path symbol not found"
    FAIL=1
fi

# Verify reaped_msg symbol exists in rodata (R17-M2-004 #619)
REAPED_MSG=$(echo "$DUMP" | grep -c "reaped_msg" || true)
if [[ $REAPED_MSG -ge 1 ]]; then
    echo "[ok]   reaped_msg symbol found in rodata"
else
    echo "[FAIL] reaped_msg symbol not found"
    FAIL=1
fi

# Verify wait_status symbol exists AND is actually placed in .bss (R17-M2-004 #619;
# fix #619b — a bare grep for "wait_status" in the disassembly dump would also
# match a .rodata placement and print a false-positive "[ok] ... in .bss", which
# is exactly the bug that let the original R+X placement slip through review.
# We cross-check the ELF symbol table (objdump -t) for the section field so a
# regression back to .rodata/.data is caught here instead of at #GP fault time.
WAIT_STATUS_SYMLINE=$(objdump -t "$ELF" 2>/dev/null | awk '$NF == "wait_status" { print }')
if [[ -z "$WAIT_STATUS_SYMLINE" ]]; then
    echo "[FAIL] wait_status symbol not found"
    FAIL=1
else
    # Symtab line shape: <addr> <flags> <type> <section> <size> <name>
    WAIT_STATUS_SECTION=$(echo "$WAIT_STATUS_SYMLINE" | awk '{print $(NF-2)}')
    if [[ "$WAIT_STATUS_SECTION" == ".bss" ]]; then
        echo "[ok]   wait_status symbol found in .bss (writable, per readelf -SW)"
    else
        echo "[FAIL] wait_status symbol found but placed in '${WAIT_STATUS_SECTION}', not .bss"
        echo "       (a non-.bss placement means the kernel's sys_wait4 write into"
        echo "        wait_status would fault #GP against a non-writable segment)"
        FAIL=1
    fi
fi

# Verify cmp + je branching pattern (fork child detection)
# Check for both cmp and je instructions (they may be on separate lines)
CMP_COUNT=$(echo "$_START_DUMP" | grep -c "cmp" || true)
JE_COUNT=$(echo "$_START_DUMP" | grep -c "je" || true)
if [[ $CMP_COUNT -ge 1 && $JE_COUNT -ge 1 ]]; then
    echo "[ok]   cmp+je branching found (fork result check)"
else
    echo "[FAIL] cmp+je branching not found in _start (cmp: $CMP_COUNT, je: $JE_COUNT)"
    FAIL=1
fi

if [[ $FAIL -eq 0 ]]; then
    echo "R17 INIT WAIT OK"
    exit 0
else
    echo "R17 INIT WAIT FAIL"
    exit 1
fi
