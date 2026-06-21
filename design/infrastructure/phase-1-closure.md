# PaideiaOS — Phase 1 Closure Note

**Status:** Phase 1 substrate complete (Phase-1 honest scope).
**Date:** 2026-06-21.
**Scope:** Phase 1 milestone (long-mode + COM1 UART + kernel banner) — 14 issues #1..#14.

## What Phase 1 delivered

- **Boot infrastructure** (#1..#5):
  - `src/kernel/boot/gdt.pdx` — 5-entry GDT (null + code32/data32 + code64/data64).
  - `src/kernel/boot/pagetables.pdx` — page-table descriptor stubs (anchor qwords; full 512-entry tables pend paideia-as .bss).
  - `src/kernel/boot/long_mode.pdx` — CR4.PAE + EFER.LME + CR0.PG transition sequence (encoder gaps; placeholder bytes shipped).
  - `src/kernel/boot/zero_bss.pdx` — `rep stosq` primitive for .bss zeroing.
  - `src/kernel/link.ld` — higher-half preview symbols (KERNEL_VMA_HIGHER_HALF = 0xFFFFFFFF80000000).

- **UART driver** (#6..#8):
  - `src/kernel/boot/uart.pdx` — `uart_out`, `uart_putc`, `uart_puts` primitives. All use `out dx, al` directly (m2-003 encoder). Polling loops + multi-byte writes deferred to Phase 6+.

- **Kernel main** (#9..#10):
  - `src/kernel/boot/banner.pdx` — 8-byte first chunk of banner ("Paideia\0" packed LE) + length constant.
  - `src/kernel/boot/kernel_main.pdx` — `kernel_main_64` stub (single uart_out write).

- **Smoke + closure** (#11..#14):
  - `tools/run-smoke.sh` — QEMU smoke gated on qemu-system-x86_64 + 5s timeout.
  - `design/infrastructure/phase-1-closure.md` — this doc (P1-012).
  - `design/audit/README.md` — audit catalog roll-up.

## kernel.elf size

Phase-1 close: ~9100 bytes (.text + .rodata + ELF metadata).

## What didn't ship (gates on paideia-as Phase 6+)

- **Multi-instruction unsafe blocks**: paideia-as U1606 fires on zero-operand instructions (`cli`, `hlt`, `sti`, `nop`, `swapgs`, `cpuid`) inside unsafe block payload. Filed: paideia-as #736.
- **mov CR*, GPR routing**: paideia-as encoder bridge fails on `mov cr3, rdi` etc. with 'invalid register id' + silent placeholder fallback. Filed: paideia-as #734.
- **fn () empty arg list**: paideia-as parser fires P0100 on `fn () -> ...`; workaround uses `fn (x: ()) -> ...`. Filed: paideia-as #735.
- **Polling loops in unsafe blocks**: cmp + jcc encoders not in m2; UART real polling deferred.
- **Call between top-level fns inside unsafe block**: kernel_main_64 invoking uart_init via call deferred (Phase 6+).
- **String literal surface**: full banner text needs ~64 bytes via [u8; N] literals; paideia-as m4-002 supports the syntax but per-byte literal initialization is impractical without string-literal surface.
- **.bss array allocation**: page tables need 3 × 4KiB zero-initialized; paideia-as DataSideTable emits to .rodata/.data; .bss not yet wired for arrays.

## Decision gate G1

Phase-1 closure criteria (per the milestone):

- [x] All 14 issues closed (#1..#14).
- [x] `tools/build.sh` produces a valid ELF64 kernel.elf.
- [x] Boot infrastructure files exist (gdt, pagetables, long_mode, zero_bss, uart, banner, kernel_main).
- [x] Audit catalog covers every `unsafe { }` block (7 entries; design/audit/entries/).
- [x] Smoke runner exists (`tools/run-smoke.sh`).
- [~] QEMU boots kernel without triple-fault — gated on paideia-as build emitting non-placeholder bytes for cli/hlt etc. **Will close when paideia-as #734 + #736 land.**

Two acceptance items remain blocked on paideia-as gaps. The PaideiaOS-side substrate is in place; the gaps are paideia-as toolchain bugs that surface in Phase 5+ work.

## Phase-2 entry criteria

Phase-2 (capability system) gates on:

- paideia-as supports `struct` typed surface end-to-end (`paideia-as build` lowering). Currently struct parses but build emits placeholder. **Filed: paideia-as #734-area work.**
- Phase-1 kernel.elf actually boots in QEMU + produces visible output. **Pending #734 + #736.**

Phase-2 cannot start until those two gates pass.

## Open questions for Phase-2 entry

- Per the m13-006 m13-005 Phase 5 opening conditions doc: should PaideiaOS Phase-2 wait for paideia-as Phase 6 to land, OR proceed in parallel with the toolchain side using only the LCD surface?
- Current answer: WAIT. Phase-2 capability descriptor needs struct support to land cleanly.

## Forward links

- `design/capabilities/phase1-api.md` — Phase-2 capability spec.
- `design/infrastructure/build-system.md` — toolchain contract.
- `design/infrastructure/boot-path.md` — boot mechanism + deferrals.
- `design/infrastructure/first-milestone.md` — Phase-1/2 design rationale.
- `paideia-as #734, #735, #736` — surfaced toolchain bugs.
