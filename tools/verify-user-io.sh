#!/usr/bin/env bash
# Build-time shape canary for src/user/io.pdx (R17-M1-005 / #614).
# Verifies puts_new and getline exist, contain appropriate call signatures,
# and do NOT contain the syscall opcode directly (must delegate to sys_read/sys_write).
# Exits with "R17 USER IO OK" or "R17 USER IO FAIL".
set -euo pipefail

ELF="${1:-build/user/shell.elf}"

if [[ ! -f "$ELF" ]]; then
    echo "R17 USER IO FAIL" >&2
    echo "ELF file not found: $ELF" >&2
    exit 1
fi

FAIL=0

# Verify a function: name, min_bytes, max_bytes, required_callees.
# required_callees: space-separated list of symbol names that must appear in call sites.
verify_fn_with_calls() {
    local name="$1" lo="$2" hi="$3" req_calls_str="$4"

    # Extract the function's disassembly (bytes column only).
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

    # Check for required call instructions and symbol references.
    # Disassemble again to get the full instruction stream.
    local asm_dump
    asm_dump=$(objdump -d -M intel "$ELF" 2>/dev/null | awk -v sym="$name" '
        BEGIN { seen = 0 }
        $0 ~ "<"sym">:"       { seen = 1; next }
        seen && $0 ~ /^[0-9a-f]+ </ { exit }
        seen { print }
    ')

    # Must contain at least one "call" instruction.
    if ! echo "$asm_dump" | grep -q 'call'; then
        echo "[FAIL] $name: missing call instruction"
        FAIL=1
    fi

    # Verify that the required callees appear.
    for callee in $req_calls_str; do
        if ! echo "$asm_dump" | grep -q "<$callee>"; then
            echo "[FAIL] $name: missing call to $callee"
            FAIL=1
        fi
    done

    # Must NOT contain syscall directly (0f 05).
    if echo "$dump" | grep -q '0f 05'; then
        echo "[FAIL] $name: contains syscall opcode 0f 05 — must delegate to sys_read/sys_write"
        FAIL=1
    fi

    # Must end with ret (c3).
    if ! echo "$dump" | grep -q 'c3'; then
        echo "[FAIL] $name: missing ret (c3)"
        FAIL=1
    fi

    if (( FAIL == 0 )); then
        echo "[ok]   $name: $nbytes bytes; calls $req_calls_str; no direct syscall"
    fi
}

# Verify puts_new(s) -> u64: calls strlen and sys_write.
# Budget: mov r9,rdi (3) + call strlen (5) + mov rdi,1 (3) + mov rsi,r9 (3) + mov rdx,rax (3) + call sys_write (5) + ret (1) = ~23 bytes, allow up to 40.
verify_fn_with_calls puts_new 20 40 "strlen sys_write"

# Verify getline(buf, sz) -> u64: calls sys_read.
# Budget: mov rdx,rsi (3) + mov rsi,rdi (3) + mov rdi,0 (3) + call sys_read (5) + ret (1) = ~15 bytes, allow up to 35.
verify_fn_with_calls getline 12 35 "sys_read"

if (( FAIL == 0 )); then
    echo "R17 USER IO OK"
    exit 0
else
    echo "R17 USER IO FAIL"
    exit 1
fi
