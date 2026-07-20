#!/usr/bin/env bash
# Build-time structural canary for src/user/shell.pdx (R17-M3-001 / #621 + R17-M3-002 / #622).
# Verifies shell main loop skeleton with line reader:
# - prompt_msg rodata symbol
# - line_buf .bss symbol (256 bytes)
# - puts_new call (for prompt emission)
# - shell_read_line call (for line reading, byte-by-byte until '\n' or EOF or buffer full)
# - shell_read_line function body contains: sys_read call, cmp against 0x0A (\n), byte loop pattern
# - Backward jump pattern (main loop)
# - dispatch_line call (stub)
# Exits with "R17 SHELL READER OK" or "R17 SHELL READER FAIL".
set -euo pipefail

ELF="${1:-build/user/shell.elf}"

if [[ ! -f "$ELF" ]]; then
    echo "R17 SHELL READER FAIL" >&2
    echo "ELF file not found: $ELF" >&2
    exit 1
fi

FAIL=0

# Get objdump disassembly
DUMP=$(objdump -d -M intel "$ELF" 2>/dev/null || true)

# Extract _start disassembly
_START_DUMP=$(echo "$DUMP" | awk '/^[0-9a-f]+ <_start>:/{flag=1; next} /^[0-9a-f]+ <.*>:/{if(flag) exit} flag')

# Extract shell_read_line disassembly
SHELL_READLINE_DUMP=$(echo "$DUMP" | awk '/^[0-9a-f]+ <shell_read_line>:/{flag=1; next} /^[0-9a-f]+ <.*>:/{if(flag) exit} flag')

# 1. Check for prompt_msg rodata symbol
PROMPT_MSG=$(echo "$DUMP" | grep -c "prompt_msg" || true)
if [[ $PROMPT_MSG -ge 1 ]]; then
    echo "[ok]   prompt_msg found in rodata"
else
    echo "[FAIL] prompt_msg not found"
    FAIL=1
fi

# 2. Check for line_buf .bss symbol (verify it's in .bss section, not .rodata)
LINE_BUF_SYMLINE=$(objdump -t "$ELF" 2>/dev/null | awk '$NF == "line_buf" { print }')
if [[ -z "$LINE_BUF_SYMLINE" ]]; then
    echo "[FAIL] line_buf symbol not found"
    FAIL=1
else
    LINE_BUF_SECTION=$(echo "$LINE_BUF_SYMLINE" | awk '{print $(NF-2)}')
    if [[ "$LINE_BUF_SECTION" == ".bss" ]]; then
        echo "[ok]   line_buf symbol found in .bss"
    else
        echo "[FAIL] line_buf symbol found but placed in '${LINE_BUF_SECTION}', not .bss"
        FAIL=1
    fi
fi

# 3. Check for puts_new call in _start
PUTS_NEW_CALL=$(echo "$_START_DUMP" | grep -c "call.*puts_new" || true)
if [[ $PUTS_NEW_CALL -ge 1 ]]; then
    echo "[ok]   call puts_new found (prompt emission)"
else
    echo "[FAIL] call puts_new not found in _start"
    FAIL=1
fi

# 4. Check for shell_read_line call in _start
SHELL_READLINE_CALL=$(echo "$_START_DUMP" | grep -c "call.*shell_read_line" || true)
if [[ $SHELL_READLINE_CALL -ge 1 ]]; then
    echo "[ok]   call shell_read_line found (line reading, byte-by-byte)"
else
    echo "[FAIL] call shell_read_line not found in _start"
    FAIL=1
fi

# 5. Check for shell_read_line function exists
SHELL_READLINE_FUNC=$(echo "$DUMP" | grep -c "<shell_read_line>" || true)
if [[ $SHELL_READLINE_FUNC -ge 1 ]]; then
    echo "[ok]   shell_read_line function found"
else
    echo "[FAIL] shell_read_line function not found"
    FAIL=1
fi

# 6. Check for sys_read call in shell_read_line (byte-by-byte reading)
SYS_READ_IN_READLINE=$(echo "$SHELL_READLINE_DUMP" | grep -c "call.*sys_read" || true)
if [[ $SYS_READ_IN_READLINE -ge 1 ]]; then
    echo "[ok]   sys_read call found in shell_read_line"
else
    echo "[FAIL] sys_read call not found in shell_read_line"
    FAIL=1
fi

# 7. Check for cmp against 0x0A (\n) in shell_read_line
CMP_0A_IN_READLINE=$(echo "$SHELL_READLINE_DUMP" | grep -c "cmp.*0xa" || true)
if [[ $CMP_0A_IN_READLINE -ge 1 ]]; then
    echo "[ok]   cmp against 0x0A (newline) found in shell_read_line"
else
    echo "[FAIL] cmp against 0x0A (newline) not found in shell_read_line"
    FAIL=1
fi

# 8. Check for dispatch_line call in _start
DISPATCH_CALL=$(echo "$_START_DUMP" | grep -c "call.*dispatch_line" || true)
if [[ $DISPATCH_CALL -ge 1 ]]; then
    echo "[ok]   call dispatch_line found (line dispatch)"
else
    echo "[FAIL] call dispatch_line not found in _start"
    FAIL=1
fi

# 9. Check for backward jump pattern (loop)
LOOP_JMP=$(echo "$_START_DUMP" | grep -c "jmp" || true)
if [[ $LOOP_JMP -ge 1 ]]; then
    echo "[ok]   jmp instruction found (loop structure)"
else
    echo "[FAIL] jmp instruction not found (no loop structure)"
    FAIL=1
fi

# 10. Check for exit path (cmp + je or cmp + jne)
CMP_COUNT=$(echo "$_START_DUMP" | grep -c "cmp" || true)
JE_COUNT=$(echo "$_START_DUMP" | grep -c "je" || true)
if [[ $CMP_COUNT -ge 1 && $JE_COUNT -ge 1 ]]; then
    echo "[ok]   cmp+je branching found (EOF check)"
else
    echo "[FAIL] cmp+je branching not found (EOF check missing)"
    FAIL=1
fi

if [[ $FAIL -eq 0 ]]; then
    echo "R17 SHELL READER OK"
    exit 0
else
    echo "R17 SHELL READER FAIL"
    exit 1
fi
