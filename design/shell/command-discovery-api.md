# Command discovery API (R123.M5)

Status: landed (Wave UMB-W7, paideia-os #2589).
Depends on: R123.M1 (KIND_CMD_MODULE substrate), R123.M2 (on-disk TOML parser),
R123.M3 (in-process functor-invoke), R123.M4 (out-of-process functor-invoke).

## Why

R123.M1..M4 give the shell a way to **register** a command module, **look it
up** by name, and **invoke** it in-process or out-of-process. None of them
answer the question *"what commands exist?"*. Three concrete consumers need
that answer:

1. **`help`** — list every available command with a one-line summary.
2. **Tab-completion** — the semantic shell's completion engine needs the full
   set of candidate names at the cursor's current position in the parse.
3. **`which`** — a diagnostic that reports which module backs a given name.

These three consumers converge on a single primitive: *enumerate the live
rows of the KIND_CMD_MODULE row pool, and read each row's module name*.

M5 adds that enumeration surface to `KindCmdModule` without touching M1's row
shape, M2's parser, M3's in-process functor path, or M4's out-of-process
functor path.

## Shape

Three new ops are added to the `cap_handler_cmd_module` dispatch cascade.
They sit alongside M1's `LOOKUP` / `LIST` / `CLOSE` arms and share the
dispatcher's existing op_arg encoding (bits [7:0] = op_code,
bits [39:8] = handle = row_id for the two row-indexed ops).

| op_code | name              | arg          | return                              | right     |
|---------|-------------------|--------------|-------------------------------------|-----------|
| 3       | `CM_OP_LIST_FIRST`| (none)       | first live row_id, or `CM_LIST_END` | `R_CM_READ` |
| 4       | `CM_OP_LIST_NEXT` | row_id       | next live row_id, `CM_LIST_END`, or `CM_BAD_ROW` | `R_CM_READ` |
| 5       | `CM_OP_READ_NAME` | row_id, out  | byte length, or `CM_BAD_ROW`        | `R_CM_READ` |

Two new in-band return codes extend the kind_cmd_module failure band from
0xFFFFFCC5 to 0xFFFFFCC7:

- `CM_LIST_END = 0xFFFFFCC6` — iterator exhausted (no live row at or after
  the current cursor). Distinct from `CM_ROW_NONE` (0xFF) which is an
  internal scan sentinel.
- `CM_BAD_ROW  = 0xFFFFFCC7` — the caller passed a row_id outside
  `[0, CM_MODULE_MAX)`.

## Semantics

### `CM_OP_LIST_FIRST`

Scan `_kcm_table[0 .. CM_MODULE_MAX)` and return the first row with
`flags & CM_FLAG_LIVE` set. If the pool is empty, return `CM_LIST_END`.

The seed op is handle-free (no arg); callers always begin iteration here.

### `CM_OP_LIST_NEXT`

Given the row_id a previous `LIST_FIRST` or `LIST_NEXT` returned, scan rows
`[row_id + 1 .. CM_MODULE_MAX)` and return the first live one. Exhaustion
yields `CM_LIST_END`. An out-of-range row_id (negative via wrap, or
`>= CM_MODULE_MAX`) yields `CM_BAD_ROW`.

**Torn iteration semantics**: a row that was live when the caller got it
back from `FIRST`/`NEXT` but that has since been closed is **not** reported
as `CM_BAD_ROW`. `NEXT` begins at `row_id + 1`, so a stale row_id simply
resumes at that offset. This matches the row-pool "soft iterator" idiom
used by `kcm_find_hash`/`kcm_find_empty` in M1: scans always observe the
present-tense `flags` word, never a captured snapshot. A caller that
cares about missed rows can re-seed with `LIST_FIRST`.

### `CM_OP_READ_NAME`

Given a row_id and an output buffer, write the module's name bytes to the
buffer and return the actual byte length (`<= CM_NAME_MAX = 64`).

Byte semantics:

- The name was captured verbatim at `cmd_module_open` time (no case
  folding, no normalisation; the raw bytes the caller passed as
  `name_ptr`/`name_len`). No NUL is appended; callers that want a C string
  pass a buffer of at least `CM_NAME_MAX + 1` and set `buf[returned_len] = 0`
  themselves.
- `out_ptr == 0` is legal — the function returns the byte length without
  touching the buffer. This supports the two-pass idiom
  *size-the-buffer → allocate → read*.
- A dead or out-of-range row_id yields `CM_BAD_ROW` (both for the sized
  query and for a real read).

**Cap-ABI note.** `cap_invoke` carries only three argument slots (rights,
target_ptr, op_arg). `op_arg` is a packed u64 that already encodes
op_code + row_id; a buffer pointer does not fit. The handler therefore
calls `kcm_read_name` with `out_ptr = 0`, so a cap-level `READ_NAME`
returns only the byte length. An in-kernel consumer that needs the actual
bytes calls `kcm_read_name` directly, bypassing the dispatcher. A later
landing (post-M5) may thread a buffer pointer through a widened invoke
ABI or through a per-process scratch slot.

## Name storage

M1's row shape has no byte buffer: the name is reduced to a 64-bit djb2
hash at `cmd_module_open` and only the hash lives in the row. M5 adds two
parallel arrays:

- `_kcm_names : [u8; 512]` — 8 slots of 64 bytes each, slot `k` at
  `[k*64 .. k*64 + 64)`.
- `_kcm_name_lens : [u64; 8]` — slot `k`'s actual byte length.

Both arrays are zero-initialised by `.bss` at real boot; `kcm_table_reset`
scrubs them defensively, matching the existing M1 belt-and-braces pattern.

`cmd_module_open` is extended with one new step between "allocate row"
and "write row": it calls `kcm_name_store(row_id, name_ptr, name_len)`
which byte-copies the bytes into the slot and records the length. The
store happens **before** the row's `flags = LIVE` publish-last write,
so a torn reader that sees `LIVE` always sees a populated name slot.
`cmd_module_close` does **not** scrub the name slot — the empty-row scan
honours `flags == 0` and the next `cmd_module_open` overwrites the slot
before republishing `LIVE`.

## Consumer pattern

The canonical shell `help` loop lives in user-space; the kernel-side
equivalent (for `init` or a future `kshell` built-in) is:

```
# pseudo-pdx
let name_buf : [u8; 65] = uninit;

let row = kcm_list_first();
while row != CM_LIST_END {
    let n = kcm_read_name(row, &name_buf[0]);
    name_buf[n] = 0;                        # NUL-terminate
    klog("cmd: %s\n", &name_buf[0]);
    row = kcm_list_next(row);
}
```

Tab-completion walks the same loop but filters names against a prefix the
shell parser hands in. `which <name>` does a `LIST_FIRST`/`LIST_NEXT` loop
until `READ_NAME` matches the queried bytes exactly, then reports the
hit's row_id as the module handle.

## Where this is NOT

- **Not a cursor.** `LIST_NEXT` returns the row_id of the NEXT live row,
  not an opaque cursor. Callers can snapshot a row_id and reuse it as a
  bookmark; the torn-iteration contract above says what happens if the
  snapshot's row went away.
- **Not a command-level iterator.** M5 enumerates **modules**, not the
  commands those modules expose. Per-module command iteration lands with
  R123.M2's registry (`cr_lookup` + a future `cr_list`) once the registry
  gains an iterator surface of its own.
- **Not transactional.** A `LIST_FIRST`/`LIST_NEXT` traversal is not
  isolated from concurrent `cmd_module_open`/`cmd_module_close`. The
  substrate's "soft iterator" contract (publish-last on `flags`) means
  every row observation is point-in-time consistent, but the traversal
  as a whole can miss rows that appear mid-walk or over-list rows that
  disappear. For `help` and tab-completion this is fine; a strict
  snapshot requires wrapping the walk in the registry's reader lock,
  which R123.M6 may add.

## File footprint

- `src/kernel/core/cap/kind_cmd_module.pdx` extended by three primitives
  (`kcm_list_first`, `kcm_list_next`, `kcm_read_name`), one helper
  (`kcm_name_slot_base` + `kcm_name_store`), two name-store buffers
  (`_kcm_names`, `_kcm_name_lens`), two failure codes (`CM_LIST_END`,
  `CM_BAD_ROW`), three op constants (`CM_OP_LIST_FIRST`,
  `CM_OP_LIST_NEXT`, `CM_OP_READ_NAME`), three dispatcher arms, and
  one new step in `cmd_module_open`.
- No new file at this landing. A dedicated `src/kernel/core/shell/cmd_enum.pdx`
  wrapper is **deferred**: the three primitives are already the iterator,
  and a wrapper would add boot-wiring glue (module import + reset call)
  without additional contract. A later landing may introduce one if a
  user-space consumer needs a batched read (e.g. "give me all live names
  into this buffer at once").

## Encoder posture

Standard paideia-as discipline, no new gaps uncovered:

- All op constants and failure codes fit imm32 (zero-extend via
  `mov rax, imm32`).
- Name slot stride 64 is a power of two → `shl rax, 6` (no imul).
- Row stride 48 continues to use the M1 `mov r11, 48; imul rax, r11`
  reg-reg sequence (no 2-op imul-with-imm form).
- Byte copy in `kcm_name_store` / `kcm_read_name` uses
  `xor r10, r10; mov_b r10, [src+i*1]; mov_b [dst+i*1], r10` — the
  encoder does not zero-extend on its own, per the pipe_backend §57
  discipline, so the pre-zero is mandatory.
- Every label is `kcm_` prefixed (reserved-word discipline: `loop`,
  `if`, `let` are keywords).

## Boot wiring

No change. `kcm_table_reset` (already called at boot in the UMB-W1 wiring)
now also scrubs the two new name arrays as part of the same single call.
`cmd_module_open` populates the name store transparently on every mint —
no caller change is required.
