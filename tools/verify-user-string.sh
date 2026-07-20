#!/usr/bin/env bash
# Build-time shape canary for src/user/string.pdx (R17-M1-002 / #611 + R17-M1-003 / #612).
# Verifies strlen, memcmp, memcpy, memset exist, sit within size budgets, contain
# appropriate opcode signatures, and do NOT contain the syscall opcode.
# Exits with "R17 USER MEM OK" or "R17 USER MEM FAIL".
set -euo pipefail

ELF="${1:-build/user/shell.elf}"

if [[ ! -f "$ELF" ]]; then
    echo "R17 USER STRING FAIL" >&2
    echo "ELF file not found: $ELF" >&2
    exit 1
fi

FAIL=0

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

    # Signature: must contain a byte load (8a = mov r8,r/m8; or 0f b6 = movzx),
    # a conditional branch (74 or 75 or 0f 84/85 for longer branches),
    # an unconditional jmp (eb or e9 for longer jumps), a ret (c3), and NO syscall (0f 05).
    if ! echo "$dump" | grep -qE '(8a|0f b6)'; then
        echo "[FAIL] $name: missing byte-load opcode (8a or 0f b6)"
        FAIL=1
    fi
    if ! echo "$dump" | grep -qE '(74|75|0f 84|0f 85)'; then
        echo "[FAIL] $name: missing conditional branch (74/75 short or 0f 84/85 long)"
        FAIL=1
    fi
    if ! echo "$dump" | grep -qE '(eb|e9)'; then
        echo "[FAIL] $name: missing unconditional jmp (eb short or e9 long)"
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

# Verify a rep-prefix function: name, min_bytes, max_bytes, rep_opcode.
# rep_opcode: "a4" for rep_movsb, "aa" for rep_stosb.
verify_rep_fn() {
    local name="$1" lo="$2" hi="$3" rep_op="$4"

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

    # rep-signature: must contain "fc" (cld), "f3 <rep_op>" (rep prefix +
    # movsb/stosb), and "c3" (ret). Must NOT contain 0f 05 (syscall).
    if ! echo "$dump" | grep -q "fc"; then
        echo "[FAIL] $name: missing cld (fc)"
        FAIL=1
    fi
    if ! echo "$dump" | grep -q "f3 ${rep_op}"; then
        echo "[FAIL] $name: missing rep prefix f3 ${rep_op}"
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
        echo "[ok]   $name: $nbytes bytes; rep signature OK"
    fi
}

# Existing byte-loop verifications (unchanged):
verify_fn strlen 20 40
verify_fn memcmp 40 70

# New rep-prefix verifications:
verify_rep_fn memcpy 10 30 a4
verify_rep_fn memset 12 30 aa

if (( FAIL == 0 )); then
    echo "R17 USER MEM OK"
    exit 0
else
    echo "R17 USER MEM FAIL"
    exit 1
fi
