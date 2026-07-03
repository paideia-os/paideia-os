---
audit_id: r12-m1-002-dispatch-arch
issue: 405
file: src/kernel/core/cap/invoke.pdx, src/kernel/core/cap/tags.pdx, src/kernel/core/cap/kind_page.pdx, src/kernel/core/cap/kind_ipc.pdx, src/kernel/core/cap/kind_sched.pdx, src/kernel/core/cap/kind_dev.pdx
function: cap_invoke_dispatch, per-kind handlers (handler_page, handler_ipc, handler_sched, handler_dev)
effects: [sysreg]
capabilities: [cap_invoke]
reviewed_by:
date: 2026-07-02
---

# AUDIT r12-m1-002 — Dispatch Architecture Pin: Direct-Branch Dispatch + Tag Discipline

## Overview

R12-m1-002 audits the capability-invoke dispatcher (invoke.pdx, m2-001) and pins three architectural decisions:

1. **Dispatch style (A1)**: Four-way conditional jump (cmp/je per kind). Rationale: small N (4 kinds), debuggable, defers jump-table layout to R13+.
2. **Rights-check placement (B1)**: Per-handler, immediately after op-code decode. Rationale: self-contained modules, per-op granularity.
3. **Tag discipline (O)**: Six COM1 diagnostic strings in tags.pdx, emitted before rights-check. Rationale: diagnostic clarity, NUL-termination correctness.

Associated files:
- **invoke.pdx** (m2-001 kernel dispatcher skeleton): not implemented until m2-001 but decisions finalized here.
- **tags.pdx** (new, m1-002): six tag-string constants.
- **Per-kind handlers** (kind_page.pdx, kind_ipc.pdx, kind_sched.pdx, kind_dev.pdx, m3-001 and m4-001): inherit dispatch style and tag discipline from this audit.

---

## Section 1 — Architectural Decisions (A1 + B1 + O)

### A1: Direct-branch dispatch (four cmp/je)

The dispatcher reads kind (descriptor offset 0) and performs four sequential conditional jumps:

```
mov rax, [descriptor_addr]          # Load kind (u64, offset 0)
cmp rax, 4; je call_handler_page    # KIND_PAGE
cmp rax, 5; je call_handler_ipc     # KIND_IPC_ENDPOINT
cmp rax, 7; je call_handler_sched   # KIND_SCHED_CTX
cmp rax, 10; je call_handler_dev    # KIND_DEVICE
# Fallthrough: return INVOKE_UNSUPPORTED (or default to R8 MVP)
```

Latency: 4 comparisons worst-case. Code size: ~28 bytes. Debuggability: high (human-readable in objdump).

Rationale:
1. **Small N** (4 kinds): negligible latency cost.
2. **Objdump-clear**: human-readable dispatch in disassembly.
3. **.bss deferral**: no jump table → defers .bss layout to R13+.

### B1: Per-handler rights-check

Each handler decodes op_code and checks rights before executing:

```
handler_kind_page(descriptor_addr, op_arg):
    op_code = op_arg & 0xFF
    if op_code == 1:  # OP_READ
        rights = [descriptor_addr + 8]
        if (rights & 0x01) != 0x01:  # RIGHT_READ
            emit "CAP DENIED\n"
            return INVOKE_DENIED
        # proceed with read...
```

Rationale:
1. **Self-contained**: handler file owns all logic for that kind.
2. **Per-op granularity**: each (kind, op) pair can have distinct rights.
3. **Bounded duplication**: 3–4 instructions per handler; 4 handlers = ~12 instructions total (acceptable for R12).

### O: Tag discipline (six strings, NUL-inclusive)

Each handler emits a tag immediately after op-code decode, **before rights-check**:

```
lea rax, [rip + cap_mem_msg]
call uart_puts
```

Six tags (from tags.pdx):
- cap_mem_msg [16 bytes, NUL-inclusive]: "CAP INVOKE MEM\n\0"
- cap_ipc_msg [16 bytes]: "CAP INVOKE IPC\n\0"
- cap_sched_msg [18 bytes]: "CAP INVOKE SCHED\n\0"
- cap_dev_msg [16 bytes]: "CAP INVOKE DEV\n\0"
- cap_dispatch_ok_msg [17 bytes]: "CAP DISPATCH OK\n\0"
- cap_denied_msg [12 bytes]: "CAP DENIED\n\0"

Rationale:
1. **Diagnostic completeness**: every attempt logged (even failures).
2. **Lazy evaluation safety**: tag emitted before heavy operations.
3. **NUL-termination correctness**: uart_puts walks until NUL; byte arrays must include terminator.

---

## Section 2 — Register-Hazard Analysis for m2-001 (assembly with annotations)

M2-001 (dispatcher skeleton implementation) requires detailed register-hazard analysis. This section documents the hazard-crossing points in the descriptor-read and kind-dispatch sequence. The descriptor is **24 bytes** (kind@0, rights@8, target_ptr@16), matching the R8 MVP arithmetic in `src/kernel/core/cap/invoke.pdx` (`slot*8 + slot*16 = slot*24`) and the layout in `src/kernel/core/cap/table.pdx`.

### Full sequence (slot-arithmetic prologue + descriptor reads + handler-ABI setup)

```
; ENTRY:   rdi = slot            (from caller cap_invoke)
;          rsi = op_arg          (from caller cap_invoke)
;
; Slot-arithmetic prologue (identical to B5-004 MVP):
mov rax, cap_table           ; rax = &cap_table
mov r8, rdi                  ; r8 = slot
shl r8, 3                    ; r8 = slot * 8
mov r9, rdi                  ; r9 = slot
shl r9, 4                    ; r9 = slot * 16
add r8, r9                   ; r8 = slot * 24
add rax, r8                  ; rax = &cap_table + slot*24 = &descriptor
;
; Descriptor field reads (three loads):
mov rcx, [rax + 0]           ; rcx = descriptor.kind
mov rdx, [rax + 8]           ; rdx = descriptor.rights
mov r10, [rax + 16]          ; r10 = descriptor.target_ptr
;
; Handler-ABI setup — HAZARD ZONE:
;   Incoming rsi (op_arg) MUST be saved before rsi is overwritten with target_ptr.
;   First hazard-crossing move: `mov r11, rsi` — this is the operation that
;   makes the rest of the sequence safe. All subsequent moves may proceed
;   in any order because r11 now holds op_arg.
mov r11, rsi                 ; <-- FIRST HAZARD-CROSSING MOVE
                             ;     r11 = op_arg (saved from rsi)
mov rdi, rdx                 ; rdi = rights (handler arg 1)
mov rsi, r10                 ; rsi = target_ptr (handler arg 2) — rsi now clobbered but safe
mov rdx, r11                 ; rdx = op_arg (handler arg 3)
;
; Kind switch (A1 direct branch):
cmp rcx, 4;  je call_kind_page          ; KIND_PAGE
cmp rcx, 5;  je call_kind_ipc           ; KIND_IPC_ENDPOINT
cmp rcx, 7;  je call_kind_sched         ; KIND_SCHED_CTX
cmp rcx, 10; je call_kind_dev           ; KIND_DEVICE
;
; Fallthrough: R8 MVP behaviour — return target_ptr
mov rax, rsi                 ; rax = target_ptr
ret
```

**Hazard groups (slot-arithmetic prologue, no hazards)**:
- `mov rax, cap_table`: table base load (no dependency).
- `mov r8, rdi; shl r8, 3`: slot*8 (depends on rdi, ready at entry).
- `mov r9, rdi; shl r9, 4`: slot*16 (depends on rdi, ready at entry).
- `add r8, r9; add rax, r8`: descriptor address (depends on r8, r9, rax — all ready).

**Conclusion**: No hazard-crossing moves in the prologue. All operations are independent or within the same logical group. r8, r9, and r10 (used for the descriptor address and target_ptr) are all caller-saved scratch registers per System V AMD64 ABI; none is callee-saved, so no push/pop is required.

### Handler-ABI setup (FIRST HAZARD-CROSSING SEQUENCE)

The `mov r11, rsi` is the **first hazard-crossing move**:

1. **Why it's a hazard.** At function entry, `rsi` holds `op_arg` (per the System V AMD64 ABI, the caller's 2nd argument). The descriptor-read sequence does not touch `rsi`, so `op_arg` remains live in `rsi` up through the handler-ABI setup. The very next instruction after `mov r11, rsi` is `mov rdi, rdx` (safe — no dependency on rsi), followed by `mov rsi, r10` — which **overwrites** rsi with `target_ptr`. If `op_arg` had not first been copied out of `rsi` into `r11`, it would be lost.
2. **This is the hazard-crossing boundary** between "the phase where `rsi` still holds the caller's `op_arg`" and "the phase where `rsi` has been repurposed as a handler argument register (target_ptr)". Every instruction after `mov r11, rsi` is free to clobber `rsi` because `r11` now holds the only remaining copy of `op_arg`.
3. **Register-class rationale.** Per System V AMD64 ABI, `r11` is caller-saved (scratch): no value is guaranteed to survive a call in `r11`, so using it as a temporary here introduces no obligation to preserve anything for the caller. This is in contrast to `r12`, which is **callee-saved** — using `r12` as scratch without a `push r12` / `pop r12` pair would silently corrupt the caller's frame. The dispatcher sequence uses only caller-saved scratch registers (r8, r9, r10, r11) and never touches r12.

**Hazard-crossing pattern for m2-001 reviewer**:

M2-001 implementation checklist:
- [ ] Confirm that the first hazard-crossing move `mov r11, rsi` is placed immediately after the three descriptor field reads and before `rsi` is overwritten.
- [ ] Confirm that no instruction overwrites `rsi` (e.g., `mov rsi, r10`) before `mov r11, rsi` completes.
- [ ] Confirm that the kind-dispatch comparisons (`cmp rcx, 4`, etc.) operate on `rcx` (kind) and do not depend on `r11`/`rsi` (they are independent).
- [ ] Confirm that no callee-saved register (r12, rbx, rbp, r13, r14, r15) is used as scratch without an explicit push/pop pair; this sequence uses only r8, r9, r10, r11 (all caller-saved).

---

## Section 3 — Return-Code Convention

### Sentinels (high-value error codes)

| Sentinel | Hex value | Meaning | Introduced |
|---|---|---|---|
| INVOKE_RESULT_INVALID_HANDLE | 0xFFFFFFFFFFFFFFFE | Invalid cap slot (R8 MVP) | R8 |
| INVOKE_DENIED | 0xFFFFFFFFFFFFFFFD | Rights check failed | R12-m1-002 |
| INVOKE_UNSUPPORTED | 0xFFFFFFFFFFFFFFFC | Operation not implemented for kind | R12-m1-002 |

All three are "high sentinels" (0xFFF... range), distinguishing from normal results (lower integers).

### Kind-specific success values

| Kind | Op | Op name | Success return value |
|---|---|---|---|
| KIND_PAGE (4) | 1 | OP_READ | 0x0000000000000001 |
| KIND_PAGE (4) | 2 | OP_WRITE | 0x0000000000000002 |
| KIND_IPC_ENDPOINT (5) | 3 | OP_SEND | 0x0000000000000003 |
| KIND_IPC_ENDPOINT (5) | 4 | OP_RECV | 0x0000000000000004 |
| KIND_SCHED_CTX (7) | 5 | OP_YIELD | 0x0000000000000005 |
| KIND_DEVICE (10) | 6 | OP_MAP_MMIO | 0x0000000000000006 |

Rationale:
1. **Return value often = op_code** for clarity.
2. **No collision with sentinels** (all are small positive integers, not high sentinels).
3. **Kind-specific** (different kinds may reuse the same op_code value in their handlers; return value uniqueness is per-kind).

---

## Section 4 — Implementation Notes

### invoke.pdx dispatcher skeleton (m2-001)

Pseudo-code for cap_invoke_dispatch (to be implemented in m2-001):

```
pub let cap_invoke_dispatch : (u64, u64) -> u64 = fn (slot: u64, op_arg: u64) -> {
    descriptor_addr = &descriptor_table[slot]
    kind = [descriptor_addr + 0]
    
    # Four-way dispatch (A1)
    if kind == 4:
        result = cap_handler_page(descriptor_addr, op_arg)
    else if kind == 5:
        result = cap_handler_ipc(descriptor_addr, op_arg)
    else if kind == 7:
        result = cap_handler_sched(descriptor_addr, op_arg)
    else if kind == 10:
        result = cap_handler_dev(descriptor_addr, op_arg)
    else:
        result = INVOKE_UNSUPPORTED
    
    return result
}
```

### Per-kind handler pattern (m3-001, m4-001, m4-002)

Each handler (e.g., cap_handler_page in kind_page.pdx):

```
pub let cap_handler_page : (u64, u64) -> u64 = fn (descriptor_addr: u64, op_arg: u64) -> {
    # Decode op_code
    op_code = op_arg & 0xFF
    
    # Emit tag
    lea rax, [rip + cap_mem_msg]
    call uart_puts
    
    # Rights-check and execution (per op_code)
    if op_code == 1:  # OP_READ
        rights = [descriptor_addr + 8]
        if (rights & 0x01) != 0x01:
            lea rax, [rip + cap_denied_msg]
            call uart_puts
            return INVOKE_DENIED
        # perform read...
        return OP_READ  # 0x1
    elif op_code == 2:  # OP_WRITE
        rights = [descriptor_addr + 8]
        if (rights & 0x02) != 0x02:
            lea rax, [rip + cap_denied_msg]
            call uart_puts
            return INVOKE_DENIED
        # perform write...
        return OP_WRITE  # 0x2
    else:
        return INVOKE_UNSUPPORTED
}
```

### Shared tag strings (tags.pdx, m1-002)

Located in `src/kernel/core/cap/tags.pdx` (created with m1-002 audit entry):

```
module CapTags = structure {
  pub let cap_mem_msg : [u8; 16] = "CAP INVOKE MEM\n\0"
  pub let cap_ipc_msg : [u8; 16] = "CAP INVOKE IPC\n\0"
  pub let cap_sched_msg : [u8; 18] = "CAP INVOKE SCHED\n\0"
  pub let cap_dev_msg : [u8; 16] = "CAP INVOKE DEV\n\0"
  pub let cap_dispatch_ok_msg : [u8; 17] = "CAP DISPATCH OK\n\0"
  pub let cap_denied_msg : [u8; 12] = "CAP DENIED\n\0"
}
```

Note: Byte counts are NUL-inclusive (e.g., "CAP INVOKE MEM\n" is 15 characters; with NUL terminator, 16 bytes).

---

## Section 5 — Access Control Discipline

### Rights evaluation at per-handler level

Each handler is responsible for enforcing its own access-control policy:

1. **Input validation**: Handler receives (descriptor_addr, op_arg) and must validate descriptor_addr points to a valid descriptor.
2. **Op-code extraction**: `op_code = op_arg & 0xFF` (lower 8 bits).
3. **Rights-mask lookup**: For each op_code, the handler knows the required rights (per Section D of r12-preflight.md).
4. **Rights-check enforcement**: `if (rights & required_mask) != required_mask: return INVOKE_DENIED`.
5. **Operation execution**: If rights pass, perform the underlying operation.

### Capability invariants

Per `design/capabilities/linearity-and-tags.md` §3.1:

- Capabilities are linear (can be used once or discarded, not copied).
- A denied invocation consumes the operation argument but returns INVOKE_DENIED (no side effect).
- A successful invocation returns the operation-specific result (kind-dependent).

R12-m1-002 enforces these invariants through the per-handler rights-check discipline.

---

## Section 6 — Traceability

### Issue #405 (r12-m1-002)

GitHub issue: https://github.com/paideia-os/paideia-os/issues/405

Plan reference: `.plans/r12-round-osarch-plan.md` §4 m1-002 (dispatch architecture pin + tags.pdx + audit entry).

Related issues:
- #404 (r12-m1-001): Pre-flight audit sections A–J.
- #406–#407 (r12-m3): MEM and SCHED handlers.
- #408–#409 (r12-m4): IPC and DEV handlers.
- #410–#412 (r12-m5): Smoke, fingerprint, regression.

### Cross-references

- **design/milestones/r12-preflight.md** (sections K–O): Dispatch architecture decisions (copy of this audit's findings).
- **src/kernel/core/cap/tags.pdx** (new file): Tag-string constants.
- **design/capabilities/linearity-and-tags.md**: Capability model and invariants.
- **design/audit/entries/r11-m3-001-sched-save-frame.md**: Register-hazard analysis methodology (precedent).

---

## Section 7 — Validation Checklist

R12-m1-002 is complete when:

- [ ] r12-preflight.md sections K–O exist and match this audit entry.
- [ ] tags.pdx file created with six `pub let` symbols, NUL-inclusive byte counts [16, 16, 18, 16, 17, 12].
- [ ] tools/build.sh succeeds (tags.pdx type-checks and links correctly).
- [ ] Smoke tests pass: `boot_r8_only`, `boot_r10`, `boot_r11` (no regression).
- [ ] Register-hazard crossing annotated: `mov r11, rsi` marked as first hazard-crossing move.
- [ ] Per-handler rights-check pattern matches Section 4 template (each handler has `and mask; cmp mask` check before operation).
- [ ] Tag-emission point confirmed: after op-code decode, before rights-check (ensures every invocation produces output).

---

## Section 8 — Final Checklist

- [ ] Audit entry complete with 8 sections (overview + 7 detailed sections).
- [ ] YAML frontmatter populated (audit_id, issue, file, function, effects, capabilities, reviewed_by, date, status).
- [ ] Register-hazard analysis explicit (first hazard-crossing move identified).
- [ ] Return-code convention table complete (3 sentinels + 6 success values).
- [ ] Implementation notes provide pseudo-code templates for m2-001 and m3–m4 reviewers.
- [ ] Access-control discipline explains per-handler rights enforcement.
- [ ] Traceability section links to related issues and design documents.
- [ ] No blocking concerns for m2-001 implementation.

---

## Trailer

**Audit date**: 2026-07-02  
**Issue**: #405  
**Status**: Ready for m2-001/m2-002 implementation.
