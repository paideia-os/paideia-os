---
audit_id: r10-m5-003-boot-r10-fingerprint
issue: 384
files: [tests/r10/expected-boot-r10.txt, tools/run-smoke.sh, .githooks/pre-push]
functions: (smoke harness + pre-push integration)
reviewed_by:
date: 2026-07-02
status: complete
---

# AUDIT R10-m5-003 — boot_r10 fingerprint and smoke test (COMPLETE)

## Issue

R10-m5-003 (#384): Define a boot_r10 fingerprint file and smoke test mode to validate Task A/B cooperative yield alternation.

## Implementation

### 1. Fingerprint File: tests/r10/expected-boot-r10.txt

Defines the expected output sequence from a 10-second QEMU run:
```
B
PaideiaOS R8
CAP OK
IPC OK
IDT OK
TASK A
TASK B
TASK A
TASK B
```

The fingerprint captures:
- Boot banner and diagnostics (R8 through IDT OK)
- Task alternation (TASK A, TASK B, TASK A, TASK B, ...)

### 2. Smoke Mode: tools/run-smoke.sh

Added mode dispatcher entry for boot_r10:
```bash
boot_r10)
    FINGERPRINT_MODE=1
    FINGERPRINT_FILE="${REPO_ROOT}/tests/r10/expected-boot-r10.txt"
    TIMEOUT=10
    EXPECTED=""
    ;;
```

- Timeout: 10 seconds (longer than boot_tick/boot_r8_only to capture task alternations)
- Fingerprint validation: contains-in-order check for all 9 lines

### 3. Pre-push Hook Integration: .githooks/pre-push

Updated pre-push hook to gate on boot_r10 instead of boot_tick:
```bash
echo "Running smoke test (boot_r10)..." >&2
if ! "${REPO_ROOT}/tools/run-smoke.sh" boot_r10 >/dev/null 2>&1; then
    echo "✗ Smoke test failed (boot_r10 fingerprint not found). Refusing push." >&2
    exit 1
fi
```

Ensures Task A/B alternation is verified before any push to any branch.

## Verification

- boot_r10 mode callable: `tools/run-smoke.sh boot_r10` passes (9 lines found in order)
- Pre-push hook enforces: hook will block pushes if task alternation fails
- Timeline: QEMU runs for 10 seconds, capturing multiple task yields

## Expected Behavior

With 10-second timeout and cooperative yield loops:
- Task A prints "TASK A", yields to Task B (100s of cycles per yield)
- Task B prints "TASK B", yields to Task A
- Alternation repeats many times within the window
- Fingerprint captures at least 2 yields per task (8 lines minimum)

## Context: QEMU Timing

Per R10-m2 diagnosis, QEMU PVH timer IRQ delivery is unreliable. R10-m5 uses cooperative yield (tasks voluntarily call sched_switch_regs) instead of preemptive timer interrupts. This avoids the QEMU timing issue while still demonstrating context switching.

## References

- R10-m5-001 audit entry (bootstrap)
- R10-m5-002 audit entry (yield loops)
- R10-m2 diagnosis document (QEMU timer limitation context)
- R9-m4-002 audit entry (smoke test framework design)
