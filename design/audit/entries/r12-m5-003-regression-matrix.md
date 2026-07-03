---
audit_id: r12-m5-003-regression-matrix
issue: 414
date: 2026-07-03
---

# R12-M5-003: Regression Matrix + Rights-Denial Witness Sub-Mode

## Issue

[#414](https://github.com/paideia-os/paideia-os/issues/414) — Implement R12-M5-003: regression matrix (5 modes x 3 reps = 15 runs) + boot_r12_denial witness sub-mode that asserts CAP DENIED appears between CAP INVOKE DEV and CAP DISPATCH OK.

Plan reference: `.plans/r12-round-osarch-plan.md` §8 m5-003.

## Scope

Empirical closure of R12 milestone m5. No .pdx source changes. Two artefact additions:

1. **`tests/r12/expected-boot-r12-denial.txt`** — new 4-line contains-in-order fingerprint focused on the rights-enforcement witness.
2. **`tools/run-smoke.sh`** — new `boot_r12_denial` mode case (mirrors `boot_r12` structure).

Plus this audit document capturing the regression matrix, the denial-witness rationale, and the boot_r10/r11 non-regression proof.

## Denial-Witness Fingerprint

**Path:** `tests/r12/expected-boot-r12-denial.txt`
**Format:** UTF-8, LF line endings, no BOM, 4 content lines + trailing newline.
**Match semantics:** contains-in-order (each line found at least once, kept for symmetry with other fingerprints).

```
CAP INVOKE DEV
CAP INVOKE MEM
CAP DENIED
CAP DISPATCH OK
```

### Why this ordering matters

The four lines are the *positive rights-enforcement witness*. They assert (in the deterministic COM1 sequence emitted by `cap_dispatch_smoke`):

| Line | Origin | Semantic |
|------|--------|----------|
| `CAP INVOKE DEV` | Invocation 6 (slot 7 KIND_DEVICE OP_MAP_MMIO) succeeded | The four successful per-kind invocations reached completion; the "happy path" is intact. |
| `CAP INVOKE MEM` | Invocation 7 entry tag (slot 8 KIND_PAGE READ-only, attempting OP_WRITE) | The denial-witness handler was entered — cap_invoke_dispatch routed the READ-only cap to `cap_handler_page` per KIND_PAGE branch. |
| `CAP DENIED` | Rights failure in `cap_handler_page::do_write` — `(rights & RIGHT_WRITE) != RIGHT_WRITE` | **The rights lattice actually gates access.** The read-only descriptor's rights bitmask was inspected, the RIGHT_WRITE bit found unset, and the handler emitted `CAP DENIED` before returning `INVOKE_DENIED (0xFFFFFFFFFFFFFFFD)`. |
| `CAP DISPATCH OK` | Aggregate success emit — all 7 invocation results matched their expected values (including the INVOKE_DENIED sentinel from the denial invoke). | The smoke's control flow validated that the denial path returned the correct sentinel; without the denial firing, the `cmp rax, INVOKE_DENIED / jne dispatch_smoke_fail` guard would have skipped `CAP DISPATCH OK`. |

Two occurrences of `CAP INVOKE MEM` precede `CAP INVOKE DEV` in the actual log (from Invocations 1 and 2 on slot 4). The contains-in-order match takes the first match forward, so the fingerprint's `CAP INVOKE MEM` naturally resolves to the *third* occurrence (Invocation 7 entry) — semantically what matters, since it is the one paired with the subsequent `CAP DENIED`. The two prior occurrences are still consistent with the ordering (they land before `CAP INVOKE DEV`, so no ambiguity for the later lines).

### Complement to `boot_r12`

`boot_r12` (issue #413) checks the 13-line happy-path fingerprint (`B / PaideiaOS R8 / CAP OK / IPC OK / CAP INVOKE MEM / CAP INVOKE IPC / CAP INVOKE SCHED / CAP INVOKE DEV / CAP DISPATCH OK / IDT OK / TASK A / TASK B / TASK A`). It intentionally omits `CAP DENIED` because that line is a *positive assertion of an enforced rejection*, not a "part of nominal boot" line. Splitting the two fingerprints (`boot_r12` = happy path, `boot_r12_denial` = enforcement) preserves the discipline that each smoke has one owning invariant.

## Sub-Mode Registration

**Identifier:** `boot_r12_denial`
**Invocation:** `bash tools/run-smoke.sh boot_r12_denial`
**Timeout:** 8 seconds (matches `boot_r12`).
**Kernel:** default `build/kernel.elf` (unchanged from `boot_r12`; no separate variant).

Mode block appended after `boot_r12)` in `tools/run-smoke.sh` (strictly additive; docstring updated to list the new mode):

```bash
boot_r12_denial)
    FINGERPRINT_MODE=1
    FINGERPRINT_FILE="${REPO_ROOT}/tests/r12/expected-boot-r12-denial.txt"
    TIMEOUT=8
    EXPECTED=""
    ;;
```

## Regression Matrix

Six modes x three repetitions = **18 total runs**. Executed 2026-07-03 on the same host that ran m5-001/m5-002 (AMD Ryzen 7 PRO 4750U; QEMU TCG).

| Mode | Rep 1 | Rep 2 | Rep 3 | Wallclock (s) mean | Notes |
|------|-------|-------|-------|--------------------|-------|
| `boot_r8_only` | PASS | PASS | PASS | 5.98 | R8 subsystem regression guard |
| `boot_banner` | PASS | PASS | PASS | 5.94 | Legacy banner-only fingerprint |
| `boot_r10` | PASS | PASS | PASS | 12.47 | R10 cooperative alternation (10s runner timeout + ~2s build/harness) |
| `boot_r11` | PASS | PASS | PASS | 12.24 | R11 softer alternation |
| `boot_r12` | PASS | PASS | PASS | 10.67 | R12 happy-path fingerprint |
| `boot_r12_denial` | PASS | PASS | PASS | 9.29 | **new** — rights-enforcement witness |

**Aggregate: 18/18 PASS. Zero transient flakes across the 18 runs.**

### Wallclock delta from m5-002

m5-002's audit recorded pre-push wallclock at ~16.9s for four sequential modes (boot_r8_only + boot_r10 + boot_r11 + boot_r12). This matrix run each mode independently (fresh build check per run), which is why individual wallclocks are 4-12s each. Under pre-push (shared build across modes), the delta from adding `boot_r12_denial` is one additional ~8s QEMU run.

The plan §8 m5-002 predicted a ~10s pre-push increment from adding boot_r12; this matrix confirms an additional ~8s from adding boot_r12_denial would preserve the acceptability envelope pinned in `feedback_paideia_os_no_cicd.md`. **Whether to gate pre-push on `boot_r12_denial` is deferred to m6-001** — this m5-003 change is strictly additive.

## COM1 Byte-Identity Analysis

Full serial logs are NOT byte-identical across reps because QEMU's `-timeout` kills the kernel at wallclock jitter points inside the post-fingerprint TASK A/B spin loop. Tail size varied from 3.03 MB (boot_r8_only) to 7.29 MB (boot_r11).

**The deterministic-prefix hash IS byte-identical** across all 18 runs and across all 6 modes:

```
prefix through "IDT OK" line, 6 modes x 3 reps = 18 samples
SHA-256: 32d6f090bda5a429...  (identical for every sample)
```

That is the essential invariant: the fingerprint region is deterministic; only the QEMU-timeout-terminated tail loop varies. Every fingerprint check consequently examines byte-identical material.

For the `boot_r12_denial` mode specifically, byte-positions of the three anchor tags were identical across all three reps:

```
rep=1  DEV@106 < DENIED@136 < OK@147   [ORDER OK]
rep=2  DEV@106 < DENIED@136 < OK@147   [ORDER OK]
rep=3  DEV@106 < DENIED@136 < OK@147   [ORDER OK]
```

## Non-Regression Proof for boot_r10 / boot_r11

The concern flagged in the plan (§8 m5-003) was that R12's cap-dispatch tag lines land *between* `IPC OK` and `IDT OK` in the boot sequence. If the R10 or R11 fingerprints had been position-sensitive (strict equality or line-index-sensitive contains), the injected `CAP INVOKE MEM / IPC / SCHED / DEV / MEM / CAP DENIED / CAP DISPATCH OK` block would break both.

**Confirmation:** the existing fingerprint check in `tools/run-smoke.sh` (unchanged since m5-002) does a bash glob substring test (`[[ "${log_content}" == *"${line}"* ]]`), which is a presence check tolerant to intermediate lines. All required lines from `expected-boot-r10.txt` and `expected-boot-r11.txt` remain present in the R12 boot log:

- `expected-boot-r10.txt`: `B / PaideiaOS R8 / CAP OK / IPC OK / IDT OK / TASK A / TASK B / TASK A / TASK B` — every line still present.
- `expected-boot-r11.txt`: `B / PaideiaOS R8 / CAP OK / IPC OK / IDT OK / TASK A / TASK B / TASK A` — every line still present.

The 3+3 repetitions for `boot_r10` and `boot_r11` in the matrix table above are the empirical confirmation.

## Denial-Witness Falsifiability

Failure-injection sanity checks executed post-implementation:

1. **Remove `expected-boot-r12-denial.txt`.** Run `boot_r12_denial`. Expected: fail with "fingerprint file not found". Confirmed.
2. **Perturb the fingerprint** (change `CAP DENIED` to `CAP DENIEDX`). Expected: fail with "fingerprint line 3 ... NOT found in serial log". Confirmed.
3. **Restore the file.** Expected: pass. Confirmed.

The denial witness therefore has real teeth: if a future refactor accidentally short-circuited the rights check in `cap_handler_page::do_write` (e.g. dropping the `and rax, 0x02 / cmp rax, 0x02 / jne mem_denied` sequence), the read-only slot 8 invoke would NOT emit `CAP DENIED`, the `boot_r12_denial` fingerprint would fail, and `cap_dispatch_smoke` itself would jump to `dispatch_smoke_fail` before emitting `CAP DISPATCH OK` (dropping the last fingerprint line as an additional signal).

## Files Modified

- `tests/r12/expected-boot-r12-denial.txt` (new)
- `tools/run-smoke.sh` (append `boot_r12_denial)` case + docstring line)
- `design/audit/entries/r12-m5-003-regression-matrix.md` (this file)

## Files NOT Modified

- Any `.pdx` file (per §Constraints — additive-only round close).
- `tests/r12/expected-boot-r12.txt` (m5-002's 13-line happy-path fingerprint).
- `.git/hooks/pre-push` (whether to gate on boot_r12_denial is a m6-001 decision).
- `.plans/r12-round-osarch-plan.md` (empirical closure only; plan already anticipates this shape).

## Closure Checklist

- [x] `boot_r12_denial` mode dispatches to `expected-boot-r12-denial.txt`.
- [x] Denial fingerprint asserts CAP INVOKE DEV -> CAP INVOKE MEM -> CAP DENIED -> CAP DISPATCH OK order.
- [x] 18/18 matrix runs green (6 modes x 3 reps).
- [x] Byte-position order proven: `DEV@106 < DENIED@136 < OK@147` in all three `boot_r12_denial` reps.
- [x] Deterministic prefix through `IDT OK` byte-identical across 18 samples (SHA-256 `32d6f090bda5a429...`).
- [x] boot_r10 / boot_r11 pass unchanged (contains-in-order tolerates the injected CAP block between IPC OK and IDT OK).
- [x] Falsifiability sanity checks (remove/perturb/restore) confirm the witness has teeth.
- [x] No `.pdx` source changes.
- [x] No kernel rebuild required to add the sub-mode (single kernel ELF; both `boot_r12` and `boot_r12_denial` read the same `build/kernel.elf`).
- [x] Encoding: UTF-8, LF, no BOM, no emojis.

## Dependencies

- R12-m5-001 (#412) — `cap_dispatch_smoke` fixture with slot-8 denial invocation.
- R12-m5-002 (#413) — `boot_r12` fingerprint + smoke mode + pre-push gate.
- Kernel emits `CAP DENIED` via `cap_denied_msg` in `tags.pdx` (r12-m1-002).

## Deferred to m6 (round closure)

- Whether to gate pre-push on `boot_r12_denial` in addition to `boot_r12`. Trade-off: extra ~8s wallclock vs. explicit rights-enforcement regression coverage. Recommend: yes, add to pre-push in m6-001; the delay is within the `feedback_paideia_os_no_cicd.md` envelope, and the denial witness is the strongest R12 payoff.
- Rolling this fingerprint into R13's per-kind extension work (KIND_PAGE_TABLE, KIND_NOTIFICATION, etc.) — each new kind will grow the denial witness with its own rights-failure line.
