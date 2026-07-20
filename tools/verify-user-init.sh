#!/usr/bin/env bash
# Byte-pattern canary for src/user/init.pdx (R17-M2-002 / #617).
# Verifies init contains calls to sys_open, sys_dup2 (3x), and sys_close.
# Exits with "R17 INIT FD OK" or "R17 INIT FD FAIL".
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

if [[ $FAIL -eq 0 ]]; then
    echo "R17 INIT FD OK"
    exit 0
else
    echo "R17 INIT FD FAIL"
    exit 1
fi
