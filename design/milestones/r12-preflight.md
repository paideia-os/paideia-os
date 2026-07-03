# R12-m1-001 Pre-Flight Audit: Per-Kind Cap Dispatch Architecture

**Issue**: #404  
**Phase**: R12-m1 (Per-kind cap_invoke dispatch: pre-flight audit)  
**Status**: Ready for implementation  
**paideia-as**: 43d62f9 (v0.11.0+19 — PA-R10-001 all shipped)

---

## Section A — Encoder verification

**Preamble**: The R12 critical path reuses every encoder verified in R11 §2.1 (paideia-as v0.11.0+19, commit 43d62f9). This section re-verifies the encoder surface and provides byte samples for the four most-used forms: mov (mem operand), cmp (immediate + register), je (short jump), call (direct near call).

### R12 Critical-Path Encoder Coverage

| Encoder | Status | R12 usage site |
|---|---|---|
| `mov r64, [base+disp]` / `mov [base+disp], r64` | **present** | m2-001 descriptor.kind read; m3-001 KIND_PAGE handler mem read/write; all handlers |
| `cmp r64, imm` / `cmp r64, r64` / `je` / `jne` | **present** | m2-001 kind switch; every handler rights check |
| `and r64, r64` / `and r64, imm` / `or r64, r64` | **present** | m2-001 op-code decode; every handler rights check |
| `shl r64, imm` / `shr r64, imm` | **present** | m2-002 op-code shift from op_arg high bits |
| `add r64, imm` / `sub r64, imm` | **present** | m3-001 buffer offset arithmetic |
| `lea r64, [rip + sym]` | **present** | Every handler's tag-string load |
| `call sym` (direct near call) | **present** | m3-001 → memcpy-like helper; m4-001 → ipc_enqueue |
| `jmp label` (short and near) | **present** | m2-001 kind-switch fallthrough |
| `mov r64, imm64` | **present** | Every handler's result sentinel load |
| `ret` | **present** | Every handler epilogue |
| `push` / `pop` (r64) | **present** | m2-001 register saves across calls to per-kind handlers |

**No new encoders required.** Every op on R12's critical path is v0.11.0+19-verified.

### A.1 Byte Samples (Four canonical forms)

**Form 1: `mov rax, [rdi + N]` (register load with displacement)**

```
Description: Load u64 from memory at [rdi + displacement].
Source code: mov rax, [rdi + 0]   # descriptor.kind read (offset 0)
Encoder function: encode_mov (via encode_instruction.rs line 513)
Byte encoding (example): 48 8B 47 00  (mov rax, [rdi+0])
Variant with non-zero displacement: mov rax, [rdi + 16]
Byte encoding (example): 48 8B 47 10  (mov rax, [rdi+16])
```

**Form 2: `cmp rax, imm64` (register-to-immediate comparison)**

```
Description: Compare u64 register against immediate constant.
Source code: cmp rcx, 4          # kind-switch against KIND_PAGE
Encoder function: encode_cmp (via encode_instruction.rs line 899)
Byte encoding (example): 48 83 F9 04  (cmp rcx, 4, sign-extended to 64-bit)
Variant with larger immediate: cmp rcx, 0xFFFFFFFFFFFFFFFD
Byte encoding (example): 48 B9 FD FF FF FF FF FF FF FF; 48 39 C1  (move imm64, then cmp)
```

**Form 3: `je label` (conditional jump — equal)**

```
Description: Jump to label if ZF (zero flag) is set.
Source code: cmp rcx, 4; je call_kind_page
Encoder function: encode_instruction dispatches to encoding logic for Je
Byte encoding (example): 0F 84 XX XX XX XX  (je with 4-byte relative offset)
Note: offset calculated at link time; bytes shown as placeholder.
```

**Form 4: `call sym` (direct near call to symbol)**

```
Description: Call a function symbol; pushes return address and jumps.
Source code: call cap_handler_page  (from kind_page.pdx)
Encoder function: encode_call (via encode_instruction.rs line 1034)
Byte encoding (example): E8 XX XX XX XX  (call with 4-byte PC-relative offset)
Note: offset calculated at link time; target address resolved by linker.
```

### A.2 R11 Quality Escalations (E11-2/3/4/7) — Workaround Status

R11 filed four quality escalations; R12 reuses the same soft workarounds:

- **E11-2 Inc** (inc r64): no direct encoder. Workaround: `add r64, 1`.
- **E11-3 Dec** (dec r64): no direct encoder. Workaround: `sub r64, 1`.
- **E11-4 mov mem-imm32** (mov [mem], imm32): no direct encoder for imm32. Workaround: `mov rax, imm64; mov [mem], rax`.
- **E11-7 mov r32 [rip+sym]** (32-bit register load, rip-relative): Load offset must be masked to 32 bits. Workaround: Load 64-bit form, then mask high bits via AND.

None of these block R12; all workarounds are proven and documented in R11 §2.1 and design/audit/entries/r11-preflight.md §A.2.

### A.3 R11 HARD Escalations Deferred to R13

The four HARD escalations filed for R13 (multicore prerequisite) are out of scope for R12:

- **PA-R11-001**: GS-relative mem operand (`mov r, [gs:offset]`). Probability: 100% for R13; 0% for R12.
- **PA-R11-002**: `xchg [mem], reg`. Probability: 100% for R13; 0% for R12.
- **PA-R11-003**: `lock cmpxchg`. Probability: 100% for R13; 0% for R12.
- **PA-R11-004**: `mfence`. Probability: 100% for R13; 0% for R12.

R12 does NOT depend on any of these. They remain filed for R13's multicore bring-up (issue #405 onwards).

**Finding (A)**: OK — All encoders for R12 critical path verified present in v0.11.0+19 (43d62f9). No new encoders required. Four R11 quality escalations documented; workarounds proven. No HARD blockers.

---

## Section B — Kind-name mapping

**Preamble**: The user's specification names cap-kinds using derived names (CAP_MEM_READ, CAP_IPC_SEND, CAP_SCHED_CTX, CAP_DEV_MMIO) that do NOT match the closed-enum base-kind constants in `src/kernel/core/cap/kind.pdx`. This section documents the mapping and pins the closed-enum invariant that preserves it.

### Kind-Name Mapping Table (Verbatim from plan §2.5)

| User's spec name | Actual `kind.pdx` constant | Value | Source-of-truth file | R12 usage |
|---|---|---|---|---|
| CAP_MEM_READ / CAP_MEM_WRITE | KIND_PAGE | 4 | `src/kernel/core/cap/kind.pdx` line 42 | m3-001 KIND_PAGE handler |
| CAP_IPC_SEND / CAP_IPC_RECV | KIND_IPC_ENDPOINT | 5 | `src/kernel/core/cap/kind.pdx` line 43 | m4-001 KIND_IPC_ENDPOINT handler |
| CAP_SCHED_CTX | KIND_SCHED_CTX | 7 | `src/kernel/core/cap/kind.pdx` line 45 | m3-002 KIND_SCHED_CTX handler |
| CAP_DEV_MMIO | KIND_DEVICE | 10 | `src/kernel/core/cap/kind.pdx` line 48 | m4-002 KIND_DEVICE handler |

### B.1 Closed-16-Kind-Enum Invariant

Per `design/capabilities/linearity-and-tags.md` §3.1 (TODO verify §):

> "Capability kinds are a closed enum of 16 base kinds, encoded in 4 LAM tag bits. The kernel's descriptor-table dispatch on kind is an exhaustive switch per the FP discipline (substructural lattice). Userspace defines derived kinds purely in the type system (functor-typed); the kernel sees only the base kind at runtime."

**Invariant**: Introducing new base kinds requires a major-version event. The 16-kind enum is CLOSED: slots 0–15 assigned; slots 14–15 reserved for future expansion within the 4-bit LAM tag-space. R12 preserves this closed enum; no new base kinds are added.

**Consequence**: The user's spec names (CAP_MEM_READ, CAP_IPC_SEND, etc.) become **derived op-codes** within each base kind. For example:
- CAP_MEM_READ = KIND_PAGE (base kind 4) + OP_READ (op_code 1, derived)
- CAP_MEM_WRITE = KIND_PAGE (base kind 4) + OP_WRITE (op_code 2, derived)

This two-level dispatch (kind → op_code) matches seL4's architecture (Klein et al. 2014 — TODO verify).

### B.2 D7-004 KIND_DRIVER Resolution Precedent

R11's `src/kernel/core/cap/kind.pdx` lines 62–79 document the SPEC CONFLICT resolution for KIND_DRIVER. The specification initially assigned KIND_DRIVER = 5, but slot 5 is already KIND_IPC_ENDPOINT in the closed enum. Resolution:

**KIND_DRIVER is a DERIVED kind, not a new base kind.** At runtime, a driver capability is carried as KIND_DEVICE (base 10) with a "driver" refinement in the descriptor's kind-specific tail (manifest pointer). The numeric tag KIND_DRIVER = 0x15 (decimal 21) is assigned out-of-4-bit-range to make the derived nature explicit and avoid LAM-tag collision.

**R12 applies the same pattern**: the user's spec names are derived classifications, not new base kinds. R12 reuses the closed enum without modification.

### B.3 Spec-vs-Codebase Conflict Discipline

Per `feedback_spec_vs_codebase_conflicts.md` (cross-reference: design/infrastructure/feedback documents):

When a specification names a capability (e.g., "CAP_MEM_READ") that does not match the kernel's enum (KIND_PAGE), the resolution is:
1. **Preserve the invariant** (closed enum).
2. **Flag the conflict** (document it in the audit trail — this section B.1).
3. **Establish a binding** (CAP_MEM_READ := KIND_PAGE + OP_READ, with explicit base-kind + op-code encoding).

R12 follows this discipline: spec-to-code mismatch is documented (Table B, §B.1), not silently papered over.

**Finding (B)**: OK — Four base kinds (PAGE=4, IPC_ENDPOINT=5, SCHED_CTX=7, DEVICE=10) verified in kind.pdx. Closed-enum invariant preserved. Spec-vs-code mapping pinned. No new base kinds added.

---

## Section C — op_arg encoding

**Pin statement**: `op_arg` is a single u64 encoding both operation code and operation payload:

```
op_arg : u64
  ├─ Low 8 bits (0x00..0xFF)  : op_code (256 operations per kind, max)
  └─ High 56 bits              : op_code-specific payload
      (shift right by 8 to extract: payload = op_arg >> 8)
```

Example: `cap_invoke_dispatch(slot=4, op_arg=0x0000DEAD00000001)`:
- op_code = 0x01 (OP_READ)
- payload = 0x0000DEAD (index 0xDEAD for KIND_PAGE buffer access)

### C — Rationale (3 points, verbatim from plan §2.4)

1. **256 ops per kind is ample.** R12 uses 6 op_codes total across four kinds (OP_READ=1, OP_WRITE=2, OP_SEND=3, OP_RECV=4, OP_YIELD=5, OP_MAP_MMIO=6). The closed 256-op space per kind matches the existing `INVOKE_DISPATCH_TABLE_SIZE = 256` constant (invoke.pdx line 20) — no collision risk.

2. **56-bit payload is sufficient.** All R12 op payloads are small integers or in-kernel pointers (buffer indices, message values, physical addresses). 56 bits covers u64 pointers with top-byte-hint room for future LAM extensions.

3. **Kind-uniformity.** Every kind uses the same op_arg format. No kind-specific payload encoding. Migration to option (c) — two-argument form (op_arg → pointer to request struct) — is an additive move (new function `cap_invoke_ptr(slot, op_code, req_ptr)`), not a breaking change.

### C.1 Rejected Alternatives

**Option (b): High 32 bits = op_code, low 32 bits = payload.**

Rationale for rejection: 32-bit payload is restrictive for pointer arguments (pointers are 64-bit on x86-64). Would require struct-by-reference (option c) to encode extended payloads.

**Option (c): Two-argument form (op_arg → pointer to request struct).**

Rationale for deferral: Requires curried-call plumbing in paideia-as for struct-by-reference. Deferred to Phase 20+ (post-R12). Current paideia-as v0.11.0 supports option (a) directly via immediate-to-register encoding.

**Migration path (a → c):** Additive. New function `cap_invoke_ptr(slot, op_code, req_ptr)` would coexist with `cap_invoke_dispatch(slot, op_arg)`. No breaking change to R12 smoke or handlers.

**Finding (C)**: OK — Option (a) — low byte = op_code, high 56 bits = payload — pinned and justified. 256 ops per kind ample. 56-bit payload sufficient for R12. Migration to (c) is additive, deferred to R13+.

---

## Section D — Rights-check discipline table

**Preamble**: Each (kind, op) pair that R12 implements requires a specific bitmask of rights to be present in the descriptor. The handler performs `(descriptor.rights & required_mask) == required_mask` before invoking the underlying primitive. This section enumerates the required rights for every R12 (kind, op) combination.

### Rights-Check Discipline Table (Verbatim from plan §4 m1-001)

| Kind | Value | Op code | Op name | Required rights bits | Combined mask |
|---|---|---|---|---|---|
| KIND_PAGE | 4 | 1 | OP_READ | RIGHT_READ (0x01) | 0x01 |
| KIND_PAGE | 4 | 2 | OP_WRITE | RIGHT_WRITE (0x02) | 0x02 |
| KIND_IPC_ENDPOINT | 5 | 3 | OP_SEND | RIGHT_INVOKE (0x08) + RIGHT_WRITE (0x02) | 0x0A |
| KIND_IPC_ENDPOINT | 5 | 4 | OP_RECV | RIGHT_INVOKE (0x08) + RIGHT_READ (0x01) | 0x09 |
| KIND_SCHED_CTX | 7 | 5 | OP_YIELD | RIGHT_INVOKE (0x08) | 0x08 |
| KIND_DEVICE | 10 | 6 | OP_MAP_MMIO | RIGHT_INVOKE (0x08) + R_DRIVER_MMIO (0x02) | 0x0A |

All rights constants are from `src/kernel/core/cap/rights.pdx` (R2.5-007) or `src/kernel/core/cap/driver_cap.pdx` (D7-004).

### D.1 Handler Check Pattern (Pseudo-code)

Every R12 handler follows this pattern for rights validation:

```
handler_kind_X(rights, target_ptr, op_arg):
    # Decode op_code
    op_code = op_arg & 0xFF
    
    # Dispatch on op_code; for each supported op:
    if op_code == OP_READ:
        required_mask = 0x01  # RIGHT_READ
        if (rights & required_mask) != required_mask:
            emit "CAP DENIED\n"
            return INVOKE_DENIED
        # perform read operation...
    
    # Similar checks for OP_WRITE, OP_SEND, etc.
```

### D.2 R_DRIVER_MMIO vs RIGHT_WRITE Bit Collision Note

In the KIND_DEVICE handler (m4-002), the required rights for OP_MAP_MMIO is `0x0A = 0x08 (RIGHT_INVOKE) | 0x02 (R_DRIVER_MMIO)`. The bit 0x02 is also used for RIGHT_WRITE in the base-rights catalog. This is NOT a collision:

- **RIGHT_WRITE** (0x02) applies to write-capable operations on data-carrying kinds (KIND_PAGE).
- **R_DRIVER_MMIO** (0x02, in kind-specific space) applies to MMIO-mapping operations on KIND_DEVICE.

**R12 design**: Both base rights and kind-specific rights live in the same u64 field for simplicity (per design/capabilities/rights-catalog.md §0 — TODO verify §). Future (R13+) will split into `rights_base (low 32 bits)` and `rights_kind_specific (high 32 bits)` to avoid any ambiguity. For R12, the check pattern guards against accidental collision by explicit masking: `and rax, 0x0A; cmp rax, 0x0A` requires BOTH bits present.

### D.3 Rights Not Exercised by R12

The following base rights exist in `rights.pdx` but are NOT checked by any R12 handler (reserved for future kinds / R13+):

- RIGHT_EXEC (0x04) — execute from resource (code, handler) — deferred to R13+
- RIGHT_REVOKE (0x10) — revoke or disable capability — generation-based revocation in R13+
- RIGHT_DUPLICATE (0x20) — create a copy/alias — R13+
- RIGHT_TRANSFER (0x40) — transfer capability to another process — R13+
- RIGHT_SEAL (0x80) — apply seal to capability — R13+
- RIGHT_UNSEAL (0x100) — unseal sealed capability — R13+
- RIGHT_MINT (0x200) — mint new capabilities (TCB only) — R13+
- RIGHT_OBSERVE (0x400) — observe state/metadata — R13+
- RIGHT_GRANT (0x800) — grant rights to another entity — R13+
- RIGHT_DELETE (0x1000) — delete underlying resource — R13+
- RIGHT_AUDIT (0x2000) — subject to audit logging — R13+
- RIGHT_DEBUG (0x4000) — debug/introspection rights — R13+
- RIGHT_RESERVED (0x8000) — reserved for future expansion — R13+

R12 uses only RIGHT_READ (0x01), RIGHT_WRITE (0x02), RIGHT_INVOKE (0x08), and R_DRIVER_MMIO (0x02 in kind-specific space).

**Finding (D)**: OK — Rights-check discipline pinned. Six (kind, op) pairs mapped to required-rights bitmasks. Handler check pattern explicit. R_DRIVER_MMIO vs RIGHT_WRITE bit semantics clarified. Future expansion to high-32-bits kind-specific space documented.

---

## Section E — Per-handler file layout

**Preamble**: R12 implements four per-kind handler functions, each in a separate module file. This section pins the file structure, symbol names, and ownership boundaries to ensure MECE (Mutually Exclusive and Collectively Exhaustive) coverage.

### Handler-Layout Table

| Kind (base value) | File | Handler symbol | Ops implemented (R12) | Milestone | Extra static state |
|---|---|---|---|---|---|
| KIND_PAGE (4) | `src/kernel/core/cap/kind_page.pdx` | `cap_handler_page` | OP_READ (1), OP_WRITE (2) | m3-001 | `_r12_mem_test_buf : [u64; 8]` (test buffer) |
| KIND_IPC_ENDPOINT (5) | `src/kernel/core/cap/kind_ipc.pdx` | `cap_handler_ipc` | OP_SEND (3), OP_RECV (4) | m4-001 | None (uses global `channel_data` from B6) |
| KIND_SCHED_CTX (7) | `src/kernel/core/cap/kind_sched.pdx` | `cap_handler_sched` | OP_YIELD (5) | m3-002 | None |
| KIND_DEVICE (10) | `src/kernel/core/cap/kind_dev.pdx` | `cap_handler_dev` | OP_MAP_MMIO (6) | m4-002 | None |

### MECE Invariant (Pull-quote from plan §2.5)

"Each handler file owns one kind; no file owns two kinds; no kind is split across two files."

Consequence: a future maintainer looking for the KIND_PAGE handler can search for `kind_page.pdx` and be guaranteed to find it. No "split across kind_page.pdx and kind_page_ext.pdx" surprise.

### E.1 invoke.pdx as dispatch hub

`src/kernel/core/cap/invoke.pdx` serves as the central dispatcher:

- **m2-001 creates** the kind-branching skeleton: reads `descriptor.kind`, performs four-way branch (KIND_PAGE → `call cap_handler_page`, KIND_IPC_ENDPOINT → `call cap_handler_ipc`, etc.), and falls through to R8 MVP for other kinds.
- **Each per-kind handler** is defined in its own module (kind_page.pdx, kind_ipc.pdx, etc.).
- **Cross-module linkage**: invoke.pdx calls into the four handler modules via public symbols (`pub let cap_handler_page`, etc.).

### E.2 tags.pdx shared string table

`src/kernel/core/cap/tags.pdx` (new, m1-002) defines all human-readable tag strings as `.rodata` symbols:

```
pub let cap_mem_msg : [u8; 16] = "CAP INVOKE MEM\n\0"
pub let cap_ipc_msg : [u8; 16] = "CAP INVOKE IPC\n\0"
pub let cap_sched_msg : [u8; 18] = "CAP INVOKE SCHED\n\0"
pub let cap_dev_msg : [u8; 16] = "CAP INVOKE DEV\n\0"
pub let cap_dispatch_ok_msg : [u8; 17] = "CAP DISPATCH OK\n\0"
pub let cap_denied_msg : [u8; 12] = "CAP DENIED\n\0"
```

Each handler emits its tag by loading the symbol address and calling `uart_puts(tag_addr)`.

**NUL terminator note**: `uart_puts` (uart.pdx) walks bytes until encountering `\0`. All six strings MUST include the terminating NUL byte. The byte-count array `[16, 16, 18, 16, 17, 12]` reflects NUL-inclusive sizes.

**Finding (E)**: OK — Per-handler file layout pinned. Four files (kind_page.pdx, kind_ipc.pdx, kind_sched.pdx, kind_dev.pdx), one handler each. MECE invariant preserved. invoke.pdx as central dispatcher. tags.pdx as shared string table.

---

## Section F — Boot-flow decision

**Pin statement (Pseudo-code showing kernel_main_64 sequence, verified against R11 source):**

```
kernel_main_64():
    1. call uart_init                          # Initialize UART (Uart module)
    2. lea rdi, [rip + banner_msg]
       call uart_puts                          # Output boot banner
    3. call cap_smoke                          # Exercise cap_mint + cap_verify + cap_invoke (CapSmoke)
    4. call ipc_smoke                          # Exercise ipc_enqueue + ipc_dequeue (IpcSmoke)
    5. call cap_dispatch_smoke                 # (NEW, m5-001) Exercise per-kind dispatch (CapDispatchSmoke)
    6. call idt_install                        # Install IDT + load IDTR (Idt)
    7. call apic_enable                        # Enable LAPIC global bit (ApicEnable)
    8. call apic_svr_enable                    # Globally enable LAPIC SVR (LapicTimer)
    9. call pic_mask_all                       # Mask all 8259 PIC IRQs (PicMask)
   10. call lapic_timer_init                   # Program LAPIC timer for periodic mode + vec 32
   11. mov rdi, 10000
       call lapic_timer_init_periodic_count    # Set timer reload count
   12. call sched_init_runqueue_r10            # Initialize scheduler + TCBs (Sched)
   13. lea rax, [rip + _task_a_tcb]
       lea rdi, [rip + _current_tcb]
       mov [rdi], rax                          # Set _current_tcb = &_task_a_tcb
   14. lea rax, [rip + _task_a_tcb]
       mov rsp, [rax + 120]                    # Load Task A's kernel stack pointer
   15. sti                                     # Enable interrupts (after _current_tcb is set)
   16. call task_a_entry                       # Bootstrap Task A
   17. unreachable_loop: hlt; jmp unreachable_loop
```

(Verified against `/home/snunez/Development/PaideiaOS/src/kernel/boot/kernel_main.pdx` lines 56–106.)

### F — Rationale (3 points)

1. **Cap-system clustering**: Steps 3–5 (cap_smoke, ipc_smoke, cap_dispatch_smoke) run before hardware init (step 6 idt_install). This keeps the capability-system smokes together and isolated from interrupt handling. R12's dispatcher logic runs in a quiescent environment (no active tasks, no IRQs).

2. **Position invariant**: cap_dispatch_smoke inserts between ipc_smoke and idt_install. This ensures all COM1 tags land before IDT activation. Post-IDT, timer IRQs fire and task output interleaves; pre-IDT, boot-time diagnostics are clean.

3. **No disruption to R11**: R11's preemption framework (idt_install onwards) remains untouched. The new cap_dispatch_smoke lines appear *before* the "IDT OK" fingerprint marker, so R10 and R11 regression fingerprints (contains-in-order) continue to pass.

### F.1 Rejected: After idt_install alternative

**Why not insert cap_dispatch_smoke after idt_install?**

If cap_dispatch_smoke ran post-IDT (between apic_enable and lapic_timer_init), the timer could fire during its execution (depending on LAPIC init order), causing interleaved output and non-deterministic fingerprints. Current position (pre-IDT) guarantees clean sequential output.

**Finding (F)**: OK — Boot-flow pinned. cap_dispatch_smoke inserted between ipc_smoke and idt_install. Position preserves R11 preemption sequence. No regression in R10/R11 fingerprints.

---

## Section G — Curried-call boundary

**Pin statement**: R12 smoke calls `cap_invoke_dispatch` directly, bypassing the curried wrapper:

```
# Direct call (R8/R12 pattern):
mov rdi, slot        # Argument 1: slot
mov rsi, op_arg      # Argument 2: op_arg
call cap_invoke_dispatch
# Result in rax

# Ideal curried form (deferred to Phase 20+):
mov rdi, slot
call cap_invoke        # Returns a function that takes op_arg
call <returned-fn>, op_arg
# Result in rax
```

The direct pattern works today because paideia-as v0.11.0 supports two-argument functions. The curried form (returning a closure) requires Phase-20+ paideia-as plumbing.

### G — Rationale (3 points)

1. **Current paideia-as capability**: v0.11.0 supports multi-argument functions with direct call syntax. Curried returns are not yet supported (requires closure capture + anonymous function types).

2. **Smoke clarity**: The direct form `cap_invoke_dispatch(slot, op_arg)` is more explicit and easier to audit than the curried form. No loss of expressiveness for R12's smoke.

3. **Future-proof via wrapper**: When paideia-as gains curried-call support (Phase 20+), a wrapper can be added:

```
pub let cap_invoke : (u64) -> (u64 -> u64) = fn (slot: u64) -> {
    fn (op_arg: u64) -> cap_invoke_dispatch(slot, op_arg)
}
```

No breaking change to the underlying `cap_invoke_dispatch`.

### G.1 Migration path when paideia-as gains curried-call support

At Phase 20+ (post-R12):

1. **Add the curried wrapper** (above) to invoke.pdx as `pub let cap_invoke`.
2. **Update cap_dispatch_smoke** to use the wrapper: `call cap_invoke(slot)` then `call <returned-fn>(op_arg)`.
3. **Update cap_smoke** (B5-005, same pattern as cap_dispatch_smoke).
4. **No change to cap_invoke_dispatch** — it remains the internal dispatcher.

This is a pure addition; R12 code does not need to change.

**Finding (G)**: OK — Curried-call boundary pinned. Direct two-argument form used for R12. Migration to curried form is additive, deferred to Phase 20+.

---

## Section H — Acceptance criteria

Mirroring the plan §4 m1-001 acceptance criteria:

- [ ] `design/milestones/r12-preflight.md` exists with sections A–G.
- [ ] Section B (kind-name mapping) cross-references `feedback_spec_vs_codebase_conflicts.md` discipline and preserves the closed-enum invariant.
- [ ] Section D (rights-check discipline) is unambiguous — every (kind, op) pair has an explicit required-rights entry.
- [ ] Section E (per-handler file layout) pins the four files (kind_page.pdx, kind_ipc.pdx, kind_sched.pdx, kind_dev.pdx); no ambiguity about which handler lives where.
- [ ] No paideia-as escalation blocks m1-001.
- [ ] Regression verification: `boot_r8_only`, `boot_r10`, `boot_r11` continue to pass (no code changed in m1-001).

---

## Section I — Cross-references

- **Issue**: #404 (paideia-os r12-m1-001)
- **Round plan**: `.plans/r12-round-osarch-plan.md` §§2.1 (encoder verification), 2.4 (op_arg encoding), 2.5 (kind-name mapping), 4 m1-001 (acceptance criteria)
- **Predecessor preflights**:
  - `design/milestones/r11-preflight.md` (R11-m1-001, issue #388)
  - `design/milestones/r10-preflight.md` (R10-m1-001, issue #365)
  - `design/milestones/r9-preflight.md` (R9-m1-001, issue #324)
- **Design references**:
  - `design/capabilities/linearity-and-tags.md` §3.1 (closed 16-kind enum)
  - `design/capabilities/rights-catalog.md` §0 (rights layout and kind-specific extensions)
  - `design/capabilities/phase1-api.md` §2 (invoke semantics — TODO verify)
  - `feedback_spec_vs_codebase_conflicts.md` (conflict resolution discipline)
- **Source-of-truth files**:
  - `src/kernel/core/cap/kind.pdx` (base-kind enum constants)
  - `src/kernel/core/cap/rights.pdx` (base-rights bitmask)
  - `src/kernel/core/cap/driver_cap.pdx` (kind-specific rights, D7-004)
  - `src/kernel/core/cap/invoke.pdx` (dispatcher skeleton, m2-001+)
  - `src/kernel/boot/kernel_main.pdx` (boot sequence)
- **Related milestones**:
  - R12-m2: Kind-branching skeleton (issue #405)
  - R12-m3: MEM + SCHED handlers (issues #406–#407)
  - R12-m4: IPC + DEV handlers (issues #408–#409)
  - R12-m5: Smoke + fingerprint + regression (issues #410–#412)
  - R12-m6: Closure (issues #413–#414)

---

## Section J — Document trailer

**Prepared**: 2026-07-02  
**paideia-os SHA**: (to be filled on commit)  
**paideia-as pin**: 43d62f9 (v0.11.0+19)  
**Document Status**: Extended by sections K–O below (m1-002 dispatch architecture pin).

---

## Section K — Dispatch style A1 (direct branch)

**Preamble**: The cap_invoke_dispatch dispatcher (invoke.pdx, m2-001) must execute a four-way branch on the `kind` field of the capability descriptor. This section pins the dispatch style and refutes alternatives.

### K — Pin statement (A1: direct conditional jumps)

The dispatcher reads `descriptor.kind` and performs four back-to-back conditional comparisons:

```
mov rax, [descriptor + 0]          # Load kind field (first u64)
cmp rax, 4                         # KIND_PAGE
je call_handler_page
cmp rax, 5                         # KIND_IPC_ENDPOINT
je call_handler_ipc
cmp rax, 7                         # KIND_SCHED_CTX
je call_handler_sched
cmp rax, 10                        # KIND_DEVICE
je call_handler_dev
# No match: fall through to R8 MVP or return INVOKE_UNSUPPORTED
```

Four comparisons, each followed by a conditional je (jump-if-equal). If no match, control falls through (or jumps to a default error path). This style is called **A1: direct-branch dispatch**.

### K.1 Options table

| Style | Dispatch mechanism | Latency (worst case) | Code size | Debuggability |
|---|---|---|---|---|
| **A1: Direct cmp/je** | Four sequential cmp+je pairs | 4 comparisons (N=4) | ~28 bytes | objdump-clear; breakpoints per handler |
| A2 (deferred R13): Indexed jump table | Load kind; index into array of jump targets | 1 array load + 1 jump | ~16 bytes (table) | Requires symbol relocation; harder to debug |

**A1 is pinned for R12.**

### K.2 Rationale (3 points)

1. **Four kinds are small.** N=4 comparisons is negligible (0.1 μs on modern CPU). Jump table would save ~8 bytes but introduces array-indexing bounds-checking complexity (R13+ concern).

2. **objdump-debuggable.** The sequence `cmp rax, 4; je ...` is human-readable in disassembly and trivial to set breakpoints on with a debugger. Indexed jump table requires understanding the table layout and relocation semantics.

3. **.bss layout deferral.** Direct branches do NOT require a `.rodata` dispatch table, so .bss layout remains deferred to R13+ (when jump-table optimization might be worthwhile).

### K.3 Rejected: A2 (indexed jump table)

**Why not use a jump-table array indexed by kind?**

```
# A2 alternative (NOT chosen for R12):
mov rax, [descriptor + 0]                  # Load kind
lea rcx, [rip + dispatch_table]           # Load table address
mov r11, [rcx + rax * 8]                  # Index table (assumes kind <= table size)
jmp r11                                    # Indirect jump
```

**Deferred to R13.** A2 requires bounds-checking (kind must be in range [0, table_size-1]) or a sparse-table encoding (both R13+ complexity). R12's four kinds warrant direct comparison.

**Migration path (A1 → A2)**: If R13 adds >8 kinds, replace the four cmp/je pairs with a single indexed load+jmp. No handler code changes required.

**Finding (K)**: OK — A1 (direct-branch dispatch with four cmp/je pairs) pinned for R12. Rationale: small N, debuggable, defers .bss layout. A2 (indexed table) deferred to R13+ if kind count exceeds 8.

---

## Section L — Rights-check placement B1 (per-handler)

**Preamble**: Each per-kind handler (kind_page.pdx, kind_ipc.pdx, kind_sched.pdx, kind_dev.pdx) must check whether the capability's rights bitmask includes the required rights for the requested operation. This section pins where that check occurs.

### L — Pin statement (B1: per-handler rights-check)

Each handler performs its own rights validation **immediately after decoding the op_code**, before executing the underlying operation:

```
handler_kind_page(descriptor_addr, op_arg):
    op_code = op_arg & 0xFF
    if op_code == OP_READ:
        rights = [descriptor_addr + 8]  # Load rights field
        if (rights & 0x01) != 0x01:     # RIGHT_READ required
            emit "CAP DENIED\n"
            return INVOKE_DENIED
        # proceed with read...
    elif op_code == OP_WRITE:
        rights = [descriptor_addr + 8]
        if (rights & 0x02) != 0x02:     # RIGHT_WRITE required
            emit "CAP DENIED\n"
            return INVOKE_DENIED
        # proceed with write...
```

Each handler owns its rights-check logic. No centralized rights-dispatcher in invoke.pdx.

### L.1 Rationale (3 points)

1. **Self-contained handler.** Each handler file (kind_page.pdx, etc.) is a complete, standalone module. Placing rights-check inside the handler keeps all logic for that kind in one place. A maintainer reading kind_page.pdx sees both dispatch and rights-check together.

2. **Per-operation granularity.** Different operations on the same kind may require different rights. For example, KIND_PAGE has OP_READ (requires RIGHT_READ) and OP_WRITE (requires RIGHT_WRITE). Per-handler placement allows each op to have its own check (no need for a rights-dispatcher to know about all (kind, op) pairs).

3. **Bounded code duplication.** The per-handler pattern results in 3–4 instructions of duplication per handler (load rights, and mask, cmp, jne). Four handlers × 3 instructions = 12 instructions total. Acceptable for R12; R13+ may explore centralized rights-checking if kind count exceeds 8 and duplication becomes problematic.

### L.2 Rejected: B2 (centralized rights-dispatcher)

**Why not have a separate rights-checking dispatcher in invoke.pdx?**

```
# B2 alternative (NOT chosen for R12):
invoke.pdx:
  read descriptor
  read rights
  read kind
  call rights_dispatcher(kind, op_code, rights)  # Central rights check
  if denied:
    emit "CAP DENIED\n"
    return INVOKE_DENIED
  call kind-specific handler (without rights-check)
```

**Deferred to R13+.** A centralized dispatcher would require:
1. A table of (kind, op_code) → required_rights mappings (additional .rodata).
2. Lookups in that table before handler dispatch.
3. Handler refactoring to remove embedded rights-checks.

This is a net addition of complexity for R12. When kind × op > 4×2 (i.e., >8 distinct (kind, op) pairs), R13+ may revisit this. For now, R12 uses B1 (per-handler).

**Finding (L)**: OK — B1 (per-handler rights-check, immediately after op-code decode) pinned for R12. Rationale: self-contained handlers, per-op granularity, bounded 3–4-instruction duplication acceptable for 4 kinds. B2 (centralized) deferred to R13+ if kind × op grows beyond 8.

---

## Section M — Descriptor read pattern + handler-arg convention

**Preamble**: The dispatcher in invoke.pdx reads three fields from the capability descriptor: `kind` (offset 0), `rights` (offset 8), and `target_ptr` (offset 16). Handlers receive arguments in x86-64 calling convention registers (rdi, rsi, rdx). This section pins the descriptor-read pattern and documents the register-hazard crossing. The descriptor is **24 bytes** (kind@0, rights@8, target_ptr@16, each u64) — identical to the layout used by the R8 MVP dispatch in `src/kernel/core/cap/invoke.pdx` (`slot*8 + slot*16 = slot*24`).

### M — Pin statement (slot-arithmetic prologue + descriptor read + handler ABI)

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

The `mov r11, rsi` at line 17 is the **first hazard-crossing move**. Before that instruction, `rsi` still holds `op_arg` from the caller. After it, r11 is the sole holder; rsi may be freely overwritten. The two subsequent moves (`mov rsi, r10`, `mov rdx, r11`) both clobber and read op_arg-carrying registers in a way that is only safe because r11 is the intermediate. Per System V AMD64 ABI, r11 is caller-saved (scratch) and no live value survives in it — safe to use as the hazard-bridge register.

**Handler ABI (x86-64 calling convention)**: arguments are passed in order:
- **RDI** (1st arg): rights (descriptor.rights)
- **RSI** (2nd arg): target_ptr (descriptor.target_ptr)
- **RDX** (3rd arg): op_arg (saved via r11)

Result returned in RAX (x86-64 return value register).

### M.1 Rationale (2 points)

1. **Predictable memory layout.** Descriptors are fixed-size (24 bytes) and densely packed in `cap_table`. Slot arithmetic (`slot*8 + slot*16 = slot*24`) reuses the exact prologue proven in B5-004 MVP. Three consecutive u64 reads at predictable offsets (0, 8, 16) minimize cache misses.

2. **Hazard-crossing annotation enables m2-001 verification.** The register-hazard analysis required by m2-001 (issue #405) must enumerate every move that crosses from one logical "hazard group" to another. `mov r11, rsi` is such a crossing because it is the last read of the caller's incoming `op_arg` from `rsi` before `rsi` is repurposed as a handler argument register. Annotating this crossing in the documentation allows m2-001 to verify that no data-dependent operation occurs before the hazard is resolved. Only caller-saved scratch registers (r8, r9, r10, r11) are used in this sequence — r12 (callee-saved per System V AMD64 ABI) is never touched, so no push/pop is required.

### M.2 Finding and cross-reference

The register-hazard-crossing move `mov r11, rsi` is annotated in design/audit/entries/r12-m1-002-dispatch-arch.md §2 (register-hazard analysis). This ensures traceability and allows future reviewers to understand where each hazard crossing occurs in the dispatch sequence.

**Finding (M)**: OK — Descriptor-read pattern pinned (24-byte descriptor; 3×u64 reads at offsets 0, 8, 16 via slot*24 arithmetic). Handler ABI established (RDI=rights, RSI=target_ptr, RDX=op_arg via r11). Register-hazard-crossing annotation in place for m2-001 audit (`mov r11, rsi`). All scratch registers are caller-saved (r8, r9, r10, r11); r12 is never used, so no callee-saved register is clobbered. No blocking concerns.

---

## Section N — Return-code convention

**Preamble**: Each handler returns a u64 sentinel value indicating the outcome: success (operation-specific), denial (rights failed), or unsupported operation. This section pins the sentinel values and their ranges.

### N — Pin statement (two new sentinels + kind-specific success values)

**High-sentinel range** (0xFFFFFFFFFFFFFFFF down to 0xFFFFFFFFFFFFFFF0):

| Sentinel name | Hex value | Meaning | Milestone |
|---|---|---|---|
| INVOKE_RESULT_INVALID_HANDLE | 0xFFFFFFFFFFFFFFFE | Invalid cap slot (R8 MVP) | R8 |
| **INVOKE_DENIED** | **0xFFFFFFFFFFFFFFFD** | Rights check failed | **R12-m1-002** |
| **INVOKE_UNSUPPORTED** | **0xFFFFFFFFFFFFFFFC** | Operation not implemented for kind | **R12-m1-002** |

All three are "high sentinels" (top 3 bits set in the u64 value), distinguishing them from normal operation results (which fit in lower bits).

### N.1 Kind-specific success values

For each (kind, op) pair that succeeds, the handler returns a kind-specific value:

| Kind | Op | Op name | Success return value (R12) | Meaning |
|---|---|---|---|---|
| KIND_PAGE (4) | 1 | OP_READ | 0x0000000000000001 | Read completed; 1 page copied |
| KIND_PAGE (4) | 2 | OP_WRITE | 0x0000000000000002 | Write completed; 2 pages modified |
| KIND_IPC_ENDPOINT (5) | 3 | OP_SEND | 0x0000000000000003 | Message sent; 3 words enqueued |
| KIND_IPC_ENDPOINT (5) | 4 | OP_RECV | 0x0000000000000004 | Message received; 4 words dequeued |
| KIND_SCHED_CTX (7) | 5 | OP_YIELD | 0x0000000000000005 | Yield succeeded; 5 = priority-level |
| KIND_DEVICE (10) | 6 | OP_MAP_MMIO | 0x0000000000000006 | MMIO region mapped; 6 = region ID |

These values are arbitrary but chosen to match their op_code for clarity (return value often equals op_code when operation succeeds).

### N.2 Rationale (3 points)

1. **High-sentinel range avoids collision.** Using 0xFFFFFFFFFFFFFFFD and 0xFFFFFFFFFFFFFFFC ensures that legitimate operation results (positive integers, pointer values) never alias sentinel values. No handler should legitimately return 0xFFFFFFFFFFFFFFFE–0xFFFFFFFFFFFFFFFF; those values are reserved.

2. **KIND_DEVICE ambiguity flagged.** For KIND_DEVICE, OP_MAP_MMIO, the success return value (0x06) is arbitrary. Future operations on KIND_DEVICE may need to distinguish "region 0x06" from "region 0x07", at which point the return-value encoding may need revision. For R12, a single OP_MAP_MMIO is sufficient; R13+ can extend if needed. This ambiguity is flagged here for transparency.

3. **Default fallthrough preserves R8 cap_smoke.** If an unknown op_code is encountered, the dispatcher falls through and returns INVOKE_UNSUPPORTED. R8's cap_smoke test (which invokes only valid operations) continues to pass because valid operations return success sentinels (not INVOKE_UNSUPPORTED).

### N.3 Rejected: single-error-sentinel

**Why not use a single error sentinel (e.g., INVOKE_ERROR = 0xFFFFFFFFFFFFFFFD)?**

If all errors (denied, unsupported, invalid-handle) returned the same sentinel, the caller would not know which error occurred. By using three distinct sentinels, the caller can distinguish:
- 0xFFFFFFFFFFFFFFFE (INVOKE_RESULT_INVALID_HANDLE) → slot out of range
- 0xFFFFFFFFFFFFFFFD (INVOKE_DENIED) → rights check failed
- 0xFFFFFFFFFFFFFFFC (INVOKE_UNSUPPORTED) → op not implemented

R12 pins three distinct sentinels. Future error recovery (R13+) may encode error details in lower bits (e.g., 0xFFFFFFFFFFFFFFD0 | error_code), but that is deferred.

**Finding (N)**: OK — Return-code convention pinned. Three high sentinels (INVOKE_RESULT_INVALID_HANDLE, INVOKE_DENIED, INVOKE_UNSUPPORTED). Six (kind, op) → success-value entries. Default fallthrough returns INVOKE_UNSUPPORTED, preserving R8 regression. KIND_DEVICE ambiguity documented for R13+ review.

---

## Section O — COM1 tag discipline

**Preamble**: Each handler emits a human-readable tag string to COM1 UART as the first substantive action after operation decode. This section pins the tag-emission point, the six tag strings, and confirms the E.2 byte-length errata.

### O — Pin statement (tag-emission point, strings, and errata)

**Tag-emission point (timing)**: Immediately after decoding op_code and **before** performing the rights-check.

**Why?** If rights-check fails, the tag "CAP DENIED" is emitted (clearly indicating which operation was denied). If op is unsupported, "CAP UNSUPPORTED" is emitted. This ordering ensures diagnostic clarity: every cap_invoke attempt produces output, even failed ones.

**Six tag strings** (from tags.pdx, m1-002):

| String symbol | Hex value (with NUL) | Byte length (NUL-inclusive) |
|---|---|---|
| cap_mem_msg | "CAP INVOKE MEM\n\0" | 16 |
| cap_ipc_msg | "CAP INVOKE IPC\n\0" | 16 |
| cap_sched_msg | "CAP INVOKE SCHED\n\0" | 18 |
| cap_dev_msg | "CAP INVOKE DEV\n\0" | 16 |
| cap_dispatch_ok_msg | "CAP DISPATCH OK\n\0" | 17 |
| cap_denied_msg | "CAP DENIED\n\0" | 12 |

Each handler loads its corresponding symbol via `lea rax, [rip + cap_mem_msg]` and calls `uart_puts(rax)`.

### O.1 Byte-length errata note (§E.2 correction)

**Issue discovered in m1-001 review**: The original byte counts in §E.2 (sections A–J, issue #404) were calculated without the NUL terminator. The `uart_puts` function (uart.pdx) walks bytes until encountering `\0`; omitting NUL runs off-buffer.

**Correction (landing with m1-002)**:

Original (wrong):
```
pub let cap_mem_msg : [u8; 15] = "CAP INVOKE MEM\n"
pub let cap_ipc_msg : [u8; 15] = "CAP INVOKE IPC\n"
pub let cap_sched_msg : [u8; 17] = "CAP INVOKE SCHED\n"
pub let cap_dev_msg : [u8; 15] = "CAP INVOKE DEV\n"
pub let cap_dispatch_ok_msg : [u8; 17] = "CAP DISPATCH OK\n"
pub let cap_denied_msg : [u8; 12] = "CAP DENIED\n"
```

Corrected (with NUL and updated byte counts):
```
pub let cap_mem_msg : [u8; 16] = "CAP INVOKE MEM\n\0"
pub let cap_ipc_msg : [u8; 16] = "CAP INVOKE IPC\n\0"
pub let cap_sched_msg : [u8; 18] = "CAP INVOKE SCHED\n\0"
pub let cap_dev_msg : [u8; 16] = "CAP INVOKE DEV\n\0"
pub let cap_dispatch_ok_msg : [u8; 17] = "CAP DISPATCH OK\n\0"
pub let cap_denied_msg : [u8; 12] = "CAP DENIED\n\0"
```

Byte-count array (for reference): [16, 16, 18, 16, 17, 12].

### O.2 Rationale (3 points)

1. **Diagnostic completeness.** Tag emission before rights-check ensures that every cap_invoke attempt is logged (including failures). Boot-time fingerprints (verification in R12-m5) include these tags, making test execution auditable.

2. **Lazy evaluation safety.** Tags are emitted before any heavy operation (rights-check, memory access). If a handler encounters a fault (e.g., invalid descriptor pointer), the tag has already been safely written to COM1, providing a last-breath diagnostic.

3. **NUL-termination correctness.** uart_puts expects zero-terminated strings. Including NUL in the byte array ensures correctness and safety; omitting NUL causes buffer overrun (and random output until a zero byte is found in memory).

### O.3 Alternative rejected (strings in boot_stub.S)

**Why not store tag strings in boot_stub.S (like R8–R11 banner messages)?**

R8–R11 pattern for banner strings:
```asm
# R10-m4-002: Task A entry message
.global _task_a_msg
.align 8
_task_a_msg:
    .ascii "TASK A\n\0"
```

This works for static boot-time messages (banner, task entry). However, for R12, tag strings are emitted from *multiple independent handler modules* (kind_page.pdx, kind_ipc.pdx, etc.). Storing all six tags in boot_stub.S would:
1. Centralize handler state in a boot-only file (violates MECE invariant).
2. Require extern linkage from each handler module to boot_stub.S (cross-module coupling).
3. Make handler code less self-contained.

**Decision (PA10-002 precedent)**: R12 stores tags in tags.pdx (a capability-system module file), not boot_stub.S. This preserves the per-kind module boundary (MECE) and keeps handler-related state in the handler-system code. PA10-002 (issue #386) established that capability-system strings live in capability-system modules; boot_stub.S is reserved for boot-sequence diagnostics only.

(Note: this design decision supersedes any earlier plan that mentioned boot_stub.S. PA10-002 CHANGELOG entry confirms the tags.pdx approach as shipped for R11; R12 reuses the same pattern.)

**Finding (O)**: OK — Tag-emission point pinned (immediately after op-code decode, before rights-check). Six tag strings defined with NUL-inclusive byte counts [16, 16, 18, 16, 17, 12]. Byte-length errata (§E.2) corrected and documented. Strings localized to tags.pdx per MECE and PA10-002 precedent. Boot_stub.S alternative considered and rejected.

---

## Section H* — Extended acceptance criteria (m1-002 dispatch architecture)

Expansion of §H to reflect m1-001 and m1-002:

- [ ] `design/milestones/r12-preflight.md` complete with sections A–O (preflight + dispatch pin).
- [ ] Section K (A1 direct-branch dispatch) pins four-way cmp/je pattern and rationale.
- [ ] Section L (B1 per-handler rights-check) pins placement and duplication bounds.
- [ ] Section M (descriptor-read pattern) documents three u64 reads and register-hazard crossing (first hazard-crossing move annotated).
- [ ] Section N (return-code convention) establishes three high sentinels and six kind-specific success values.
- [ ] Section O (COM1 tag discipline) defines six tag strings with NUL-inclusive byte counts; errata (§E.2) corrected.
- [ ] `src/kernel/core/cap/tags.pdx` created with six `pub let` symbols matching section O spec.
- [ ] `design/audit/entries/r12-m1-002-dispatch-arch.md` created with 10 sections, register-hazard annotation, and traceability.
- [ ] No paideia-as escalation blocks m1-002.
- [ ] Smoke tests pass: `boot_r8_only`, `boot_r10`, `boot_r11` (regression verification).

---

## Section I* — Cross-references extension (m1-002)

Expansion of §I to include m1-002 references:

- **Issues**: #404 (r12-m1-001), **#405 (r12-m1-002)**
- **Round plan**: `.plans/r12-round-osarch-plan.md` §§2.1 (encoder verification), 2.4 (op_arg encoding), 2.5 (kind-name mapping), 3 (dispatch-architecture), 4 (acceptance criteria, m1-001 and m1-002)
- **Audit trail**: `design/audit/entries/r12-m1-002-dispatch-arch.md` (register hazards, return-code convention, tag discipline)
- **Design references** (additions):
  - `design/audit/entries/r11-m3-001-sched-save-frame.md` (register-hazard precedent and verification discipline)
- **Source files** (additions):
  - `src/kernel/core/cap/tags.pdx` (tag string constants, m1-002)
- **Related milestones**:
  - R12-m2-001, m2-002: Kind-branching skeleton + per-kind dispatch (issue #405)
  - R12-m3-001, m3-002: MEM + SCHED handlers (issues #406–#407)
  - R12-m4-001, m4-002: IPC + DEV handlers (issues #408–#409)
  - R12-m5-001 through m5-003: Smoke + fingerprint + regression (issues #410–#412)

---

## Section P — Extended trailer (prepared 2026-07-02 for #404+#405)

**Prepared**: 2026-07-02  
**Issue**: #404 (r12-m1-001) + **#405 (r12-m1-002)**  
**paideia-os SHA**: (to be filled on commit)  
**paideia-as pin**: 43d62f9 (v0.11.0+19)  
**Document Status**: Ready for m2-001/m2-002 (kind-branching skeleton + per-kind dispatch).
