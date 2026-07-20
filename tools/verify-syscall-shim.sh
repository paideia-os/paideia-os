#!/usr/bin/env bash
# Byte-pattern canary for src/user/syscall_shim.pdx (R17-M1-001 / #610).
# Verifies each wrapper compiles to the exact SysV→SYSCALL trampoline.
# Exits with "R17 SYSCALL SHIM OK" or "R17 SYSCALL SHIM FAIL".
set -euo pipefail

ELF="${1:-build/user/shell.elf}"
FAIL=0
MATCHED=0

if [[ ! -f "$ELF" ]]; then
    echo "R17 SYSCALL SHIM FAIL" >&2
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

# Expected patterns for each wrapper
declare -A EXPECTED=(
    [sys_read]="48 c7 c0 00 00 00 00 0f 05 c3"
    [sys_write]="48 c7 c0 01 00 00 00 0f 05 c3"
    [sys_open]="48 c7 c0 02 00 00 00 0f 05 c3"
    [sys_close]="48 c7 c0 03 00 00 00 0f 05 c3"
    [sys_cap_invoke]="48 c7 c0 04 00 00 00 0f 05 c3"
    [sys_debug_puts]="48 c7 c0 0c 00 00 00 0f 05 c3"
    [sys_dup2]="48 c7 c0 20 00 00 00 0f 05 c3"
    [sys_getpid]="48 c7 c0 27 00 00 00 0f 05 c3"
    [sys_fork]="48 c7 c0 38 00 00 00 0f 05 c3"
    [sys_execve]="48 c7 c0 3b 00 00 00 0f 05 c3"
    [sys_exit]="48 c7 c0 3c 00 00 00 0f 05 c3"
    [sys_wait4]="49 89 ca 48 c7 c0 3d 00 00 00 0f 05 c3"
    [sys_exit_thread]="48 c7 c0 3c 00 00 00 0f 05 c3"
)

# Check each wrapper in order
for name in sys_read sys_write sys_open sys_close sys_cap_invoke sys_debug_puts \
            sys_dup2 sys_getpid sys_fork sys_execve sys_exit sys_wait4 sys_exit_thread; do
    got=$(extract_bytes "$name") || got=""
    exp="${EXPECTED[$name]}"

    if [[ "$got" == "$exp" ]]; then
        echo "[ok]   $name: $exp"
        MATCHED=$((MATCHED + 1))
    else
        echo "[FAIL] $name"
        echo "         want: $exp"
        echo "         got : $got"
        FAIL=1
    fi
done

# Sanity check: ensure we checked all wrappers
if [[ $MATCHED -eq 0 ]]; then
    echo "R17 SYSCALL SHIM FAIL" >&2
    echo "No wrappers extracted from ELF" >&2
    exit 1
fi

if [[ $FAIL -eq 0 ]]; then
    echo "R17 SYSCALL SHIM OK"
    exit 0
else
    echo "R17 SYSCALL SHIM FAIL"
    exit 1
fi
