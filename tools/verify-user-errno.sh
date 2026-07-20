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

# #613 regression guard: syscall_check's -4095 boundary MUST be built via
# xor+sub (encoder-safe), never via a bare 64-bit immediate mov. bebc377
# used `mov r8, 0xFFFFF000` expecting sign-extension to -4096; paideia-as
# instead emits MOVABS r64, imm64 with the immediate loaded verbatim
# (unsigned), which made the subsequent `cmp rax, r8; jl` branch always
# taken and turned the entire POSIX error-handling path into dead code.
# Re-check both directions on every build:
#   (a) the sub-based boundary construction IS present (49 81 e8 ff 0f =
#       sub r8, 0xfff, i.e. r8 = -4095), and
#   (b) no MOVABS r8, imm64 pattern (49 b8) appears anywhere in the
#       function body.
verify_syscall_check_no_movabs_boundary() {
    local name="syscall_check"
    local dump
    dump=$(objdump -d -M intel "$ELF" 2>/dev/null | awk -v sym="$name" -F '\t' '
        BEGIN { seen = 0; buf = "" }
        $0 ~ "<"sym">:"       { seen = 1; next }
        seen && $0 ~ /^[0-9a-f]+ </ { exit }         # next symbol
        seen && NF >= 2 && $1 ~ /^[[:space:]]+[0-9a-f]+:/ {
            hex_bytes = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", hex_bytes)
            if (hex_bytes != "") buf = buf " " hex_bytes
        }
        END { print buf }
    ' | tr -s ' ' | sed 's/^ //;s/ $//')

    if [[ -z "$dump" ]]; then
        echo "[FAIL] $name: symbol not found in ELF (regression guard skipped)"
        FAIL=1
        return
    fi

    # (a) sub-based boundary construction present: 49 81 e8 ff 0f
    #     (REX.WB 81 /5 id = sub r8, imm32; imm32 = 0x00000fff = 4095).
    if ! echo "$dump" | grep -qE '49 81 e8 ff 0f'; then
        echo "[FAIL] $name: missing encoder-safe boundary construction (49 81 e8 ff 0f = sub r8,0xfff / -4095) — #613 regression?"
        FAIL=1
    else
        echo "[ok]   $name: encoder-safe -4095 boundary (sub r8,0xfff) present"
    fi

    # (b) no MOVABS r8, imm64: opcode byte 49 b8 (REX.WB + B8 = MOVABS r8,imm64).
    if echo "$dump" | grep -qE '49 b8'; then
        echo "[FAIL] $name: contains MOVABS r8, imm64 (49 b8) — #613 sign-extension bug has regressed"
        FAIL=1
    else
        echo "[ok]   $name: no MOVABS r8, imm64 (49 b8) present"
    fi
}

verify_syscall_check_no_movabs_boundary

if (( FAIL == 0 )); then
    echo "R17 USER ERRNO OK"
    exit 0
else
    echo "R17 USER ERRNO FAIL"
    exit 1
fi
