# Capability-flow adversarial test harness

**Status:** R141.M4 landed (Wave UMB-W23, paideia-os #2648). Scope: a
kernel-side test module (`src/kernel/core/perf/cap_adversary.pdx`) that
exercises five adversarial cases against the R125 cap-flow substrate --
`_cap_minter_derive`, `_cap_minter_set_active_env`, the `KIND_CAP_ENV`
row pool, and the direct-write revoke semantics the shell relies on --
and reports PASS/FAIL per case plus a packed run-all summary.

**Umbrella:** R141 is the kernel-space performance-measurement umbrella.
M1 (Wave UMB-W3, #2645) landed the microbench harness. M2 (Wave UMB-W13,
#2646) landed the perf-sink dumper. M3 (Wave UMB-W22, #2647) landed the
byte-level fuzz entries. **M4 (this landing)** adds the adversarial
layer: hostile-input tests against the R125 cap-flow invariants that
every other R141.M* milestone measures but none actively PROBE.

**Companion module to R125.** R125 (`#2478`) is the cap-flow-at-exec
umbrella; its M1/M2/M3/M4 landings built the substrate (env table,
sub-cap derivation daemon, ELF `.caps.decl` loader, syscall-entry
cap-check). This M4-of-R141 is the first harness that treats that
substrate as a hostile-input surface rather than a producer-correct one.

---

## 1  Problem statement

Every function in R125 carries a per-function justification that argues
one invariant: `_cap_minter_derive` refuses to widen rights, `cap_env_
insert` refuses to overflow the slot pool, `cap_env_lookup` refuses to
cross env boundaries, and so on. Those arguments are READ at review
time and never EXECUTED. A refactor that inverts a `jne cmnt_de_widen`
to a `je cmnt_de_widen` would:

* make `_cap_minter_derive` return `CM_OK` for widened rights;
* leave every unit-test the kernel runs today untouched (no R125 test
  exercises widening);
* leave every boot witness fingerprint intact (`CAP_MINTER DERIVE OK`
  looks identical for a legitimate narrow and a bogus widen);
* make every subsequent command run with wider authority than its
  cap-env should grant.

The chain from "silent regression" to "privilege escalation across
every command" is one keystroke. R141.M4 closes it by giving each of
the five load-bearing invariants an adversarial witness that explicitly
tries the forbidden thing and reports whether the daemon refused.

## 2  Five adversarial cases

| id | name                | invariant                            | expected errno                               |
|----|---------------------|--------------------------------------|----------------------------------------------|
| 0  | `narrow_only`       | child rights ⊆ parent rights         | `CM_ERR_RIGHTS_WIDEN`    (0x0F02)            |
| 1  | `bad_parent`        | parent slot must be occupied         | `CM_ERR_PARENT_INVALID`  (0x0F01)            |
| 2  | `env_full`          | env has at most 6 slots              | `CM_ERR_ENV_FULL`        (0x0F03)            |
| 3  | `cross_env_leak`    | active-env rebind isolates authority | `CM_ERR_PARENT_INVALID`  (0x0F01)            |
| 4  | `revoke_blocks_use` | revoked cap is unreachable           | `CM_ERR_PARENT_INVALID`  (0x0F01)            |

Each case follows the same five-step shape:

1. **Setup.** Create a fresh env via `cap_env_create`; mint a parent
   fixture at `cap_table[CADV_PARENT_SLOT=100]` with the test-specific
   rights via `cadv_mint_parent` (a thin wrapper over `cap_mint_write`
   that pins `kind=0xAD` and `target_ptr=0xBEEF`); insert the parent
   into the env's slot 0 via `cap_env_insert`; bind the ambient active
   env via `_cap_minter_set_active_env`. Cases without a parent (bad_
   parent) skip the mint+insert; cases needing multiple envs (cross_
   env_leak) iterate the create step.
2. **Invoke.** Call the surface under test -- in all five cases this
   is `_cap_minter_derive`, because derive is the only R125.M2 surface
   that exercises every one of the four invariants' refusal paths plus
   the lineage-level revoke semantics (the second derive in test 4).
3. **Capture.** Read the daemon's returned errno into a callee-save
   register.
4. **Cleanup.** Reset the ambient active env to `CM_ENV_NONE` (0xFF);
   destroy the env row(s) via `cap_env_destroy`; clear the parent
   fixture via `cadv_clear_cap_slot(CADV_PARENT_SLOT)`. The harness
   leaves no residue on the cap-table or env-table pools.
5. **Classify.** `cadv_classify_and_emit(expected, actual, pass_tag,
   fail_tag)` compares, emits one klog line, and returns one of
   `CA_ADV_OK`, `CA_ADV_UNEXPECTED_SUCCESS` (actual == 0 ≠ expected),
   or `CA_ADV_UNEXPECTED_ERRNO` (actual ≠ expected ≠ 0).

### 2.1  Case detail: `narrow_only`

Parent rights = `CADV_RIGHTS_NARROW` (0x001, single-bit). Derive request
asks for `CADV_RIGHTS_WIDEN` (0x003 -- bit 1 is NOT in parent). The
daemon's step 7 narrow-only check (`svc/cap_minter.pdx`) evaluates

```
rax := requested_rights
and rax, parent_rights
cmp rax, requested_rights
jne cmnt_de_widen
```

which is `(0x003 & 0x001) == 0x001 ≠ 0x003`, so the daemon jumps to
`cmnt_de_widen` and returns `CM_ERR_RIGHTS_WIDEN` (0x0F02).

Why 0x003 against 0x001 specifically? Because `(0x002 & 0x001) == 0`,
which fails the compare for a different reason -- the whole mask is
disjoint rather than wider -- and the test wants to witness the WIDER-
BUT-OVERLAPPING case, which is the realistic refactor hazard.

### 2.2  Case detail: `bad_parent`

No parent cap is inserted. The env is created, bound as the ambient
active, and `_cap_minter_derive(slot=0, requested=0x001)` runs against
an empty slot. Step 4 reads `cap_env_lookup(env, 0) == 0` and the
daemon branches to `cmnt_de_parent`, returning `CM_ERR_PARENT_INVALID`
(0x0F01).

The task directive mentions "derive from a non-existent parent slot".
The present test chooses the strictly stronger variant -- a slot that
EXISTS in the env's slot range (`slot=0 < CAP_ENV_SLOTS=6`) but is
EMPTY -- because that is the one a shell with a misconfigured `.caps.
decl` would hit, not the out-of-range case (`slot >= 6`) which is
rejected earlier in the ladder (step 3) and whose refusal path is a
superset of the step-4 path tested here. A follow-on milestone may add
an `_ca_test_oob_parent` for the step-3 branch.

### 2.3  Case detail: `env_full`

A parent with rights `CADV_RIGHTS_WIDE` (0xFF) is inserted into all six
env slots. `cap_env_insert` bumps `cap_count` on each 0→non-zero
transition; after the sixth insert `cap_count == 6`, and the env is at
capacity. `_cap_minter_derive(slot=0, requested=0x001)` passes steps
1-8 (narrow-check succeeds, env is not frozen) and reaches step 9's
`cmnt_find_free_env_slot`, which scans all six slots via
`cap_env_lookup` and finds none empty, returning the no-free sentinel
`CAP_ENV_SLOTS` (6). Step 9 branches to `cmnt_de_envfull` and the
daemon returns `CM_ERR_ENV_FULL` (0x0F03).

Choosing the SAME `cap_table` idx (100) for the fill value makes the
pre-derive state deterministic: every slot holds the same `u64`, every
`cap_env_lookup` returns 100, every advance of the scan cursor is
visible from outside via the cap-env stats pool. A race-free witness
that a future multi-core landing can re-use once the daemon takes a
guard.

### 2.4  Case detail: `cross_env_leak`

Two envs: A (with parent at slot 0) and B (empty). Active env is set
to B. The derive request `_cap_minter_derive(slot=0, requested=0x001)`
hits step 4 against env B -- `cap_env_lookup(env_B, 0) == 0` -- and the
daemon returns `CM_ERR_PARENT_INVALID`.

**Why this case matters more than it looks.** The ambient active-env
global `_cap_minter_active_env` is a single `u64` the shell writes
during `_cap_minter_set_active_env`. If a future IPC-level active-env
rebind lands with a bug -- for example, if the dispatcher reads the
cap-env handle from a frame field and forgets to validate ownership
of the referenced env -- a compromised shell could call
`_cap_minter_set_active_env(someone_elses_env)` and immediately read
or derive caps from an env it never held. This test witnesses the
daemon's env-side `cap_env_lookup` behaviour -- it DOES NOT witness
the broader ownership question (because R125 at M4 has no per-env
owner column) -- but it catches the simplest regression: a code path
that happens to read the stored slot value from env A even when env B
is active would turn `CAP_ADV cross_env_leak PASS` into `CAP_ADV
cross_env_leak FAIL errno=0x0` (unexpected SUCCESS -- the scariest
category).

### 2.5  Case detail: `revoke_blocks_use`

Three steps:

1. First derive succeeds. The daemon writes a child capability into
   `cap_table[192..256)` (the cap-minter's reserved range) and the
   child's env slot is written to `_cadv_scratch_out`.
2. The test reads back the child's `cap_table` idx via
   `cap_env_lookup(env, child_env_slot)` and clears the three
   descriptor words at `cap_table + child_idx*24` via
   `cadv_clear_cap_slot`.
3. Second derive uses `child_env_slot` as its parent. The daemon's
   step 6 reads `cap_table + child_idx*24 + 0` and finds `kind == 0`,
   which falls into the `cmnt_de_parent` branch. Expected errno =
   `CM_ERR_PARENT_INVALID`.

**Why direct-clear rather than `cap_revoke_slot`?** The harness is a
R125 invariant witness, not a kind-dispatch exerciser. `cap_revoke_
slot` dispatches on kind through a table that spans `KIND_OP_REGION`,
`KIND_I2C_BUS`, `KIND_GPIO_LINE`, `KIND_FW_SESSION`, `KIND_EC_QUERY`,
`KIND_THERMAL_ZONE`, `KIND_BATTERY`, `KIND_COOLING_DEVICE` and more;
coupling the harness to that table would make a change to any per-kind
revoke break the harness even though the invariant under test did not
change. The direct-clear path matches the generic branch of
`cap_revoke_slot` for an unregistered kind (which the test's
`kind=0xAD` is), one-for-one, so the daemon's step-6 kind check sees
the exact state a real revoke would produce.

**Observations the test does NOT make at R141.M4:**

* The child's env slot in the env row is UNCHANGED by the revoke
  (lineage tracking is R128 scope). The daemon catches the revoked
  state only via the kind check at step 6, not via env bookkeeping.
* The "USE" of the child cap is a derive attempt rather than a
  `cap_invoke`, because `kind=0xAD` has no dispatcher arm; the derive
  path is the richest reachable use without a per-kind handler. A
  follow-on milestone adds an invoke-path case once a dispatched kind
  is wired for test fixtures.

## 3  Return codes

```
CA_ADV_OK                 = 0        # test observed the expected errno
CA_ADV_UNEXPECTED_SUCCESS = 0x2500   # daemon returned CM_OK (no refusal)
CA_ADV_UNEXPECTED_ERRNO   = 0x2501   # daemon refused with wrong code
```

Both error codes fit `imm32` with bit 31 clear (seven-byte zero-extend
`mov rax, imm32` emit). Band audit on 2026-10-14:

```
$ grep -rnE '0x250[01]\b' src/kernel/ 2>/dev/null
(empty)
```

The adjacent band base `0x2400` is R141.M3's `FZ_ERR_BAD_ENTRY` /
`FZ_ERR_CORPUS_EMPTY` (fuzz_entries); `0x2500` is a clean next-slice
step adjacent to the R141 family.

**UNEXPECTED_SUCCESS is the load-bearing failure mode.** It means a
privilege-escalation path exists: the daemon let the hostile request
through without any refusal. UNEXPECTED_ERRNO is weaker (the daemon
refused, so no escalation) but still an API-contract break -- the
caller's error-handling ladder was designed against the pinned
taxonomy. Any CI dashboard watching `_ca_run_all`'s return should
tier its alerts accordingly: UNEXPECTED_SUCCESS pages immediately,
UNEXPECTED_ERRNO files an issue.

## 4  Fingerprint contract

Each test emits exactly ONE klog line at the classify step:

```
CAP_ADV narrow_only PASS                        # klog_s1, no KV
CAP_ADV narrow_only FAIL errno=0x0F03           # klog_s1_x1, one hex KV
CAP_ADV bad_parent PASS
...
```

The ten pre-built tag strings (five PASS, five FAIL) sit alongside the
one key tag `cadv_k_errno = "errno\0"` (N=6). Tag byte counts are
NUL-inclusive per `kernel-logging-substrate.md` discipline (N = len(
string) + 1).

A FAIL line in the test log is intended to be
`grep -i cap_adv.*fail`-able without further parsing, which is why the
tags embed the exact test name verbatim and keep the errno in a
canonical `errno=0x<hex>` KV.

## 5  Run-all packing

`_ca_run_all()` iterates all five tests and returns a packed `u64`:

```
bits [63:32] = fail_mask    (bit i set iff test i returned non-OK)
bits [31:0]  = pass_count   (0..5)
```

Packing lets a userspace reader decode in two cheap moves:

```c
fail_mask  = result >> 32;
pass_count = result & 0xFFFFFFFF;
```

A healthy harness returns `(0 << 32) | 5 == 5`. Any non-zero high half
is an immediate regression signal; the low half tells an operator how
many of the invariants still hold while a fix is prepared.

`_ca_run_all` also bumps two stats-pool slots: `CADV_ST_RUN_ALL_
INVOKED` (unconditional) and `CADV_ST_ANY_FAIL` (iff `fail_mask != 0`
at the tail). A boot-time observer that wants a single counter to
watch for cap-flow regressions can hook on `CADV_ST_ANY_FAIL`.

## 6  Parent capability fixture

Each test needs a well-formed parent capability to derive from. The
fixture is a 24-byte row in `cap_table` at a slot in `[100, 110)`:

```
kind       = CADV_PARENT_KIND       (0xAD, "adversary")
rights     = test-specific (0x001 narrow, 0xFF wide)
target_ptr = CADV_PARENT_TARGET     (0xBEEF, placeholder)
```

The kind `0xAD` is deliberately NOT a registered dispatch arm anywhere
in `cap/invoke.pdx`. Band audit on 2026-10-14:

```
$ grep -rnE 'cmp rcx, 0xAD\b' src/kernel/ 2>/dev/null
(empty)
$ grep -rnE 'KIND_[A-Z_]*\s*=\s*0xAD\b' src/kernel/ 2>/dev/null
(empty)
```

A ring-3 `cap_invoke` against this row would return
`INVOKE_UNSUPPORTED` (0xFFFF...FC), which is correct: the fixture
exists only to satisfy `_cap_minter_derive`'s `parent_kind != 0`
validation at step 6. The derive path writes a NEW `cap_table` row
(not this one) via `cap_mint_write`, so the fixture's semantic
underspecification does not affect what the daemon sees downstream.

The slot range `[100, 110)` sits in the gap between low-slot kernel
mints (0..99) and the cap-minter's own derived-cap range (`[192, 256)`
per `svc/cap_minter.pdx` §3). All five tests use slot 100; the extra
slots up to 110 are reserved for a future multi-parent case (e.g. a
"derive child whose parent's parent is revoked" scenario that needs
TWO distinct parent fixtures).

## 7  Active-env handling

`_cap_minter_derive` resolves the caller env through the ambient global
`_cap_minter_active_env` (`svc/cap_minter.pdx` §2). Each test sets the
ambient env to its own fresh handle at entry and resets it to
`CM_ENV_NONE` (0xFF) at exit. No test depends on a prior test's
setting; `_ca_run_all` runs the five tests back-to-back and the final
active-env state is `CM_ENV_NONE`.

A production boot that invokes `_ca_run_all` BEFORE user-space is up
therefore leaves the ambient env in the exact state `_cap_minter_init`
writes (`CM_ENV_NONE`), making the harness invisible to any
subsequent caller.

## 8  How to add a new case

The harness is append-only in five concrete edits:

1. **Add a bit index** `CA_TEST_<NAME>` after `CA_TEST_REVOKE_BLOCKS_USE`
   and bump `CA_TEST_COUNT`.
2. **Add two fingerprint tag literals** -- one PASS, one FAIL -- with
   `N = len(string) + 1` (the trailing NUL counts). Example for a
   hypothetical `frozen_env` case:

   ```
   // "CAP_ADV frozen_env PASS" -> 8+10+1+4 = 23, +1 NUL => N=24
   pub let cadv_tag_frozen_env_pass : [u8; 24] = "CAP_ADV frozen_env PASS\0"
   pub let cadv_tag_frozen_env_fail : [u8; 24] = "CAP_ADV frozen_env FAIL\0"
   ```

3. **Reserve a stats slot** (`CADV_ST_FROZEN_OK`) if the new case
   should land in the stats pool. The pool is 8 slots and six are
   currently in use (five test-OK slots + `RUN_ALL_INVOKED` +
   `ANY_FAIL`); past slot 7, grow the array in the state block.
4. **Write `_ca_test_<name>()` -> u64** following the shape of the
   five existing tests: setup → invoke daemon surface → capture errno
   → cleanup → `cadv_classify_and_emit(expected, actual, pass_tag,
   fail_tag)`. The classify helper is the only correct way to emit
   the fingerprint and compute the result code -- do not inline it,
   because the FAIL/UNEXPECTED_SUCCESS discrimination belongs in one
   place.
5. **In `_ca_run_all`**, add a `call _ca_test_<name>` + bit/count
   update arm BEFORE the final `shl r12, 32` packing. Each arm follows
   the same shape:

   ```
   cadv_ra_t4:
     call _ca_test_<name>;
     cmp rax, 0;
     jne cadv_ra_t4_fail;
     add rbx, 1;
     jmp cadv_ra_done;
   cadv_ra_t4_fail:
     mov r10, 32;         // bit 5 (next free)
     or  r12, r10;
   cadv_ra_done:
     ...
   ```

   OR-with-imm is staged via a scratch register because paideia-as
   emits only reg-reg `or`. Bit position is `1 << CA_TEST_<NAME>`.

### 8.1  Shape rules the harness enforces by convention

* **Isolation.** Every test allocates and destroys its own env(s) and
  clears its parent fixture. No test depends on another's state. This
  property is what makes the harness runnable in any order and from
  any boot phase.
* **Determinism.** Every expected errno is a single pinned value from
  the daemon's return band; a test that could legitimately observe
  more than one errno is a design smell -- split into two cases, each
  with a single expected value.
* **One klog line per test.** `cadv_classify_and_emit` emits exactly
  one line. A test that fires auxiliary klog traffic (e.g. a debug
  print at setup) muddles the audit grep and should be refactored.
* **No boot hook from the harness.** The call-site decision belongs
  in whoever drives the harness, not in the harness itself. Running
  during `kernel_main.pdx` boot is a reasonable choice but not the
  only one; a `KIND_FUZZ`-style ring-3 driver is a future call-site.

## 9  Encoder-pitfall posture

Standard R125/R141 posture, re-stated for this file's audit:

* Labels prefixed `cadv_` (reserved-word discipline -- `loop`/`if`/
  `let` are keywords; `ca_` prefix is already taken by cmd_audit).
* No `test rN, rN` -- all zero/liveness tests use `cmp rN, 0`.
* No 2-op `imul r, imm` -- stride 24 composed as `(slot<<3)+(slot<<4)`.
* No `and r, imm64` -- every mask fits imm32.
* No `or r, imm` -- paideia-as encoder gap. Immediate ORs are staged
  through a caller-save scratch (`mov r10, imm; or r12, r10`).
* All `pub let` string decls are single-line.
* Module basename `CapAdversary` matches file basename
  `cap_adversary.pdx`.
* Fingerprint `[u8; N]` strings have `N = string length + 1` (NUL
  counts). Each tag's N is spelled next to the literal for audit.
* Return constants `CA_ADV_OK` (0), `CA_ADV_UNEXPECTED_SUCCESS`
  (0x2500), `CA_ADV_UNEXPECTED_ERRNO` (0x2501) all fit `imm32`.
* Packed-return high half via `shl rN, 32` (power-of-two shift).

Stack discipline (SysV, entry `rsp%16==8`):

| function                     | pushes      | extra          | rsp%16 at call |
|------------------------------|-------------|----------------|----------------|
| `cadv_note`                  | 0           | -              | leaf           |
| `cadv_mint_parent`           | 0           | sub rsp, 8     | 0              |
| `cadv_clear_cap_slot`        | 0           | -              | leaf           |
| `cadv_classify_and_emit`     | 3 (b/12/13) | -              | 0              |
| `_ca_test_narrow_only`       | 2 (b/12)    | sub rsp, 8     | 0              |
| `_ca_test_bad_parent`        | 2 (b/12)    | sub rsp, 8     | 0              |
| `_ca_test_env_full`          | 3 (b/12/13) | -              | 0              |
| `_ca_test_cross_env_leak`    | 3 (b/12/13) | -              | 0              |
| `_ca_test_revoke_blocks_use` | 4 (b/12/13/14) | sub rsp, 8  | 0              |
| `_ca_run_all`                | 2 (b/12)    | sub rsp, 8     | 0              |

## 10  Interaction with surrounding milestones

* **R125.M1 (KIND_CAP_ENV substrate).** The harness drives every one
  of M1's supervisor entrypoints (`cap_env_create`, `cap_env_insert`,
  `cap_env_destroy`, `cap_env_lookup`) and the FROZEN flag (indirectly,
  via the derive step-8 check that would fire if any test accidentally
  froze its env).
* **R125.M2 (svc.cap-minter).** The harness drives
  `_cap_minter_set_active_env`, `_cap_minter_derive`, and -- via the
  revoke test -- the step-6 `parent_kind != 0` check that closes the
  revoked-cap-reuse hole.
* **R125.M3 (ELF `.caps.decl`).** The harness does not exercise M3
  directly. A follow-on milestone could add an `.caps.decl` fuzz
  entry (parallel to `_fuzz_wit_bridge` in R141.M3) that feeds
  malformed decl tables through `caps_decl_apply`; this is left out
  of M4 because the harness and the fuzz loop target different layers.
* **R125.M4 (`_syscall_cap_check`).** The harness does not call the
  syscall-entry gate. A follow-on milestone could add a
  `_ca_test_syscall_gate` case that inserts a rights-mask directly
  into an env slot and verifies the gate's `(stored & required) ==
  required` check against both satisfying and non-satisfying masks.
* **R141.M1 (microbench).** The harness runs OUTSIDE the microbench
  bracket. A follow-on milestone could register `_ca_run_all` as a
  microbench site so the per-run cost is tracked over time.
* **R141.M2 (perf-sink).** The harness emits via `klog_s1` and
  `klog_s1_x1`; those go through the same subsystem routing as every
  other kernel klog, so `PERF SITE` dumps are unaffected.
* **R141.M3 (fuzz entries).** The harness is independent of the fuzz
  layer. A future milestone could expose each `_ca_test_*` as a fuzz
  entry (with no corpus -- a single-case entry) so the fuzz-entry
  catalogue's observability (count, min, max, mean) covers the
  adversary runs.

## 11  Open questions deferred to a successor

* **Boot wiring.** Should `_ca_run_all` be called from `kernel_main.
  pdx` at every boot, gated behind a build flag, or left as a manual
  invocation? The present landing takes the third option; a successor
  can promote it once the UMB-W23 landing has observed enough boots
  to confirm no regressions in the per-test cleanup paths.
* **Multi-core.** The harness is single-threaded. Once R125 lifts its
  single-flow substrate (R125.M4+), a successor milestone must
  parallelise -- either by running N instances concurrently against
  disjoint env ranges, or by weaving a cross-core contention witness
  into each test.
* **Lineage.** When R128 lands lineage tracking, test 4's
  `cadv_clear_cap_slot` can be replaced by `cap_revoke_lineage`, and
  a new test can be added for cascade semantics (a revoked parent
  implicitly revokes its children). The present landing is forward-
  compatible: `cadv_clear_cap_slot` matches the generic revoke-sweep
  shape in `cap/owner.pdx`.
* **Dispatched-kind invoke.** Test 4 uses derive-as-invoke because
  `kind=0xAD` has no dispatcher arm. Once a dispatched test-only kind
  is wired (e.g. a `KIND_NO_OP` whose handler returns a fixed value
  for every op), the test can switch to a real `cap_invoke` and
  exercise the full ring-3 reach path.

## 12  Audit summary

* File: `src/kernel/core/perf/cap_adversary.pdx` (~1085 LOC including
  the per-section commentary; the compiled body is ~450 asm lines
  across one module).
* Module: `CapAdversary`.
* Public symbols: 5 test entries + 1 run-all + 1 classify helper +
  2 fixture helpers (mint/clear) + 1 stats note + constants/tags.
* Band audit: 0x2500/0x2501 clean in `src/kernel/` on 2026-10-14.
* Kind audit: 0xAD not used as a kind constant or dispatch arm in
  `src/kernel/` on 2026-10-14.
* Parent-slot audit: `cap_table` slots `[100, 110)` have no live
  producers in `src/kernel/` on 2026-10-14.
