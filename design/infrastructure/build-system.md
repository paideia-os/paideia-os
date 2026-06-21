# PaideiaOS — Build System

**Status:** Decided (in force as of 2026-06-20)
**Date:** 2026-06-20
**Scope:** How the PaideiaOS monorepo builds its kernel from `.pdx` sources using `paideia-as` as the sole toolchain. Covers submodule integration, the build orchestrator, the per-file compile/link pipeline, the linker script, and the walker-activation gate that constrains which surface kernel sources may use.

**Hard inputs:**
- `design/02-development-environment.md` §6.1 — monorepo decision (toolchain lives alongside the code it compiles).
- `design/02-development-environment.md` §8 — the older OCaml-era bootstrap plan; this document supersedes it on the paideia-as path.
- `design/infrastructure/github-org-and-repos.md` — `paideia-as` lives in its own repo under the `paideia-os` org; PaideiaOS consumes it as a submodule.
- `tools/paideia-as/design/toolchain/phase-transition-4.md` §2 — the walker-activation discipline that gates `paideia-as build` on per-walker readiness.
- `tools/paideia-as/design/toolchain/phase-4-implementation.md` m1-005/006, m6-001..003 — walker hookup milestones.

---

## 0. Decisions summary

| ID    | Decision                          | Choice                                                                     | Rationale                                                                                                                          |
|-------|-----------------------------------|----------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------|
| BS-D1 | paideia-as integration            | Git submodule at `tools/paideia-as/`                                       | Pillar 11 (research-driven) — atomic design+code commits; pins toolchain to a known commit per release; fresh clones reproduce.    |
| BS-D2 | Toolchain provenance              | Submodule binary only; no PATH lookup, no system install, no pinned release | Hermetic builds; one source of truth; no version skew between developer machines.                                                  |
| BS-D3 | Build orchestrator                | `tools/build.sh` (POSIX shell)                                             | Minimal dependency footprint for Phase 0; will be re-hosted in `.pdx` once self-hosting lands (Phase-2 target).                    |
| BS-D4 | Emit target                       | `paideia-as build --emit elf64` only                                       | QEMU `-kernel` accepts ELF64 directly; PE/COFF and PAX are out of scope for Phase 0.                                               |
| BS-D5 | Linker                            | GNU `ld` with `src/kernel/link.ld`                                         | Stable, reproducible, available in the Nix flake; no need for a custom linker until Phase 3.                                       |
| BS-D6 | Build artifact location           | `build/` at repo root (gitignored)                                         | Mirror of `src/kernel/` layout; one well-known path for CI, QEMU, and developers.                                                   |

---

## 1. The paideia-as submodule

- **Path:** `tools/paideia-as/`
- **Remote:** `https://github.com/paideia-os/paideia-as.git`
- **Pinned commit:** `v0.4.0` (Phase 4 closure — full Phase-4 surface parses; walker activation in progress).
- **Update protocol:** treat the submodule pointer like any other tracked file.

```sh
git submodule update --remote tools/paideia-as
git add tools/paideia-as
git commit -m "chore(toolchain): bump paideia-as to <new-sha>"
git push
```

- **Build of the toolchain itself:** performed once per developer machine inside the submodule tree.

```sh
cd tools/paideia-as
cargo build --release -p paideia-as
# produces tools/paideia-as/target/release/paideia-as
```

- **Why submodule (vs PATH lookup or pinned binary release):**
  - Pillar 11 demands atomic design + code commits; the submodule SHA *is* the toolchain version bound to each PaideiaOS commit.
  - A fresh clone (`git clone --recursive`) reproduces the kernel byte-for-byte without trusting the developer's `$PATH`.
  - A pinned binary release would require a second supply chain (releases page + checksums); the submodule subsumes both with one SHA.

---

## 2. The build chain

```
src/kernel/**/*.pdx
       │
       │  (per file, sorted for determinism)
       ▼
   paideia-as build --emit elf64  -->  build/**/*.o
                                          │
                                          ▼  (all .o gathered)
                       ld -nostdlib -T src/kernel/link.ld
                                          │
                                          ▼
                                  build/kernel.elf
                                          │
                                          ▼
                            qemu-system-x86_64 -kernel ...
```

Stage walk-through:

1. **Discover.** `tools/build.sh` runs `find src/kernel -name '*.pdx' | sort` — the sort guarantees the same link order on every machine, so the resulting ELF is bit-identical given the same toolchain SHA.
2. **Compile.** For each `.pdx`, invoke `tools/paideia-as/target/release/paideia-as build --emit elf64 -o build/<mirror>.o <file>`. The mirror path preserves the source tree under `build/`, so `src/kernel/boot/entry.pdx` becomes `build/boot/entry.o`.
3. **Link.** `ld -nostdlib -T src/kernel/link.ld -o build/kernel.elf $(find build -name '*.o' | sort)`. `-nostdlib` keeps libc and libgcc out; the kernel is self-contained.
4. **Boot.** `qemu-system-x86_64 -kernel build/kernel.elf -m 256M -serial stdio -nographic`. QEMU honours the ELF program headers and jumps to the entry symbol (`_start`) at `0x100000`.

---

## 3. The walker-activation gate

`paideia-as` v0.4.0 closed Phase 4 of the toolchain plan, but Phase 4 closure has two distinct meanings that must be kept separate:

- **Parsing closure:** every Phase-4 surface form (records, enums, generics, traits, borrowed references, stdlib types) is recognised by the parser and lowered into the IR.
- **Walker activation:** the elaborator's per-construct walkers (type-check, borrow-check, capability-check, effect-check) are wired into the full IR walk on a per-walker basis. Per `phase-transition-4.md` §2, `paideia-as build` gates on the relevant walker being **active**, not merely **implemented**.

The Phase-4 implementation plan (m1-005, m1-006 for the type/elab walker hookups; m6-001..003 for borrow walkers) ships walkers as unit-tested units first and activates them in the full IR walk incrementally. Until all Phase-4 walkers are active, **`paideia-as build` is conservative**: it accepts only the surface forms whose walkers are live.

**Consequence for PaideiaOS Phase 0:** kernel `.pdx` sources MUST restrict themselves to the Phase-1/2 lowest-common-denominator surface:

- `let`, `fn`, `lambda`, `match`
- raw pointers `*T`
- `unsafe` blocks for MMIO and inline asm

No records, no traits, no generics, no borrowed references in Phase-0 kernel code. This is the **LCD-surface discipline**, and it is enforced socially (review) and mechanically (the build will reject unsupported surface forms with a clear walker-not-active diagnostic from paideia-as). The discipline lifts file-by-file as walkers activate upstream; see `tools/paideia-as/design/toolchain/phase-4-implementation.md` for the activation schedule.

---

## 4. Linker script (`src/kernel/link.ld`)

The linker script is small and deliberately conservative for Phase 0:

- `OUTPUT_FORMAT(elf64-x86-64)` — matches the paideia-as emit target.
- `ENTRY(_start)` — QEMU `-kernel` uses the ELF entry to find the first instruction.
- `.text` starts at `0x100000` (1 MiB) — above the legacy BIOS/IVT region, the canonical multiboot load address.
- `.text._start` is placed first inside `.text` so the entry point is literally the first byte of the loaded image; this makes `objdump -d build/kernel.elf | head` an immediate sanity check.
- `.rodata`, `.data`, `.bss` are each aligned to 4 KiB so that page-table mappings (Phase 1) can grant per-section permissions without fragmentation.
- **Discards:** `.comment`, `.note*`, `.eh_frame*` — these are toolchain metadata with no runtime meaning for a freestanding kernel.

**Future.** When the long-mode transition lands (Phase 1), the kernel relocates to the higher half (base `0xFFFF_FFFF_8000_0000`) via a load-address / virtual-address split in the linker script. That change is out of scope for this document; see `design/infrastructure/boot-path.md` for the long-mode roadmap.

---

## 5. Outputs

`build/` is gitignored. Typical contents after a Phase-0 build:

- `build/boot/entry.o` — the bootstrap entry stub.
- `build/<additional>.o` — one object per `.pdx` as the kernel grows.
- `build/kernel.elf` — the linker output; the artifact QEMU loads.

`build/` is safe to delete at any time; `tools/build.sh` recreates it. CI treats `build/kernel.elf` as the single deliverable to upload as an artifact for downstream QEMU smoke jobs.

---

## 6. Forward links

- `design/infrastructure/boot-path.md` — boot mechanism (QEMU `-kernel` direct path now; UEFI deferred to Phase 2+).
- `design/infrastructure/first-milestone.md` — Phase-0 smoke (`hlt`-only kernel), Phase-1 banner over serial, capability-system roadmap.
- `design/02-development-environment.md` §8 — the OCaml-era toolchain bootstrap plan; superseded by this document on the paideia-as path but retained for historical context.
- `BUILDING.md` (repo root) — user-facing build instructions; this document is the design rationale, `BUILDING.md` is the recipe.
