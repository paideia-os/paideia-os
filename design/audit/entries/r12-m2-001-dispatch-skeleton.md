---
audit_id: r12-m2-001-dispatch-skeleton
issue: 406
file: src/kernel/core/cap/invoke.pdx
function: cap_invoke_dispatch
effects: [mem, sysreg]
capabilities: [cap]
reviewed_by:
date: 2026-07-02
---

# AUDIT r12-m2-001 — Dispatch Skeleton: Descriptor Read + Four-Way Handler Branch

## Overview

R12-m2-001 implements cap_invoke_dispatch, the kernel's capability-invoke dispatcher. This audit documents the assembly skeleton that reads a capability descriptor, extracts kind and rights, and branches to one of four per-kind handlers. The implementation combines the slot-arithmetic prologue (identical to R8 MVP) with three descriptor-field reads and a four-way conditional-branch switch on kind (A1 direct branch from r12-m1-002 architectural audit).

Key changes from R8 MVP:
1. **Effects signature upgrade** from `!{mem}` to `!{mem, sysreg}` to propagate handler side effects.
2. **Three descriptor fields** now read (kind, rights, target_ptr) instead of just target_ptr.
3. **Handler-ABI setup** with register hazard crossing (first hazard-crossing move: `mov r11, rsi`).
4. **Four-way kind dispatch** via conditional branches (cmp/je).
5. **Fallthrough behavior** preserves R8 MVP: returns target_ptr for unrecognized kinds (ensures KIND_PROCESS=1 cap_smoke stays green).

---

## Section 1 — Assembly Sequence (28 instructions)

The complete cap_invoke_dispatch body, from slot-arithmetic prologue through handler dispatch:

```
mov rax, cap_table;
mov r8, rdi;
shl r8, 3;
mov r9, rdi;
shl r9, 4;
add r8, r9;
add rax, r8;
mov rcx, [rax + 0];
mov rdx, [rax + 8];
mov r10, [rax + 16];
mov r11, rsi;
mov rdi, rdx;
mov rsi, r10;
mov rdx, r11;
cmp rcx, 4;
je call_kind_page;
cmp rcx, 5;
je call_kind_ipc;
cmp rcx, 7;
je call_kind_sched;
cmp rcx, 10;
je call_kind_dev;
mov rax, rsi;
ret;
call_kind_page:
  call cap_handler_page;
  ret;
call_kind_ipc:
  call cap_handler_ipc;
  ret;
call_kind_sched:
  call cap_handler_sched;
  ret;
call_kind_dev:
  call cap_handler_dev;
  ret
```

### Line-by-line breakdown

| Lines | Instruction | Purpose | Input | Output |
|---|---|---|---|---|
| 1–7 | Slot-arithmetic prologue | Compute descriptor address | rdi=slot | rax=&descriptor |
| 8–10 | Descriptor field reads | Load kind, rights, target_ptr | rax=&descriptor | rcx=kind, rdx=rights, r10=target_ptr |
| 11 | Hazard-crossing move | Save op_arg from rsi to r11 | rsi=op_arg | r11=op_arg |
| 12–14 | Handler-ABI setup | Prepare arguments for handler call | rdx=rights, r10=target_ptr, r11=op_arg | rdi=rights, rsi=target_ptr, rdx=op_arg |
| 15–22 | Four-way kind switch | Branch on kind (cmp/je × 4) | rcx=kind | PC branch to handler or fallthrough |
| 23–24 | Fallthrough (R8 MVP) | Return target_ptr for unrecognized kind | rsi=target_ptr | rax=target_ptr, PC return |
| 25–32 | Handler labels | Four entry points for per-kind handlers | — | PC at handler entry |

---

## Section 2 — Register-Hazard Analysis

### Hazard groups (slot-arithmetic prologue, no hazards)

The slot-arithmetic prologue is identical to R8 MVP B5-004 and contains no hazard-crossing moves:

- Lines 1–2: `mov rax, cap_table; mov r8, rdi` — load table base and slot (independent operations).
- Lines 3–7: Shift and arithmetic (`shl r8, 3; mov r9, rdi; shl r9, 4; add r8, r9; add rax, r8`) — all depend only on rax (table base) and rdi (slot), both live at entry.

### Descriptor field reads (three loads, no hazards)

Lines 8–10 read three u64 fields from the descriptor:

```
mov rcx, [rax + 0];    // rcx = descriptor.kind
mov rdx, [rax + 8];    // rdx = descriptor.rights
mov r10, [rax + 16];   // r10 = descriptor.target_ptr
```

All three depend only on rax (already computed in prologue). No hazard-crossing moves yet.

### Handler-ABI setup (FIRST HAZARD-CROSSING SEQUENCE)

Line 11 is the **FIRST HAZARD-CROSSING MOVE**:

```
mov r11, rsi                 // <-- FIRST HAZARD-CROSSING MOVE
                             //     r11 = op_arg (saved from rsi)
mov rdi, rdx                 // rdi = rights (handler arg 1)
mov rsi, r10                 // rsi = target_ptr (handler arg 2) — rsi now clobbered
mov rdx, r11                 // rdx = op_arg (handler arg 3)
```

**Why line 11 is a hazard:**

At function entry (per System V AMD64 ABI), `rsi` holds `op_arg` (caller's 2nd argument). The descriptor-read sequence (lines 8–10) does not touch `rsi`, so `op_arg` remains live in `rsi` through those lines. Line 14 (`mov rsi, r10`) overwrites `rsi` with `target_ptr`. If `op_arg` had not been saved to `r11` first, it would be lost.

**Hazard resolution:**

Line 11 `mov r11, rsi` copies `op_arg` out of `rsi` into `r11` (caller-saved scratch). After this move, `rsi` is free to be repurposed (line 14). This is the boundary between "phase where rsi holds op_arg" and "phase where rsi holds target_ptr"; every instruction after line 11 is free to clobber rsi.

**Register-class justification:**

Per System V AMD64 ABI, `r11` is caller-saved (scratch): no caller value is guaranteed to survive a call in `r11`. Using `r11` as temporary here introduces no obligation. Contrast with `r12` (callee-saved) — using `r12` without `push/pop` would corrupt the caller's frame. This sequence uses only caller-saved scratch (r8, r9, r10, r11).

### Kind-switch comparisons (no hazards)

Lines 15–22 perform four sequential comparisons and conditional branches:

```
cmp rcx, 4;  je call_kind_page          // Kind=4 → page
cmp rcx, 5;  je call_kind_ipc           // Kind=5 → IPC
cmp rcx, 7;  je call_kind_sched         // Kind=7 → scheduler
cmp rcx, 10; je call_kind_dev           // Kind=10 → device
```

All comparisons operate on `rcx` (kind, read at line 8) and do not depend on `rsi`/`r11` or the handler-ABI arguments (rdi, rdx). They are independent of the hazard-crossing sequence.

---

## Section 3 — Handler ABI Pin

All four per-kind handlers (cap_handler_page, cap_handler_ipc, cap_handler_sched, cap_handler_dev) receive arguments via a standardized ABI:

```
RDI = rights           (descriptor.rights from [rax + 8])
RSI = target_ptr       (descriptor.target_ptr from [rax + 16])
RDX = op_arg           (caller's op_arg, preserved in r11 then moved to rdx)
→ RAX = result         (handler return value)
```

This ABI is stable across all four handlers and enables per-kind polymorphism. Each handler decodes op_arg independently and decides what operation to perform and what rights to check.

---

## Section 4 — Return-Code Convention Constants

R12-m2-001 introduces two new sentinel constants (joining R8's INVOKE_RESULT_INVALID_HANDLE):

| Constant | Hex value | Meaning | Introduced |
|---|---|---|---|
| INVOKE_RESULT_INVALID_HANDLE | 0xFFFFFFFFFFFFFFFE | Invalid cap slot | R8 MVP |
| INVOKE_DENIED | 0xFFFFFFFFFFFFFFFD | Rights check failed | R12-m1-002 |
| INVOKE_UNSUPPORTED | 0xFFFFFFFFFFFFFFFC | Operation not implemented for kind | R12-m1-002 |

These are defined in invoke.pdx at module scope.

---

## Section 5 — Regression Preservation: KIND_PROCESS=1 Fallthrough

R8 MVP cap_smoke tests KIND_PROCESS (kind=1), which is not one of the four dispatched kinds (4, 5, 7, 10). The dispatcher's fallthrough behavior must preserve this regression:

```
cmp rcx, 10;
je call_kind_dev;
;; fallthrough: unrecognized kind
mov rax, rsi             // rax = target_ptr (same as R8 MVP)
ret
```

If kind ∉ {4, 5, 7, 10}, the dispatcher returns target_ptr (rsi) in rax without branching to a handler. This preserves R8 MVP's contract and ensures cap_smoke's boot_r8_only and boot_r10 modes continue to pass byte-identically.

---

## Section 6 — Byte-Verification Instructions

After build, verify the dispatcher assembly:

```bash
cd /home/snunez/Development/PaideiaOS
objdump -d build/kernel.elf | grep -A 35 "cap_invoke_dispatch>:"
```

Expected sequence (approximately 28 instructions from dispatch entry to final ret):
1. mov rax, cap_table
2–7. Slot arithmetic (shifts and adds)
8–10. Descriptor field reads
11. mov r11, rsi (hazard crossing)
12–14. Handler-ABI argument setup
15–22. Four cmp/je pairs (kind switch)
23–24. Fallthrough (mov rax, rsi; ret) if not branched
25–32. Four handler call labels with ret

All instructions should be encoded in native x86-64 bytes. `call` instructions should reference cap_handler_page, cap_handler_ipc, cap_handler_sched, cap_handler_dev (resolved by linker).

---

## Section 7 — Traceability

### Issue #406 (r12-m2-001)

GitHub issue: https://github.com/paideia-os/paideia-os/issues/406

Plan reference: `.plans/r12-round-osarch-plan.md` §5 m2-001 (dispatch skeleton).

### Related issues

- #405 (r12-m1-002): Dispatch architectural audit (decisions A1, B1, O).
- #407 (r12-m2-002): Four handler stubs.
- #408–#411 (r12-m3/m4): Real per-kind handler bodies.
- #412 (r12-m5): Regression matrix and cap_dispatch_smoke.

### Cross-references

- **design/milestones/r12-preflight.md**: Architectural decisions (copy of r12-m1-002).
- **src/kernel/core/cap/tags.pdx** (m1-002): Tag-string constants.
- **src/kernel/core/cap/kind_page.pdx, kind_ipc.pdx, kind_sched.pdx, kind_dev.pdx** (m2-002): Handler stubs that receive dispatch.

---

## Section 8 — Validation Checklist

R12-m2-001 is complete when:

- [ ] invoke.pdx cap_invoke_dispatch body matches the 28-instruction assembly (slot prologue + reads + hazard crossing + kind switch).
- [ ] Effects signature is `!{mem, sysreg}` (upgraded from R8's `!{mem}`).
- [ ] First hazard-crossing move (`mov r11, rsi`) occurs immediately after descriptor reads, before rsi is overwritten.
- [ ] All four cmp/je instructions reference correct kind values (4, 5, 7, 10).
- [ ] Handler-ABI arguments are set up correctly (rdi=rights, rsi=target_ptr, rdx=op_arg).
- [ ] Fallthrough returns target_ptr (rsi) in rax (R8 MVP behavior preserved).
- [ ] build/kernel.elf links successfully with four cap_handler_* symbols resolved.
- [ ] Smoke tests boot_r8_only, boot_r10, boot_r11 pass byte-identically (no regression).
- [ ] objdump disassembly shows ~28 instructions from dispatch entry to final ret (before handler labels).

---

## Trailer

**Audit date**: 2026-07-02  
**Issue**: #406  
**Status**: Ready for implementation and verification.
