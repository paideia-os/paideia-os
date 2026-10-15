# Completion protocol (LSP-style)

**Wave UMB-W28** - R228.M1 (paideia-os #2711).

The completion protocol is the kernel-side substrate that drives
tab-completion in the paideia-os shell. Its request/response shape is
patterned on the Language Server Protocol (LSP, Microsoft, 2017), but
the protocol framing is binary (fixed-size records on a kernel ring
buffer, not JSON over stdio) and the dispatcher runs inside the kernel
rather than as a separate process.

This document captures the M1 landing (the protocol substrate) and
anchors the forward path to M2+ (per-kind handlers, syscall / cap
wiring, session-aware completion, score ranking).

Code: `src/kernel/core/shell/completion_proto.pdx` (module
`CompletionProto`, label prefix `cp_`).

----

## 1. Rationale: why in-kernel

The shell line editor already runs in userspace (`src/user/shell`),
and so does its line-reader loop. The *source material* for completion
(the command registry, the fact store, the directory tree, the schema
member tables) is almost entirely kernel-owned: each of those sits
behind a capability kind that enforces its own rights discipline.

Two implementation shapes are possible:

**Option A (self-service, rejected).** Hand every piece of source
material to userspace via a read-only shadow of the backing store, let
the shell's line editor walk it. Rejected because (1) the shadow is
either stale (not what the user sees) or expensive to keep live, and
(2) every substrate - command registry, fact store, directory iterator,
schema member table - would have to expose a userspace iteration API
plus a cross-session capability bridge for cross-session completion.

**Option B (RPC, chosen).** Keep the source material where it is, let
the shell's line editor issue a one-shot *completion request* that the
kernel services synchronously, returning a bounded result set. This is
the LSP shape, lifted into the kernel. Each per-kind handler reaches
directly into the backing store it already has rights to; the shell's
line editor only sees items.

The RPC overhead is one request record (64 bytes) + one response
record (128 bytes) + up to 32 items (2 KB), i.e. ~2.2 KB per keystroke
that triggers completion - well within the budget for a line editor
that fires completion on tab or on an idle timeout, not on every
keystroke.

----

## 2. Comparison with LSP

| LSP                                       | paideia-os completion            |
|-------------------------------------------|----------------------------------|
| JSON-RPC 2.0 over stdio                   | binary records on a cap endpoint |
| `textDocument/completion`                 | `CP_KIND_*` dispatch             |
| `CompletionItem` with 15+ optional fields | 64-byte item: `kind` + `text`    |
| server computes `insertText`              | caller substitutes `text`        |
| `isIncomplete`                            | `truncated_flag`                 |
| `label` + `kind` + `detail` + `doc`       | `kind` + raw bytes               |

The paideia-os surface is deliberately leaner. LSP's rich-item fields
exist to let a GUI render completion menus with icons, type signatures,
docstrings, and snippets. Paideia-os's completion target is a
terminal-shell line editor; a kind byte and raw bytes are enough.
Future UX (R228.M4+) can carry side-band metadata via the reserved
tail without widening the item size.

----

## 3. Wire format

### 3.1 Request record (64 B)

```
offset  size  field
0       4     session_id       (u32, SS_POOL slot 0..7)
4       4     request_id       (u32, caller-chosen correlator)
8       2     kind             (u16, CP_KIND_* enum)
10      2     prefix_offset    (u16, byte offset from req_ptr)
12      2     prefix_len       (u16, bytes)
14      2     cursor_pos       (u16, reserved for M2+ context)
16      4     context_offset   (u32, byte offset from req_ptr)
20      4     context_len      (u32, bytes)
24      40    reserved         (zero at mint)
```

### 3.2 Response record (128 B)

```
offset  size  field
0       4     request_id       (u32, echoed)
4       2     n_items          (u16, 0..CP_MAX_ITEMS)
6       2     truncated_flag   (u16, 0 or 1)
8       4     items_offset     (u32, byte offset within items_blob)
12      4     items_blob_len   (u32, bytes written)
16      4     status           (u32, CP_OK or CP_ERR_*)
20      108   reserved         (zero at mint)
```

**Specification reconciliation.** The R228.M1 briefing specified the
response record as 128 B with explicit fields totalling 16 B and a
108-byte reserved tail - 124 B total, 4 B short of the declared
footprint. We treat the 128 B total as the binding invariant (the
record is embedded in a 128 B IPC frame slot on the wire; any other
size breaks downstream frame alignment) and resolve the shortfall by
inserting a `status: u32` at [+16]. The reserved tail then runs from
[+20..+128] = 108 B exactly as the briefing specifies, and the
response gains an engineering improvement: every reader of the record
sees the status without having to inspect the packed-return register.

The implementation records this reconciliation at
`src/kernel/core/shell/completion_proto.pdx` SECTION 1.

### 3.3 Completion item (64 B)

```
offset  size  field
0       1     kind    (u8, CP_KIND_*)
1       1     len     (u8, 0..CP_ITEM_TEXT_MAX = 62)
2       62    text    (raw UTF-8, no trailing NUL required)
```

`text[len..62]` is zero-filled by `cp_pack_item`, so a reader may
consume the full 64 B span deterministically.

### 3.4 Buffer discipline

The caller places the request header AND the prefix/context bytes in
the same buffer, and the request's `prefix_offset` / `context_offset`
fields resolve as *byte offsets from `req_ptr`*. This mirrors the pdxfs
manifest discipline (fixed header + variable tail in one allocation)
and avoids the capability-forwarding question of how a second buffer
would be authorised through the completion syscall.

The response's `items_offset` is a byte offset within `items_blob`
(the separate output buffer the caller allocates for returned items).
M1 always writes items contiguously starting at `items_blob[0]`, so
`items_offset == 0` on every response.

----

## 4. Return codes

| Code                   | Value   | Meaning                                        |
|------------------------|---------|------------------------------------------------|
| `CP_OK`                | `0`     | Request processed; see `n_items`               |
| `CP_ERR_BAD_REQUEST`   | `0x2F00`| Null pointer, resp_cap too small, session id out of range, kind == 0 |
| `CP_ERR_UNKNOWN_KIND`  | `0x2F01`| Kind not in CP_KIND_* enum                     |
| `CP_ERR_OUT_TOO_SMALL` | `0x2F02`| items_blob_cap below one item (= 64 B)         |
| `CP_UNIMPLEMENTED`     | `0x2F03`| Kind known but handler not yet wired (M1 only wires COMMAND) |

The public entry point `_cp_request` returns a packed `u64`:

```
status  = ret & 0xFFFFFFFF
n_items = ret >> 32
```

The response record carries the same fields separately. A well-behaved
caller reads either source.

----

## 5. Completion kinds

| Kind                    | Value | Backing store                      | M1 status |
|-------------------------|-------|------------------------------------|-----------|
| `CP_KIND_COMMAND`       | `1`   | `_kcm_table` (KIND_CMD_MODULE, R123.M1) | wired |
| `CP_KIND_PATH`          | `2`   | CoW FS directory (R134)            | stub      |
| `CP_KIND_SCHEMA_FIELD`  | `3`   | R222.M1 SchemasSig member table     | stub      |
| `CP_KIND_DATALOG_PREDICATE` | `4` | R226 datalog predicate index     | stub      |

### 5.1 COMMAND (wired at M1)

The COMMAND handler walks the KIND_CMD_MODULE row pool via the
R123.M5 discovery iterator:

```
row := kcm_list_first()
while row != CM_LIST_END and n_items < max_items:
    name_len := kcm_read_name(row, scratch)
    if name is valid and name starts with prefix:
        pack(items_blob[n_items], CP_KIND_COMMAND, scratch, name_len)
        n_items += 1
    row := kcm_list_next(row)
```

`max_items := min(CP_MAX_ITEMS=32, items_blob_cap / 64)`. If the
iteration hits `max_items` and would have continued, the response's
`truncated_flag` is set.

The prefix match is case-sensitive, byte-for-byte. An empty prefix
matches every row (useful for the pure "what commands exist" query).

Interaction with R123 cross-cuts:

- The handler uses the public `kcm_list_first` / `kcm_list_next` /
  `kcm_read_name` surface (R123.M5), not the raw `_kcm_table` layout
  - so a future R123.M6+ refactor of the row structure cannot break
  this handler.
- A torn iteration (a `cmd_module_close` landing between a
  `kcm_list_next` and the subsequent `kcm_read_name`) returns a stale
  row id whose read yields `CM_BAD_ROW`; the handler treats that as
  "skip this row" and continues. No crash, no bogus completion.
- Rights: because the completion handler runs in-kernel and reaches
  the discovery iterator directly (not through `cap_handler_cmd_module`),
  it bypasses the `R_CM_READ` rights check that an untrusted caller
  would face. This is correct at M1 (the handler is called only by
  `_cp_request`, which is itself gated by whatever cap the shell was
  minted). R228.M2's syscall wrapper will carry the shell's own cap
  into the handler and the handler can then re-gate per-kind if the
  rights model needs it.

### 5.2 PATH (M2 stub)

The handler will:

1. Resolve `req.context_offset / context_len` to a directory path.
2. Open the directory via `vfs_open` with READDIR rights.
3. Walk entries via `vfs_dir_readnext`, filtering by prefix.
4. Pack each match as `CP_KIND_PATH`.

Depends on R134 directory-iterator capability (currently in design).

### 5.3 SCHEMA_FIELD (M2 stub)

The handler will:

1. Resolve `req.context_offset / context_len` to a schema-signature
   handle (hex-encoded id).
2. Consult the R222.M1 SchemasSig member-table export API (currently
   internal-only; R222.M3 will export it).
3. Enumerate field names matching the prefix.

### 5.4 DATALOG_PREDICATE (M2 stub)

The handler will:

1. Treat the session as the datalog scope.
2. Scan the R226 predicate index built by the datalog parser landing.
3. Return each predicate head matching the prefix.

----

## 6. Dispatch pipeline

```
                      req_ptr --+
                                v
                        _cp_request
                        /    |    \
                 validate  write   emit
                   kind    resp    log
                     |      ^
                     v      |
                 cp_do_<kind>
                        |
                        v
                 backing-store
                 iterator
```

Validation precedes dispatch. Dispatch invokes exactly one
`cp_do_<kind>` function. The response record is written in every
return path (OK, error, unimplemented) so a reader need not consult
the packed return. A `COMPLETION OK` fingerprint fires on every
return path with four KV pairs (sid, rid, kind, items) so smoke
harnesses can observe the dispatch outcome.

The in-kernel surface of M1 is one function (`_cp_request`). M2's
syscall wrapper, M3's shell integration, and M4's cross-session widen
this to a small handful; the record formats and status codes stay
stable.

----

## 7. Session awareness

The `session_id` field is validated at M1 (range check against
`SS_POOL_MAX = 8`) but not consulted during dispatch - COMMAND is
session-independent, so inside session S the answer is the same as
inside session S'. M2 wires the three stub kinds to per-session state:

- PATH: looks up the session's cwd (via `shell_session.pdx` cwd slot,
  landing with R127.M-later) to resolve relative context paths.
- SCHEMA_FIELD: resolves the schema signature through the session's
  capability env, so a session that can see schema `S` offers its
  members while a session that cannot does not.
- DATALOG_PREDICATE: scopes to the session's own fact store (R139.M3+
  cross-session fact sharing lets a session see across the boundary
  with an explicit grant).

Cross-session completion (R228 x R139.M-series) lets a user in session
A ask for completions as if they were in session B, provided B has
granted that visibility - a user-facing analogue of
`cross_session_open`.

----

## 8. Error handling

Every error path writes a well-formed response record (zero `n_items`,
status set to the error, `truncated_flag` from `_cp_last_truncated`
which starts at zero for every request) and emits the standard
`COMPLETION OK` fingerprint (the "OK" there is "the dispatcher
returned a well-formed response", not "the request succeeded"). A
caller that sees `status != 0` reads the record for diagnostics and
discards the items blob.

The one exception: when `resp_ptr == 0` or `req_ptr == 0`, there is
no response record to write. The handler bumps the stat and returns
the packed error anyway; the caller recovers via the return register.

----

## 9. Capacity ceilings

| Ceiling              | Value           | Rationale                        |
|----------------------|-----------------|----------------------------------|
| `CP_REQ_BYTES`       | 64 bytes        | one cacheline                    |
| `CP_RESP_BYTES`      | 128 bytes       | two cachelines, holds the full enum of status fields with room for v2 |
| `CP_ITEM_BYTES`      | 64 bytes        | matches `CM_NAME_MAX`, fits one path component |
| `CP_ITEM_TEXT_MAX`   | 62 bytes        | item - kind - len                |
| `CP_MAX_ITEMS`       | 32              | one keystroke's worth of options is enough for a human |

The 32-item cap bounds the per-request response blob at 32 * 64 =
2048 bytes = half a page. A caller that passes `items_blob_cap` below
2048 gets a `max_items := items_blob_cap / 64` effective cap and -
when the iteration hits that cap - a `truncated_flag = 1`.

----

## 10. Encoder-pitfall discipline

Standard paideia-as encoder posture. Specific pitfalls this module
avoids:

- No `test rN, rN` - every zero-check uses `cmp reg, 0`.
- No 2-op `imul r, imm` - item stride 64 uses `shl 6`; max-items
  divide uses `shr 6`.
- No `and reg, imm64` - the 32-bit mask stages through `r10`.
- No multiline `pub let name = "..."` - every tag string is a
  single-line literal with `\0` appended.
- Reserved labels: `cp_` prefix with second-level qualifiers
  (`cp_in_`, `cp_nt_`, `cp_pm_`, `cp_pi_`, `cp_dc_`, `cp_rq_`). None
  of `loop / if / else / let / fn` collides.
- Module basename `CompletionProto` matches file basename
  `completion_proto.pdx`.
- Fingerprint tag sizes include the trailing NUL (string length + 1).
- `mov_w` / `mov_d` zero-extend u16 / u32 loads to the full 64-bit
  register per `vops.pdx` L614 discipline.

----

## 11. Deferred work (R228.M2+)

### R228.M2 - stub handlers come online

- `cp_do_path`: directory walk + prefix filter. Depends on R134
  directory iterator capability.
- `cp_do_schema_field`: schema signature member enumeration. Depends
  on R222.M3 member-table export.
- `cp_do_datalog_predicate`: predicate index scan. Depends on R226
  predicate index.

### R228.M3 - UX / syscall surface

- `sys_completion_request`: syscall wrapping `_cp_request`. The syscall
  copies the caller's request record into a kernel scratch buffer
  (so the prefix bytes cannot be swapped out mid-dispatch), invokes
  the dispatcher, and copies the response record + items blob back
  to userspace.
- `cap_handler_completion_proto`: cap_invoke dispatch so completion
  is reachable via the capability surface.
- Shell line editor integration (`src/user/shell/line_editor.pdx`
  tab-key handler).

### R228.M4 - cross-session

- Validates that the invoking session has visibility rights on the
  target session (per `cross_session_open` discipline, R139).
- Resolves PATH / SCHEMA_FIELD / DATALOG_PREDICATE against the target
  session's cwd / capability env / fact store.

### R228.M5+ - ranking

- Score each item by `frecency * prefix-weight * recent-use`.
- Sort before writing the items blob.
- A caller may opt out of ranking (M1 ordering == source iteration
  order) via a request flag.

### R228.M6 - rich items

- Side-band metadata via the reserved tail: type hint, docstring
  pointer, deprecation flag.
- Snippet-style completion for CP_KIND_COMMAND (match + argument
  skeleton).

----

## 12. Open questions

1. **Should the items blob live inside the response record?** Today
   it is a separate caller buffer, which lets a caller size it
   independently (and skip allocating for `CP_UNIMPLEMENTED` /
   `CP_ERR_*` responses). The alternative is to make the response
   record variably-sized (fixed 128 B header + variable item tail);
   this would keep everything in one buffer but complicates the IPC
   framing. **Current answer**: keep them separate; the two-buffer
   shape is cheap enough.

2. **Should prefix matching be case-insensitive?** M1 is byte-exact.
   A case-insensitive variant lives in the design space but hits an
   ambiguity in Unicode (case folding is locale-dependent). M1
   defers; a per-request flag in `kind`'s high byte or in the
   reserved tail can land case-insensitive later without breaking
   the record format.

3. **Should `n_items == 0` fire a different fingerprint?** The M1
   emit uses one tag (`COMPLETION OK`) across all return paths. A
   `COMPLETION EMPTY` tag would help the smoke harness distinguish
   "the dispatcher ran but found nothing" from "the dispatcher
   returned a hit". Deferred to M2's fingerprint-coverage review.

4. **Should the response record carry a continuation cursor?** M1
   does not; a caller that hits the cap sees the first 32 matches
   only. M2's syscall wrapper could add an opaque cursor in the
   reserved tail so a caller can re-issue with "continue from here".
   Deferred.

----

## 13. References

- `src/kernel/core/shell/completion_proto.pdx` - the M1 implementation.
- `src/kernel/core/cap/kind_cmd_module.pdx` - the R123.M5 discovery
  iterator the COMMAND handler consumes.
- `src/kernel/core/svc/shell_session.pdx` - the SS_POOL that
  `session_id` indexes into.
- `design/terminal/command-registry.md` - the on-disk registry whose
  rows feed the COMMAND handler.
- LSP spec, `textDocument/completion` request:
  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/
