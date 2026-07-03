---
audit_id: r12-m1-003-tags-fallback-b
issue: 405
cross_repo: paideia-as#910
status: RESOLVED (2026-07-02)
resolution: paideia-as #910 fix landed at commit 26ba157; tags.pdx reverted to inline PRIMARY form; boot_stub.S trimmed of the 6 R12 tag globals.
file: src/kernel/core/cap/tags.pdx, tools/boot_stub.S
function: cap_mem_msg, cap_ipc_msg, cap_dev_msg, cap_sched_msg, cap_dispatch_ok_msg, cap_denied_msg
effects: []
capabilities: []
reviewed_by:
date: 2026-07-02
---

# AUDIT r12-m1-003 — tags.pdx Fallback B: Strings Sourced from boot_stub.S (RESOLVED)

## Resolution notice

paideia-as issue #910 (PA-R12-001) was fixed at commit 26ba157: cmd_build.rs's
Let-RHS data-table population cascade now includes an `IrKind::StringLiteral`
branch. `pub let X : [u8; N] = "..."` inside a module now emits a `.rodata`
symbol with truncation or zero-padding to the declared N.

paideia-os reverted to the PRIMARY form:
- `src/kernel/core/cap/tags.pdx` now contains inline `pub let cap_X_msg : [u8; N] = "..."` declarations for all 6 strings.
- `tools/boot_stub.S` trimmed of the 6 R12 tag globals (banner_msg, cap_ok_msg, ipc_ok_msg, idt_ok_msg, _tick_msg, _task_a_msg, _task_b_msg remain).
- Handler references (flat `[rip + cap_X_msg]`) unchanged — they now resolve against tags.pdx symbols instead of boot_stub.S symbols. Byte-count semantics preserved: [16, 16, 18, 16, 17, 12].

Verification: `nm build/core/cap/tags.o` shows 6 V symbols (was 0); `nm build/kernel.elf` shows the 6 symbols at 0x103ea0-0x103f00 range; regression matrix green.

Historical record of the fallback preserved below for retrospective reference.

---

# Historical: tags.pdx Fallback B: Strings Sourced from boot_stub.S

## Overview

R12-m1-002 (see `r12-m1-002-dispatch-arch.md`) pinned the "Tag discipline (O)"
decision: six COM1 diagnostic strings, declared in `tags.pdx` as
`pub let X : [u8; N] = "..."` module-scope bindings, referenced by per-kind
handlers via `lea rdi, [rip + cap_X_msg]`.

When the R12-m2 bundle (#406 cap_invoke_dispatch, #407 per-kind handler stubs)
was built against the PRIMARY form of `tags.pdx`, the link step failed with
four undefined references: `cap_mem_msg`, `cap_ipc_msg`, `cap_sched_msg`,
`cap_dev_msg`. This audit documents why the PRIMARY form failed, why the
first fallback (FALLBACK A) was rejected before it was tried, and the
FALLBACK B strings-in-assembly workaround now applied, matching the
precedent already established for `banner_msg` (B3-004) and every
subsequent COM1 tag symbol through R11.

## Why PRIMARY form failed

`tags.pdx` declared:

```
module Tags = structure {
  pub let cap_mem_msg : [u8; 16] = "CAP INVOKE MEM\n\0"
  ...
}
```

Building this module in isolation and inspecting the object file showed no
emitted symbols:

```
nm build/core/cap/tags.o   # (no output — zero symbols)
```

paideia-as v0.11.0+19 parses `pub let X : [u8; N] = "string"` (accepts the
syntax, produces an AST node) but its PA10-002 string-literal-to-data-binding
lowering does not emit a corresponding `.rodata` symbol when the binding sits
inside a `module ... = structure { ... }` scope. The binding is silently
dropped between AST and codegen — no diagnostic, no error, just an absent
symbol. This is filed upstream as paideia-as issue #910 (cross-repo tracker:
paideia-os/paideia-as#910).

## Why FALLBACK A failed

Before reaching for the boot_stub.S workaround, the softarch-recommended
FALLBACK A was attempted: replace the string-literal binding with a raw
pointer/byte-array declaration using `*const u8` (or equivalent) at module
scope, hoping the pointer-typed path through codegen would emit a symbol
even where the string-literal path did not. The paideia-as parser rejects
`*const u8`-typed `let` bindings inside a `module ... = structure { ... }`
block — the type is not recognized as a valid module-scope binding type
in the current grammar. This is a parser-level rejection (not a codegen
gap), so no workaround at the `.pdx` source level was available and
FALLBACK A was abandoned without a build attempt.

## FALLBACK B applied

Matching the proven pattern used for `banner_msg` (B3-004), `cap_ok_msg`
(B5-005), `ipc_ok_msg` (B6-004), `idt_ok_msg` (R9-m1-002), `_tick_msg`
(R9-m4-001), `_task_a_msg`/`_task_b_msg` (R10-m4-002): define the six tag
strings directly in `tools/boot_stub.S` as `.global` symbols in the
`.rodata`-adjacent `.text.boot`/data area of the boot stub, each NUL-terminated
so `uart_puts` (which walks bytes until NUL) stops correctly.

```
.global cap_mem_msg
.align 8
cap_mem_msg:
    .ascii "CAP INVOKE MEM\n\0"
```

(and equivalently for `cap_ipc_msg`, `cap_dev_msg`, `cap_sched_msg`,
`cap_dispatch_ok_msg`, `cap_denied_msg`).

`tags.pdx` is rewritten as a documentation-only stub module, structurally
identical to the existing `banner.pdx` precedent: it declares an empty
`module Tags = structure { }` body and carries a comment block recording
the six symbol names and their NUL-inclusive byte counts, so any code
reading `tags.pdx` still learns the canonical string contents and where
they actually live.

Handlers (`kind_page.pdx`, `kind_ipc.pdx`, `kind_sched.pdx`, `kind_dev.pdx`)
require no changes: they already reference the tags as flat globals via
`[rip + cap_X_msg]`, which resolves identically whether the symbol
originates from a `.pdx` data binding or from hand-written assembly — the
linker sees the same symbol name either way.

`cap_dispatch_ok_msg` and `cap_denied_msg` are added preemptively (not yet
referenced by any handler as of m2) since m3/m4/m5 work is already known to
need them (m5-001 for dispatch-ok, m3/m4 rights-check paths for denied),
saving a repeat of this fallback later.

## Migration path

When paideia-as issue #910 lands (PA10-002 lowering emits symbols for
string-literal bindings inside module scope), the migration is:

1. Revert `tags.pdx` to its PRIMARY form (six `pub let X : [u8; N] = "..."`
   bindings), confirming with `nm` that all six symbols now emit.
2. Delete the six `.global` blocks from `tools/boot_stub.S` (the
   R12-m1-002 block appended after `_task_b_msg`).
3. Rebuild and rerun the R8/R10/R11 regression smokes plus any R12 smokes
   introduced by then, confirming byte-identical serial output.

No handler code changes are required either direction — the ABI is the
symbol name, not its origin module.

## Regression preservation

This change touches only `tags.pdx` (rewritten to a stub) and appends new
symbols to `tools/boot_stub.S` strictly after the existing `_task_b_msg`
block (line 128 in the pre-change file). No existing symbol, byte layout,
or instruction above that line is altered, so R8/R10/R11 fingerprints are
expected to remain byte-identical.

## Traceability

- Architectural decision origin: `design/audit/entries/r12-m1-002-dispatch-arch.md`
- Consumer stubs: `design/audit/entries/r12-m2-002-stub-handlers.md`
- Cross-repo issue: paideia-os/paideia-as#910
- Precedent pattern: `design/audit/entries/banner-r15.md` and B3-004 through
  R10-m4-002 `.global` tag-string additions to `tools/boot_stub.S`
