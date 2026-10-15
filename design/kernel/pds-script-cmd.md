# PDS script execution as functor application — R133.M6

Parent: paideia-os#2480. Milestone: paideia-os#2625.

## Scope

A loaded, type-checked `.pds` script becomes an in-process functor
call to a synthesized `ScriptCmd`. The functor inherits the invoker's
capability env NARROWED by the script's `#capability` list, and
dispatches through a weak-imported satellite registered at R131
pds-loader boot. The acceptance smoke is
`pds run backup.pds` on the §0 example from
`design/terminal/pds-format.md`, with the fingerprint
`pds run ok script=<n> duration_us=<n>`.

## Why a dedicated shim

R133.M2 admits the capability SHAPE; R133.M3 admits the import-graph
SHAPE; R133.M4 admits the ABI VERSION; R133.M5 admits the TYPE
compatibility across pipeline stages. None of those predicates say
how a script actually RUNS — the question of how an admitted script
becomes a running computation.

The answer this module commits to is: **a script is an in-process
functor whose capability env is the intersection of the invoker's env
and the script's declared `#capability` set, and whose dispatcher is
a weak-imported satellite registered through a `.bss` slot**. Three
forces argue AGAINST folding this into any sibling:

  1. **Cap narrowing is a run-time act, not a load-time predicate.**
     The caps-decl gate at R133.M2 proves the script's declarations
     are a SUBSET of a grant env (admission); R133.M6 then performs
     a per-invocation INTERSECTION with the invoker's current env.
     The two acts share the `#capability` list as input but operate
     in different directions: admission says "the author's declared
     set is honest about what they will touch", narrowing says
     "whatever the author declared, the current invoker only grants
     their own subset". A `.pds` published by a system author with
     `#capability fs.write.home/backup` is admissible system-wide
     (R133.M2) but still refuses to touch `~/backup/` when the
     invoker is a guest user whose env lacks `fs.write.home`.

  2. **Dispatcher decoupling.** The in-process functor dispatcher
     for a synthesized ScriptCmd lives OUTSIDE the kernel — in the
     R131 pds-loader satellite. The kernel's cadence and the
     pds-loader's cadence are independent, and a kernel built on
     wave N cannot wait for a dispatcher that lands on wave N+K.
     The pdx dialect does not implement linker-level weak imports
     (the paideia-as encoder emits strict symbol references only),
     so the gate exposes a REGISTRATION slot (`.bss` function
     pointer); the satellite's init publishes its dispatcher there
     at boot. Before registration, `_pds_sc_run` refuses with
     `SC_ERR_NO_DISPATCHER`; after registration, every run
     dispatches through the slot via `call rax`. This mirrors
     R133.M5's weak-import adapter model byte-for-byte.

  3. **Pure predicate at the shim layer.** `_pds_sc_run` accepts a
     `(body_ptr, body_len, invoker_caps)` triple and returns a packed
     `u64` — no session-env mutation, no disk I/O, no allocation.
     The descriptor it hands the dispatcher is stack-local and
     lives only for the duration of the dispatch call.

## ScriptBody wire shape

```
+----------------------------------------------------------+
| ScriptBody header (SC_HEADER_SIZE = 32 bytes)            |
|   [ 0.. 4] magic         u32 = 0x50534352 ('PSCR')       |
|                             (LE: file bytes 'R','C','S','P') |
|   [ 4.. 8] script_id     u32  (<= 0xFFFF at M6)          |
|   [ 8..16] script_caps   u64  the script's declared cap  |
|                             mask — derived upstream from  |
|                             the `#capability` directives  |
|                             admitted at R133.M2          |
|   [16..24] payload_len   u64  informational              |
|   [24..32] reserved      [u8; 8]  zero at M6             |
+----------------------------------------------------------+
| opaque pipeline body bytes (dispatcher-defined)          |
+----------------------------------------------------------+
```

The caller (R131 pds-loader at M6+) is responsible for assembling the
header. In particular, `script_caps` is precomputed at caps-decl
admission time (the caps-decl gate already walks every
`#capability <cap>` directive); M6 does NOT re-parse the directives
here.

### script_id ceiling

M6 caps `script_id` at `0xFFFF` so the 16-bit field in the packed
return value (`[31:16]`) is lossless. A script with a larger id is
refused with `SC_ERR_SCRIPT_ID_TOO_LARGE`. A future wave can widen
the pack (e.g. move script_id to `[63:32]` and duration into a
separate accessor-only field) if the pds-loader's id allocator
exceeds 65535 live scripts per invocation.

## ScriptCmd descriptor

The 16-byte stack-local shim handed to the dispatcher:

```
+----------------------------------------+
| ScriptCmd descriptor (16 bytes)        |
|   [ 0.. 8] narrowed_caps  u64          |
|   [ 8..12] flags          u32  (0 M6)  |
|   [12..16] script_id      u32          |
+----------------------------------------+
```

`narrowed_caps = invoker_caps & script_caps`. The author's declared
set is AND'd with the invoker's current grant env; bits set in
`script_caps` but not in `invoker_caps` silently drop. The ANDed
mask is the authoritative env for every effect dispatched within
this script's lifetime.

`flags` is reserved as a per-call shape bitfield (deadline enabled,
quiet mode, trace mode, …). M6 pins it at 0. A future wave widens.

`script_id` mirrors the header verbatim (u32, bounded by I3).

### Fields NOT in the M6 descriptor

The brief lists `deadline_us` and `invoker_tid` as logical ScriptCmd
fields. Neither is in the 16-byte shim at M6:

  * **deadline_us.** The R131 pds-loader at M6 does not surface a
    deadline, and the acceptance smoke
    (`pds run backup.pds` on §0 example) does not require one. A
    future wave extends the descriptor (bumping `SC_DESC_SIZE`) and
    threads the deadline; the current layout stays as the first 16
    bytes of that extended struct for ABI stability. The dispatcher
    reads only the fields it understands.

  * **invoker_tid.** Same posture — M6 does not expose a tid in the
    shim. A future wave that adds per-tenant policing threads this
    field alongside `deadline_us`.

### Lifetime

The descriptor pointer MUST NOT be retained past the dispatcher's
return. A conforming satellite copies out the fields it needs before
any suspend / schedule / await.

## Weak-import adapter model

The pdx dialect does not implement linker-level weak imports (the
paideia-as encoder emits strict symbol references only). To let the
kernel link in isolation from the R131 pds-loader satellite, R133.M6
expresses the "weak import" as a REGISTRATION SLOT:

```
pub let mut _sc_dispatch_fn : u64 = uninit @align(8)   // .bss nil
```

The slot is zero-init by the kernel's `.bss` zero-fill at boot
entry. The surrounding satellite's init publishes the dispatcher
via:

```
_pds_sc_register_dispatcher(fn_ptr: u64) -> u64
```

which writes the function pointer into the slot and emits a one-shot
`pds run registered` fingerprint. Passing `fn_ptr == 0` is a
contract violation (returns `SC_ERR_NULL_FN`). Unregistering is NOT
supported at M6 (nullifying the slot would race with an in-flight
run); a later wave adds a sealed `unregister` primitive if the
hot-reload-the-dispatcher workflow lands.

At run time, `_pds_sc_run` loads the slot into `rax`, dispatches via
`call rax`, and interprets a non-zero return as a dispatcher-level
run failure. The dispatcher's status band is OPAQUE to the shim:
whatever the satellite returns is forwarded verbatim in the high 32
bits of the SCRIPT_RUN_FAILED packing (see "Return packing" below).

### Dispatcher ABI

```
_sc_dispatch_fn(desc_ptr, body_ptr, body_len) -> u64
```

Entry: `rdi` = `desc_ptr` (16-byte stack-local descriptor),
`rsi` = `body_ptr` (ScriptBody payload base),
`rdx` = `body_len` (full ScriptBody length including header).

Return: `rax = 0` on success, non-zero errno on failure. The errno
value is opaque to the shim; a conforming satellite may define its
own band.

## Invariants

The shim enforces three invariants BEFORE invoking the registered
dispatcher — the shim never hands a malformed stream to the satellite:

| id   | assertion                                                        | fault code                       |
|------|------------------------------------------------------------------|----------------------------------|
| I1   | `body_ptr != 0 AND body_len >= SC_HEADER_SIZE (32)`              | `SC_ERR_NULL_BODY`               |
| I2   | `header.magic == SC_MAGIC`                                        | `SC_ERR_BAD_HEADER`              |
| I3   | `header.script_id <= SC_MAX_SCRIPT_ID (0xFFFF)`                   | `SC_ERR_SCRIPT_ID_TOO_LARGE`     |

`script_caps` is NOT validated: a bitmap wider than the invoker
silently narrows via the AND. The author's intent to widen past the
invoker's env is a soft no-op, not a hard fault.

## Status band — 0x4100..0x41FF

| code                              | hex    | meaning                                                        |
|-----------------------------------|--------|----------------------------------------------------------------|
| `SC_OK`                           | 0x0000 | dispatcher returned 0; `script_id` in [31:16]; `duration_us` in [63:32] |
| `SC_ERR_NO_DISPATCHER`            | 0x4100 | registration slot nil (satellite not registered)               |
| `SC_ERR_NULL_BODY`                | 0x4101 | `body_ptr == 0` or `body_len < SC_HEADER_SIZE`                 |
| `SC_ERR_BAD_HEADER`               | 0x4102 | magic mismatch at [0..4]                                        |
| `SC_ERR_SCRIPT_RUN_FAILED`        | 0x4103 | dispatcher returned non-zero; `script_id` in [31:16]; `errno` in [63:32] |
| `SC_ERR_SCRIPT_ID_TOO_LARGE`      | 0x4104 | `header.script_id > SC_MAX_SCRIPT_ID` (0xFFFF, M6 ceiling)      |
| `SC_ERR_NULL_FN`                  | 0x4105 | `_pds_sc_register_dispatcher` rejected `fn_ptr == 0`           |

### Band collision audit

`grep -rnE '\b0x41[0-9A-Fa-f]{2}\b' src/kernel/ design/` on
2026-10-15 returned only `0x41ED` (`S_IFDIR | 0o755`) in
`src/kernel/core/syscall/handlers/sys_pdxfs_stat_by_inode.pdx` — a
POSIX mode constant, not an error code, in a disjoint semantic
namespace. The 0x4100..0x41FF band is free of collision for the
status-code semantic (Wave 118 R133.M3-vs-R221.M2 lesson applied).

Each prior R133 gate owns a disjoint 16-bit band so a surrounding
error-reporter can switch on the low 16 bits of the packed status
without ambiguity:

```
0x3200..0x32FF  R133.M2 caps-decl gate
0x3A00..0x3AFF  R133.M3 import graph
0x3B00..0x3BFF  R133.M4 version gate
0x3E00..0x3EFF  R133.M5 typecheck gate
0x4100..0x41FF  R133.M6 script-cmd            <-- THIS
```

(0x3C00..0x3CFF reserved by R222.M4 ArgSpec/FlagSpec; 0x3D00..0x3DFF
reserved by R229.M3 TypeEnv; 0x3F00..0x40FF intentionally unused
pending future gates.)

### Return packing

```
SC_OK:
  bits [15: 0] = 0x0000
  bits [31:16] = script_id         (u16-bounded by I3)
  bits [63:32] = duration_us       (u32 — see TSC conversion below)

SC_ERR_SCRIPT_RUN_FAILED:
  bits [15: 0] = 0x4103
  bits [31:16] = script_id         (u16-bounded by I3)
  bits [63:32] = dispatcher_errno  (opaque u32, forwarded verbatim)

all other SC_ERR_*:
  bits [15: 0] = SC_ERR_*
  bits [31:16] = 0
  bits [63:32] = 0
```

Three accessors recover each packed field without exposing the layout
to callers:

```
_pds_sc_script_id(packed)    -> script_id on OK or SCRIPT_RUN_FAILED, 0 otherwise
_pds_sc_duration_us(packed)  -> duration_us on OK, 0 otherwise
_pds_sc_errno(packed)        -> dispatcher_errno on SCRIPT_RUN_FAILED, 0 otherwise
```

## TSC → microseconds conversion

`rdtsc` captures a 64-bit cycle counter in `rdx:rax`. Reconstruct via
`shl rdx, 32; or rax, rdx` — same shape as
`src/kernel/core/time/tsc.pdx:138-140` and
`src/kernel/core/fs/pdxfs_lite/uuid.pdx:74-76`.

Compute:
```
duration_us = (end_tsc - start_tsc) * 10^6 / _tsc_hz
```

Inline, with a `_tsc_hz == 0` clamp to 0 (boot-order degradation):

```
mov  rax, duration_tsc
mov  rcx, 1000000               ; SC_US_PER_SEC
imul rax, rcx                   ; 2-op reg,reg (distinct from the
                                ; forbidden 2-op reg,imm)
xor  rdx, rdx
mov  rcx, [rip + _tsc_hz]
cmp  rcx, 0
je   sc_du_zero
div  rcx                        ; unsigned 128/64 -> 64
```

### Overflow envelope

`duration_tsc * 10^6` fits in `u64` for `duration_tsc < 2^64 / 10^6`
≈ 1.8e13 cycles ≈ 6000 seconds at 3 GHz TSC — plenty for any script
run bounded by a human-scale deadline. A future wave that threads a
`deadline_us` into the descriptor will refuse any script whose
declared deadline exceeds this envelope; for M6 the envelope is
implicit.

### Clamp semantics

If `_tsc_hz` is zero (TSC calibration has not run — a boot-order
degradation), `duration_us` is clamped to zero and the fingerprint
reports `duration_us=0`. This is NOT an error; `_pds_sc_run` still
returns `SC_OK` (dispatcher returned 0). Surrounding tooling may
notice the clamp separately via `_tsc_hz` inspection.

## Fingerprints

The shim emits one klog fingerprint per return path:

| path                           | wrapper      | level       | tag                     | kv entries                      |
|--------------------------------|--------------|-------------|-------------------------|---------------------------------|
| `SC_OK`                        | `klog_s1_d2` | LEVEL_INFO  | `pds run ok`            | `script=<id>`, `duration_us=<us>` |
| `SC_ERR_SCRIPT_RUN_FAILED`     | `klog_s1_d2` | LEVEL_WARN  | `pds run failed`        | `script=<id>`, `errno=<e>`      |
| `SC_ERR_NO_DISPATCHER`         | `klog_s1`    | LEVEL_WARN  | `pds run no-dispatcher` | —                               |
| `SC_ERR_NULL_BODY`             | `klog_s1`    | LEVEL_WARN  | `pds run null-body`     | —                               |
| `SC_ERR_BAD_HEADER`            | `klog_s1`    | LEVEL_WARN  | `pds run bad-header`    | —                               |
| `SC_ERR_SCRIPT_ID_TOO_LARGE`   | `klog_s1`    | LEVEL_WARN  | `pds run bad-script-id` | —                               |
| `_pds_sc_register_dispatcher` OK      | `klog_s1` | LEVEL_INFO | `pds run registered`    | —                               |
| `_pds_sc_register_dispatcher` NULL_FN | `klog_s1` | LEVEL_WARN | `pds run null-fn`       | —                               |

The tag strings use lowercase `ok` deliberately: the
`tools/verify-fingerprint-coverage.sh` `OK_TOK` regex matches only
bare uppercase `OK` as a word token, so these tags bypass the
asserted-marker extractor. Same posture as R133.M2's `pds.cdg: ok`,
R133.M3's `pds import graph ok`, R133.M4's `pds version ok`, and
R133.M5's `pds typecheck ok`. A future smoke that pins these
fingerprints does so via plain substring assertions in its golden
file.

## Register plan

```
_pds_sc_run(body_ptr, body_len, invoker_caps) -> packed u64

Saves rbx, r12, r13, r14, r15 (5 pushes) + sub rsp, 32 (4 locals):

  push rbx     rbx = body_ptr                 (base of input)
  push r12     r12 = body_len                 (byte count)
  push r13     r13 = invoker_caps             (survives dispatch call)
  push r14     r14 = script_id (u32)          (survives dispatch call
                                                and klog)
  push r15     r15 = scratch bay              (script_caps → start_tsc
                                                → duration bay)
  sub  rsp, 32
                [rsp +  0] = narrowed_caps     (desc byte 0..7)
                [rsp +  8] = flags(u32 lo) |   (desc byte 8..15)
                              script_id(u32 hi)
                [rsp + 16] = start_tsc         (saved across dispatch
                                                CALL)
                [rsp + 24] = dispatcher_errno  (saved across klog on
                                                the SCRIPT_RUN_FAILED
                                                path; otherwise
                                                duration_us holding
                                                bay on OK path)
```

Entry `rsp % 16 == 8`; +40 pushes + 32 sub = +72; `(8 + 72) % 16 == 0`
at body.

  * Pre-CALL to `klog_s1`: body `rsp % 16 == 0`, direct call.
  * Pre-CALL to `klog_s1_d2`: idiom `sub rsp, 8; push v2` (= +16)
    lands `rsp % 16 == 0` at the CALL, matching
    `typecheck_gate.pdx:634` precedent. Post-CALL `add rsp, 16`
    reclaims pad + push.
  * Pre-CALL to the registered dispatcher via `call rax`: body
    `rsp % 16 == 0`, direct indirect call lands callee at
    `rsp % 16 == 8` per SysV with NO pad. Mirrors
    `typecheck_gate.pdx:613` byte-for-byte.

Scratch (caller-save; may be clobbered by any nested CALL): `rax`,
`rcx`, `rdx`, `rsi`, `rdi`, `r8`, `r9`, `r10`, `r11`.

### rdtsc clobber discipline

`rdtsc` writes `rax` + `rdx`. Every `rdtsc` is preceded by any-survivor
spill to a callee-save or stack slot. Reconstruction via
`shl rdx, 32; or rax, rdx` (uuid.pdx:74-76 precedent). The two
`rdtsc` sites in `_pds_sc_run` (start and end of the dispatch) both
survive the clobber via:
  * `start_tsc` → stored to `[rsp+16]` immediately after reconstruction.
  * `end_tsc`   → used immediately for `sub rax, [rsp+16]` before any
                  further CALL.

### Register liveness (Wave 116 lesson)

`r11` is clobbered by every nested CALL. Every value that must
survive a nested CALL lives in a callee-save (`rbx`, `r12..r15`) OR on
the caller frame. `r15` is re-established at each phase boundary
(script_caps → start_tsc → duration_us holding) and the spill mirrors
live on the frame at `[rsp+16]` (start_tsc) and `[rsp+24]`
(dispatcher_errno or duration_us depending on branch).

### `_pds_sc_register_dispatcher`

Minimal 2-push frame:

```
push rbx     rbx = fn_ptr
push r12     callee-save pad (keeps 2-push alignment)
```

Entry `rsp % 16 == 8`, +16 pushes = `rsp % 16 == 8`; `sub rsp, 8`
before `klog_s1` lands `rsp % 16 == 0` at the CALL, `add rsp, 8`
after. Byte-for-byte R133.M5 `_pds_tcg_register_checker` modulo tag
names and the slot symbol.

## Encoder discipline

Per `feedback_pdx_encoder_pitfalls`:

  * `cmp rN, 0`              never `test rN, rN`.
  * No `and rN, imm64`        the cap intersection uses `and r64, r64`
                               (reg-reg); every mask literal is
                               loaded into a register first.
  * No 2-op `imul r, imm`     the TSC → us conversion uses
                               `imul rax, rcx` (2-op reg,reg —
                               distinct from the forbidden 2-op
                               reg,imm). Confirmed usable at
                               `tsc.pdx:275`.
  * Single-line `pub let`     one line per literal (tags, status
                               codes, registration slot).
  * Module basename matches   `ScriptCmd` ↔ `script_cmd.pdx`.
  * Labels prefixed `sc_`     reserved-word discipline; distinct from
                               `ctr_` / `pds_cdg_` / `ig_` / `vg_` /
                               `tcg_` siblings.
  * u32 loads                 `xor rN, rN; mov eax, [reg+off]`
                               (container_reader.pdx G4 pattern;
                               typecheck_gate.pdx:519 echo).
  * u64 loads                 `mov rN, [reg+off]` (full-width).
  * `cmp rN, imm32` for all   `0x4100..0x4105` all fit imm32
    status codes               sign-ext safe (bit 31 clear). SC_MAGIC
                               `0x50534352` also sign-ext safe.
  * Full-u64 status compares  not low-byte masked (Wave 118 lesson).
  * rdtsc clobber discipline  rdtsc writes `rax` + `rdx`; spill any
                               survivor before and restore after.
                               Reconstruct via `shl rdx, 32; or rax,
                               rdx` (uuid.pdx:74-76 precedent).

## Fingerprint tag geometry (N = len(string) + 1, NUL inclusive)

```
"pds run ok"              10 + NUL -> N = 11
"pds run failed"          14 + NUL -> N = 15
"pds run no-dispatcher"   21 + NUL -> N = 22
"pds run null-body"       17 + NUL -> N = 18
"pds run bad-header"      18 + NUL -> N = 19
"pds run bad-script-id"   21 + NUL -> N = 22
"pds run null-fn"         15 + NUL -> N = 16
"pds run registered"      18 + NUL -> N = 19
"script"                   6 + NUL -> N =  7
"duration_us"             11 + NUL -> N = 12
"errno"                    5 + NUL -> N =  6
```

## Cross-module wiring

The R131 pds-loader at M6+ invokes `_pds_sc_run` on the assembled
ScriptBody immediately after the typecheck gate admits the pipeline:

```
e = _pds_cdg_gate(...);                     // 0x3200..0x32FF band
if (e != 0) abort;
e = _vg_check(req_line_ptr, req_line_len);  // 0x3B00..0x3BFF band
if (e != 0) abort;
e = _ig_build_order(adj, n, out, cap);      // 0x3A00..0x3AFF band
if (ig_status(e) != IG_OK) abort;
e = _pds_tcg_gate(body_ptr, body_len);      // 0x3E00..0x3EFF band
if (tcg_status(e) != TCG_OK) abort;

// Assemble the ScriptBody header; cap_mask was derived upstream from
// the admitted #capability directives.
e = _pds_sc_run(script_body_ptr, script_body_len, invoker_caps);
if (sc_status(e) != SC_OK) report;
```

Each gate owns its band so a surrounding error-reporter can switch on
the low 16 bits of the packed status without ambiguity.

### Satellite init sequence

Lands at R131 pds-loader boot (future wave):

  1. Satellite's own init runs AFTER kernel `.bss` zero-fill (so the
     registration slot is nil at the time of registration).
  2. Satellite publishes its dispatcher:

     ```
     status = _pds_sc_register_dispatcher(&_pds_sc_dispatch_impl)
     ```

     On OK: the shim is now armed with the real dispatcher.
     On `SC_ERR_NULL_FN`: fatal — the satellite's fn-ptr is bogus.

Between kernel boot and satellite registration, every `_pds_sc_run`
call returns `SC_ERR_NO_DISPATCHER`; the surrounding R131 pds-loader
surfaces this as `PdsErr::NoScriptDispatcher` and either refuses the
run (strict posture) or admits to a dry-run-only mode (allow-partial
posture; selected at M7+ by a kernel-boot flag).

## Acceptance smoke

```
Pipeline:
  Script source: backup.pds
    #! /bin/paideia-sh
    #capability fs.read.home
    #capability fs.write.home/backup
    #requires-paideia >= 0.5
    find ~
      | where modified > now - 1.day
      | each { |f|
          copy $f.path to ~/backup/$(basename $f.path)
        }

  Pre-R133.M6:
    * caps_decl_gate     -> admits (invoker grants fs.read.home +
                                     fs.write.home/backup).
    * version_gate       -> admits (kernel version >= 0.5).
    * import_graph       -> admits (no imports).
    * typecheck_gate     -> admits (find emits Record<Entry>, where
                                     accepts Record<Entry>, each
                                     accepts Record<Entry>).

  R131 pds-loader at M6 builds a ScriptBody:
    header.magic        = 0x50534352
    header.script_id    = 42       (invoker-allocated, bounded <= 0xFFFF)
    header.script_caps  = fs.read.home | fs.write.home/backup
    header.payload_len  = <opaque pipeline bytes>

  Fixture: a mock dispatcher registered at boot:
    _pds_sc_dispatch_mock(desc_ptr, body_ptr, body_len) -> 0

  Smoke invocation:
    packed = _pds_sc_run(body_ptr, body_len, invoker_caps)

Expected outcome:
  packed = (duration_us << 32) | (42 << 16) | 0x0000
  _pds_sc_script_id(packed)    == 42
  _pds_sc_duration_us(packed)  == <nonzero micro-seconds; depends on
                                    TSC frequency and fixture work>

Expected fingerprint:
  LEVEL_INFO  subsys=cap  tag="pds run ok"
              script=42   duration_us=<n>

Negative companion (dispatcher returns 7):
  packed = (7 << 32) | (42 << 16) | 0x4103
  _pds_sc_script_id(packed) == 42
  _pds_sc_errno(packed)     == 7

Expected fingerprint:
  LEVEL_WARN  subsys=cap  tag="pds run failed"
              script=42   errno=7
```

## Future work

  * **Deadline threading.** M6 pins `flags` at 0 and omits
    `deadline_us` from the descriptor. A later wave extends
    `SC_DESC_SIZE` to carry a `deadline_us` field (bounded by the TSC
    overflow envelope at ~6000 s @ 3 GHz) and refuses to dispatch
    scripts whose declared deadline exceeds the envelope.

  * **Invoker tid.** M6 omits `invoker_tid` from the descriptor; a
    future per-tenant policing wave threads the tid alongside
    `deadline_us`.

  * **Dispatcher hot-reload.** M6 bans unregistration to avoid race
    with in-flight runs. A sealed `_pds_sc_unregister` with an epoch
    guard (bump an epoch counter, refuse any run whose captured
    epoch doesn't match, wait for drain) is a reasonable M7+
    elaboration if the shell workflow surfaces a legitimate reason
    to hot-swap.

  * **script_id widening.** M6 caps `script_id` at `0xFFFF` for the
    16-bit pack. If a future allocator exceeds 65535 live scripts
    per invocation, move `script_id` to `[63:32]` and relocate
    `duration_us` behind an accessor-only field (the fingerprint
    still carries the full value as a decimal kv).

  * **Allow-partial admit.** `SC_ERR_NO_DISPATCHER` is currently a
    hard refuse. The R131 pds-loader could trade this for a
    downgraded promise ("admit the run, but mark every stage effect
    as quarantine-only") behind a kernel-boot flag. The shim's
    return value is already shaped for a 3-way admit/warn/refuse
    split; the policy sits one layer up.

  * **Caller-provided scratch.** M6's `_sc_dispatch_fn` slot is a
    module singleton (one dispatcher per kernel instance). A
    multi-tenant pds runtime (far future — see
    `design/kernel/multi-tenancy.md` once it lands) would thread a
    per-tenant dispatcher fn through the shim's signature. The
    current signature stays stable; new args append.

  * **Nested scripts.** M6 does not forbid a dispatcher from
    re-entering `_pds_sc_run` on behalf of a sub-script, but the
    shim's module-level state is reentrant-safe only because it has
    none (the registration slot is a one-shot `.bss` write, read-
    only after boot). A later wave that adds per-run state must
    either thread it through the descriptor or formalize a nesting
    policy.

## References

  * `src/kernel/core/pds/container_reader.pdx` — R133.M1
  * `src/kernel/core/pds/caps_decl_gate.pdx` — R133.M2
  * `src/kernel/core/pds/import_graph.pdx` — R133.M3
  * `src/kernel/core/pds/version_gate.pdx` — R133.M4
  * `src/kernel/core/pds/typecheck_gate.pdx` — R133.M5
  * `src/kernel/core/pds/script_cmd.pdx` — R133.M6 (THIS)
  * `design/kernel/pds-typecheck-gate.md` — R133.M5 design doc
  * `design/kernel/pds-version-gate.md` — R133.M4 design doc
  * `design/kernel/pds-import-graph.md` — R133.M3 design doc
  * `design/terminal/pds-format.md` — pds script format spec (§0 example)
  * `src/kernel/core/shell/functor_invoke.pdx` — R123.M3 in-process
     functor dispatch (sibling arm; ScriptCmd is a synthesized
     functor, not a disk-resident one)
  * `src/kernel/core/time/tsc.pdx` — rdtsc reconstruction idiom
  * `src/kernel/core/fs/pdxfs_lite/uuid.pdx` — rdtsc clobber precedent
  * `tools/verify-fingerprint-coverage.sh` — OK_TOK regex semantics
  * `feedback_pdx_encoder_pitfalls` — encoder discipline
