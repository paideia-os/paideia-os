# PaideiaOS — Shell: Light vs Heavy Dispatch (R222.M6)

**Status:** Draft v0.1 — landed Wave 123
**Date:** 2026-10-15
**Scope:** Load-time dispatch-mode classifier for the semantic shell.
At every REPL dispatch the framework reads a command's declared
resource needs from its `CommandSig` record and decides whether to
elaborate the functor IN-PROCESS (LIGHT) or SPAWN a separate process
to host the functor's effects (HEAVY). The classification is a pure
function of the record; the actual invocation flows through two
disjoint weak-import seams the kernel-side substrate publishes at
session boot.

**Upstream:** paideia-os#2486 (R222 cmd-functor umbrella),
paideia-os#2663 (R222.M6 light/heavy dispatch).
**Module:** `tools/user/libpdx-pds-parser/src/dispatch_mode.pdx`
module `DispatchMode`.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| DM-D1 | Resource-need declaration lives in a `resource_mask` u32 at offset 84 of the CommandSigHeader | Reserved-slot carve-out out of the 44-byte reserved region at `[CS_HEADER + 84 .. +128)`; no ABI break with R222.M2 CommandSig consumers that read only the first 84 bytes; `caps_offset` / `caps_len` at offsets 72 / 76 are untouched |
| DM-D2 | Six resource bits: FS_READ (1), FS_WRITE (2), NET (4), EXEC (8), LONG_RUNNING (16), HIGH_MEM (32) | The three cheap FS bits are not escalation triggers (shell builtins read + write pervasively); NET / EXEC / LONG_RUNNING / HIGH_MEM each independently warrant process isolation |
| DM-D3 | HEAVY iff `resource_mask & 0x3C != 0`; else LIGHT | The 0x3C mask is `NET \| EXEC \| LONG_RUNNING \| HIGH_MEM`; a command that declares none of those is LIGHT regardless of its FS-touch pattern. Encodes identically to the brief's two-condition shape and lets the classifier be a single `and r, imm8` + branch (per `feedback_pdx_encoder_pitfalls`, imm8 variants of `and` are permitted) |
| DM-D4 | Two disjoint weak-import function slots: `_dm_light_fn` for the in-process invoker, `_dm_spawn_fn` for the kernel-side spawn seam | Mirrors the R133.M5 `_tcg_check_fn` / R133.M6 `_sc_dispatch_fn` precedent byte-for-byte. The pdx dialect lacks linker-level weak imports; the `.bss` function-pointer slot is the convention. The two execution paths are independent so each gets its own slot and registration primitive |
| DM-D5 | Classifier is a pure leaf; dispatcher validates record + indirect-calls through the weak-import slot | `_dm_classify` has no nested CALL and no .bss write; `_dm_dispatch` CALLs `_dm_classify` then indirect-calls either `[_dm_light_fn]` or `[_dm_spawn_fn]`. Separating classification from invocation lets callers who need only the policy decision (planners, cost estimators, test fixtures) skip the invocation half |
| DM-D6 | Per-decision counters as the dispatch fingerprint | User-space satellite modules in `libpdx-pds-parser` have no klog surface. Two u64 counters (`_dm_light_count`, `_dm_heavy_count`) plus a `_dm_last_decision` sentinel let a smoke-mode asserter observe the 4-command acceptance test's distribution. The counters are append-only within a session; `_dm_init` resets them |
| DM-D7 | `dm_` label prefix | Grep-confirmed free of linker-visible symbol collisions against the eighteen prior parser-tier label prefixes (`u8n_`, `gi_`, `wp_`, `cl_`, `sch_sig_`, `cmd_sig_`, `fi_`, `afs_`, `cmdreg_`, `pl_`, `rp_`, `ll_`, `cc_`, `er_`, `cr_`, `hm_`, `rt_`, `dl_`, `se_`, `te_`, `ls_`, `ast_`). The lone `dm_*` labels found at grep time (`dm_pud_divide_setup` / `dm_fail` in `src/user/dmesg.pdx`) are function-scoped so they do not share a linker-visible namespace |

---

## 1. Resource-need declaration

A command's `CommandSig` record (R222.M2) carries a `resource_mask`
u32 at offset 84 of its 128-byte header:

```
CommandSigHeader (128 B, R222.M2 ABI):
  [+0..+4)    magic         u32 = 'CSIG' (0x47495343)
  [+4..+5)    n_caps        u8
  [+5..+6)    stability     u8
  [+6..+7)    name_len      u8
  [+7..+8)    version_len   u8
  [+8..+56)   name_inline   u8[48]
  [+56..+72)  version_inline u8[16]
  [+72..+76)  caps_offset   u32  (= 128)
  [+76..+80)  caps_len      u32  (= n_caps * 32)
  [+80..+84)  flags         u32  (R222.M2 flag bits 0x01/0x02/0x04)
  [+84..+88)  resource_mask u32  (R222.M6 -- THIS landing)
  [+88..+128) reserved      u8[40]
```

The slot was reserved at R222.M2 landing as part of a 44-byte
reserved tail "for R222.M3+ (effect-row id, cap-row id, source span,
etc.)." R222.M6 claims the first 4 bytes of that tail without
disturbing any R222.M2..M5 consumer: every landed reader of the
header stops at offset 84 (`flags u32`), and the fingerprint pipeline
(R222.M8) ingests the whole 128-byte header verbatim, so the field
carrying new data is already covered by the fingerprint over the
record.

Bit layout:

| Bit | Mask    | Name           | Meaning |
|-----|---------|----------------|---------|
|  0  | `0x01`  | `FS_READ`      | reads filesystem bytes |
|  1  | `0x02`  | `FS_WRITE`     | writes filesystem bytes |
|  2  | `0x04`  | `NET`          | makes outbound network connections |
|  3  | `0x08`  | `EXEC`         | invokes other processes |
|  4  | `0x10`  | `LONG_RUNNING` | may run past the shell's per-turn deadline |
|  5  | `0x20`  | `HIGH_MEM`     | retains a working set larger than the shell's in-process arena |

Bits 6..31 are reserved. A command's TOML or `#resource` directive
sets any subset of these bits; the TOML-side bind layer that fills
the `resource_mask` field lives at R222.M6.5 (deferred, follows the
`#capability` bind precedent R133.M2 landed for the cap mask).

---

## 2. Light vs heavy decision

The classification mask is

```
DM_HEAVY_MASK = NET | EXEC | LONG_RUNNING | HIGH_MEM
              = 0x04 | 0x08 | 0x10 | 0x20
              = 0x3C
```

The decision rule:

```
decision = (resource_mask & DM_HEAVY_MASK == 0) ? LIGHT : HEAVY
```

- `resource_mask == 0` → `(0 & 0x3C) == 0` → LIGHT (the trivial case).
- Pure read-only shell builtins (`where`, `sort`) declare at most
  `FS_READ` → `(0x01 & 0x3C) == 0` → LIGHT.
- Filesystem traversal (`find`) declares `FS_READ | LONG_RUNNING` →
  `(0x11 & 0x3C) == 0x10` → HEAVY.
- Byte-pattern search over a traversal (`grep`) declares `FS_READ |
  LONG_RUNNING` or `FS_READ | EXEC | LONG_RUNNING` → HEAVY either way.

The classifier is a single branch over a single `and r, imm8`. No
2-op `imul r, imm` is needed; no `and r, imm64` is needed (the mask
is `0x3C`, an imm8 with bit 7 clear).

---

## 3. Dispatcher weak-import seams

```
.bss  _dm_light_fn   : u64      // in-process invoker ptr (0 = unregistered)
.bss  _dm_spawn_fn   : u64      // spawn invoker ptr (0 = unregistered)
```

Both slots are nil at session boot. Two one-shot registration
primitives publish each:

```
_dm_register_light(fn_ptr) -> u64
_dm_register_spawn(fn_ptr) -> u64
```

Returns `DM_OK` on publish; `DM_ERR_NULL_FN` on `fn_ptr == 0`.

Both registered functions share one ABI:

```
fn_ptr(cs_body, cs_len, mat_body, mat_len) -> u64
    returns 0 on success, non-zero errno on failure.
```

The caller passes:
- `cs_body` / `cs_len`: the CommandSig record (R222.M2 output).
- `mat_body` / `mat_len`: the FunctorInstance materialization record
  (R222.M3 output) with the elaborated arguments.

The two seams are deliberately independent: nothing stops a session
from registering only `_dm_light_fn` and leaving `_dm_spawn_fn` nil
(a shell variant that refuses heavy commands) or vice versa.

### Rationale for two seams rather than one

The brief lists `_dm_spawn_fn` by name. The LIGHT execution path
also goes through a function pointer because the actual in-process
functor invoker is a separately-shipped artefact (R222.M8 OOP ABI
in the kernel-side shell / R131 pds-loader) that is not linked
against `libpdx-pds-parser`. The symmetrical two-slot shape mirrors
how the kernel-side pds pipeline (R133.M5 typecheck gate +
R133.M6 script-cmd) exposes gates: each gate is a `.bss` slot plus
a one-shot register fn. A single-slot variant that multiplexes
`(decision, fn_ptr)` through one pointer would be denser but would
also force a shared ABI on the two execution paths; the current
layout keeps them disjoint.

---

## 4. Public API

```
_dm_init() -> ()
  Idempotent boot. Clears both weak-import slots and both decision
  counters. .bss zero-init at program load already satisfies this;
  the explicit init supports a test harness that wants to reset
  the counters between runs. Pure leaf.

_dm_register_light(fn_ptr) -> u64
_dm_register_spawn(fn_ptr) -> u64
  Publish the function pointer into the matching .bss slot.
  Returns DM_OK on success, DM_ERR_NULL_FN on nil fn_ptr.
  2-push callee-save frame + 8-byte alignment pad (sysV).

_dm_classify(cs_body, cs_len) -> u64
  Returns:
    DM_LIGHT (0)         if (resource_mask & DM_HEAVY_MASK) == 0
    DM_HEAVY (1)         else
    DM_ERR_BAD_RECORD (0x4800) if cs_body == 0, cs_len < 128, or
                               magic != CSIG (0x47495343).
  Pure leaf; no .bss write, no nested CALL. The caller is free to
  consume this classification without invoking either dispatcher
  (e.g. the planner / cost estimator / smoke-mode asserter).

_dm_dispatch(cs_body, cs_len, mat_body, mat_len) -> packed_u64
  Classify, bump the matching decision counter, then indirect-call
  the matching weak-import slot. Returns:
    bits [15: 0] status (DM_OK or DM_ERR_*)
    bit  [16]    decision (0 = LIGHT, 1 = HEAVY)
    bits [63:32] downstream errno on *_FAILED paths; 0 otherwise.
  Nested-CALL frame: 4 callee-save pushes + sub rsp, 8 pad = rsp%16==0
  at the one classifier call and at the single indirect dispatcher
  call.
```

### Register map (SysV)

```
_dm_init()                                       -> rax (ignored)
_dm_register_light(rdi)                          -> rax
_dm_register_spawn(rdi)                          -> rax
_dm_classify(rdi, rsi)                           -> rax
_dm_dispatch(rdi, rsi, rdx, rcx)                 -> rax
```

---

## 5. Status codes (band 0x4800..0x48FF)

| Code                     | Value   | Meaning |
|--------------------------|---------|---------|
| `DM_OK`                  | 0       | operation / dispatch succeeded. |
| `DM_LIGHT`               | 0       | classifier returned LIGHT (same value as OK). |
| `DM_HEAVY`               | 1       | classifier returned HEAVY. |
| `DM_ERR_BAD_RECORD`      | 0x4800  | `cs_body == 0`, `cs_len < 128`, or magic mismatch. |
| `DM_ERR_NO_LIGHT_FN`     | 0x4801  | LIGHT path requested but `_dm_light_fn == 0`. |
| `DM_ERR_NO_SPAWN_FN`     | 0x4802  | HEAVY path requested but `_dm_spawn_fn == 0`. |
| `DM_ERR_NULL_FN`         | 0x4803  | registration called with `fn_ptr == 0`. |
| `DM_ERR_LIGHT_FAILED`    | 0x4804  | `_dm_light_fn` returned non-zero errno. |
| `DM_ERR_SPAWN_FAILED`    | 0x4805  | `_dm_spawn_fn` returned non-zero errno. |
| `DM_ERR_BAD_MAT`         | 0x4806  | `mat_body == 0` or `mat_len < 64` (FunctorInstance header min). |

The 0x4800..0x48FF band is reserved for the dispatch-mode landing;
slots 0x4807..0x48FF are reserved for M6.5+ follow-ups (per-cost
budget violation, cross-session dispatch policy, cap-mask narrowing
mismatch). Disjoint from every landed Wave-120..122 band:

- `0x4000..0x40FF` R224.M3 EffectRow
- `0x4200..0x42FF` R221.M4 CtxLexer
- `0x4300..0x43FF` R224.M4 CapRow
- `0x4400..0x44FF` R221.M5 Ast
- `0x4500..0x45FF` R222.M5 CmdRegistry
- `0x4600..0x46FF` R224.M5 LetScope
- `0x4700..0x47FF` parallel R221.M6 span-mapping NFC variant (reserved)
- `0x4800..0x48FF` R222.M6 DispatchMode (THIS landing)

The 0x4700..0x47FF slot is reserved for the parallel Wave-123 R221.M6
arm; the two Wave-123 arms sit on adjacent kilo-step boundaries
disjoint from every prior landed band.

---

## 6. Fingerprint surface

Three u64 .bss counters record the dispatch sequence a session has
observed:

```
_dm_light_count    : u64   // bumped on each DM_LIGHT dispatch
_dm_heavy_count    : u64   // bumped on each DM_HEAVY dispatch
_dm_last_decision  : u64   // 1 = LIGHT, 2 = HEAVY, 0 = never dispatched
```

A smoke-mode asserter observes the three counters to anchor the
4-command acceptance test:

```
after `where <path>`      : light=1, heavy=0, last=1
after `sort <field>`      : light=2, heavy=0, last=1
after `find . -name foo`  : light=2, heavy=1, last=2
after `grep pattern file` : light=2, heavy=2, last=2
```

The counters survive across the per-command boundary because the
weak-import adapters run in the same process; a session teardown
re-calls `_dm_init` to reset them.

Rationale for a counter-based fingerprint over a klog emit: user-
space satellite modules in `libpdx-pds-parser` have no klog surface
(the kernel-side `klog_s1` is not linked into user-space objects).
A data-based fingerprint matches the parser-tier precedent --
every .bss state the library exposes is itself a fingerprint.

---

## 7. Encoder discipline (per `feedback_pdx_encoder_pitfalls`)

- No `test rN, rN`; every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64`; the one `and` immediate is `0x3C` which fits
  in imm8 (bit 7 clear). The imm8 variant of `and r64, imm8` is
  permitted (precedent: `grapheme_iter.pdx` line 335
  `and r11, 0xFF`).
- No 2-op `imul r, imm`. No multiply is needed in this module: the
  classifier and both registration helpers are pure byte / u64
  loads and compares.
- No multiline `pub let = "..."`; justifications are single-line.
- Module basename `DispatchMode` matches `dispatch_mode.pdx`.
- Label prefix `dm_` (unique against the parser-family's 22 prior
  prefixes; grep-confirmed at landing time).
- Reserved-word labels (`loop`, `if`, `let`, `fn`, `ret`, `done`)
  are never bare -- every label is prefixed `dm_`.
- All `cmp reg, imm` immediates (0, 1, 64, 128, 0x3C, status codes
  0x4800..0x4806, magic 0x47495343) fit imm32 with bit 31 clear.
  The CSIG magic (0x47495343) is below the imm32 sign-extension
  boundary (< 0x80000000) so `cmp rax, 0x47495343` is sign-safe.
- Byte loads via `xor rN, rN; mov_b rN, [base + idx]` (zero-extends
  into the full qword).
- u32 loads via `mov_d rN, [base + disp]` (precedent: arg_flag_spec
  `_afs_classify_invocation` line 1703).
- u64 reads of module .bss via `lea r11, [rip + sym]; mov rax, [r11]`
  (precedent: cmd_registry.pdx line 379, cap_row.pdx line 407).
- Indirect CALL via `mov rax, [slot_ptr]; call rax` (precedent:
  script_cmd.pdx line 660).

---

## 8. Register-liveness discipline

The module has three nested-CALL sites. r11 is clobbered by every
nested CALL; every value that must survive a CALL lives in r12..r15
or in the module's own .bss.

- `_dm_register_light` / `_dm_register_spawn`:
  2 callee-save pushes (rbx = fn_ptr, r12 pad) + `sub rsp, 8` for
  the klog alignment pad (unused in user-space; retained for
  symmetry with the script_cmd precedent). Entry rsp%16==8, +16
  pushes = %16==8, +8 pad = %16==0 at the (currently absent) klog
  CALL -- the user-space variant never actually CALLs klog; the
  pad is cosmetic and could be dropped at M6.1 when the pattern
  is reaudited.

- `_dm_classify`:
  Pure leaf. Zero callee-save pushes; zero stack frame; zero nested
  CALL. Register plan: r8 = cs_body, r9 = cs_len, rax = scratch for
  the magic compare and the u32 resource_mask load.

- `_dm_dispatch`:
  4 callee-save pushes (rbx = cs_body, r12 = cs_len, r13 = mat_body,
  r14 = mat_len) + `sub rsp, 8` pad = 40 B frame; entry rsp%16==8,
  +32 pushes = %16==8, +8 pad = %16==0 steady at the nested CALL
  into `_dm_classify` and at the indirect CALL through the weak-
  import slot. The decision byte returned by `_dm_classify` lands
  in rax; the dispatcher restores rdi/rsi/rdx/rcx from the callee-
  save bay for the indirect-call ABI.

---

## 9. Acceptance (4-command test)

The smoke-mode anchor exercises exactly four commands with
pre-populated CommandSig records:

| Command | `resource_mask` | Expected decision |
|---------|-----------------|-------------------|
| `where` | `0x01` (FS_READ)                        | LIGHT  |
| `sort`  | `0x01` (FS_READ)                        | LIGHT  |
| `find`  | `0x11` (FS_READ \| LONG_RUNNING)        | HEAVY  |
| `grep`  | `0x19` (FS_READ \| EXEC \| LONG_RUNNING) | HEAVY  |

Post-sequence assertions:

```
_dm_light_count    == 2
_dm_heavy_count    == 2
_dm_last_decision  == 2 (HEAVY)
```

The weak-import slots are stubbed at test time with recording
callbacks that always return 0; the dispatcher's return value is
`DM_OK | (decision << 16)` in each case.

The test corpus + proptest harness is filed as the deferred
R222.M6-003 (`tests/proptest_dispatch_mode.pdx`); the enumeration
above is the spec the late-landing harness goldens from.

---

## 10. Forward path

- R222.M6.1 — drop the cosmetic alignment pad in the two
  `_dm_register_*` prologues once the kernel-side symmetry audit
  closes.
- R222.M6.5 — commands.toml bind layer that fills `resource_mask`
  from a `#resource` directive at session boot. Mirrors R133.M2's
  cap-mask bind pass; shares the TOML parse infrastructure.
- R222.M6.6 — per-cost budget violation code (0x4807) and
  `_dm_dispatch_with_budget` variant. The budget semantics live
  with R222.M8 (`describe <cmd>`) which also surfaces the cost
  envelope.
- R222.M7 — fuzz corpus for the four-arm cmd-functor family
  (SchemasSig + CommandSig + FunctorInstance + ArgFlagSpec).
- R222.M8 — `describe <cmd>` serialisation renders the
  `resource_mask` bits as a human-readable string
  (`"fs_read, long_running"`) alongside the cap list.

---

## 11. Open questions

- **DM-O1** — Should a session be allowed to re-register a slot
  mid-run? At M6 the registration primitive overwrites the existing
  slot verbatim; a session-level policy that would make the slot
  write-once (and surface a `DM_ERR_ALREADY_REGISTERED` on the
  second attempt) is a defensible tightening. Left open at M6 for
  the symmetry with script_cmd (R133.M6) which also permits
  overwrite.
- **DM-O2** — The counters are per-process, not per-session.
  A multi-session shell (session daemon pattern) that wants per-
  session fingerprint will land a counter-per-session table at
  M6.7, keyed by session id. The current single-counter shape is
  adequate for the single-session smoke-mode asserter.
- **DM-O3** — Should the classifier error path `DM_ERR_BAD_RECORD`
  also surface the specific invariant that failed (null cs_body
  vs cs_len too small vs magic mismatch)? At M6 the three failure
  modes collapse into one code to minimise the status-band width.
  A diagnostic refinement at M6.2 would split them.

---

## 12. References

- `design/shell/cmd-functor-command-sig.md` — the R222.M2 CommandSig
  record this module reads `resource_mask` out of.
- `design/shell/command-registry-client.md` — the R222.M5 registry
  this module is called downstream of (`_cmdreg_lookup` returns
  the `cs_body_ref` the dispatcher classifies).
- `design/terminal/semantic-shell-language-plan.md` §R222 — the
  umbrella view of the cmd-functor landings.
- `src/kernel/core/pds/script_cmd.pdx` — the R133.M6 weak-import
  precedent (`_sc_dispatch_fn` slot + `_pds_sc_register_dispatcher`
  publisher) this module's `_dm_*_fn` slots mirror.
