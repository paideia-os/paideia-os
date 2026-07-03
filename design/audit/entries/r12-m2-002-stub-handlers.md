---
audit_id: r12-m2-002-stub-handlers
issue: 407
file: src/kernel/core/cap/kind_page.pdx, src/kernel/core/cap/kind_ipc.pdx, src/kernel/core/cap/kind_sched.pdx, src/kernel/core/cap/kind_dev.pdx
function: cap_handler_page, cap_handler_ipc, cap_handler_sched, cap_handler_dev
effects: [mem, sysreg]
capabilities: [cap]
reviewed_by:
date: 2026-07-02
---

# AUDIT r12-m2-002 — Stub Handlers: Four Entry Points + Tag Emission

## Overview

R12-m2-002 implements four capability-handler stubs, one for each capability kind dispatched by cap_invoke_dispatch (r12-m2-001):

1. **cap_handler_page** (kind_page.pdx): KIND_PAGE (kind=4) — placeholder for OP_READ/OP_WRITE.
2. **cap_handler_ipc** (kind_ipc.pdx): KIND_IPC_ENDPOINT (kind=5) — placeholder for OP_SEND/OP_RECV.
3. **cap_handler_sched** (kind_sched.pdx): KIND_SCHED_CTX (kind=7) — placeholder for OP_YIELD.
4. **cap_handler_dev** (kind_dev.pdx): KIND_DEVICE (kind=10) — placeholder for OP_MAP_MMIO.

Each stub is a minimal entry point that:
1. Emits a diagnostic tag string on COM1 (via `lea rdi, [rip + tag_symbol]; call uart_puts`).
2. Returns a kind-specific sentinel value (to distinguish handler-reached from dispatcher-fallthrough).

Rationale: The stubs enable the R12 m2 bundle to link successfully (resolving all four cap_handler_* symbols from invoke.pdx), while deferring real operation implementations to m3-001, m4-001, and m4-002. Real bodies will perform rights-checks, decode op_code, and execute memory operations or IPC messages.

---

## Section 1 — Handler ABI Inherited from Dispatcher

All four handlers share the same ABI, established by cap_invoke_dispatch (r12-m2-001, §3):

```
Input arguments (caller-saved registers per System V AMD64):
  RDI = rights           (descriptor.rights from invoke.pdx line 8)
  RSI = target_ptr       (descriptor.target_ptr from invoke.pdx line 10)
  RDX = op_arg           (original caller op_arg, preserved via r11 in invoke.pdx line 11)

Output:
  RAX = result           (kind-specific return value or error sentinel)
  Effects: {mem, sysreg} (may emit tags, read memory, modify sysreg)
```

Handlers receive these arguments in fixed registers and must return a result in rax.

---

## Section 2 — Sentinel Table (Four Values)

Each stub returns a distinct sentinel to allow testing/debugging (distinguishing handler-reached from fallthrough):

| Handler | Kind | Sentinel hex | Sentinel decimal | Purpose |
|---|---|---|---|---|
| cap_handler_page | 4 | 0xDEADBEEF00000004 | 16045690883584004 | Reaches kind_page handler |
| cap_handler_ipc | 5 | 0xDEADBEEF00000005 | 16045690883584005 | Reaches kind_ipc handler |
| cap_handler_sched | 7 | 0xDEADBEEF00000007 | 16045690883584007 | Reaches kind_sched handler |
| cap_handler_dev | 10 | 0xDEADBEEF0000000A | 16045690883584010 | Reaches kind_dev handler |

Pattern: High 32 bits = 0xDEADBEEF (distinctive marker); low 32 bits = kind value (enables handler identification).

---

## Section 3 — Tag-Emission Pattern (3-Instruction Body)

Each stub follows an identical 3-instruction pattern:

```
lea rdi, [rip + <tag_symbol>]    // Load tag string address (RIP-relative)
call uart_puts                    // Emit tag on COM1 (defined in uart.pdx)
mov rax, <sentinel>               // Load sentinel into rax (return value)
ret                               // Return to dispatcher
```

This pattern is repeated four times (once per kind file).

### Tag symbols (from tags.pdx, r12-m1-002)

- **kind_page.pdx**: `lea rdi, [rip + cap_mem_msg]` — "CAP INVOKE MEM\n"
- **kind_ipc.pdx**: `lea rdi, [rip + cap_ipc_msg]` — "CAP INVOKE IPC\n"
- **kind_sched.pdx**: `lea rdi, [rip + cap_sched_msg]` — "CAP INVOKE SCHED\n"
- **kind_dev.pdx**: `lea rdi, [rip + cap_dev_msg]` — "CAP INVOKE DEV\n"

Tag symbols are defined in src/kernel/core/cap/tags.pdx (m1-002, not in scope for m2-002). Stubs reference these via flat symbols (no `Tags::` module qualification); paideia-as resolves them as STB_GLOBAL at link time.

---

## Section 4 — Effect+Capability Annotation

Each stub declares:

```
pub let cap_handler_<x> : (u64, u64, u64) -> u64 !{mem, sysreg} @{cap}
```

Meaning:
- **`!{mem, sysreg}`**: Function may read/write memory and system registers (uart_puts uses both).
- **`@{cap}`**: Function requires CAP capability (inherited from dispatcher).

This annotation enables the paideia-as type system to verify that callers (cap_invoke_dispatch) have declared the same effects.

---

## Section 5 — Link-Resolution Witness

After build, verify all four handlers are linked as global text symbols:

```bash
nm build/kernel.elf | grep cap_handler_
```

Expected output (4 lines, all `T` type):

```
0000000000001234 T cap_handler_page
0000000000001234 T cap_handler_ipc
0000000000001234 T cap_handler_sched
0000000000001234 T cap_handler_dev
```

(Addresses are illustrative; exact values depend on linker layout.) The `T` type indicates global text symbol (executable code). All four must be present for cap_invoke_dispatch to link.

---

## Section 6 — Regression Preservation

R12 m2 does not introduce regression-breaking changes:

1. **boot_r8_only** and **boot_r10** smokes do not reach kinds 4, 5, 7, or 10 (they test kind=1, KIND_PROCESS). Dispatcher fallthrough returns target_ptr (R8 MVP behavior), unchanged.
2. **boot_r11** smoke tests the full boot-up sequence but does not invoke capabilities. Stubs are never called.
3. **Sentinel values** (0xDEADBEEF*) are never returned by R8 MVP code, so existing callers cannot mistake a stub sentinel for a real result.

Rationale: Stubs are placeholders. Real handlers (m3/m4) will replace them with full implementations. Until then, the stubs must not break existing tests.

---

## Section 7 — boot_cap_stub — SKIPPED

Softarch recommends skipping an optional intermediate smoke test (boot_cap_stub) that would verify stub reachability. Rationale:

1. **Link-time verification sufficient**: `nm build/kernel.elf | grep cap_handler_` after build provides complete link witness (all four symbols present or build fails).
2. **Runtime witness deferred**: m5-001's cap_dispatch_smoke provides the meaningful runtime witness (actual invocations of all four kinds).
3. **Cycle efficiency**: Omitting boot_cap_stub saves 1 build+test cycle; regression matrix (boot_r8_only, boot_r10, boot_r11) already covers non-regression.

---

## Section 8 — Traceability

### Issue #407 (r12-m2-002)

GitHub issue: https://github.com/paideia-os/paideia-os/issues/407

Plan reference: `.plans/r12-round-osarch-plan.md` §5 m2-002 (handler stubs).

### Related issues

- #405 (r12-m1-002): Dispatch architectural audit (tag discipline, handler ABI).
- #406 (r12-m2-001): Dispatcher skeleton (calls handlers).
- #408 (r12-m3-001): Real kind_page handler (OP_READ/OP_WRITE).
- #409 (r12-m3-002): Real kind_sched handler (OP_YIELD).
- #410 (r12-m4-001): Real kind_ipc handler (OP_SEND/OP_RECV).
- #411 (r12-m4-002): Real kind_dev handler (OP_MAP_MMIO).
- #412 (r12-m5): Regression matrix and cap_dispatch_smoke.

### Cross-references

- **src/kernel/core/cap/invoke.pdx** (m2-001): Dispatcher (calls cap_handler_*).
- **src/kernel/core/cap/tags.pdx** (m1-002): Tag-string definitions.
- **design/audit/entries/r12-m1-002-dispatch-arch.md**: Architectural decisions (section 4 handler pattern).

---

## Section 9 — Validation Checklist

R12-m2-002 is complete when:

- [ ] Four handler files created: kind_page.pdx, kind_ipc.pdx, kind_sched.pdx, kind_dev.pdx.
- [ ] Each handler has correct module name (KindPage, KindIpc, KindSched, KindDev).
- [ ] Each handler symbol name matches dispatcher's call target (cap_handler_page, cap_handler_ipc, cap_handler_sched, cap_handler_dev).
- [ ] Each handler has effects annotation `!{mem, sysreg}` and capabilities `@{cap}`.
- [ ] Each handler takes three u64 arguments (matching dispatcher's ABI).
- [ ] Each handler emits exactly one tag on COM1 (lea + call uart_puts).
- [ ] Each handler returns distinct sentinel (0xDEADBEEF + kind number).
- [ ] No `Tags::` module qualification in handler files (tags are flat symbols).
- [ ] `build/kernel.elf` links successfully (all four cap_handler_* symbols resolved).
- [ ] `nm build/kernel.elf | grep cap_handler_` returns 4 lines, all type `T`.
- [ ] Smoke tests boot_r8_only, boot_r10, boot_r11 pass byte-identically (no regression).

---

## Section 10 — File Structure

Each handler file follows the template:

1. **File header** (3 lines): PaideiaOS R12-m2-002 comment, real body placeholder, handler ABI.
2. **Module declaration**: `module <KindName> = structure { ... }`.
3. **Sentinel constant**: `let R12_<KIND>_STUB_SENTINEL : u64 = 0xDEADBEEF...`.
4. **Handler function**: `pub let cap_handler_<kind> : (u64, u64, u64) -> u64 !{mem, sysreg} @{cap}`.
5. **Function body**: Unsafe block with effects, capabilities, justification, and 4-instruction assembly (lea + call + mov + ret).

No other declarations or logic.

---

## Trailer

**Audit date**: 2026-07-02  
**Issue**: #407  
**Status**: Ready for implementation and verification.
