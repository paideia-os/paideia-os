# Splitting kernel_main.pdx into boot witness modules

Status: landed (2026-08-16, commits `0da0472`, `de48b8e`, `035ebb6`, `bbb9b69`)

## The file

`src/kernel/boot/kernel_main.pdx` had reached **24,330 lines** — 14% of a
175k-line tree and 6.3x the next largest file — in **two functions**:

| function | lines | shape |
|---|---:|---|
| `kernel_main_64` | 2,050 | bring-up calls interleaved with 24 witness blocks |
| `boot_continue_after_ring3` | 21,350 | one `unsafe` block, 116 witness blocks |
| data trailer | 1,036 | 149 `pub let` storage declarations |

143 banner-delimited sections, one per round or issue, accumulated over
roughly fifty milestones. Every one of them ran unconditionally on every
boot, in every mode.

After the split:

| file | lines |
|---|---:|
| `src/kernel/boot/kernel_main.pdx` | 1,454 |
| `src/kernel/boot/witness/*.pdx` (24 modules) | 26,059 |

`boot_continue_after_ring3` is now the boot spine — per-CPU init, the UART
RX poll, `lapic_timer_init`, SMP bring-up, init's task/entry/rsp handoff,
the ring-3 transfer and its fail/hang handlers — with twenty-two `call`s
naming what runs between them and where it lives.

## What the transformation is

Each group is lifted **verbatim**. The body of every new function is
byte-identical to the lines it replaced; the only bytes added are:

```
    block: {
      push rbp;

      <original lines, unchanged>

      pop rbp;
      ret
    }
```

and, at the original site, a single `call witness_<name>;`.

### Why the push is not decoration

paideia-as emits **no frame prologue for an `unsafe`-bodied lambda**.
`emit_visit_lambda.rs` short-circuits on `body_is_unsafe` before it ever
consults `@no_frame`, so every hand-written assembly function in this
kernel is emitted exactly as written, with no `push rbp; mov rbp, rsp` and
no matching epilogue. (`@no_frame` is therefore a no-op on all 513 of its
uses in this tree — filed as #1606.)

The consequence is that an `unsafe` function's body runs at whatever
`rsp % 16` its caller's `call` produced. `boot_continue_after_ring3`'s is
**8**, and the witnesses inside it compute their own nested-call alignment
from that number in their own comments:

> "3 pushes from %16==8 yields (8+3*8)%16 = 32%16 = 0"

A bare `call` into a bare body would present `%16 == 0` instead, silently
inverting every such argument — the failure shape of #1192, #1195 and
#1584. One 8-byte push at entry restores the inline parity exactly, at
every nesting depth, and the matching pop keeps rbp's SysV guarantee.

## Where the group boundaries came from

Boundaries were not chosen by size. Three properties were computed over the
whole function first, and the groups are what those properties allow.

**1. Jump closure.** Every `jmp`/`jcc` target in a candidate group must be
defined inside it. Two places fail this:

- The init-boot wire-up jumps to `init_boot_fail`, defined at the very end
  of the function. Both stay inline; they are the spine, not a witness.
- `pf_handle_cow` (#661) has nine `je kpti_fail` edges into the ring-3
  witness that follows it, so those two are one unit — and that unit cannot
  leave, because the ring-3 witness's `iretq` is the reason
  `boot_continue_after_ring3` exists as a callable symbol at all.

**2. Push/pop closure.** A group's stack nesting must close within it.
Exactly one region fails: `ipc_bounce_witness` pushes r12/r13/r14 and the
matching pops are **1,545 lines later**, with four sections jumping into
each other's fail/done labels in between. That whole region is
`witness/r20b_ipc.pdx`, one function of 1,644 lines, and its header says
why it cannot be subdivided.

**3. Inbound register dependencies.** A read-before-write of a callee-saved
register at a group's entry is an implicit inbound argument. One survives
the analysis and it is the important one — see below.

## The dependency this exposed

`r12`/`r13`/`r14` carry init's `task_slab`, `e_entry` and `user_rsp` from
the init-boot wire-up to `enter_userland_initial`. Inline, that was ~5,900
lines of straight-line code. It is now ~500 lines, but the values cross
**twenty `call` boundaries** into witness modules.

It survives because each extracted body preserves callee-saved registers
exactly as it did inline. Nothing in the type system, the effect rows, or
any gate says it must. This is filed as **#1604**, not fixed here: a
refactor that also changes behaviour cannot be checked against "the log is
identical".

## Storage ownership

120 of the 149 declarations moved to the module that reads them. The rule:
a block moves only when every symbol it declares is referenced, in code
with comments stripped, by exactly one file, and that file is a witness
module.

29 stayed, and the reasons are the interesting output:

- `_ring3_witness_active`, `_kernel_resume_rsp`, `_ud_witness_active`,
  `_cow_witness_active` (read by `core/int/exceptions.pdx`) and
  `_cow_witness_verbose` (by `core/mm/pf_handler.pdx`) are the
  kernel_main/handler rendezvous. They belong to neither side alone.
- `smp_bringup_*_msg` are read by `tests/kernel/mm/tlb_shootdown_race.pdx`;
  `_loader_seed_witness_sidecar` by `tools/boot_stub.S`.
- `_registry_v2_witness_name0` and `_blob_witness_blob` each have two
  witness-module readers.
- The R29 restart-witness and audit-witness storage is textually
  *interleaved* in a single block, so it has two owners as written.
- Three have no reader anywhere in the tree (#1607).

**Declaration order is preserved inside each destination.** Several
witnesses deliberately write past one buffer into the next — the
511-u64 payload patterns sitting in front of 512-u64 scratch — so relative
placement within an object is load-bearing, not formatting.

## How it was verified

The goldens assert an **ordered subsequence** of 190 fingerprints across 14
boot modes. That check cannot see a witness that silently stops running:
most of the subsequence survives. So the criterion used here is stronger.

Full serial logs were captured for all 16 modes (the 14-mode matrix plus
`boot_r31_spawn_pair` and `boot_r17_init`) before and after, and compared
byte-for-byte with two things masked:

- the 16-hex TSC column, which also appears mid-line where a raw
  `uart_puts` left no trailing newline, and
- `TSC CALIBRATED hz=0x…`, a host-clock measurement.

**Two runs of the same kernel are byte-identical under that
normalisation**, in all 16 modes — so the comparison has no noise floor to
hide a regression in.

Because `tools/run-smoke.sh` rebuilds on every invocation (~1m38 each),
before/after capture of 16 modes twice would cost three hours. The capture
harness used a copy of `run-smoke.sh` with only its three build invocations
neutered, against a pre-built `build/kernel.elf` — 2m30 for the full matrix
instead of 26 minutes. The real runner was used for the final spot check.

### The one delta, and why it is not a behaviour change

Every batch produces exactly **three differing lines per mode**:

```
- FRAME rip=0x000000000000cccc rbp=0xffff800000172c20
+ FRAME rip=0x000000000000cccc rbp=0xffff800000174500
```

The `klog_walk_rbp` witness (M5-001, #695) prints the **linked address** of
`_stack_walk_buf`, which necessarily moves when object sizes change and
`.bss` is relaid out. Frame count, chain shape and the rip canaries
(`0xaaaa`/`0xbbbb`/`0xcccc`) are unchanged, and no golden in the tree
asserts an address — `grep -rl '0xffff8' tests/` is empty.

Zero golden changes: `git diff --stat HEAD~4 -- tests/` is empty.

### Pre-extraction proofs

Run before each batch's first build, so a mistake was caught at the text
level rather than as a link error or, worse, a silent retarget:

- every extracted body reconstructed byte-identically from the source it
  replaced (149/149 for the storage move);
- every jump target in every new file defined in that file;
- push/pop nesting closed per group.

### Gates

`no-aml-lint`, `opcode-canary`, `elaborator-negatives`, `aml-parser`,
`verify-aml-fuzz`, `verify-atomics` (6/6), `verify-fingerprint-coverage`
(**190/168/22, unchanged**), `verify-cap-stride` (**142 sites, unchanged**),
`verify-task-pool-bounds` (18 slabs pinned), `verify-user-image-extent`,
`verify-user-cap-sidecars`. All green at each batch.

`tools/verify-task-pool-bounds.sh` names eight witness slabs by
`(file, symbol)` to pin their width at `TASK_STRUCT_QWORDS`; the paths
follow the symbols to their new modules. The pin itself is unchanged.

## What was deliberately not done

- **`file_ids.pdx` was not regenerated.** It is stale (205 entries for 413
  files) and five sites hardcode its ordinals — a pre-existing defect
  regenerating it would trip. Filed as #1605. The new witness modules
  reference no `FILE_ID_*`, so nothing new depends on it.
- **No effect or capability row was widened.** Each extracted function
  declares exactly what `boot_continue_after_ring3` / `kernel_main_64`
  declared: `!{sysreg}` with `effects: { sysreg }, capabilities: { boot }`.
  Same instruction stream, same authority.
- **No bug found during the move was fixed in the same commit.** Four are
  filed: #1604, #1605, #1606, #1607.

## Where this could go next

The per-section analysis is finer-grained than the groups that landed. Of
116 sections inside `boot_continue_after_ring3`, only the `r20b_ipc` region
has cross-section jumps or split push/pop scopes; the rest are individually
closed and could each become their own named function inside its module.
That is a strictly smaller change than this one and now has a
proven-byte-identical harness to check it against.
