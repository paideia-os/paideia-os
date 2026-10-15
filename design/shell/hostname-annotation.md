# Hostname annotation parse + type (R223.M6)

**Status:** parse-only landing (R223.M6). Substrate wire-up (encrypted
remote-shell transport) is a separate milestone.
**Issue:** paideia-os#2671 (R223.M6).
**Umbrella:** paideia-os#2487 (R223 pipeline-lang).
**Module:** `tools/user/libpdx-pds-parser/src/hostname_annot.pdx`
(`HostnameAnnot`).
**Error band:** `0x5300..0x53FF`.

## 1. Scope and motivation

The paideia-os shell dispatches commands as pipeline stages where each
stage may optionally run on a REMOTE host via an encrypted channel.
The user writes:

```
@workstation grep foo /etc/hosts | sort | @laptop uniq
```

The semantics: the first stage runs on `workstation`; the second runs
locally; the third runs on `laptop`. The pipeline-stage parser
(R223.M1) tokenises the three stages but does NOT decide WHERE each
stage runs; the `@hostname` prefix is a per-stage POST-pass annotation.

R223.M6 (THIS landing) commits ONLY the parse surface:

- A 32-byte `HostAnnot` record identifying the target host (either
  LOCAL or REMOTE with a hashed hostname).
- A parser (`_ha_parse`) that walks a stage's leading bytes, extracts
  the optional `@hostname` prefix, and emits one `HostAnnot` record.
- A checker (`_ha_check`) that type-checks a `HostAnnot` record
  against the current execution context's hostname (empty for local
  dispatch).

The SUBSTRATE half -- actually routing stage bytes across an encrypted
channel -- is a SEPARATE milestone (R105+ remote-shell daemon,
design/shell/remote-shell-daemon.md and
design/shell/remote-shell-hybrid-kem.md). This module is strictly
parse-only; the record it emits is the HAND-OFF point to the
substrate.

## 2. Grammar

```
StagePrefix := ( '@' Hostname? WS* )?
Hostname    := [A-Za-z0-9.-]+   (byte length 1..HA_HOSTNAME_MAX = 16)
WS          := 0x20 | 0x09 | 0x0A | 0x0D
```

Semantics:

- No `@` at the first byte -> IS_LOCAL record, `bytes_consumed = 0`.
- `@` followed by WS or EOI -> IS_LOCAL record (empty-@ idiom);
  `bytes_consumed = 1 + trailing-WS run`.
- `@<hostname>` -> remote record; hash = FNV-1a 64 of hostname bytes;
  `bytes_consumed = 1 + hostname_len + trailing-WS run`.

Hostname byte class: ASCII alphanumeric plus `.` and `-`. This covers
the "short hostname" idiom the brief anchors (`workstation`, `laptop`,
`lab-01`, `10.0.0.5`, `node.local`). Longer FQDNs (> 16 bytes) are
REJECTED at parse with `HA_ERR_HOSTNAME_TOO_LONG`; the M6.1 landing
introduces a pointer-indirect long-hostname mode behind the same API
shape.

### 2.1 Why not a stricter hostname grammar?

RFC 1123 permits more than this grammar accepts (uppercase letters,
digits, `.`, `-`; underscores in LDH-plus; percent-encoded unicode in
IDN form). The parse-time grammar is deliberately CONSERVATIVE:

- The downstream transport computes the hash of the parsed bytes
  BYTE-FOR-BYTE. If the parser silently normalises (lowercases,
  Punycode-encodes), a user who typed `Workstation` and a daemon
  advertising `workstation` would MISS each other's hash.
- RFC 1123 cases out of this grammar (underscore, trailing `-`, leading
  digit on a label) are either rare in practice OR a configuration
  smell. The M6.1 strict-canonicalisation pass is where normalisation
  belongs; the raw M6 parser accepts the common 95% case and defers.
- The byte class is a strict subset of DNS label chars, so a hostname
  this parser accepts WILL round-trip through a POSIX DNS resolver
  without transformation.

### 2.2 Why the empty-`@` idiom?

Three considerations:

1. **Local-override.** A pipeline like `@workstation foo | @ bar | baz`
   makes the LOCAL dispatch explicit; without an empty-`@`, there is
   no way to say "this stage is NOT inherited from the previous one".
2. **Future federation.** A later milestone may define `@<group>:<rule>`
   syntax for a federation-wide stage dispatch. Reserving `@` with no
   hostname as the LOCAL sentinel keeps the parse shape uniform.
3. **Diagnostic clarity.** `@|` and `@ ` are easy user typos that the
   parser handles gracefully (empty-@ -> local) rather than erroring
   out. The M6.1 strict-federation mode may refuse these.

## 3. Record layout (32 bytes)

| offset | size | field            | type   | notes                                                                 |
|--------|------|------------------|--------|-----------------------------------------------------------------------|
| 0      | 4    | `magic`          | u32    | `'HOST'` LE = `0x54534F48`.                                           |
| 4      | 4    | `flags`          | u32    | bit 0 = `HA_FLAG_IS_LOCAL`; bits 1..31 reserved (zero at M6).         |
| 8      | 8    | `hostname_hash`  | u64    | FNV-1a 64 of hostname bytes. Zero iff `IS_LOCAL`.                     |
| 16     | 16   | `hostname_inline`| [u8;16]| ASCII hostname, zero-padded. All zero iff `IS_LOCAL`.                 |

Stride is 32 bytes (power of two). A dispatcher indexing an array of
`HostAnnot` records multiplies by 32 via `shl rN, 5` -- no 2-op
`imul r, imm` pitfall. The 16-byte inline capacity leaves exactly 32B
total; the brief's early arithmetic that included a reserved `u64`
tail would have come to 40B, so the brief's own "32B exactly -- trim
reserved u64" note is honoured here.

### 3.1 Magic byte sequence

`'HOST'` little-endian = `0x54534F48`:

- Byte 0 = `0x48` = `'H'`
- Byte 1 = `0x4F` = `'O'`
- Byte 2 = `0x53` = `'S'`
- Byte 3 = `0x54` = `'T'`

Reads as the 4-byte ASCII string `"HOST"` in a hex-dump sequential
scan, per the Wave 125 SortGroupReduce magic-reconciliation lesson
(byte-sequence readability matters more than numeric prettiness).
Grep-disjoint across the parser-family's other magic values
(`'HIST'`, `'JOBS'`, `'PLAM'`, `'DESC'`, `'CSIG'`, `'FINS'`,
`'ARGS'`, `'FLAG'`, `'SORT'`, `'GRPS'`, `'REDU'`, `'FILT'`).

### 3.2 Why hash + inline rather than ptr + len?

Two downstream properties follow from inlining the hostname:

1. **Byte-identical record hashing.** A federation planner that
   fingerprints the record (for cache lookup, for identity-equal
   comparison between two parsed pipelines) can hash the 32 bytes
   verbatim. A `(ptr, len)` representation would require resolving
   the pointer first, which breaks across process boundaries.
2. **No dangling pointers across pipeline-stage lifetimes.** A
   `HostAnnot` record emitted at parse time outlives the stage's
   source bytes if the downstream dispatcher queues the record;
   inlining removes the lifetime coupling.

### 3.3 Why FNV-1a 64?

Standard parser-family precedent:

- `command_sig.pdx` (R222.M2) hashes cap-names with FNV-1a 64.
- `functor_instance.pdx` (R222.M3) hashes functor names with FNV-1a 64.
- `history.pdx` (R229.M5) hashes command text with FNV-1a 64.
- `cmd_registry.pdx` (R222.M5) uses FNV-1a 64 as the probe hash.

Using FNV-1a 64 here keeps the family uniform; the downstream
transport can mix hashes from different sources (command id, hostname,
cap-name) into one lookup key without a hash-function type-dance.
FNV-1a 64 is NOT a cryptographic hash; the SECURITY layer of the
remote-shell transport uses the hybrid KEM (R105 PQ work) over the
LITERAL hostname bytes, not the parse-time hash.

## 4. Public API

```
pub let _ha_init        : () -> ()                             !{} @{}
pub let _ha_parse       : (u64, u64, u64, u64) -> u64          !{mem} @{}
pub let _ha_check       : (u64, u64, u64) -> u64               !{mem} @{}
```

### 4.1 `_ha_init() -> ()`

Idempotent lazy boot hook. M6 holds NO `.bss` state (every record is
caller-owned; the check primitive operates as a pure FNV compare over
caller-supplied bytes). Bare `ret`. Kept for parallelism with the
DispatchMode (R222.M6) / CmdRegistry (R222.M5) / DescribeSig (R222.M8)
init-hook family so a later landing that adds `.bss` does not break
the API.

### 4.2 `_ha_parse(bytes, bytes_len, out, out_cap) -> packed`

Register map (SysV):

| reg | role         |
|-----|--------------|
| rdi | `bytes`      |
| rsi | `bytes_len`  |
| rdx | `out`        |
| rcx | `out_cap`    |
| rax | packed       |

Returns `(bytes_consumed << 32) | status`. Non-fatal statuses still
include a well-formed record at `[out, out+32)`:

- `HA_OK` (0): record emitted; caller resumes parsing at
  `bytes + bytes_consumed`.
- `HA_ERR_HOSTNAME_TOO_LONG` (`0x5301`): hostname > 16 bytes;
  `bytes_consumed` is the END-of-hostname offset (useful for a
  diagnostic site to point at the offending span).
- `HA_ERR_OUT_TOO_SMALL` (`0x5302`): `out == 0` or `out_cap < 32`;
  no record written; `bytes_consumed == 0`.

### 4.3 `_ha_check(record, host_ptr, host_len) -> status`

Register map (SysV):

| reg | role                           |
|-----|--------------------------------|
| rdi | `record`                       |
| rsi | `host_ptr`                     |
| rdx | `host_len`                     |
| rax | status                         |

Returns:

- `HA_OK` (0): record matches the host (either LOCAL + `host_len == 0`
  or REMOTE + hash equal).
- `HA_ERR_BAD_RECORD` (`0x5303`): `record == 0` or magic mismatch.
- `HA_ERR_HOST_MISMATCH` (`0x5304`): record vs host disagree
  (LOCAL + non-empty host, REMOTE + empty host, or REMOTE + hash
  mismatch).
- `HA_ERR_BAD_HOST_PTR` (`0x5305`): `host_len > 0 && host_ptr == 0`.

## 5. Status band

`0x5300..0x53FF` reserved for `HostnameAnnot`. Six slots used at M6:

| code      | symbol                      | semantic                                      |
|-----------|-----------------------------|-----------------------------------------------|
| 0         | `HA_OK`                     | success                                       |
| `0x5300`  | `HA_ERR_SYNTAX`             | reserved for M6.1 strict-mode `@|` refusal    |
| `0x5301`  | `HA_ERR_HOSTNAME_TOO_LONG`  | hostname > 16 bytes                           |
| `0x5302`  | `HA_ERR_OUT_TOO_SMALL`      | `out == 0` or `out_cap < 32`                  |
| `0x5303`  | `HA_ERR_BAD_RECORD`         | `record == 0` or magic != `'HOST'`            |
| `0x5304`  | `HA_ERR_HOST_MISMATCH`      | record vs host disagree                       |
| `0x5305`  | `HA_ERR_BAD_HOST_PTR`       | `host_len > 0 && host_ptr == 0`               |

Slots `0x5306..0x53FF` reserved for M6.1+ follow-ups (long-hostname
pointer-indirect mode, strict-federation-mode `@|` refusal, cross-
session hostname cache misses, canonical-form hostname normalisation
errors).

Disjoint from:

- Parallel R223.M5 band `0x5200..0x52FF` (flag/positional partition).
- Every prior landed parser-tier band (`0x27`, `0x2A`, `0x2B`, `0x2C`,
  `0x2D`, `0x2E`, `0x33`, `0x34`, `0x35`, `0x36`, `0x37`, `0x38`,
  `0x39`, `0x3C`, `0x3D`, `0x44`, `0x45`, `0x46`, `0x47`, `0x48`,
  `0x49`, `0x4A`, `0x4C`, `0x4D`, `0x4E`, `0x4F`, `0x50`, `0x51`).

Grep-disjointness confirmation at R223.M6 landing time:

```
grep -rE '0x530[0-5]\b' paideia-os/{src,tools,design,tests}
  -> no packed-status hits outside this file + caps.decl +
     src/hostname_annot.pdx.
```

## 6. Encoder discipline (absolute)

Per `feedback_pdx_encoder_pitfalls`:

- **No `test rN, rN`** -- every zero-check is `cmp reg, 0; je/jne`.
- **No `and rN, imm64`** -- bit-isolation uses imm8 variants only
  (`and rN, 1` for the `IS_LOCAL` mask).
- **No 2-op `imul rN, imm`** -- byte-copy loops step by 1; FNV uses
  the one-op `mul rN` form (unsigned-mul `rdx:rax = rax * rN`).
- **FNV constants** `0xCBF29CE484222325` (offset basis) and
  `0x100000001B3` (prime) are > imm32, so they load via `mov rN,
  imm64` (MOVABS, 10-byte REX+mov encoding). Precedent: `history.pdx`
  lines 727-728 (`_h_append` inlined FNV).
- **`'HOST'` magic (`0x54534F48`)** fits in imm32 with bit 31 clear;
  direct `cmp rN, imm32` is sign-extension-safe.
- **No multiline `pub let = "..."`** -- single-line justifications.
- **Module basename `HostnameAnnot`** matches `hostname_annot.pdx`.
- **Labels prefixed `ha_`** -- disjoint from every prior parser-tier
  label prefix. Never bare `loop` / `if` / `let` / `fn` / `ret`.
- **All `cmp reg, imm` immediates** (ASCII literals `0x20..0x7F`,
  `HA_HOSTNAME_MAX=16`, `HA_RECORD_BYTES=32`, status codes
  `0x5300..0x5305`, magic `0x54534F48`) fit imm32 with bit 31 clear.
- **Byte loads** via `xor rN, rN; mov_b rN, [base + idx * 1]` with
  explicit `*1` scale (paideia-as #1248 + U1606 mitigation).
- **Byte stores at `[base + idx]`** precompute the address into a
  scratch (`mov r9, base; add r9, idx; mov_b [r9 + 0], reg`) to
  sidestep the `mov_b [reg + reg + off], reg` encoder gap (precedent:
  `session_env.pdx`, `job_control.pdx`, `history.pdx`).
- **u32 stores** via `mov_d [dst + disp], reg` (writes low 4 bytes).
- **u64 stores** via plain `mov [dst + disp], reg`.
- **No chained-displacement addressing** with three terms: all
  `[base + off + idx]` expressions precomputed into a scratch via
  `add` first.

## 7. Register-liveness per entry

### 7.1 `_ha_init`

Bare `ret`. No regs touched. Pure leaf; zero pushes; no stack frame;
no nested CALL.

### 7.2 `_ha_parse`

6-push callee-save frame (`rbx`, `rbp`, `r12`, `r13`, `r14`, `r15` =
48 B); pure leaf (no nested CALL, FNV-1a 64 inlined). After prologue,
`rsp%16==(8+48)%16==8`; a pure-leaf with no CALL does not require
`rsp%16==0` at a call site because no call site exists; epilogue pops
6 before `ret` so stack balance is restored.

Register plan:

| reg  | role                                          |
|------|-----------------------------------------------|
| rbx  | `bytes_ptr` (held through FNV loop)           |
| rbp  | `bytes_len`                                   |
| r12  | `out` (held through zero-fill + inline copy)  |
| r13  | cursor into bytes                             |
| r14  | `hostname_start` (offset into bytes)          |
| r15  | `hostname_len`                                |

Scratch: `rax`, `rcx`, `rdx`, `rsi`, `rdi`, `r8`, `r9`, `r10`, `r11`.
FNV-1a 64 inner loop uses: `rax` (accumulator), `rcx` (prime, held
through loop), `rdx` (mul high half -- clobbered by `mul`), `r10`
(loop index), `r11` (byte load).

Precedent: `_h_append` (R229.M5): same 6-push, 0-sub, FNV-inlined,
pure-leaf shape.

### 7.3 `_ha_check`

1-push callee-save frame (`rbx` = 8 B); pure leaf (no nested CALL,
FNV-1a 64 inlined). Entry `rsp%16==8`; +8 push = `rsp%16==0`; no
CALL; pop; `ret`.

Register plan:

| reg  | role                              |
|------|-----------------------------------|
| rbx  | `record` (held through FNV)       |
| r8   | `host_len` (saved before `mul`)   |
| rsi  | `host_ptr`                        |

Scratch: `rax`, `rcx`, `rdx`, `rdi`, `r9`, `r10`, `r11`. 1-push is
sufficient because `record` is the only datum we need to hold across
the FNV loop; `host_len` is saved to `r8` (a caller-save that FNV's
`mul rcx` does not touch).

## 8. Lazy-init non-applicability

Not applicable at M6: this module holds no `.bss` state. Every
`HostAnnot` record is caller-owned on both the parse and check paths.
`_ha_init` is a bare `ret` placeholder; a later landing that adds
`.bss` (per-session hostname counters, a hostname-intern table) will
flesh it out behind the same name without an ABI break.

## 9. Acceptance (8-test corpus)

The acceptance anchor is an 8-test parse+check corpus covering the
grammar's observable states. The corpus runs as a `tools/` driver at
smoke-time once the fuzz-harness bridge (R221.M7) adds a
`FUZZ_KIND_HOSTANNOT` target; at raw M6 the corpus is specified here
and the implementations round-trip under hand inspection.

Each case fixes `bytes` and the expected parse output; where
`_ha_check` runs, it against a fixed `host_ptr`/`host_len` pair.

### 9.1 Case 1: no `@` prefix (plain stage)

```
input:    "echo foo"      (bytes_len = 8)
_ha_parse -> status = HA_OK, bytes_consumed = 0
            record = { magic='HOST', flags=1 (IS_LOCAL), hash=0, inline=zero }
_ha_check(record, 0, 0) -> HA_OK
_ha_check(record, "workstation", 11) -> HA_ERR_HOST_MISMATCH
```

### 9.2 Case 2: `@hostname` with alphanumeric name

```
input:    "@workstation echo foo"      (bytes_len = 21)
_ha_parse -> status = HA_OK, bytes_consumed = 13
            record = { magic='HOST', flags=0, hash=FNV64("workstation"),
                        inline="workstation\0\0\0\0\0" }
_ha_check(record, "workstation", 11) -> HA_OK
_ha_check(record, "laptop", 6) -> HA_ERR_HOST_MISMATCH
_ha_check(record, 0, 0) -> HA_ERR_HOST_MISMATCH
```

### 9.3 Case 3: `@hostname.sub.domain` with dots

```
input:    "@node.local uname"      (bytes_len = 17)
_ha_parse -> status = HA_OK, bytes_consumed = 12
            record = { magic='HOST', flags=0, hash=FNV64("node.local"),
                        inline="node.local\0\0\0\0\0\0" }
_ha_check(record, "node.local", 10) -> HA_OK
```

### 9.4 Case 4: `@hostname` with dash and digits

```
input:    "@lab-01 df -h"      (bytes_len = 13)
_ha_parse -> status = HA_OK, bytes_consumed = 8
            record = { magic='HOST', flags=0, hash=FNV64("lab-01"),
                        inline="lab-01\0\0\0\0\0\0\0\0\0\0" }
_ha_check(record, "lab-01", 6) -> HA_OK
```

### 9.5 Case 5: `@` with no hostname (empty-@ idiom)

```
input:    "@ echo foo"      (bytes_len = 10)
_ha_parse -> status = HA_OK, bytes_consumed = 2
            record = { magic='HOST', flags=1 (IS_LOCAL), hash=0, inline=zero }
_ha_check(record, 0, 0) -> HA_OK
```

### 9.6 Case 6: `@` at EOI (empty-@ at end)

```
input:    "@"      (bytes_len = 1)
_ha_parse -> status = HA_OK, bytes_consumed = 1
            record = { magic='HOST', flags=1 (IS_LOCAL), hash=0, inline=zero }
```

### 9.7 Case 7: hostname at the 16-byte cap

```
input:    "@sixteenbytelong1 cmd"      (bytes_len = 21; hostname = 16 B)
_ha_parse -> status = HA_OK, bytes_consumed = 17
            record = { magic='HOST', flags=0, hash=FNV64("sixteenbytelong1"),
                        inline="sixteenbytelong1" (NO trailing zero -- fills
                                                   the 16-byte inline exactly) }
_ha_check(record, "sixteenbytelong1", 16) -> HA_OK
```

### 9.8 Case 8: hostname exceeds the 16-byte cap

```
input:    "@seventeenbytes.go cmd"      (bytes_len = 22; hostname = 17 B)
_ha_parse -> status = HA_ERR_HOSTNAME_TOO_LONG (0x5301)
            bytes_consumed = end-of-hostname offset (18)
            record: magic 'HOST' + flags u32 = 0 (zero-fill left intact;
                   NO IS_LOCAL set) + hash=0 + inline=zero. The caller
                   discards the record on error.
```

An IPv4-literal case (`@10.0.0.5 cmd`) sits in the dot/digit coverage
of case 3 by the grammar; the parser does NOT distinguish numeric vs
alphabetic bytes.

## 10. Consumer pattern (future pipeline-stage dispatcher)

```
# Pseudocode (NOT part of the M6 landing; sketches the consumer):

stages = _pl_parse(nfc_bytes, nfc_len, pl_buf, pl_buf_cap)  # R223.M1
for stage in stages:
    stage_bytes = nfc_bytes + stage.cmd_name_offset
    stage_len   = ... (stage.cmd_name_len + argv spans)
    r = _ha_parse(stage_bytes, stage_len, &host_annot, 32)  # R223.M6
    if r.status == HA_OK:
        if host_annot.flags & IS_LOCAL:
            dispatch_local(stage_bytes + r.bytes_consumed, ...)
        else:
            dispatch_remote(host_annot.hostname_hash,
                            host_annot.hostname_inline,
                            stage_bytes + r.bytes_consumed, ...)
    else:
        diagnose(r.status, stage_bytes, r.bytes_consumed)
```

The R223.M1 Pipeline parser does NOT need to know about hostname
annotations; it tokenises `|`-separated stages uniformly. The
dispatcher is where the hostname annotation becomes load-bearing.

## 11. Where this is NOT

- **NOT a DNS resolver.** The parser accepts any ASCII LDH-plus
  (`[A-Za-z0-9.-]+`) up to 16 bytes; it does NOT resolve the
  hostname. Resolution is the substrate's job.
- **NOT a federation planner.** The record identifies ONE host; a
  stage that should fan out to a group (`@lab:*`, `@group:devs`)
  waits for M6.3 federation syntax.
- **NOT the encrypted-transport wire-up.** The record is a HAND-OFF
  point; the substrate consumes it. See
  `design/shell/remote-shell-daemon.md` and
  `design/shell/remote-shell-hybrid-kem.md`.
- **NOT a connectivity probe.** `_ha_check` validates record-vs-host
  AGREEMENT at parse time; it does NOT test whether the host is
  reachable.

## 12. File footprint

- `tools/user/libpdx-pds-parser/src/hostname_annot.pdx` (NEW,
  ~700 LOC) -- the module.
- `design/shell/hostname-annotation.md` (NEW; THIS FILE) -- the
  design doc.
- `tools/user/libpdx-pds-parser/src/lib.pdx` (patch) -- flip
  `LPX_PDS_PARSER_R223_M6_READY` from 0 to 1; update comment;
  version 1.26.0 -> 1.27.0.
- `tools/user/libpdx-pds-parser/caps.decl` (patch) -- add
  `0x5300..0x53FF` error-band section; R223.M6 catalogue paragraph;
  R223.M6 linker-dep paragraph.
- `tools/user/libpdx-pds-parser/CHANGELOG.md` (patch) -- `[1.27.0]`
  stanza at top.
- `tools/user/libpdx-pds-parser/STATUS.md` (patch) -- milestone
  landing note.
- `.plans/scratch/CHANGELOG-R223M6.md` (NEW) -- the per-primitive
  CHANGELOG scratch for main-agent consolidation per
  `feedback_paideia_as_parallel_changelog`.

Zero `.bss` footprint at M6 (no label-intern table; no cache; no
counter).

## 13. Forward path (M6.1..M6.5)

**M6.1 (long-hostname mode).** Hostnames > 16 bytes get a pointer-
indirect encoding: the record's inline slot becomes
`(ptr_u64_in_arena, len_u16, flags_u16)` with a flag bit discriminating
inline vs. pointer. The 32-byte stride stays unchanged. The caller
owns a per-session long-hostname arena.

**M6.2 (strict-federation refusal of empty-@).** A thread-local
toggle makes `@` with no hostname return `HA_ERR_SYNTAX` (`0x5300`)
instead of silently emitting the LOCAL record. The default stays
permissive.

**M6.3 (federation syntax).** `@group:rule` and `@*` sketches for
stage fan-out. The record grows a `kind` field distinguishing SINGLE
(M6 default), GROUP, GLOB. Pure parser-tier work; the substrate
runtime materialises the fan-out.

**M6.4 (hostname intern table).** A per-session `.bss` intern table
dedupes repeated hostnames across a long pipeline. `_ha_init` goes
non-bare. Keeps the per-record 32-byte stride.

**M6.5 (canonical-form normalisation).** An opt-in pass that
lowercases, Punycode-decodes, and strips a trailing dot BEFORE
hashing. The raw-bytes mode stays available for daemons that pin on
a specific wire-form.

## 14. Related docs

- `design/shell/pipeline-stage-parser.md` (R223.M1) -- the stage
  tokeniser this module post-passes on.
- `design/shell/pipeline-record-projection.md` (R223.M2) -- the
  record-projection parser (sibling R223 primitive).
- `design/shell/where-filter-op.md` (R223.M3) -- the filter combinator.
- `design/shell/sort-group-reduce.md` (R223.M4) -- the aggregation
  combinators.
- `design/shell/remote-shell-daemon.md` -- the encrypted-transport
  substrate the record ultimately feeds.
- `design/shell/remote-shell-hybrid-kem.md` -- the post-quantum KEM
  wire-up.
- `feedback_pdx_encoder_pitfalls` -- the paideia-as encoder discipline
  this module honours verbatim.
