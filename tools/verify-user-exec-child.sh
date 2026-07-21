#!/usr/bin/env bash
# Build-time structural canary for src/user/dispatch.pdx (R17-M3-005 / #625).
# Verifies exec_child function: fork, execve, wait4, NULL-terminator setup, exit(127) fallback.
# Marker: R17 EXEC OK / R17 EXEC FAIL.
set -euo pipefail

ELF="${1:-build/user/shell.elf}"

if [[ ! -f "$ELF" ]]; then
    echo "R17 EXEC FAIL" >&2
    echo "ELF file not found: $ELF" >&2
    exit 1
fi

FAIL=0
DUMP=$(objdump -d -M intel "$ELF" 2>/dev/null || true)
SYMS=$(objdump -t "$ELF" 2>/dev/null || true)

# awk function-slicer
slice() { echo "$DUMP" | awk "/<$1>:/{f=1;next} /^[0-9a-f]+ <.*>:/{if(f)exit} f"; }

EC=$(slice exec_child)
START=$(slice _start)

# helpers
sym_size() {
    local name="$1"
    echo "$SYMS" | awk -v n="$name" '$NF == n {print $(NF-1)}' | head -1
}
sym_present() {
    local name="$1"
    echo "$SYMS" | awk -v n="$name" '$NF == n {print}' | head -1
}
size_ge() { # hex, decimal-threshold
    local hex="$1" thr="$2"
    local d=$((16#$hex))
    [[ $d -ge $thr ]]
}

# 1. exec_child symbol present, size >= 40
SZ=$(sym_size exec_child)
if [[ -z "$SZ" ]]; then echo "[FAIL] exec_child symbol missing"; FAIL=1
elif ! size_ge "$SZ" 40; then echo "[FAIL] exec_child too small (0x$SZ)"; FAIL=1
else echo "[ok]   exec_child present, size 0x$SZ"; fi

# 2. child_wait_status in .bss, size 0x8
SL=$(echo "$SYMS" | awk '$NF == "child_wait_status" {print}' | head -1)
if [[ -z "$SL" ]]; then echo "[FAIL] child_wait_status missing"; FAIL=1
elif [[ "$(echo "$SL" | awk '{print $(NF-2)}')" != ".bss" ]]; then echo "[FAIL] child_wait_status not in .bss"; FAIL=1
elif [[ "$(echo "$SL" | awk '{print $(NF-1)}')" != "0000000000000008" ]]; then echo "[FAIL] child_wait_status wrong size ($(echo "$SL" | awk '{print $(NF-1)}'))"; FAIL=1
else echo "[ok]   child_wait_status in .bss, size 0x8"; fi

# 3. exec_child calls sys_fork >= 1
N=$(echo "$EC" | grep -Ec "call.*sys_fork" || true)
if [[ "$N" -ge 1 ]]; then echo "[ok]   exec_child calls sys_fork ($N)"; else echo "[FAIL] exec_child sys_fork count $N < 1"; FAIL=1; fi

# 4. exec_child calls sys_execve >= 1
N=$(echo "$EC" | grep -Ec "call.*sys_execve" || true)
if [[ "$N" -ge 1 ]]; then echo "[ok]   exec_child calls sys_execve ($N)"; else echo "[FAIL] exec_child sys_execve count $N < 1"; FAIL=1; fi

# 5. exec_child calls sys_wait4 >= 1
N=$(echo "$EC" | grep -Ec "call.*sys_wait4" || true)
if [[ "$N" -ge 1 ]]; then echo "[ok]   exec_child calls sys_wait4 ($N)"; else echo "[FAIL] exec_child sys_wait4 count $N < 1"; FAIL=1; fi

# 6. exec_child calls sys_exit >= 1 (child's failure exit(127))
N=$(echo "$EC" | grep -Ec "call.*sys_exit" || true)
if [[ "$N" -ge 1 ]]; then echo "[ok]   exec_child calls sys_exit ($N)"; else echo "[FAIL] exec_child sys_exit count $N < 1"; FAIL=1; fi

# 7. exec_child contains mov edi,0x7f or mov rdi,0x7f (the 127 literal for exit code)
if echo "$EC" | grep -Eq "mov.*rdi,0x7f|mov.*edi,0x7f"; then
    echo "[ok]   exec_child contains mov to rdi with 0x7f (exit 127)"
else
    echo "[FAIL] exec_child missing mov rdi,0x7f or mov edi,0x7f (exit 127 literal)"
    FAIL=1
fi

# 8. exec_child contains indexed store into argv_buf area (mov QWORD PTR [...*8], ...)
#    Pattern: mov [reg + reg*8], ... (NULL-terminator store)
if echo "$EC" | grep -Eq "mov.*QWORD PTR.*\[.*\*8\],|mov.*\[.*\*8\].*,"; then
    echo "[ok]   exec_child contains indexed store into argv_buf area (NULL-terminator)"
else
    echo "[FAIL] exec_child missing indexed store (mov [...*8], ...) for NULL-terminator"
    FAIL=1
fi

# 9. _start calls exec_child exactly once
N=$(echo "$START" | grep -Ec "call.*exec_child" || true)
if [[ "$N" -eq 1 ]]; then echo "[ok]   _start calls exec_child once"; else echo "[FAIL] _start exec_child count $N != 1"; FAIL=1; fi

# 10. _start ordering: dispatch_line PC < exec_child PC
DL_PC=$(echo "$START" | grep -E "call.*dispatch_line" | head -1 | awk -F: '{print $1}' | tr -d ' ')
EC_PC=$(echo "$START" | grep -E "call.*exec_child" | head -1 | awk -F: '{print $1}' | tr -d ' ')
if [[ -n "$DL_PC" && -n "$EC_PC" ]] && (( 16#$DL_PC < 16#$EC_PC )); then
    echo "[ok]   _start ordering: dispatch_line ($DL_PC) < exec_child ($EC_PC)"
else
    echo "[FAIL] _start ordering wrong (dispatch_line=$DL_PC vs exec_child=$EC_PC)"; FAIL=1
fi

# 11. _start has cmp rax,0x0 followed by je within ~8 instructions after call dispatch_line
DL_LINE=$(echo "$START" | grep -n "call.*dispatch_line" | head -1 | cut -d: -f1)
if [[ -n "$DL_LINE" ]]; then
    # Extract ~8 lines after dispatch_line call
    DISPATCH_SECTION=$(echo "$START" | tail -n +$DL_LINE | head -20)
    if echo "$DISPATCH_SECTION" | grep -Eq "cmp.*rax,0x0|cmp.*rax,0" && echo "$DISPATCH_SECTION" | grep -Eq "je[[:space:]]+"; then
        echo "[ok]   _start has cmp rax,0 + je after dispatch_line"
    else
        echo "[FAIL] _start missing cmp rax,0 + je after dispatch_line"
        FAIL=1
    fi
else
    echo "[FAIL] _start dispatch_line call not found for conditional check"
    FAIL=1
fi

# 12. #1248 hygiene: zero cmp al, in exec_child
if [[ -n "$EC" ]]; then
    BAD_CMP=$(echo "$EC" | grep -Ec "cmp[[:space:]]+al," || true)
    if [[ "$BAD_CMP" -gt 0 ]]; then
        echo "[FAIL] paideia-as #1248 risk: $BAD_CMP byte-narrow 'cmp al,imm8' instruction(s) in exec_child"
        FAIL=1
    else
        echo "[ok]   paideia-as #1248 hygiene: no cmp al, in exec_child"
    fi
fi

if [[ $FAIL -eq 0 ]]; then
    echo "R17 EXEC OK"
    exit 0
else
    echo "R17 EXEC FAIL"
    exit 1
fi
