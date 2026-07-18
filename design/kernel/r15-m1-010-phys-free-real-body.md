---
issue: 649
milestone: R15.M1 (User aspace creation & ELF-lite loader)
subsystem: 4 — physical-frame allocator
prereq: []                # none — bitmap release + phys_alloc_free_count() are
                          # local to the PhysAlloc/PhysFree/PhysPool triad.
blocks:
  - R15.M6 fork/exec/wait/_exit (needs real resource accounting across
    aspace_create/aspace_teardown cycles at process lifecycle boundaries).
touching:
  - src/kernel/core/mm/phys_pool.pdx         (+ bitmap decl)
  - src/kernel/core/mm/phys_alloc.pdx        (bitmap-first search, cursor as hint)
  - src/kernel/core/mm/phys_free.pdx         (real body — bitmap release)
  - src/kernel/boot/kernel_main.pdx          (witness block, ~30 LOC)
  - tests/r15/expected-boot-r15-ring3.txt    (marker line)
  - design/kernel/r15-m1-010-phys-free-real-body.md (this file)
related:
  - #658 (phys_alloc/aspace_create VA-not-PA landmine — independent, non-blocker)
  - #652 (first ring-3 witness — established the VA/PA discipline this design
    interoperates with at the aspace_teardown → phys_free boundary)
---

# R15-M1-010 — phys_free real body: bitmap release + free-count accessor (#649)

## 1. Scope

Replace `src/kernel/core/mm/phys_free.pdx`'s no-op body with a real
bitmap release so `aspace_teardown` (#521) and the future R15.M6
fork/exec/wait/_exit paths actually return physical frames to the pool
rather than silently leaking them.

In flight-check terms:

- `aspace_teardown` today walks the 4-level PT structure correctly, but
  every `phys_free` it invokes is a no-op — so a repeated
  create/teardown loop monotonically drains the 1024-page pool until
  the next `phys_alloc` returns 0 and the boot hangs on the OOM branch.
- With this change, an alloc/free round-trip returns
  `phys_alloc_free_count()` to its initial value (AC), and 100
  create/teardown cycles across user aspaces (AC) run to completion
  with the pool never exhausting.

Out of scope (deliberately deferred):

- Real physical-address contract for `phys_alloc` / `aspace_create` —
  that is #658, tackled independently. This design interoperates with
  the current VA-form contract by normalizing at the phys_free
  boundary (§4).
- Buddy coalesce for orders 1..10 — `phys_free` still errors on
  non-zero orders (matching current `phys_alloc` support). Buddy
  activation is milestone-scale work (R14 substrate).
- SMP / concurrency — the pool is still single-CPU. Locking lands
  with the magazine layer (#442).
- Bitmap growth beyond 1024 frames — the pool size is a `PhysPool`
  constant; enlarging the pool + resizing the bitmap is a mechanical
  follow-up when the substrate grows.

## 2. Prereq check

### 2.1 What's in place

- `src/kernel/core/mm/phys_pool.pdx`: static 1024-page
  `_phys_page_pool : [u64; 524288] @align(4096)`; bump cursor
  `_phys_pool_next : u64`.
- `src/kernel/core/mm/phys_alloc.pdx`: order-0 bump path (RIP-relative
  `lea + shift + add`); returns 0 on exhaustion, 0 on order ≠ 0.
  Contract-wise its "phys" return is a kernel VA (#658, harmless for
  every current consumer — see §4).
- `src/kernel/core/mm/phys_free.pdx`: no-op body (returns
  `PHYS_FREE_OK` on order 0, `PHYS_FREE_INVALID` on order ≠ 0).
- `src/kernel/core/mm/aspace_teardown.pdx`: 4-level PT walker, calls
  `phys_free` at each level for present entries (root PML4 last).
  Extracts frame addr from PTE via `and rax, 0xFFFFFFFFF000` — that
  is a **genuine PA** (per #652's fix in `aspace_map`, which stores
  `phys_alloc_result - KERNEL_VMA_BASE` in every PTE frame field).
  The root PML4 argument in `rdi`, however, is passed by the caller
  as the **VA form** (aspace_create's return value, unchanged).
- `KERNEL_VMA_BASE = 0xFFFF800000000000` — established in `link.ld`,
  used at 5+ sites as a movabs literal (paideia-as has no imm64 SUB/ADD).
- `paideia-as` v0.20 + #1246 (REX.B fix): all extended-register memory
  operands used below are on the audited path.

### 2.2 Callsites that consume phys_alloc's return today

Confirmed via `grep -rn 'phys_alloc' src/kernel/`:

| Caller                             | Uses result as             |
|------------------------------------|----------------------------|
| `aspace_create.pdx`                | pointer (zero + copy loops)|
| `kpti.pdx` (`kpti_build_user_pml4`)| pointer (structural writes)|
| `aspace_map.pdx`                   | PA (via `-KERNEL_VMA_BASE`)|
| `user_stack.pdx`                   | pointer + PA               |
| `elf_lite.pdx`                     | pointer + PA               |
| `boot/kernel_main.pdx` (#652)      | pointer (writes 0xF4)      |

Every current caller has been audited by #652; none is disturbed by
adding a bitmap check-and-set to the alloc path or by making
`phys_free` idempotent on double-free.

### 2.3 Callsites that consume phys_free's return today

| Caller                     | Frame form supplied  |
|----------------------------|----------------------|
| `aspace_teardown.pdx` L4   | PA (from PTE mask)   |
| `aspace_teardown.pdx` L3   | PA (from PTE mask)   |
| `aspace_teardown.pdx` L2   | PA (from PTE mask)   |
| `aspace_teardown.pdx` PML4 | **VA** (caller arg)  |
| `buddy.pdx` (delegate)     | pass-through         |

The mixed VA/PA input regime is the entire reason §4 exists. It is
**not a bug in `aspace_teardown`** — it is the visible surface of #658
at this boundary, and #649 handles it locally rather than plumbing
#658's full fix.

## 3. Design

### 3.1 High-level shape

Three tiny, orthogonal pieces:

1. Add `_phys_pool_bitmap : [u64; 16]` to `PhysPool`. Zero-initialized
   (all pages start free). Semantics: **bit `i` set → page `i`
   allocated**; **bit `i` clear → page `i` free**.
2. Rewrite `phys_alloc(0)`: linear-scan the bitmap starting at the
   word pointed to by `_phys_pool_next` (retained purely as a scan
   hint), find first zero bit, set it, compute page VA, return.
3. Write `phys_free(page, 0)`: normalize `page` to a PA-form offset
   into the pool (§4), compute `(word, bit)`, clear the bit, return
   `PHYS_FREE_OK`.

Plus one accessor for the AC witness:

4. `phys_alloc_free_count() -> u64`: sum `(64 - popcnt(word))` across
   the 16 bitmap words. Uses the `popcnt` instruction (SSE4.2;
   available under QEMU `-cpu max`).

### 3.2 PhysPool changes

`src/kernel/core/mm/phys_pool.pdx`:

```pdx
module PhysPool = structure {
  pub let PHYS_POOL_PAGES     : u64 = 1024
  pub let PHYS_POOL_PAGE_SIZE : u64 = 4096
  pub let PHYS_POOL_BITMAP_WORDS : u64 = 16   // 1024 / 64

  pub let mut _phys_page_pool : [u64; 524288] = uninit @align(4096)

  // Retained as scan hint into the bitmap; no longer the source of truth.
  pub let mut _phys_pool_next : u64 = 0

  // Bit i corresponds to page i in _phys_page_pool.
  //   bit == 1 → allocated,  bit == 0 → free.
  // Zero-initialized: whole pool is free at boot (matches R13-m2-005 baseline).
  pub let mut _phys_pool_bitmap : [u64; 16] = [
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0
  ]
}
```

Note: the array literal form matches `buddy.pdx`'s existing
`free_list_heads_per_node` initializer, which paideia-as codegens
into a `.bss`/`.data` block correctly under v0.20.

### 3.3 phys_alloc — bitmap-first search

Algorithm (order 0 only; order ≠ 0 continues to return 0):

```
1. cmp rdi, 0            ; only order 0
   jne exhausted
2. lea rax, [rip + _phys_pool_bitmap]      ; rax = &bitmap
3. lea rcx, [rip + _phys_pool_next]        ; rcx = &hint
   mov r10, [rcx]                          ; r10 = hint word index
4. xor r11, r11                            ; r11 = words tried
   scan_loop:
     cmp r11, 16
     jge exhausted
     ; word index = (hint + tries) mod 16
     mov rdx, r10
     add rdx, r11
     and rdx, 15                           ; mod 16 (power-of-2)
     ; load bitmap[word]
     mov r8, rdx
     shl r8, 3
     add r8, rax                           ; r8 = &bitmap[word]
     mov r9, [r8]
     ; find first zero bit (== find first one in ~r9)
     mov rsi, r9
     not rsi
     cmp rsi, 0
     jz next_word                          ; all bits set → word is full
     bsf rsi, rsi                          ; rsi = index of lowest 0 bit
     ; page index = word*64 + bit
     mov rdi, rdx
     shl rdi, 6
     add rdi, rsi
     ; range check (last word may extend past PHYS_POOL_PAGES)
     cmp rdi, 1024
     jge next_word
     ; mark bit set
     mov r12, 1
     shl r12, cl_from_rsi                  ; see note below
     or  r9, r12
     mov [r8], r9
     ; update hint
     mov [rcx], rdx
     ; compute page VA
     lea r13, [rip + _phys_page_pool]
     mov r14, rdi
     shl r14, 12
     add r13, r14
     mov rax, r13
     ret
   next_word:
     add r11, 1
     jmp scan_loop
   exhausted:
     xor rax, rax
     ret
```

Notes on the shift-by-variable step. paideia-as prints `shl r12, cl`
correctly (audited path). We stage the bit index into `rcx` via
`mov rcx, rsi` then `shl r12, cl`. Full concrete sequence lands with
the implementation.

Complexity: worst-case scan is 16 word-loads + one `bsf` per word
that is not fully set. In steady state (hint tracks last-allocated
word) it is one word-load + one `bsf`.

The bump cursor `_phys_pool_next` is deliberately **repurposed** as
a scan hint, not deleted, to keep the existing `.data` symbol layout
stable and to preserve any diagnostic tooling that watches it.

### 3.4 phys_free — bitmap release

Algorithm (order 0 only; order ≠ 0 continues to return `PHYS_FREE_INVALID`):

```
1. cmp rsi, 0
   jne invalid
2. ; --- normalize input to a VA (§4) ---
   mov rax, 0xFFFF800000000000    ; KERNEL_VMA_BASE (movabs)
   cmp rdi, rax
   jae va_form                    ; already a VA (bit 63 set → high-half)
   add rdi, rax                   ; PA form → convert to VA
   va_form:
3. ; --- compute page offset within pool ---
   lea rcx, [rip + _phys_page_pool]       ; rcx = pool VA base
   sub rdi, rcx                            ; rdi = byte offset (page-aligned)
   ; range check
   mov rax, 4194304                        ; 1024 * 4096
   cmp rdi, rax
   jae invalid
4. ; --- page_index = offset >> 12 ---
   shr rdi, 12
   ; word = page_index >> 6 ;  bit = page_index & 63
   mov rdx, rdi
   shr rdx, 6                              ; rdx = word index
   and rdi, 63                             ; rdi = bit index
5. ; --- clear bit ---
   lea rax, [rip + _phys_pool_bitmap]
   mov rcx, rdx
   shl rcx, 3
   add rax, rcx                            ; rax = &bitmap[word]
   mov r8, [rax]
   mov rcx, rdi
   mov r9, 1
   shl r9, cl                              ; r9 = 1 << bit
   not r9
   and r8, r9
   mov [rax], r8
6. xor rax, rax                            ; PHYS_FREE_OK
   ret
   invalid:
     mov rax, 0xFFFFFFFFFFFFFFFF
     ret
```

**Key properties**:

- **Idempotent double-free**: clearing an already-clear bit is a
  no-op. This is the correct default. A stricter "reject
  double-free" mode is deferred — it needs additional state.
- **Order-safe**: order ≠ 0 still returns the same
  `PHYS_FREE_INVALID` sentinel the parking body used, keeping the
  contract stable.
- **Range-safe**: any address outside the pool (e.g., a stray PA
  extracted from a corrupt PTE, or a caller passing a legitimately
  static-mapped address) returns `PHYS_FREE_INVALID` instead of
  scribbling on random bits.

### 3.5 phys_alloc_free_count accessor

Add to `phys_alloc.pdx` (co-located with the primary alloc surface,
matches locality convention used for `PHYS_ALLOC_NULL`):

```
pub let phys_alloc_free_count : () -> u64 !{} @{} = fn () -> unsafe {
  effects: {}, capabilities: {},
  justification: "R15-M1-010: sum (64 - popcnt(word)) across 16 bitmap words.
    Read-only; no {mem} effect. popcnt requires SSE4.2 (QEMU -cpu max).",
  block: {
    lea rax, [rip + _phys_pool_bitmap];
    xor rcx, rcx;                    ; total set
    xor rdx, rdx;                    ; word index
  fc_loop:
    cmp rdx, 16;
    jge fc_done;
    mov r8, rdx;
    shl r8, 3;
    mov r9, [rax + r8];
    popcnt r10, r9;
    add rcx, r10;
    add rdx, 1;
    jmp fc_loop;
  fc_done:
    ; free = 1024 - total_set
    mov rax, 1024;
    sub rax, rcx;
    ret
  }
}
```

The `mov r9, [rax + r8]` form is paideia-as v0.20 audited (`base +
reg` mem-operand). If a later audit surfaces a REX.B corner, the
paideia-as#928 workaround (compute address in a scalar reg first) is
a one-line substitution.

## 4. Interaction with #658 (VA / PA landmine)

### 4.1 The landmine, restated

Per #658 and #652: `phys_alloc` computes `&_phys_page_pool + cursor*4096`
via a RIP-relative `lea`. Since `_phys_page_pool` is a `.bss` symbol
linked at `KERNEL_VMA_BASE + phys`, the LEA resolves to a kernel VA,
**not** a hardware-walkable PA. Every current `phys_alloc` consumer
treats the return as a pointer, so this has been invisible everywhere
except at real CR3 flips (fixed at the two live callsites by #652).

`aspace_create` inherits the same VA-not-PA contract (returns the
`phys_alloc` result verbatim), which is why the root PML4 argument
passed to `aspace_teardown` — and, transitively, to `phys_free` —
arrives in **VA form**, while the intermediate tables and leaves
extracted from PTE frame fields arrive in **PA form** (per #652's fix
that made `aspace_map` store PAs).

### 4.2 How #649 handles it

`phys_free` normalizes input at entry (§3.4 step 2). Test on bit 63:

- **Bit 63 set → VA form**: pass through.
- **Bit 63 clear → PA form**: add `KERNEL_VMA_BASE` to lift to VA.

Then work exclusively in VA space (subtract pool VA base, compute
offset). This is safe because:

- `_phys_page_pool` lives in kernel `.bss.data` (high half only in the
  boot PT). Its VA is > `KERNEL_VMA_BASE`. The pool never spans the
  canonical hole; all 1024 frames are in a single 4 MiB VA range.
- Legitimate PA-form inputs from `aspace_teardown` are the PTE
  frame-field values — 40-bit low-half PAs, always with bit 63 clear.
- Legitimate VA-form inputs are `phys_alloc` results, always with
  bit 63 set (canonical high half).
- The two forms cannot alias because the pool VA range is entirely
  in the high half and the pool PA range is entirely in the low half.

### 4.3 Why this is independent of #658

`phys_free`'s normalizer is a **local** interoperation with #658's
current state, not a dependency on its resolution. If #658 lands
before #649, `phys_alloc` starts returning PAs and every input to
`phys_free` is PA form; the normalizer's PA branch handles that
without change. If #658 lands after #649, the normalizer's mixed
regime keeps working. **#649 does not block #658; #658 does not
block #649.**

The only cross-cut is documentation: the `phys_free` justification
string should call out the normalizer explicitly so that whoever
lands #658 knows they can *simplify* (not remove) the normalizer at
that time.

### 4.4 What #658 would simplify (not gate)

Once #658 lands and all `phys_alloc` / `aspace_create` returns are
PAs:

- The VA branch of `phys_free`'s normalizer becomes dead code and
  can be dropped.
- Pool-VA-base lookup could switch to a compile-time PA constant
  (`_phys_page_pool_pa = link.ld symbol - KERNEL_VMA_BASE`), removing
  the runtime `lea + sub` pair.

These are polish; the correctness argument is complete without them.

## 5. Test canary

### 5.1 Marker witness in kernel_main

Add a small block at the head of `kernel_main_64`, after
`ipc_smoke` / `cap_dispatch_smoke` and before the boot-substrate
sequence (GDT/IDT install), that exercises alloc/free round-trip and
emits `PHYS FREE ROUNDTRIP OK\n` to serial. Placement rationale: as
early as possible so any subsequent alloc (KPTI witness, ring-3
witness) that succeeds is empirical evidence that #649's changes did
not disturb the alloc path.

Witness contents:

```asm
; ============================================================
; R15-M1-010 (#649): phys_free bitmap release witness.
; ============================================================

; 1. Snapshot initial free count.
call phys_alloc_free_count;
mov r12, rax;                       ; r12 = initial free

; 2. Allocate 4 pages.
mov rdi, 0; call phys_alloc; mov r13, rax; cmp rax, 0; je pfr_fail;
mov rdi, 0; call phys_alloc; mov r14, rax; cmp rax, 0; je pfr_fail;
mov rdi, 0; call phys_alloc; mov r15, rax; cmp rax, 0; je pfr_fail;
mov rdi, 0; call phys_alloc; mov rbx, rax; cmp rax, 0; je pfr_fail;

; 3. Check free went down by 4.
call phys_alloc_free_count;
mov rcx, r12;
sub rcx, 4;
cmp rax, rcx;
jne pfr_fail;

; 4. Free all 4, in reverse order.
mov rdi, rbx; xor rsi, rsi; call phys_free;
mov rdi, r15; xor rsi, rsi; call phys_free;
mov rdi, r14; xor rsi, rsi; call phys_free;
mov rdi, r13; xor rsi, rsi; call phys_free;

; 5. Free count must return to initial.
call phys_alloc_free_count;
cmp rax, r12;
jne pfr_fail;

; 6. Emit marker.
lea rdi, [rip + phys_free_ok_msg];
call uart_puts;
jmp pfr_done;

pfr_fail:
lea rdi, [rip + phys_free_fail_msg];
call uart_puts;

pfr_done:
```

New rodata strings (append to existing `banner_msg` block):

```
phys_free_ok_msg   : "PHYS FREE ROUNDTRIP OK\n"
phys_free_fail_msg : "PHYS FREE ROUNDTRIP FAIL\n"
```

Callee-save discipline: r12/r13/r14/r15/rbx are used across
`uart_puts` / `phys_alloc` / `phys_free` calls. All five are
callee-saved by SysV AMD64 (which paideia-as adopts implicitly for
its `call` convention). `uart_puts`, `phys_alloc`, `phys_free`, and
`phys_alloc_free_count` all preserve them. No push/pop churn needed
here (kernel_main never returns).

### 5.2 Fingerprint drift

Extend `tests/r15/expected-boot-r15-ring3.txt`:

```
B
HI VA FFFF8000
PaideiaOS R8
PHYS FREE ROUNDTRIP OK       ← new
KPTI OK
KPTI SCRATCH OK
ENTER USER RELOC OK
R15 RING3 HELLO OK
IPI OK
```

Contains-in-order matching (`run-smoke.sh`) accepts extra lines, so
every earlier fingerprint file that lacks this marker continues to
pass unmodified. Canonical 9-mode smoke stays green (AC).

### 5.3 100-cycle aspace loop (deferred to R15.M6 landing)

The AC's "create + teardown 100 user aspaces, free_count returns to
initial value" test is a **stronger** witness that #649 wires
correctly end-to-end. Recommended: land the 4-page round-trip in
#649 (proves the arithmetic and the VA/PA normalizer), and land the
100-cycle loop in the R15.M6 substrate where `aspace_create_user` +
`aspace_teardown` are the natural verbs. Filing:

- Landing #649: **round-trip witness only** (4 pages, ~30 LOC).
- Follow-up in R15.M6: extend the fork/exec smoke to snapshot
  `phys_alloc_free_count()` before/after 100 cycles and assert
  equality. That witness lives naturally in the process-lifecycle
  smoke, not in the phys-allocator smoke.

If the reviewer wants both witnesses in #649, backtrack B (§7.2)
carries them.

### 5.4 Structural checks (objdump / nm)

Optional but recommended:

- `nm build/kernel.elf | grep _phys_pool_bitmap` — non-empty.
- `nm build/kernel.elf | grep phys_alloc_free_count` — non-empty.
- `objdump -d build/kernel.elf | sed -n '/<phys_free>:/,/^$/p'`
  must contain a `mov [reg], reg` write to the bitmap and a
  `movabs …, 0xFFFF800000000000` (the normalizer's compare).

Run by hand while implementing; not required as a script.

## 6. LOC estimate

| File                                        | LOC delta |
|---------------------------------------------|-----------|
| `src/kernel/core/mm/phys_pool.pdx`          | +5        |
| `src/kernel/core/mm/phys_alloc.pdx`         | +45       |
| `src/kernel/core/mm/phys_free.pdx`          | +45       |
| `src/kernel/boot/kernel_main.pdx`           | +30       |
| `tests/r15/expected-boot-r15-ring3.txt`     | +1        |
| `design/kernel/r15-m1-010-phys-free-real-body.md` (this file) | +330 |
| **Total**                                   | **~455**  |

Executable/config: **~125 LOC**. Design + fingerprint: ~330 LOC.

## 7. Backtrack candidates

Ordered by preference.

### 7.1 Backtrack A — Bump-only free path (rejected as primary)

Track a separate free-list head (LIFO) and push freed pages to it;
`phys_alloc` pops from the head before touching the bump cursor.
No bitmap.

Advantages: simpler alloc/free arithmetic; no VA/PA normalizer
needed (freed pages are threaded via their own memory, so their
addresses round-trip in whatever form the caller used).

Disadvantages: no way to answer `phys_alloc_free_count()` in O(1) —
you'd walk the list, which is O(n). AC calls out the accessor
explicitly. And the free-list is stored **in the freed pages
themselves**, which means anyone who reads a freed page (a
use-after-free bug) corrupts the allocator state — much harder to
diagnose than a bitmap-corruption.

Reject as primary. Retain as an option if bitmap turns out to
generate paideia-as encoder friction we don't want to unstick.

### 7.2 Backtrack B — Fold 100-cycle loop into #649's witness (rejected)

Instead of the 4-page round-trip (§5.1), do the full 100-aspace
create/teardown loop in `kernel_main`, snapshot free_count
before/after, emit `PHYS FREE 100 CYCLES OK`.

Advantages: retires the AC's stronger witness in the same PR.

Disadvantages: requires `aspace_create_user` +
`aspace_teardown` to succeed end-to-end on every iteration — but
`aspace_create_user` currently sets up strict-KPTI PMLs whose full
teardown coverage is unproven at this altitude. If any iteration
leaks a frame (which is precisely what #649 aims to prove **doesn't**
happen, circularly), the smoke pass becomes a co-witness of two
independent properties and it becomes harder to bisect a regression.

Reject as primary. Retain if reviewer wants the AC closed inside
#649.

### 7.3 Backtrack C — Bitmap in a separate module (rejected)

Move bitmap + free-count accessor to a new
`src/kernel/core/mm/phys_bitmap.pdx`, out of `PhysPool`.

Advantages: separates data (pool) from data-structure (bitmap).

Disadvantages: cross-module data references currently work via
`[rip + sym]` idiom that paideia-as v0.20 supports for `pub` symbols,
but every additional module split multiplies the surface where a
paideia-as encoder edge could surface. The bitmap is data, not
behavior; it belongs with `_phys_page_pool` for the same reason
`_phys_pool_next` belongs there today.

Reject. Colocation with the pool is the correct altitude.

### 7.4 Backtrack D — Reject double-free (rejected)

Track a second "allocated" bitmap ("this bit was set the last time
we alloc'd"); `phys_free` compares and returns
`PHYS_FREE_INVALID` on double-free instead of silently no-op'ing.

Advantages: catches real bugs.

Disadvantages: doubles the bitmap footprint for a defensive feature
that has no current consumer. Idempotent double-free is the standard
Linux `__free_pages` semantic (with the caveat that Linux catches
double-free via reference counting on the page struct, which we do
not have yet). Filing a follow-up ("`phys_free` double-free
detection") is the right move.

Reject for #649. File as **`phys-free-double-free-detection`**
follow-up.

### 7.5 Backtrack E — Skip cursor hint, always scan from 0

Simpler `phys_alloc`: no hint, scan bitmap word 0..15 every call.

Advantages: fewer moving parts; simpler proof of correctness.

Disadvantages: worst-case allocation cost grows to 16 word-loads
every call, even in the common case where the pool is 99% empty
and allocation naturally packs the low end. In a 100-iteration
create/teardown loop that touches ~200 pages per iter (up to ~200
allocations against a 1024-page pool), the difference is
~15,000 extra word-loads. Cheap, but no reason to accept the
regression.

Reject. Cursor as hint is ~5 extra LOC of `mov` + `and`.

### 7.6 Backtrack F — Land phys_alloc bitmap search separately from phys_free

Split the work: (F.1) `phys_free` gets its real body but
`phys_alloc` stays bump-only (bitmap still declared, but only read
by `phys_free`). (F.2) Follow-up: `phys_alloc` starts consulting the
bitmap.

Advantages: minimizes touch to the audited alloc path.

Disadvantages: creates a window where the bitmap is only half
accurate — `phys_free` clears bits, `phys_alloc` never sets them.
`phys_alloc_free_count()` becomes misleading: it says
"1024 - freed_count", when the truth is "1024 - freed_count - bump_used".
Anyone touching this in the F.1 → F.2 window has to hold a subtle
invariant in their head. Not worth the split.

Reject. Land alloc + free + accessor together.

## 8. Tractability

**HIGH.**

- All addressing modes used (`[rip + sym]`, `[reg + reg*8]`, `[reg + reg]`,
  variable-shift via `cl`, `bsf`, `popcnt`) are on the audited paideia-as
  v0.20 + #1246 path.
- No new paideia-as encoder capability required. `bsf` and `popcnt` are
  in the existing kernel or reachable via the same encoder surface as
  `bsr` / other bit-scan ops.
- No new linker-section discipline. `_phys_pool_bitmap` is `.bss.data`
  like every other `PhysPool` symbol.
- No new smoke mode. Existing `boot_r15_ring3` fingerprint file
  absorbs one new required line.
- The VA/PA normalizer at `phys_free`'s entry is 5 instructions and
  entirely local; no cross-file churn.
- No dependency on #658. If #658 lands ahead of #649, the normalizer
  becomes strictly redundant and can be simplified as noted in §4.4.
- No dependency on buddy activation (buddy still delegates order-0
  to `phys_alloc` / `phys_free` unchanged).

Known follow-ups (not blockers for #649):

- **`phys-free-double-free-detection`**: second bitmap or per-page
  refcount to reject double-free (§7.4).
- **`phys-alloc-pa-contract`** = #658: retire the VA-not-PA
  mislabeling at the source; simplify §4's normalizer to unconditional
  PA arithmetic.
- **`phys-alloc-smp-safety`**: LOCK prefix or magazine layer before
  the allocator is called from more than one CPU (#442 substrate).
- **`aspace-loop-witness-r15m6`**: 100-cycle create/teardown witness
  in the process-lifecycle smoke, closing the AC's stronger property
  (§5.3).

## 9. Cross-cutting risks

- **Bitmap init timing**: `_phys_pool_bitmap` is initialized by the
  `[u64; 16]` literal in `.data`, so it is correct **before**
  `kernel_main` runs. No dependence on `zero_bss` — if the literal
  were `uninit`, the `.bss.data` zero pass would still yield the
  correct all-free state, but the literal is explicit for clarity.
- **First allocation after boot**: with bitmap all-zero and hint at
  word 0, the first `phys_alloc(0)` returns page 0's VA. That's
  identical to the current bump behavior. `cap_smoke` /
  `ipc_smoke` / KPTI witness / ring-3 witness all see byte-identical
  allocation sequences up to the first `phys_free` — which is exactly
  the property that keeps existing smokes stable.
- **Race with cursor hint**: the hint is advisory. If it points past
  the last-freed page, allocation still finds the free bit — just
  after wrapping through 16 words. Idempotent under concurrent
  updates in the (still single-CPU) regime.
- **PA form aliasing kernel PT**: `phys_free`'s PA-form input is
  added to `KERNEL_VMA_BASE` to lift to VA. This is safe because
  every PA extracted from a PTE by `aspace_teardown` is a
  low-half address (bit 63 clear) that names a frame in the pool;
  the pool's PA range does not overlap other kernel data in a way
  that would cause a spurious "in pool" range-check hit. The
  `< 4 MiB pool size` range check guards this explicitly.
- **popcnt availability**: QEMU `-cpu max` exposes SSE4.2, which
  includes `popcnt`. If a future minimal CPU config drops SSE4.2,
  fall back to a Kernighan-style `x &= x-1` loop — trivial
  substitution in `phys_alloc_free_count` only.

## 10. References

- Issue: paideia-os#649
- VA/PA landmine: paideia-os#658
- #652 fix + full diagnosis: `design/kernel/r15-m2-006b-boot-r15-ring3-hello.md`
- Current no-op body: `src/kernel/core/mm/phys_free.pdx`
- Current bump alloc: `src/kernel/core/mm/phys_alloc.pdx`
- Pool + cursor: `src/kernel/core/mm/phys_pool.pdx`
- Consumer: `src/kernel/core/mm/aspace_teardown.pdx`
- Buddy delegate: `src/kernel/core/mm/buddy.pdx`
- Kernel VMA base: `src/kernel/link.ld` (`KERNEL_VMA_BASE = 0xFFFF800000000000`)
- Intel SDM Vol 2A — `BSF` (bit-scan forward), `POPCNT`
- Linux `mm/page_alloc.c` — bitmap release + free-count semantics
