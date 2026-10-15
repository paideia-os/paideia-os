# ArgSpec + FlagSpec typing — R222.M4

Parent: paideia-os#2486 (R222 cmd-functor umbrella).
Milestone: paideia-os#2661.
Wave: 119 (follows Wave 118 which landed R222.M3 FunctorInstance).

## Scope

HM-typed argument and flag descriptors for the semantic-shell cmd-
functor surface. Positional arguments vs `--named` flags are declared
in two separate signature blocks and compiled to flat 32-byte binary
records. At REPL prompt time, user invocation bytes (as parsed into a
`FunctorInstance` materialization record by R222.M3) are checked
against the per-command ArgSpec + FlagSpec records; type mismatches
produce diagnostics that reference the ArgSpec source span (via the
R222.M3 ArgDesc's `ref_ptr`+`length` into the original invocation
buffer).

R222.M3 (FunctorInstance) emits the raw `(type_code=STR, mode=REF,
length, ref_ptr)` ArgDesc stream. R222.M4 (this landing) consumes that
stream against a declared signature and either promotes each ArgDesc
to a typed form OR flags a mismatch at the ArgSpec source span.

## Where this lives

- Module: `tools/user/libpdx-pds-parser/src/arg_flag_spec.pdx`
  (module name `ArgFlagSpec`).
- Caps-decl: new error band `0x3C00..0x3CFF` in
  `tools/user/libpdx-pds-parser/caps.decl`.
- Status code band: `0x3C00..0x3CFF`. Disjoint from every prior
  user-space packed-status band in the paideia-os tree. The adjacent
  `0x3A00..0x3AFF` is R133.M3's kernel-side pds import graph band;
  `0x3B00..0x3BFF` is reserved for the parallel R133.M4 kernel arm of
  Wave 119.

## Record layouts

Both records are a strict 32 bytes so the stride multiply is a
power-of-two shift (`shl rN, 5` — never 2-op `imul r, imm`).

### ArgSpec — 32 bytes

```
offset size  field              notes
  0     4   magic         u32  AFS_ARG_SPEC_MAGIC = 'ARGS' LE
                               = 0x53475241
  4     2   pos           u16  0..AFS_MAX_ARGS-1; 0xFFFF reserved for
                               a future flag-only sentinel.
  6     2   flags         u16  bit 0 OPTIONAL, bit 1 VARIADIC
  8     1   type_code     u8   AFS_TYPE_* ∈ {U64=1, I64=2, STR=3,
                                HEX=4, HASH32=5, TSC=6, PATH=8, PID=9}
                                — byte-for-byte mirror of R222.M3
                                FI_TYPE_* and R222.M1 SS_TYPE_*.
  9     1   name_len      u8   1..AFS_NAME_MAX = 14
 10    14   name_inline   u8[] ASCII, zero-padded past name_len
 24     8   default_ref   u64  type-tagged default-value pointer;
                                0 if no default (at M4 always 0 —
                                default-literal grammar lands at M5).
```

Note: the parent brief sketched a trailing `reserved[4]` on top of the
sum above, which would have made the record 36 bytes. This landing
drops that trailing padding to keep the record a strict 32-byte
power-of-two stride; a future need for a cap-row id or source-span u32
can carve into the (never-populated) low bits of `default_ref` or a
new sibling descriptor type without an ABI break.

### FlagSpec — 32 bytes

```
offset size  field              notes
  0     4   magic         u32  AFS_FLAG_SPEC_MAGIC = 'FLAG' LE
                               = 0x47414C46
  4     2   flags         u16  bit 0 TAKES_VALUE, bit 1 REPEATABLE
  6     1   short_char    u8   ASCII letter or 0 (no short form)
  7     1   long_len      u8   1..AFS_NAME_MAX = 14
  8    14   long_name     u8[] ASCII, zero-padded past long_len
 22     1   type_code     u8   0 for bool flag (TAKES_VALUE=0),
                                otherwise AFS_TYPE_* for a flag whose
                                value is consumed from the next
                                invocation token.
 23     9   reserved      u8[] zeroed; parallel to ArgSpec's trailing
                                `default_ref` 8-byte slot, reserved
                                for M5's default-literal landing.
```

Parent brief sketched `reserved[11]` which would have overflowed the
32-byte header. Shrunk to 9 bytes to keep the record exactly 32.

## Spec body grammars

Both spec blocks are whitespace-separated declaration lists; the
caller (R222.M5 registry client at a later landing) locates the
`arg_spec { ... }` / `flag_spec { ... }` braces and hands the inner
bytes to this module.

### ArgSpec body

```
ArgSpecBody := ArgDecl*
ArgDecl     := "arg" WS* ":" WS* NAME WS* ":" WS* TYPE_NAME
                   [WS* "?"] [WS* "..."]
NAME        := [A-Za-z_] [A-Za-z0-9_]*     (len 1..14)
TYPE_NAME   := u64 | i64 | str | hex | hash32 | tsc | path | pid
```

- `?` sets AFS_ARG_FLAG_OPTIONAL.
- `...` sets AFS_ARG_FLAG_VARIADIC.
- Position auto-increments by appearance order (first declared → pos 0,
  second → pos 1, ...). AFS_MAX_ARGS = 16 cap.
- `WS` ∈ {0x20, 0x09, 0x0A, 0x0D}.

Example:

```
arg : start   : path
arg : limit   : u64 ?
arg : rest    : str ...
```

### FlagSpec body

```
FlagSpecBody := FlagDecl*
FlagDecl     := "flag" WS* ":" WS* "--" LONG_NAME
                        [WS* "," WS* "-" SHORT_CHAR]
                        [WS* ":" WS* TYPE_NAME]
                        [WS* "+"]
LONG_NAME    := [A-Za-z] [A-Za-z0-9_-]*     (len 1..14)
SHORT_CHAR   := [A-Za-z]                    (1 char)
```

- Presence of `:" TYPE_NAME` sets AFS_FLAG_TAKES_VALUE and records
  the type_code. Absence → bool flag (type_code = 0, TAKES_VALUE = 0).
- `+` sets AFS_FLAG_REPEATABLE.
- AFS_MAX_FLAGS = 16 cap.

Example:

```
flag : --verbose, -v
flag : --limit, -n : u64
flag : --tag : str +
```

## Public API

Register maps follow SysV. Every entry point is `effects: {mem},
capabilities: {}` (pure byte-walker).

```
_afs_parse_arg_spec_body(bytes_ptr, bytes_len, out_ptr, out_cap)
                                                  -> packed_u64
    rdi = bytes_ptr
    rsi = bytes_len
    rdx = out_ptr
    rcx = out_cap
    rax = (bytes_written << 32) | status

_afs_parse_flag_spec_body(bytes_ptr, bytes_len, out_ptr, out_cap)
                                                  -> packed_u64
    rdi = bytes_ptr
    rsi = bytes_len
    rdx = out_ptr
    rcx = out_cap
    rax = (bytes_written << 32) | status

_afs_check_invocation(args_body, args_len, flags_body, flags_len,
                      invocation, inv_len)        -> status
    rdi = args_body         (ArgSpec records, concatenated)
    rsi = args_len          (bytes at args_body)
    rdx = flags_body        (FlagSpec records, concatenated)
    rcx = flags_len         (bytes at flags_body)
    r8  = invocation        (FunctorInstance materialization record
                             as produced by _fi_instantiate; must
                             start with 'FINS' magic)
    r9  = inv_len           (bytes at invocation; must be
                             >= 64 + arg_count * 32)
    rax = status
```

### Status band — 0x3C00..0x3CFF

```
AFS_OK                     = 0
AFS_ERR_SYNTAX             = 0x3C00  grammar fault in a spec body
AFS_ERR_UNKNOWN_TYPE       = 0x3C01  type_name not in the M4 set
AFS_ERR_TOO_MANY_ARGS      = 0x3C02  > AFS_MAX_ARGS (16)
AFS_ERR_TOO_MANY_FLAGS     = 0x3C03  > AFS_MAX_FLAGS (16)
AFS_ERR_OUT_TOO_SMALL      = 0x3C04  out_cap < records_written
AFS_ERR_BAD_INVOCATION     = 0x3C05  _afs_check_invocation: invocation
                                     missing 'FINS' magic or inv_len <
                                     64 + arg_count*32.
AFS_ERR_TYPE_MISMATCH      = 0x3C06  invocation positional's byte run
                                     does not parse as the ArgSpec's
                                     declared type_code.
AFS_ERR_MISSING_REQUIRED   = 0x3C07  non-optional ArgSpec not consumed
                                     by the invocation.
AFS_ERR_UNKNOWN_FLAG       = 0x3C08  invocation flag not in FlagSpec
                                     table.
AFS_ERR_FLAG_NO_VALUE      = 0x3C09  TAKES_VALUE flag at end of input.
AFS_ERR_EXTRA_POS          = 0x3C0A  invocation positional past the
                                     last ArgSpec (and no VARIADIC
                                     slot available).
```

Slots `0x3C0B..0x3CFF` reserved for R222.M5 (registry-client reconcile
errors) and R222.M6 (commands.toml bind errors).

## Type-check rules at `_afs_check_invocation`

For each ArgDesc byte run (from the invocation's `(ref_ptr, length)`
tuple):

| type_code      | validator                                         |
|----------------|---------------------------------------------------|
| U64 (1)        | all bytes in [0x30..0x39], length >= 1            |
| I64 (2)        | optional leading '-', rest decimal, length >= 1   |
| STR (3)        | always OK (any length >= 1, any byte)             |
| HEX (4)        | "0x" prefix + 1..16 hex digits                    |
| HASH32 (5)     | "0x" prefix + exactly 16 hex digits (u64 identity)|
| TSC (6)        | all decimal digits                                |
| PATH (8)       | always OK                                         |
| PID (9)        | all decimal digits                                |

The HASH32 wire shape is the FNV-1a 64 identity used by R222.M2
CommandSig CapDecl's `name_hash` and R222.M3 FunctorInstance's
`name_hash`; the "32" in the type name refers to the 32-char hex
(=64-bit) wire form, not a 32-byte payload. If a later landing wants
a 128-bit or 256-bit identity, it carves a sibling type code
(HASH128, HASH256) rather than widening HASH32.

## Interactions

- **R222.M1 (SchemasSig)** — type codes mirrored byte-for-byte so a
  consumer that compares ArgSpec.type_code against SchemasSig INPUT
  record field types operates on the same byte-value space.
- **R222.M2 (CommandSig)** — a command's full signature now consists of
  CommandSig (identity + caps + version + stability) + SchemasSig
  (input/output shapes) + ArgSpec (positional parameters) + FlagSpec
  (named flags). The four parsers are composed by the registry client
  at R222.M5.
- **R222.M3 (FunctorInstance)** — produces the raw ArgDesc stream that
  `_afs_check_invocation` consumes. R222.M3's `_fi_elaborate_args`
  takes a per-arg `arg_types_ptr` that is seeded from an ArgSpec
  record at R222.M5+ (currently seeded by hand in test setup).
- **R222.M5 (registry client, deferred)** — reads commands.toml,
  materializes the per-command ArgSpec + FlagSpec records, hashes them
  into the schema-registry fingerprint, hands them to the kernel-side
  cap-decl checker as flat byte blobs.
- **R229.M3 (REPL dispatch, deferred)** — calls `_fi_instantiate`
  then `_afs_check_invocation` on every PARSED->EVAL transition.
  On AFS_OK, calls `_fi_elaborate_args` seeded from the ArgSpec
  type_codes to promote REF ArgDescs into INLINE ones.

## Encoder discipline

Same discipline as the rest of libpdx-pds-parser:

- No `test rN, rN` — every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64` — every mask is imm8 or imm32.
- No 2-op `imul r, imm` — all strides are power-of-2 shifts
  (`shl rN, 5` for the 32-byte record stride).
- No multiline `pub let = "..."` — single-line justifications only.
- Module basename `ArgFlagSpec` matches `arg_flag_spec.pdx`.
- Labels prefixed `afs_` (grep-confirmed free of symbol collisions;
  `libpdx-audit::audit_file_sink` uses `afs_` for FUNCTION-LOCAL
  labels inside its `audit_file_append` entry — paideia-as labels are
  function-scoped, not module-global, so there is no linker
  collision; grep-level overlap is cosmetic only).
- All `cmp reg, imm` immediates fit in imm32 with bit 31 clear
  (ASCII literals 0x20..0x7E, counts 14/16, size constants 32/64/
  128, status codes 0x3C00..0x3C0A). The two magic values
  (0x53475241 'ARGS', 0x47414C46 'FLAG') and the FunctorInstance
  magic 0x534E4946 'FINS' all fit in imm32.
- Byte loads via `xor rax, rax; mov_b rax, [base + idx]`
  (zero-extends into the full qword); byte stores via
  `mov_b [dst + disp], reg`.
- u16 stores via two `mov_b` byte writes (low, high); u32 stores via
  `mov_d [dst + disp], reg`; u64 stores via `mov [dst + disp], reg`.
- Zero-fill of a fresh 32-byte spec record uses a shift-add u64 loop
  (4 iterations stepping by 8).

## Status-check discipline (Wave 118 lesson)

The debugger caught two infinite-loop bugs in Wave 118's R222.M3 where
status 0x3800 (low byte 0x00) was masked with `and r11, 0xFF` and
misread as OK. **This module compares status values with full-32-bit
`cmp`, never low-byte-only masks.** The R222.M3 status band
0x3900..0x3906 and this module's 0x3C00..0x3C0A both have low byte 0
on their first slot (0x3900 and 0x3C00 both ending `..00`), so a
caller that treats a packed `(bytes_written << 32) | status` return
and masks the low 8 bits to classify OK vs error would silently
misclassify the first status code of each band. Every status check in
this file uses `cmp reg, 0` (zero-vs-nonzero) or `cmp reg, 0x3C0N`
(full-value compare) — never `and reg, 0xFF`.

## Register-liveness note

`r11` is clobbered by every nested `CALL`. In `_afs_check_invocation`
the ArgDesc byte-run pointer survives nested calls to type-check
helpers by living in `r12..r15` or on the stack. Specifically:

- `_afs_parse_arg_spec_body` / `_afs_parse_flag_spec_body`: 6-push +
  24-byte scratch (cursor + token_start + token_len) → `rsp%16==0`
  steady at every nested `CALL`.
- `_afs_check_invocation`: 6-push + 40-byte scratch (invocation ptr,
  arg_count, pos_idx, flag_match_bitmask, arg_match_bitmask) →
  `rsp%16==0` steady; nested calls into `_afs_skip_ws`,
  `_afs_classify_type`, and `_afs_parse_as_type` leaves need no
  additional per-call pad.

## Acceptance

20-test corpus of well-typed and ill-typed arg lists, with error
diagnostics referencing the ArgSpec source span. The test corpus
lands at `tests/proptest_arg_flag_spec.pdx` on a follow-up (deferred
to the R222.M7 fuzz-corpus milestone per the umbrella); this landing
documents the representative cases:

**Well-typed (10):**
1. `find .` against `arg : path : path` — path accepted.
2. `grep hello foo.txt` against `arg : pattern : str; arg : file : path`.
3. `ls -l /tmp` — flag -l (bool), positional PATH.
4. `rm --force /tmp/x` — long flag --force (bool), positional PATH.
5. `head --count 10 foo.txt` — flag --count takes u64 value.
6. `tag --name hello --name world` — repeatable flag.
7. `find . foo bar baz` — variadic positional captures 3 trailing args.
8. `kill 1234` — positional pid.
9. `history 0xDEADBEEF` — positional hex.
10. `benchmark 0x1234567890ABCDEF` — positional hash32.

**Ill-typed (10):**
11. `find` — missing required positional → AFS_ERR_MISSING_REQUIRED.
12. `grep` — missing both positionals.
13. `head --count foo foo.txt` — flag value "foo" not u64 → TYPE_MISMATCH.
14. `ls --unknown` — unknown flag → UNKNOWN_FLAG.
15. `ls -z` — unknown short flag.
16. `head --count` — TAKES_VALUE flag at EOF → FLAG_NO_VALUE.
17. `kill abc` — non-digit for pid → TYPE_MISMATCH.
18. `history 0xZZ` — bad hex → TYPE_MISMATCH.
19. `benchmark 0x12` — hash32 wrong length → TYPE_MISMATCH.
20. `find . a b c d e f g h i j k l m n o p q` — > 16 positionals →
    EXTRA_POS (no variadic in the ArgSpec).

## Forward path

- **R222.M5**: registry client reads commands.toml, round-trips
  ArgSpec + FlagSpec records through on-disk form, reconciles with
  the live CommandSig at functor-elaboration time.
- **R222.M6**: `default_ref` grammar — the `= <literal>` suffix on an
  ArgDecl; FlagSpec picks up a default-literal slot via the
  `reserved[9]` byte range.
- **R222.M8**: `describe <cmd>` builtin round-trips the ArgSpec +
  FlagSpec records through the queryable form.

## References

- `tools/user/libpdx-pds-parser/src/schemas_sig.pdx` (R222.M1).
- `tools/user/libpdx-pds-parser/src/command_sig.pdx` (R222.M2).
- `tools/user/libpdx-pds-parser/src/functor_instance.pdx` (R222.M3).
- `design/terminal/semantic-shell-language-plan.md` §4 R222 row M4.
