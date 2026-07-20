#!/usr/bin/env bash
# Build-time canary for src/user/errno.pdx (R17-M1-004 / #613).
# Verifies _user_errno symbol exists, errno_get/errno_set/syscall_check functions
# exist, sit within size budgets, contain appropriate opcode signatures (lea, mov [mem]),
# and do NOT contain the syscall opcode (0f 05).
# Exits with "R17 USER ERRNO OK" or "R17 USER ERRNO FAIL".
set -euo pipefail

ELF="${1:-build/user/shell.elf}"

if [[ ! -f "$ELF" ]]; then
    echo "R17 USER ERRNO FAIL" >&2
    echo "ELF file not found: $ELF" >&2
    exit 1
fi

FAIL=0

# Verify a static symbol exists (data object).
verify_symbol() {
    local name="$1"

    if ! nm "$ELF" 2>/dev/null | grep -q "\b${name}\b"; then
        echo "[FAIL] $name: symbol not found in ELF"
        FAIL=1
        return
    fi
    echo "[ok]   $name: symbol exists"
}

# Verify a function: name, min_bytes, max_bytes.
verify_fn() {
    local name="$1" lo="$2" hi="$3"

    # Extract the function's disassembly (bytes column only).
    local dump
    dump=$(objdump -d -M intel "$ELF" 2>/dev/null | awk -v sym="$name" -F '\t' '
        BEGIN { seen = 0; buf = "" }
        $0 ~ "<"sym">:"       { seen = 1; next }
        seen && $0 ~ /^[0-9a-f]+ </ { exit }         # next symbol
        seen && NF >= 2 && $1 ~ /^[[:space:]]+[0-9a-f]+:/ {
            # Line: "  400071:\t48 c7 c0 00 00 00 00\tmov rax,0x0"
            # $1 = "  400071:", $2 = "48 c7 c0 00 00 00 00", $3 = "mov rax,0x0"
            hex_bytes = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", hex_bytes)
            if (hex_bytes != "") buf = buf " " hex_bytes
        }
        END { print buf }
    ' | tr -s ' ' | sed 's/^ //;s/ $//')

    if [[ -z "$dump" ]]; then
        echo "[FAIL] $name: symbol not found in ELF"
        FAIL=1
        return
    fi

    # Count bytes (each byte is 2 hex chars + separator).
    local nbytes
    nbytes=$(echo "$dump" | tr ' ' '\n' | grep -c '^[0-9a-f][0-9a-f]$' || true)

    if (( nbytes < lo || nbytes > hi )); then
        echo "[FAIL] $name: $nbytes bytes outside budget [$lo, $hi]"
        FAIL=1
        return
    fi

    # Signature: must contain lea (8d) and mov from/to memory ([mem] addressing),
    # a ret (c3), and NO syscall (0f 05).
    # LEA = 8d (e.g., 48 8d = lea r64, [rip+disp]).
    # MOV from/to memory: 48 8b (mov r64, [mem]), 48 89 (mov [mem], r64), etc.
    if ! echo "$dump" | grep -qE '(8d|48 8d)'; then
        echo "[FAIL] $name: missing lea opcode (8d)"
        FAIL=1
    fi
    if ! echo "$dump" | grep -qE '(48 8b|48 89)'; then
        echo "[FAIL] $name: missing mov [mem] opcode (48 8b or 48 89)"
        FAIL=1
    fi
    if ! echo "$dump" | grep -q 'c3'; then
        echo "[FAIL] $name: missing ret (c3)"
        FAIL=1
    fi
    if echo "$dump" | grep -q '0f 05'; then
        echo "[FAIL] $name: contains syscall opcode 0f 05 — must be pure userland"
        FAIL=1
    fi

    if (( FAIL == 0 )); then
        echo "[ok]   $name: $nbytes bytes; signature OK"
    fi
}

# Verify _user_errno symbol (static data, u64 = 8 bytes).
verify_symbol _user_errno

# Verify errno_get: small function (lea + mov + ret = ~10 bytes).
verify_fn errno_get 8 20

# Verify errno_set: slightly larger (lea + mov store + xor + ret = ~16 bytes).
verify_fn errno_set 12 28

# Verify syscall_check: largest; implements if/else logic with branches.
# Expected: mov + cmp + jge + mov + neg + lea + mov + jmp + lea + mov + ret.
# Rough byte count: ~80-120 bytes depending on encoding and branch distances.
verify_fn syscall_check 50 150

if (( FAIL == 0 )); then
    echo "R17 USER ERRNO OK"
    exit 0
else
    echo "R17 USER ERRNO FAIL"
    exit 1
fi
