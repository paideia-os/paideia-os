# `/system/shell/commands.toml` grammar + parser contract

**Issue:** paideia-os#2586 (UMB-W4 R123.M2)
**Code:** `src/kernel/core/shell/cmd_registry_parser.pdx`
**Depends on:** `src/kernel/core/cap/kind_cmd_module.pdx` (UMB-W1 R123.M1, KIND_CMD_MODULE=0x5C)
**Status:** landed 2026-10-11.

## 1. Purpose

The on-disk command registry declares named shell commands and binds each name to a functor path + a required capability label. At boot, the kernel parses this file to populate the `KIND_CMD_MODULE` row pool so later landings (R123.M3 in-process invoke, R123.M5 discovery, R127 tab completion) can resolve a shell-typed command name to a capability substrate row.

The file is a TOML subset chosen for:

* trivially-tokenisable grammar (hand-rolled single-pass byte scanner, no backtracking, no regex, no multiline strings),
* operator-authorable with any text editor,
* diff-stable per entry (one block per command),
* round-trippable with the standard TOML type system (an operator-facing writer / linter can be a straight TOML emitter).

## 2. Formal grammar

```
FILE          := LINE*
LINE          := BLANK | COMMENT | SECTION | KEYVAL
BLANK         := WS* LF?
COMMENT       := WS* '#' .* LF?
SECTION       := WS* '[' 'c' 'o' 'm' 'm' 'a' 'n' 'd' '.' NAME ']' WS* COMMENT? LF?
KEYVAL        := WS* IDENT WS* '=' WS* '"' VALUE '"' WS* COMMENT? LF?

WS            := SP (0x20) | HT (0x09) | CR (0x0D)
IDENT         := [A-Za-z_] [A-Za-z0-9_]*
NAME          := [A-Za-z0-9_]+               ; 1..CRP_NAME_MAX = 64
VALUE         := any byte except '"' (0x22) and LF (0x0A)
```

The scanner is line-oriented. Each line falls into exactly one of the four `LINE` alternatives, chosen by the first non-whitespace byte:

| First non-WS byte | Resolution       |
|-------------------|------------------|
| LF (0x0A) or EOF  | BLANK            |
| `#`  (0x23)       | COMMENT          |
| `[`  (0x5B)       | SECTION          |
| `[A-Za-z_]`       | KEYVAL           |
| anything else     | `CRP_ERR_BAD_SYNTAX` |

Nothing is permitted after `]` in a SECTION or after the closing `"` in a KEYVAL except whitespace or a trailing comment. There is no multi-line value, no array value, no nested table, no inline table, no explicit type suffix. The grammar refuses TOML features the shell-command registry does not need.

## 3. Expected keys per `[command.NAME]` block

```
[command.ls]
functor    = "pdx.builtin.ls"
capability = "fs.read"

[command.cat]
functor    = "pdx.builtin.cat"
capability = "fs.read"
```

Two keys are expected per block:

* `functor` -- dotted path to the command's implementation (`pdx.builtin.<name>` for in-process builtins; the convention expands when out-of-process command servers land in R123.M4).
* `capability` -- the capability label the shell dispatcher must hold to invoke this command.

At R123.M2 the parser VALIDATES THE SHAPE of each key=value line but DOES NOT BIND the value into the `KIND_CMD_MODULE` row. Binding lands in R123.M3+ once the row grows per-command functor-id + cap-env columns. Unknown keys inside a block are accepted at R123.M2 (shape-validated and dropped); a later landing may reject unknown keys to catch typos.

## 4. Semantic actions

Per `SECTION`: call `cmd_module_open(name_ptr, name_len)` from `kind_cmd_module.pdx`. The returned value folds into the parser result as:

| cmd_module_open return  | Parser action                           |
|-------------------------|-----------------------------------------|
| handle in [0, 8)        | continue; `CRP_ST_ROWS_ADDED` += 1      |
| `CM_ALREADY_LOADED` (0xFFFFFCC5) | continue (idempotent dedup)    |
| `CM_BAD_NAME`      (0xFFFFFCC1) | return `CRP_ERR_BAD_SYNTAX` with byte offset of the name |
| `CM_MODULE_FULL`   (0xFFFFFCC2) | return `CRP_ERR_TOO_MANY_ROWS` |

Per `KEYVAL`: validate shape, discard value.

Per `BLANK` / `COMMENT`: skip.

## 5. Return codes

| Code                        | Value      | Meaning                                                                |
|-----------------------------|------------|------------------------------------------------------------------------|
| `CRP_OK`                    | `0x0000`   | Clean scan.                                                            |
| `CRP_ERR_BAD_SYNTAX`        | `0x0C01`   | First malformed byte. Bits 32..63 pack the byte offset in the buffer.  |
| `CRP_ERR_TOO_MANY_ROWS`     | `0x0C02`   | `cmd_module_open` returned `CM_MODULE_FULL`; pool exhausted.           |
| `CRP_ERR_READ`              | `0x0C03`   | `vfs_read` returned the 0xFFFF... sentinel.                            |
| `CRP_ERR_NO_FILE`           | `0x0C04`   | `vfs_open` returned 0. Non-fatal at boot.                              |
| `CRP_ERR_RELOAD_BUSY`       | `0x0C05`   | Another reload is already in flight (see §13 Hot-reload).              |

The byte-offset packing on `CRP_ERR_BAD_SYNTAX` lets an operator jump to the offending byte with `tail -c +<offset+1>` on the file.

## 6. Row cap

The parser's row ceiling is 8, matching `CM_MODULE_MAX` in `kind_cmd_module.pdx` §2 (8 rows x 48 bytes = 384 bytes). The parser does not maintain a separate counter: `cmd_module_open` is the source of truth. Growing the ceiling is a two-site change (raise `CM_MODULE_MAX` + grow `_kcm_table` to match); no change in this file.

## 7. Boot sequence

```
kernel_main.pdx
    ...
    call _mb_init;
    call _cmd_registry_load_boot;    <-- UMB-W4 R123.M2 HOOK
    call x2apic_probe_bsp;
    ...
    (much later in the cascade)
    call cmd_module_init;
    call cmd_registry_init;
    call cmd_registry_parser_init;   <-- UMB-W4 R123.M2 defensive scrub
    call kind_surface_init;
    ...
```

At today's wiring the parser-boot call runs BEFORE `witness_r16_vfs`. The VFS is therefore not yet up, `vfs_open("/system/shell/commands.toml", 0)` returns 0, and `_cmd_registry_load_boot` returns `CRP_ERR_NO_FILE` without any row-pool mutation. This is the expected behavior at UMB-W4; a later landing moves the call behind `witness_r16_vfs` (or re-invokes it there) to actually read the file.

The fingerprint `CMDREG TOML LOADED rows=<n> errno=<e>` emits regardless (`klog_s1_x2`, SUBSYS_CAP_, LEVEL_INFO). The witness coverage tool keys on the `CMDREG TOML LOADED` tag prefix.

## 8. Error-recovery policy

* `CRP_ERR_NO_FILE`: boot continues with an empty registry. An operator sees the `rows=0 errno=0x0C04` fingerprint and can diagnose.
* `CRP_ERR_READ`: boot continues with an empty registry. A chaos-restart flow may re-invoke the loader after the FS stabilises.
* `CRP_ERR_BAD_SYNTAX`: boot continues; the rows already added before the offending byte stay LIVE. Partial-load is intentional -- a typo in the Nth command block does not deny the (N-1) earlier commands.
* `CRP_ERR_TOO_MANY_ROWS`: boot continues; rows up to `CM_MODULE_MAX`=8 stay LIVE. Later entries are dropped.

No path at this landing panics the kernel; the registry is advisory at R123.M2 (the shell dispatch cascade falls through to a NOT_FOUND handler if a command name misses the row pool).

## 9. Observability

`_crp_stats[]` is an 8-u64 counter array indexed by:

```
0  CRP_ST_PARSE_OK      successful parse calls
1  CRP_ST_LOAD_OK       successful boot-load calls
2  CRP_ST_NO_FILE       boot-loads that hit CRP_ERR_NO_FILE
3  CRP_ST_READ_ERR      boot-loads that hit CRP_ERR_READ
4  CRP_ST_SYNTAX        parse calls that returned BAD_SYNTAX
5  CRP_ST_FULL          parse calls that returned TOO_MANY_ROWS
6  CRP_ST_ROWS_ADDED    cumulative rows added across all loads
7  reserved
```

A later landing adds a `cmd_registry_parser_stats()` call for a semantic terminal query site.

## 10. Encoder-pitfall discipline

Every constant 0x0C01..0x0C04 fits imm32 (bit 31 clear). The pool ceiling 8 and name ceiling 64 fit imm32. Byte loads use `mov_b rN, [rbx + rcx*1]` with a pre-zero of rN (encoder does not zero-extend on its own; see pipe_backend.pdx §57). Zero checks use `cmp rN, 0`, never `test rN, rN`. Masked compares stage through r10/r11 reg-reg, never `and r11, imm64`. All `pub let` string declarations are single-line. Module basename `CmdRegistryParser` matches the file basename `cmd_registry_parser.pdx`. Every label prefixed `crp_` (reserved-word discipline).

## 11. Seed file

A canonical two-command seed (ls + cat) will be dropped into the ramdisk staging dir at `src/user/system/shell/commands.toml` once the ramdisk staging path for `/system/shell/` is defined. At today's landing the ramdisk staging dir for the `/system/` subtree is not yet in place; the seed drop is deferred to a follow-up and does NOT block R123.M2. Boot continues to drain to `CRP_ERR_NO_FILE` without the seed.

## 12. Forward-compatibility

The grammar deliberately omits features that could be added without breakage:

* Case-sensitive keys (currently `functor` is spelled `functor`, not `Functor`).
* Multi-line array values (`capability = ["fs.read", "fs.write"]`).
* Boolean / integer values (currently every value is a quoted string).
* Nested dotted keys (`version.major = "1"`).

Any additions ride the grammar as a strict superset: files that parse today keep parsing. Behavior changes are reserved for a MAJOR schema bump, carried in a top-of-file comment that the parser must inspect.

## 13. Hot-reload

**Issue:** paideia-os#2590 (UMB-W8 R123.M6)
**Code:** `src/kernel/core/shell/cmd_registry_parser.pdx` §12 — `_cmd_registry_reload`.
**Dispatch:** `src/kernel/core/cap/kind_cmd_module.pdx` — `CM_OP_RELOAD = 6`, gated by `R_CM_WRITE` (`0x004`).

### 13.1 Purpose

The shell can rebuild its command table at runtime after an operator (or a configuration tool) edits `/system/shell/commands.toml`, without a reboot. The capability is driven synchronously by any holder of a `KIND_CMD_MODULE` capability that carries `R_CM_WRITE`; a future landing adds an FS-watch (`KIND_FS_WATCH`) daemon that invokes it automatically after a file-change event.

### 13.2 Phases

```
_cmd_registry_reload() -> errno
    (1) atomic_xchg_u64(&_crp_reload_in_flight, 1)   -- acquire guard
            previous == 1 -> return CRP_ERR_RELOAD_BUSY (0x0C05)
    (2) pre_rows = _crp_stats[CRP_ST_ROWS_ADDED]     -- snapshot
    (3) kcm_table_reset()                            -- flush KCM pool
            zeros _kcm_table (48 u64), _kcm_stats (8 u64),
            _kcm_names (64 u64 = 512 B), _kcm_name_lens (8 u64).
    (4) errno = _cmd_registry_load_boot()            -- re-parse
            opens /system/shell/commands.toml, reads up to CRP_BUF_CAP
            bytes, iterates `[command.NAME]` sections through
            cmd_module_open. Emits its own CMDREG TOML LOADED
            fingerprint as a side-effect.
    (5) delta = _crp_stats[CRP_ST_ROWS_ADDED] - pre_rows
        klog_s1_x2(INFO, SUBSYS_CAP_, "CMDREG RELOADED",
                   rows=delta, errno=errno)          -- fingerprint
    (6) atomic_store_u64(&_crp_reload_in_flight, 0)  -- release guard
    return errno
```

### 13.3 Idempotency guard

`_crp_reload_in_flight` is a static `u64` in the `CmdRegistryParser` module. Entry is a single-instruction test-and-set:

```
atomic_xchg_u64(&_crp_reload_in_flight, 1) -> previous
```

`xchg` on a memory operand is implicitly `LOCK`-prefixed per Intel SDM Vol 2A §XCHG; the bus lock excludes a racing CPU between read and write. A naive `cmp [mem], 0 / mov [mem], 1` pair is NOT equivalent — two CPUs could both pass the compare and both store 1, each believing it holds the guard. The reload primitive therefore MUST route through `atomic_xchg_u64` (never a plain `mov`).

The guard is released with `atomic_store_u64(&_crp_reload_in_flight, 0)`. On x86 TSO a plain `mov [mem], 0` would deliver release-ordered visibility, but routing through the helper keeps the module's atomic discipline uniform.

A concurrent re-entry (two CPUs land `cap_invoke(CM_OP_RELOAD)` in overlap, or a nested call on the same CPU re-enters through an interrupt-wake path) sees `previous == 1` and returns `CRP_ERR_RELOAD_BUSY` immediately — WITHOUT touching the KCM pool, WITHOUT emitting the fingerprint. The holder completes its reload uninterrupted; the loser's errno is a signal to retry later.

### 13.4 Fingerprint

Wire shape (`klog_s1_x2`, `SUBSYS_CAP_`, `LEVEL_INFO`):

```
CMDREG RELOADED rows=<hex> errno=<hex>
```

Fields:

* `rows` — delta of `_crp_stats[CRP_ST_ROWS_ADDED]` across the inner `_cmd_registry_load_boot` call. On a clean reload with N commands in the file: `rows=0x<N>` (hex). On a missing or malformed file: `rows=0` plus a nonzero `errno`.
* `errno` — the inner `_cmd_registry_load_boot` return value. See §5 for codes.

The inner call also emits its own `CMDREG TOML LOADED rows=<n> errno=<e>` fingerprint; the two lines come out in order (TOML LOADED first, RELOADED second).

### 13.5 Right gate

`CM_OP_RELOAD` gates `R_CM_WRITE` (`0x004`), a bit distinct from the per-row `R_CM_INVOKE` that gates `CM_OP_CLOSE`. The distinction reflects the scope: a holder with `R_CM_INVOKE` can close its own handle; a holder with `R_CM_WRITE` can flush and rebuild the entire table. At today's landing no non-supervisor process holds `R_CM_WRITE`; a shell admin shim mints it from the capability substrate root.

### 13.6 Concurrency caveat (DEFERRED to R123.M6-followup)

The guard excludes concurrent **RELOADs**, not concurrent **LOOKUPs**. Between phases (3) `kcm_table_reset` and (4) `_cmd_registry_load_boot` returning, a racing `cap_invoke(KIND_CMD_MODULE, CM_OP_LOOKUP)` will miss (the pool is empty). A follow-up adds a shadow-table + seqlock swap so lookups continue to resolve against the old table until the new one is fully populated, then switch atomically. Today's reload is a stop-the-world update suitable for the single-shell early-boot phase.

The FS-watch integration (`KIND_FS_WATCH`) is similarly deferred: today's reload is driven by an explicit shell `rebuild` command (or a `cap_invoke` from an admin tool), not by a file-change event.

## 14. Lifecycle

The parser substrate goes through three phases in a kernel's lifetime:

### 14.1 Boot-load (R123.M2, UMB-W4)

```
kernel_main.pdx
    ...
    call _mb_init;
    call _cmd_registry_load_boot;       <-- initial parse
    call x2apic_probe_bsp;
    ...
    call cmd_module_init;
    call cmd_registry_init;
    call cmd_registry_parser_init;       <-- defensive scrub
    ...
```

At today's wiring the parser-boot call runs BEFORE `witness_r16_vfs`, so `vfs_open` returns 0 and the load drains to `CRP_ERR_NO_FILE`. A later landing moves the call behind the VFS witness.

### 14.2 Discovery (R123.M5, UMB-W5)

`cap_invoke(KIND_CMD_MODULE, CM_OP_LIST_FIRST | CM_OP_LIST_NEXT | CM_OP_READ_NAME)` iterates the live KCM rows (populated by the boot-load phase above) under the `R_CM_READ` gate. The row-id iterator exposes module handles to a holder that wants to enumerate the registered command set without pre-knowing names.

### 14.3 Hot-reload (R123.M6, UMB-W8)

`cap_invoke(KIND_CMD_MODULE, CM_OP_RELOAD)` runs the phases in §13.2 under the `R_CM_WRITE` gate. The on-disk `commands.toml` is the authoritative source; the KCM pool is derived state that the reload path rebuilds from scratch.

A subsequent lookup against the fresh pool sees the current file contents. The `_crp_stats[CRP_ST_ROWS_ADDED]` counter is cumulative across every parse run (boot + reload × N); the hot-reload fingerprint reports the per-call DELTA so an operator reading `CMDREG RELOADED rows=0x3` knows this call added three rows, independent of history.

### 14.4 Boot-reset (chaos restart / witness replay)

`cmd_registry_parser_init` scrubs `_crp_load_buf`, `_crp_stats`, and `_crp_reload_in_flight` to zero. This is defensive (`.bss` already starts zero at real boot) but allows a chaos-restart flow or a witness-replay harness to re-run the full lifecycle from a known state.
