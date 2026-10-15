# Nested lambda + `let` / `let rec` scoping — R224.M5

**Issue:** paideia-os#2679
**Umbrella:** R224 (lambda-lang, paideia-os#2488)
**Satellite:** `tools/user/libpdx-pds-parser` (user-space; `src/let_scope.pdx`)
**Upstream substrate:** R225.M1 HmCore (`design/shell/hm-algorithm-w-core.md`,
`src/hm_core.pdx` — type-scheme storage) + R229.M3 TypeEnv
(`design/shell/type-env-threading.md`, `src/type_env.pdx` — the
polymorphic-scheme payload that the raw-M5 u32 `type_scheme_ref`
upgrades to at the M5.1 wire-up).
**Design axis:** Standard Hindley–Milner shadowing on a stack-of-frames
pool, with recursion threaded by `let rec` pre-push of the self-frame
BEFORE the RHS is typed.

**Status at this landing:** M5 lands the user-space working-memory
substrate — a 128-slot ring of 32-byte scope frames with
inner-first parent-chain resolve. The grammar-driver splice-points
(the production rules that drive `_ls_push_let` / `_ls_push_letrec` /
`_ls_push_lambda` from the shape of a parse) are the responsibility
of R221.M5 unified-AST and are the subject of the M5.3 follow-up.
This landing is self-contained and reviewable against its own
12-test acceptance corpus (§7 below).

---

## 1 · Scope and motivation

The semantic-shell plan
(`design/terminal/semantic-shell-language-plan.md` §R224.M5)
specifies that nested lambdas and `let` / `let rec` bindings follow
**standard HM shadowing** — the inner binding of a name wins within
its lexical scope — and that **recursion** is enabled by `let rec`,
with mutual recursion handled by typing a group of `let rec`-bound
names together before generalisation.

Three design axes considered:

* **Q-A5a — flat lexical name table.** A single hash table keyed by
  name, re-stacked on scope entry/exit. **Rejected.** The pds-shell
  parser is a single-pass byte walker; a stack-of-frames pool
  (one frame per lexical binding) interoperates one-to-one with the
  parse's own recursion over the AST and avoids an O(n) scope-pop
  rehash on frame exit.
* **Q-A5b — persistent scope-env records.** A deep immutable list of
  bindings per node, re-shared on parse tree reuse. **Rejected.**
  Parse-tree reuse is not a current workflow; the straight-line
  cost of a copy-on-push would dominate the resolve cost at R224
  grammar sizes. Postponed to R229.M5 (lexical nested scopes with
  persistent per-user env) when persistence becomes the dominant
  shape.
* **Q-A5c — frame pool with parent chain (THIS M5).** 128-slot ring
  of 32-byte frames; each frame carries one binding and a
  parent_frame_ref u32. Inner-first chain walk returns the first
  match. Memory is bounded (4096 B pool); allocation is append-only
  within a parse; pop is a logical no-op (the enclosing frame
  cursor is restored by the AST driver). **Chosen** because it
  mirrors R225.M1 HmCore's own frame-indexed pool conventions and
  reuses the pool-full / BAD_FRAME / NOT_FOUND diagnostic shape.

The 12-test acceptance corpus from the issue brief is enumerated at
§7 below. The canonical acceptance test is: *in `let x = u64 in let
x = str in x`, the inner `x` resolves to the `str` scheme and the
outer `let x = u64` is naturally shadowed*.

---

## 2 · HM standard semantics

### 2.1 `let` shadowing

```
let x = e1 in                     — push frame F1 (kind=LET,
let x = e2 in                       parent=0, name="x", scheme=T1)
  x                               — push frame F2 (kind=LET,
                                    parent=F1, name="x", scheme=T2)
                                  — resolve "x" at F2 inner-first
                                    hits F2's byte-matching name;
                                    returns T2. F1 is never visited.
```

### 2.2 `let rec` self-recursion

```
let rec f = \x. (f x) in body
```

The elaborator PRE-pushes a SCOPE_LETREC frame for `f` BEFORE typing
the RHS `\x. (f x)` so a free-name resolution of `f` inside the
body of the lambda sees the self-frame. Generalisation of the RHS
defers until the RHS is fully typed (R225.M6).

### 2.3 `let rec` mutual recursion

```
let rec f = \x. g x
    and g = \y. f y
in body
```

The elaborator pushes `f`'s SCOPE_LETREC frame AND `g`'s
SCOPE_LETREC frame BEFORE typing EITHER RHS. Both RHSs see both
names. Generalisation defers until all N RHSs are typed.

M5 asks the caller to loop over `_ls_push_letrec` for the N names.
M5.2 lands a `_ls_push_letrec_group` batch helper that pushes N
frames atomically after validating that all N names fit the 1..16
cap.

### 2.4 Lambda parameter shadowing

```
let x = 42 in
  (\x. x)                         — the lambda's `x` param shadows the
                                    outer `let x` within the lambda
                                    body. Same inner-first rule.
```

A lambda-parameter frame is pushed with kind=SCOPE_LAMBDA so a
later diagnostic can distinguish "shadowed by lambda param" from
"shadowed by nested let".

---

## 3 · Frame record layout

32-byte stride (power-of-2 so addressing uses `shl rN, 5`,
sidestepping the `imul r, imm` pitfall).

| Offset | Size | Field              | Values / notes                                  |
|-------:|-----:|--------------------|-------------------------------------------------|
|  0x00  |  2   | `kind` (u16)       | 1 = SCOPE_LET, 2 = SCOPE_LETREC, 3 = SCOPE_LAMBDA, 0 = slot-unused sentinel |
|  0x02  |  2   | `flags` (u16)      | reserved; 0 at M5. M5.1 may use bit 0 as "scheme_ref is a TypeEnv scheme_id (polymorphic)" and leave bit 0 clear for a HmCore pool_idx (monomorphic). |
|  0x04  |  4   | `parent_frame_ref` (u32) | pool_idx of enclosing frame; 0 = top-level null-sentinel. |
|  0x08  | 16   | `name_inline`      | NFC byte run, right-padded with zero.           |
|  0x18  |  1   | `name_len`         | 1..16 at M5. 0 means slot-unused.               |
|  0x19  |  1   | reserved           | 0.                                              |
|  0x1A  |  2   | reserved           | 0.                                              |
|  0x1C  |  4   | `type_scheme_ref` (u32) | caller-opaque payload. M5: HmCore pool_idx. M5.1: TypeEnv scheme_id when flags bit 0 is set. |

---

## 4 · Pool

* `.bss _ls_frame_pool : [u8; 4096] @align(8)` — 128 slots × 32 bytes.
* `.bss _ls_frame_next : u64 @align(8)` — next-free slot (1..128).

Slot 0 is reserved as the null-sentinel so `parent_frame_ref == 0`
reads as "no enclosing scope". `_ls_init` sets `_ls_frame_next := 1`
on a cold .bss; subsequent calls short-circuit on
`_ls_frame_next != 0`. Pool-full is `_ls_frame_next >= 128`
(27 usable + null-sentinel = 128 total; 127 real frames).

A caller that wants to reset the pool across parse passes
externally writes `_ls_frame_next := 0` and re-calls `_ls_init`;
the .bss zero-init at program load means the frames themselves do
not need to be re-cleared. M5.4 lands an in-library `_ls_reset`
helper if the use-case firms up.

---

## 5 · Public API

```
_ls_init() -> ()
_ls_push_let(parent, name_ptr, name_len, type_scheme_ref) -> frame_ref
_ls_push_letrec(parent, name_ptr, name_len, type_scheme_ref) -> frame_ref
_ls_push_lambda(parent, name_ptr, name_len, type_scheme_ref) -> frame_ref
_ls_resolve(frame_ref, name_ptr, name_len) -> (type_scheme_ref << 32) | errno
_ls_pop(frame_ref) -> parent_frame_ref
```

Status taxonomy:

| Code                      | Hex    | When                                       |
|---------------------------|--------|--------------------------------------------|
| `LS_OK`                   | 0      | success                                    |
| `LS_ERR_POOL_FULL`        | 0x4600 | push on full pool                          |
| `LS_ERR_NOT_FOUND`        | 0x4601 | resolve: chain ended, no byte-match        |
| `LS_ERR_BAD_FRAME`        | 0x4602 | resolve: frame_ref >= 128 or kind==0       |
| `LS_ERR_BAD_NAME`         | 0x4603 | push or resolve: name_len == 0 or > 16     |
| `LS_ERR_BAD_KIND`         | 0x4604 | push_impl: kind not in {1,2,3} (internal)  |

Diagnostic-family mapping (E0830 family):

| Diagnostic                 | Status code      |
|----------------------------|------------------|
| `E0830_NAME_NOT_FOUND`     | `LS_ERR_NOT_FOUND` (0x4601) |
| `E0831_BAD_FRAME`          | `LS_ERR_BAD_FRAME` (0x4602) |
| `E0832_BAD_NAME`           | `LS_ERR_BAD_NAME`  (0x4603) |
| `E0833_POOL_FULL`          | `LS_ERR_POOL_FULL` (0x4600) |
| `E0834_BAD_KIND`           | `LS_ERR_BAD_KIND`  (0x4604) |

Push functions return the raw frame_ref `u64` (0 on error);
`_ls_resolve` returns a packed `(ref << 32) | errno`. `_ls_pop`
returns the raw parent_frame_ref `u64`.

---

## 6 · Pool encoding + resolve algorithm

### 6.1 Push

```
_ls_push_impl(parent, name_ptr, name_len, type_scheme_ref, kind):
  call _ls_init                               # idempotent lazy init
  if name_len == 0 or name_len > 16: return 0
  if kind not in {1,2,3}:            return 0
  if _ls_frame_next >= 128:          return 0

  idx = _ls_frame_next
  addr = &_ls_frame_pool + idx * 32

  write kind u16            at addr + 0
  write flags u16 = 0       at addr + 2
  write parent u32          at addr + 4
  copy name_len bytes       to addr + 8
  zero-pad to 16 bytes      at addr + 8 + name_len
  write name_len u8         at addr + 24
  write 0 u8                at addr + 25
  write 0 u16               at addr + 26
  write type_scheme_ref u32 at addr + 28

  _ls_frame_next := idx + 1
  return idx
```

### 6.2 Resolve

```
_ls_resolve(frame_ref, name_ptr, name_len):
  call _ls_init                               # idempotent lazy init
  if name_len == 0 or name_len > 16: return LS_ERR_BAD_NAME

  cursor = frame_ref
  loop:
    if cursor == 0:               return LS_ERR_NOT_FOUND
    if cursor >= 128:             return LS_ERR_BAD_FRAME

    addr = &_ls_frame_pool + cursor * 32
    kind = u16 at addr + 0
    if kind == 0:                 return LS_ERR_BAD_FRAME

    this_name_len = u8 at addr + 24
    if this_name_len == name_len:
      bytes_match = memcmp(addr + 8, name_ptr, name_len)
      if bytes_match:
        return (type_scheme_ref << 32) | LS_OK

    cursor = parent_frame_ref u32 at addr + 4
    continue
```

### 6.3 Pop

```
_ls_pop(frame_ref):
  if frame_ref == 0:            return 0
  if frame_ref >= 128:           return 0
  addr = &_ls_frame_pool + frame_ref * 32
  return parent_frame_ref u32 at addr + 4
```

The slot is NOT freed; the pool is append-only within a parse pass.
The enclosing cursor is restored by the AST driver (which held it
in a local register BEFORE the push), so `_ls_pop` is a convenience
accessor rather than an allocator primitive. M5.4 lands a
compacting pop that actually reclaims the slot if the use-case
firms up.

---

## 7 · 12-test acceptance corpus

Each test is a sequence of push and resolve calls; the expected
return of the final call is stated. Push `name_ptr` points at the
indicated 1..16-byte NFC byte run; `name_len` is the length of that
run. `type_scheme_ref` payloads are the per-test numeric literals
below.

| # | Scenario                                       | Expected                           |
|---|------------------------------------------------|------------------------------------|
| 1 | push_let(parent=0, "x", 1, scheme=10) → f1; resolve(f1, "x") | `(10 << 32) \| LS_OK`  |
| 2 | push_let(0, "x", 1, 10) → f1; push_let(f1, "y", 1, 20) → f2; resolve(f2, "x") | `(10 << 32) \| LS_OK` |
| 3 | push_let(0, "x", 1, 10) → f1; push_let(f1, "x", 1, 20) → f2; resolve(f2, "x") | `(20 << 32) \| LS_OK` (inner shadow) |
| 4 | push_letrec(0, "f", 1, 30) → f1; resolve(f1, "f") | `(30 << 32) \| LS_OK` (self-rec visible) |
| 5 | push_letrec(0, "f", 1, 30) → f1; push_lambda(f1, "x", 1, 40) → f2; resolve(f2, "f"); resolve(f2, "x") | first `(30 << 32)`, second `(40 << 32)` |
| 6 | push_lambda(0, "x", 1, 40) → f1; push_let(f1, "y", 1, 50) → f2; resolve(f2, "y"); resolve(f2, "x") | `(50 << 32)`, `(40 << 32)` |
| 7 | three nested lets a,b,c; resolve from innermost for each name | all three resolve correctly from the innermost cursor |
| 8 | push_let(0, "x", 1, 10) → f1; resolve(f1, "z") | `LS_ERR_NOT_FOUND` (0x4601) |
| 9 | push_let(0, "x", 1, 10) → f1; pop(f1) | 0 (top-level parent) |
|10 | push 127 lets with distinct names; 128th push | 0 (pool-full)                     |
|11 | resolve(frame_ref=200, "x", 1)                 | `LS_ERR_BAD_FRAME` (0x4602)        |
|12 | push_let(0, "", 0, 10)                         | 0 (BAD_NAME via rax==0)            |

Test 12 exercises the two name-rejection paths (zero-length AND
over-length); the harness variant with `name_len = 17` also
returns 0. Test 10 exercises the pool-full exit — the 128th push
(slot 128) is rejected because slot 0 is the null-sentinel.

A follow-up at R224.M5-005 lands the proptest harness
(`tests/proptest_let_scope.pdx`) that golden-matches these 12 cases
plus a fingerprint over the 32-byte pool bytes of each landed
frame.

---

## 8 · Error band + diagnostic family

Band 0x4600..0x46FF. Five slots used, 251 reserved for M5.1+.

Disjointness:

* R221.M4 CtxLexer: 0x4200..0x42FF
* R221.M5 unified-AST (parallel Wave-122 arm): 0x4400..0x44FF
* R222.M5 CmdRegistry (parallel Wave-122 arm): 0x4500..0x45FF
* R224.M3 EffectRow: 0x4000..0x40FF
* R224.M4 CapRow: 0x4300..0x43FF
* R224.M5 LetScope (THIS): 0x4600..0x46FF
* R133.M6 kernel-side reserved: 0x4100..0x41FF

All adjacent to kilo-step boundaries; disjoint from every other
user-space packed-status band in the paideia-os tree (see
`caps.decl` for the full disjointness proof).

---

## 9 · Linker dependencies

* **No external cross-library dependency.** All six public entry
  points touch only this module's own `.bss` (`_ls_frame_pool`,
  `_ls_frame_next`) and caller-supplied pointer arguments.
* **No intra-library dependency at M5.** Unlike R224.M3 EffectRow
  and R224.M4 CapRow, LetScope does not call into R225.M2 RowTypes
  or R225.M1 HmCore: the `type_scheme_ref` u32 is stored and
  returned verbatim. The R229.M3 TypeEnv + R225.M1 HmCore
  interpretation of the stored u32 is the responsibility of the
  R224.M5-dispatch REPL layer at R229.M4+ wire-up.

All six public entry points can be linked standalone.

---

## 10 · Encoder discipline (ABSOLUTE)

* No `test rN, rN` — zero-checks via `cmp reg, 0; je/jne`.
* No `and rN, imm64` — bounds compares via `cmp r, imm32`.
* No 2-op `imul r, imm` — frame stride 32 is `shl r, 5`.
* No multiline `pub let = "..."` — single-line justifications.
* Module basename `LetScope` matches `let_scope.pdx`.
* Labels prefixed `ls_` with per-function suffix (`ls_ini_`,
  `ls_pi_`, `ls_pl_`, `ls_plr_`, `ls_pla_`, `ls_r_`, `ls_po_`).
  Grep-confirmed disjoint from the sibling parser-tier module
  label prefixes (`u8n_`, `gi_`, `wp_`, `cl_`, `sch_sig_`,
  `cmd_sig_`, `fi_`, `afs_`, `pl_`, `rp_`, `ll_`, `cc_`, `er_`,
  `cr_`, `hm_`, `rt_`, `dl_`, `se_`, `te_`). Never bare `loop`,
  `if`, `let`, `fn`, `ret`, `done`.
* All `cmp reg, imm` immediates (0, 1, 3, 16, 32, 128, 4096,
  status codes 0x4600..0x4604) fit imm32 with bit 31 clear.
* Byte loads via `mov_b r, [base + idx * 1]` with explicit `*1`
  scale on reg+reg forms.
* Byte stores decomposed via staging register for reg+reg; direct
  `[reg + imm_disp]` form for reg+disp.
* u32 loads / stores via `mov_d [reg + imm_disp]`.
* Cross-module `.bss` writes via `lea r11, [rip + sym]; mov [r11],
  rax`.
* Register-liveness: r11 clobbered by every nested CALL. Values
  that must survive a nested CALL live in r12..r15 (callee-save).
  LetScope's only nested CALLs are to `_ls_init` from
  `_ls_push_impl` and `_ls_resolve`, and to `_ls_push_impl` from
  each of the three public push wrappers. All frame alignments
  achieve `rsp % 16 == 0` at every nested CALL.

---

## 11 · Forward path

| M5.1 | TypeEnv `scheme_id` payload (`flags & 1` selects scheme_id vs HmCore pool_idx). |
| M5.2 | `_ls_push_letrec_group` batch mutual-recursion push.                            |
| M5.3 | `_ll_parse` splice-points for `let` / `let rec` production rules.              |
| M5.4 | Compacting pop (`_ls_pop_and_reclaim`) that frees the slot.                    |
| M5.5 | 12-test proptest harness + fingerprint goldens (`tests/proptest_let_scope.pdx`). |

---

## 12 · Upstream + related

* **Issue:** paideia-os#2679 (THIS ticket, R224.M5).
* **Design docs related:**
  * `design/terminal/semantic-shell-language-plan.md` §R224.M5.
  * `design/shell/hm-algorithm-w-core.md` (R225.M1 scheme-storage
    substrate; the `type_scheme_ref` u32 at raw M5 is a HmCore
    pool_idx).
  * `design/shell/type-env-threading.md` (R229.M3 TypeEnv scheme-
    store substrate for the M5.1 payload reinterpretation).
  * `design/shell/lambda-literal-grammar.md` (R224.M1 grammar
    driver that will splice at M5.3).
  * `design/shell/effect-polymorphism.md`,
    `design/shell/capability-row-typing.md` (R224.M3/M4 siblings;
    same frame-pool stride/sentinel convention).
