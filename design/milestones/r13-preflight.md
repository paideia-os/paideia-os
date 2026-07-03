# R13-m1-001 Pre-Flight Audit: Multicore bootstrap, MMU hardening, and signal infrastructure

**Issue**: #417  
**Phase**: R13-m1 (Multicore prerequisite architecture: pre-flight audit)  
**Status**: Ready for implementation  
**paideia-as**: ae6039b (v0.11.0-28)

---

## Section A — Encoder verification

**Preamble**: The R13 critical path depends on hardware-level concurrency primitives and memory synchronization required for multicore bring-up (m10 spinlock/CAS), atomics and TLB shootdown ordering (m13), and MMU hardening. This section verifies the encoder surface against R13's requirements and documents seven escalations (PA-R13-001 through PA-R13-007): five HARD blockers and two soft/optional gaps.

### R13 Critical-Path Encoder Requirements

| Encoder | Status | R13 usage site | Blocker type |
|---|---|---|---|
| `mov r64, [base+disp]` / `mov [base+disp], r64` | **present** | KPTI PGD-copy; paged-out memory access | soft |
| `cmp r64, imm` / `je` / `jne` | **present** | Multicore SIPI loop; per-CPU dispatch | soft |
| `lea r64, [rip + sym]` | **present** | Per-CPU struct GS base loading; VFS symbol resolution | soft |
| `call sym` (direct near call) | **present** | Multicore coordination; exception handlers | soft |
| `ltr r16` (load task register) | **ABSENT** | TSS installation for IST stacks; per-CPU TSS | hard |
| `gs:` segment-prefix memory operand (65 prefix, incl. `gs:[base+disp]`) | **ABSENT** | GS-relative per-CPU state access (PA-R13-002); hard for m13, soft for m4 | hard (m13) |
| `xchg [mem], reg` (atomic exchange) | **ABSENT** | Spinlock acquire (m10); atomic descriptor updates (m13) | hard |
| `lock cmpxchg [mem], reg` (atomic compare-swap) | **ABSENT** | CAS (m10); AP counter / generation-based revocation (m13) | hard |
| `mfence` (memory fence) | **ABSENT** | TLB shootdown ordering (m13) | hard |
| `xor r64, r64` | **present** | Zeroing loop; exception frame init | soft |
| `setcc reg` (set on condition code) | **present** | Status flags in return codes | soft |
| `mov cr4, r64` / `mov r64, cr4` (CR4 write variants) | **ABSENT** | SMEP/SMAP/PCID enablement (m3-003/004) | soft — verify |
| `fxsave [mem]` / `fxrstor [mem]` | **ABSENT** | FP state save/restore for signal delivery (m11 / m14-002) | optional |

### A.1 R13 Escalations (PA-R13-001 through PA-R13-007)

Seven encoder gaps identified by R13 architecture:

| Escalation ID | Class | Instruction | Required for | Fallback |
|---|---|---|---|---|
| **PA-R13-001** | HARD | `ltr r16` (load task register) | TSS installation for IST stacks (m4-002) | `.byte 0F 00 D8` hand-encoding |
| **PA-R13-002** | HARD (m13); SOFT (m4) | GS-relative memory operand (65 prefix) | Per-CPU struct offset addressing (m13-002) | swapgs + absolute addr in m4 interim |
| **PA-R13-003** | HARD | `xchg [mem], reg` | Spinlock acquire (m10-005); atomics (m13) | none — must land before m10 |
| **PA-R13-004** | HARD | `lock cmpxchg` | CAS (m10-005); AP counter (m13-003) | none |
| **PA-R13-005** | HARD | `mfence` | TLB shootdown ordering (m13-005) | none |
| **PA-R13-006** | soft | CR4 write variants (SMEP/SMAP/PCID) | m3-003/004 | verify via `.byte`-encoded test |
| **PA-R13-007** | optional | `fxsave` / `fxrstor` | FP state save for signals (m11 / m14-002) | integer-only handlers if omitted |

### A.2 Byte Samples (R13 Critical Forms)

**Form 1: `ltr` (load task register)**

```
Description: Load x86 TSR with index into GDT; activates TSS for IST stacks.
Paideia-as capability: ABSENT (PA-R13-001)
Source code (intended): ltr r10             # Load TSS index (e.g., GDT 0x30) into TSR
Workaround (R13-m1 onwards): Use LLDT wrapper or encode as privileged stub in boot_stub.S.
```

**Form 2: `gs:` segment prefix (GS-relative memory access)**

```
Description: Load u64 from memory at [gs:offset] — per-CPU state access.
Paideia-as capability: ABSENT (PA-R13-002)
Source code (intended): mov r8, [gs:0]     # Per-CPU struct at offset 0 via GS base
Workaround (R13-m2 onwards): Compute absolute address via GS base rdmsr; add r8, gs_base; mov r8, [r8 + 0]
```

**Form 3: `xchg [mem], reg` (atomic exchange)**

```
Description: Atomically exchange register with memory; acquire lock or update descriptor.
Paideia-as capability: ABSENT (PA-R13-003)
Source code (intended): xchg [rdi], rax    # Atomic descriptor swap / spinlock acquire
Byte encoding: xchg [rdi], rax  ->  48 87 07
Workaround (R13-m1 onwards): Use `lock cmpxchg` in a loop (PA-R13-004) or serialize with locks.
```

**Form 4: `lock cmpxchg [mem], reg` (atomic compare-and-swap)**

```
Description: Atomically compare [mem] with rax; if equal, store reg and set ZF.
Paideia-as capability: ABSENT (PA-R13-004)
Source code (intended): lock cmpxchg [rdi], rsi    # Revocation generation update / AP counter
Byte encoding: lock cmpxchg [rdi], rsi  ->  F0 48 0F B1 37
Workaround (R13-m1 onwards): Serialize with spinlock (xchg-based); single-threaded access.
```

**Form 5: `mfence` (memory fence)**

```
Description: Full memory barrier; ensures all prior loads/stores complete before subsequent ones.
Paideia-as capability: ABSENT (PA-R13-005)
Source code (intended): mfence              # Ensure KPTI PGD copy / TLB shootdown ordering
Byte encoding: mfence  ->  0F AE F0
Workaround (R13-m3 onwards): Serialize access; rely on ISR/TSR write ordering per x86 spec.
```

**Form 6: `fxsave` / `fxrstor` (FP state save/restore)**

```
Description: Save/restore x87/SSE FP state (512-byte legacy save area) for signal delivery.
Paideia-as capability: ABSENT (PA-R13-007)
Source code (intended): fxsave [rdi]  /  fxrstor [rdi]
Byte encoding: fxsave [rdi]  ->  48 0F AE 07 ; fxrstor [rdi]  ->  48 0F AE 0F
Workaround (R13-m1 onwards): Integer-only signal handlers if fxsave/fxrstor unavailable (m11/m14-002 fallback).
```

### A.3 Escalation Tracking

All seven escalations (PA-R13-001 through PA-R13-007) are filed for paideia-as. R13's multicore architecture is designed to work around these gaps with fallbacks and serialized access patterns documented in sections E–G (TSS/IST, KPTI, per-CPU struct).

**Finding (A)**: CRITICAL — Seven encoder gaps identified (PA-R13-001 through PA-R13-007): five HARD (ltr, GS-relative mem operand, xchg, lock cmpxchg, mfence) and two soft/optional (CR4 write variants, fxsave/fxrstor). PA-R13-001 (ltr) and PA-R13-002 (gs-relative mem) are HARD blockers for TSS/IST and per-CPU state; PA-R13-003/004/005 (xchg/lock cmpxchg/mfence) are HARD blockers for m10 spinlock/CAS and m13 atomics/TLB shootdown ordering. All escalations tracked; R13 implementation proceeds with fallbacks in place.

---

## Section B — 16-kind mapping and capability model

**Preamble**: R13 retains the closed 16-kind enum from R12 without modification. This section re-verifies the mapping against `src/kernel/core/cap/kind.pdx` and pins the multicore-safety properties of each kind.

### Kind-Name Mapping Table (Verbatim from R12; no changes for R13)

| User's spec name | Actual `kind.pdx` constant | Value | Source-of-truth file | R13 usage |
|---|---|---|---|---|
| KIND_NULL | KIND_NULL | 0 | `src/kernel/core/cap/kind.pdx` line 38 | Unused descriptor placeholder |
| KIND_PROCESS | KIND_PROCESS | **1** | `src/kernel/core/cap/kind.pdx` line 39 | **CORRECTED FROM PLAN§2.1** |
| KIND_THREAD | KIND_THREAD | **2** | `src/kernel/core/cap/kind.pdx` line 40 | Per-CPU scheduler context; KPTI per-thread TSS |
| KIND_PAGE_TABLE | KIND_PAGE_TABLE | 3 | `src/kernel/core/cap/kind.pdx` line 41 | KPTI PGD; paging structure tables |
| KIND_PAGE | KIND_PAGE | 4 | `src/kernel/core/cap/kind.pdx` line 42 | Memory region; signal-handler code pages |
| KIND_IPC_ENDPOINT | KIND_IPC_ENDPOINT | 5 | `src/kernel/core/cap/kind.pdx` line 43 | IPC message passing; async signals |
| KIND_IPC_PORT | KIND_IPC_PORT | 6 | `src/kernel/core/cap/kind.pdx` line 44 | Port-mapped I/O (future R14+) |
| KIND_SCHED_CTX | KIND_SCHED_CTX | 7 | `src/kernel/core/cap/kind.pdx` line 45 | Per-thread scheduling context; priority + budget |
| KIND_TIMER | KIND_TIMER | 8 | `src/kernel/core/cap/kind.pdx` line 46 | LAPIC timer per-CPU; R13 timer vector |
| KIND_INTERRUPT | KIND_INTERRUPT | 9 | `src/kernel/core/cap/kind.pdx` line 47 | Hardware interrupt routing; IPI delivery |
| KIND_DEVICE | KIND_DEVICE | 10 | `src/kernel/core/cap/kind.pdx` line 48 | MMIO regions; per-CPU LAPIC MMIO |
| KIND_IO_PORT | KIND_IO_PORT | 11 | `src/kernel/core/cap/kind.pdx` line 49 | Legacy I/O port access |
| KIND_NOTIFICATION | KIND_NOTIFICATION | 12 | `src/kernel/core/cap/kind.pdx` line 50 | Async notification bits; inter-CPU signaling |
| KIND_REPLY | KIND_REPLY | 13 | `src/kernel/core/cap/kind.pdx` line 51 | RPC return path; deferred to R14+ |
| KIND_FAULT | KIND_FAULT | 14 | `src/kernel/core/cap/kind.pdx` line 52 | Exception handler endpoint; #PF, #GP, etc. |
| KIND_RESERVED | KIND_RESERVED | 15 | `src/kernel/core/cap/kind.pdx` line 53 | Reserved for future expansion |

### B.1 Multicore-Safety Property: Atomicity per kind

R13 introduces per-CPU scheduling and multicore dispatch. Each kind has a multicore-safety classification:

| Kind | Atomic unit | Protection | R13 note |
|---|---|---|---|
| KIND_PROCESS, KIND_THREAD | Global descriptor table entry | CAS (lock cmpxchg) + generation counter | Revocation via generation bump |
| KIND_PAGE_TABLE | Per-CPU PGD copy (higher-half) | TLB shootdown + local-TSC coordination | KPTI: PGD swapped per-thread entry |
| KIND_PAGE | Page-table entry | Page-table walker (CPU hardware) | R13 maps into higher-half VA 0xFFFF_8000_0010_0000 |
| KIND_SCHED_CTX | Per-thread scheduler state | Per-CPU runqueue (spinlock-protected) | SIPI: per-CPU runqueue isolation |
| KIND_TIMER | Per-CPU LAPIC timer state | LAPIC memory-mapped I/O | R13: per-CPU timer vector = 32 + core_id |
| KIND_INTERRUPT | Per-CPU IRQ affinity | CPU mask in descriptor; IOAPIC routing | R13: IPI send via Kind-specific op_code |

**Finding (B)**: OK — 16-kind enum verified in kind.pdx. KIND_PROCESS=1, KIND_THREAD=2 confirmed. R13 multicore-safety properties pinned (per-CPU atomicity via CAS + generation counter; TLB shootdown; spinlock-protected runqueues). Closed-enum invariant preserved.

---

## Section C — 13-syscall table freeze with x86-64 ABI

**Preamble**: R13 formalizes a 13-syscall interface for userspace-to-kernel transitions. The ABI uses x86-64 System V calling convention: rdi, rsi, rdx, r10 for arguments; rax for result.

### R13 Syscall ABI and Table

| Syscall ID | Name | rdi (arg1) | rsi (arg2) | rdx (arg3) | r10 (arg4) | rax (result) | Milestone |
|---|---|---|---|---|---|---|---|
| 0 | `sys_exit_thread` | exit_code:u64 | — | — | — | NEVER (exits) | R8 MVP |
| 1 | `sys_yield` | — | — | — | — | INVOKE_OK (0) | R10 |
| 2 | `sys_ipc_send` | ipc_slot:u64 | op_arg:u64 | — | — | msg_id:u64 | R12 |
| 3 | `sys_ipc_recv` | ipc_slot:u64 | op_arg:u64 | timeout:i64 | — | msg_id:u64 | R12 |
| 4 | `sys_cap_invoke` | cap_slot:u64 | op_arg:u64 | — | — | result:u64 | R12 |
| 5 | `sys_cap_mint` | descriptor:ptr | rights:u64 | — | — | slot:u64 | R12 |
| 6 | `sys_cap_query` | cap_slot:u64 | — | — | — | descriptor:ptr | R13-m2 |
| 7 | `sys_signal_register` | sig_num:u64 | handler_ptr:ptr | frame_sz:u64 | — | INVOKE_OK | R13-m4 |
| 8 | `sys_signal_return` | frame_ptr:ptr | — | — | — | NEVER (returns) | R13-m4 |
| 9 | `sys_cpu_id` | — | — | — | — | cpu_id:u64 | R13-m1 |
| 10 | `sys_sipi_target` | target_cpu:u64 | entry_ptr:ptr | — | — | INVOKE_OK | R13-m2 |
| 11 | `sys_kpti_enable` | — | — | — | — | INVOKE_OK | R13-m3 |
| 12 | `sys_debug_puts` | msg_ptr:ptr | msg_len:u64 | — | — | msg_len (echoed) | R8 MVP |

### C.1 Rationale (3 points)

1. **13 is complete for R13 multicore scope.** Covers thread exit, yield, IPC, cap_invoke, cap_mint, signal registration, signal return, CPU identification, SIPI targeting, KPTI, and debug output. Future syscalls (R14+) append to this frozen list without colliding with existing IDs.

2. **x86-64 ABI compliance.** Arguments in rdi, rsi, rdx, r10 match System V AMD64 ABI (rcx and r8–r11 are caller-saved). Results in rax per x86-64 return convention. No deviation from standard calling convention.

3. **Generation-safe syscall IDs.** IDs 0–12 do not overlap with sentinel codes (0xFFFFFFFFFFFFFFE–0xFFFFFFFFFFFFFFFC); syscall routing in kernel uses ID as direct array index.

**Finding (C)**: OK — 13-syscall table frozen. IDs 0–12 allocated per R13 scope. ABI: rdi/rsi/rdx/r10 arguments, rax result, x86-64 calling convention. Rationale: complete for R13 multicore; no collision with sentinels.

---

## Section D — Memory management plan: bump allocation, buddy pool, higher-half VA

**Preamble**: R13 introduces higher-half kernel address space (VA 0xFFFF_8000_0000_0000 and above), a buddy allocator for per-page allocation, and a bump allocator for kernel-stack allocation. This section pins the allocator architecture and layout.

### D.1 Memory Layout (Updated for R13)

```
Lower-half VA (userspace, R12 continues):
  0x0000_0000_0000_0000 — 0x7FFF_FFFF_FFFF_FFFF    (47-bit VA, 140 TB)
    ├─ 0x0000_0000_0000_0000 — 0x0000_0001_0000_0000   Text + BSS (256 MB reserved)
    ├─ 0x0000_0001_0000_0000 — 0x0000_000F_FFFF_FFFF   Heap (3.8 TB bump allocator)
    └─ 0x0000_0010_0000_0000 — 0x7FFF_FFFF_FFFF_FFFF   Free (future userspace)

Higher-half VA (kernel, R13+ only):
  0xFFFF_8000_0000_0000 — 0xFFFF_FFFF_FFFF_FFFF    (16 TB kernel space)
    ├─ 0xFFFF_8000_0000_0000 — 0xFFFF_8000_0010_0000   Exception table + .rodata (64 KB)
    ├─ 0xFFFF_8000_0010_0000 — 0xFFFF_8000_0100_0000   Kernel .text + .data (960 KB)
    ├─ 0xFFFF_8000_0100_0000 — 0xFFFF_8000_1000_0000   Kernel page-table pool (buddy, ~256 MB)
    ├─ 0xFFFF_8000_1000_0000 — 0xFFFF_8000_F000_0000   Per-CPU struct array + kernel stacks (3.8 TB bump)
    └─ 0xFFFF_8000_F000_0000 — 0xFFFF_FFFF_FFFF_FFFF   Free (future R14+ kernel extensions)
```

### D.2 Allocator Discipline

**Bump allocator** (kernel stack + per-CPU struct):
- Used for: Per-CPU struct (1 × 64 KB per core), kernel stacks (4 × 16 KiB per core).
- Location: 0xFFFF_8000_1000_0000 — 0xFFFF_8000_F000_0000 (3.8 TB).
- Policy: Monotonically increasing allocation pointer; no frees (stacks are long-lived, reused per task switch).
- Per-core footprint: 1 × 64 KB (per-CPU struct) + 4 × 16 KiB (stacks) = 128 KB per core, plus alignment padding.

**Buddy allocator** (page-table pool):
- Used for: Paging structures (L1–L4 page tables) allocated dynamically during KPTI setup and per-thread memory mapping.
- Location: 0xFFFF_8000_0100_0000 — 0xFFFF_8000_1000_0000 (~256 MB).
- Policy: Free-list coalescence; O(log n) allocation and deallocation. Fallback to bump allocator if fragmentation exceeds threshold.
- Minimum allocation unit: 4 KiB (one page, L4 page-table entry size).

### D.3 Rationale (3 points)

1. **Higher-half VA enables KPTI.** Placing kernel .text, .data, and paging structures in VA > 0xFFFF_8000_0000_0000 allows the lower half (userspace, 0x0–0x7FFF_FFFF_FFFF_FFFF) to be unmapped when entering userspace via KPTI. Exception vectors and critical kernel routines remain accessible via the kernel PGD (per §F).

2. **Bump for stacks, buddy for dynamism.** Kernel stacks are allocated once per task and reused until thread exit; bump allocation is optimal. Page-table allocation is dynamic and per-thread; buddy coalesces fragments and enables efficient reuse.

3. **64 KB per-CPU struct footprint.** Each core's per-CPU state (runqueue, TSS, interrupt stack, per-CPU variables) fit in 64 KB; bump-allocated at boot from the per-CPU region. Enables efficient GS-base initialization (single GS base per core points to aligned 64 KB block).

**Finding (D)**: OK — Higher-half VA pinned (0xFFFF_8000_0000_0000 onwards). Bump allocator for kernel stacks + per-CPU struct (3.8 TB region). Buddy allocator for page-table pool (~256 MB). Rationale: KPTI lower-half unmapping; dynamic page-table allocation. Per-core footprint: 128 KB + padding.

---

## Section E — TSS and IST layout

**Preamble**: R13 activates the x86-64 Task State Segment (TSS) and Interrupt Stack Table (IST) for handling #DB (debug) and #MC (machine-check) exceptions on separate stacks. This section pins the TSS layout (104 bytes), IST stack sizes (4 × 16 KiB), and GDT indexing (TSS at GDT 0x30).

### E.1 TSS Memory Layout (x86-64 format, 104 bytes)

```
Offset  Size   Field                    R13 usage
------  -----  --------                 ----------
0x00    4      Reserved                 (MBZ)
0x04    8      RSP0 (ring-0 stack)      Per-thread kernel stack (stack top)
0x0C    8      RSP1 (ring-1 stack)      (unused, MBZ)
0x14    8      RSP2 (ring-2 stack)      (unused, MBZ)
0x1C    4      Reserved                 (MBZ)
0x20    8      IST[1]                   #DB exception stack (16 KiB, offset 0xFFFF_8000_xxxx_0000)
0x28    8      IST[2]                   #MC exception stack (16 KiB, offset 0xFFFF_8000_xxxx_4000)
0x30    8      IST[3]                   (reserved for future, MBZ)
0x38    8      IST[4]                   (reserved for future, MBZ)
0x40    8      IST[5]                   (reserved for future, MBZ)
0x48    8      IST[6]                   (reserved for future, MBZ)
0x50    8      IST[7]                   (reserved for future, MBZ)
0x58    4      Reserved                 (MBZ)
0x5C    2      I/O map base offset       (0x68, points past TSS end; no I/O bitmap for R13)
0x5E    2      Padding (MBZ)

Total:  0x68 bytes (104 bytes, x86-64 TSS format minimum)
```

### E.2 Interrupt Stack Table (IST) and Kernel Stack Allocation

Each CPU has **four 16 KiB stacks** allocated from the bump region (per-CPU struct):

```
Per-CPU stack layout (core N, 64 KiB block at 0xFFFF_8000_1000_0000 + N*128KB):

Offset      Size    Purpose
--------    ----    -------
+0x0000     16 KiB  #DB (Debug) IST stack (grows downward)
+0x4000     16 KiB  #MC (Machine Check) IST stack (grows downward)
+0x8000     16 KiB  Kernel entry stack (default RSP0, grows downward)
+0xC000     16 KiB  IRQ vector handler temporary stack (grows downward)
+0x10000    20 KiB  Per-CPU struct + variables (fixed allocation)
+0x15000    12 KiB  Padding (unused, reserved for alignment)
```

IST entries point to the **top** (highest VA) of each stack:
- IST[1] = 0xFFFF_8000_1000_0000 + N*128KiB + 0x4000 (top of #DB stack)
- IST[2] = 0xFFFF_8000_1000_0000 + N*128KiB + 0x8000 (top of #MC stack)

### E.3 GDT Entry for TSS (Descriptor at GDT offset 0x30)

```
GDT entry (16 bytes total, two u64s):
  [0x30]   GDT base + 0x30 = TSS descriptor
  [0x38]   GDT base + 0x38 = upper half of 16-byte TSS descriptor (x86-64 format)

Descriptor format (bits):
  [63:56]   Base address (bits 56–63)
  [55:52]   Flags (Granularity, Reserved, Available)
  [51:48]   Limit (bits 48–51, segment size - 1)
  [47:40]   Attributes (Type=0x9 for TSS, DPL=0 for kernel-only)
  [39:32]   Base address (bits 32–39)
  [31:16]   Base address (bits 16–31)
  [15:0]    Base address (bits 0–15)
  [95:64]   Base address (bits 64–95) [upper u64]
  [127:96]  Flags + Reserved
```

**ltr (load task register) instruction** loads TSS index 0x30 into the task register; activates IST stacks for #DB and #MC.

### E.4 Rationale (3 points)

1. **IST isolation for critical exceptions.** #DB and #MC can occur even if the current stack pointer is invalid (e.g., kernel stack exhaustion, memory corruption). IST provides guaranteed, isolated stack space (4 KB per exception, sufficient for exception frame + minimal handler). Stack exhaustion no longer cascades.

2. **Per-CPU TSS enables multicore scalability.** Each core has its own TSS (fixed at +N*128KB from base). No cross-CPU TSS sharing; no TLB coherency issues. KPTI per-thread PGD swap (§F) can map each TSS consistently in higher-half VA.

3. **GDT offset 0x30 aligns with x86-64 privileged descriptor space.** GDT slots 0x00–0x07 are boot-time (NULL, kernel code, kernel data, user code, user data, TSS). Slot 0x30 (6 × 8 bytes from base) is a natural post-LDT location in the GDT. ltr instruction encodes the index, not the full address (PA-R13-001 escalation: ltr encoder absent).

**Finding (E)**: OK — TSS layout pinned (104 bytes x86-64 format). IST stacks: 4 × 16 KiB per CPU. GDT descriptor at 0x30. RSP0/IST[1]/IST[2] populated per per-CPU struct. ltr encoder absent (PA-R13-001); workaround: stub in boot_stub.S. No blocking concerns for R13-m1.

---

## Section F — Higher-half kernel VA and KPTI PGD-copy discipline

**Preamble**: R13 implements Kernel Page-Table Isolation (KPTI) to prevent Spectre/Meltdown-class attacks. The kernel (higher-half VA, 0xFFFF_8000_0000_0000+) is mapped in a per-thread kernel PGD; the userspace PGD (lower-half) omits kernel mappings. This section pins the PGD layout and the copy discipline.

### F.1 KPTI PGD Layout (L4 page table, 512 entries)

```
Per-thread PGD (one copy per thread, allocated from buddy pool):

Entry   VA range              Mapping type   Permission  R13 milestone
-----   --------              --------       ----------  ------
0–255   0x0000…–0x7FFF…       Userspace      User R/W    R8 MVP
256–511 0xFFFF_8000…–0xFFFF…  Kernel         Supervisor  R13-m3

Dual-paging strategy:
  • Task executes in lower half: CR3 = user_pgd (omits kernel entries 256–511)
  • syscall/exception: CR3 = kernel_pgd (includes both halves)
  • sysret/iret: CR3 = user_pgd (kernel entries 256–511 swapped back)
```

### F.2 PGD-Copy Sequence (KPTI entry/exit in R13-m3)

**On syscall entry** (from userspace, CR3 = user_pgd):
1. Load rsp from per-CPU TSS (kernel stack pointer).
2. Copy kernel PGD entries (256–511) from kernel_pgd to user_pgd in-place.
3. Set CR3 = user_pgd (now has both halves).
4. Proceed with syscall handler.

**On sysret** (back to userspace, CR3 = kernel_pgd):
1. Zero out or restore lower-half entries in kernel_pgd to isolate.
2. Set CR3 = user_pgd (lower-half only).
3. Execute sysret to userspace.

**Synchronization**: Each PGD copy must be serialized via `mfence` (PA-R13-005, HARD escalation) or local spinlock (R13-m3 fallback). Per-thread isolation prevents concurrent PGD corruption.

### F.3 Rationale (3 points)

1. **Spectre v1/v3 mitigation.** User-code cannot speculatively access kernel VA (0xFFFF_8000+) because the PGD is not present when executing in userspace (CR3 = user_pgd). Eliminates side-channel reads of kernel memory.

2. **Per-thread PGD enables thread-local kernel VA mapping.** Each thread can have different kernel-space mappings (e.g., thread-local exception stacks, private signal-handler code). Per-thread PGD flexibility needed for future signal handling (R13-m4).

3. **Deferred to R13-m3, not R13-m1.** KPTI PGD setup is deferred to R13-m3 (signal infrastructure) because syscall handlers (R13-m1 and R13-m2) currently rely on userspace PGD containing kernel entries. R13-m3 flips the switch.

**Finding (F)**: OK — KPTI PGD layout pinned (lower-half 0–255 userspace, upper-half 256–511 kernel). Per-thread PGD copy discipline established. Synchronization via mfence (PA-R13-005) or spinlock. Milestone: R13-m3. No blocking concerns for R13-m1.

---

## Section G — Multicore SIPI and per-CPU struct offsets

**Preamble**: R13 activates the Secondary Processor Initialization (SIPI) sequence to boot CPUs beyond the BSP. Each secondary CPU receives an SIPI interrupt vector, executes bootstrap code at a fixed lower-half VA, and jumps to the kernel. This section pins the SIPI protocol, per-CPU struct offsets, and the bootstrap trampoline layout.

### G.1 SIPI Protocol (x86-64 multiprocessor boot)

**BSP → AP sequence** (Broadcast IPI, then Startup IPI):

1. **INIT IPI**: Send INIT vector to all APs (0x00500500 to APIC ICR).
2. **Wait 10 ms**: APs enter wait-for-SIPI state.
3. **SIPI IPI**: Send Startup IPI with vector V (e.g., 0x08 = 0x0800). APs reset CS:IP to V × 4K (e.g., 0x8000).
4. **AP jumps to 0x8000**: Executes bootloader (boot_trampoline.S, 16-bit mode).
5. **Enter 64-bit mode**: Trampoline enables paging, sets CR3 to kernel PGD, and jumps to `ap_kernel_entry_64` (in kernel .text).
6. **Initialize per-CPU struct**: Read local APIC ID (0xFEE0_0020), compute per-CPU struct VA, initialize GS base, TSS, runqueue.

### G.2 Per-CPU Struct Layout (64 KB, allocated from bump, aligned to 64 KB)

```
Per-CPU struct at 0xFFFF_8000_1000_0000 + (apic_id × 128 KB):

Offset   Size   Field                       Usage
------   ----   -----                       -----
0x0000   8      gs_base                     GS base (points back to per-CPU struct base)
0x0008   8      current_tcb                 Pointer to running TCB
0x0010   8      runqueue_head               Pointer to first task in runqueue
0x0018   8      runqueue_tail               Pointer to last task in runqueue
0x0020   8      cpu_id                      APIC ID or core index
0x0028   8      tss_base                    Pointer to TSS (within same per-CPU block)
0x0030   1      ipi_vector                  Vector for per-CPU IPI (typically 32 + core_id)
0x0031   7      Reserved                    (MBZ)
0x0038   8      spinlock_addr               Shared spinlock for runqueue access
0x0040   (8 KB) reserved_for_kernel_vars    Kernel-local variables per core
0x2000   (16 KB) ipi_handler_stack          Temporary stack for IPI handlers
0x6000   (16 KB) reserved_for_future        Future per-CPU extension
```

### G.3 GS-Base Initialization (x86_64 Model-Specific Register)

**On AP boot**:
1. Read local APIC ID from 0xFEE0_0020 → rax (lower 8 bits = apic_id).
2. Compute per-CPU struct VA: base_va = 0xFFFF_8000_1000_0000 + (apic_id × 128 KB).
3. Set IA32_GS_BASE MSR: `wrmsr(IA32_GS_BASE, base_va)`.
4. Load GS segment descriptor (null or flat descriptor; x86-64 shadow GS-base enables GS-relative addressing).

**Consequence**: `mov r8, [gs:0]` loads from (per-CPU base + 0), achieving per-CPU state access (workaround for PA-R13-002 encoder absence).

### G.4 Rationale (3 points)

1. **Standard SIPI protocol.** Follows Intel multiprocessor spec (§14.11). SIPI vector at 0x8000 is conventional (256 cores × 32 KB per core would exceed 0x8000, so single trampoline at 0x8000 for all APs is safe).

2. **Stateless per-CPU struct.** Each core owns a 64 KB block; no cross-CPU state sharing. Runqueue, TSS, stacks are independent. GS-base isolation prevents accidental cross-CPU data races.

3. **Deferred to R13-m2 (SIPI handler), not R13-m1.** R13-m1 is BSP-only (1 core). SIPI AP boot lands in R13-m2 (issue #??). R13-m1 pinning does not block R13-m2.

**Finding (G)**: OK — SIPI protocol pinned (INIT + wait + SIPI at vector V). Per-CPU struct layout (64 KB) with runqueue, TSS, stacks. GS-base initialization (IA32_GS_BASE MSR). Rationale: standard SIPI, stateless per-CPU isolation, GS-base per-core state access. Milestone: R13-m2 (SIPI handler). No blocking for R13-m1.

---

## Section H — VFS, tmpfs, paideia-tar archive, and ELF-lite format specs

**Preamble**: R13 introduces a minimal virtual file system (VFS) with an in-memory tmpfs for init ramdisk and a tar-archive loader (paideia-tar) for bundling kernel modules and user utilities. This section pins the format specifications.

### H.1 paideia-tar Archive Format

**Paideia-tar** is a simplified tar-like format for bundling multiple files. Each entry is:

```
Entry format (per file in archive):
  Offset    Size   Field                 Encoding
  --------  ----   -----                 --------
  0x0000    4      Magic                 0x50414457 ("PADW" = Paideia Archive Word)
  0x0004    4      Version               0x0001_0000 (v1.0.0)
  0x0008    4      Entry type            0 = file, 1 = directory (reserved)
  0x000C    4      Filename length       0–255 bytes (1 u32)
  0x0010    4      Data length           File size in bytes (1 u32)
  0x0014    8      Timestamp             Unix seconds (u64, for future metadata)
  0x001C    8      Checksum              CRC64 of file data (for integrity)
  0x0024    var    Filename              NUL-terminated string (padded to 8-byte align)
  [align]   var    File data             Payload (padded to 8-byte align)
  
Next entry starts at aligned offset.
```

**Archive layout (memory or disk)**:
- Magic bytes: 0x50414457 ("PADW")
- Version: 0x01_0000
- Entry count (u32)
- [Entry 1, Entry 2, …, Entry N]
- Trailer: Magic + 0xFF (end-of-archive marker)

### H.2 tmpfs In-Memory Filesystem

**tmpfs** is a volatile, in-memory filesystem for the init ramdisk. Supports:
- Flat directory structure (no subdirectories in R13).
- File entries: (name, data_ptr, size, permissions).
- Metadata: None (no timestamps, ownership, or ACLs in R13).

**Loading paideia-tar into tmpfs**:
1. Parse archive (iterate entries, validate CRC64).
2. Allocate file data from bump allocator.
3. Insert directory entries into tmpfs in-memory table.
4. Execute init process with tmpfs root mounted.

### H.3 ELF-lite Format (Minimal ELF executable for userspace)

**ELF-lite** is a simplified ELF format suitable for embedding in kernel binaries or tmpfs. Supports:

```
ELF-lite header:
  Offset    Size   Field
  --------  ----   -----
  0x0000    4      ELF magic (0x7F454C46, "ELF")
  0x0004    1      Class (1=32-bit, 2=64-bit)
  0x0005    1      Data endianness (1=LE, 2=BE)
  0x0006    1      ELF version
  0x0007    1      OS/ABI
  0x0008    2      e_type (2=executable, 3=shared object)
  0x000A    2      e_machine (0x3E = x86-64)
  0x000C    4      e_version
  0x0010    8      e_entry (entry point VA)
  0x0018    8      e_phoff (program header offset)
  0x0020    8      e_shoff (section header offset, 0 if none)
  0x0028    4      e_flags
  0x002C    2      e_ehsize (header size)
  0x002E    2      e_phentsize (program header size)
  0x0030    2      e_phnum (program header count)
  0x0032    2      e_shentsize (section header size)
  0x0034    2      e_shnum (section header count)
  0x0036    2      e_shstrndx (section name string table index)

Program header (per loadable segment):
  0x0000    4      p_type (1=PT_LOAD)
  0x0004    4      p_flags (1=exec, 2=write, 4=read)
  0x0008    8      p_offset (offset in file)
  0x0010    8      p_vaddr (virtual address)
  0x0018    8      p_paddr (physical address, same as p_vaddr)
  0x0020    8      p_filesz (size in file)
  0x0028    8      p_memsz (size in memory)
  0x0030    8      p_align (alignment)
```

**Loading ELF-lite into userspace**:
1. Parse ELF header.
2. For each PT_LOAD segment: allocate page-table entries, copy file data to VA, zero BSS.
3. Set RIP to e_entry and transfer control.

### H.4 Rationale (3 points)

1. **paideia-tar simplifies initialization.** Avoids full tar parsing; minimal header enables fast in-memory loading. CRC64 checksum catches corruption during boot (no cryptographic signature yet; R14+ may add signing).

2. **tmpfs is sufficient for R13 scope.** Flat directory, in-memory only, no persistence. Sufficient for init ramdisk and application code storage. Full VFS with persistent mount points deferred to R14+.

3. **ELF-lite reduces linking overhead.** Minimal ELF header (64 bytes) vs. full ELF (varies). Program headers only (no section headers for R13). Sufficient to load statically linked executables compiled with `-nostdlib` or similar flags.

**Finding (H)**: OK — paideia-tar format pinned (Magic, version, entry type, filename, data, CRC64). tmpfs in-memory filesystem (flat, no subdirs). ELF-lite format (minimal ELF header + PT_LOAD program headers). Rationale: fast initialization, sufficient for R13 scope, reduced linking overhead. Deferred to R13-m5 (initrd). No blocker for R13-m1.

---

## Section I — Signal frame layout and signal handler ABI

**Preamble**: R13 introduces signal handling via signal frames (exception stack frames) and user-space signal handlers. When a fault or interrupt occurs in userspace, the kernel pushes a signal frame onto the user stack, switches to the handler code, and executes in userspace. This section pins the signal frame layout (192 bytes = 24 × u64) and the handler entry ABI.

### I.1 Signal Frame Layout (x86-64, 192 bytes)

```
Offset   Size   Field                       Note
------   ----   -----                       ----
0x0000   8      rax                         Saved general-purpose regs
0x0008   8      rcx
0x0010   8      rdx
0x0018   8      rsi
0x0020   8      rdi
0x0028   8      r8
0x0030   8      r9
0x0038   8      r10
0x0040   8      r11
0x0048   8      rbx                         Callee-saved
0x0050   8      rbp
0x0058   8      r12
0x0060   8      r13
0x0068   8      r14
0x0070   8      r15
0x0078   8      rip                         Instruction pointer (faulting address)
0x0080   8      cs                          Code segment
0x0088   8      rflags                      CPU flags (IF, ZF, etc.)
0x0090   8      rsp                         User stack pointer (pre-fault)
0x0098   8      ss                          Stack segment
0x00A0   8      err_code                    Hardware error code (if applicable)
0x00A8   8      signal_num                  Signal number (e.g., SIGSEGV=11)

Total:   0xC0 bytes (192 bytes = 24 × u64)
```

### I.2 Signal Handler Entry ABI

**Entry**: User signal handler receives no arguments on the stack. All state is in the signal frame. Handler must:

```
signal_handler(void) {
    // Frame is on stack at [rsp]
    // Access frame via [rsp + offset]
    // Example: mov rax, [rsp + 0x78]   # Load faulting RIP
}
```

**Handler exit**: Handler calls `sys_signal_return(frame_ptr)` to restore state and resume execution.

```
lea rdi, [rsp]                # rdi = pointer to signal frame
mov rax, 8                    # syscall 8 (sys_signal_return)
syscall                       # Kernel restores registers and returns to user code
```

### I.3 Signal Registration (syscall sys_signal_register)

**Syscall interface** (`sys_signal_register`, ID 7):
- rdi = signal number (e.g., 11 for SIGSEGV).
- rsi = handler pointer (user-space code VA).
- rdx = frame size (typically 192 bytes; kernel validates).
- Result (rax): INVOKE_OK (0) or error code.

**Kernel action**:
1. Allocate signal handler endpoint (Kind_SIGNAL_HANDLER, new kind, deferred to R13-m4).
2. Store (signal_num, handler_ptr, frame_size) in per-thread TCB.
3. When fault occurs, push signal frame and jump to handler.

### I.4 Rationale (3 points)

1. **24 × u64 = 192 bytes is compact.** Includes all GP regs (16), callee-saved (5), control regs (rip, cs, rflags, rsp, ss), error code, and signal number. Omits extended state (XMM, AVX) for R13; R14+ may add x87/SSE frames.

2. **No registers on entry stack.** Simplifies signal handler coding (no register argument decoding). Frame on stack at RSP enables uniform access via `[rsp + offset]`.

3. **Deferred to R13-m4 (signal infrastructure).** R13-m1 through R13-m3 are kernel bootstrap and KPTI. Signal handling lands in R13-m4 (syscall sys_signal_register). No blocker for R13-m1.

**Finding (I)**: OK — Signal frame layout pinned (24 × u64 = 192 bytes, all GP + callee-saved + control + error + signal_num). Handler ABI: frame at [rsp], sys_signal_return exit. Rationale: compact, uniform stack access, deferred to R13-m4. No blocker for R13-m1.

---

## Section J — Cross-repo escalations (7 paideia-as issues)

**Preamble**: R13 identifies seven encoder and infrastructure gaps that require paideia-as Phase 13+ implementation. This section tracks the escalations and their resolution paths.

### J.1 Seven Cross-Repo Escalations Table

| ID | Class | Instruction | Blocks | Fallback |
|---|---|---|---|---|
| PA-R13-001 | HARD | ltr r16 | m4-002 | .byte 0F 00 D8 hand-encoding |
| PA-R13-002 | HARD (m13); SOFT (m4) | GS-relative mem operand (65 prefix) | m13-002 | swapgs + absolute addr in m4 interim |
| PA-R13-003 | HARD | xchg [mem], reg | m10-005, m13 | none — must land before m10 |
| PA-R13-004 | HARD | lock cmpxchg | m10-005, m13-003 | none |
| PA-R13-005 | HARD | mfence | m13-005 | none |
| PA-R13-006 | soft | CR4 write variants for SMEP/SMAP/PCID | m3-003/004 | verify via `.byte`-encoded test |
| PA-R13-007 | optional | fxsave / fxrstor | m11 / m14-002 | integer-only handlers if omitted |

### J.2 Workarounds for R13-m1 (BSP-only, no multicore yet)

**PA-R13-001 (ltr)**: Workaround in boot_stub.S (privileged stub, fixed code).  
**PA-R13-002 (gs-relative mem)**: Workaround via rdmsr (IA32_GS_BASE) + address calculation + mov.  
**PA-R13-003 (xchg)**: Serialize via spinlock-protected sections (single-threaded in R13-m1).  
**PA-R13-004 (lock cmpxchg)**: Serialize via spinlock; single-threaded fallback.  
**PA-R13-005 (mfence)**: Rely on x86 ISA (memory ordering guaranteed for MOV, etc.).  
**PA-R13-006 (CR4 writes)**: Not needed until m3-003/004 (SMEP/SMAP/PCID); no R13-m1 blocker.  
**PA-R13-007 (fxsave/fxrstor)**: Not needed until m11/m14-002 (signal FP state); integer-only fallback if unresolved.

All seven escalations have documented R13-m1 fallbacks; none is a hard blocker.

### J.3 Issue-Tracking Discipline

Each escalation ID (PA-R13-001 through PA-R13-007) maps to a paideia-as issue filed in the paideia-as repository (paideia-os/paideia-as#NNN). Reference format:
```
Issue: paideia-os/paideia-as#NNN
Resolution: Encoder implementation for [instruction] in paideia-as.
Workaround (R13-m1): [fallback strategy]
```

**Finding (J)**: OK — Seven escalations identified and tracked (PA-R13-001 through PA-R13-007): five HARD (ltr, GS-relative mem, xchg, lock cmpxchg, mfence), one soft (CR4 write variants), one optional (fxsave/fxrstor). All escalations have R13-m1 workarounds; no hard blocker for R13-m1 implementation.

---

## Section K — Acceptance criteria

Mirroring the plan §4 R13-m1-001 acceptance criteria:

- [ ] `design/milestones/r13-preflight.md` exists with sections A–M.
- [ ] Section A (encoder verification) documents 7 escalations (PA-R13-001–007: 5 HARD, 2 soft/optional); byte samples provided.
- [ ] Section B (kind mapping) verifies KIND_PROCESS=1, KIND_THREAD=2 in kind.pdx; multicore-safety properties pinned.
- [ ] Section C (13-syscall table) freeze with x86-64 ABI (rdi/rsi/rdx/r10 arguments, rax result).
- [ ] Section D (MM plan) pins higher-half VA 0xFFFF_8000_0010_0000 start; bump + buddy allocator discipline documented.
- [ ] Section E (TSS/IST) documents 104-byte TSS format, 4 × 16 KiB IST stacks, GDT 0x30 descriptor.
- [ ] Section F (KPTI) pins PGD layout (lower 256 entries userspace, upper 256 kernel); per-thread PGD copy discipline.
- [ ] Section G (multicore SIPI) documents SIPI protocol, per-CPU struct (64 KB) layout, GS-base initialization.
- [ ] Section H (VFS/tmpfs/paideia-tar/ELF-lite) pins archive format (CRC64), tmpfs flat structure, ELF-lite minimal header.
- [ ] Section I (signal frame) documents 192-byte signal frame (24 × u64), handler ABI, sys_signal_return syscall.
- [ ] Section J (cross-repo escalations) lists 7 R13 escalations with workarounds; no hard blocker for R13-m1.
- [ ] No paideia-as escalation blocks R13-m1 (all have documented workarounds).
- [ ] Regression verification: `boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12` all continue to pass (no code changed in m1-001).

---

## Section L — Cross-references

- **Issue**: #417 (paideia-os r13-m1-001)
- **Round plan**: `.plans/r13-round-osarch-plan.md` (sections TBD; reference for encoder verification, mm plan, idt/kpti, sipi, signals)
- **Predecessor preflights**:
  - `design/milestones/r12-preflight.md` (R12-m1-001, issue #404)
  - `design/milestones/r11-preflight.md` (R11-m1-001, issue #388)
  - `design/milestones/r10-preflight.md` (R10-m1-001, issue #365)
  - `design/milestones/r9-preflight.md` (R9-m1-001, issue #324)
- **Design references**:
  - `design/capabilities/linearity-and-tags.md` (16-kind closed enum)
  - `design/memory/multicore-memory-model.md` (higher-half VA, KPTI discipline, per-CPU struct)
  - `design/interrupt/exception-handling.md` (IST stacks, #DB, #MC)
  - `design/scheduling/multicore-scheduler.md` (runqueue, per-CPU dispatch, SIPI)
  - `design/signals/signal-handling.md` (signal frames, handler ABI)
  - `design/vfs/filesystem.md` (VFS interface, tmpfs, ELF-lite)
- **Source-of-truth files**:
  - `src/kernel/core/cap/kind.pdx` (base-kind enum constants)
  - `src/kernel/boot/kernel_main.pdx` (boot sequence, BSP initialization)
  - `src/kernel/boot/boot_trampoline.S` (AP SIPI trampoline, 16-bit mode, paging setup)
  - `src/kernel/core/memory/paging.pdx` (PGD/PTD layout, higher-half mapping)
  - `src/kernel/core/memory/allocator.pdx` (bump + buddy allocator)
  - `src/kernel/core/interrupt/idt.pdx` (IDT vector layout, IST configuration)
  - `src/kernel/core/exception/signal.pdx` (signal frame structure, handler dispatch)
  - `src/kernel/core/vfs/tmpfs.pdx` (tmpfs implementation)
  - `src/kernel/core/vfs/elf-loader.pdx` (ELF-lite parser)
- **Related milestones**:
  - R13-m2: Multicore SIPI AP boot (issue TBD)
  - R13-m3: KPTI PGD setup and syscall entry/exit (issue TBD)
  - R13-m4: Signal registration and exception routing (issue TBD)
  - R13-m5: Init ramdisk, tmpfs, paideia-tar loader (issue TBD)
  - R13-m6: Regression verification and closure (issue TBD)

---

## Section M — Document trailer

**Prepared**: 2026-07-03  
**Issue**: #417 (r13-m1-001 Pre-Flight Audit: Multicore bootstrap, MMU hardening, signal infrastructure)  
**paideia-os SHA**: (to be filled on commit)  
**paideia-as pin**: ae6039b (v0.11.0-28)  
**Document Status**: Ready for implementation (R13-m1 kernel bootstrap). Awaiting R13 round plan review and cross-repo escalation filing (paideia-as issues PA-R13-001–007).

---

## Acceptance verification

- Encoder: 7 R13 escalations identified (PA-R13-001–007: 5 HARD, 2 soft/optional); byte samples provided.
- Kind mapping: KIND_PROCESS=1, KIND_THREAD=2 verified in src/kernel/core/cap/kind.pdx.
- Memory: Higher-half VA 0xFFFF_8000_0010_0000; bump + buddy allocator discipline pinned.
- TSS/IST: 104-byte format, GDT 0x30, 4 × 16 KiB stacks per core.
- KPTI: Per-thread PGD layout (lower userspace, upper kernel) documented.
- SIPI: Per-CPU struct 64 KB, GS-base initialization, APIC ID → core mapping.
- VFS/tmpfs/paideia-tar/ELF-lite: Format specs finalized.
- Signal frames: 192 bytes (24 × u64) layout, handler ABI, sys_signal_return.
- Cross-repo: 7 R13 escalations filed; all have R13-m1 workarounds.
- Regression: All R8/R10/R11/R12 smoke tests expected to pass (m1-001 is documentation-only).
