# Functor instantiation at REPL prompt — R222.M3

Parent: paideia-os#2486. Milestone: paideia-os#2660.

## Scope

When the user types `find .` at the REPL, resolve `find` to its functor,
instantiate against the session's schemas, elaborate the arguments,
and produce a materialization record ready for the kernel `execute`
syscall.

## Materialization record

```
offset  size  field
0x00    4     magic              = 'FINS' (0x534E4946 LE)
0x04    4     reserved
0x08    8     functor_name_hash  (FNV-1a 64 of the functor name)
0x10    2     arg_count          (<= FI_MAX_ARGS = 16)
0x12    2     flags
0x14    12    reserved
0x20    32*N  arg_descriptors[N] (type_code + inline value or ref + length)
```

Total length: `64 + 32 * arg_count` bytes.

## Pipeline

- `_fi_instantiate(inv, inv_len, cs, cs_len, out, out_cap)` parses `<name> <arg>*`
  into a materialization record skeleton: writes magic, name hash,
  arg_count, and per-arg (type_code=0, raw_offset, raw_len) stubs.
- `_fi_elaborate_args(mat, mat_len, cs_body, cs_len)` resolves the
  functor against a CommandSig body (R222.M2), looks up the typed
  signature, and elaborates each per-arg stub against its expected
  type_code. On name mismatch: `FI_ERR_NAME_MISMATCH`. On expected
  type_code mismatch: `FI_ERR_UNKNOWN_TYPE`. On parse failure:
  `FI_ERR_ELABORATION`. On success: packs the input mat_len back
  into the status word.

## Status band

See `tools/user/libpdx-pds-parser/src/functor_instance.pdx` for the
0x3900..0x3906 error reservation (and `caps.decl`).

## Interactions

- R222.M1 (SchemasSig) provides the per-schema type arrays referenced
  via `type_code`.
- R222.M2 (CommandSig) provides the catalogued functor bodies.
- R229.M1/M2 (REPL + SessionEnv) consume the materialization record
  and dispatch to the kernel `execute` syscall.
- Downstream: R222.M4 ArgSpec and R222.M5 registry client refine the
  per-arg elaboration path.

## References

- `design/terminal/semantic-shell-language-plan.md` §4 R222 row M3
- `tools/user/libpdx-pds-parser/src/schemas_sig.pdx` (R222.M1)
- `tools/user/libpdx-pds-parser/src/command_sig.pdx` (R222.M2)
