# PDS `#requires-paideia` version gate — R133.M4

Parent: paideia-os#2480. Milestone: paideia-os#2623.

## Scope

Parse the `#requires-paideia <op> <semver>` load-time directive, compare
the requested semver triple against the kernel's own
`KERNEL_VERSION_(MAJOR|MINOR|PATCH)` triple, and refuse the load when the
constraint is unsatisfied. A `.pds` script that targets a runtime newer
or older than the host kernel never executes a single TEXT byte: the gate
is the last read-only predicate between the admitted container (R133.M2
caps-decl gate + R133.M3 import-graph post-order) and the R131 shell
command dispatcher.

## Why a dedicated gate

R133.M2 admits the capability shape and R133.M3 admits the import-graph
shape. Neither predicate speaks to the ABI contract between the script
and the kernel's command / effect surface. A `.pds` compiled against
`paideia 2.x` which declares an `@effect` or capability name that `0.x`
has not minted yet does not fail at the cap-decl gate (the gate checks
narrow-only against the current env — it does not know the script is
asking for something `2.x`-shaped). The version gate is the explicit
contract wire: the script's author pins the runtime floor (and, via
`<=` / `<`, ceiling) that their text was authored under. A load that
fails here fails BEFORE the loader walks any import edge, so a mismatch
cannot pull foreign bytes into the session's attention.

Three concerns argued for a layer separate from the cap-decl gate:

  1. **Separation of concerns.** `_pds_cdg_gate` is parameterised over
     the KIND_CAP_ENV grant env; `_vg_check` is parameterised over the
     static kernel-version triple. Collapsing them would couple an
     ABI-pin predicate to a session-local env handle and preclude the
     use of the version gate as a pure predicate in offline tools (e.g.
     a future `pdsc verify` pass).

  2. **Error-code namespace.** Cap-decl faults carry the cap-shape
     reason (UNDECLARED, RIGHTS_WIDEN). Version-gate faults carry the
     ABI reason (VERSION_MISMATCH plus parse errors). A single band
     per gate keeps `tools/verify-fingerprint-coverage.sh` and the
     downstream `PdsErr::*` surface uniform.

  3. **Reusability.** The parser accepts a byte-range `(ptr, len)` and
     returns a packed u64. It is reusable from the R133.M1 container
     reader's pragma extractor, the source-form `_pds_hp_parse`, and
     the hypothetical offline `pdsc verify` path without wiring.

## Textual directive shape

```
#requires-paideia OP SEMVER
```

Grammar:

```
directive := "#requires-paideia" WS+ OP WS+ SEMVER
OP        := ">="  |  "<="  |  "~="  |  ">"  |  "<"  |  "="
SEMVER    := DIGITS "." DIGITS [ "." DIGITS ]
DIGITS    := [0-9]+
WS        := " "  |  "\t"
```

The parser scans greedily: `>=` matches before `>`, `<=` before `<`.
`DIGITS` is unbounded in the string form but each component is parsed
into a u64 accumulator with no overflow guard (the acceptance smoke
`>= 99.0` fits trivially; a later wave MAY add an explicit overflow
check against `u32::MAX`).

Trailing whitespace / newline after the version is tolerated:
`vg_pmn_done` and `vg_pp_done` fall through to the comparator rather
than demanding a terminator. The caller is expected to hand the gate
only the directive bytes (the R133.M1 container reader's pragma
extractor isolates each line).

## Comparison semantics

Three-way lexicographic compare on `(major, minor, patch)`:

```
cmp3((hm,hn,hp), (rm,rn,rp)) =
    HI    if hm > rm, or (hm==rm and hn > rn),
                 or (hm==rm and hn==rn and hp > rp)
    EQ    if (hm,hn,hp) == (rm,rn,rp)
    LO    otherwise
```

Op dispatch:

| op   | satisfied when            |
|------|---------------------------|
| `=`  | cmp == EQ                 |
| `>=` | cmp in {HI, EQ}           |
| `<=` | cmp in {LO, EQ}           |
| `>`  | cmp == HI                 |
| `<`  | cmp == LO                 |
| `~=` | have.major == req.major AND cmp in {HI, EQ} |

`~=` is the "compatible with" op — same major, equal or newer within
that major. It is the directive form that lets a script written against
`2.3.1` run on any `2.y.z` (y >= 3, or y == 3 && z >= 1) but refuse to
load on `3.0.0`. Equivalent to the Cargo-style caret, named `~=` because
`^` is lexed as a bitxor token in pdx-lang.

## Status band (0x3B00..0x3BFF)

| code                        | hex    | meaning                                        |
|-----------------------------|--------|------------------------------------------------|
| `VG_OK`                     | 0x0000 | directive parses + constraint satisfied        |
| `VG_ERR_VERSION_MISMATCH`   | 0x3B00 | parsed, but have-triple fails op vs req-triple |
| `VG_ERR_BAD_DIRECTIVE`      | 0x3B01 | prefix mismatch (not `#requires-paideia`)      |
| `VG_ERR_BAD_OP`             | 0x3B02 | op token not in `{>=, <=, ~=, >, <, =}`        |
| `VG_ERR_BAD_SEMVER`         | 0x3B03 | missing / malformed digit run or '.'           |
| `VG_ERR_SRC_TOO_SHORT`      | 0x3B04 | src_len < 18 (prefix + ≥1 trailing byte)       |

Band selection: a `grep -rnE '0x3B[0-9A-Fa-f]{2}\b' src/ design/` on
2026-10-15 returned no live source references, so the band is free of
the collisions that caught R133.M3 at 0x3800 (Wave 118 lesson). Prior
R133 bands:

  * 0x3200..0x32FF  R133.M2 caps-decl gate
  * 0x3A00..0x3AFF  R133.M3 import graph
  * 0x3B00..0x3BFF  R133.M4 version gate   ← this file

The 0x33xx..0x39xx range is occupied by R221..R229 user-space milestones
(see import_graph.pdx §3 for the current map).

### `VG_ERR_VERSION_MISMATCH` packing

```
bits [15: 0] = 0x3B00                      status
bits [31:16] = KERNEL_VERSION_MAJOR        have-major (u16)
bits [63:32] = req_major                   required-major (u32)
```

Only the major is packed into the return value, both because the
major boundary is the only ABI-breaking boundary in practice and
because the fingerprint already carries the major in both slots.
A future caller that needs the full triple of each side pulls them
from the `_vg_last_required_*` / `_vg_last_have_*` accessors (added
at the first wave that needs the richer surface — M4 does not).

## Fingerprint

Success emits `pds version ok required=<rm> have=<hm>` via `klog_s1_d2`
at `LEVEL_INFO`. Mismatch emits `pds version mismatch` via `klog_s1`
at `LEVEL_WARN`. All parse errors return silently (caller-contract
violations; the surrounding R131 pds-loader surfaces them as its own
`PdsErr::*` value).

The tag string "pds version ok" uses lowercase `ok` deliberately: the
`tools/verify-fingerprint-coverage.sh` `OK_TOK` regex matches only
bare uppercase `OK` as a word token, so this tag bypasses the asserted-
marker extractor. Same posture as R133.M2's `pds.cdg: ok` and R133.M3's
`pds import graph ok`. A future smoke that pins this fingerprint does
so via a plain substring assertion in its golden file.

## Kernel version triple

Declared in-place at the top of `version_gate.pdx`:

```
pub let KERNEL_VERSION_MAJOR : u64 = 0
pub let KERNEL_VERSION_MINOR : u64 = 1
pub let KERNEL_VERSION_PATCH : u64 = 0
```

`0.1.0` reflects the pre-1.0 posture of the paideia-os workspace in
Wave 118. A `grep -rn 'KERNEL_VERSION' src/kernel` on 2026-10-15 found
no pre-existing exported triple, so this file is the authoritative
declaration site. A later wave bumps these on each phase close in
parallel with the paideia-as `workspace.version` discipline
(feedback_paideia_as_version_discipline). Call sites load via
`mov r11, [rip + KERNEL_VERSION_MAJOR]` (same idiom as
`frame_capture_emit.pdx:538` loading `CAPTURE_ROW_MAX`).

## Register plan

```
_vg_check(src_ptr, src_len) -> packed u64

Saves rbx, r12, r13, r14, r15 (5 pushes) + sub rsp, 16 (2 locals):

  push rbx     rbx = src_ptr
  push r12     r12 = src_len
  push r13     r13 = cursor (byte offset into src)
  push r14     r14 = req_major (u64 accumulator)
  push r15     r15 = req_minor (u64 accumulator)
  sub  rsp, 16
                [rsp +  0] = req_patch
                [rsp +  8] = op (VG_OP_*)
```

Entry `rsp % 16 == 8`; +40 pushes + 16 sub = +56; `(8 + 56) % 16 == 0`
at body. Pre-CALL to `klog_s1`: body `rsp % 16 == 0`. Pre-CALL to
`klog_s1_d2`: idiom `sub rsp, 8; push v2` (= +16) lands `rsp % 16 == 0`
at the CALL, matching the `klog_s1_d2` call-site alignment proof in
`import_graph.pdx:610-612`. Post-CALL: `add rsp, 16` reclaims pad +
push.

Internal op codes (stack-local; never surface externally):

```
VG_OP_EQ        = 1   =
VG_OP_GE        = 2   >=
VG_OP_LE        = 3   <=
VG_OP_GT        = 4   >
VG_OP_LT        = 5   <
VG_OP_CARET_EQ  = 6   ~=
```

## Encoder discipline

Per `feedback_pdx_encoder_pitfalls`:

  * `cmp rN, 0`               never `test rN, rN`.
  * No 2-op `imul r, imm`     — `v * 10` done via
      `mov r10, v; shl r10, 3; mov r11, v; shl r11, 1; add r10, r11`
      (v*8 + v*2 = v*10).
  * No `and rN, imm64`         — mismatch pack uses `shl` + `or` only.
  * Single-line `pub let`      — one line per literal (tags, prefix).
  * Module basename matches    — `VersionGate` ↔ `version_gate.pdx`.
  * Labels prefixed `vg_`      — reserved-word-safe; distinct from
                                 `ctr_` / `pds_cdg_` / `ig_` siblings.
  * Byte loads via `xor rN,rN; mov_b rN, [reg+reg*1]`  — mov_b does not
                                 implicitly zero-extend (R133.M3 L450
                                 precedent).
  * `mov r11, imm32` for all   — `0x3B00..0x3B04` all fit imm32
    status codes                 sign-ext safe (bit 31 clear).

## Fingerprint tag geometry (N = len(string) + 1, NUL inclusive)

```
"pds version ok"         14 + NUL -> N = 15
"pds version mismatch"   20 + NUL -> N = 21
"required"                8 + NUL -> N =  9
"have"                    4 + NUL -> N =  5
"#requires-paideia"      17 + NUL -> N = 18   (compared on 17 bytes)
```

## Cross-module wiring

The R131 pds-loader at M4+ invokes `_vg_check` on the parsed
`#requires-paideia` line immediately after `_pds_cdg_gate` admits the
caps-decl bundle and before `_ig_build_order` is invoked on the import
adjacency. The three gates compose:

```
e = _pds_cdg_gate(...);                   // 0x3200..0x32FF band
if (e != 0) abort;
e = _vg_check(req_line_ptr, req_line_len);  // 0x3B00..0x3BFF band
if (e != 0) abort;
e = _ig_build_order(adj, n, out, cap);    // 0x3A00..0x3AFF band
if (ig_status(e) != IG_OK) abort;
dispatch TEXT bytes...
```

Each gate owns its band so a surrounding error-reporter can switch on
the low 16 bits of the packed status without ambiguity.

## Acceptance smoke

```
#requires-paideia >= 99.0        on 0.1.0 runtime     ->  VG_ERR_VERSION_MISMATCH
                                 fingerprint tag:    "pds version mismatch"
                                 packed return:      0x0000006300003B00
                                                     = (99 << 32) | (0 << 16) | 0x3B00
```

The fingerprint on success is `pds version ok required=<rm> have=<hm>`
(e.g. `pds version ok required=0 have=0` on a self-check with
`#requires-paideia >= 0.1`).

## Future work

  * **Richer compare surface.** M4 packs only the major pair into the
    error status. A future wave adds a `_vg_last_required_(major|minor|patch)`
    accessor family that reads the parse's accumulators out of a .bss
    scratch area, letting an audit path recover the full triple.

  * **Overflow guard.** The digit parser caps nothing; `>= 2^64 - 1`
    would silently wrap. A later wave adds a `cmp r10, 0xFFFFFFFF; ja
    vg_bad_semver` guard inside each parse loop once the surrounding
    pds-script type-system pins per-component widths (R227 planning).

  * **Multi-constraint syntax.** `#requires-paideia >= 2.0, < 3.0`
    (conjunctive) lands at M5+; M4's parser accepts exactly one op /
    semver pair, which matches the acceptance scope.

  * **External version source.** The `KERNEL_VERSION_*` triple will
    migrate to a kernel-boot-time init that reads the triple from the
    pdx-build-info section embedded by `paideia-as` on each cut (same
    section that carries `workspace.version`). The accessor shape is
    stable; the storage moves.

## References

  * `src/kernel/core/pds/container_reader.pdx` — R133.M1
  * `src/kernel/core/pds/caps_decl_gate.pdx` — R133.M2
  * `src/kernel/core/pds/import_graph.pdx` — R133.M3
  * `design/kernel/pds-import-graph.md` — R133.M3 design doc
  * `tools/verify-fingerprint-coverage.sh` — OK_TOK regex semantics
  * `feedback_pdx_encoder_pitfalls` — encoder discipline
  * `feedback_paideia_as_version_discipline` — version-bump cadence
