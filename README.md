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
  primitives, not library conventions. The tree currently defines ~200
  `KIND_*` derived capabilities spanning drivers, IPC, memory, GPU,
  networking, storage, and user identity.

- **IPC must admit a formal deadlock-freedom argument.** PaideiaOS uses
  wait-free dataflow channels with mint-time enforcement of single-producer /
  single-consumer discipline, eliminating circular wait by construction
  rather than by runtime detection.

- **Post-quantum readiness is a construction property.** ML-KEM (FIPS 203),
  ML-DSA (FIPS 204), and SLH-DSA (FIPS 205) are designed into the trust root,
  attestation chain, transport handshakes, driver-signature keyring, and
  per-user identity from the outset; classical primitives appear only inside
  hybrid constructions.

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

PaideiaOS is pre-alpha but no longer thin. The kernel now boots under QEMU
through the PVH direct-kernel entry path
(`design/infrastructure/boot-path.md`), completes the R14b higher-half
transition with KPTI, brings up SMP, mounts tmpfs, launches init, runs a
POSIX-shaped shell, executes `exit`, reaps the shell, and shuts down cleanly.
Zero witness-level FAILs across the R32–R44 substrate.

The following subsystems have code landed and gated by their witnesses in
`src/kernel/boot/witness/`:

**Boot and core (R14b–R20b).** Higher-half execution, KPTI, IPI, IDT/GDT,
per-CPU state, x2APIC, MSI/MSI-X routing, capability system with LAM-tagged
handles + slab allocation, wait-free SPSC IPC with mint-time enforcement,
work-stealing scheduler, ring-3 dispatch, task pool, VFS + tmpfs, syscalls
(`sys_open` / `close` / `read` / `write` / `dup2` / `fork` / `exec` / `wait`
/ `exit` + `ipc_send` / `recv` / `reply` / `svc_lookup` + FD inherit +
`FD_CLOEXEC`), UART RX, TTY line editor, init + shell (fork/exec, `cd`, path
resolution, multi-command), and the userspace-server substrate (endpoint
caps, `svc_broker`, payload arena, frame headers, IPC broker, loader
`init_caps` + `seed_caps`).

**Driver lifecycle (R29–R31).** Registry v2, PQ-signed keyring with dual-sig
verification, cascade restart, chaos harness, backlight, battery, EC event
demux, hotkey routing, cooling policy, thermal envelope.

**HID + audio + USB (R32–R34).** I2C-HID + gesture stack (two-finger scroll,
pinch, kinetic, swipe); Intel HDA with ALC287 codec init, SOF, PCM,
`KIND_AUDIO_CTRL`, `KIND_PCM_STREAM`, `KIND_AUDIO_ROUTE`; full USB stack
(`KIND_USB_DEVICE` / `HUB` / `INTERFACE` / `ENDPOINT`, xHCI, hub topology,
MSC BOT/UAS/SCSI, USB HID for keyboard/mouse/gamepad, isochronous streams,
`KIND_FP_SENSOR` with Goodix + Synaptics fingerprint drivers).

**Thunderbolt + display + GPU (R35–R37).** Thunderbolt 4 with `KIND_TB_DOMAIN`,
NHI, CM rings, `KIND_TB_ROUTE`, PCIe/DP/USB3 tunnels, DMA attestation, IOMMU
consent, security policy cascade, software CM, tunnel arbiter, DP DDI shim,
USB-PD, DP alt-mode; Intel Iris Xe display (`KIND_DISPLAY_ENGINE`, EDID,
`KIND_DISPLAY_OUTPUT`, `KIND_MODESET_TXN`, `KIND_DISPLAY_MODE`, atomic
commit, primary / overlay / cursor planes); GPU execution (`KIND_GPU_BO`,
GuC firmware, PPGTT, `KIND_GPU_VM`, `KIND_GPU_CONTEXT`, execlists,
`KIND_GPU_SUBMIT`, GuC submit, batch builder, GT fence, HuC, VCS engine).

**Wireless + camera (R38–R40).** Wi-Fi AX211 (probe, firmware load,
`KIND_WIFI_PHY` / `VIF` / `SCAN_TXN` / `KEY`, WPA3 SAE, WPA 4-way, HE MCS,
roaming, rekey); Bluetooth over CNVi (`KIND_BT_ADAPTER` / `HCI_CHANNEL` /
`L2CAP_CHANNEL` / `PAIRING`, ATT, `KIND_BT_GATT_CONNECTION`, GATT, LE Secure
Connections pairing, A2DP + RTX, HFP, BT HID, LE audio); IPU6 camera + CSI
(`KIND_CSI_CAMERA`, sensor init, IPU6 pipeline); WWAN modem
(`KIND_MBIM_SESSION`).

**Terminal, filesystem, VMD, users (R41–R48).** Semantic terminal — lexer,
parser, type system, engine, sources, resultset, plot, layout, palette, fb
frontend, line editor, pager, recovery, session log; PdxFS v1 with
refcounted CoW, GC, WAL, journal fence + replay + checksum, snapshot
create / mount-ro / diff / prune, upgrade v1 + dry-run, lite reader, fs
channel, NVMe write path, durability + concurrent-stress witnesses;
semantic-terminal GUI (shell, layout, theme, Vello, charts, scroll, IME,
a11y, keyboard-nav) with HDR (BT.2020) and presentation-time feedback; VMD
PCI substrate (`KIND_VMD_ENDPOINT`, endpoint enumeration, virtual root
complex, MSI-X remap, hotplug, NVMe-over-VMD, per-endpoint IOMMU domain);
user management (`KIND_USER` cap tree, `.pdxuser` records, `.identity/`
subtree with sealed `user_sk`, first-boot founder provisioning,
`user_supervisor` process, audit journal, `elevate` protocol).

**Boot presentation (R49).** Test / release build modes split via
`PAIDEIA_BUILD_MODE`, gating `klog` drain and `uart_puts`; `Present` module
for the release banner.

**GUI stack (G1–G6).** Display timeline + VRR (`KIND_DISPLAY_TIMELINE`,
`KIND_VRR_RANGE`, explicit-sync enforcement); direct-scanout leases with
tearing-free VRR (`KIND_SCANOUT_LEASE`); Vulkan-analogue swapchain +
presentation timing (`KIND_VK_SURFACE`, `KIND_VK_SWAPCHAIN_IMAGE`,
`VK_KHR_present_wait/id`, `VK_EXT_swapchain_maintenance1`); Vello
vector-scene render (`KIND_VELLO_SCENE`, `KIND_VELLO_RENDERER`, stroke /
fill / blend, CPU fallback, gradients, blur, tile coarsening); text + fonts
(`KIND_FONT_ATLAS`, `KIND_TEXT_SHAPE`, SDF/MSDF, HarfBuzz-analogue shaper,
sub-pixel positioning, color emoji, BiDi UAX #9, Indic clustering); color
management (`KIND_COLOR_PROFILE`, CICP parser, ICC v4, GPU color conversion,
EOTF/OETF PQ + HLG + DV, scRGB-linear fp16).

Thirteen hardware-smoke tasks are D7-per-convention (design-complete,
awaiting real Thinkpad T14 G4 execution); their placeholders and fingerprint
files live under `tests/kernel/**/hw_smoke_*` and `tools/hw-smoke-*.md`.

`design/STATUS.md` tracks per-milestone completion; per-round retrospectives
live under `design/round-retrospectives/`.

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

Exit QEMU with `Ctrl-A` then `X`. The hero smoke boots to shell, injects
`exit`, reaps the shell, and shuts down cleanly, asserting the ordered
fingerprint:

```sh
./tools/run-smoke.sh boot_r17_shell_shutdown
```

Twenty-four boot modes are dispatched from the same script (`boot_min`,
`boot_banner`, `boot_r14b_kpti`, `boot_r15_ring3`, `boot_r17_init`,
`boot_smp`, `boot_r31_spawn_pair`, `boot_panic`, `boot_release`, …); see
`./tools/run-smoke.sh --help` (or the header comment) for the full matrix.

Full prerequisites (Rust, GNU `ld`, `qemu-system-x86_64`) and per-distro
installation notes are in `BUILDING.md`. A Nix flake at `nix/flake.nix`
provides a reproducible development shell. Note that PaideiaOS deliberately
does not use CI: verification is local-only via `tools/run-smoke.sh` and the
pre-push hook.

## Project layout

```
src/kernel/           Kernel sources in .pdx (paideia-as assembly),
                      ~850 files organised by subsystem
                      (boot, core, acpi, apic, cap, cpu, driver,
                       drivers, fs, input, iommu, ipc, mm, net,
                       pci, policy, sched, semterm, smp, syscall,
                       thread, timer, tty, uart, user, ...).
tests/kernel/         Per-subsystem witnesses and synth harnesses;
                      ~450 .pdx files.
tools/                Build orchestration (build.sh with ~40+
                      confinement gates + audit passes,
                      run-qemu.sh, run-smoke.sh with 24-mode boot
                      matrix, hw-smoke-*.md fingerprint capture
                      recipes) and the paideia-as submodule.
design/               The canonical argument: ~550 documents across
                      31 subsystem directories (kernel, ipc,
                      capabilities, security, network, filesystem,
                      terminal, drivers, hardware, runtime, toolchain,
                      infrastructure, audit, acpi, system, user,
                      tooling, roadmap, architecture, milestones,
                      round-retrospectives, ...).
nix/                  flake.nix for the reproducible dev shell.
BUILDING.md           Detailed build and run instructions.
STATUS.md             Per-milestone implementation state.
LICENSE               MIT.
```

## Key design documents

- `design/00-feature-inventory.md` — the eleven pillars, justified.
- `design/01-foundational-decisions.md` — the fifteen binding answers that
  operationalize the pillars.
- `design/architecture/next-wave-derived-kinds.md` — the catalogue of
  `KIND_*` capabilities that structure every subsystem.
- `design/roadmap/next-wave-synthesis.md` — the 24-round unified roadmap
  (R29–R40 driver axis, G1–G12 GUI axis).
- `design/tooling/plan.md` — the ~95-tool userland ecosystem, one repo per
  tool, and the `pkg` package manager.
- `design/user/model.md` — the identity, authentication, and delegation
  model.
- `design/ipc/deadlock-freedom-argument.md` — the SPSC-at-mint proof
  sketch.
- `design/security/pq-trust-root.md` — the ML-KEM / ML-DSA / SLH-DSA trust
  root and the hybrid rollout.

## Roadmap

The driver + GUI substrate (R29–R49 + G1–G6) is landed. Forward work, in
dependency order, is captured in `design/roadmap/next-wave-synthesis.md`:

- Real Thinkpad T14 G4 execution for the thirteen D7-per-convention
  hardware smokes.
- G7–G12 — compositor protocol freeze, input server split, accessibility
  tree, unified IME, presentation-time feedback loop hardening, and the
  recovery-console reserved-plane invariant.
- The ~95-tool userland ecosystem — one repo per tool under the
  `paideia-os` GitHub organization, first slice being `pkg` + coreutils
  bootstrap (`ls`, `cat`, `cp`, `mv`, `rm`, `mkdir`, `find`, `grep`,
  `less`, `doc`, and a primitive editor).
- Networking bring-up past R27: TCP + TLS 1.3 with hybrid ML-KEM.
- Multi-user, multi-session refinements on top of R48's identity substrate.

No dates and no version commitments attach to this list. The order is fixed
by the dependency graph in `design/`; the pace is set by the substrate.

## Companion projects

PaideiaOS co-evolves with a small constellation of auxiliary repositories
under the same GitHub organization:

- **`paideia-as`** — the custom x86_64 assembler used to build the kernel.
  Implemented in Rust, it provides substructural capability typing,
  algebraic effect rows, ML-style functor modules, SARIF diagnostics, LSP
  integration, and post-quantum hybrid signing of object files. Vendored
  here at `tools/paideia-as/` as a git submodule. Contract at
  `design/infrastructure/build-system.md` and `design/toolchain/`.
- **Userland tool repos (planned)** — the ~95 tools from
  `design/tooling/plan.md`, each in its own repository under
  `github.com/paideia-os/<name>` (P0 first slice: `pkg`, `ls`, `cat`,
  `cp`, `mv`, `rm`, `mkdir`, `find`, `grep`, `less`, `doc`, editor). All
  MIT.

## Status and contributing

PaideiaOS is pre-alpha research software. The kernel boots to shell and
shuts down cleanly under QEMU, and the driver + GUI substrate compiles and
witnesses; the tree does not yet run user-authored programs on real
hardware. The most valuable contributions today are critiques of, and
additions to, the design documents under `design/`: new citations,
counter-examples, sharper invariants, and proofs.

Code contributions must conform to the relevant design document and pass
the ~40 confinement gates in `tools/build.sh` (mutation-marker gate,
cap-descriptor-confine gate, cap-stride gate, file-id-hardcodes gate,
no-frame-forbidden gate, and their peers). If a proposal requires
deviating from a pillar in `design/00-feature-inventory.md` or a decision
in `design/01-foundational-decisions.md`, the deviation is argued
explicitly in a new design note before any code is written.

Autonomous work in this tree follows a two-agent softarch (architect +
implement) then debugger (test + fix) loop, running continuously across
open issues and milestones; see the memory notes prefixed
`feedback_paideia_os_*` for the exact discipline.

Issues and pull requests are accepted at the project's GitHub repository.

## License

MIT. See `LICENSE`.
