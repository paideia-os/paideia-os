// design/shell/renderer-override-as-syntax.md
# `as` renderer-override syntax — design

**Umbrella:** paideia-os R129 ("render: Kitty + fallback pipeline").
**Milestone:** R129.M5 (paideia-os#2608, Wave UMB-W19).
**Status:** landing 2026-10-14.
**Module:** `src/kernel/core/term/renderer_registry.pdx`.

## 1. Position in the terminal substrate

```
            +---------------------------+   +----------------------------+
            | R129.M1  XTGETTCAP probe  |   | R129.M2  Kitty APC emitter |
            +------------+--------------+   +--------------+-------------+
                         |                                 |
                         | caps hint                       | rgba+W+H
                         v                                 v
            +---------------------------+                  |
            | R129.M3  ANSI-256 table   |                  |
            +------------+--------------+                  |
                         ^                                 |
                         | packed row grid                 |
            +---------------------------+                  |
            | R129.M4  schema formatter |                  |
            +------------+--------------+                  |
                         ^                                 |
                         | dispatch                        |
            +---------------------------+------------------+
            | R129.M5  renderer         |
            |   registry (this)         |  <----- shell parser sees
            +---------------------------+          "<cmd> ... as <name>"
```

R129.M5 adds a **named, user-visible selector** that lets a shell command
or pipeline force a specific stdout renderer with an `as <renderer>`
tail, bypassing the default per-capability choice.

M5 is deliberately **not** a renderer. It is a thin substrate with two
responsibilities:

1. **Name registry.** A static 7-entry table maps a stable ASCII name to
   a renderer id and back. The id is the sole over-the-wire identity
   the shell carries from parse through dispatch.
2. **Dispatch router.** `_renderer_dispatch` consumes a renderer id and
   a 4-tuple `(tty_fd, data_ptr, data_len, schema_ptr)` and routes to
   the matching M-module entry point under a capability fallback matrix.

Everything else (parser hooks, cap probing, concrete bytewise renderers)
lives in neighbouring modules; M5 only knits them together behind a
single `as` surface.

## 2. Shell surface — grammar

```
command        := word (SP word)*
cmd_with_as    := command SP 'as' SP renderer_name
renderer_name  := 'table' | 'kitty' | 'schema' | 'raw'
                | 'plot'  | 'json'  | 'csv'
```

Examples:

```
ls -l                       # default: no override
ls -l as table              # force ANSI-256 tabular (M3)
img.png as kitty            # force Kitty APC bitmap (M2)
log.jsonl as raw            # pass bytes straight to UART
jobs as schema              # force M4 schema dispatch
metrics as plot             # reserved; falls back under matrix
events.ndjson as json       # reserved; falls back under matrix
rows.csv as csv             # reserved; falls back under matrix
```

### 2.1 Parser contract (shell lexer)

The shell lexer (lives in a future wave at `src/shell/` or in
`shell/line_disc.pdx`; M5 does not land it, only specifies it) is
expected to:

1. Tokenise the input line into argv.
2. Inspect the **tail** of argv for the two-token pattern
   `[... , "as", <name>]`.
3. If present, strip both tokens from argv, then call
   `_rr_lookup(name_ptr, name_len) -> renderer_id | 0xFF`.
4. If `0xFF` (`RR_ID_NONE`), report `SH_ERR_UNKNOWN_RENDERER` and
   refuse the command (do not fall back to default — the user asked for
   a specific one).
5. Stash the id in the per-command execution record; downstream stdout
   plumbing honours it in step 3.5.

**Standalone-only.** The lexer recognises `as` **only** as a standalone
argv token at the tail (`argv[argc-2] == "as"`), never embedded. The
following lines are **not** overrides and `as` passes through to the
command as an ordinary argv element:

```
ls as/dir                   # 'as/' is a path prefix
echo "as table"             # 'as' is inside a quoted string
grep as file.txt            # 'as' is the first argv (search pattern)
rename a as b               # 'as' sits in the middle, not the tail
cmd as                      # trailing bare 'as' with no name — error
```

The last line (bare `as` with no following name) is a parse error
(`SH_ERR_RENDERER_MISSING_NAME`); the lexer never silently drops it.

### 2.2 Pipeline-tail placement

A pipeline like `cmd1 | cmd2 as table` applies the override to the
**pipeline's final stdout**, not to cmd1's. Formally the parser treats
`as <name>` as a two-token suffix on the whole command group, not on
any single command. The parser already groups by `|` before stripping
the trailing `as`; M5 inherits that behaviour. A multi-stage pipeline
with `as` nested per stage (`cmd1 as table | cmd2`) is not supported at
M5 and is reserved for a future wave.

### 2.3 Why trailing position only

Placing `as` at the tail avoids any ambiguity with option parsers that
already consume mid-line tokens. The alternative syntaxes considered:

| Shape                           | Rejected because                            |
|---------------------------------|---------------------------------------------|
| `--render=table` (GNU-style)    | collides with every command's own flags      |
| `cmd | render table` (pipe)     | makes `render` a reserved keyword mid-line   |
| `cmd !table` (sigil)            | sigil budget too narrow; collides with hist  |
| `cmd ::table` (type-ascription) | reserves `::` across the whole shell grammar |
| `as table : cmd`  (prefix)      | commits the renderer before the command runs |

Trailing `as <name>` is unambiguous, aligns with English reading order,
and leaves the whole mid-line argv namespace to the command's own
parser.

## 3. Renderer registry — table

Seven renderer entries. The ids are **not** padded or reserved for
future expansion inside the 0..6 band; a new renderer appends id 7+
and bumps `RR_RENDERER_COUNT`.

| Id | Name     | Backing module             | Status at M5             |
|---:|----------|----------------------------|--------------------------|
|  0 | `table`  | R129.M3 `_ansi256_table_render` | wired               |
|  1 | `kitty`  | R129.M2 `_kitty_image_rgba`     | wired                |
|  2 | `schema` | R129.M4 `_schema_fmt_render`    | wired                |
|  3 | `raw`    | pass-through via `uart_putc`    | wired                |
|  4 | `plot`   | future (R129.M8+)               | reserved; falls back |
|  5 | `json`   | future (serial-record emitter)  | reserved; falls back |
|  6 | `csv`    | future (serial-record emitter)  | reserved; falls back |

### 3.1 Name encoding

Names are 7-bit ASCII, lowercase, no NUL terminator. The registry
stores them as a packed array of `{name_ptr: u48, name_len: u16}` 8-byte
words — the same shape M3/M4 use for header-text pointers. The seven
name byte strings (`"table"`, `"kitty"`, `"schema"`, `"raw"`, `"plot"`,
`"json"`, `"csv"`) are stored concatenated in a single immutable byte
blob `_rr_name_blob` to let the loader place one `.rodata` region.

Max name length is 8 (`"schema"` is 6; the budget leaves slack for a
future `"24bit"` or `"compact"`). `RR_NAME_MAX = 16` in the public
constants is the enforced cap on any argument the lexer passes to
`_rr_lookup`; longer inputs short-circuit to `RR_ID_NONE`.

### 3.2 Lookup

```
_rr_lookup(name_ptr: u64, name_len: u64) -> renderer_id | 0xFF
```

Linear scan over 7 entries. Each entry comparison is a length check
followed by a byte-wise `memcmp` loop. The whole lookup is bounded at
`7 * 8 = 56` byte compares in the worst case; a hash table is not worth
the setup cost at this cardinality.

Returns the id (`0..6`) on hit, or `0xFF` (`RR_ID_NONE`) on miss. The
caller never confuses a hit with a miss because every valid id fits in
one byte and the `0xFF` sentinel is unused by the table.

### 3.3 Reverse lookup

```
_rr_name(renderer_id: u64) -> name_ptr | 0
```

Returns the packed `{name_ptr | name_len}` 8-byte word for a valid id,
or `0` for an out-of-range id. Used by diagnostic / log emitters that
want to echo the renderer selection back to the operator.

## 4. Dispatch — `_renderer_dispatch`

```
_renderer_dispatch(renderer_id, tty_fd, data_ptr, data_len, schema_ptr)
                    -> errno
```

| Argument       | Register | Semantics                                       |
|----------------|----------|-------------------------------------------------|
| `renderer_id`  | rdi      | 0..6 (0xFF-safe: returns `RR_ERR_UNKNOWN`)       |
| `tty_fd`       | rsi      | Forwarded identity (every backend bypasses)     |
| `data_ptr`     | rdx      | Renderer-specific pointer (see 4.1)             |
| `data_len`     | rcx      | Renderer-specific length / packed dims (see 4.1)|
| `schema_ptr`   | r8       | Schema descriptor for `schema`; 0 otherwise     |
| return         | rax      | `RR_OK` or `RR_ERR_*` or propagated backend err |

### 4.1 Per-renderer argument shape

| Renderer | `data_ptr`                   | `data_len`                           | `schema_ptr`      |
|----------|------------------------------|--------------------------------------|-------------------|
| `table`  | rows byte block (M3 layout)  | `(row_count << 32) | col_count`      | column desc ptr   |
| `kitty`  | RGBA pixel block             | `(width << 32) | height`             | 0 (ignored)       |
| `schema` | typed-record byte block      | `record_count` (low 32 bits)         | schema descriptor |
| `raw`    | byte stream                  | byte count                           | 0 (ignored)       |
| `plot`   | reserved                     | reserved                             | reserved          |
| `json`   | reserved                     | reserved                             | reserved          |
| `csv`    | reserved                     | reserved                             | reserved          |

The packed `(u32 << 32 | u32)` convention for `data_len` is chosen to
keep the dispatch ABI at exactly five arguments (SysV register limit
before stack arguments start). For `schema` the single `record_count`
is adequate; the field count is derived from the schema's own
`SF_TYPE_END` sentinel. For `kitty` the width/height already max out
at 1024, so a 32-bit half-word apiece is far more than enough.

### 4.2 Branch ladder

The dispatcher is a flat `cmp rdi, N; je rr_d_<name>` ladder. No LUT /
jump-table is used at M5 — the cardinality (7) and the per-renderer
call-site layout differ too much for a uniform shape to pay off.

### 4.3 Return semantics

- `RR_OK` (0): backend returned success.
- `RR_ERR_UNKNOWN` (0x1B00): `renderer_id` was `0xFF` or `>= 7`.
- `RR_ERR_INCOMPATIBLE` (0x1B01): backend rejected the data shape
  (e.g. `kitty` on an ANSI-only terminal after fallback refused, or
  `plot` / `json` / `csv` at M5 before their renderer lands).
- Backend passthrough: `AT_ERR_*` (0x1800+), `SF_ERR_*` (0x1900+),
  `KG_ERR_*` (0x1700+), `XT_ERR_*` (0x1400+). The bands are disjoint
  (M5 owns 0x1B00..0x1BFF; see 4.4), so a diagnostic shell can
  identify the layer by its band.

### 4.4 Return-code bands (whole substrate, updated)

| Band          | Owner                                   |
|---------------|-----------------------------------------|
| `0x1400..`    | R129.M1 XTGETTCAP probe                 |
| `0x1700..`    | R129.M2 Kitty graphics                   |
| `0x1800..`    | R129.M3 ANSI-256 table                   |
| `0x1900..`    | R129.M4 schema formatter                 |
| `0x1B00..`    | **R129.M5 renderer registry (this)**     |

The `0x1A00..` band is deliberately skipped and reserved for a future
R125/R127 bridge if the shell parser grows its own band.

## 5. Fallback matrix

The core rule: when the terminal's capability vector refuses the
requested renderer, the dispatcher walks a **fixed** per-renderer
fallback chain and tries the next entry. Each chain terminates at
`raw` so the data always lands on the UART; `RR_ERR_INCOMPATIBLE` is
returned only when **the user's request** cannot be served, never
because the terminal was underpowered.

### 5.1 Fallback chain

```
    kitty  -->  schema  -->  table  -->  raw
    schema -->  table   -->  raw
    table  -->  raw
    plot   -->  table   -->  raw
    json   -->  raw
    csv    -->  raw
    raw    -->  <terminal>
```

### 5.2 Transition triggers

| Renderer | Fallback triggered when...                                 |
|----------|------------------------------------------------------------|
| `kitty`  | `_kitty_graphics_available(tty_fd) == 0` (probe refused)   |
| `schema` | `schema_ptr == 0`                                           |
| `table`  | `data_ptr == 0` or `data_len == 0`                          |
| `plot`   | backend not landed (M5 always falls back)                   |
| `json`   | backend not landed (M5 always falls back)                   |
| `csv`    | backend not landed (M5 always falls back)                   |
| `raw`    | never (terminal is the hard wall)                           |

### 5.3 Honouring the operator's intent

A `kitty` request that falls through to `schema` is a soft downgrade:
the operator still sees their data, structured by whatever schema
the pipeline provides. A `plot` request on today's substrate silently
becomes a `table` — the fallback matrix is explicit about this so the
operator can read the renderer-registry doc and know what to expect.
A future wave will add an `AT_FLAG_WARN_FALLBACK` the operator can
flip in their shell profile to emit a one-line stderr note on every
non-trivial downgrade.

## 6. Interaction with R125.M4 cap-check

R125.M4 (`design/shell/capability-typed-arguments.md`) added capability
typing to shell argv. The renderer selection is **advisory** and does
not consume a capability at M5: the shell's own command execution
already carries the port-IO capability needed for every renderer, and
the renderer id is a plain integer selector, not a capability handle.

The deferred wave **R129.M6** will introduce a `KIND_RENDERER`
capability so a sandboxed command can only invoke renderers it was
explicitly granted. The handoff from today's untyped integer id to a
cap-handle will be a one-line signature change in `_renderer_dispatch`
(the id becomes a cap-decoded id), and the registry layout is already
compatible: `_rr_lookup` returns the id-after-decode, and the
cap-minter will own the id-under-capability mapping. M5 reserves this
by naming the dispatch entry point `_renderer_dispatch` (not `_rr_dispatch`),
leaving the `_rr_` prefix for registry-internal helpers so the public
entry can be re-shaped to `_renderer_cap_dispatch` without a rename
cascade through the shell.

## 7. Scope at M5

- Static 7-entry registry (table, kitty, schema, raw, plot, json, csv).
- `_rr_lookup`, `_rr_name`, `_renderer_dispatch` public API.
- `table`, `kitty`, `schema`, `raw` wired to their M-module backends.
- `plot`, `json`, `csv` reserved; each walks its fallback chain to the
  first wired backend and returns that backend's status (so a `plot`
  call still renders as a table and returns `AT_OK` on success). The
  reservation is **wire** (name registered, id reserved) +
  **soft-fallback** (does not break); it is not a stub-with-TODO that
  would surprise an operator. `RR_ERR_INCOMPATIBLE` is defined for the
  future case where a non-raw-reachable chain is added (today every
  chain terminates at `raw`, so this code is never returned at M5).
- Fallback matrix implemented inline in the dispatcher.
- Capability probe cached per call (no cross-call cache at M5; the
  probe is cheap and this keeps the registry stateless).

## 8. Explicit non-scope at M5

- No shell-side parser landing — the lexer that strips the `as <name>`
  tail is a separate module and lands in a future shell wave. M5 only
  **specifies** the parser contract (Section 2.1) and **owns** the
  registry/dispatch backend.
- No `KIND_RENDERER` cap integration (deferred to R129.M6).
- No per-column SGR via `color_hint` (the schema-driven-formatter doc's
  original M5 proposal); that work is pushed to R129.M7.
- No streaming / incremental dispatch — one `_renderer_dispatch` call
  per rendered record set.
- No parallel-renderer fan-out (`as table,json`); M5 is single-renderer.
- No persistent cap vector cache in the registry; the registry is
  stateless across calls at M5.
- No logging of fallback decisions. R129.M8 wires `AT_FLAG_WARN_FALLBACK`
  into stderr; M5 does not surface the decision.

## 9. Memory sizing

| Buffer         | Size (bytes) | Purpose                               |
|----------------|-------------:|---------------------------------------|
| `_rr_entries`  |           56 | 7 entries × 8 bytes `{ptr48 | len16}` |
| `_rr_name_blob`|           31 | packed `tablekittyschemarawplotjsoncsv` |
| `_rr_caps`     |            8 | reserved for M6 cap-handle table      |

Total `.rodata`: ~95 bytes. The registry fits in one cache line and
has no `.bss` of its own; the dispatcher's stack frame is 6 pushes +
0 scratch (see Section 11).

## 10. Encoder-pitfall discipline

Standard set from `~/.claude/.../memory/MEMORY.md` → `pdx encoder
pitfalls`:

- No `test rN, rN` — all zero tests use `cmp rN, 0; j{e,ne}`.
- No 2-op `imul rN, imm`. The one multiplication in the lookup
  (`i * 8`) uses `shl rN, 3`, not `imul`.
- No `and rN, imm64`. Masks are `0xFF` (byte) / `0xFFFF` (word) /
  `0xFFFFFFFF` (dword, imm32-safe) only.
- Signed compares (`jl`, `jge`) are avoided; renderer ids are u8-sized.
- Module basename `RendererRegistry` matches `renderer_registry.pdx`.
- Reserved-label prefixes: `rr_` for registry helpers (lookup, name,
  memcmp); `rr_d_` for dispatcher sub-labels (one per renderer).
  None collide with M1's `xt_*`, M2's `kg_*`, M3's `at*_`, or M4's
  `sf*_` families.
- Cross-module calls (`_kitty_graphics_available`, `_kitty_image_rgba`,
  `_ansi256_table_render`, `_schema_fmt_render`, `uart_putc`) resolve
  as RIP-relative; the linker emits `R_X86_64_PC32`.

## 11. Stack discipline

| Function             | Pushes | Scratch | Steady `rsp%16` | Per-call pad   |
|----------------------|-------:|--------:|-----------------|----------------|
| `_rr_memcmp`         |      0 |       0 | 8               | — (leaf)       |
| `_rr_lookup`         |      4 |       0 | 8               | per-call +8    |
| `_rr_name`           |      0 |       0 | 8               | — (leaf)       |
| `_renderer_dispatch` |      6 |       0 | 8               | per-call +8    |

Both `_rr_lookup` and `_renderer_dispatch` carry even push counts, so
`rsp%16` stays at `8` across the prologue and every nested backend
call needs an explicit `sub rsp, 8` / `add rsp, 8` to land `%16==0`
at the call site. The raw-path loop inside `_renderer_dispatch` uses
`sub rsp, 24` instead of `sub rsp, 8` because it spills `rcx` and `r9`
across the `uart_putc` call (8 bytes of pad + 8 bytes `rcx` + 8 bytes
`r9` = 24, which lands `%16==0` at the call site: `(8 + 48 + 24) %
16 == 0`). The one leaf `_rr_memcmp` has zero pushes; its sole caller
(`_rr_lookup`) absorbs the alignment cost on its own frame.

## 12. Call-graph

```
_renderer_dispatch
   |
   +-- cmp renderer_id band -> RR_ERR_UNKNOWN tail
   |
   +-- renderer == kitty:
   |     _kitty_graphics_available(tty_fd)
   |       -> yes: _kitty_image_rgba(tty_fd, ptr, w, h)
   |       -> no:  fall through to schema
   |
   +-- renderer == schema:
   |     schema_ptr == 0 -> fall through to table
   |     else _schema_fmt_render(tty_fd, schema, ptr, cnt, flags=0)
   |
   +-- renderer == table:
   |     data_ptr == 0 -> fall through to raw
   |     else _ansi256_table_render(tty_fd, ptr, rows, desc, cols, flags=0)
   |
   +-- renderer == raw:
   |     loop i in 0..data_len: uart_putc(ptr[i])
   |
   +-- renderer in {plot, json, csv}:
         walk fallback chain; return RR_ERR_INCOMPATIBLE if nothing
         wired (impossible at M5 since every chain ends at raw).
```

## 13. Caller recipe

A shell plugin consumes the registry as follows:

```
// 1. Lexer strips tail "as <name>" if present.
argc, argv = tokenise(line)
if argc >= 2 and argv[argc-2] == "as":
    name_ptr, name_len = argv[argc-1], |argv[argc-1]|
    rid = _rr_lookup(name_ptr, name_len)
    if rid == 0xFF:
        report SH_ERR_UNKNOWN_RENDERER; return
    argc -= 2
else:
    rid = DEFAULT_RENDERER      // caller-provided default
                                // (today: 2 == schema if schema_ptr
                                //  present, else 0 == table)

// 2. Run the command; collect stdout into data_ptr/data_len.
run(argv[0..argc], &data_ptr, &data_len, &schema_ptr)

// 3. Dispatch.
err = _renderer_dispatch(rid, tty_fd, data_ptr, data_len, schema_ptr)
if err != 0:
    log err band -> which layer failed
```

The lexer, run-step, and default-selector live outside M5; they are
sketched here to show how the registry threads into a complete shell
cycle.

## 14. Follow-on work

- **R129.M6** — `KIND_RENDERER` capability + `_renderer_cap_dispatch`
  entry (replaces today's untyped id with a cap-decoded one).
- **R129.M7** — per-column SGR via `color_hint` (was the original M5
  slot in `schema-driven-formatter.md`; pushed back by one wave).
- **R129.M8** — `plot` renderer landing (uses the ANSI-256 colour
  blocks as a density heatmap over a bucketed numeric column).
- **R129.M9** — `json` / `csv` serialising renderers; both consume the
  same typed-record stream the schema formatter does but emit a
  machine-readable line instead of a cell grid.
- **R129.M10** — operator-visible `AT_FLAG_WARN_FALLBACK` on stderr.
- **R129.M11** — multi-renderer fan-out (`as table,json` tee).

Each follows the same registry-first discipline: the backend lives in
its own module; the registry owns id-to-name and id-to-backend;
callers never hard-code a renderer by cross-module symbol.

## 15. Tests (future)

Standing kernel-smoke pattern (see
`design/testing/compositor-test-runner.md` for the harness shape):

- `rr_lookup_smoke`: feed each of the 7 names and 3 non-matches
  (`""`, `"TABLE"`, `"json5"`); assert the ids match 0..6 and the
  misses return 0xFF.
- `rr_name_smoke`: for each id in 0..7 and three out-of-range values
  (7, 8, 0xFF), assert the reverse lookup returns the expected
  `{ptr | len}` word or 0.
- `rr_dispatch_table_smoke`: build a trivial M3 column descriptor and
  one data row; call `_renderer_dispatch(RR_RENDERER_TABLE, ...)`;
  verify the UART log fingerprint matches
  `render override ok mode=0`.
- `rr_dispatch_fallback_smoke`: call `_renderer_dispatch(RR_RENDERER_KITTY, ...)`
  on an ANSI-only mock terminal; verify the output matches the
  schema-fallback path (`render override ok mode=2`).
- `rr_dispatch_raw_smoke`: call `_renderer_dispatch(RR_RENDERER_RAW,
  ..., ptr=&"hello", len=5)`; verify `hello` appears verbatim on the
  UART.
- `rr_dispatch_unknown_smoke`: call `_renderer_dispatch(0xFF, ...)`;
  assert return == 0x1B00.

Each smoke emits the fingerprint `render override ok mode=<n>` where
`<n>` is the renderer id actually used after fallback. The acceptance
line on paideia-os#2608 asks for this fingerprint and three distinct
renderings of the same input; the harness above gives six.
