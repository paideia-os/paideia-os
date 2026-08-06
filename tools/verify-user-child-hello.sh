#!/usr/bin/env bash
# Byte-pattern canary for src/user/child_hello.pdx (R15-M6-009 / #560).
#
# Verifies child_hello.elf contains:
#  - inline sys_write bytes  (mov rdi,1; lea rsi,[rip+msg]; mov rdx,15; mov rax,1; syscall)
#  - inline sys_exit bytes   (mov rdi,42; mov rax,60; syscall)
#  - final defensive hlt
#  - msg symbol in .rodata holding "CHILD HELLO 42\n"
#  - _start exists and is the ELF entry point (e_entry == addr(_start))
#
# Exits "R15 CHILD HELLO EMBED OK" or "R15 CHILD HELLO EMBED FAIL".
set -euo pipefail

ELF="${1:-build/user/child_hello.elf}"
FAIL=0

if [[ ! -f "$ELF" ]]; then
    echo "R15 CHILD HELLO EMBED FAIL" >&2
    echo "ELF file not found: $ELF" >&2
    exit 1
fi

# 1. Byte-pattern check on _start.
#    Expected sequence (see src/user/child_hello.pdx):
#      mov rdi, 1        48 c7 c7 01 00 00 00
#      lea rsi, [rip+X]  48 8d 35 XX XX XX XX   (X displacement, we don't pin it)
#      mov rdx, 15       48 c7 c2 0f 00 00 00
#      mov rax, 1        48 c7 c0 01 00 00 00
#      syscall           0f 05
#      mov rdi, 42       48 c7 c7 2a 00 00 00
#      mov rax, 60       48 c7 c0 3c 00 00 00
#      syscall           0f 05
#      hlt               f4
DUMP=$(objdump -d "$ELF" 2>/dev/null)

# Extract _start bytes (up to next symbol or end).
_START_BYTES=$(echo "$DUMP" | awk '
    /^[0-9a-f]+ <_start>:/ { flag=1; next }
    /^[0-9a-f]+ <.*>:/     { if (flag) exit }
    flag {
        after = $0
        sub(/^[[:space:]]+[0-9a-f]+:[[:space:]]*/, "", after)
        # after now begins with "hex hex hex ...  \tmnemonic..."
        # split on tab; keep hex column
        n = index(after, "\t")
        if (n > 0) {
            hex = substr(after, 1, n - 1)
            printf "%s ", hex
        }
    }
' | tr -s ' ')

want_prefix="48 c7 c7 01 00 00 00 48 8d 35"        # mov rdi,1; lea rsi,[rip+..]
want_after_lea="48 c7 c2 0f 00 00 00 48 c7 c0 01 00 00 00 0f 05 48 c7 c7 2a 00 00 00 48 c7 c0 3c 00 00 00 0f 05 f4"

if [[ "$_START_BYTES" == "$want_prefix "* ]]; then
    echo "[ok]   _start prefix (mov rdi,1; lea rsi) matches"
else
    echo "[FAIL] _start prefix mismatch"
    echo "       got: $_START_BYTES"
    FAIL=1
fi

if [[ "$_START_BYTES" == *"$want_after_lea"* ]]; then
    echo "[ok]   _start tail (mov rdx,15; sys_write; mov rdi,42; sys_exit; hlt) matches"
else
    echo "[FAIL] _start tail mismatch"
    echo "       want (substring): $want_after_lea"
    echo "       got: $_START_BYTES"
    FAIL=1
fi

# 2. Verify msg symbol exists in .rodata and holds "CHILD HELLO 42\n".
MSG_LINE=$(objdump -t "$ELF" 2>/dev/null | awk '$NF == "msg" { print }')
if [[ -z "$MSG_LINE" ]]; then
    echo "[FAIL] msg symbol not found"
    FAIL=1
else
    MSG_SECTION=$(echo "$MSG_LINE" | awk '{print $(NF-2)}')
    if [[ "$MSG_SECTION" != ".rodata" ]]; then
        echo "[FAIL] msg symbol not in .rodata (found in ${MSG_SECTION})"
        FAIL=1
    else
        echo "[ok]   msg symbol in .rodata"
    fi
fi

# Payload check: does .rodata contain "CHILD HELLO 42"?
RODATA_HEX=$(objdump -s -j .rodata "$ELF" 2>/dev/null | tr -d ' ' | tr -d '\n' || true)
# "CHILD HELLO 42\n" → 43 48 49 4c 44 20 48 45 4c 4c 4f 20 34 32 0a
WANT_HEX="4348494c4420"        # "CHILD "  — 6 bytes is enough to disambiguate
if [[ "$RODATA_HEX" == *"$WANT_HEX"* ]]; then
    echo "[ok]   .rodata contains 'CHILD ' payload prefix"
else
    echo "[FAIL] .rodata does not contain 'CHILD ' payload prefix"
    FAIL=1
fi

# 3. Verify _start is the ELF entry point.
START_ADDR=$(objdump -t "$ELF" 2>/dev/null | awk '$NF == "_start" { print $1 }')
ENTRY_ADDR=$(readelf -h "$ELF" 2>/dev/null | awk '/Entry point address/ { print $NF }')
if [[ -z "$START_ADDR" || -z "$ENTRY_ADDR" ]]; then
    echo "[FAIL] could not resolve _start or e_entry"
    FAIL=1
else
    # Normalize (strip leading zeros / 0x)
    NORM_START=$(printf "%s" "$START_ADDR" | sed 's/^0*//')
    NORM_ENTRY=$(printf "%s" "${ENTRY_ADDR#0x}" | sed 's/^0*//')
    if [[ "$NORM_START" == "$NORM_ENTRY" ]]; then
        echo "[ok]   e_entry matches _start (${ENTRY_ADDR})"
    else
        echo "[FAIL] e_entry (${ENTRY_ADDR}) != _start (${START_ADDR})"
        FAIL=1
    fi
fi

if [[ $FAIL -eq 0 ]]; then
    echo "R15 CHILD HELLO EMBED OK"
    exit 0
else
    echo "R15 CHILD HELLO EMBED FAIL"
    exit 1
fi
