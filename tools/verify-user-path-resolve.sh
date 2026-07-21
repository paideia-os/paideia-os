#!/usr/bin/env bash
# Build-time structural canary for src/user/dispatch.pdx (R17-M3-006 / #626).
# Verifies resolve_path function: scan argv[0] for '/', prepend '/bin/' if absent.
# Marker: R17 PATH RESOLVE OK / R17 PATH RESOLVE FAIL.
set -euo pipefail

ELF="${1:-build/user/shell.elf}"

if [[ ! -f "$ELF" ]]; then
    echo "R17 PATH RESOLVE FAIL" >&2
    echo "ELF file not found: $ELF" >&2
    exit 1
fi

FAIL=0
DUMP=$(objdump -d -M intel "$ELF" 2>/dev/null || true)
SYMS=$(objdump -t "$ELF" 2>/dev/null || true)
RODATA=$(objdump -s -j .rodata "$ELF" 2>/dev/null || true)

# awk function-slicer
slice() { echo "$DUMP" | awk "/<$1>:/{f=1;next} /^[0-9a-f]+ <.*>:/{if(f)exit} f"; }

RP=$(slice resolve_path)
EC=$(slice exec_child)

# helpers
sym_size() {
    local name="$1"
    echo "$SYMS" | awk -v n="$name" '$NF == n {print $(NF-1)}' | head -1 || true
}
sym_present() {
    local name="$1"
    echo "$SYMS" | awk -v n="$name" '$NF == n {print}' | head -1 || true
}
size_ge() { # hex, decimal-threshold
    local hex="$1" thr="$2"
    local d=$((16#$hex))
    [[ $d -ge $thr ]]
}

# 1. resolve_path symbol present, size >= 30
SZ=$(sym_size resolve_path)
if [[ -z "$SZ" ]]; then echo "[FAIL] resolve_path symbol missing"; FAIL=1
elif ! size_ge "$SZ" 30; then echo "[FAIL] resolve_path too small (0x$SZ)"; FAIL=1
else echo "[ok]   resolve_path present, size 0x$SZ"; fi

# 2. resolved_path in .bss, size 0x140 (320 bytes)
SL=$(echo "$SYMS" | awk '$NF == "resolved_path" {print}' | head -1)
if [[ -z "$SL" ]]; then echo "[FAIL] resolved_path missing"; FAIL=1
elif [[ "$(echo "$SL" | awk '{print $(NF-2)}')" != ".bss" ]]; then echo "[FAIL] resolved_path not in .bss"; FAIL=1
elif [[ "$(echo "$SL" | awk '{print $(NF-1)}')" != "0000000000000140" ]]; then echo "[FAIL] resolved_path wrong size ($(echo "$SL" | awk '{print $(NF-1)}'))"; FAIL=1
else echo "[ok]   resolved_path in .bss, size 0x140"; fi

# Normalise rodata dump to a single hex stream (strip addresses, ASCII gutter, whitespace)
RODATA_STREAM=$(echo "$RODATA" | awk '/^ [0-9a-f]+ / {for (i=2;i<=5;i++) printf "%s", $i}' || true)

# 3. bin_prefix rodata bytes 2f 62 69 6e 2f (/bin/)
if echo "$RODATA_STREAM" | grep -q "2f62696e2f"; then
    echo "[ok]   bin_prefix bytes present in .rodata"
else
    echo "[FAIL] bin_prefix bytes not found in .rodata"; FAIL=1
fi

# 4. resolve_path calls memcpy >= 2
N=$(echo "$RP" | grep -Ec "call.*memcpy" || true)
if [[ "$N" -ge 2 ]]; then echo "[ok]   resolve_path calls memcpy ($N)"; else echo "[FAIL] resolve_path memcpy count $N < 2"; FAIL=1; fi

# 5. resolve_path calls strlen >= 1
N=$(echo "$RP" | grep -Ec "call.*strlen" || true)
if [[ "$N" -ge 1 ]]; then echo "[ok]   resolve_path calls strlen ($N)"; else echo "[FAIL] resolve_path strlen count $N < 1"; FAIL=1; fi

# 6. resolve_path contains cmp against 0x2F (/)
if echo "$RP" | grep -Eq "cmp.*0x2[Ff]\b"; then
    echo "[ok]   resolve_path contains cmp against 0x2F"
else
    echo "[FAIL] resolve_path missing cmp against 0x2F"; FAIL=1
fi

# 7. resolve_path contains cmp against 0x0
if echo "$RP" | grep -Eq "cmp.*0x0|cmp[[:space:]]+rax[[:space:]]*,.*0\b"; then
    echo "[ok]   resolve_path contains cmp against 0x0"
else
    echo "[FAIL] resolve_path missing cmp against 0x0"; FAIL=1
fi

# 8. resolve_path contains xor rax,rax
if echo "$RP" | grep -Eq "xor.*rax.*,.*rax"; then
    echo "[ok]   resolve_path contains xor rax,rax"
else
    echo "[FAIL] resolve_path missing xor rax,rax"; FAIL=1
fi

# 9. resolve_path #1248 hygiene: zero cmp al, instructions
if [[ -n "$RP" ]]; then
    BAD_CMP=$(echo "$RP" | grep -Ec "cmp[[:space:]]+al," || true)
    if [[ "$BAD_CMP" -gt 0 ]]; then
        echo "[FAIL] paideia-as #1248 risk: $BAD_CMP byte-narrow 'cmp al,imm8' instruction(s) in resolve_path"
        FAIL=1
    else
        echo "[ok]   paideia-as #1248 hygiene: no cmp al, in resolve_path"
    fi
fi

# 10. exec_child calls resolve_path exactly once
N=$(echo "$EC" | grep -Ec "call.*resolve_path" || true)
if [[ "$N" -eq 1 ]]; then echo "[ok]   exec_child calls resolve_path once"; else echo "[FAIL] exec_child resolve_path count $N != 1"; FAIL=1; fi

# 11. exec_child ordering: resolve_path call PC < sys_execve call PC
RP_PC=$(echo "$EC" | grep -E "call.*resolve_path" | head -1 | awk -F: '{print $1}' | tr -d ' ')
EXECVE_PC=$(echo "$EC" | grep -E "call.*sys_execve" | head -1 | awk -F: '{print $1}' | tr -d ' ')
if [[ -n "$RP_PC" && -n "$EXECVE_PC" ]] && (( 16#$RP_PC < 16#$EXECVE_PC )); then
    echo "[ok]   exec_child ordering: resolve_path ($RP_PC) < sys_execve ($EXECVE_PC)"
else
    echo "[FAIL] exec_child ordering wrong (resolve_path=$RP_PC vs sys_execve=$EXECVE_PC)"; FAIL=1
fi

# 12. exec_child has mov rdi, rax within ~4 instructions after call resolve_path
RP_LINE=$(echo "$EC" | grep -n "call.*resolve_path" | head -1 | cut -d: -f1)
if [[ -n "$RP_LINE" ]]; then
    # Extract lines after resolve_path call (next ~4 instructions)
    RESOLVE_SECTION=$(echo "$EC" | tail -n +$RP_LINE | head -5)
    if echo "$RESOLVE_SECTION" | grep -Eq "mov.*rdi[[:space:]]*,.*rax|mov[[:space:]]+rdi[[:space:]]*,"; then
        echo "[ok]   exec_child has mov rdi, rax within ~4 instructions after call resolve_path"
    else
        echo "[FAIL] exec_child missing mov rdi, rax after call resolve_path"
        FAIL=1
    fi
else
    echo "[FAIL] exec_child resolve_path call not found"
    FAIL=1
fi

if [[ $FAIL -eq 0 ]]; then
    echo "R17 PATH RESOLVE OK"
    exit 0
else
    echo "R17 PATH RESOLVE FAIL"
    exit 1
fi
