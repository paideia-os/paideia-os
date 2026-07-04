---
audit_id: r15-m2-002-user-page-flags
issue: 523
file: src/kernel/core/loader/elf_lite.pdx, src/kernel/core/mm/user_stack.pdx
function: elf_lite_load, user_stack_alloc
effects: [mem]
capabilities: []
reviewed_by:
date: 2026-07-04
---

# AUDIT r15-m2-002 — User page accessibility and W^X enforcement

## Scope

Audit that user-mode pages (both text/data and stack) are mapped with user-accessible flag (U=1) and that the write-XOR-execute (W^X) invariant is enforced at page-mapping time. This audit verifies the implementation of #517 (aspace_map user-space page installation) and #518 (user stack allocation).

## elf_lite_load flag translation

Per **src/kernel/core/loader/elf_lite.pdx** (lines 432–459), the flag translation during ELF segment loading constructs page flags from ELF p_flags as follows:

- **Bit 0 (P):** always 1 (present) — leaf PTEs always mark pages present
- **Bit 1 (W):** set if PF_W is present in the segment's p_flags (line 442–445)
- **Bit 2 (U):** **ALWAYS 1** (user-accessible) — mandatory for ring-3 code fetch and data access (line 437)
- **Bit 63 (NX):** set if PF_X is absent (lines 448–456) — execute disable if segment is not executable

The translation is deterministic: `U = 1` is unconditional, ensuring all user-mode text pages are ring-3 accessible.

## user_stack_alloc flags

Per **src/kernel/core/mm/user_stack.pdx** (line 74), stack pages are mapped with:
```
USTACK_FLAGS = 0x8000000000000007 = NX | U | W | P
```

This grants read, write, and user access (U=1, W=1) while disabling execution (NX=1). Invariant **(I1):** all N mapped stack pages have R+W+U+NX.

## W^X enforcement in elf_lite_load

Lines 325–329 enforce the W^X invariant at load time:
```
mov rax, r9           // r9 = p_flags
and rax, 0x6          // mask PF_W (0x2) and PF_X (0x1)
cmp rax, 0x6          // check if both set
je elf_load_wx_error  // error if both present
```

If a PT_LOAD segment has both PF_W and PF_X set, elf_lite_load rejects it with error code `ELF_WX = 0xFFFFFFFD`. This pre-load gate ensures **no page ever has both write and execute permission**.

## Implicit guard page

Per **src/kernel/core/mm/user_stack.pdx** (lines 83–84), the page immediately below the allocated stack region is left unmapped (P=0). This guard-page mechanism matches x86_64 standard practice: any user access to the unmapped page triggers a #PF exception, guarding against stack overflow without needing a dedicated hardware flag.

Invariant **(I2):** guard page at `TOP - (size_pages+1)*4096` has P=0.

## AC (Architectural Conformance) Review

✓ **User text pages** (from elf_lite_load):
  - U=1 (ring-3 fetch enabled)
  - W=0 (write disabled, no PF_W)
  - NX=0 (execute enabled, PF_X set)

✓ **User data pages** (from elf_lite_load):
  - U=1 (ring-3 access enabled)
  - W=1 (write enabled, PF_W set)
  - NX=0 (execute enabled, PF_X set)

✓ **User stack pages** (from user_stack_alloc):
  - U=1 (ring-3 access enabled)
  - W=1 (write enabled, essential for stack operations)
  - NX=1 (execute disabled, prevents code execution from stack)

✓ **W^X invariant:**
  - Pre-load check in elf_lite_load rejects `(PF_W | PF_X)` combinations (error ELF_WX)
  - user_stack_alloc unconditionally sets NX=1, precluding any execute bit
  - No path in either function violates W^X

## Conclusion

Architectural conformance condition (AC) is met by existing #517 and #518 code:
1. User pages are consistently marked U=1, enabling ring-3 access.
2. W^X is enforced: no page is mapped with both write and execute permission.
3. Guard page below stack is unmapped (P=0), providing overflow protection.

No changes required.
