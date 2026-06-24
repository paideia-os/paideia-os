# PaideiaOS

PaideiaOS is a clean-slate, research-grade microkernel operating system for
x86_64, written end-to-end in assembly through the in-house `paideia-as`
toolchain. It is designed for many-core Intel hardware from inception, treats
capabilities and effects as first-class kernel objects, and assumes a
post-quantum cryptographic baseline.

The project is a vehicle for sustained investigation into what a contemporary
operating system looks like when every legacy compromise is removed: no POSIX
surface, no portability layer, no retrofitted SMP, no classical-only crypto,
no untyped byte-stream shell. The codebase is the artifact; the `design/`
tree is the argument.

## Research thesis

- **A clean-slate x86_64-asm microkernel is tractable when the assembler is
  itself a research instrument.** `paideia-as` carries substructural typing,
  algebraic effect rows, ML-style functor modules, and elaborator reflection,
  so safety-by-construction is enforced at assembly time rather than imposed
  by a higher-level language layered on top.

- **Authority is expressed through unforgeable, derivable capabilities
  rather than ambient identity.** The kernel manages object-capabilities as
  the sole carrier of rights; derivation, revocation, and sealing are kernel
  primitives, not library conventions.

- **IPC must admit a formal deadlock-freedom argument.** PaideiaOS uses
  wait-free dataflow channels with mint-time enforcement of single-producer /
  single-consumer discipline, eliminating circular wait by construction
  rather than by runtime detection.

- **Post-quantum readiness is a construction property.** ML-KEM (FIPS 203),
  ML-DSA (FIPS 204), and SLH-DSA (FIPS 205) are designed into the trust root,
  attestation chain, and transport handshakes from the outset; classical
  primitives appear only inside hybrid constructions.

- **A terminal should query meaning, not parse text.** The shell operates on
  typed, schema-bearing records over session-typed channels, with embedded
  Datalog over the typed name-resolution graph. Unicode is native, not
  bolt-on.

## Architecture pillars

Eleven non-negotiable design pillars bound every decision in the tree. They
are stated and justified in `design/00-feature-inventory.md` and refined into
fifteen binding answers in `design/01-foundational-decisions.md`.

| Pillar | Where it lives in `design/` |
|---|---|
| x86_64 native, full ISA, no portability layer | `design/kernel/`, `design/toolchain/` |
| Multicore-efficient by design | `design/kernel/scheduler.md`, `design/kernel/work-stealing.md` |
| Strict microkernel | `design/00-feature-inventory.md` |
| Deadlock-free IPC | `design/ipc/deadlock-freedom-argument.md`, `design/ipc/wait-free-dataflow.md` |
| No backwards compatibility | `design/01-foundational-decisions.md` (Q9) |
| Hardened security, post-quantum where applicable | `design/security/algorithm-catalog.md`, `design/security/pq-trust-root.md` |
| Forward-looking networking | `design/network/` |
| Semantic terminal | `design/terminal/semantic-shell.md` |
| Hierarchical, hot-pluggable drivers | `design/drivers/` |
| Functional discipline in assembly | `design/toolchain/`, `design/capabilities/linearity-and-tags.md` |
| Research-driven | every document in `design/` cites its sources |

## What is observable today

PaideiaOS is pre-alpha. Built against the vendored `paideia-as` toolchain,
the kernel currently exercises the following on real and emulated hardware:

- Boots under QEMU through the PVH direct-kernel entry path
  (`design/infrastructure/boot-path.md`).
- Emits a banner over the 16550 UART (polling mode) on COM1.
- Mints, verifies, and invokes phase-1 capability descriptors with LAM-tagged
  handles and slab-backed allocation
  (`design/capabilities/phase1-api.md`).
- Enqueues and dequeues messages on single-producer / single-consumer IPC
  channels with mint-time SPSC enforcement
  (`design/ipc/phase1-api.md`).

Everything listed under "Roadmap" below is design-complete in `design/` but
not yet realized in code.

## Try it

Clone, build the toolchain, build the kernel, and launch under QEMU:

```sh
git clone --recursive https://github.com/paideia-os/paideia-os.git
cd paideia-os
git submodule update --init --recursive
(cd tools/paideia-as && cargo build --release -p paideia-as)
./tools/build.sh
./tools/run-qemu.sh
```

Exit QEMU with `Ctrl-A` then `X`. A smoke harness validates serial output
against a stored fingerprint:

```sh
./tools/run-smoke.sh
```

Full prerequisites (Rust, GNU `ld`, `qemu-system-x86_64`) and per-distro
installation notes are in `BUILDING.md`. A Nix flake at `nix/flake.nix`
provides a reproducible development shell.

## Project layout

```
src/kernel/           Kernel sources in .pdx (paideia-as assembly).
src/drivers/          Userspace driver servers.
design/               The canonical argument: ~150 documents organised by
                      subsystem (kernel, ipc, capabilities, security,
                      network, filesystem, terminal, drivers, runtime,
                      toolchain, infrastructure, audit, acpi, system).
tools/                Build orchestration (build.sh, run-qemu.sh,
                      run-smoke.sh) and the paideia-as submodule.
tests/                Smoke fixtures and serial-output fingerprints.
nix/                  flake.nix for the reproducible dev shell.
BUILDING.md           Detailed build and run instructions.
LICENSE               MIT.
```

## Companion projects

PaideiaOS co-evolves with a small constellation of auxiliary repositories
under the same organization:

- **`paideia-as`** — the custom x86_64 assembler used to build the kernel.
  Implemented in Rust, it provides substructural capability typing,
  algebraic effect rows, ML-style functor modules, SARIF diagnostics, LSP
  integration, and post-quantum hybrid signing of object files. Vendored
  here at `tools/paideia-as/` as a git submodule. The toolchain contract is
  specified in `design/infrastructure/build-system.md` and
  `design/toolchain/`.

## Roadmap

The kernel's design is largely complete on paper; the implementation walk is
long. Planned trajectory, in dependency order:

- Interrupt and exception dispatch (IDT, x2APIC, MSI/MSI-X routing to
  userspace handlers).
- Scheduling-context-based scheduler with per-core run queues, work-stealing,
  and NUMA-aware placement.
- Memory protection primitives: 4-level paging by default with 5-level
  opt-in, PCID/INVPCID, SMEP/SMAP, CET, and MPK/PKU.
- SMP bring-up and multicore-first synchronization primitives.
- Post-quantum trust root: TPM 2.0 measured boot, ML-KEM/ML-DSA hybrid
  handshakes, attestation chain.
- Userspace: root task, capability-mediated driver servers, the CoW
  filesystem, the user-space network stack, and the semantic shell.

No dates and no version commitments attach to this list. The order is fixed
by the dependency graph in `design/`; the pace is set by the substrate.

## Status and contributing

PaideiaOS is pre-alpha research software. It does not run user programs and
will not for some time. The most valuable contributions today are critiques
of, and additions to, the design documents under `design/`: new citations,
counter-examples, sharper invariants, and proofs.

Code contributions must conform to the relevant design document. If a
proposal requires deviating from a pillar in
`design/00-feature-inventory.md` or a decision in
`design/01-foundational-decisions.md`, the deviation is argued explicitly in
a new design note before any code is written.

Issues and pull requests are accepted at the project's GitHub repository.

## License

MIT. See `LICENSE`.
