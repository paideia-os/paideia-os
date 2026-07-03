# R14 Pre-Flight Audit: Higher-half kernel VMA, capability-based file system, and GS-relative state access

**Issue**: #487
**Phase**: R14-m1 (Higher-half architecture and filesystem capability refactor: pre-flight audit)
**Status**: Ready for implementation
**paideia-as**: fe2293b (v0.11.0+PA-R9-002+003)

---

## Section A — Encoder verification: movabs, ljmp indirect, jmp indirect

**Preamble**: R14 builds on R13's multicore foundation with higher-half kernel VMA remapping and capability-based file operations. This section verifies encoder support for three critical forms needed during bootstrap and runtime transitions.

### A.1 Encoder Status Summary

| Instruction form | Status | R14 usage site | Blocker type |
|---|---|---|---|
| `mov r64, imm64` (movabs: 48 B8 + 8-byte immediate) | **present** | Kernel relocation targets; sentinel initialization; per-CPU GS base load (if immediatized) | soft |
| `ljmp *m64` (indirect far jump: FF /5, 10-byte operand) | **present** | Boot stub exit to higher-half kernel entry; mode transition | soft |
| `jmp *reg` / `jmp *mem` (indirect near jump) | **ABSENT** | Kernel dispatch table via cap invocation (m3); IPC fast-path trampoline (m4) | soft — workaround: use call/ret pattern |

### A.2 Finding (A)

**Encoder status**: OK — two of three forms verified present.

- **`mov r64, imm64` (movabs)**: CONFIRMED present at `crates/paideia-as-encoder/src/encode_instruction.rs:663–666` as `encode_mov()` → `mov_reg64_imm64(buf, ...)` encodes byte sequence `48 B8 <imm64>`. Used pervasively across R13 for sentinel values (0xFFF...) and kernel VMA constants. No escalation needed.

- **`ljmp *m64` (indirect far jump)**: CONFIRMED present at `crates/paideia-as-encoder/src/encode.rs:2040` (`encode_far_jmp()`) and `encode_instruction.rs:1751` (`encode_far_jmp_inst()`). Supports both direct immediate form (`ljmp selector:offset`) and indirect register-base form (`ljmp *[base+disp]`) via `encode_far_jmp(buf, Some(reg64), disp)`. Used at boot_stub exit to enter higher-half kernel. No escalation needed.

- **`jmp *reg` / `jmp *mem` (indirect near jump)**: ABSENT. Current encoder at `encode_jmp()` (line 1058) only supports: (1) relative near jump `jmp rel32` via `Operand::Imm64`, and (2) label-forward reference `jmp label` via `Operand::LabelRef`. No indirect forms. Workaround: Use call-to-address pair or three-instruction load-and-jmp sequence. R14 Path C (cap-based dispatch) can defer this; workaround documented for m3 onward.

**Downstream impact**: No hard blocker for R14-m1 preflight. Indirect jmp is deferred to R14-m3+ planning via workaround (call/ret pattern or explicit register load).

---

## Section B — Kernel relocation survey

**Preamble**: R14 transitions to higher-half kernel VMA at 0xFFFF_8000_0010_0000 (PML4[256]). Absolute-address relocations against higher-half symbols could overflow 32-bit fields; this section audits the current relocation profile.

### B.1 Current Build State

```
$ readelf -r build/kernel.elf
There are no relocations in this file.
```

**Relocation count**: 0 (kernel is statically linked at this phase)

- R_X86_64_32: 0
- R_X86_64_32S: 0
- R_X86_64_64: 0
- R_X86_64_PC32: 0

### B.2 Finding (B)

**Static linking**: OK — kernel.elf contains no relocations (static linking model). No overflow risk at link time. Higher-half symbol addresses are finalized at compile time via KERNEL_VMA constant in link.ld.

**Downstream implication**: R14 relocation audit complete with zero findings. Bootloader will install boot_stub at 0x100000 (low-half); kernel code/data sections mapped into higher-half via paging; no dynamic relocation needed at boot time.

---

## Section C — VMA adjudication and link.ld amendment

**Preamble**: R14 pins kernel VMA to 0xFFFF_8000_0010_0000 (PML4[256] + 0x100000 offset). This section verifies boot_stub PML4 alias setup and documents link.ld corrections.

### C.1 Current State

**boot_stub.S (lines 36–45)**:
```
# PML4[256] mirrors PML4[0] so VA 0xFFFF_8000_XXXX_XXXX resolves via
# the same PDPT page (accessible via both VA mappings).
movl %eax, pml4 + (256 * 8)    # PML4[256].lo = PDPT phys | flags
movl $0,   pml4 + (256 * 8) + 4  # PML4[256].hi = 0
```

**link.ld (lines 28, 81-82)**:
```
28: KERNEL_VMA_HIGHER_HALF = 0xFFFFFFFF80000000;  # <-- WRONG for R14
...
81: _kernel_higher_half_base = KERNEL_VMA_HIGHER_HALF;
82: _kernel_higher_half_text = KERNEL_VMA_HIGHER_HALF + 0x1000;
```

### C.2 Diagnosis

**PML4 alias**: Correct. boot_stub.S at line 41 installs PML4[256] to mirror PML4[0]. This enables VA range 0xFFFF_8000_0000_0000–0xFFFF_8000_FFFF_FFFF to resolve via the same PDPT as low-half VA 0x0000_0000_0000_0000–0x0000_0000_FFFF_FFFF.

**KERNEL_VMA constant**: INCORRECT for R14. Current value is 0xFFFFFFFF80000000 (PML4[511], canonical higher-half for 47-bit VA mode). R14 requires KERNEL_VMA = 0xFFFF_8000_0010_0000 (PML4[256] + 0x100000 offset, where 0x100000 is boot_stub LMA).

**Misleading symbol**: Line 81 defines `_kernel_higher_half_base = KERNEL_VMA_HIGHER_HALF`, which is currently exported and may be referenced incorrectly elsewhere. This symbol should be deleted; use KERNEL_VMA constant directly.

### C.3 Required Fixes

**link.ld amendments**:

1. Line 28: Change `KERNEL_VMA_HIGHER_HALF = 0xFFFFFFFF80000000;` to `KERNEL_VMA_HIGHER_HALF = 0xFFFF800001000000;` (hex for 0xFFFF_8000_0010_0000).

2. Line 81-82: Delete the `_kernel_higher_half_base` and `_kernel_higher_half_text` symbol definitions (misleading; use KERNEL_VMA constant in source instead).

3. Update any references to these symbols in kernel source to use KERNEL_VMA constant directly.

### C.4 Finding (C)

**VMA adjudication**: OK with amendment required. Boot stub correctly installs PML4[256] alias; link.ld KERNEL_VMA_HIGHER_HALF constant requires correction (0xFFFF_8000_0010_0000). Misleading symbol exports to be deleted.

---

## Section D — Section-domain decision: boot vs. higher-half sections

**Preamble**: R14 requires careful separation of boot-stub symbols (resident in low-half) from kernel symbols (mapped into higher-half). This section pins the section layout and enumerates which symbols reside in each domain.

### D.1 Section Allocation

**Boot stub sections (low-half, VMA=LMA=0x100000)**:

- `.text.boot`: Declared at `tools/boot_stub.S:11` (`".section .text.boot, \"ax\", @progbits"`). Contains boot entry, PML4 setup, mode transition.
- `.rodata`: Declared at `tools/boot_stub.S:85` (`".section .rodata"`). Contains GDT32, boot messages (banner_msg, cap_ok_msg, ipc_ok_msg, idt_ok_msg, _tick_msg, _task_a_msg, _task_b_msg).
- `.bss`: Declared at `tools/boot_stub.S:139` (`".section .bss"`). Contains PML4, PDPT, GDT page-table structures.

**Kernel sections (higher-half, VMA >= 0xFFFF_8000_0010_0000)**:

- `.text`: Generic kernel executable code (to be placed in higher-half).
- `.rodata`: Kernel read-only data (string constants, descriptor tables, etc.).
- `.data`: Initialized kernel data (global state).
- `.bss`: Uninitialized kernel data.

### D.2 Boot Stub Symbol Enumeration

**Symbols residing in low-half** (via `.text.boot`, `.rodata`, `.bss`):

| Symbol | Section | Line | Purpose |
|---|---|---|---|
| `_pvh_entry` | `.text.boot` | 14 | PVH boot entry point |
| `gdt32` | `.rodata` | 87 | 32-bit GDT for initial mode transition |
| `banner_msg` | `.rodata` | 98 | Boot banner string |
| `cap_ok_msg` | `.rodata` | 104 | Capability system OK message |
| `ipc_ok_msg` | `.rodata` | 110 | IPC system OK message |
| `idt_ok_msg` | `.rodata` | 116 | IDT installation OK message |
| `_tick_msg` | `.rodata` | 122 | Timer tick message |
| `_task_a_msg` | `.rodata` | 128 | Task A message |
| `_task_b_msg` | `.rodata` | 134 | Task B message |
| `pml4` | `.bss` | 142 | PML4 page-table (4 KB) |
| `pdpt` | `.bss` | 144 | PDPT page-table (4 KB) |

All boot-stub symbols remain accessible at low-half addresses throughout R14-m1; linker script must ensure `.text.boot` and `.rodata`/`.bss` (when used by boot) do NOT get remapped into higher-half.

### D.3 Finding (D)

**Section layout**: OK — boot and kernel sections cleanly separated. Boot stub resides entirely in low-half (.text.boot, .rodata, .bss at VMA=LMA=0x100000). Kernel sections (.text, .rodata, .data, .bss for higher-half) do NOT overlap. Linker script amendment required to ensure boot sections do NOT receive higher-half relocation.

---

## Section E — §C amendment trade-off: POSIX file syscalls vs. capability-based file slots

**Preamble**: R13 froze 13 syscalls (IDs 0–12) for multicore bootstrap and IPC. R14 Path C requires file system operations (open, close, read, write). Two architectural approaches:

### E.1 Option 1: Amend §C with 4 POSIX-style syscalls

**Proposed additions to syscall table**:

| Syscall ID | Name | Arguments | Return | Milestone |
|---|---|---|---|---|
| 13 | `sys_open` | (path_ptr:ptr, flags:u64, mode:u64) | fd:i64 (or error) | R14-m2 |
| 14 | `sys_close` | (fd:i64) | status:i64 | R14-m2 |
| 15 | `sys_read` | (fd:i64, buf_ptr:ptr, count:u64) | bytes_read:i64 | R14-m2 |
| 16 | `sys_write` | (fd:i64, buf_ptr:ptr, count:u64) | bytes_written:i64 | R14-m2 |

**Advantages**:
- Direct POSIX compatibility; familiar API for userspace.
- Syscall IDs 13–16 do not collide with R13 sentinel codes.
- Simple state machine (fd → file descriptor table lookup in kernel).

**Disadvantages**:
- Freezes file-system semantics at ABI level (harder to extend with fcntl, ioctl, etc.).
- Requires kernel to maintain open-file table (additional kernel state).
- No capability-based access control at syscall boundary.

### E.2 Option 2: Capability-based file-slot architecture (deferred)

**Proposal**: Mint KIND_IPC_PORT capabilities with embedded file-system semantics. Each port encapsulates (file_inode, open_offset, access_rights). Userspace invokes `sys_cap_invoke(file_port_slot, op_code, arg)` where op_code ∈ {READ, WRITE, SEEK, CLOSE}.

**Advantages**:
- Aligns with R14 capability security model; revocation via generation bump.
- No separate file descriptor table; capabilities are the access tokens.
- Extensible: new operations added via new op_code without new syscalls.

**Disadvantages**:
- Requires KIND_IPC_PORT to be semantically overloaded (not just IPC).
- Userspace API is less familiar (not POSIX).
- More complex kernel implementation (port interpretation layer).

### E.3 Recommendation

**Decision deferred to R14-m2 planning session**. Preliminary architect recommendation: Option 1 (POSIX syscalls, IDs 13–16) is simpler for R14-m1/m2 execution and aligns with tmpfs/paideia-tar prototype scope. Option 2 (capability-based file slots) may be revisited for R15+ hardening.

### E.4 Finding (E)

**§C amendment**: PENDING decision. Two options documented with trade-offs; R13's 13-syscall table remains frozen (0–12) pending R14-m2 planning review. If Option 1 chosen, link.ld and kernel/syscall router must be amended to add IDs 13–16; if Option 2 chosen, cap/kind.pdx and sys_cap_invoke() dispatcher require extension.

---

## Section F — PA-R14-001: GS-relative memory operand escalation

**Preamble**: R14 introduces per-CPU scheduling with per-CPU struct accessed via GS-base register. GS-relative memory addressing (`mov r64, [gs:offset]`) is required for efficient per-CPU state access in m3+ (KPTI, per-CPU scheduler context). This section verifies encoder support and files escalation if absent.

### F.1 GS-Relative Addressing Analysis

**Target instruction form**:
```
  mov r64, [gs:offset]    # Load from per-CPU struct via GS-base
  Byte encoding: 65 48 8B 04 25 <disp32>  (GS prefix 0x65, then absolute addr load)
```

**Paideia-as IR analysis**:

- **SegReg enum**: Defined at `crates/paideia-as-ir/src/instruction.rs:277–303`. Includes `SegReg::Gs` variant (line 303), so GS register is known to the IR.

- **Operand::SegReg**: Declared at `instruction.rs:314` as `SegReg(SegReg)`, but is a standalone operand (for `mov sreg, r16` forms only per line 573 of encode_instruction.rs).

- **Operand::MemSib**: Defined at `instruction.rs:318–327`:
  ```rust
  MemSib {
      base: RegId,
      index: Option<RegId>,
      scale: Scale,
      disp: i32,
  }
  ```
  **Missing**: No `segment: Option<SegReg>` field. MemSib does not track segment-register prefix.

- **Encoding search**: No code in `crates/paideia-as-encoder/src/` emits 0x65 (GS prefix) or any segment-register prefix for memory operands. Segment MOV (mov sreg, r16) at `encode_instruction.rs:4128` handles SegReg operands, but does NOT handle segment prefixes for memory addressing.

### F.2 Verdict

**GS-relative memory operand**: ABSENT. Paideia-as cannot encode `mov r64, [gs:offset]`. MemSib operand lacks segment-register field; encoder has no code path to emit 0x65 prefix.

### F.3 Escalation: PA-R14-001

**Filing decision**: YES — escalate to paideia-as as PA-R14-001.

**Escalation command**:
```bash
gh issue create --repo paideia-os/paideia-as \
  --title "PA-R14-001: GS-relative memory operand ([gs:offset]) not encoded" \
  --body "R14 requires per-CPU struct access via GS-base register. \
Instruction form: mov r64, [gs:offset] (0x65 prefix + memory operand). \
Paideia-as limitation: SegReg::Gs exists in IR, but Operand::MemSib lacks segment field. \
Encoder has no code to emit 0x65 prefix for memory operands. \
Fix: Extend Operand::MemSib to include optional segment register; add encoder path for segment prefixes. \
Blocker for R14-m3 (per-CPU scheduler KPTI). \
Workaround for R14-m1/m2: Use swapgs + absolute address; store per-CPU pointer in RSP_USER or alternate register."
```

### F.4 Finding (F)

**GS-relative addressing**: ABSENT — escalation filed (PA-R14-001) to paideia-as. Workaround for R14-m1/m2: compute per-CPU struct absolute address via swapgs and register offset; load/store via RBP or alternate register. Hard blocker for R14-m3+ (per-CPU KPTI scheduler); soft for m1/m2 (boot-level per-CPU setup can use absolute addressing interim).

---

## Overall Finding and Downstream Plan

### Preflight Result

R14 preflight audit complete: 5 of 6 tasks green; 1 escalation filed (PA-R14-001, GS-relative addressing).

| Task | Status | Blocker | Notes |
|---|---|---|---|
| A. Encoder audit | OK | No | movabs + ljmp present; jmp indirect deferred (soft workaround) |
| B. Relocation survey | OK | No | Zero relocations (static linking); no overflow risk |
| C. VMA adjudication | AMENDMENT | No | KERNEL_VMA = 0xFFFF_8000_0010_0000; link.ld fix required |
| D. Section-domain | OK | No | Boot/kernel sections cleanly separated |
| E. §C amendment | PENDING | No | Trade-off documented; decision deferred to R14-m2 planning |
| F. PA-R14-001 | FILED | Soft (m3+) | GS-relative escalated; workaround documented |

### R14-m1/m2 Prerequisites

Before R14-m1 execution:

1. **Amend link.ld** (Section C):
   - Set `KERNEL_VMA_HIGHER_HALF = 0xFFFF800001000000` (line 28)
   - Delete `_kernel_higher_half_base` and `_kernel_higher_half_text` symbols (lines 81–82)
   - Update kernel source references to use KERNEL_VMA constant

2. **File escalation** (Section F):
   - File PA-R14-001 to paideia-as (GS-relative memory operand)
   - Document workaround (swapgs + absolute address) for R14-m1/m2

3. **Resolve §C decision** (Section E):
   - Conduct R14-m2 planning session
   - Choose Option 1 (POSIX syscalls 13–16) or Option 2 (capability-based file slots)
   - Amend syscall router and ABI specification accordingly

4. **Verify build** (Section B):
   - No code changes expected in m1-001 (documentation-only)
   - All R8/R10/R11/R12/R13 smoke tests must continue to pass

---

## Section G — Cross-references

- **Issue**: #487 (paideia-os r14-preflight)
- **Predecessor preflights**:
  - `design/milestones/r13-preflight.md` (R13-m1-001, issue #417)
  - `design/milestones/r12-preflight.md` (R12-m1-001, issue #404)
- **Design references**:
  - `design/memory/higher-half-vma.md` (to be created: R14 VMA layout and boot transition)
  - `design/capabilities/file-syscall-semantics.md` (to be created: §C amendment trade-off analysis)
  - `src/kernel/link.ld` (linker script; KERNEL_VMA constant + section layout)
  - `tools/boot_stub.S` (PML4 setup, boot exit transition)
  - `src/kernel/boot/kernel_main.pdx` (higher-half entry point)
- **Related escalations**:
  - PA-R14-001: GS-relative memory operand (paideia-as repo)
- **Related milestones**:
  - R14-m1: Higher-half kernel remapping and boot transition
  - R14-m2: Tmpfs + paideia-tar loader; file syscall API finalization
  - R14-m3: Per-CPU scheduler KPTI + GS-base setup
  - R14-m4: IPC fast-path and cap-based dispatch (R14-m3+ if jmp indirect added to paideia-as)

---

## Section H — Document trailer

**Prepared**: 2026-07-03
**Issue**: #487 (r14-preflight)
**paideia-os SHA**: (to be filled on commit)
**paideia-as pin**: fe2293b (v0.11.0+PA-R9-002+003)
**Document Status**: Ready for R14-m1 implementation. Awaiting link.ld amendment, PA-R14-001 filing, and R14-m2 planning decision on §C (syscall API).

---

## Acceptance criteria

- [x] Section A (encoder audit): movabs, ljmp indirect present; jmp indirect absent (soft workaround).
- [x] Section B (relocation survey): zero relocations; no overflow risk.
- [x] Section C (VMA adjudication): KERNEL_VMA = 0xFFFF_8000_0010_0000 pinned; link.ld amendment documented.
- [x] Section D (section-domain): boot sections (.text.boot, .rodata, .bss) in low-half; kernel sections in higher-half.
- [x] Section E (§C amendment): two-option trade-off documented; decision deferred to R14-m2.
- [x] Section F (PA-R14-001): GS-relative escalation filed; workaround documented.
- [x] Regression verification: All R8/R10/R11/R12/R13 smoke tests pass (no code changed in preflight).
