# PaideiaOS

A research-grade, clean-slate x86_64 microkernel operating system, written entirely
in assembly via the in-house `paideia-as` toolchain.

## Status

Bootstrap phase (Phase-0). The kernel skeleton and build chain are in place; the
`paideia-as` v0.4.0 substrate is complete and vendored as a submodule. The current
kernel entry point halts immediately after boot. The next milestone is the first
observable kernel behaviour: long-mode entry plus a UART banner over the serial
console.

## Project pillars

1. **x86_64 native, full ISA, no portability layer.**
2. **Multicore-efficient by design.**
3. **Strict microkernel.**
4. **Deadlock-free IPC.**
5. **No backwards compatibility.**
6. **Hardened security, post-quantum where applicable.**
7. **Forward-looking networking.**
8. **Semantic terminal.**
9. **Hierarchical, hot-pluggable drivers.**
10. **Functional discipline in assembly.**
11. **Research-driven.**

## Getting started

Clone the repository with submodules:

```sh
git clone --recursive https://github.com/paideia-os/paideia-os.git
cd paideia-os
```

Full build, run, and toolchain-setup instructions: `BUILDING.md`.

## Repository layout

```
design/            — All architectural documents (155 files, organised by subsystem).
src/kernel/        — Kernel source in .pdx (paideia-as assembly).
src/userspace/     — Userspace servers (Phase-3+).
tools/             — Build orchestration + paideia-as submodule.
tests/             — Smoke tests + regression fixtures.
nix/               — Reproducible dev environment (flake.nix).
BUILDING.md        — Build + run instructions.
LICENSE            — MIT.
```

## The paideia-as toolchain

PaideiaOS uses `paideia-as`, an in-house custom assembler with built-in substructural
typing (linear / affine / ordered capabilities), algebraic effect rows, post-quantum
hybrid signing, and SARIF/LSP integration. The toolchain is at v0.4.0 (Phase 4
substrate complete; see `tools/paideia-as/CHANGELOG.md` for the per-phase release
notes). It lives in a sibling repo at `github.com/paideia-os/paideia-as` and is
included here as a git submodule.

## Design philosophy and research grounding

Every design decision in PaideiaOS cites recent literature (≥ 2015 preferred), an
Internet RFC, an Intel SDM reference, or prior-art system documentation. The
`design/` directory is the canonical source of truth; code commits are subordinate
to (and must conform to) the design documents. See `design/01-foundational-decisions.md`
for the 15 binding decisions (Q1–Q15) that bound all subsequent work.

## License and contributing

- License: MIT (see `LICENSE`).
- Contributions: per `design/02-development-environment.md` §12 (contributor workflow).
  Issues and PRs at `github.com/paideia-os/paideia-os`.

## Pointers

| Document | Purpose |
|---|---|
| `BUILDING.md` | Build + run instructions. |
| `design/00-feature-inventory.md` | Four-tier feature catalogue + project pillars. |
| `design/01-foundational-decisions.md` | The 15 binding Q-decisions. |
| `design/02-development-environment.md` | Dev environment + toolchain + CI. |
| `design/infrastructure/build-system.md` | Toolchain contract. |
| `design/infrastructure/boot-path.md` | Boot mechanism (QEMU `-kernel` today; UEFI deferred). |
| `design/infrastructure/first-milestone.md` | Phase-0 + Phase-1 + Phase-2 plan. |
| `tools/paideia-as/` | Custom assembler submodule (v0.4.0+). |
