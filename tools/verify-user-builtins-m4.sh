#!/usr/bin/env bash
# Build-time structural canary for R17.M4 shell builtins (src/user/dispatch.pdx #629-634).
# Marker: R17 BUILTINS M4 OK / R17 BUILTINS M4 FAIL.
set -euo pipefail

ELF="${1:-build/user/shell.elf}"

if [[ ! -f "$ELF" ]]; then
    echo "R17 BUILTINS M4 FAIL" >&2
    echo "ELF file not found: $ELF" >&2
    exit 1
fi

FAIL=0
DUMP=$(objdump -d -M intel "$ELF" 2>/dev/null || true)
SYMS=$(objdump -t "$ELF" 2>/dev/null || true)
RODATA=$(objdump -s -j .rodata "$ELF" 2>/dev/null || true)

# awk function-slicer
slice() { echo "$DUMP" | awk "/<$1>:/{f=1;next} /^[0-9a-f]+ <.*>:/{if(f)exit} f"; }

DI=$(slice dispatch_init)
EB=$(slice echo_builtin)
XB=$(slice exit_builtin)
PWD=$(slice pwd_builtin)
HELP=$(slice help_builtin)
ENV=$(slice env_builtin)
DP=$(slice dec_parse)
CWD=$(slice cwd_init)
START=$(slice _start)
SRL=$(slice shell_read_line)

# helpers
sym_size() {
    local name="$1"
    echo "$SYMS" | awk -v n="$name" '$NF == n {print $(NF-1)}' | head -1
}
sym_present() {
    local name="$1"
    echo "$SYMS" | awk -v n="$name" '$NF == n {print}' | head -1
}
sym_pc() {
    local name="$1"
    echo "$SYMS" | awk -v n="$name" '$NF == n {print $1}' | head -1
}
size_ge() { # hex, decimal-threshold
    local hex="$1" thr="$2"
    local d=$((16#$hex))
    [[ $d -ge $thr ]]
}

# Normalise rodata dump to a single hex stream (strip addresses, ASCII gutter, whitespace)
RODATA_STREAM=$(echo "$RODATA" | awk '/^ [0-9a-f]+ / {for (i=2;i<=5;i++) printf "%s", $i}')

# 1. pwd_builtin present
if [[ -z "$(sym_present pwd_builtin)" ]]; then echo "[FAIL] pwd_builtin missing"; FAIL=1
else echo "[ok]   pwd_builtin present"; fi

# 2. help_builtin present
if [[ -z "$(sym_present help_builtin)" ]]; then echo "[FAIL] help_builtin missing"; FAIL=1
else echo "[ok]   help_builtin present"; fi

# 3. env_builtin present
if [[ -z "$(sym_present env_builtin)" ]]; then echo "[FAIL] env_builtin missing"; FAIL=1
else echo "[ok]   env_builtin present"; fi

# 4. dec_parse present
if [[ -z "$(sym_present dec_parse)" ]]; then echo "[FAIL] dec_parse missing"; FAIL=1
else echo "[ok]   dec_parse present"; fi

# 5. cwd_init present
if [[ -z "$(sym_present cwd_init)" ]]; then echo "[FAIL] cwd_init missing"; FAIL=1
else echo "[ok]   cwd_init present"; fi

# 6. builtin_descs .bss size 0x40
SL=$(echo "$SYMS" | awk '$NF == "builtin_descs" {print}' | head -1)
if [[ -z "$SL" ]]; then echo "[FAIL] builtin_descs missing"; FAIL=1
elif [[ "$(echo "$SL" | awk '{print $(NF-2)}')" != ".bss" ]]; then echo "[FAIL] builtin_descs not in .bss"; FAIL=1
elif [[ "$(echo "$SL" | awk '{print $(NF-1)}')" != "0000000000000040" ]]; then echo "[FAIL] builtin_descs wrong size"; FAIL=1
else echo "[ok]   builtin_descs in .bss, size 0x40"; fi

# 7. echo_emit_nl .bss size 0x8
SL=$(echo "$SYMS" | awk '$NF == "echo_emit_nl" {print}' | head -1)
if [[ -z "$SL" ]]; then echo "[FAIL] echo_emit_nl missing"; FAIL=1
elif [[ "$(echo "$SL" | awk '{print $(NF-2)}')" != ".bss" ]]; then echo "[FAIL] echo_emit_nl not in .bss"; FAIL=1
elif [[ "$(echo "$SL" | awk '{print $(NF-1)}')" != "0000000000000008" ]]; then echo "[FAIL] echo_emit_nl wrong size"; FAIL=1
else echo "[ok]   echo_emit_nl in .bss, size 0x8"; fi

# 8. _cwd_buf .bss size 0x100
SL=$(echo "$SYMS" | awk '$NF == "_cwd_buf" {print}' | head -1)
if [[ -z "$SL" ]]; then echo "[FAIL] _cwd_buf missing"; FAIL=1
elif [[ "$(echo "$SL" | awk '{print $(NF-2)}')" != ".bss" ]]; then echo "[FAIL] _cwd_buf not in .bss"; FAIL=1
elif [[ "$(echo "$SL" | awk '{print $(NF-1)}')" != "0000000000000100" ]]; then echo "[FAIL] _cwd_buf wrong size"; FAIL=1
else echo "[ok]   _cwd_buf in .bss, size 0x100"; fi

# 9. pwd_name rodata bytes 70 77 64 00
if echo "$RODATA_STREAM" | grep -q "70776400"; then
    echo "[ok]   pwd_name bytes present in .rodata"
else
    echo "[FAIL] pwd_name bytes not found in .rodata"; FAIL=1
fi

# 10. help_name rodata bytes 68 65 6c 70 00
if echo "$RODATA_STREAM" | grep -q "68656c7000"; then
    echo "[ok]   help_name bytes present in .rodata"
else
    echo "[FAIL] help_name bytes not found in .rodata"; FAIL=1
fi

# 11. env_name rodata bytes 65 6e 76 00
if echo "$RODATA_STREAM" | grep -q "656e7600"; then
    echo "[ok]   env_name bytes present in .rodata"
else
    echo "[FAIL] env_name bytes not found in .rodata"; FAIL=1
fi

# 12. env_path_msg rodata bytes 504154483d2f62696e0a (PATH=/bin\n)
if echo "$RODATA_STREAM" | grep -q "504154483d2f62696e0a"; then
    echo "[ok]   env_path_msg bytes present in .rodata"
else
    echo "[FAIL] env_path_msg bytes not found in .rodata"; FAIL=1
fi

# 13. help_sep rodata bytes 202d20 ( - )
if echo "$RODATA_STREAM" | grep -q "202d20"; then
    echo "[ok]   help_sep bytes present in .rodata"
else
    echo "[FAIL] help_sep bytes not found in .rodata"; FAIL=1
fi

# 14. dispatch_init size >= 0x90
SZ=$(sym_size dispatch_init)
if [[ -z "$SZ" ]]; then echo "[FAIL] dispatch_init symbol missing"; FAIL=1
elif ! size_ge "$SZ" 144; then echo "[FAIL] dispatch_init too small (0x$SZ, need >= 0x90)"; FAIL=1
else echo "[ok]   dispatch_init present, size 0x$SZ"; fi

# 15. dispatch_init writes builtin_count=5 (mov rax,0x5)
if echo "$DI" | grep -Eq "mov[[:space:]]+rax,0x5|mov[[:space:]]+rax,5"; then
    echo "[ok]   dispatch_init writes builtin_count=5"
else
    echo "[FAIL] dispatch_init missing mov rax,0x5 (builtin_count=5)"; FAIL=1
fi

# 16. _start calls cwd_init once
N=$(echo "$START" | grep -Ec "call.*cwd_init" || true)
if [[ "$N" -eq 1 ]]; then echo "[ok]   _start calls cwd_init once"; else echo "[FAIL] _start cwd_init count $N != 1"; FAIL=1; fi

# 17. cwd_init PC > dispatch_init PC, < shell_read_line PC
DI_PC=$(sym_pc dispatch_init)
CWD_PC=$(sym_pc cwd_init)
SRL_PC=$(sym_pc shell_read_line)
if [[ -n "$DI_PC" && -n "$CWD_PC" && -n "$SRL_PC" ]] && (( 16#$DI_PC < 16#$CWD_PC )) && (( 16#$CWD_PC < 16#$SRL_PC )); then
    echo "[ok]   cwd_init PC in correct order ($DI_PC < $CWD_PC < $SRL_PC)"
else
    echo "[FAIL] cwd_init PC ordering wrong (dispatch=$DI_PC cwd=$CWD_PC shell_read_line=$SRL_PC)"; FAIL=1
fi

# 18. echo_builtin references echo_emit_nl
if echo "$EB" | grep -q "echo_emit_nl"; then
    echo "[ok]   echo_builtin references echo_emit_nl"
else
    echo "[FAIL] echo_builtin missing echo_emit_nl reference"; FAIL=1
fi

# 19. echo_builtin has cmp 0x2d (-character check)
if echo "$EB" | grep -Eq "cmp[[:space:]]+.*,0x2d|cmp.*0x2d"; then
    echo "[ok]   echo_builtin has cmp 0x2d"
else
    echo "[FAIL] echo_builtin missing cmp 0x2d"; FAIL=1
fi

# 20. echo_builtin has cmp 0x6e (n-character check)
if echo "$EB" | grep -Eq "cmp[[:space:]]+.*,0x6e|cmp.*0x6e"; then
    echo "[ok]   echo_builtin has cmp 0x6e"
else
    echo "[FAIL] echo_builtin missing cmp 0x6e"; FAIL=1
fi

# 21. exit_builtin calls dec_parse
if echo "$XB" | grep -Eq "call.*<dec_parse>|call.*dec_parse"; then
    echo "[ok]   exit_builtin calls dec_parse"
else
    echo "[FAIL] exit_builtin missing dec_parse call"; FAIL=1
fi

# 22. dec_parse has cmp 0x30 (digit '0' check)
if echo "$DP" | grep -Eq "cmp[[:space:]]+.*,0x30|cmp.*0x30"; then
    echo "[ok]   dec_parse has cmp 0x30"
else
    echo "[FAIL] dec_parse missing cmp 0x30"; FAIL=1
fi

# 23. dec_parse has cmp 0x39 (digit '9' check)
if echo "$DP" | grep -Eq "cmp[[:space:]]+.*,0x39|cmp.*0x39"; then
    echo "[ok]   dec_parse has cmp 0x39"
else
    echo "[FAIL] dec_parse missing cmp 0x39"; FAIL=1
fi

# 24. dec_parse has shl 0x3 (multiply by 8 for digit accumulation)
if echo "$DP" | grep -Eq "shl[[:space:]]+.*,0x3|shl.*0x3"; then
    echo "[ok]   dec_parse has shl 0x3"
else
    echo "[FAIL] dec_parse missing shl 0x3"; FAIL=1
fi

# 25. pwd_builtin references _cwd_buf
if echo "$PWD" | grep -q "_cwd_buf"; then
    echo "[ok]   pwd_builtin references _cwd_buf"
else
    echo "[FAIL] pwd_builtin missing _cwd_buf reference"; FAIL=1
fi

# 26. pwd_builtin calls puts_new
if echo "$PWD" | grep -Eq "call.*<puts_new>|call.*puts_new"; then
    echo "[ok]   pwd_builtin calls puts_new"
else
    echo "[FAIL] pwd_builtin missing puts_new call"; FAIL=1
fi

# 27. pwd_builtin calls sys_write
if echo "$PWD" | grep -Eq "call.*<sys_write>|call.*sys_write"; then
    echo "[ok]   pwd_builtin calls sys_write"
else
    echo "[FAIL] pwd_builtin missing sys_write call"; FAIL=1
fi

# 28. help_builtin references builtin_names
if echo "$HELP" | grep -q "builtin_names"; then
    echo "[ok]   help_builtin references builtin_names"
else
    echo "[FAIL] help_builtin missing builtin_names reference"; FAIL=1
fi

# 29. help_builtin references builtin_descs
if echo "$HELP" | grep -q "builtin_descs"; then
    echo "[ok]   help_builtin references builtin_descs"
else
    echo "[FAIL] help_builtin missing builtin_descs reference"; FAIL=1
fi

# 30. help_builtin references builtin_count
if echo "$HELP" | grep -q "builtin_count"; then
    echo "[ok]   help_builtin references builtin_count"
else
    echo "[FAIL] help_builtin missing builtin_count reference"; FAIL=1
fi

# 31. help_builtin calls sys_write >= 2
N=$(echo "$HELP" | grep -Ec "call.*sys_write" || true)
if [[ "$N" -ge 2 ]]; then echo "[ok]   help_builtin calls sys_write ($N)"; else echo "[FAIL] help_builtin sys_write count $N < 2"; FAIL=1; fi

# 32. help_builtin calls puts_new >= 2
N=$(echo "$HELP" | grep -Ec "call.*puts_new" || true)
if [[ "$N" -ge 2 ]]; then echo "[ok]   help_builtin calls puts_new ($N)"; else echo "[FAIL] help_builtin puts_new count $N < 2"; FAIL=1; fi

# 33. help_builtin has backward jmp (loop)
JMP_LINES=$(echo "$HELP" | grep -E "jmp[[:space:]]+[0-9a-f]+" || true)
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
if [[ $BACKWARD -eq 1 ]]; then echo "[ok]   help_builtin has backward jmp (loop)"
else echo "[FAIL] help_builtin missing backward jmp (loop structure)"; FAIL=1; fi

# 34. env_builtin calls sys_write exactly 1
N=$(echo "$ENV" | grep -Ec "call.*sys_write" || true)
if [[ "$N" -eq 1 ]]; then echo "[ok]   env_builtin calls sys_write (1)"; else echo "[FAIL] env_builtin sys_write count $N != 1"; FAIL=1; fi

# 35. #1248 hygiene: no cmp al, in new functions
BAD=0
for F in pwd_builtin help_builtin env_builtin dec_parse cwd_init; do
    N=$(slice "$F" | grep -Ec "cmp[[:space:]]+al," || true)
    [[ "$N" -gt 0 ]] && { echo "[FAIL] #1248 risk: '$F' has $N byte-narrow cmp al,"; BAD=1; }
done
if [[ $BAD -eq 0 ]]; then echo "[ok]   paideia-as #1248 hygiene: no cmp al, in new functions"
else FAIL=1; fi

if [[ $FAIL -eq 0 ]]; then
    echo "R17 BUILTINS M4 OK"
    exit 0
else
    echo "R17 BUILTINS M4 FAIL"
    exit 1
fi
