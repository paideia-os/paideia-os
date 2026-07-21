#!/usr/bin/env bash
# Build-time structural canary for src/user/tokenizer.pdx (R17-M3-003 / #623).
# Verifies shell tokenizer with:
# - argv_buf .bss symbol (size 0x80 = 128 bytes)
# - argc .bss symbol (size 0x8)
# - tokenize function exists and contains required cmp instructions
# - Whitespace comparisons: 0x20 (space), 0x09 (tab), 0x0A (newline)
# - In-place NUL store via mov BYTE PTR or mov with register
# - Indexed argv_buf store with *8 scaling
# - _start calls in order: shell_read_line, tokenize, dispatch_line
# - paideia-as #1248 hygiene checks
# Exits with "R17 TOKENIZER OK" or "R17 TOKENIZER FAIL".
set -euo pipefail

ELF="${1:-build/user/shell.elf}"

if [[ ! -f "$ELF" ]]; then
    echo "R17 TOKENIZER FAIL" >&2
    echo "ELF file not found: $ELF" >&2
    exit 1
fi

FAIL=0

# Get objdump disassembly
DUMP=$(objdump -d -M intel "$ELF" 2>/dev/null || true)

# Extract _start disassembly
_START_DUMP=$(echo "$DUMP" | awk '/^[0-9a-f]+ <_start>:/{flag=1; next} /^[0-9a-f]+ <.*>:/{if(flag) exit} flag')

# Extract tokenize disassembly
TOKENIZE_DUMP=$(echo "$DUMP" | awk '/^[0-9a-f]+ <tokenize>:/{flag=1; next} /^[0-9a-f]+ <.*>:/{if(flag) exit} flag')

# 1. Check for argv_buf .bss symbol, size 0x80
ARGV_BUF_SYMLINE=$(objdump -t "$ELF" 2>/dev/null | awk '$NF == "argv_buf" { print }')
if [[ -z "$ARGV_BUF_SYMLINE" ]]; then
    echo "[FAIL] argv_buf symbol not found"
    FAIL=1
else
    ARGV_BUF_SECTION=$(echo "$ARGV_BUF_SYMLINE" | awk '{print $(NF-2)}')
    ARGV_BUF_SIZE=$(echo "$ARGV_BUF_SYMLINE" | awk '{print $(NF-1)}')
    if [[ "$ARGV_BUF_SECTION" == ".bss" ]]; then
        if [[ "$ARGV_BUF_SIZE" == "0000000000000080" ]] || [[ "$ARGV_BUF_SIZE" == "00000080" ]]; then
            echo "[ok]   argv_buf symbol found in .bss, size 0x80 (128 bytes)"
        else
            echo "[FAIL] argv_buf found in .bss but size is $ARGV_BUF_SIZE (expected 0x80)"
            FAIL=1
        fi
    else
        echo "[FAIL] argv_buf symbol found but placed in '${ARGV_BUF_SECTION}', not .bss"
        FAIL=1
    fi
fi

# 2. Check for argc .bss symbol, size 0x8
ARGC_SYMLINE=$(objdump -t "$ELF" 2>/dev/null | awk '$NF == "argc" { print }')
if [[ -z "$ARGC_SYMLINE" ]]; then
    echo "[FAIL] argc symbol not found"
    FAIL=1
else
    ARGC_SECTION=$(echo "$ARGC_SYMLINE" | awk '{print $(NF-2)}')
    ARGC_SIZE=$(echo "$ARGC_SYMLINE" | awk '{print $(NF-1)}')
    if [[ "$ARGC_SECTION" == ".bss" ]]; then
        if [[ "$ARGC_SIZE" == "0000000000000008" ]] || [[ "$ARGC_SIZE" == "00000008" ]]; then
            echo "[ok]   argc symbol found in .bss, size 0x8 (8 bytes)"
        else
            echo "[FAIL] argc found in .bss but size is $ARGC_SIZE (expected 0x8)"
            FAIL=1
        fi
    else
        echo "[FAIL] argc symbol found but placed in '${ARGC_SECTION}', not .bss"
        FAIL=1
    fi
fi

# 3. Check for tokenize function exists
TOKENIZE_FUNC=$(echo "$DUMP" | grep -c "<tokenize>" || true)
if [[ $TOKENIZE_FUNC -ge 1 ]]; then
    echo "[ok]   tokenize function found"
else
    echo "[FAIL] tokenize function not found"
    FAIL=1
fi

# 4. Check for cmp against 0x20 (space) in tokenize
CMP_0x20=$(echo "$TOKENIZE_DUMP" | grep -c "cmp.*0x20" || true)
if [[ $CMP_0x20 -ge 1 ]]; then
    echo "[ok]   cmp against 0x20 (space) found in tokenize"
else
    echo "[FAIL] cmp against 0x20 (space) not found in tokenize"
    FAIL=1
fi

# 5. Check for cmp against 0x9 (tab) in tokenize
#    (objdump may print 0x9 or 0x09; check for both)
CMP_0x09=$(echo "$TOKENIZE_DUMP" | grep -Ec "cmp.*0x0*9\b" || true)
if [[ $CMP_0x09 -ge 1 ]]; then
    echo "[ok]   cmp against 0x9 (tab) found in tokenize"
else
    echo "[FAIL] cmp against 0x9 (tab) not found in tokenize"
    FAIL=1
fi

# 6. Check for cmp against 0xa (newline) in tokenize
CMP_0x0A=$(echo "$TOKENIZE_DUMP" | grep -c "cmp.*0xa" || true)
if [[ $CMP_0x0A -ge 1 ]]; then
    echo "[ok]   cmp against 0xa (newline) found in tokenize"
else
    echo "[FAIL] cmp against 0xa (newline) not found in tokenize"
    FAIL=1
fi

# 7. Check for in-place NUL store: match "mov BYTE PTR ..., 0x0" or "mov [...], al/bl/cl/dl"
NUL_STORE=$(echo "$TOKENIZE_DUMP" | grep -E "mov.*BYTE PTR.*,0x0|mov.*BYTE PTR.*\[[^]]+\],[a-d]l|mov.*\[[^]]+\],[a-d]l" | head -1 || true)
if [[ -n "$NUL_STORE" ]]; then
    echo "[ok]   in-place NUL store found (null-terminate pattern)"
else
    echo "[FAIL] in-place NUL store not found (expected mov BYTE PTR [...], 0x0 or mov [...], [a-d]l)"
    FAIL=1
fi

# 8. Check for indexed argv_buf store with *8 scaling
#    Pattern: mov [reg + reg*8], ... or similar
INDEXED_STORE=$(echo "$TOKENIZE_DUMP" | grep -E "\[.*\*8\]" | head -1)
if [[ -n "$INDEXED_STORE" ]]; then
    echo "[ok]   indexed argv_buf store with *8 scaling found"
else
    echo "[FAIL] indexed store with *8 scaling not found (expected mov [argv + argc*8], ptr)"
    FAIL=1
fi

# 9. Check _start calls in order: shell_read_line, tokenize, dispatch_line
if [[ -n "$_START_DUMP" ]]; then
    # Extract line numbers of calls
    READLINE_LINE=$(echo "$_START_DUMP" | grep -n "call.*shell_read_line" | head -1 | cut -d: -f1)
    TOKENIZE_LINE=$(echo "$_START_DUMP" | grep -n "call.*tokenize" | head -1 | cut -d: -f1)
    DISPATCH_LINE=$(echo "$_START_DUMP" | grep -n "call.*dispatch_line" | head -1 | cut -d: -f1)

    if [[ -z "$READLINE_LINE" ]]; then
        echo "[FAIL] call shell_read_line not found in _start"
        FAIL=1
    elif [[ -z "$TOKENIZE_LINE" ]]; then
        echo "[FAIL] call tokenize not found in _start"
        FAIL=1
    elif [[ -z "$DISPATCH_LINE" ]]; then
        echo "[FAIL] call dispatch_line not found in _start"
        FAIL=1
    elif [[ "$READLINE_LINE" -lt "$TOKENIZE_LINE" ]] && [[ "$TOKENIZE_LINE" -lt "$DISPATCH_LINE" ]]; then
        echo "[ok]   _start calls in correct order: shell_read_line → tokenize → dispatch_line"
    else
        echo "[FAIL] _start calls not in correct order"
        echo "       shell_read_line: line $READLINE_LINE"
        echo "       tokenize: line $TOKENIZE_LINE"
        echo "       dispatch_line: line $DISPATCH_LINE"
        FAIL=1
    fi
else
    echo "[FAIL] _start function not found for call order check"
    FAIL=1
fi

# 10. Check #1248 hygiene: all whitespace cmps must be full-register (cmp rax, imm),
#     not byte-narrow (cmp al, imm8) which triggers paideia-as #1248 wrong REX.W emission.
#     Also require an xor rax,rax presence in the body (zero-extend pattern documentation).
if [[ -n "$TOKENIZE_DUMP" ]]; then
    BAD_CMP=$(echo "$TOKENIZE_DUMP" | grep -Ec "cmp[[:space:]]+al," || true)
    HAS_XOR_RAX=$(echo "$TOKENIZE_DUMP" | grep -Ec "xor[[:space:]]+rax,rax" || true)
    if [[ "$BAD_CMP" -gt 0 ]]; then
        echo "[FAIL] paideia-as #1248 risk: $BAD_CMP byte-narrow 'cmp al,imm8' instruction(s) present"
        echo "       Use 'xor rax,rax; mov_b rax,[...]; cmp rax,imm' pattern instead"
        FAIL=1
    elif [[ "$HAS_XOR_RAX" -lt 1 ]]; then
        echo "[FAIL] paideia-as #1248 hygiene: no 'xor rax,rax' zero-extend prelude in tokenize"
        FAIL=1
    else
        echo "[ok]   paideia-as #1248 hygiene: full-register cmp only + xor rax,rax zero-extend present"
    fi
fi

if [[ $FAIL -eq 0 ]]; then
    echo "R17 TOKENIZER OK"
    exit 0
else
    echo "R17 TOKENIZER FAIL"
    exit 1
fi
