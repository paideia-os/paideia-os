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
pub let cap_mem_msg : [u8; 15] = "CAP INVOKE MEM\n"
pub let cap_ipc_msg : [u8; 15] = "CAP INVOKE IPC\n"
pub let cap_sched_msg : [u8; 17] = "CAP INVOKE SCHED\n"
pub let cap_dev_msg : [u8; 15] = "CAP INVOKE DEV\n"
pub let cap_dispatch_ok_msg : [u8; 17] = "CAP DISPATCH OK\n"
pub let cap_denied_msg : [u8; 12] = "CAP DENIED\n"
```

Each handler emits its tag by loading the symbol address and calling `uart_puts(tag_addr)`.

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
**Document Status**: Ready for implementation with m1-002 (dispatch architecture pin, tags.pdx, audit entries)
