# AP-side descriptor tables: shared IDT + per-CPU TSS (R87, #1964)

## Decision

**Shared IDT, shared GDT, per-CPU TSS.** Every logical CPU (BSP + up to 3
APs, `Percpu.MAX_CPUS = 4`) loads its *own* IDTR and GDTR via its own
`lidt`/`lgdt`, but both point at the *same* underlying tables in memory
(`Idt._idt_storage` / `Idt._idt_descriptor`, `Gdt._gdt_new` /
`Gdt._gdt_ptr`). Only the Task Register (TR) — and the TSS it points at —
is genuinely per-CPU: each AP gets its own 104-byte TSS (`ApTss._ap_tss`,
3 slots for cpu_idx 1..3) and its own three IST stacks, installed via a
new GDT descriptor slot per AP (slots 8..13, selectors 0x40/0x50/0x60).

Rationale:

- **IDT**: 256 gates, all pointing at the same trampolines
  (`trampoline_vec32`, `_ipi_trampoline_f0/f1/f2`, exception trampolines).
  There is nothing CPU-specific in a gate itself — the CPU-specific part
  of "which stack do I land on" is carried by IST indices (per-gate,
  shared) resolving against the *current* TSS (per-CPU). One 4 KiB table
  shared read-only across CPUs costs nothing extra per CPU and avoids
  4x the bookkeeping of rebuilding it per AP.
- **GDT**: segmentation is vestigial in long mode (bases/limits are
  ignored for code/data segments), so there is no reason for per-CPU
  code/data descriptors. The *only* per-CPU necessity is the TSS
  descriptor, because a TSS descriptor's "busy" bit is flipped by `ltr`
  and a second CPU cannot `ltr` an already-busy descriptor — so each CPU
  needs its own descriptor slot even though they can live in the same
  table.
- **TSS**: RSP0 and IST1..3 are inherently per-CPU state (they name a
  physical stack this exact core will push onto). Sharing a TSS across
  CPUs is not an optimization, it is a race: two CPUs simultaneously
  taking a ring transition would push onto the *same* stack.

## Why per-CPU IST stacks are not optional

The shared IDT already carries nonzero IST indices for vectors 8 (#DF,
IST1), 2 (#NMI, IST2), 14 (#PF, IST3), 18 (#MC, IST3) —
`Idt.idt_apply_ist_fields`, unchanged by this round. Per the SDM (Vol 3A
§7.7), a nonzero IST field in a gate is a hard instruction to the CPU:
"switch RSP to IST\<n> of the *currently loaded* TSS" — this is not
conditional on the TSS's own IST fields being non-null. Concretely: the
instant `lidt` is executed on an AP (making this shared IDT reachable via
that AP's IDTR), any subsequent NMI/#MC/#PF/#DF on that AP **must** find
a valid, non-null IST1/2/3 in whatever TSS that AP's TR currently names,
or the CPU pushes onto address 0 and triple-faults. Since NMI is
non-maskable (bypasses `cli`), this is not a theoretical corner: it is
the very next instruction boundary after `lidt`.

Consequence for ordering in `ap_desc_tables_install`
(`core/smp/ap_tss.pdx`): **`ltr` (with a fully-populated, non-null-IST
TSS) must complete before `lidt`.** This round's AP bring-up sequence is
lgdt → CS/SS reload → ap_tss_install (zero TSS, RSP0, IST1..3, GDT
descriptor, ltr) → lidt → fingerprint. Reversing the last two would
reopen exactly the triple-fault class the pre-R87 `cli`-only design
accepted as "no IDT loaded, so no gate to speak of."

Storage cost: 3 APs × 3 ISTs × 16 KiB = 144 KiB of `.bss`, plus 3 × 104 B
TSS = negligible. Not shared with the BSP's own `Ist._ist1/2/3_stack` —
sharing would reintroduce the exact NMI-mid-write race per-CPU IST
stacks exist to avoid.

## CS/SS reload after `lgdt`

The AP enters `_ap_entry` running under the trampoline's own low-memory
GDT with CS = 0x18 (a valid code64 descriptor *there*). After this AP's
own `lgdt` repoints its GDTR at the shared kernel GDT, selector 0x18 in
*that* table is slot 3 — reserved, all-zero. CS's hidden descriptor
cache is not re-validated by `lgdt` itself, so ordinary execution
continues unaffected — but the first `iretq` this AP ever takes (e.g. a
future timer tick, once a later round enables `sti`) would re-fetch CS's
descriptor from the *now-current* GDT to restore it, and find a null
descriptor: #GP.

Fix: reuse the same same-privilege-`iretq`-to-self trick
`Gdt.gdt_install` already uses on the BSP after its own `lgdt`
(`#661-followup`), parameterized per-AP so concurrent APs (which *can*
be mid-bring-up simultaneously — `ap_launch.pdx` does not wait for one
AP to finish `_ap_entry` before SIPI-ing the next) do not race a shared
scratch frame. `ApTss.ap_gdt_cs_reload(cpu_idx)` builds a 5-slot iretq
frame in a per-AP slice of `_ap_gdt_reload_frame` (RIP = the *caller's*
return address, CS = 0x08, RFLAGS = current, RSP = current, SS = 0x10)
and `iretq`s to the shared, stateless `Gdt._gdt_reload_land` (`ret`) —
from the caller's perspective this is indistinguishable from an ordinary
`call`/`ret`, with CS/SS freshly validated as a side effect.

## LAPIC base: MSR vs. constant (#1970 audit — no code change)

Every LAPIC accessor already in the tree (`apic_eoi`, `apic_svr_enable`,
`lapic_timer_init`, `lapic_timer_init_periodic_count`,
`lapic_timer_rearm`) composes its MMIO address from `_xapic_mmio_va` — a
VA populated once by `platform_map_early_mmio` on the BSP
(`design/kernel/boot-mmio-mapping.md`) — with an x2APIC MSR fast path
gated on `_x2apic_active`. Neither is CPU-specific in a way that breaks
under multi-CPU use: xAPIC's physical MMIO window (`0xFEE00000` by
default, unrelocated) decodes to *the issuing CPU's own* local APIC by
hardware construction — every CPU reads/writes "the same address" and
each hits its own unit. `_xapic_mmio_va` maps that one physical window
once; every CPU's access to it is local by definition. **No change
needed**; calling these same functions from AP context (as
`ap_desc_tables_install` and a future round's timer-enable will) is
already correct.

## The blocking finding: `_current_tcb` / `_idle_tcb` / `_tss` are BSP-global, not per-CPU

This is the ceiling this round lands against, and the reason
#1967/#1968/#1969 are **not** wired to real dispatch or real timer
preemption on the AP in this round.

`Percpu` (`core/smp/percpu.pdx`) already reserves `PERCPU_OFF_CURRENT_TCB`
(+16) and `PERCPU_OFF_TSS_PTR` (+64) for exactly this purpose, and
`PERCPU_OFF_PREEMPT_NEEDED` (+48) / `PERCPU_OFF_IDLE_TCB` (+80) are
*already* wired per-CPU (`_ipi_handler_f1` writes CB+48;
`sched_pick_next_r15` reads/returns CB+80). But the consumption side of
the preempt path never migrated:

- `Exceptions.handle_timer` reads/writes `Runqueue._current_tcb`,
  `Idle._idle_tcb`, and `Runqueue._preempt_needed` — all **single
  global instances**, not `[gs:+16]` / `[gs:+80]` / `[gs:+48]`.
- `Idt.trampoline_vec32`'s preempt tail checks the same global
  `_preempt_needed`, ignoring the per-CPU flag `_ipi_handler_f1` writes.
- `Sched.sched_switch_r15` writes `Runqueue._current_tcb` (global) and
  `TSS.RSP0` into `Tss._tss` (the *single* BSP TSS), not a per-CPU TSS
  pointer.

`idle.pdx`'s own `_ap_sched_init` comment already flags half of this
("the module-global `_idle_tcb`, which is BSP-only under SMP"). The
other half — `_current_tcb`, `_preempt_needed` consumption, and
`_tss`-RSP0 — was not previously documented as broken because no AP has
ever had a loaded IDT before this round, so `handle_timer` could never
actually run on a CPU other than the BSP.

**Consequence**: with this round's per-CPU GDT/TSS/IDT installed, it
would now be *mechanically possible* to enable `sti` and the LAPIC timer
on an AP — but doing so before the fix above would mean: the AP's
timer tick calls the identical shared `handle_timer` code, which reads
and writes the BSP's `_current_tcb`/`_idle_tcb`/`_preempt_needed`
globals with **no locking**, concurrently with the BSP's own tick. Any
real task dispatch reached via `trampoline_vec32`'s preempt tail would
call `sched_switch_r15`, which would overwrite `Tss._tss`'s RSP0 (the
BSP's own ring-3→ring-0 stack pointer) with whatever task the AP picked
— corrupting the BSP's next syscall/interrupt entry.

**This round does not attempt that migration.** It is scoped as a
follow-up (tentatively "R88: per-CPU scheduler-state migration"):
redirect `_current_tcb`/`_idle_tcb`/`_preempt_needed` reads in
`handle_timer` and `trampoline_vec32` to `[gs:+16]`/`[gs:+80]`/`[gs:+48]`,
and redirect `sched_switch_r15`'s RSP0 write to `[gs:+64]`
(`PERCPU_OFF_TSS_PTR`, which this round populates on every AP —
see `ApTss.ap_tss_install`'s CB+64 publish — so the follow-up has a
ready-made value to consume). Until that lands, AP bring-up in this
round deliberately stops at "descriptor tables loaded, CS/SS valid,
`cli;hlt` retained" — mechanically real progress (an NMI/#MC/#PF/#DF on
an AP now dispatches through a valid IST stack instead of triple-
faulting on a null IDT limit) without touching the live scheduler.

## What this round lands (#1965/#1966)

1. `Gdt._gdt_new` grows from 8 to 14 qwords (limit 0x3F → 0x6F); slots
   8..13 are 3 new TSS descriptors (selectors 0x40/0x50/0x60, one per
   AP), zero-initialized at BSP boot and populated lazily by each AP.
2. New module `core/smp/ap_tss.pdx`: per-AP TSS storage, per-AP IST1/2/3
   stacks, `ap_stack_top`-style accessors, `ap_tss_install(cpu_idx)`
   (zero + RSP0 + IST1..3 + IOMAP + GDT descriptor + `ltr` + CB+64
   publish), `ap_gdt_cs_reload(cpu_idx)` (per-AP CS/SS reload frame +
   shared landing pad), and `ap_desc_tables_install()` (the single
   `_ap_entry` call site: cpu_idx read → `lgdt` → CS/SS reload → TSS
   install/`ltr` → `lidt` → `ap idt ok` fingerprint).
3. `_ap_entry` calls `ap_desc_tables_install` once, after the existing
   R69 `sched_try_steal` call and before the (unchanged) `cli;hlt;jmp`
   park loop.
4. BSP-side witness `witness_r87_ap_idt` (`boot/witness/r87_ap_idt.pdx`),
   called from `kernel_main` after the existing AP-bring-up busy-wait:
   reads back the 3 AP TSS descriptors' access bytes from `_gdt_new`
   directly (busy bit `0xB9` proves `ltr` executed) and emits a single
   BSP-observable rollup fingerprint, `ap idt verify ok --
   cpus_ready=<N>`. This sidesteps relying on serial-interleaved
   per-AP fingerprints for the golden (those still print, presence-only,
   same discipline as `CPU_ID_XX_HELLO`).

## What this round does *not* land, and why (bail conditions)

- **`sti` / LAPIC timer / real task dispatch on AP** (#1968/#1969): see
  the blocking finding above. Landing this now would corrupt BSP
  scheduler state on the very next timer tick.
- **Re-enabling `witness_r69_smp_dispatch`**: its documented hang cause
  (`kernel_main.pdx`, the call site comment) is BSP's *own*
  `sched_pick_next_r15` eventually selecting one of the witness's
  synthetic, never-cleaned-up TCB slabs — a runqueue-hygiene bug
  independent of AP-IDT install. This round does not fix that, so the
  witness stays disabled and the 3 R69 fingerprints stay allowlisted in
  `tools/verify-fingerprint-coverage.sh`.
- **A literal `cpu_ticks > 0` AP-dispatch witness** (#1971 as specified):
  not achievable without the items above landing first. The witness
  this round actually lands proves what's real (per-CPU descriptor
  tables, verified via the GDT busy bit) rather than fabricating a
  ticks histogram — same honest-scope discipline
  `boot/witness/r69_smp_dispatch.pdx` already set precedent for.

## Encoder check (paideia-as, current tree)

Every mnemonic this round needs is already proven in-tree before this
round touches it: `lgdt [mem]` (`gdt.pdx`), `lidt [mem]` (`idt.pdx`),
`ltr r16` (`tss.pdx`), `iretq` + same-privilege reload frame
(`gdt.pdx`), `rdmsr`/`wrmsr` (pervasive), `imul r64, r64`
(`r69_smp_dispatch.pdx`), `shl r64, imm`/`shl r64, cl` (pervasive). No
new encoder gap; no paideia-as issue filed.
