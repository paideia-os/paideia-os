# Import resolution + module graph (R227.M3)

**Status:** parser-tier landing (R227.M3). Kernel-tier wire-up for the
VFS `stat` probe deferred to R227.M3.3.
**Issue:** paideia-os#2705 (R227.M3).
**Umbrella:** paideia-os#2491 (R227 pds container / loader).
**Module:** `tools/user/libpdx-pds-parser/src/import_resolve.pdx`
(`ImportResolve`).
**Error band:** `0x5900..0x59FF`.
**Mirror:** paideia-os#2622 (R133.M3 kernel-side ImportGraph) --
adjacency row shape and DFS algorithm shared.

## 1. Scope and motivation

A `.pds` source may declare `#import "<path>" as <name>` directives that
reference other `.pds` sources on the local pdx-filesystem. R227 is the
umbrella for the pds container / loader; R227.M1 (header pragmas) and
R227.M2 (cap-decl checker) landed earlier at the KERNEL tier. R227.M3
(THIS landing) lands the parser-tier HALF of the import-graph
machinery: a self-contained primitive the shell / REPL / loader can
call to

1. **Parse** one `#import "path" as name` directive into a 48-byte
   `ImportDirective` record (`_ir_parse_directive`).
2. **Resolve** the quoted path against the project root (the directory
   of the module FILE whose text is being parsed) and the system root
   (the standard library location at `/pds/`), reporting
   `E1101_RESOLVE_FAILED` on neither-branch-matches and
   `E1103_PATH_TRAVERSAL` on a `..` component that escapes both roots
   (`_ir_resolve_path`).
3. **Build** the module-dependency adjacency table at the parser tier,
   enforcing `E1102_DUPLICATE_NAME` for `as name` collisions within
   the same source (`_ir_build_graph`).
4. **Detect** cycles via iterative three-colour DFS -- byte-for-byte
   mirror of R133.M3 ImportGraph's algorithm at the kernel tier, with
   `E1100_IMPORT_CYCLE` on back-edge (`_ir_detect_cycle`).

The two halves of the import-graph machinery -- the parser tier (THIS
module) and the kernel tier (R133.M3) -- share the ADJACENCY ROW SHAPE
exactly (36-byte stride: `u32 n_imports` + `u32[8] imports`). The
kernel-tier cycle detector re-runs over the parser-emitted adjacency as
a defensive guard against adversarial dynamic-load scenarios.

## 2. Grammar

```
ImportDirective := '#import' WS+ '"' Path '"' WS+ 'as' WS+ Name
WS              := 0x20 | 0x09 | 0x0A | 0x0D
Path            := ( '/'? [A-Za-z0-9._-/] )+   byte length 1..256
                  (interior '..' allowed; validated at RESOLVE time
                   against the project + system roots)
Name            := [A-Za-z_] [A-Za-z0-9_]*     byte length 1..16
```

Semantics:

- `#import "foo/bar.pdx" as bar`
  -> resolve "foo/bar.pdx" against project root (iff path does not
     begin with '/') OR system root (iff path begins with '/'); emit
     edge (current_module, resolved_module); bind `bar` to the
     resolved module in the per-source name table.
- `#import "lib/x.pdx" as x` followed by `#import "lib/y.pdx" as x`
  -> second emits `E1102_DUPLICATE_NAME`.
- `#import "../../etc/passwd" as pwd`
  -> path traversal escapes BOTH roots -> `E1103_PATH_TRAVERSAL`.
- directive produces an edge to a module that transitively edges back
  to the current module -> `E1100_IMPORT_CYCLE` on the cycle-detection
  pass.

## 3. ImportDirective record (48 bytes)

| offset | size | field          | type     | note                              |
|-------:|-----:|----------------|----------|-----------------------------------|
|      0 |    4 | magic          | u32      | `'IMPT'` LE (0x54504D49)          |
|      4 |    4 | flags          | u32      | bit 0 SYSTEM_PATH / bit 1 RESOLVED / bit 2 CYCLE_SRC |
|      8 |    8 | path_hash      | u64      | FNV-1a 64 of resolved path bytes  |
|     16 |   16 | name_inline    | [u8;16]  | `as <name>`, zero-padded          |
|     32 |   16 | path_prefix    | [u8;16]  | first 16 bytes of resolved path   |

Rationale:

- Stride is 48 B, mirroring the R133.M3 ImportAdjRow stride-plus-some
  margin; a dispatcher indexing an array of ImportDirective records
  multiplies via `shl rN, 5` (* 32) + `shl rM, 4` (* 16) +
  `add rN, rM` (i*32 + i*16 = i*48) -- no 2-op `imul r, imm`.
- Magic `'IMPT'` = 0x54504D49 LE reads as the 4-byte ASCII string
  "IMPT" in a hex-dump sequential scan (byte sequence 49 4D 50 54).
- The 16-byte inline capacity for `name` matches the Name grammar
  ceiling and the DescribeSig / HostnameAnnot inline-ident precedent.
- The 16-byte `path_prefix` is a diagnostic affordance -- a cycle
  error reporter can render `..#import "foo/..." as bar` without
  re-reading the full path. The full path is reproducible by the
  caller via the hash; downstream code that needs the full path bytes
  keeps them in a separate parser-managed pool.

## 4. Adjacency row shape (byte-identical to R133.M3)

```
+----------------------------------------------------------+
| ImportAdjRow (IR_ADJ_STRIDE = 36 bytes)                  |
|   [ 0.. 4]  n_imports  u32   number of valid imports     |
|                              in this row (0..IR_MAX_IMPORTS=8) |
|   [ 4.. 8]  import[0]  u32   destination module index    |
|   [ 8..12]  import[1]  u32                               |
|   ...                                                    |
|   [32..36]  import[7]  u32                               |
+----------------------------------------------------------+
```

Caller supplies `n_nodes` rows laid out contiguously as
`ImportAdjRow[n_nodes]`. Row `i` describes module `i`'s imports;
module indices are u32 ordinals in `[0, n_nodes)`.

Invariants enforced at traversal time:

- (I1) `n_nodes <= IR_MAX_NODES (64)` -- bounds the scratch colour +
  stack arrays.
- (I2) `out_cap >= n_nodes * 4` -- caller buffer has room for the
  post-order u32 stream.
- (I3) per row `i`: `n_imports <= IR_MAX_IMPORTS (8)` -- row fits in
  the fixed stride.
- (I4) per import `j` of row `i`: `j < n_nodes` -- import ordinal is a
  valid module index.

## 5. Traversal algorithm (iterative DFS)

Classic three-colour DFS with an explicit (not recursive) work stack,
so the traversal has NO stack-depth bound beyond `IR_MAX_NODES` frames
(64) and is immune to the kernel's bounded callstack discipline.

- `WHITE (0)` node not yet visited
- `GRAY  (1)` node currently on the DFS stack
- `BLACK (2)` node fully explored

Pseudocode (same shape as R133.M3):

```
dfs_build_order():
  for each i in 0..n_nodes:
    if color[i] != WHITE: continue
    push (i, next_child_idx = 0)
    color[i] = GRAY
    while stack non-empty:
      let frame = stack.top
      let row   = adj[frame.node]
      if frame.next_child >= row.n_imports:
        color[frame.node] = BLACK
        out.append(frame.node)         // POST-ORDER emit
        stack.pop
        continue
      let child = row.import[frame.next_child]
      frame.next_child += 1
      if child >= n_nodes: return BAD_RECORD
      match color[child]:
        GRAY  => return CYCLE(path_len = stack.depth)
        BLACK => continue              // already fully processed
        WHITE => push (child, 0); color[child] = GRAY
```

Cycle report encoding: the error packs the DFS stack depth into the
high 32 bits of the packed return; the low 16 bits carry the opaque
error tag `E1100_IMPORT_CYCLE` (0x5910).

Scratch arrays live as module-level `mut` statics in `.bss`:

```
_ir_color : [u8;  64]     per-node colour, zeroed per invocation
_ir_stk   : [u64; 128]    DFS work stack; 64 frames * 2 u64
                          (node_idx, next_child_idx)
```

## 6. Path resolver

At raw M3 the resolver (`_ir_resolve_path`) is a byte-walker that:

(a) if path begins with `/` -> system root prefix (literal `/pds/`, 5
    bytes) + `path[1..]` (strip leading `/`).
(b) else -> project root prefix (literal `./`, 2 bytes) + `path`.

After concatenation, walk the result and refuse any `..` component
that would ESCAPE the root (an unmatched `..` at depth 0 after the
root prefix). On success, write the canonicalised path into
`[out_resolved, out_resolved + resolved_len)`.

The syscall-side `stat` wire-up (actually checking the file exists)
is deferred to M3.3. At raw M3 the resolver is pure byte walk +
path-traversal refusal.

## 7. Return codes (band 0x5900..0x59FF)

| code                     | hex    | surface                                           |
|--------------------------|--------|---------------------------------------------------|
| `IR_OK`                  | 0      | success on every entry point                      |
| `IR_ERR_SYNTAX`          | 0x5900 | `_ir_parse_directive`: malformed bytes            |
| `IR_ERR_PATH_TOO_LONG`   | 0x5901 | path > 256                                        |
| `IR_ERR_NAME_TOO_LONG`   | 0x5902 | name > 16                                         |
| `IR_ERR_OUT_TOO_SMALL`   | 0x5903 | out null or capacity too small                    |
| `IR_ERR_BAD_RECORD`      | 0x5904 | magic mismatch or bad adjacency child index       |
| `IR_ERR_TOO_MANY_IMPORTS`| 0x5905 | adjacency row n_imports > 8                       |
| `IR_ERR_TOO_MANY_MODULES`| 0x5906 | n_directives / graph_len > 64                     |
| `E1100_IMPORT_CYCLE`     | 0x5910 | DFS back-edge; stack depth in high 32             |
| `E1101_RESOLVE_FAILED`   | 0x5911 | neither project nor system root resolves          |
| `E1102_DUPLICATE_NAME`   | 0x5912 | `as name` collision within source                 |
| `E1103_PATH_TRAVERSAL`   | 0x5913 | `..` escapes both roots                           |

Slots `0x5907..0x590F` reserved for M3.1+ parse / resolve diagnostics.
Slots `0x5914..0x59FF` reserved for M3.2+ graph / cycle diagnostics.

## 8. Public API summary

| entry point                  | signature                                             | role                                              |
|------------------------------|-------------------------------------------------------|---------------------------------------------------|
| `_ir_init`                   | `() -> ()`                                            | defensive scrub of live-count scalar              |
| `_ir_parse_directive`        | `(bytes, len, out, out_cap) -> packed`                | emit one 48-B ImportDirective record              |
| `_ir_resolve_path`           | `(path_bytes, path_len, out_resolved, out_cap) -> packed` | project/system root resolve + traversal refusal |
| `_ir_build_graph`            | `(directives, n_dirs, out_graph, out_cap) -> packed`  | emit R133.M3-shaped adjacency table               |
| `_ir_detect_cycle`           | `(graph, graph_len, out_cycle_path, out_cap) -> packed` | iterative DFS cycle detector                    |

Register maps (SysV):

- `_ir_init()` -> `()`
- `_ir_parse_directive(rdi=bytes, rsi=bytes_len, rdx=out, rcx=out_cap)` -> `rax = (bytes_consumed << 32) | status`
- `_ir_resolve_path(rdi=path_bytes, rsi=path_len, rdx=out_resolved, rcx=out_cap)` -> `rax = (resolved_len << 32) | status`
- `_ir_build_graph(rdi=directives, rsi=n_directives, rdx=out_graph, rcx=out_cap)` -> `rax = (n_rows << 32) | status`
- `_ir_detect_cycle(rdi=graph, rsi=graph_len, rdx=out_cycle_path, rcx=out_cap)` -> `rax = (count << 32) | status`

## 9. Acceptance -- 20-test corpus

The acceptance smoke exercises each public entry point against a
representative input corpus of 20 cases. Each row names the input, the
primitive under test, and the expected low-16 packed status.

| #   | input / scenario                                                            | primitive                | expected status             |
|----:|------------------------------------------------------------------------------|--------------------------|-----------------------------|
|  1  | `#import "foo/bar.pdx" as bar`                                               | `_ir_parse_directive`    | `IR_OK`                     |
|  2  | `#import "/lib/x.pdx" as x` (system path)                                    | `_ir_parse_directive`    | `IR_OK` + SYSTEM_PATH flag  |
|  3  | `#import "" as x` (empty path)                                               | `_ir_parse_directive`    | `IR_ERR_SYNTAX`             |
|  4  | `#import "x" as` (missing name)                                              | `_ir_parse_directive`    | `IR_ERR_SYNTAX`             |
|  5  | `#import "x" x`  (missing `as`)                                              | `_ir_parse_directive`    | `IR_ERR_SYNTAX`             |
|  6  | path of 257 bytes                                                            | `_ir_parse_directive`    | `IR_ERR_PATH_TOO_LONG`      |
|  7  | name of 17 bytes                                                             | `_ir_parse_directive`    | `IR_ERR_NAME_TOO_LONG`      |
|  8  | out == 0                                                                     | `_ir_parse_directive`    | `IR_ERR_OUT_TOO_SMALL`      |
|  9  | out_cap == 47                                                                | `_ir_parse_directive`    | `IR_ERR_OUT_TOO_SMALL`      |
| 10  | resolve `foo.pdx` (project)                                                  | `_ir_resolve_path`       | `IR_OK` -> `./foo.pdx`      |
| 11  | resolve `/lib/x.pdx` (system)                                                | `_ir_resolve_path`       | `IR_OK` -> `/pds/lib/x.pdx` |
| 12  | resolve `../../etc/passwd` (traversal)                                       | `_ir_resolve_path`       | `E1103_PATH_TRAVERSAL`      |
| 13  | resolve `` (empty)                                                           | `_ir_resolve_path`       | `E1101_RESOLVE_FAILED`      |
| 14  | build graph over 3 non-colliding directives                                  | `_ir_build_graph`        | `IR_OK` (3 rows)            |
| 15  | build graph with two `as foo` directives                                     | `_ir_build_graph`        | `E1102_DUPLICATE_NAME`      |
| 16  | build graph with corrupted magic                                             | `_ir_build_graph`        | `IR_ERR_BAD_RECORD`         |
| 17  | build graph with 65 directives                                               | `_ir_build_graph`        | `IR_ERR_TOO_MANY_MODULES`   |
| 18  | cycle-detect over acyclic 4-node chain                                       | `_ir_detect_cycle`       | `IR_OK` (4 modules)         |
| 19  | cycle-detect over 3-cycle (A->B->C->A)                                       | `_ir_detect_cycle`       | `E1100_IMPORT_CYCLE`        |
| 20  | cycle-detect over row with n_imports=9                                       | `_ir_detect_cycle`       | `IR_ERR_TOO_MANY_IMPORTS`   |

## 10. Interactions

- **R133.M3 (kernel ImportGraph)** -- adjacency row shape is byte-
  identical; the kernel-tier cycle detector re-runs over the parser-
  emitted adjacency as a defensive guard.
- **R227.M1 / R227.M2 (kernel pds container / cap-decl)** -- these
  gates admit the `.pds` container BEFORE the import-resolution pass;
  a container that fails cap-decl is never admitted here.
- **R221.M1 (Utf8Nfc)** -- the parser operates on ALREADY-NORMALISED
  NFC bytes; the caller walks text through Utf8Nfc first and hands the
  normalised bytes to `_ir_parse_directive`.
- **R221.M6 (SpanMap)** -- diagnostic error reporting at the directive
  level consults SpanMap for the original source-byte offsets of the
  directive run. R227.M3 does not call SpanMap directly; the caller
  carries the directive's `src_offset` for the diagnostic.

## 11. Forward path

- **M3.1** Non-ASCII path support: UTF-8 identifier bytes in path (per
  PRECIS-FreeformClass + PDS-O1 import-UTF8 allowance).
- **M3.2** Interned name table: hash-based lookup for repeated import
  names across concurrent source parses.
- **M3.3** Resolve syscall wire-up: at raw M3 the resolver validates
  path shape but does NOT call `stat`; M3.3 wires in the kernel-side
  VFS probe. On stat-failure the resolver surfaces
  `E1101_RESOLVE_FAILED` with the stat errno packed as a secondary
  hint in bits [63:48] (TBD at M3.3).
- **M3.4** Multi-source concurrent parse: at raw M3 the pool is
  singleton `.bss`; M3.4 moves it to per-source handle.
- **M3.5** Per-directive edge computation via name-table consult:
  at raw M3 `_ir_build_graph` emits placeholder edges (i -> (i+1) mod
  n); M3.5 elaborates to lookup the resolved module index in the
  per-source name table.

## 12. Related

- `src/kernel/core/pds/import_graph.pdx` (R133.M3 ImportGraph; kernel-
  tier mirror).
- `design/kernel/pds-import-graph.md` (R133.M3 design doc).
- `design/terminal/semantic-shell-materialization-plan.md` §4 R227.
- `tools/user/libpdx-pds-parser/src/utf8_nfc.pdx` (R221.M1 Utf8Nfc,
  the normalising substrate the directive bytes pass through).
- `tools/user/libpdx-pds-parser/src/span_map.pdx` (R221.M6 SpanMap,
  the span-tracking primitive consulted at diagnostic time).
