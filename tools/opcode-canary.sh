#!/usr/bin/env bash
# Byte-level opcode canaries for operator-fragile kernel functions.
# Catches silent BinOp miscompiles that log-fingerprint smoke gates miss.
# Follow-up to #1201.
set -uo pipefail
REPO="$(git rev-parse --show-toplevel)"
"${REPO}/tools/build.sh" >/dev/null 2>&1 || { echo "opcode-canary: build failed" >&2; exit 2; }

# Format: OBJ|SYMBOL|MUST_CONTAIN|MUST_NOT_CONTAIN|WHY
CANARIES=(
  "build/core/mm/pt_walk.o|entry_present|4c 21|4c 01|#1196/entry_present must AND not ADD"
  "build/core/mm/pt_walk.o|pt_index|4c 21|4c 01|#1196/pt_index must AND not ADD"
  "build/core/mm/pt_walk.o|make_pte|4c 21|4c 01|#1196/make_pte must AND not ADD"
  # NOTE: #1230 C6 canary (entry_gt cmp/setcc/movzx assertion) deferred —
  # requires a kernel-side comparison-op function to exist as an anchor.
  # Filed as separate follow-up; the paideia-as-side operator-registry
  # drift-detector already catches the class of miscompile this would gate.
)

fail=0
for row in "${CANARIES[@]}"; do
  IFS='|' read -r obj sym must_have must_not why <<<"$row"
  dis=$(objdump -d --disassemble="$sym" "${REPO}/${obj}" 2>/dev/null)
  if [[ -z "$dis" ]]; then
    echo "opcode-canary: FAIL symbol $sym not found in $obj ($why)" >&2
    fail=1
    continue
  fi
  if ! grep -qE "$must_have" <<<"$dis"; then
    echo "opcode-canary: FAIL $obj:$sym missing '$must_have' ($why)" >&2
    fail=1
  fi
  if grep -qE "$must_not" <<<"$dis"; then
    echo "opcode-canary: FAIL $obj:$sym contains forbidden '$must_not' ($why)" >&2
    fail=1
  fi
done
exit $fail
