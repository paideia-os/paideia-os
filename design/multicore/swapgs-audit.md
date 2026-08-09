# swapgs discipline audit — R18-M2-002 (#766)

Enumeration of every `swapgs` site in the paideia-os kernel and
verification of entry/exit pairing per Intel SDM Vol 3A §6.14.5 and
Vol 4 §2.5.1 (IA32_KERNEL_GS_BASE semantics).

Every `swapgs` on kernel entry from CPL=3 must be matched by exactly
one `swapgs` on the corresponding kernel exit to CPL=3. A CPL=0-only
path (kernel-to-kernel ISR, no ring transition) must NOT execute
`swapgs`. Double-swap is a bug (leaves user's GS_BASE in effect for
kernel code; corrupts per-CPU `[gs:off]` access). Zero-swap on ring-3
entry is a bug (kernel runs with user's GS_BASE; same corruption).

## Invariants (in steady state)

- **CPL=0 (kernel running)**: `IA32_GS_BASE = &_percpu_cbs[cpu_idx]`;
  `IA32_KERNEL_GS_BASE = &_percpu_cbs[cpu_idx]` (post-#766 —
  previously `&_cpu0_kernel_gs` placeholder).
- **CPL=3 (user running)**: `IA32_GS_BASE = 0` (or user's TLS base
  once userland TLS lands); `IA32_KERNEL_GS_BASE = &_percpu_cbs[cpu_idx]`.

`swapgs` atomically exchanges the two MSRs' values. The Intel-mandated
discipline is:

- On CPL=3 → CPL=0 (SYSCALL / IRQ / #EXC): `swapgs` IS the first
  interrupt-window-safe instruction on the kernel side. GS_BASE now
  holds the per-CPU CB; KERNEL_GS_BASE holds what user had.
- On CPL=0 → CPL=3 (SYSRET / IRETQ): `swapgs` immediately before the
  ring transition. GS_BASE gets restored to user's; KERNEL_GS_BASE
  once again holds the per-CPU CB.

## Site inventory (HEAD 7589751 + #766)

### Syscall path — `src/kernel/core/syscall/entry.pdx`

| Line | Site                | Direction        | Notes                              |
| ---- | ------------------- | ---------------- | ---------------------------------- |
| 26   | `syscall_entry:`    | entry (user→krn) | First insn after SYSCALL           |
| 163  | epilogue            | exit (krn→user)  | Last insn before final `sysret`    |

**Paired.** Every SYSCALL executes both exactly once. The `sysret` at
L188 does not itself touch GS.

### First-time user entry — `src/kernel/core/syscall/enter_user.pdx`

| Line | Site                            | Direction       | Notes                                       |
| ---- | ------------------------------- | --------------- | ------------------------------------------- |
| 19   | `enter_userland_initial:`       | exit (krn→user) | Ring-0→ring-3 iretq bootstrap for init      |
| 151  | `sys_fork_child_landing:`       | exit (krn→user) | Ring-0→ring-3 iretq for forked child        |

**Asymmetric by design.** These two functions are the *only* ring-0 →
ring-3 transitions on a fresh task's first schedule; the paired kernel
re-entry is subsequent (any SYSCALL / IRQ / #EXC from that user code
does the entry-side swapgs). Balances out across a task's lifetime.

### ISR path — `src/kernel/core/int/isr_trampoline.pdx`

**Entry stubs** — 11 vectors with strict-KPTI CPL-conditional swapgs:

| Line | Stub               | Vector | Notes                                    |
| ---- | ------------------ | ------ | ---------------------------------------- |
| 74   | `_isr_stub_0`      | #DE    | ring-3 → swapgs; ring-0 → skip           |
| 93   | `_isr_stub_3`      | #BP    | idem                                     |
| 112  | `_isr_stub_6`      | #UD    | idem                                     |
| 131  | `_isr_stub_8`      | #DF    | idem (IST1)                              |
| 150  | `_isr_stub_13`     | #GP    | idem                                     |
| 169  | `_isr_stub_14`     | #PF    | idem (IST2)                              |
| 188  | `_isr_stub_32`     | timer  | idem                                     |
| 207  | `_isr_stub_33`     | LAPIC err/spurious | idem                          |
| 226  | `_isr_stub_36`     | UART RX | idem                                    |
| 245  | `_isr_stub_240`    | self-IPI f0 | idem                                |
| 264  | `_isr_stub_241`    | self-IPI f1 | idem                                |

**Exit** — 1 shared epilogue:

| Line | Site           | Direction        | Notes                                    |
| ---- | -------------- | ---------------- | ---------------------------------------- |
| 55   | `_isr_return`  | exit (conditional) | CPL peek at `[rsp+8]`; ring-3 → swapgs |

**Paired.** Every ISR entry stub `jmp`s into the vector-specific
`trampoline_vec_N` (in core/int/exceptions.pdx or handlers), which
eventually falls into `_isr_return`. Both entry-stub and exit gate
on the same CS.RPL check, so ring-0-entering ISRs (kernel-to-kernel
IRQ, e.g. timer firing mid-kernel-work) skip both sides — no swap
imbalance.

### Legacy TODOs — `src/kernel/core/int/idt.pdx`

The block-comment header at L23-70 documents `#657-SWAPGS-TODO`
markers on the *original* trampolines that were superseded by the
`_isr_stub_N` KPTI entry stubs in #721 Phase D. The TODOs are now
stale — the swapgs discipline is enforced at the `_isr_stub_N`
layer, and IDT gates 0/3/6/8/13/14/32/33/36/240/241 point at those
stubs (verified via idt.pdx build-time entry population). Any
new IDT-installed vector must either (a) use the same
`_isr_stub_N` template, or (b) explicitly document why it is
ring-0-only.

**Follow-up.** #657 tracking issue can be updated to reflect that
Phase D closed it; the block-comment in idt.pdx should be trimmed to
a historical footnote.

### CPUID-conditional / ad-hoc

None. `grep -rn 'swapgs' src/kernel/` at HEAD returns exactly the
sites tabulated above.

## #766 impact on the audit

Prior to #766, `IA32_KERNEL_GS_BASE` was seeded once at BSP boot
(`syscall_msr_init` → `_cpu0_kernel_gs`, a 16-byte scratch buffer),
and the corresponding entry-side `swapgs` in `syscall_entry` /
`_isr_stub_N` moved the per-CPU pointer OUT of GS_BASE and installed
`&_cpu0_kernel_gs` — an inert address whose backing memory was
untouched by any subsequent kernel code. Kernel [gs:off] accesses
were routed through `Local.cpu_local_get` (rdmsr, sidestepping GS)
so the broken KERNEL_GS_BASE value never manifested.

#766 fixes both halves:

1. `gs_base_init_bsp` (BSP, at kernel_main) writes both
   `IA32_GS_BASE` and `IA32_KERNEL_GS_BASE` to the BSP's per-CPU CB
   VA (`Percpu.percpu_cb_for(0)`). This runs AFTER `syscall_msr_init`
   so the #766 write wins.
2. `gs_base_init_ap` (each AP, at `_ap_entry`) does the same with the
   AP's own dense `cpu_idx` (derived by linear search of
   `_ap_apic_ids`). Ring-3 support for APs is not yet wired (no per-CPU
   IDT / TSS / LAPIC config on APs at M2), so the `IA32_KERNEL_GS_BASE`
   value is inert until M3-M5 wire the AP-side syscall/ISR paths, but
   programming it now keeps the invariant uniform across CPUs.

After #766, the swapgs discipline is *architecturally correct* for
future SMP userland: any `swapgs` on kernel entry from ring-3 loads
the correct per-CPU CB into GS_BASE regardless of which CPU the
interrupted user thread was running on. The audit tabulated above
remains sound — no new sites were added; only the MSR content was
corrected.

## Followup owners

- **M3 (#767 / #768):** per-CPU TSS + AP-side IDT install. New AP-side
  `swapgs` sites (if any) must be added to this table.
- **R21+ userland TLS:** when user code gets its own `IA32_GS_BASE`
  (via `arch_prctl(ARCH_SET_GS)` or equivalent), `IA32_KERNEL_GS_BASE`
  becomes strictly kernel-per-CPU and `IA32_GS_BASE` becomes user's
  per-thread. `gs_base_init_bsp` / `gs_base_init_ap` write only
  `IA32_KERNEL_GS_BASE` at that point; the user-side `IA32_GS_BASE`
  is written on context switch to a user task.
- **Paranoid entry (NMI / #MC):** vectors 2 and 18 are not in the
  wired IDT set today. When added, a paranoid-entry pattern
  (`rdmsr GS_BASE`; test user-space signedness; conditionally swap)
  is required to avoid double-swap on top of an in-progress
  post-swapgs kernel entry.
