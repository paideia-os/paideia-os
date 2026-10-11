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
