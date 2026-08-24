# Boot-time MMIO Mapping — Definitive Fix

**Status:** design memo, pre-implementation
**Author:** softarch (Opus 4.7), 2026-08-23
**Repos touched (implementation):** `src/kernel/boot/`, `src/kernel/core/mm/`, `src/kernel/core/time/`, `src/kernel/core/apic/`, `src/kernel/core/drivers/`
**Companion docs:** `design/kernel/boot-witness-module-split.md`, `design/kernel/kernel-logging-substrate.md`, `design/roadmap/r19-t14-g4-boot-guide.md`

---

## 1. Root cause

The boot identity map is hard-coded in `tools/boot_stub.S` as four 1-GiB
PDPT entries covering `[0, 4 GiB)` (`pdpt+0..pdpt+24` at lines 26–33: physical
bases 0/1/2/3 GiB, each with `PS | RW | P = 0x83`). The kernel has no
subsequent code that widens this map or installs additional PTEs for
device MMIO; every driver that reaches into I/O space (`core/time/hpet.pdx`
at `0xFED00000`, `core/apic/eoi.pdx` at `0xFEE00000`, `core/apic/ioapic.pdx`
at `0xFEC00000`, and any device with a BAR above 4 GiB) has, up to today,
relied on the accident that its fixed PA happens to fall inside one of those
four 1-GiB huge pages — and the huge pages happen to be R/W. That accident
holds for QEMU q35's firmware-fixed window (all three of HPET/xAPIC/IOAPIC
sit in `[0xFEC00000, 0xFF000000)` inside PDPT[3]) but is *not* a design;
it is an unenumerated coincidence. On T14 G4, ACPI-discovered MMIO ranges
can land anywhere in the CPU's physical address space (`design/roadmap/
r19-t14-g4-boot-guide.md` §Firmware layout), and NVMe BAR0 under QEMU is
whatever the BIOS assigns — routinely above 4 GiB.

The boot witness runner (`src/kernel/boot/kernel_main.pdx` L392–L950 and
L1293–L1370, invoking `witness_r30_platform` at L930 with body in
`src/kernel/boot/witness/r30_platform.pdx`) executes ~388 sequential
witnesses, many of which perform real MMIO reads/writes to those exact
addresses, on the ring-0 boot stack, before `enter_userland_initial`
(kernel_main.pdx L1412). When a witness accesses an unmapped MMIO PA, the
CPU raises `#PF`; the ring-0 arm of `_typed_handler_14`
(`src/kernel/core/int/exceptions.pdx` L449–L493) calls `pf_handle_cow`
(rejects — not a CoW fault), then falls through to `handle_pf` (L125), which
calls `exc_handle(EXC_PF)` and cpu-halts. There is no ring-0 death arm.
`src/kernel/boot/witness/r30_platform.pdx` L6775–L6782 already documents
one instance of the collision (clock_read_ns_witness_call is manually
neutered to a `nop`). That per-witness gate is exactly what this memo is
designed to make unnecessary.

## 2. The definitive fix

**Introduce a `platform_mmio_map(pa_base, size, cache_type) -> kernel_va`
primitive and a static early-boot MMIO manifest, then require every driver
that touches MMIO to route its reads/writes through the returned kernel VA
rather than the raw PA.** The primitive is a near-verbatim generalization
of the existing `fb_map_lfb` (`src/kernel/core/drivers/fb_map.pdx` L159 ff.),
which already demonstrates the whole mechanism: allocate VA sequentially
from a reserved higher-half window, iterate the [pa, pa+size) range in
4-KiB steps, `aspace_map(_kernel_pml4_pa, va, pa, flags)` per page with the
appropriate PAT selector, and return the resolved VA. This inverts the
current unwritten contract from "MMIO PA = MMIO VA (via identity map)" into
"MMIO VA is whatever the mapper returned; PA is opaque after registration"
— which is the only contract that survives ACPI-discovered ranges on real
hardware.

**Concrete building blocks that already exist:**

- `aspace_map` (`src/kernel/core/mm/aspace_map.pdx` L47) — 4-level PT walker
  that allocates intermediate tables via `phys_alloc`, writes the leaf PTE,
  and issues `INVLPG`. Sentinel `MAP_HUGE = 0xFFFFFFFD` (L24) is returned if
  descent hits a 1-GiB or 2-MiB huge page — this is the collision the fix
  must anticipate for PA windows that overlap the boot huge-page identity
  map.
- `_kernel_pml4_pa` (`src/kernel/core/mm/kpti.pdx` L67, populated at
  `src/kernel/boot/kernel_main.pdx` L70) — the shared kernel PML4 base, the
  same root every existing `aspace_map` call for kernel-level pages uses.
- PAT slot programming (`src/kernel/core/mm/pat.pdx` L135–L136) — already
  wires slot 0=WB, slot 3=UC, slot 4=WC. The MMIO mapper uses slot 3 (UC)
  for register windows (HPET/APIC/IOAPIC/NVMe control) and slot 4 (WC) for
  linear framebuffer / DMA push windows — same encoding scheme `fb_map_lfb`
  uses (flags word `0x8000_0000_0000_0082` for WC + NX + RW; the UC
  equivalent is `0x8000_0000_0000_0012` — PCD bit 4 + NX + RW).
- `fb_map_lfb` (`src/kernel/core/drivers/fb_map.pdx` L159) — the working
  reference implementation. The VA-window discipline it establishes is
  reusable: PML4[320] = `0xFFFF_A000_0000_0000` for framebuffer; this memo
  reserves the *adjacent* PML4[321] slot = `0xFFFF_A800_0000_0000` for the
  device MMIO window (VA selection rationale at fb_map.pdx L36 documents
  that PML4[256] holds the kernel image alias and PML4[384+] is reserved
  for the R25+ physmap — PML4[321] is unclaimed and does not collide with
  either).

**New primitive (to be built), `src/kernel/core/mm/mmio_map.pdx`:**

```
pub let platform_mmio_map : (u64, u64, u64) -> u64 !{mem, sysreg} @{boot}
    // (pa_base, size, cache_type) -> kernel_va (or 0 on failure)
```

`cache_type` is an enum-like `u64`: `MMIO_UC=0`, `MMIO_WC=1`. Body follows
fb_map's structure exactly: 5-push prologue; loop over [pa, pa+size) in
4-KiB steps; per page call `aspace_map(_kernel_pml4_pa, va_cursor,
pa_cursor, flags_for(cache_type))`. If `aspace_map` returns `MAP_HUGE`, the
range collides with the boot huge-page identity map — for a fixed roster of
q35 addresses this is expected (they *are* already mapped, just at the
identity VA, R/W, WB); the wrapper's response is to `return pa_base` (i.e.,
tell the caller "the identity VA is a valid alias — use the PA verbatim")
rather than fail. This one branch is what preserves compatibility for every
existing driver whose base constants (`0xFED00000`, `0xFEE00000`,
`0xFEC00000`) already work under QEMU q35 today.

**A companion `platform_map_early_mmio` (in `src/kernel/boot/mmio_init.pdx`)**
walks a static manifest of firmware-fixed windows and pre-populates the
mappings before *any* witness runs. This handles the four boot-critical
ranges deterministically:

| PA          | Size   | Cache | Producer                           |
|-------------|--------|-------|------------------------------------|
| 0xFED00000  | 0x1000 | UC    | HPET (Intel PCH / QEMU q35 fixed)  |
| 0xFEE00000  | 0x1000 | UC    | xAPIC MMIO (LAPIC fallback)        |
| 0xFEC00000  | 0x1000 | UC    | IOAPIC (ICH9/q35 default)          |
| MCFG.base   | MCFG.n | UC    | PCIe ECAM window (from MCFG table) |

The first three are constants; MCFG comes from `src/kernel/acpi/mcfg.pdx`
which has already run by this point in the boot sequence (see
`kernel_main.pdx` around L277–L295 for the ACPI RSDP walk). For NVMe and
other PCI BARs, the driver's `_probe` function calls `platform_mmio_map`
itself once it has read the BAR from PCI config — this is the correct
locus of responsibility because the BAR value is device-specific and known
only after enumeration.

**Handler policy is UNCHANGED.** `handle_pf` (`core/int/exceptions.pdx` L125)
continues to panic on ring-0 #PF — a kernel-mode page fault to an unmapped
address is a bug, and masking it would hide the class of defects (bad
pointer dereferences, teardown races, ring-0 stack overflows) this handler
exists to surface. The invariant we replace it with is "every MMIO
touch is preceded by a `platform_mmio_map` call whose return value the
driver stores in a `_ctx.base` field it thereafter reads through" — that
invariant is checkable (grep for raw MMIO literals in driver code), which
a "silently skip faulting witness" arm is not.

## 3. Migration steps

Order matters — each step compiles and boots before the next lands.

1. **Land `platform_mmio_map`** as a new module `src/kernel/core/mm/mmio_map.pdx`,
   modelled on `fb_map_lfb`. Reserve `MMIO_VA_BASE = 0xFFFF_A800_0000_0000`
   (PML4[321]) and a `_mmio_va_next` bump-cursor `.bss` slot. Add a
   `MAP_HUGE`-branch that returns `pa_base` unchanged (identity-VA fallback
   for the boot huge-page window). No callers yet; module is dead code at
   this step. Build turns green with zero behavior change.

2. **Add `platform_map_early_mmio`** in `src/kernel/boot/mmio_init.pdx` with
   the static three-row manifest above (HPET/xAPIC/IOAPIC). Call it from
   `kernel_main_64` immediately after `pat_init_this_cpu`
   (`kernel_main.pdx` L138) and before the fb-console block at L157. On
   PVH/`-kernel` boots the three static rows collide with the boot huge-page
   map and take the "return pa_base" fast path — no behavior change; on
   UEFI/T14, the ranges are mapped genuinely into PML4[321]. The MCFG row is
   deferred to step 5.

3. **Convert HPET first** (`src/kernel/core/time/hpet.pdx`): replace the
   hard-coded `0xFED00000` at L51 and elsewhere with a load from a new
   `_hpet_ctx.base` slot that `hpet_init` populates from
   `platform_mmio_map(0xFED00000, 0x1000, MMIO_UC)`. Uncomment the
   `clock_read_ns_witness_call` in `witness/r30_platform.pdx` L6781 — this
   witness now passes on both q35 and T14. The cascade is: one file
   converted, one witness recovered, one boot-log fingerprint returns.

4. **Convert LAPIC MMIO fallback path** (`core/apic/eoi.pdx` L43,
   `core/apic/tpr.pdx` L42, `core/apic/self_ipi.pdx` L90/L103) and
   **IOAPIC** (`core/apic/ioapic.pdx` L87/L113, and the MADT-supplied bases
   in `core/apic/ioapic_route.pdx` L74). Each `mov rax, <const>` becomes a
   `mov rax, [rip + _apic_mmio_base]` or `_ioapic_mmio_base` load; those
   slots are populated by `platform_map_early_mmio` at boot. The x2APIC path
   is unchanged and continues to be the primary path on modern CPUs. Under
   TCG (no x2APIC), the MMIO fallback now reads/writes through a validated
   VA.

5. **Extend `platform_map_early_mmio`** to read `_mcfg_ctx.base` +
   `_mcfg_ctx.length` from `src/kernel/acpi/mcfg.pdx` and pass them through
   `platform_mmio_map`. Then convert PCI ECAM accessors in
   `src/kernel/core/pci/` to use the mapped VA. Every PCI-driver probe
   thereafter can read its own BARs.

6. **Convert NVMe** (`src/kernel/core/drivers/nvme*/` and any references in
   `src/kernel/boot/witness/pdxb_ahci_probe.pdx`, `r30_platform.pdx`
   L6633's `kind_nvme_io_queues_witness_call`): the driver's probe function
   now calls `platform_mmio_map(bar0_pa, bar0_size, MMIO_UC)` and stores
   the returned VA in its per-device context. Uncomment
   `kind_nvme_io_queues_witness_call`.

7. **Repeat the pattern** across the remaining R30/R31/R32/R33 witnesses
   that were disabled or that read MMIO via hard-coded PAs. Every step
   turns a `nop`ped witness back into a live one and adds one line of
   fingerprint to the boot log.

8. **Gate**: add a `tools/verify-no-raw-mmio.sh` grep — reject any
   `mov rax, 0xFE[C-F]?????` or `mov rdi, 0xFE[C-F]?????` literal in
   `src/kernel/core/` outside `src/kernel/core/mm/mmio_map.pdx`, HPET
   context init, and the four early-boot manifest rows. This is the
   enforcement mechanism that keeps the invariant "MMIO PA is opaque
   after registration" from drifting back over time.

## 4. What NOT to do

- **Do not weaken `handle_pf` into a witness-fail-and-skip arm.** A
  ring-0 #PF is either a bug (bad pointer, teardown race, stack overflow)
  or an unmapped MMIO touch; the second case is precisely what this design
  eliminates by construction. Preserve the halt so the first case still
  gets surfaced. The one legitimate softening — a
  `_boot_witness_active`-gated ring-0 death arm — is *belt and braces*,
  not a substitute for the mapping fix, and should be considered only if a
  future regression re-introduces raw MMIO literals faster than the grep
  gate can catch them.

- **Do not just tack more 1-GiB PDPT entries onto `boot_stub.S`.** Widening
  the identity map from 4 GiB to 16 GiB catches QEMU q35's fixed MMIO but
  does nothing for T14 G4's ACPI-discovered ranges above 16 GiB, nothing
  for PCI BARs allocated at 64-bit addresses (routine on real hardware),
  nothing for future IOMMU/CXL windows, and nothing for the memory-type
  problem (identity mapping is WB by default, which is *wrong* for MMIO —
  it will coalesce, reorder, and cache device register writes). The identity
  map is a bootstrap crutch, not a memory model.

- **Do not defer `r30_platform_run` to userspace.** The witnesses run at
  ring 0 for a reason: they exercise driver code paths that are ring-0
  only. Moving the witness harness to a userspace task collapses the
  substrate under test — a ring-3 process cannot exercise `apic_eoi`,
  `hpet_now_ns`, or `ioapic_program_redir` directly, only via syscalls
  whose own paths are what the witness is meant to prove.

- **Do not add per-witness "if PA in [3G,4G) skip" gates.** That is where
  the current design has already ended up (line 6781 of r30_platform.pdx),
  and the whole point of this memo is that gating cannot scale — every
  MMIO-touching witness needs its own gate, every driver adds new gates,
  and every gate is a witness silently not running. The definitive fix is
  a shared substrate the witnesses trust unconditionally.

- **Do not conflate the fix with reworking `_kernel_pml4_pa`.** The kernel
  PML4 is fine; we install into it. No CR3 flip, no new KPTI concerns —
  MMIO windows go in the kernel half (PML4[321]), which is copied into
  every user PGD by `kpti_build_user_pml4` (`core/mm/kpti.pdx`), so ring-3
  code doesn't see them and ring-0 code always does regardless of active
  CR3.

## 5. Success criterion

After the migration lands, a clean boot log (both `-kernel` PVH and
`-drive nvme`) contains, in order:

```
PAT INIT OK slot4=WC                              <- pat_init_this_cpu
PLATFORM MMIO EARLY OK n=4                        <- new: manifest mapped
HPET INIT OK freq=<n>                             <- HPET via _hpet_ctx.base
[... existing R14b/R15/R16 witness stream ...]
R30 CLOCK READ NS OK                              <- was #nop'd, now live
[... R30 platform stream, uninterrupted ...]
KIND_NVME_IO_QUEUES OK                            <- was #nop'd, now live
[... remaining R30/R31/R32/R33 witnesses ...]
INIT BOOT OK
```

No `EXC HALT` line. No `PF` fingerprint at kernel level. Every witness
that was previously commented-out with an MMIO-window rationale is now
active and passes. On T14 G4, the same log appears, differing only in the
`n=` count of `PLATFORM MMIO EARLY OK` (T14 has extra ACPI-discovered
IOAPICs) and in the ACPI table contents. The gate script
`tools/verify-no-raw-mmio.sh` returns zero. The comment at
`witness/r30_platform.pdx` L6776–L6780 is deleted, along with every other
"MMIO PA is outside the boot identity map" hedge in the tree.

The invariant this establishes: **the boot identity map is a
bootstrap-only artifact; after `platform_map_early_mmio` runs, no kernel
code depends on `identity_va(pa) == pa` for any MMIO address.** That
invariant is what makes T14 G4 first-light tractable, and it is what
keeps the QEMU smoke matrix from silently regressing when a new witness
adds a new hardware touch.
