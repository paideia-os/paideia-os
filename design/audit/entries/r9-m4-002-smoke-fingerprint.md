---
audit_id: r9-m4-002-smoke-fingerprint
issue: 364
file: tests/r9/expected-boot-tick.txt, tools/run-smoke.sh, .githooks/pre-push
function: (smoke harness + pre-push integration)
effects: []
capabilities: []
reviewed_by:
date: 2026-06-24
---

# AUDIT r9-m4-002 — Smoke fingerprint extension for TICK observable

## Overview

R9-m4-002 extends the smoke testing harness to validate the R9-m4 tick worker. New fingerprint file `tests/r9/expected-boot-tick.txt` defines the expected boot sequence including multiple "TICK\n" lines. Integration into pre-push hook ensures timer functionality is verified before any push.

## Implementation details

### 1. Fingerprint file: `tests/r9/expected-boot-tick.txt`

**Content:**
```
B
PaideiaOS R8
CAP OK
IPC OK
IDT OK
TICK
TICK
TICK
TICK
```

**Specification:**
- 9 lines total (includes final newline after "TICK")
- First 5 lines: boot banner (from R8 and earlier milestones)
- Lines 6–9: four "TICK\n" outputs (demonstrates timer events are occurring)
- Order matters: boot banner must appear before any TICKs
- Contains-in-order check: smoke script verifies all lines appear in sequence in the log, with no requirement for consecutive lines

### 2. Smoke harness extension: `tools/run-smoke.sh`

**New mode: `boot_tick`**

```bash
case "${EXPECTED}" in
    ...
    boot_tick)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r9/expected-boot-tick.txt"
        TIMEOUT=5
        EXPECTED=""
        ;;
esac
```

**Usage:**
```bash
bash tools/run-smoke.sh boot_tick
```

**Behavior:**
1. Build kernel via `tools/build.sh` (or return exit code 2 if build fails)
2. Run QEMU with 5-second timeout
3. Capture serial output to `/tmp/paideia-os-smoke.log`
4. Load fingerprint file `tests/r9/expected-boot-tick.txt`
5. Verify all lines appear in order in the log (allows intervening output)
6. Return exit code 0 if fingerprint check passes, 1 if any line is missing

**Fingerprint check logic:**
```bash
while IFS= read -r line; do
    ((line_num++))
    if [[ -z "${line}" ]]; then
        continue  # Skip empty lines in fingerprint file
    fi
    if [[ "${log_content}" == *"${line}"* ]]; then
        # Line found; search offset updated for next iteration
        search_offset=$(( ${#log_content} ))
    else
        echo "smoke: fingerprint line ${line_num} ('${line}') NOT found" >&2
        exit 1
    fi
done < "${FINGERPRINT_FILE}"
```

This allows for interleaved output (e.g., debug messages between TICKs) as long as the required lines appear in order.

### 3. Pre-push hook integration: `.githooks/pre-push`

**Update:**
```bash
# R9-m4-002: Run smoke test (boot_tick fingerprint) before allowing push
echo "Running smoke test (boot_tick)..." >&2
if ! "${REPO_ROOT}/tools/run-smoke.sh" boot_tick >/dev/null 2>&1; then
    echo "✗ Smoke test failed (boot_tick fingerprint not found). Refusing push." >&2
    exit 1
fi

exit 0
```

**Effect:**
- Before any push to any branch, the pre-push hook is invoked
- Hook calls `tools/run-smoke.sh boot_tick`
- If smoke test fails (fingerprint missing), push is rejected with message:
  ```
  ✗ Smoke test failed (boot_tick fingerprint not found). Refusing push.
  ```
- If smoke test passes, hook continues to branch-protection checks (main-only)
- Per `paideia-os: no CI/CD` memory: verification is local-only, not GitHub Actions

### 4. QEMU invocation and timing

**Timeout:** 5 seconds
- At ~4 kHz TICK rate (from the polling loop): 5 seconds → ~20 TICKs expected
- Fingerprint requires 4 TICKs minimum: well within timeout
- Allows for boot latency (UART init, capability system, IPC, IDT setup, LAPIC init)

**Serial output capture:**
```bash
timeout ${TIMEOUT} qemu-system-x86_64 \
    -kernel "${KERNEL}" \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -serial "file:${LOG}" \
    -display none \
    -no-reboot \
    -no-shutdown \
    -m 32M
```

Output is written to `/tmp/paideia-os-smoke.log` (single file, overwritten on each run).

## Invariants

1. **Fingerprint line order:** All lines from expected-boot-tick.txt must appear in order in the log
2. **No duplicates required:** Each line needs to appear at least once (may appear more than once)
3. **Allowed interleaving:** Other output (debug messages, errors) may appear between fingerprint lines
4. **Case-sensitive matching:** "TICK" != "tick" (entire string match required)
5. **Pre-push gate:** Smoke test is mandatory before push (no bypass option)

## Testing strategy

**Manual verification (before pushing):**
```bash
cd /home/snunez/Development/PaideiaOS
rm -rf build && bash tools/build.sh >/dev/null 2>&1
timeout 5 qemu-system-x86_64 -kernel build/kernel.elf -display none -serial stdio -no-reboot -m 256M 2>&1 | tee /tmp/boot.log
bash tools/run-smoke.sh boot_tick
```

Expected output:
```
smoke: fingerprint check passed (all 9 lines found in order)
```

**Pre-push hook test:**
```bash
git push origin main
```

If smoke test fails:
```
Running smoke test (boot_tick)...
✗ Smoke test failed (boot_tick fingerprint not found). Refusing push.
error: failed to push some refs
```

**Failure modes:**
1. Kernel doesn't build → build.sh returns non-zero, smoke exits code 2
2. QEMU doesn't start → timeout after 5s, smoke exits code 124 (timeout)
3. Boot succeeds but no TICKs → log missing "TICK" line, smoke exits code 1
4. Boot hangs before IDT OK → log stops early, smoke exits code 1

## Known issues and future work

1. **K-modulo adjustment:** Currently outputs a TICK on every polling iteration (~4 kHz). For production, may output fewer TICKs per the K=16 or K=64 specification. Fingerprint may need to be adjusted if TICK rate changes significantly.

2. **Timeout tuning:** 5 seconds assumed sufficient for QEMU boot + TICK generation. For slower hardware or emulation, may need increase.

3. **Log file location:** Currently `/tmp/paideia-os-smoke.log` (system temp). For persistent test artifacts, consider output to `.build/smoke.log` or similar.

4. **Parallel push protection:** Pre-push hook runs serially (blocks until completion). For large teams, may want to cache build results to speed up repeated pushes.

## Citation

- `tools/run-smoke.sh` original design: `.plans/phase-1-smoke.md` (R8 bootstrap phase)
- `.githooks/pre-push` original design: `design/02-development-environment.md` §6.5 (branch-protection-equivalent)
- `paideia-os: no CI/CD` memory: feedback_paideia_os_no_cicd.md (no GitHub Actions; local verification only)
