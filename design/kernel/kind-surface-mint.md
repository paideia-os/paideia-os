# COMP-IMPL-02: KIND_SURFACE mint operation

Wave: compositor-impl-backtrack (TTT).

## Finding: the substrate mint body was already real, not a WEAK stub

`src/kernel/core/cap/kind_surface.pdx` `surface_mint(owner_task, w, h,
format) -> row_id | error` (landed R113.M1-001, #2381) already:

- validates owner/w/h/format,
- low-first-scans a real 16-row static pool (`_surface_table`,
  128 u64 words, `SURFACE_ROW_MAX = 16`),
- bumps the LAM generation + in-use marker,
- stamps `surface_id / owner / wh_packed / format / state+serial /
  damage / buffers` per the row layout frozen in
  `design/graphics/r113-m1-substrate.md`,
- bumps `_surface_stats.mints`, and
- emits the `SURFACE MINT OK` fingerprint.

This wave's brief described a 256-slot pool; the frozen design (§2 of
the substrate doc) specifies 16 rows, chosen to match T14 G4's expected
concurrent-surface count. Widening the pool would mean re-opening a
FROZEN design doc and re-deriving `SURFACE_ROW_MAX`-dependent byte
math across every accessor in the file for no compositor-test-visible
benefit, so this landing does not touch the pool size.

`src/kernel/core/cap/handlers/cap_handler_surface.pdx` (#2424) also
already existed, fully implemented, unpacking `OP_SURFACE_MINT`'s
`arg2 = w`, `arg3 = h | (format << 32)` into `surface_mint`'s SysV
signature.

## The real gap: the generic cap_invoke path always refused MINT

`cap_handler_surface` was reachable from two paths:

1. A direct 5-argument call (a boot witness, or a future kernel-side
   bridge) -- fully functional.
2. The generic 2-argument syscall ABI, `sys_cap_invoke(slot, op_arg)`,
   routed through `cap_invoke_dispatch`'s `call_kind_surface` shim in
   `src/kernel/core/cap/invoke.pdx`.

Path 2 is the ONLY way userspace can reach `cap_handler_surface` at
all (there is no other syscall or IPC route to it). Before this
landing, `call_kind_surface` treated `op_arg` as a bare op ordinal and
hardcoded `arg2 = arg3 = 0` for every op -- so a `MINT` invocation
through the real, only-available userspace path always saw
`w = h = format = 0` and correctly refused with
`SURFACE_MINT_BAD_DIMS` / `_FORMAT`. `cap_handler_surface`'s own file
header already named this exactly: "a follow-on landing (R113.M1-002)
refines op_arg into a packed encoding." That landing had not happened;
MINT was unreachable from userspace by construction. This is the WEAK
spot this wave item closes.

## Fix

`src/kernel/core/cap/invoke.pdx` `call_kind_surface` now decodes a
packed `op_arg` for the MINT ordinal only (ordinals 0..4 -- QUERY /
COMMIT / DAMAGE / ATTACH / DESTROY -- are byte-for-byte unchanged,
since a caller already passing a bare small-int ordinal has an
implicit zero payload today):

| bits | field |
|---|---|
| `[7:0]` | op ordinal (5 selects the new decode path) |
| `[31:8]` | `w` (24 bits) |
| `[55:32]` | `h` (24 bits) |
| `[63:56]` | `format` (8 bits) |

No existing caller invokes `OP_SURFACE_MINT` through `sys_cap_invoke`
today (verified: `OP_SURFACE_MINT` / `SURFACE_OP_MINT` appear only in
`invoke.pdx`, `cap_handler_surface.pdx`, and the user-side vocabulary
file `surface_kind.pdx` -- no call site), so this is purely additive
and changes no existing behaviour.

## Files touched

- `src/kernel/core/cap/invoke.pdx` -- `call_kind_surface` packed op_arg
  decode for MINT.
