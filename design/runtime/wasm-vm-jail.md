# PaideiaOS — WASM/VM Jail (Foreign Software Hosting)

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Architectural specification of the PaideiaOS jail for hosting foreign software (per Q9). Covers the two-tier execution model — WASM/WASI as the primary substrate, with a capability-gated VT-x VM mode as escape hatch — the capability mediation at the WASI host-function boundary, the thin VMM design for the VM path, integration with the semantic shell's foreign-command bridge, resource accounting, multi-jail isolation, and failure containment.

**Hard inputs (do not relitigate):**
- `design/00-feature-inventory.md` — U9 (virtualization VT-x); E10 (init/service supervisor).
- `design/01-foundational-decisions.md` — Q9 (no POSIX; WASM/VM jail for foreign software), Q5 (ACPICA is *not* in this jail — it has its own bubble), Q15 (max mitigations default).
- `design/02-development-environment.md` — fuzz targets include jail entry points.
- `design/toolchain/custom-assembler.md` — algebraic effects (Q-A3), functor modules (Q-A7), substructural lattice; `unsafe` blocks for any non-paideia-as code in the runtime.
- `design/ipc/wait-free-dataflow.md` — session-typed channels for jail-to-host communication.
- `design/capabilities/linearity-and-tags.md` — capability mediation at host-function boundary.
- `design/kernel/memory-model.md` — IOMMU isolation; memory caps for jail address spaces.
- `design/kernel/scheduler.md` — SC budgets per jail; `reserved_core_cap` not granted to jails.
- `design/security/pq-trust-root.md` — universal hybrid KEM for jail-to-network confidentiality.
- `design/drivers/framework.md` — jails don't talk to drivers directly; they consume class-driver services.
- `design/network/stack.md` — jails consume typed network channels (TCP/UDP/QUIC).
- `design/filesystem/cow-design.md` — jails consume typed file capabilities; no direct FS access.
- `design/terminal/semantic-shell.md` — the shell's foreign-command bridge dispatches WASM and VM commands to this jail.

---

## 0. Decisions summary

### 0.1 Inherited (already binding)

| Source | Constraint |
|---|---|
| Q9 | PaideiaOS native API is clean-slate. Foreign software runs in a jail. The jail mechanism is WASM- and/or VM-based. |
| Pillar 3 (microkernel) | The jail is userspace; kernel provides only IOMMU isolation and (for VM mode) VT-x management. |
| Pillar 6 (security) | Foreign code is untrusted; capability membrane is the safety boundary. |
| Pillar 5 (no legacy) | PaideiaOS native does not accumulate POSIX surface; the jail is the *containment* of POSIX, not its integration. |
| Q15 | Foreign code runs with default-max mitigations; the jail itself cannot hold `relax-mitigations`. |

### 0.2 New decisions in this document

| # | Choice | Source |
|---|---|---|
| JAIL-Q1 | Execution model: **tiered** — WASM/WASI is the primary path; VM mode is an audited capability-gated escape | User choice |
| JAIL-D1 | WASM engine | Port of upstream **wasmtime** (Bytecode Alliance reference implementation), pinned in Nix per dev-env §7.3. Cranelift as the JIT backend (vectorized for AVX-512 where present). |
| JAIL-D2 | WASI version | **WASI Preview 2** with the component model (the current standard at 2026); Preview 1 supported for legacy WASM binaries. |
| JAIL-D3 | Host function mediation | Every WASI host function is a paideia-as effect handler with capability check. The capability set delivered to a jail at start defines its authority; WASI calls beyond that authority return WASI errno values per the spec. |
| JAIL-D4 | VMM | A **thin custom VMM** (~10 kloc paideia-as) running VT-x guests. Not a port of QEMU; not a port of Cloud Hypervisor; designed under PaideiaOS discipline from first principles. Only the minimum hardware emulation needed for Linux guest boot + virtio devices. |
| JAIL-D5 | VM-mode capability | `vm_jail_cap` — a capability granted by the supervisor only for specific application registrations; each grant is audited; the grant is per-application, not per-user-session. |
| JAIL-D6 | Jail isolation | Per-application jail (each foreign command gets its own AS); no shared jail across applications. |
| JAIL-D7 | Resource accounting | Per-jail SC budget + memory budget + IO budget; the supervisor enforces; jails that exceed budgets are throttled or killed per policy. |
| JAIL-D8 | Network access for jails | A jail does *not* hold network capabilities by default; the supervisor mints minimal network access per declared need (e.g., a `curl` invocation gets a per-host outbound capability). |
| JAIL-D9 | FS access for jails | A jail does *not* hold FS capabilities by default; the shell's argument parser converts file-path arguments to file capabilities the supervisor mints with the minimum rights. |
| JAIL-D10 | Schema-typed boundary | Foreign command registration includes a typed schema annotation (per shell doc SH-D11/§12.3); the jail bridge converts pipeline records to/from the foreign-language form (argv/stdin for POSIX; WIT-typed for WASI). |
| JAIL-D11 | JIT vs interpretation | JIT by default (Cranelift); interpretation as opt-in for security-sensitive cases (e.g., AOT-compiled to paideia-as code for deterministic verification). |
| JAIL-D12 | Linux guest support | The VM mode's primary supported guest is **Linux** (Alpine Linux as the canonical minimal distribution; other distros user-supplied). The VMM does not bind to Linux semantically; any guest that boots from UEFI with virtio devices works. |
| JAIL-D13 | GPU and accelerator access from jails | Phase 1–2: not supported. Phase 3+: GPU access via a capability-mediated bridge through the GPU driver (per Q6's open-source-only stance); accelerator access likewise via class-driver services. |

### 0.3 Three meta-positions

1. **The jail is the containment of POSIX, not the integration.** PaideiaOS does not gain POSIX surface by hosting POSIX software in a jail. The native API remains capability-typed, effect-tracked, FP-disciplined. The jail's interior is a Linux-flavored userland (or a WASI-flavored one); the boundary is the capability membrane. A user of `curl` does not affect the rest of the system; a kernel CVE in the Linux guest does not affect PaideiaOS.

2. **WASM is the default; VM is the audited escape.** Most foreign software the user needs (Python scripts, Ruby programs, Node.js applications, WASI-compiled C programs) runs in the WASM path with no special privileges. The VM mode is for software that genuinely needs Linux: full GCC toolchain, browsers, proprietary applications without WASM ports. Each VM grant is a *security event* logged to audit; the supervisor's policy controls grants.

3. **The custom VMM is small.** A typical VMM ports decades of QEMU code (~2M loc) or builds on Linux's KVM userspace tooling. PaideiaOS's VMM is from-scratch and minimal — only enough to boot a Linux guest with virtio-blk (storage), virtio-net (network), virtio-console (terminal), and a virtio-RNG (entropy). No legacy devices (no VGA, no PS/2, no IDE). No ACPI in the guest beyond a minimal table set we generate. This keeps the VMM auditable and the attack surface bounded — the cost is that some software requiring legacy hardware emulation won't run, which is acceptable (such software is itself legacy).

---

## 1. Architectural overview

```
                  ┌─────────────────────────────────────────────────────────────────┐
                  │   Shell session (per terminal/semantic-shell.md)                  │
                  │                                                                    │
                  │   foreign-command bridge ──── shell-side schema conversion         │
                  └────────────────────┬─────────────────────────────────────────────┘
                                       │
                                       ▼
                  ┌─────────────────────────────────────────────────────────────────┐
                  │   Jail Supervisor process (paideia-as)                            │
                  │   - mints per-jail caps from the user's environment              │
                  │   - selects WASM or VM substrate based on command registry       │
                  │   - tracks active jails for resource accounting                  │
                  │   - audit-logs every jail start/stop                             │
                  └────────────────────┬─────────────────────────────────────────────┘
                                       │
            ┌──────────────────────────┼──────────────────────────────┐
            │  WASM/WASI substrate     │     VM substrate              │
            ▼                          ▼                                ▼
   ┌─────────────────────┐    ┌─────────────────────┐    ┌────────────────────────┐
   │ WASM jail process   │    │ WASM jail process   │    │ VM jail process       │
   │   - wasmtime engine │    │                     │    │   - thin VMM           │
   │   - WASI Pv2 impl   │    │                     │    │   - VT-x guest         │
   │   - host functions  │    │                     │    │   - virtio devices    │
   │     are effect      │    │                     │    │   - Linux guest        │
   │     handlers        │    │                     │    │   - guest kernel +     │
   │   - capability      │    │                     │    │     userland           │
   │     mediation       │    │                     │    │                        │
   └──────────┬──────────┘    └──────────┬──────────┘    └──────────┬─────────────┘
              │                          │                           │
              │ IPC channels with the host PaideiaOS services        │
              │ - typed file capabilities  - typed network channels   │
              │ - typed FS graph access    - typed shell stdin/stdout │
              ▼                          ▼                           ▼
   ┌─────────────────────────────────────────────────────────────────────────────┐
   │   Host services: FS, network stack, supervisor, audit log                   │
   │   (Jails access these only through minted capabilities, never directly.)    │
   └─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. The two tiers (JAIL-Q1)

### 2.1 WASM/WASI as primary

The default tier handles software compiled to WASI. The WASM module is loaded by the jail process; the runtime (wasmtime) JIT-compiles to native code; execution proceeds with capability mediation at every WASI host call.

Software that runs natively in WASM/WASI:
- Python (via wasi-python).
- Ruby (via Ruby.wasm).
- Node.js (via Node-WASI port).
- Lua, Tcl, Perl (various).
- Many C/C++ tools compiled via wasi-sdk (clang's WASI target).
- Rust binaries with `wasm32-wasi` target.
- Go binaries with `wasi` target.

This covers the dominant case for "I need to run external tools".

### 2.2 VM mode as escape

Software that cannot run in WASI (or runs poorly):
- Full GCC compiler driver (limited WASI support).
- Modern browsers (Firefox, Chrome — no WASI port currently).
- Proprietary applications (no WASM build).
- Software with low-level POSIX-specific needs (advanced process management, fork-heavy patterns).
- Linux-specific scientific software (CUDA, certain HPC libraries).

These run in a VT-x guest. The user must grant `vm_jail_cap` to the application; the grant is audited; the application runs in a Linux guest (Alpine by default) with virtio devices to communicate with the host PaideiaOS.

### 2.3 Choosing between tiers

The command registry's entry for each foreign command declares its substrate:

```toml
[command.curl]
substrate = "wasm"
binary = "/jail/wasm/curl/curl.wasm"
schema = { input = "none", output = "string" }

[command.firefox]
substrate = "vm"
binary = "/jail/vm/firefox/firefox.tar"
requires_capability = ["vm_jail_cap", "gpu_passthrough_cap"]
schema = { input = "none", output = "none", interactive = true }
```

The shell dispatches based on `substrate`; the jail supervisor enforces capability requirements.

---

## 3. WASM/WASI runtime (JAIL-D1, JAIL-D2)

### 3.1 wasmtime as the engine

PaideiaOS ports wasmtime (Bytecode Alliance reference implementation) under the C-runtime shim used by the ACPICA bubble (per `acpi/acpica-bubble.md` §3). wasmtime is written in Rust and compiles to a native binary; the port involves:

- **Stage 1 (phase 1–2)**: build wasmtime with the `wasi` feature; link against the C-runtime shim; treat as a regular foreign-component bundle in paideia-as.
- **Stage 2 (phase 3+)**: optionally compile wasmtime *to WASM itself* and run the WASM engine inside an outer WASM jail (research extension — self-hosted WASM engine).

Justification for porting rather than implementing: a clean-slate WASM engine is roughly 50–100 kloc of careful work; wasmtime is well-tested and the Bytecode Alliance's reference. The semantics-correctness argument for porting outweighs the FP-discipline argument for clean-slate.

### 3.2 WASI Preview 2 + Component Model

WASI Preview 2 (current standard as of 2026) introduces the *component model*: typed interfaces (`wit` interface description), structured types across module boundaries, and a clean async I/O story. PaideiaOS implements:

- **wasi-cli**: command-line execution (argv, stdin, stdout, stderr).
- **wasi-filesystem**: file operations against PaideiaOS-minted file caps.
- **wasi-sockets**: network operations against PaideiaOS network caps.
- **wasi-clocks**: real-time and monotonic clocks.
- **wasi-random**: cryptographic and pseudo-random numbers.
- **wasi-poll**: I/O multiplexing.
- **wasi-http** (Preview 2): HTTP client and server.

Preview 1 is supported for backward compatibility with older WASM binaries.

### 3.3 Capability mediation (JAIL-D3)

Every WASI host function is a paideia-as effect handler that:
1. Receives the WASI function name and arguments.
2. Translates arguments to PaideiaOS-typed values.
3. Checks the jail's capability set for the required capability.
4. Executes the underlying PaideiaOS service call.
5. Translates the result back to WASI form.
6. Returns to the WASM code.

Example: `wasi:filesystem/types.descriptor.read`:

```paideia-as
effect WasiFsRead {
  op handler(jail : JailCap, fd : Wasi.Fd, buf : Wasi.Buffer, len : u32)
            -> Wasi.Result<u32>
}

// implementation:
fn wasi_fs_read_impl(jail, fd, buf, len) =
  // 1. Look up the file capability associated with fd in the jail's table.
  let fc = jail.fd_table.lookup(fd)
  match fc with
  | None     -> return Wasi.errno(BAD_FD)
  | Some(cap) ->
      // 2. Verify the file cap allows reading.
      if not cap.rights.contains(fs_read):
          return Wasi.errno(NOT_CAPABLE)
      // 3. Perform the read via the FS server.
      let result = Fs.read(cap, buf.offset, len)
      // 4. Return.
      return Wasi.Result.ok(result.bytes_read)
```

The jail's `fd_table` maps WASI file descriptors to PaideiaOS file capabilities. New caps enter when the jail opens a file (via the supervisor's argument-parsing mediation); revoked caps invalidate their fds.

### 3.4 JIT and AOT

wasmtime's Cranelift backend JIT-compiles WASM to native x86_64 code at function entry (first-call). For security-sensitive jails, an AOT path is supported: the entire WASM module is compiled ahead of time to a paideia-as object; the jail then runs the AOT artifact with no JIT in process. The AOT artifact can be inspected, audited, and signed (via the PQ trust root).

Default: JIT. AOT is opt-in by command-registry entry.

### 3.5 Memory layout

A WASM jail's process AS contains:
- The WASM module's linear memory (typically up to 4 GiB; can be larger with Memory64 proposal).
- The JIT code cache.
- The wasmtime runtime structures.
- The host-function shim code.

WASM linear memory is backed by `Page2MCap`s from the jail's memory budget. Growth (`memory.grow`) requests are mediated by the supervisor's per-jail memory accounting.

### 3.6 Performance

WASM via Cranelift typically achieves 50–80% of native x86_64 performance for compute-bound workloads. PaideiaOS's host-function path adds ~50 ns per call (capability check + paideia-as effect dispatch). For I/O-bound code, the per-call overhead dominates; for compute-bound code, JIT quality dominates.

---

## 4. VM mode (JAIL-D4, JAIL-D12)

### 4.1 The thin VMM

The VMM (`paideia-vmm`) is a userspace process holding `vm_jail_cap`. It uses VT-x via the kernel's VMX exposure (per C18 / `kernel/scheduler.md`). The kernel provides:
- `VtxRootCap`: permission to enter VMX root mode (the VMM's authority).
- `VtxGuestSetupCap`: per-guest setup (EPT page tables, VMCS construction).

The VMM, in turn:
- Constructs the guest's EPT (Extended Page Table) from a memory cap pool.
- Sets up the guest's VMCS (VM Control Structure).
- Enters guest execution via `vmlaunch`.
- Handles VM exits (page faults, MMIO accesses, I/O instructions, hypercalls).
- Provides virtio-blk, virtio-net, virtio-console, virtio-rng to the guest.

### 4.2 Minimal device emulation

| Device | Type | Phase 1–2 | Phase 3+ |
|---|---|---|---|
| virtio-blk | storage | yes | yes |
| virtio-net | network | yes | yes |
| virtio-console | text I/O | yes | yes |
| virtio-rng | entropy | yes | yes |
| virtio-gpu | display | no | optional |
| virtio-input | keyboard/mouse | no | optional |
| virtio-fs | filesystem passthrough | no | optional |
| Local APIC | interrupt controller | yes (emulated) | yes |
| HPET | high-precision timer | yes | yes |
| ACPI minimal tables (DSDT/FADT/MADT) | platform tables | yes | yes |

No VGA, no PS/2, no IDE, no SATA, no PCIe configuration space, no USB, no audio, no legacy serial — modern PVH-equivalent boot only.

### 4.3 Guest boot

The guest boots via PVH (Para-Virtualized Hypercall): the VMM places the guest kernel at a known address, sets up the boot info structure, and jumps. Most Linux distros support PVH boot natively; the Alpine canonical distribution is built with PVH.

### 4.4 Linux as canonical guest

Alpine Linux (small, musl-based, well-maintained) is the default guest. Users can supply other distros (Debian-derived, Fedora, etc.) but the support level is "best effort"; Alpine is the tested target.

The Linux guest sees PaideiaOS as a hypervisor; the host PaideiaOS sees it as just another process. From the guest's perspective, it's running on what looks like a modern minimal VM.

### 4.5 Guest-to-host communication

The host bridges between the VM jail's virtio devices and PaideiaOS services:
- virtio-blk reads/writes are translated to FS-server operations on a file cap held by the jail.
- virtio-net packets traverse a tap-equivalent to the PaideiaOS network stack.
- virtio-console output flows to a typed channel; the shell renders it.
- virtio-rng entropy comes from PaideiaOS's RDSEED + jitter pool.

The jail does *not* see PaideiaOS-typed records directly; it sees POSIX-flavored I/O.

### 4.6 GPU passthrough (phase 3+)

For applications needing GPU (Firefox, machine-learning workloads), PCIe passthrough via VT-d is supported phase 3+. The host's GPU driver releases its device cap; the VMM remaps via VT-d. The user must grant `gpu_passthrough_cap`.

### 4.7 Memory layout

A VM jail's process AS contains:
- The VMM code.
- The guest's RAM (backed by `Page2MCap`s from the jail's memory budget).
- The EPT page tables.
- The VMCS for each vCPU.

The guest's physical addresses map via EPT to the VMM process's virtual addresses. The IOMMU constrains DMA from any passed-through device.

---

## 5. Bridge to PaideiaOS-native (JAIL-D8, JAIL-D9, JAIL-D10)

### 5.1 File access

A jail does not hold FS capabilities by default. Files are passed at jail start as arguments:

```
shell: curl --output ./report.pdf https://example.com/report
```

The shell's argument parser:
1. Recognizes `./report.pdf` as a file-write target.
2. Asks the supervisor to mint a `FileWriteCap` for that path with minimum rights.
3. Passes the cap to the jail at start.
4. The jail's WASI fd_table records (fd=1, cap=that_cap).
5. The `curl` WASM binary writes to fd=1; bytes flow through the WASI host function; the FS server commits.

### 5.2 Network access

Same pattern. Per-host or per-port capability is minted:

```
shell: curl https://example.com:443/page
```

The shell sees the URL; asks the supervisor for a `TcpConnectCap` for `example.com:443`. The jail uses the cap via wasi-sockets.

### 5.3 STDIN/STDOUT and pipeline records

The shell's foreign-command bridge converts:
- Inbound pipeline records to JSON (or another configured serialization) on stdin for POSIX-style jails.
- Outbound stdout text (or JSON if the command produces it) to typed pipeline records based on the registered output schema.

For WASI Preview 2 commands using the component-model interfaces, the conversion is type-direct: PaideiaOS records ↔ WIT-typed values; no string round-trip.

### 5.4 Schema annotation revisited

The shell's command registry (per shell SH-D5) carries schema annotations per foreign command. The jail bridge consults these to know:
- What input the command expects (none, stdin text, structured stdin, environment variables).
- What output the command produces (none, stdout text, structured stdout).
- What capabilities the command requires.
- The substrate (WASM or VM).

Without good schema annotations, foreign commands appear as opaque text producers/consumers. With them, foreign commands are first-class typed citizens in the semantic-shell pipeline.

---

## 6. Multi-jail and isolation (JAIL-D6)

### 6.1 Per-application jail

Each foreign command invocation gets a fresh jail process:
- Fresh AS.
- Fresh capability set (minted from the user's environment subset).
- Fresh file-descriptor table.
- Fresh resource budget.

No sharing between jails. Two simultaneous `curl` invocations are two separate jails.

### 6.2 Long-running jails

For interactive applications (`vim`, `firefox`), the jail persists for the application's lifetime. The jail's state (open files, network connections, etc.) is preserved across the lifetime.

### 6.3 Multi-jail interactions

If two jails need to interact (e.g., piping output from one to another), the interaction is via PaideiaOS-typed channels:
- The shell creates a typed channel.
- Both jails receive cap halves at start.
- Within each jail, the WASI bridge presents the channel as stdin/stdout to the WASM/Linux side.

Direct memory sharing between jails is not supported; if two foreign programs need shared memory, they must use the host's mediation (a file in PaideiaOS-typed shared memory).

### 6.4 Spy-resistance

The Q15 max-mitigations posture applies to jails: KPTI, IBPB, L1D-flush on every cross-AS switch. A jail cannot hold `relax-mitigations`. Side-channel attacks from one jail to another or to the host are constrained by the kernel's mitigation discipline.

---

## 7. Resource accounting and supervision (JAIL-D7)

### 7.1 Per-jail budgets

The supervisor sets per-jail:
- **SC budget**: scheduling-context budget per period. A jail cannot exceed.
- **Memory budget**: maximum AS size (linear memory for WASM; guest RAM for VM).
- **I/O budget**: maximum FS read/write bytes per second; network bytes per second.
- **Lifetime budget**: maximum wall-clock time (with renewal possible).

Defaults are policy-set; users can request more via the supervisor.

### 7.2 Enforcement

- SC budget: the scheduler enforces (per Q8 / `scheduler.md`).
- Memory budget: the supervisor refuses memory growth past the limit.
- I/O budget: the FS and network stacks check the budget on every operation; reject when exhausted.
- Lifetime budget: the supervisor sends `stop_request` at expiry.

### 7.3 Pressure response

A jail exceeding its memory budget receives `OutOfMemory` from WASI memory.grow or from guest VM operations; the jail's code handles it (most software handles OOM ungracefully but reliably exits, which is acceptable).

A jail exceeding its I/O budget receives `RateLimited` errors; the jail's code retries or fails.

### 7.4 Audit log

Every jail start, stop, capability check, capability denial, and budget violation is logged to the audit channel. Aggregate statistics support the supervisor's policy decisions.

---

## 8. Failure containment

### 8.1 WASM jail crash

A WASM module that traps (out-of-bounds memory access, illegal instruction, integer overflow with trap, stack overflow) raises a host-level signal:
1. wasmtime catches the trap.
2. The jail process exits with a documented exit code.
3. The supervisor logs the crash.
4. The shell receives `JailCrashed`; reports to user.
5. No effect on other jails, host services, or kernel.

### 8.2 VM jail crash

A guest kernel panic or unrecoverable VM exit:
1. The VMM receives the VM exit with the failure code.
2. The VMM logs the failure.
3. The VM jail process exits.
4. Same downstream as WASM crash.

### 8.3 Jail capability violations

If foreign code attempts an operation it lacks the capability for, the WASI host function returns the appropriate WASI errno (`PERM`, `NOTCAPABLE`). The foreign code handles per its language conventions (raise exception, return error, etc.). No system effect.

### 8.4 Restart policy

The jail's restart policy is per command:
- Most one-shot commands (`curl`, `grep`): no automatic restart; the user reruns if desired.
- Interactive applications (`vim`, `firefox`): user-controlled.
- Daemon-style foreign code (rare): the supervisor's policy may include automatic restart with cascade limits (per drivers framework's pattern).

---

## 9. Integration with the semantic shell

### 9.1 Foreign command execution path

```
user types:    curl https://example.com/api.json | from json | where status == "ok"

shell parses:  pipeline of [
                  Cmd("curl", args=["https://example.com/api.json"]),
                  Cmd("from", args=["json"]),
                  Cmd("where", args=[Lambda(status == "ok")])
               ]

shell type-checks: 
  - curl: substrate=wasm, output=string
  - from json: input=string, output=Record (untyped record stream)
  - where: input=Record, output=Record

shell asks supervisor: 
  - for curl: mint cap (TcpConnect to example.com:443, no FS access)
  - for from: no caps (pure transformation)
  - for where: no caps (pure transformation)

shell dispatches:
  - curl runs in WASM jail with the minted caps
  - from runs in-process (light command, lambda-evaluator)
  - where runs in-process

records flow:
  - curl outputs bytes
  - from json parses to records
  - where filters
  - shell renders
```

### 9.2 Long-running interactive jails

A user running `vim some_file.md`:
- vim runs in a VM jail (POSIX-heavy ncurses).
- The shell's terminal output is multiplexed to vim's virtio-console.
- The user's input is multiplexed to vim's stdin.
- vim sees a Linux pseudo-terminal; the shell sees a typed channel.
- Capability set: the file `some_file.md` has read+write minted; no other access.

When vim exits, the jail is destroyed; the file changes persist to the FS.

---

## 10. paideia-as implementation

### 10.1 Module layout

```
src/userspace/jail/
├── supervisor.s                # jail-specific supervisor extensions
├── registry.s                  # foreign-command registry
├── budget.s                    # resource budget enforcement
├── wasm/                       # WASM/WASI substrate
│   ├── jail.s                  # WASM jail process
│   ├── wasmtime_port/          # ported wasmtime (C runtime + Rust runtime shim)
│   ├── wasi_pv1/               # WASI Preview 1 implementations
│   ├── wasi_pv2/               # WASI Preview 2 implementations
│   ├── host_functions/         # capability-mediated host functions
│   └── effects.s
├── vm/                         # VM substrate
│   ├── vmm.s                   # the thin VMM
│   ├── vmx_boot.s              # VT-x setup
│   ├── ept.s                   # extended page tables
│   ├── vmcs.s                  # VM control structures
│   ├── exit_handler.s          # VM exit dispatch
│   ├── virtio_blk.s
│   ├── virtio_net.s
│   ├── virtio_console.s
│   ├── virtio_rng.s
│   ├── apic_emu.s
│   └── acpi_tables.s           # minimal ACPI tables generated for guest
└── bridge/                     # shell-side bridge (lives in shell process)
    ├── arg_parse.s             # converts shell args to caps
    ├── stdin_stdout.s          # text/record conversion
    └── component_bridge.s      # WIT-typed bridge for Preview 2 commands
```

### 10.2 Phase-1 vs. phase-2 split

Phase 1 (NASM bootstrap):
- No jail. Foreign software not supported on PaideiaOS phase 1.
- Bring-up uses only PaideiaOS-native tools.

Phase 2 (paideia-as coexistence):
- WASM jail comes online with wasmtime port + WASI Preview 1.
- Initial commands: WASI-compiled curl, basic POSIX tools.
- VM jail design specified but not implemented.

Phase 3+ (paideia-as canonical):
- VM jail implementation.
- WASI Preview 2 + component model.
- GPU passthrough.
- AOT compilation path.
- Self-hosted WASM engine experiment.

### 10.3 The wasmtime port

wasmtime is written in Rust. The port:
- Builds the Rust standard library against PaideiaOS's WASI implementation (yes, wasmtime itself becomes a WASI consumer when ported).
- Compiles via the Rust target `x86_64-unknown-paideia-native` (a new target we register).
- Links against the paideia-as C-runtime shim (similar to ACPICA).

This is a complex port. The benefit is a production-grade WASM engine without reinventing it.

### 10.4 The VMM size

Target: under 10 kloc of paideia-as. The VMM does only what's needed for Linux guest boot + virtio device support. Specifically *not* in scope:
- VFIO emulation (use VT-d directly).
- Snapshots (the guest can be checkpointed via VMCS state save, but snapshot/restore tooling deferred).
- Live migration (not needed; phase 3+ if pursued).
- Multi-vCPU complex topologies (single-socket only; arbitrary vCPU count supported).
- Nested virtualization (the guest cannot itself host VMs).

---

## 11. Performance considerations

| Metric | Budget | Substrate |
|---|---|---|
| WASM jail startup (cold) | ≤ 100 ms | bare-metal |
| WASM jail startup (warm AOT) | ≤ 10 ms | bare-metal |
| WASI host function call overhead | ≤ 50 ns | bare-metal |
| Cranelift JIT compilation rate | ≥ 50 MiB/s | bare-metal AVX-512 |
| WASM JIT'd code throughput vs native | ≥ 50% | bare-metal |
| VM jail startup (cold Linux boot) | ≤ 500 ms | bare-metal |
| VM-to-host hypercall overhead | ≤ 1 µs | bare-metal |
| virtio-net throughput | ≥ 10 Gbps | bare-metal |
| virtio-blk IOPS | ≥ 200K | bare-metal NVMe + virtio passthrough |
| Capability-check overhead per WASI call | ≤ 20 ns | bare-metal |

Aspirational; baselines come from `design/runtime/perf-baselines.md` (future).

---

## 12. Verification

### 12.1 WASI conformance

Run the upstream WASI testsuite against PaideiaOS's WASI implementation. Failures are PaideiaOS bugs.

### 12.2 wasmtime conformance

The ported wasmtime should pass the WebAssembly spec tests (the official wasm-spec test corpus).

### 12.3 Capability mediation tests

Per-WASI-function tests verify:
- Each host function checks the required capability.
- Missing-capability requests return the documented errno.
- Audit log records denial.

### 12.4 VM mode tests

Boot Alpine Linux guest; verify:
- Boot completes within budget.
- virtio devices function (filesystem mounts, network connects).
- Hypercall overhead within budget.
- Guest kernel panic is contained.

### 12.5 Fuzz testing

WASI host functions are fuzz targets. Malformed WASM modules are fuzz targets. The VMM's VM exit handler is a fuzz target. Per dev-env §9.5.

### 12.6 Adversarial jail tests

A "malicious" jail (deliberately exceeds capabilities, attempts to escape):
- Try to access capabilities not granted: must fail.
- Try to exhaust memory: must be throttled.
- Try to use unhandled WASI functions: must trap.
- Try to trigger speculative side channels: mitigated by Q15.

---

## 13. Open issues

| ID | Issue | Resolution |
|---|---|---|
| JAIL-O1 | wasmtime upstream commit pin and update cadence. | `design/runtime/wasmtime-tracking.md` (future) |
| JAIL-O2 | Rust target registration (`x86_64-unknown-paideia-native`) — what does the LLVM target spec look like? | `design/runtime/rust-target.md` (future) |
| JAIL-O3 | The WIT-typed component-model bridge — concrete conversion rules between PaideiaOS records and WIT types. | `design/runtime/wit-bridge.md` (future) |
| JAIL-O4 | VMM size audit — the 10 kloc target is realistic for the minimum device set; document actual count post-implementation. | `design/runtime/vmm-audit.md` (future) |
| JAIL-O5 | GPU passthrough authorization workflow — how does the user grant `gpu_passthrough_cap`? | `design/runtime/gpu-passthrough.md` (future) |
| JAIL-O6 | The shell command registry's foreign-command verification — every registered foreign command should be PQ-signed; the verification step. | `design/runtime/foreign-cmd-signing.md` (future) |
| JAIL-O7 | AOT compilation pipeline — the toolchain for ahead-of-time WASM compilation. | `design/runtime/aot.md` (future) |
| JAIL-O8 | Linux guest distro support beyond Alpine — Debian, Fedora; per-distro testing. | `design/runtime/guest-distros.md` (future) |
| JAIL-O9 | Performance baselines — first measurements drive `perf-baselines.md`. | `design/runtime/perf-baselines.md` (future) |
| JAIL-O10 | Multi-jail interaction — pipeline-record passing between jails; concrete channel semantics. | `design/runtime/multi-jail.md` (future) |
| JAIL-O11 | The audit-log entry format for jails — what's recorded per jail start/stop. | `design/audit/jail-records.md` (future) |
| JAIL-O12 | The interactive jail terminal multiplexing — how does ncurses-style I/O work? | `design/runtime/terminal-mux.md` (future) |

---

## 14. References

### 14.1 WebAssembly and WASI

- WebAssembly Specification, W3C / Bytecode Alliance, current revision.
- WASI Preview 2 specification, Bytecode Alliance.
- WASI Component Model proposal documentation.
- WebAssembly System Interface (WASI) IETF / W3C work.

### 14.2 wasmtime

- wasmtime: https://wasmtime.dev (informative; pin a commit in Nix).
- Cranelift code generation: https://github.com/bytecodealliance/wasmtime/tree/main/cranelift.

### 14.3 VT-x and virtualization

- Intel® 64 and IA-32 Architectures Software Developer's Manual, Vol. 3C chs. 23–33 (VMX).
- Intel® Virtualization Technology for Directed I/O (VT-d), rev. 4.1.
- *Xen Project Hypervisor Documentation* (informative; for virtio and PVH reference).

### 14.4 Linux guest

- Alpine Linux documentation.
- Linux PVH boot protocol documentation.
- virtio specification.

### 14.5 Microkernel virtualization

- Heiser, G., Andronick, J. *Modular and Compositional Approach to OS Verification*. (Microkernel + virtualization research.)
- Genode OS Framework virtualization documentation (informative; comparable approach).

### 14.6 Capability-based foreign-code hosting

- Wasm/WASI capability discipline papers (WebAssembly community).

---

*End of document.*
