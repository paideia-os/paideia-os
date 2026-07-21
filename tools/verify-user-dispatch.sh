#!/usr/bin/env bash
# Build-time structural canary for src/user/dispatch.pdx (R17-M3-004 / #624).
# Marker: R17 DISPATCH OK / R17 DISPATCH FAIL.
set -euo pipefail

ELF="${1:-build/user/shell.elf}"

if [[ ! -f "$ELF" ]]; then
    echo "R17 DISPATCH FAIL" >&2
    echo "ELF file not found: $ELF" >&2
    exit 1
fi

FAIL=0
DUMP=$(objdump -d -M intel "$ELF" 2>/dev/null || true)
SYMS=$(objdump -t "$ELF" 2>/dev/null || true)
RODATA=$(objdump -s -j .rodata "$ELF" 2>/dev/null || true)

# awk function-slicer
slice() { echo "$DUMP" | awk "/<$1>:/{f=1;next} /^[0-9a-f]+ <.*>:/{if(f)exit} f"; }

DL=$(slice dispatch_line)
DI=$(slice dispatch_init)
EB=$(slice echo_builtin)
XB=$(slice exit_builtin)
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

# 1. dispatch_line size > 40
SZ=$(sym_size dispatch_line)
if [[ -z "$SZ" ]]; then echo "[FAIL] dispatch_line symbol missing"; FAIL=1
elif ! size_ge "$SZ" 40; then echo "[FAIL] dispatch_line too small (0x$SZ)"; FAIL=1
else echo "[ok]   dispatch_line present, size 0x$SZ"; fi

# 2. dispatch_init size > 20
SZ=$(sym_size dispatch_init)
if [[ -z "$SZ" ]]; then echo "[FAIL] dispatch_init symbol missing"; FAIL=1
elif ! size_ge "$SZ" 20; then echo "[FAIL] dispatch_init too small (0x$SZ)"; FAIL=1
else echo "[ok]   dispatch_init present, size 0x$SZ"; fi

# 3. echo_builtin size > 20
SZ=$(sym_size echo_builtin)
if [[ -z "$SZ" ]]; then echo "[FAIL] echo_builtin symbol missing"; FAIL=1
elif ! size_ge "$SZ" 20; then echo "[FAIL] echo_builtin too small (0x$SZ)"; FAIL=1
else echo "[ok]   echo_builtin present, size 0x$SZ"; fi

# 4. exit_builtin present
if [[ -z "$(sym_present exit_builtin)" ]]; then echo "[FAIL] exit_builtin missing"; FAIL=1
else echo "[ok]   exit_builtin present"; fi

# Normalise rodata dump to a single hex stream (strip addresses, ASCII gutter, whitespace)
RODATA_STREAM=$(echo "$RODATA" | awk '/^ [0-9a-f]+ / {for (i=2;i<=5;i++) printf "%s", $i}')

# 5. echo_name rodata bytes 65 63 68 6f 00
if echo "$RODATA_STREAM" | grep -q "6563686f00"; then
    echo "[ok]   echo_name bytes present in .rodata"
else
    echo "[FAIL] echo_name bytes not found in .rodata"; FAIL=1
fi

# 6. exit_name rodata bytes 65 78 69 74 00
if echo "$RODATA_STREAM" | grep -q "6578697400"; then
    echo "[ok]   exit_name bytes present in .rodata"
else
    echo "[FAIL] exit_name bytes not found in .rodata"; FAIL=1
fi

# 7. builtin_names .bss size 0x10
SL=$(echo "$SYMS" | awk '$NF == "builtin_names" {print}' | head -1)
if [[ -z "$SL" ]]; then echo "[FAIL] builtin_names missing"; FAIL=1
elif [[ "$(echo "$SL" | awk '{print $(NF-2)}')" != ".bss" ]]; then echo "[FAIL] builtin_names not in .bss"; FAIL=1
elif [[ "$(echo "$SL" | awk '{print $(NF-1)}')" != "0000000000000010" ]]; then echo "[FAIL] builtin_names wrong size ($(echo "$SL" | awk '{print $(NF-1)}'))"; FAIL=1
else echo "[ok]   builtin_names in .bss, size 0x10"; fi

# 8. builtin_handlers .bss size 0x10
SL=$(echo "$SYMS" | awk '$NF == "builtin_handlers" {print}' | head -1)
if [[ -z "$SL" ]]; then echo "[FAIL] builtin_handlers missing"; FAIL=1
elif [[ "$(echo "$SL" | awk '{print $(NF-2)}')" != ".bss" ]]; then echo "[FAIL] builtin_handlers not in .bss"; FAIL=1
elif [[ "$(echo "$SL" | awk '{print $(NF-1)}')" != "0000000000000010" ]]; then echo "[FAIL] builtin_handlers wrong size"; FAIL=1
else echo "[ok]   builtin_handlers in .bss, size 0x10"; fi

# 9. builtin_count .bss size 0x8
SL=$(echo "$SYMS" | awk '$NF == "builtin_count" {print}' | head -1)
if [[ -z "$SL" ]]; then echo "[FAIL] builtin_count missing"; FAIL=1
elif [[ "$(echo "$SL" | awk '{print $(NF-2)}')" != ".bss" ]]; then echo "[FAIL] builtin_count not in .bss"; FAIL=1
elif [[ "$(echo "$SL" | awk '{print $(NF-1)}')" != "0000000000000008" ]]; then echo "[FAIL] builtin_count wrong size"; FAIL=1
else echo "[ok]   builtin_count in .bss, size 0x8"; fi

# 10. dispatch_line calls strlen >= 2
N=$(echo "$DL" | grep -Ec "call.*strlen" || true)
if [[ "$N" -ge 2 ]]; then echo "[ok]   dispatch_line calls strlen ($N)"; else echo "[FAIL] dispatch_line strlen count $N < 2"; FAIL=1; fi

# 11. dispatch_line calls memcmp >= 1
N=$(echo "$DL" | grep -Ec "call.*memcmp" || true)
if [[ "$N" -ge 1 ]]; then echo "[ok]   dispatch_line calls memcmp ($N)"; else echo "[FAIL] dispatch_line memcmp count $N < 1"; FAIL=1; fi

# 12. dispatch_line has call rax (indirect dispatch)
if echo "$DL" | grep -Eq "call[[:space:]]+rax|call.*QWORD PTR"; then
    echo "[ok]   dispatch_line has indirect call (call rax or call QWORD PTR)"
else
    echo "[FAIL] dispatch_line missing indirect call"; FAIL=1
fi

# 13. dispatch_line has sub rsp,0x8 AND add rsp,0x8 (SysV pad)
SUB=$(echo "$DL" | grep -Ec "sub.*rsp,0x8\b" || true)
ADD=$(echo "$DL" | grep -Ec "add.*rsp,0x8\b" || true)
if [[ "$SUB" -ge 1 && "$ADD" -ge 1 ]]; then
    echo "[ok]   dispatch_line has SysV alignment pad (sub/add rsp,0x8)"
else
    echo "[FAIL] dispatch_line missing SysV pad (sub=$SUB add=$ADD)"; FAIL=1
fi

# 14. dispatch_line has backward jmp (loop)
# Find PCs of jmp instructions and their targets; verify at least one target < source
JMP_LINES=$(echo "$DL" | grep -E "jmp[[:space:]]+[0-9a-f]+" || true)
BACKWARD=0
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    SRC=$(echo "$line" | awk -F: '{print $1}' | tr -d ' ')
    TGT=$(echo "$line" | awk '{print $NF}' | grep -oE "^[0-9a-f]+" || echo "")
    [[ -z "$TGT" ]] && TGT=$(echo "$line" | awk '{print $(NF-1)}' | grep -oE "^[0-9a-f]+" || echo "")
    if [[ -n "$SRC" && -n "$TGT" ]]; then
        SN=$((16#$SRC))
        TN=$((16#$TGT))
        if [[ $TN -lt $SN ]]; then BACKWARD=1; break; fi
    fi
done <<< "$JMP_LINES"
if [[ $BACKWARD -eq 1 ]]; then echo "[ok]   dispatch_line has backward jmp (loop)"
else echo "[FAIL] dispatch_line missing backward jmp (loop structure)"; FAIL=1; fi

# 15. echo_builtin sys_write calls >= 3
N=$(echo "$EB" | grep -Ec "call.*sys_write" || true)
if [[ "$N" -ge 3 ]]; then echo "[ok]   echo_builtin calls sys_write ($N)"; else echo "[FAIL] echo_builtin sys_write count $N < 3"; FAIL=1; fi

# 16. echo_builtin strlen calls >= 1
N=$(echo "$EB" | grep -Ec "call.*strlen" || true)
if [[ "$N" -ge 1 ]]; then echo "[ok]   echo_builtin calls strlen ($N)"; else echo "[FAIL] echo_builtin strlen count $N < 1"; FAIL=1; fi

# 17. exit_builtin calls sys_exit (not sys_exit_thread)
if echo "$XB" | grep -Eq "call.*<sys_exit>" && ! echo "$XB" | grep -Eq "sys_exit_thread"; then
    echo "[ok]   exit_builtin calls sys_exit (canonical SC+ id 60, not legacy sys_exit_thread)"
else
    echo "[FAIL] exit_builtin missing canonical sys_exit call (or calls legacy sys_exit_thread)"; FAIL=1
fi

# 18. _start calls dispatch_init exactly once
N=$(echo "$START" | grep -Ec "call.*dispatch_init" || true)
if [[ "$N" -eq 1 ]]; then echo "[ok]   _start calls dispatch_init once"; else echo "[FAIL] _start dispatch_init count $N != 1"; FAIL=1; fi

# 19. _start: dispatch_init call PC < first shell_read_line call PC
DI_PC=$(echo "$START" | grep -E "call.*dispatch_init" | head -1 | awk -F: '{print $1}' | tr -d ' ')
SR_PC=$(echo "$START" | grep -E "call.*shell_read_line" | head -1 | awk -F: '{print $1}' | tr -d ' ')
if [[ -n "$DI_PC" && -n "$SR_PC" ]] && (( 16#$DI_PC < 16#$SR_PC )); then
    echo "[ok]   dispatch_init runs before shell_read_line ($DI_PC < $SR_PC)"
else
    echo "[FAIL] _start ordering wrong (dispatch_init=$DI_PC vs shell_read_line=$SR_PC)"; FAIL=1
fi

# 20. #1248 hygiene: no cmp al, in dispatch-emitted functions
BAD=0
for F in dispatch_line dispatch_init echo_builtin exit_builtin; do
    N=$(slice "$F" | grep -Ec "cmp[[:space:]]+al," || true)
    [[ "$N" -gt 0 ]] && { echo "[FAIL] #1248 risk: '$F' has $N byte-narrow cmp al,"; BAD=1; }
done
if [[ $BAD -eq 0 ]]; then echo "[ok]   paideia-as #1248 hygiene: no cmp al, in dispatch functions"
else FAIL=1; fi

if [[ $FAIL -eq 0 ]]; then
    echo "R17 DISPATCH OK"
    exit 0
else
    echo "R17 DISPATCH FAIL"
    exit 1
fi
