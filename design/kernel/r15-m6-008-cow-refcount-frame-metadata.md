---
issue: 559
milestone: R15.M6 (fork / exec / wait / _exit)
subsystem: 9 — fork / exec / wait / _exit
prereq:
  - "#649 (phys_free real body — LANDED at src/kernel/core/mm/phys_free.pdx)"
  - "#658 note: VA/PA landmine — inherited discipline; frame_meta reuses phys_free's normalizer"
blocks:
  - "#552 (aspace_clone_cow — walker calls frame_meta_incref for each shared frame)"
  - "#553 (pf_handler CoW split — decrement on split, alloc new frame with refcount=1)"
touching:
  - src/kernel/core/mm/frame_meta.pdx           (NEW — _frame_meta[1024] + incref/get helpers)
  - src/kernel/core/mm/phys_alloc.pdx           (+2 store instructions after bit-set)
  - src/kernel/core/mm/phys_free.pdx            (+refcount decref-guard block)
  - src/kernel/boot/kernel_main.pdx             (witness block, ~45 LOC)
  - tools/boot_stub.S                           (2 rodata strings, +8 lines)
  - tests/r15/expected-boot-r15-ring3.txt       (marker line, contains-in-order)
  - tests/r15/expected-boot-r15-process.txt     (marker line, contains-in-order)
  - design/kernel/r15-m6-008-cow-refcount-frame-metadata.md (this file)
related:
  - design/kernel/r15-m1-010-phys-free-real-body.md   (VA/PA normalizer inherited verbatim)
  - design/kernel/cow-multishare.md                   (§CMS-D2: refcount as arbiter of who owns the split)
  - design/kernel/r15-m5-006-task-new-real.md         (register-discipline post-mortem template)
---

# R15-M6-008 — Frame refcount metadata: _frame_meta[1024] + incref/get + refcount-aware phys_free (#559)

## 0. Landing posture — STANDALONE, ahead of #552

This issue lands **decoupled from #552** (aspace_clone_cow walker) after
workerbee's co-landing attempt regressed boot. The pivot rationale:

- #559's core deliverable is a **local extension** of the physical
  allocator — one array, two helpers, one refcount-guarded free. It has
  a self-contained witness that requires **no page-table walking**.
- #552's walker is a distinct kernel altitude (touches PML4/PDPT/PD/PT
  under CR3-live constraints) with its own failure surface. Co-landing
  merged the two failure surfaces and the walker's regression masked
  the refcount correctness.
- Landing #559 first gives #552 a **known-good substrate**: when the
  walker is re-attempted, `frame_meta_incref` is already audited, the
  refcount semantic is already proved by boot witness, and #552's diff
  is confined to the walker itself.

The AC in the issue body ("refcount visible in fixture that forks,
then increment observed; frame not freed until refcount==0") is
**satisfied here by a manual-increment witness** rather than a fork
fixture. The fork-time increment is #552's territory; #559 owns the
allocator-side contract and proves it against manual driver code.

## 1. Scope

Introduce per-frame reference counting so that CoW-shared frames
(#552) survive `phys_free` calls until every sharing aspace has
released them, and only the last release actually returns the frame
to the pool.

Three tiny, orthogonal pieces:

1. **Storage** — `_frame_meta : [u64; 1024]` in `.bss`, one u64 per
   frame. Zero-initialized (every frame starts with refcount 0 == free,
   matching the bitmap's all-zero initial state).
2. **Allocator wire-in** — `phys_alloc(0)`, on successful bit-set,
   also writes `_frame_meta[page_index] = 1`. A fresh allocation is
   born with a single reference held by the caller.
3. **Deallocator wire-in** — `phys_free(page, 0)` decrements
   `_frame_meta[page_index]` and only clears the bitmap bit when the
   refcount hits 0. Double-free stays idempotent (§4.4).

Plus two cross-module helpers for #552 / #553 / witness use:

4. **`frame_meta_incref(page) -> u64`** — accepts VA or PA form
   (§4.1 normalizer), increments the refcount, returns the new count.
   This is what an `aspace_clone_cow` walker will call for each shared
   frame it maps into the destination aspace.
5. **`frame_meta_get(page) -> u64`** — read-only accessor. Returns
   the current refcount for observability (witness + future
   diagnostics).

Explicitly **out of scope** (deferred):

- **aspace_clone_cow walker** (#552) — the CoW-map side that
  materializes shared-and-RO PTEs across two aspaces. #559 supplies
  the incref primitive; #552 walks tables and drives it.
- **pf_handler CoW split** (#553) — decrement-on-split-and-alloc-new
  is #553's diff, not this issue's.
- **Refcount overflow protection** — 64-bit refcount, `MAX_PIDS = 64`
  aspaces at R15, one entry per aspace-sharing-a-frame. Even a
  million-way share tops out at 20 bits. Saturation guard (§7.5
  backtrack E) is deferred; not needed at R15 substrate.
- **SMP atomicity** — refcount reads/writes are non-atomic. The pool
  is still single-CPU (#442 substrate). LOCK XADD / LOCK CMPXCHG
  promotion is trivial when the magazine layer lands.
- **Owner tracking** — `_frame_meta[i]` is a bare u64 today. Field
  layout (refcount in low 16 bits, owner cap in next 32, flags in
  top 16) is a future-facing refinement (§7.3 backtrack C). At R15.M6
  it's just "the refcount".
- **Reject refcount underflow** — decrementing when refcount is
  already 0 is treated as a **no-op double-free** to match #649's
  idempotent contract. A stricter "reject double-free" mode is
  §7.4 backtrack D.
- **Wire `frame_meta_incref` into aspace_map** — every allocation
  going through `phys_alloc` already gets refcount=1. Sharing needs
  an explicit incref call (which is what #552 will do). aspace_map
  is not modified.

## 2. Prereq check

### 2.1 What's in place

| Primitive                         | Location                                | Contract used by #559                              |
|-----------------------------------|-----------------------------------------|----------------------------------------------------|
| `_phys_page_pool : [u64;524288]`  | `core/mm/phys_pool.pdx:25`              | Pool VA base for page_index arithmetic.            |
| `_phys_pool_bitmap : [u64;16]`    | `core/mm/phys_pool.pdx:33`              | Bit `i` set ⇔ frame `i` allocated. Refcount extends this: refcount>=1 iff bit set. |
| `phys_alloc(order)` — bitmap-first| `core/mm/phys_alloc.pdx:22`             | After bit-set, `_frame_meta[page_index] = 1`.       |
| `phys_free(page, order)` — bitmap release + normalizer | `core/mm/phys_free.pdx:17` | Reuses the VA/PA normalizer verbatim; wraps bit-clear in a refcount decref-guard. |
| `phys_alloc_free_count()`         | `core/mm/phys_alloc.pdx:114`            | Backs witness's refcount-vs-bitmap consistency check. |
| VA/PA normalizer discipline       | `phys_free.pdx:22-30`                   | `frame_meta_incref` reuses the same 5-instruction preamble. |
| `[rip + sym]` RIP-rel + `[reg + reg*8]` SIB | Every `core/mm/*.pdx`         | u64 array indexing (`_frame_meta[idx]` with idx*8 scale). |
| Callee-save discipline (rbx/r12-r15) | `phys_alloc.pdx:30` (post-#649 fix)  | frame_meta helpers stay register-clean like phys_free. |

### 2.2 What is not in place (and not required)

- **aspace_clone_cow**. The walker is #552; #559's witness fakes the
  "sharing" step via a manual `frame_meta_incref` call. When #552
  lands and drives real sharing, the same incref primitive is what
  it calls — no change to the allocator side.
- **pf_handler CoW split**. #553's side. #559's witness never
  triggers a #PF.

### 2.3 Encoder gaps (paideia-as)

**None.** Every addressing mode used is on paideia-as v0.20 + #1246
audited path:

- `mov [rip + _frame_meta + reg*8], imm` — no; the immediate form
  through SIB isn't universally covered. We use `mov r, imm; mov
  [rip + _frame_meta + reg*8], r` instead. Two instructions, same
  effect, no encoder risk.
- `mov r, [rip + _frame_meta + reg*8]` — SIB with `rip` as base is
  **not** valid x86 (RIP-relative doesn't support SIB); use `lea r,
  [rip + _frame_meta]; mov r2, [r + reg*8]`. Same pattern as
  `_pid_table` publish in `task_new.pdx:571`.
- `movabs rax, 0xFFFF800000000000` — the KERNEL_VMA_BASE constant,
  same as `phys_free.pdx:26`.
- `cmp` / `jae` / `add` / `sub` / `test` — register-only, standard.

## 3. Design

### 3.1 High-level shape

```
frame_meta.pdx
├─ _frame_meta : [u64; 1024]                (.bss, zero-init)
├─ frame_meta_incref(page) -> u64           (normalize → idx → *8 → inc → return)
└─ frame_meta_get(page)    -> u64           (normalize → idx → *8 → read → return)

phys_alloc.pdx  (bit-set path)
└─ +2 insns: mov rcx, 1; mov [rip + _frame_meta + rdi*8], rcx

phys_free.pdx  (bit-clear path)
├─ existing: normalize → offset → page_index (rdi) → word/bit split (rdx/rdi)
├─ NEW: refcount decref-guard:
│    lea r10, [rip + _frame_meta]
│    mov r11, [r10 + page_index*8]
│    test r11, r11 ; jz  fm_double_free      (idempotent: already free)
│    sub  r11, 1
│    mov [r10 + page_index*8], r11
│    test r11, r11 ; jnz fm_still_shared     (skip bit-clear, return OK)
├─ existing: clear bitmap bit
└─ existing: return PHYS_FREE_OK
```

### 3.2 `_frame_meta` layout

```pdx
// src/kernel/core/mm/frame_meta.pdx
module FrameMeta = structure {
  // Per-frame metadata. One u64 per page in _phys_page_pool.
  // R15.M6 usage: refcount only. Field layout deferred (§7.3).
  //
  // Semantics (invariant):
  //   _frame_meta[i] == 0  ⇔  _phys_pool_bitmap bit i == 0  (frame free)
  //   _frame_meta[i] >= 1  ⇔  _phys_pool_bitmap bit i == 1  (frame allocated with N refs)
  //
  // Zero-init: every frame is free at boot.
  pub let mut _frame_meta : [u64; 1024] = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    // ... 1024 entries, all zero, via the same array-literal pattern
    //     used by _phys_pool_bitmap
  ]
}
```

**Array-literal size**: 1024 u64 entries. Same pattern as
`_phys_pool_bitmap`'s 16-entry literal — paideia-as v0.20 has audited
support for this shape (`buddy.pdx:free_list_heads_per_node`).

If literal size proves noisy in source: `[u64; 1024] = uninit
@align(8)` works too (`.bss` zeros it before `kernel_main_64` runs
via the `zero_bss` pass in `boot/zero_bss.pdx`). The explicit literal
is chosen for **documentation clarity** — a reader sees "all zero"
at declaration site, not "trust the loader". LOC delta is ~15 lines
either way (16-per-line for the literal form).

**Byte cost**: 1024 × 8 = 8192 bytes = 2 pages. Kernel `.bss`; no
runtime allocation.

**Alignment**: `[u64; N]` naturally 8-aligned; no `@align` needed.

### 3.3 Public helpers — the incref/get pair

Both helpers reuse `phys_free`'s VA/PA normalizer verbatim (§4.1),
compute `page_index`, index `_frame_meta`, and act.

```pdx
// frame_meta_incref(page) -> u64 !{mem} @{}
//   Accepts page in VA form (from phys_alloc) or PA form (from PTE
//   frame field). Normalizes internally. Increments _frame_meta[idx]
//   and returns the new refcount. Returns FRAME_META_INVALID on
//   out-of-pool addresses.
pub let FRAME_META_INVALID : u64 = 0xFFFFFFFFFFFFFFFF

pub let frame_meta_incref : (u64) -> u64 !{mem} @{} =
  fn (page: u64) -> unsafe {
    effects: {mem}, capabilities: {},
    justification: "R15-M6-008 (#559): normalize page to VA form (bit-63
      test — same as phys_free §3.4), subtract pool VA base, range-check
      against 4 MiB pool extent, shift right 12 for page_index, then
      atomically-in-single-CPU-regime increment _frame_meta[page_index].
      Uses lea [rip+_frame_meta]; mov [reg+reg*8]; add; store. Returns
      new refcount for #552's walker to sanity-check. Returns
      FRAME_META_INVALID (-1) on out-of-pool address, matching
      phys_free's range-check reject shape.",
    block: {
      // --- normalize to VA form (§4.1 — verbatim from phys_free) ---
      mov rax, 0xFFFF800000000000;
      cmp rdi, rax;
      jae fmi_va_form;
      add rdi, rax;
      fmi_va_form:

      // --- compute page offset within pool ---
      lea rcx, [rip + _phys_page_pool];
      sub rdi, rcx;
      mov rax, 4194304;                       // 1024 * 4096
      cmp rdi, rax;
      jae fmi_invalid;

      // --- page_index = offset >> 12 ---
      shr rdi, 12;

      // --- increment _frame_meta[page_index] ---
      lea rax, [rip + _frame_meta];
      mov rcx, [rax + rdi*8];
      add rcx, 1;
      mov [rax + rdi*8], rcx;
      mov rax, rcx;                           // return new count
      ret;

      fmi_invalid:
        mov rax, 0xFFFFFFFFFFFFFFFF;
        ret
    }
  }

// frame_meta_get(page) -> u64 !{} @{}
//   Read-only accessor. Returns current refcount or FRAME_META_INVALID
//   on out-of-pool address. No {mem} effect — pure read.
pub let frame_meta_get : (u64) -> u64 !{} @{} =
  fn (page: u64) -> unsafe {
    effects: {}, capabilities: {},
    justification: "R15-M6-008 (#559): read-only twin of frame_meta_incref.
      Same normalize + range-check + index arithmetic, then load
      _frame_meta[page_index] into rax. No store. No {mem} effect.
      Used by witness (§5) to observe refcount at bump points, and
      available for future diagnostics.",
    block: {
      // --- normalize to VA form ---
      mov rax, 0xFFFF800000000000;
      cmp rdi, rax;
      jae fmg_va_form;
      add rdi, rax;
      fmg_va_form:

      // --- compute page offset within pool ---
      lea rcx, [rip + _phys_page_pool];
      sub rdi, rcx;
      mov rax, 4194304;
      cmp rdi, rax;
      jae fmg_invalid;

      shr rdi, 12;

      lea rax, [rip + _frame_meta];
      mov rax, [rax + rdi*8];
      ret;

      fmg_invalid:
        mov rax, 0xFFFFFFFFFFFFFFFF;
        ret
    }
  }
```

**Register discipline**: both helpers use only caller-save regs (rax,
rcx, rdi) — no push/pop prologue. Callers holding live state in
callee-save regs (rbx, r12-r15) are unaffected. This is the same
shape as `phys_alloc_free_count` (rax/rcx/rdx/r9/r10/r11 only).

### 3.4 `phys_alloc` — set refcount to 1 on successful bit-set

In the current bit-set epilogue (`phys_alloc.pdx:78-92`), after `or
r9, r8; mov [rax + rdx*8], r9;` and before `pop r14; pop r13; pop r12;
ret;`:

```pdx
// R15-M6-008 (#559): initialize refcount for the freshly-allocated frame.
// rdi already holds the page_index (line 71-73 computed it).
// Two instructions; no callee-save regs disturbed.
lea r12, [rip + _frame_meta];
mov r9,  1;
mov [r12 + rdi*8], r9;
```

**Why r12 as the address-holder**: r12 is already saved in the
prologue (`push r12` at line 30); using it here for a fresh load
is safe because we're between the last hint-update and the final
epilogue pop sequence. The existing `lea r12, [rip + _phys_pool_next]`
at line 81 already reuses r12 the same way.

**Why r9 as the value-holder**: r9 already held `bitmap[word]` moments
ago (line 78's `or r9, r8`). We overwrite it with `1` and store — the
old `r9` value is no longer needed. If preferred, use `mov qword ptr
[r12 + rdi*8], 1` in a single memory-immediate encoding. paideia-as
v0.20 support for `mov m64, imm32` is audited (task_new's
`mov [r13 + 4], eax` pattern is analogous). Two instructions
either way.

**No error path**: the bit-set already succeeded; the refcount write
is unconditional. No new failure surface.

**Interaction with phys_alloc's fail paths**: `phys_alloc_exhausted`
(line 98) and `phys_alloc_unsupported` (line 105) both bypass this
new write — correct, because no bit was set, so no refcount needs
initializing.

### 3.5 `phys_free` — refcount decref-guard

In the current bit-clear path (`phys_free.pdx:42-57`), between "shr
rdi, 12" (line 42) and the `mov rdx, rdi` word-index split:

```pdx
// R15-M6-008 (#559): refcount decref-guard.
// rdi = page_index (fresh from shr rdi, 12).
// Guard: if refcount is already 0, this is an idempotent double-free
// (matches #649's contract). If refcount decrements to a positive
// value, some other aspace still holds the frame — skip bit-clear.
// Only if refcount hits 0 do we fall through and clear the bitmap bit.

lea r10, [rip + _frame_meta];
mov r11, [r10 + rdi*8];
test r11, r11;
jz phys_free_idempotent;                   // already 0 → no-op OK
sub r11, 1;
mov [r10 + rdi*8], r11;
test r11, r11;
jnz phys_free_still_shared;                // refcount > 0 → return OK, keep bit
// fall through to existing bit-clear code
```

New epilogues:

```pdx
phys_free_still_shared:
    xor rax, rax;                          // PHYS_FREE_OK — but bit stays set
    ret;

phys_free_idempotent:
    xor rax, rax;                          // PHYS_FREE_OK — no-op semantics preserved
    ret;
```

**Why r10/r11**: both are caller-save; not used elsewhere in
phys_free's body. The existing body uses r8, r9, r10, r11 downstream
(lines 49, 51, 54, 55) but only **after** this new block runs and
either falls through or returns. No aliasing risk.

**Idempotent double-free** (r11 == 0 at entry): the guard returns
early with `PHYS_FREE_OK`, matching #649's contract. No underflow, no
bitmap disturbance. The AC of the phys_free real-body issue ("no-op
on double-free") stays satisfied.

**Refcount underflow risk**: guarded by the `jz phys_free_idempotent`
check. `sub r11, 1` only executes when `r11 >= 1`, so `r11` never
goes negative.

**Interaction with #649's normalizer**: the normalizer runs before
this block; the decref sees a valid page_index. No coupling change.

### 3.6 Invariant proof — bitmap and refcount stay coherent

The invariant to preserve is:
```
∀ i ∈ [0, 1024):  bitmap_bit(i) == 1  ⇔  _frame_meta[i] >= 1
```

Boot state: both zero. Invariant holds.

**phys_alloc** finds bit clear (0), sets it (1), sets refcount to 1.
Both transition together: `(0, 0) → (1, 1)`. Invariant holds.

**frame_meta_incref**: bumps refcount from `n` to `n+1` where `n >= 1`
(caller only calls on frames the caller believes are allocated —
enforced by #552's walker semantics). Bit stays 1. Invariant holds.
If a caller misuses incref on a truly free frame (refcount 0 → 1
without setting bit), the invariant breaks — this is a caller-side
bug, not the allocator's problem. §7.4 covers a defensive-check
variant.

**phys_free** three cases:
1. Refcount == 0 at entry: `jz phys_free_idempotent`. No state change.
   Was `(0, 0)`, stays `(0, 0)`. Invariant holds.
2. Refcount > 1 at entry: decrement to `n-1 >= 1`; skip bit-clear.
   Was `(1, n)`, becomes `(1, n-1)`. Invariant holds.
3. Refcount == 1 at entry: decrement to 0; fall through to bit-clear.
   Was `(1, 1)`, becomes `(0, 0)`. Invariant holds.

**#552's future walker** — for each frame it shares from src to dst:
`frame_meta_incref(pte_pa)`. Bit was already 1 (src had it mapped),
refcount goes 1 → 2. Invariant holds.

**#553's future pf_handler split** — when a shared frame faults on
write: `phys_free(old_pa)` (refcount 2 → 1, bit stays), `phys_alloc()`
returns a new frame with refcount 1, PTE rewritten to point at the
new frame. Both sides invariant-preserving.

## 4. Interaction with the VA/PA landmine (#658)

### 4.1 Normalizer reused verbatim

`frame_meta_incref` and `frame_meta_get` both open with the exact
5-instruction preamble from `phys_free.pdx:26-30`:

```asm
mov rax, 0xFFFF800000000000;    ; KERNEL_VMA_BASE
cmp rdi, rax;
jae va_form;                    ; already high-half
add rdi, rax;                   ; PA form → VA form
va_form:
```

Rationale identical to §4.2 of `r15-m1-010-phys-free-real-body.md`:
callers legitimately pass either form — `phys_alloc` returns a VA
(bit 63 set), PTE-mask extraction yields a PA (bit 63 clear), and
the two ranges cannot alias because the pool's VA range is entirely
high-half and its PA range is entirely low-half.

### 4.2 Same "#658 does not gate #559" property

If #658 lands ahead of #559: `phys_alloc` returns PAs. The
normalizer's PA branch handles them without change. `frame_meta_get`
called from #559's witness passes the `phys_alloc` result verbatim,
still normalizes correctly.

If #658 lands after #559: mixed regime keeps working. When #658
finally lands, the VA branch of both helpers' normalizers becomes
dead code and can be dropped in the same commit that simplifies
`phys_free`'s normalizer.

**#559 does not block #658; #658 does not block #559.**

## 5. Test canary — kernel_main witness block

### 5.1 Witness placement

Insert the witness block into `boot/kernel_main.pdx`'s
`kernel_main_64` immediately **after** the existing "R15-M1-010
(#649): phys_free bitmap release witness" block (currently at lines
90-131, ending at label `pfr_done:`), and **before** the KPTI
structural witness. Placement rationale:

- Runs immediately after `PHYS FREE ROUNDTRIP OK` — so if `#559`'s
  changes to `phys_free` broke the round-trip, the earlier witness
  fails first and pinpoints the regression to the refcount block.
- Runs before KPTI / ring-3 / loader witnesses — so any subsequent
  boot progression is empirical evidence that #559 didn't disturb
  the alloc path.

### 5.2 Witness body — 5 checks

```asm
; ============================================================
; R15-M6-008 (#559): frame_meta refcount witness.
; ============================================================

; Check 1: Snapshot initial free count.
call phys_alloc_free_count;
mov r12, rax;                       ; r12 = initial free count

; Check 2: Alloc a frame, verify refcount == 1 and free count -= 1.
mov rdi, 0; call phys_alloc;
mov r13, rax;                       ; r13 = frame VA
cmp rax, 0;
je fm_fail;

mov rdi, r13; call frame_meta_get;
cmp rax, 1;                         ; refcount must be exactly 1
jne fm_fail;

call phys_alloc_free_count;
mov rcx, r12;
sub rcx, 1;
cmp rax, rcx;                       ; free count decreased by exactly 1
jne fm_fail;

; Check 3: Incref, verify refcount == 2, free count unchanged.
mov rdi, r13; call frame_meta_incref;
cmp rax, 2;                         ; incref returns new count = 2
jne fm_fail;

mov rdi, r13; call frame_meta_get;
cmp rax, 2;
jne fm_fail;

call phys_alloc_free_count;
mov rcx, r12;
sub rcx, 1;
cmp rax, rcx;                       ; still down by only 1 (bit not cleared)
jne fm_fail;

; Check 4: First phys_free — refcount drops to 1, frame STAYS allocated.
mov rdi, r13; xor rsi, rsi; call phys_free;
cmp rax, 0;                         ; PHYS_FREE_OK
jne fm_fail;

mov rdi, r13; call frame_meta_get;
cmp rax, 1;                         ; refcount now 1
jne fm_fail;

call phys_alloc_free_count;
mov rcx, r12;
sub rcx, 1;
cmp rax, rcx;                       ; free count STILL down by 1 (bit stayed set)
jne fm_fail;

; Check 5: Second phys_free — refcount hits 0, frame RETURNS to pool.
mov rdi, r13; xor rsi, rsi; call phys_free;
cmp rax, 0;                         ; PHYS_FREE_OK
jne fm_fail;

mov rdi, r13; call frame_meta_get;
cmp rax, 0;                         ; refcount now 0
jne fm_fail;

call phys_alloc_free_count;
cmp rax, r12;                       ; free count restored to initial
jne fm_fail;

; All checks green.
lea rdi, [rip + frame_meta_ok_msg];
call uart_puts;
jmp fm_done;

fm_fail:
lea rdi, [rip + frame_meta_fail_msg];
call uart_puts;

fm_done:
```

### 5.3 What the 5 checks prove

1. **Refcount == 1 on fresh alloc.** `phys_alloc`'s new
   `mov [rip + _frame_meta + rdi*8], 1` instruction wrote the right
   value at the right offset. If it wrote to the wrong index or the
   wrong value, `frame_meta_get` returns something ≠ 1.
2. **Free count decreased by 1.** Confirms the bitmap set-bit path
   still runs — the refcount write didn't corrupt the bitmap state.
3. **Incref returns 2 and get sees 2.** `frame_meta_incref` correctly
   normalizes, indexes, reads, adds, stores, returns. The
   VA-form-from-phys_alloc case is exercised (bit 63 set → `jae
   fmi_va_form`).
4. **First free returns OK but bit stays.** The decref-guard's
   `jnz phys_free_still_shared` branch was taken (refcount decremented
   to 1, not 0). Bit not cleared. This is the **central property**
   #552 will rely on: sharing survives a free.
5. **Second free returns OK, bit clears, refcount 0.** The
   decref-guard's fall-through was taken (refcount decremented to 0),
   the existing bitmap-clear path ran, and the frame is truly back
   in the free pool.

Together, checks 4 and 5 exercise both branches of the refcount
guard and prove the invariant §3.6.

### 5.4 Rodata strings (append to `tools/boot_stub.S`)

```asm
# R15-M6-008 (#559): frame_meta refcount witness success message
.global frame_meta_ok_msg
.align 8
frame_meta_ok_msg: .ascii "R15 FRAME META OK\n\0"

# R15-M6-008 (#559): frame_meta refcount witness failure message
.global frame_meta_fail_msg
.align 8
frame_meta_fail_msg: .ascii "R15 FRAME META FAIL\n\0"
```

Placement in `boot_stub.S`: after `pool_witness_fail_msg` (line ~372),
before `exit_marker_msg`. Follows the alphabetical-ish
progression of the existing block.

### 5.5 Fingerprint drift

Extend two fingerprint files (contains-in-order):

`tests/r15/expected-boot-r15-ring3.txt`:

```diff
 PHYS FREE ROUNDTRIP OK
+R15 FRAME META OK
 KPTI OK
```

`tests/r15/expected-boot-r15-process.txt`:

```diff
 PHYS FREE ROUNDTRIP OK
+R15 FRAME META OK
 KPTI OK
```

The other fingerprint files (`boot_r8_only`, `boot_r10`, `boot_r11`,
`boot_r12`, `boot_r12_denial`) do **not** need editing — their scope
is pre-`phys_alloc` substrate that runs before this witness fires;
contains-in-order matching accepts extra output post-fingerprint.

### 5.6 Callee-save discipline in the witness

The witness uses `r12` (initial free count) and `r13` (frame VA)
across nested `call frame_meta_get`, `call frame_meta_incref`, `call
phys_free`, `call phys_alloc_free_count`, `call uart_puts` calls.

**All five callees preserve r12 and r13**:

- `phys_alloc_free_count` (`phys_alloc.pdx:114`): rax/rcx/rdx/r9/r10/r11
  only — r12/r13 untouched.
- `frame_meta_get` / `frame_meta_incref` (this doc §3.3): rax/rcx/rdi
  only — r12/r13 untouched.
- `phys_free` (`phys_free.pdx:17`): rax/rcx/rdx/rdi/rsi/r8/r9/r10/r11
  — r12/r13 untouched.
- `uart_puts`: audited by every witness in this file — preserves r12+.

No push/pop needed in the witness itself. `kernel_main_64` never
returns, so the outer-function view is moot.

## 6. LOC estimate

| File                                                             | LOC delta |
|------------------------------------------------------------------|-----------|
| `src/kernel/core/mm/frame_meta.pdx` (new)                        | +95       |
| `src/kernel/core/mm/phys_alloc.pdx` (+3 insns + comment)         | +6        |
| `src/kernel/core/mm/phys_free.pdx` (decref-guard block)          | +25       |
| `src/kernel/boot/kernel_main.pdx` (witness block)                | +55       |
| `tools/boot_stub.S` (2 rodata strings)                           | +10       |
| `tests/r15/expected-boot-r15-ring3.txt`                          | +1        |
| `tests/r15/expected-boot-r15-process.txt`                        | +1        |
| `design/kernel/r15-m6-008-cow-refcount-frame-metadata.md` (this) | +580      |
| **Total**                                                        | **~773**  |

Executable code + rodata + fingerprint: ~193 LOC. Design: ~580 LOC.

Same order of magnitude as #649 (~455 LOC total) and half the size
of #548 (~667 LOC total). Well within milestone budget.

## 7. Backtrack candidates

Ordered by preference.

### 7.1 Backtrack A — Colocate `_frame_meta` inside `PhysPool`

Instead of a new `frame_meta.pdx` module, add `_frame_meta` next to
`_phys_pool_bitmap` in `phys_pool.pdx`. Helpers still live in
`frame_meta.pdx` for external callers.

**Advantages**: One fewer module. Data locality with the bitmap it
extends.

**Disadvantages**: Contradicts the issue title's explicit `frame_meta.pdx
(new)` file mention. Mixes "frame metadata substrate" with "raw pool
storage" — a #552 reader looking at the incref mechanism should find
both the array declaration and the helpers colocated. Also, a future
extension to per-frame owner-cap tracking (§7.3) naturally lives in
`frame_meta.pdx`, not `phys_pool.pdx`.

**Reject as primary**. Honor the issue title. New-module cost is low
(paideia-as build.sh globs; §2.3 of #659's `build.sh`).

### 7.2 Backtrack B — Skip the incref helper (declare struct, no interface)

Ship `_frame_meta[1024]` + phys_alloc/phys_free wiring, no
`frame_meta_incref` / `frame_meta_get`. Let #552 poke the array
directly.

**Advantages**: Smaller diff. No cross-module call cost in #552's
walker inner loop.

**Disadvantages**: #552's walker would inline the normalizer+indexing
+increment (~10 instructions per frame). Encoder audit surface
duplicates. `frame_meta_get` is what the **witness** needs — without
it, the witness must directly index `_frame_meta` too, which
duplicates the normalizer a third time.

**Reject**. The ~30 LOC of helpers pay for themselves at first
reuse.

### 7.3 Backtrack C — Structured u64: refcount + owner + flags fields

Reserve field layout in `_frame_meta[i]` today:

```
bits 0..15    refcount (u16, max 65535 — enough for R15 sharing)
bits 16..47   owner_cap_id (u32 — capability naming the "creator")
bits 48..63   flags (u16 — pinned, dma, uncached, ...)
```

Provide field accessors `frame_meta_refcount(idx) -> u16` etc.
phys_alloc / phys_free operate only on the refcount field via mask+shift.

**Advantages**: Future-proofs the metadata word for owner tracking
and cap-audit properties. Reserves space for zero-page / pinned
frame flags without a second array.

**Disadvantages**: Overshoots R15.M6. Owner-cap tracking has no
consumer yet. Field masking adds 3-4 instructions per refcount access.

**Reject at R15.M6.** Land as `frame-meta-field-layout` follow-up when
the first consumer (cap-audit? zero-page tracker?) arrives. Migration
is source-level: today's callers see `_frame_meta[i]` as "the
refcount"; tomorrow's see it as a struct-typed word. No storage
change (already u64).

### 7.4 Backtrack D — Reject double-free via refcount underflow

Instead of `jz phys_free_idempotent; sub r11, 1`, treat entry-refcount
== 0 as an error:

```
test r11, r11
jz phys_free_invalid            ; underflow → refuse
sub r11, 1
...
```

**Advantages**: Catches real bugs where a caller frees a frame it
doesn't hold. This is exactly what #552's walker or #553's fault
handler might do wrong.

**Disadvantages**: Breaks #649's idempotent contract. Every existing
consumer of `phys_free` that expected a no-op double-free (which
Linux `__free_pages` also does, and #649 §7.4 documented as
intentional) suddenly gets `PHYS_FREE_INVALID`. `aspace_teardown`'s
walker may have paths that free-through-empty-PTE cases; a hard
reject would panic the boot.

**Reject for #559.** File `phys-free-double-free-detection` as a
follow-up (same title #649 §7.4 reserved). It's the same design
question, and refcount-underflow is the natural mechanism to
implement it — but a **separate landing** so consumer audits happen
in isolation.

### 7.5 Backtrack E — Saturating refcount at UINT64_MAX

Add a saturation guard in `frame_meta_incref`:

```
mov rcx, [rax + rdi*8]
mov r8, 0xFFFFFFFFFFFFFFFF
cmp rcx, r8
je fmi_saturated                ; already saturated → return without inc
add rcx, 1
```

**Advantages**: Impossible for the refcount to wrap and prematurely
free a widely-shared frame.

**Disadvantages**: Cost is 3 extra instructions per incref on a hot
path (#552's walker). Wrap requires 2^64 shares — physically
impossible in any conceivable system. Even the 2^16 saturation
suggested by §7.3's field layout is 65535-way sharing, which
exceeds MAX_PIDS by 3 orders of magnitude at R15.

**Reject.** Follow-up if §7.3's u16 refcount field lands and a
realistic overflow scenario surfaces.

### 7.6 Backtrack F — Ship refcount storage but no witness (defer to #552)

Land `_frame_meta[1024]` + `phys_alloc` wire-in + `phys_free`
decref-guard **without** the witness block. Rely on #552's aspace_clone_cow
fixture to first observe refcount!=0 at boot.

**Advantages**: Smallest diff. No boot-log churn.

**Disadvantages**: Contradicts the pivot rationale (§0). The whole
point of standalone landing is a **self-contained witness** that
proves the refcount mechanism works before #552's walker complexity
lands. Without the witness, #559 is untestable in isolation, and a
future #552 failure would re-couple the debugging.

**Reject.** Witness is the pivot's central contribution.

### 7.7 Backtrack G — Refcount bump inside frame_meta_incref only; phys_alloc leaves it at 0

Alternative semantic: `phys_alloc` returns a frame with refcount 0
("uninitialized"). The first `frame_meta_incref` call takes it to 1.
The caller is required to incref before treating the frame as owned.

**Advantages**: Symmetric — every ref is explicit. #552's walker
would naturally match "one incref per aspace that maps the frame".

**Disadvantages**: Breaks the invariant §3.6 immediately — a
freshly-allocated frame would have `(bit=1, refcount=0)`, violating
the "bit set iff refcount >= 1" property. `phys_free` would need a
special "refcount==0 but bit set" case that behaves like the old
no-op-body — losing all the diagnostic power of the invariant. Also,
every existing `phys_alloc` caller (kpti, aspace_map, elf_lite,
user_stack, kernel_main witnesses) would need audit for a missing
incref call.

**Reject.** "phys_alloc births with refcount 1" is the correct
Linux-mm-style default. Existing callers keep working unchanged.

## 8. Tractability

**HIGH.**

- No new paideia-as encoder gap. All addressing modes
  (`[rip + sym]` + `[reg + reg*8]` SIB, register-only arithmetic,
  `movabs`) are on the audited v0.20 + #1246 path.
- No new smoke mode. Existing `boot_r15_ring3` and `boot_r15_process`
  fingerprint files absorb one new line each.
- No new module directory. `core/mm/` is established.
- `frame_meta_incref` and `frame_meta_get` reuse the phys_free
  normalizer verbatim — zero new correctness surface, one new call
  path.
- `phys_alloc` diff is 3 instructions in the successful-bit-set
  epilogue. No new registers touched (r12 already saved; r9 already
  clobbered in the preceding `or`).
- `phys_free` diff is a ~10-instruction guard block before the
  existing bit-clear. No callee-save reg reuse; caller-save only.
- Witness runs directly after PHYS FREE ROUNDTRIP OK; if it regresses
  boot, backtrace is 45 LOC of witness or 30 LOC of allocator diff,
  bounded scope.
- **No walker complexity**. This is the pivot's whole point. #552's
  aborted attempt died because the walker + refcount landed as one
  commit; here the walker isn't touched.
- No dependency on #552 (issue explicitly deferred). No dependency
  on #658 (VA/PA normalizer inherited). No dependency on buddy
  activation (order-0 only).

Known follow-ups (not blockers for #559):

- **#552 aspace_clone_cow walker** — will call `frame_meta_incref`
  for each shared frame. Re-attempt lands isolated from refcount.
- **#553 pf_handler CoW split** — will call `phys_free` +
  `phys_alloc`; refcount arithmetic is transparent.
- **`phys-free-double-free-detection`** (§7.4) — strict-mode variant.
- **`frame-meta-field-layout`** (§7.3) — bit-field split for owner
  + flags when a consumer surfaces.
- **`frame-meta-smp-atomicity`** — LOCK XADD / CMPXCHG when the
  magazine layer (#442) lands.

## 9. Cross-cutting risks

- **`_frame_meta` init timing.** Array-literal in `.bss.data`; correct
  before `kernel_main_64` runs, no dependence on `zero_bss`. If the
  literal form proves noisy (1024 zero entries), the `uninit @align(8)`
  form still gets zero-init via `zero_bss.pdx` — same guarantee.
- **First allocation after boot.** With `_frame_meta` all zero and
  bitmap all zero, the first `phys_alloc(0)` returns page 0's VA,
  sets bitmap bit 0, sets `_frame_meta[0] = 1`. Byte-identical to
  the existing bump behavior on the alloc side; adds one 8-byte
  store in `.bss`. `cap_smoke`, `ipc_smoke`, KPTI witness, ring-3
  witness, loader witness — every downstream witness sees the same
  free-count and same VA — but now every allocated frame carries a
  refcount==1. Nothing observable changes at the witness surface
  until #559's own witness fires.
- **Existing `phys_free` callers now traverse the refcount guard.**
  Every current phys_free caller (`aspace_teardown`,
  `phys_free_ok_msg` witness) frees frames that were alloc'd with
  refcount=1. The first phys_free decrements 1 → 0, falls through to
  bit-clear — byte-identical outcome to today. **No change to
  boot-log fingerprints beyond the new witness line.**
- **VA/PA normalizer reuse triples the surface.** `phys_free`,
  `frame_meta_incref`, `frame_meta_get` each carry the same 5-inst
  preamble. A future #658-simplification pass needs to update three
  sites, not one. Mitigation: each site's justification string names
  the normalizer as inheritable from #649 §4 — a `grep 0xFFFF800000000000`
  finds all three.
- **Witness passes r13 (frame VA) across `phys_alloc_free_count`.**
  Confirmed at §5.6: the accessor uses only caller-save regs.
  Regression here would surface as a Check-2 free-count mismatch,
  bounded scope.
- **Refcount arithmetic under speculative execution.** `sub r11, 1;
  mov [r10 + rdi*8], r11; test r11, r11` — the test consumes r11
  from the sub, not from the memory. Speculation on the store's
  visibility doesn't affect the branch. Safe under x86 TSO.
- **1024-entry literal in source.** Written as 64 rows × 16 zeros;
  ~64 lines of source. If paideia-as v0.20 has any per-line initializer
  cap surfacing, fall back to `uninit @align(8)` (7 lines total) with
  reliance on `zero_bss` — same runtime result. Explicit literal is
  chosen for documentation clarity, not correctness.

## 10. Backtrack markers (for debugger if witness reports FAIL)

| Symptom                                        | Root cause hypothesis                                     | Where to look                                        |
|------------------------------------------------|-----------------------------------------------------------|------------------------------------------------------|
| Check 2 FAIL (refcount != 1 on fresh alloc)    | phys_alloc's `mov [rip+_frame_meta + rdi*8], 1` didn't run OR wrote wrong index | `phys_alloc.pdx`: verify insn placed AFTER `mov [rax+rdx*8], r9;` (bit-set) and BEFORE `pop r14`; verify rdi still holds page_index at that point |
| Check 2 FAIL (free_count didn't decrease)      | Bitmap set-bit path skipped                               | `phys_alloc.pdx`: is `or r9, r8; mov [rax+rdx*8], r9;` still emitted? |
| Check 3 FAIL (incref != 2)                     | frame_meta_incref normalizer or index arithmetic broken   | `frame_meta.pdx`: check `add rdi, rax` (PA→VA branch) not taken when phys_alloc already returned VA; check `shr rdi, 12` divided the offset, not the raw VA |
| Check 4 FAIL (frame returned to pool early)    | Decref-guard's `jnz phys_free_still_shared` not taken     | `phys_free.pdx`: verify `sub r11, 1` then `test r11, r11; jnz` present; verify `_frame_meta` write actually took effect (decrement stored, not just computed) |
| Check 4 FAIL (refcount != 1 after 1st free)    | Decref-guard subtracted wrong amount OR stored to wrong slot | `phys_free.pdx`: check `mov [r10 + rdi*8], r11` uses rdi (page_index at that stage) with scale-8 |
| Check 5 FAIL (bit not cleared after 2nd free)  | Fall-through from `jnz phys_free_still_shared` skipped bit-clear code | `phys_free.pdx`: verify the label placement — `phys_free_still_shared` is a ret target, NOT a jump-past for the bit-clear |
| Check 5 FAIL (free_count didn't recover)       | Bit-clear ran but on wrong word/bit                       | `phys_free.pdx`: verify `mov rdx, rdi; shr rdx, 6; and rdi, 63` split happens BEFORE `phys_free_still_shared` ret target, not after |
| Silent hang after PHYS FREE ROUNDTRIP OK       | Witness call clobbers caller-save rax/rcx/rdi in unexpected way, corrupting subsequent jumps | Witness lives inside kernel_main_64; check no accidental `push/pop` mismatch inside the witness block |

## 11. References

- Issue: paideia-os#559
- Sibling issues (this milestone):
  - #552 (aspace_clone_cow — deferred; walker calls `frame_meta_incref`)
  - #553 (pf_handler CoW split — deferred; sees refcount transparently)
  - #554 (sys_fork), #555 (sys_execve), #556 (sys_wait), #557 (sys_exit)
- Predecessor issue (LANDED):
  - #649 (phys_free real body) — VA/PA normalizer inherited verbatim
- Related design docs:
  - `design/kernel/r15-m1-010-phys-free-real-body.md` §3.4 (bit-clear
    path this doc extends), §4 (VA/PA normalizer this doc reuses)
  - `design/kernel/cow-multishare.md` §CMS-D2 (first-writer-wins
    semantic the refcount enforces)
  - `design/kernel/r15-m5-006-task-new-real.md` §3.2 (register-discipline
    template for post-mortem-immunized helpers)
- Source (touching):
  - `src/kernel/core/mm/phys_pool.pdx` — pool + bitmap declaration
  - `src/kernel/core/mm/phys_alloc.pdx:78-92` — bit-set path to extend
  - `src/kernel/core/mm/phys_free.pdx:42-57` — bit-clear path to guard
  - `src/kernel/boot/kernel_main.pdx:90-131` — phys_free witness (predecessor
    marker; new witness lands immediately after)
  - `tools/boot_stub.S:340-372` — rodata block for `_msg` symbols
- Fingerprints (touching):
  - `tests/r15/expected-boot-r15-ring3.txt`
  - `tests/r15/expected-boot-r15-process.txt`
- Constant:
  - `src/kernel/link.ld` (`KERNEL_VMA_BASE = 0xFFFF800000000000`)
- Prior-art register-discipline post-mortem: commit `f6195ed`
  (phys_alloc callee-save fix) — §5.6 immunizes against.
- paideia-as encoder audits: `tools/paideia-as/tests/build-emit/`
  — RIP-rel + SIB memory-operand smoke tests.
