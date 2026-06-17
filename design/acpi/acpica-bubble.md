# PaideiaOS — ACPICA Userspace Capability Bubble

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Architectural specification of how PaideiaOS hosts Intel's ACPICA reference implementation inside a capability-bounded userspace process — the "bubble" — to handle ACPI table interpretation, AML execution, power/thermal/PCIe-hotplug events, and vendor-firmware quirks. Resolves the engineering details of Q5 ("Port ACPICA into a sandboxed userspace capability bubble") and dev-env open issue PQ-O4-equivalent for ACPI handling.

**Hard inputs (do not relitigate):**
- `design/00-feature-inventory.md` — U1 (ACPI subsystem), U2 (power management), U12 (sensors); C8 (interrupt dispatch); E10 (init/service supervisor).
- `design/01-foundational-decisions.md` — Q5 (ACPICA-in-bubble, not clean-slate AML interpreter), Q9 (no POSIX; WASM jail for *other* foreign software), Q14 (hard restart default; opt-in handoff).
- `design/02-development-environment.md` — ACPICA tooling pinned in Nix; CI lanes include ACPI table fuzz (§9.5).
- `design/toolchain/custom-assembler.md` — substructural lattice, effects (Q-A3), functor modules.
- `design/ipc/wait-free-dataflow.md` — wait-free dataflow primitive is how the bubble talks to drivers and the supervisor.
- `design/capabilities/linearity-and-tags.md` — kind-tagged capabilities; the bubble holds specific MMIO, port, and IRQ capabilities.
- `design/kernel/memory-model.md` — `MmioMemCap` derived kind; per-CPU NUMA direct map.
- `design/kernel/scheduler.md` — `reserved_core_cap`; SC donation; soft RT.
- `design/security/pq-trust-root.md` — measured boot covers ACPI tables; PCR extension chain.

---

## 0. Decisions summary

### 0.1 Inherited (already binding)

| Source | Constraint |
|---|---|
| Q5 | ACPICA runs in a sandboxed userspace capability bubble — not in the kernel, not reimplemented from scratch. |
| Q9 | The WASM/VM jail is for POSIX-foreign software; the ACPICA bubble is *not* hosted by the WASM jail. |
| Pillar 3 (microkernel) | ACPICA must not be in the kernel; the kernel only routes events to the bubble. |
| C11 / measured boot | ACPI tables are measured into PCR-1 by the UEFI firmware; the boot chain's trust extends to the tables PaideiaOS receives. |
| AML standard | AML is ACPI's Turing-complete bytecode; vendor firmware emits motherboard-specific AML. ACPICA carries 25 years of vendor-quirk workarounds. |

### 0.2 New decisions in this document (all taken without questionnaire, with explicit rationale)

| # | Choice | Rationale |
|---|---|---|
| AC-D1 | Hosting form | Regular userspace process behind a capability membrane (the "bubble"); *not* the WASM jail. The WASM jail targets POSIX-foreign software with rich runtimes; ACPICA's OSL was *designed* for direct hosting on a custom OS layer. |
| AC-D2 | The OSL is the capability membrane | Every ACPICA → outside-world call goes through the OS Services Layer (OSL); each OSL function maps to a specific paideia-as effect + capability. ACPICA holds *only* the capabilities the bubble was minted with; the OSL is the gate. |
| AC-D3 | AML interpreter authority | AML actions are bounded by what the OSL exposes; no inner sandbox. AML cannot escape the OSL by construction — the AML interpreter only invokes OSL functions, which are capability-checked. |
| AC-D4 | ACPI table provenance | Trust through measured boot (PCR-1 covers the RSDP and key tables); sanity-check on parse (size, range, content invariants); allow boot-time user DSDT override for development/debugging. |
| AC-D5 | Number of bubbles | One bubble per PaideiaOS instance. ACPI is fundamentally a global abstraction; multi-bubble adds coordination cost without benefit. |
| AC-D6 | Supervisor/bubble division of labor | The supervisor owns *policy* (when to suspend, P-state targets, thermal thresholds); ACPICA executes (evaluates AML methods on request). |
| AC-D7 | Driver/bubble communication | The wait-free dataflow IPC primitive: ACPICA bubble holds session-typed channels to driver servers; events (PCIe hot-plug, thermal alerts, button presses) flow through these channels. |
| AC-D8 | Phase-1 fallback | Phase 1 ships a minimal MADT + MCFG + FADT parser hardcoded in NASM (~2000 LOC) for kernel boot only; no AML interpretation. Phase 2 brings up the full ACPICA bubble. |
| AC-D9 | C runtime shim | Smallest possible: malloc/free (slab over a memory cap), mutex (paideia-as capability-based lock), time (TSC + ACPI timer), basic logging (audit channel write). No file I/O, no networking, no signals, no stdio. |
| AC-D10 | ACPICA upstream tracking | ACPICA is pinned in Nix per `02-development-environment.md` §7.3; vendor-quirk workarounds inherit from Intel's upstream catalog; PaideiaOS-specific patches are minimal and held in a project patch series. |

### 0.3 Two meta-positions

1. **ACPICA is a localized impurity, by design.** ACPICA is ~150 kloc of C with its own style, conventions, and historical workarounds. Hosting it in PaideiaOS means accepting a C-runtime corner of the project that does not follow paideia-as conventions. This was the explicit Q5 trade-off: the alternative — reimplementing AML interpretation from scratch under paideia-as discipline — is years of work chasing vendor quirks ACPICA already handles. The bubble is the smallest possible containment of the impurity.

2. **The OSL is the choke point.** Every interaction between ACPICA and the rest of PaideiaOS goes through the OS Services Layer. By implementing the OSL as a paideia-as effect handler with capability checks, the bubble's authority is *exactly* the OSL's permitted operations — nothing more. No AML method, no matter how creative, can affect the system beyond what the OSL allows. The OSL is therefore the central security artifact; its design is the central engineering work.

---

## 1. Architectural overview

```
                       ┌────────────────────────────────────────────────────┐
                       │   ACPICA Bubble (userspace process)                  │
                       │                                                      │
                       │  ┌────────────────────────────────────────────────┐ │
                       │  │   ACPICA codebase (C, ~150 kloc upstream)       │ │
                       │  │   - Table loader, parser                       │ │
                       │  │   - AML interpreter                            │ │
                       │  │   - Namespace manager                          │ │
                       │  │   - Event manager (GPE / fixed events)         │ │
                       │  │   - Vendor-quirk workaround corpus              │ │
                       │  └────────────────────┬───────────────────────────┘ │
                       │                       │ OS Services Layer (OSL) calls│
                       │                       ▼                              │
                       │  ┌────────────────────────────────────────────────┐ │
                       │  │   OSL bridge (paideia-as)                       │ │
                       │  │   - AcpiOsMap / Unmap → MmioMemCap operations  │ │
                       │  │   - AcpiOsReadPort / WritePort → port-cap ops  │ │
                       │  │   - AcpiOsInstallInterruptHandler → IRQ-cap   │ │
                       │  │   - AcpiOsAllocate → bubble heap (slab)       │ │
                       │  │   - AcpiOsCreateMutex → cap-based lock         │ │
                       │  │   - AcpiOsGetTimer → TSC reading              │ │
                       │  │   - AcpiOsPrintf → audit-channel write        │ │
                       │  │   ...                                          │ │
                       │  └────────────────────┬───────────────────────────┘ │
                       │                       │                              │
                       │  ┌────────────────────▼───────────────────────────┐ │
                       │  │   C runtime shim (paideia-as)                  │ │
                       │  │   - malloc / free / realloc (slab)             │ │
                       │  │   - memcpy / memset / strcmp                   │ │
                       │  │   - assert (→ effect: panic)                   │ │
                       │  │   - setjmp / longjmp (limited use)             │ │
                       │  └────────────────────────────────────────────────┘ │
                       └─────────────────────────────────────────────────────┘
                                              │
                                              │ wait-free dataflow IPC
                       ┌──────────────────────┴──────────────────────────┐
                       │                                                  │
                       ▼                                                  ▼
        ┌──────────────────────────────────┐         ┌────────────────────────────────┐
        │  Supervisor                       │         │  Driver servers (PCIe, USB,    │
        │  - policy decisions               │         │  audio, GPU, thermal sensors,  │
        │  - power state transitions        │         │  battery, etc.)                │
        │  - audit log writes               │         │  - receive hot-plug events     │
        │  - revocation on bubble crash     │         │  - receive thermal alerts      │
        └──────────────────────────────────┘         │  - submit power-state requests  │
                                                       └────────────────────────────────┘
                                              │
                                              │ event injection (IPI / cap)
                       ┌──────────────────────▼──────────────────────────┐
                       │   Kernel                                          │
                       │   - SCI (System Control Interrupt) → bubble       │
                       │   - IRQ routing to bubble's installed handlers    │
                       │   - MMIO / port I/O capabilities granted at start │
                       └──────────────────────────────────────────────────┘
```

---

## 2. The bubble process

### 2.1 Bubble identity

The ACPICA bubble is a single userspace process named `acpica-bubble`, started by the supervisor at boot after the kernel has discovered ACPI table locations from UEFI. The bubble holds a specific set of capabilities granted by the supervisor:

- A memory cap for its heap (sized at ~16 MiB initially; grows on supervisor approval).
- `MmioMemCap` for each ACPI MMIO region (FACS, FACP fields, GPE registers, etc.).
- `port-cap`s for each ACPI port I/O range (PM1a, PM1b control/status, PM_TMR, SMI_CMD, etc.).
- `irq-cap` for the SCI vector (System Control Interrupt).
- A `pager_cap` for its own AS.
- Send/recv capabilities for IPC channels to the supervisor and to every driver server that registers ACPI interest.
- An audit-channel capability.

The bubble does *not* hold:
- Direct page-table capabilities (no `PML4Cap`, `PTCap`).
- The `sched-ctx` cap of any other process.
- Any capability to other userspace memory.
- `relax-mitigations` (the bubble runs with full mitigations).
- `cycle_cap` (the bubble is a pure consumer + responder, no cyclic patterns).

### 2.2 Bubble lifecycle

- **Start**: supervisor invokes `start_bubble(acpica_image, initial_caps)` at boot.
- **Initialization**: bubble parses ACPI tables; initializes the namespace; performs the ACPI initialization phase.
- **Run**: event-driven main loop dispatching SCI events and IPC requests.
- **Crash**: per Q14, default behavior is hard restart. The supervisor watches; on bubble death, it logs to the audit channel and respawns. ACPICA's state is reconstructible from the ACPI tables (which are static) plus the supervisor's policy state.
- **Update**: a bubble binary update follows the Q14 protocol — for ACPICA, hard restart is the only supported path (live-handoff of an AML interpreter's state is a non-starter).

### 2.3 Bubble scheduling

The bubble runs at a priority appropriate to its workload (per the priority convention in `scheduler.md` §3.6):
- Default: priority 200 (drivers and time-critical servers band).
- SCI-driven events run at the SCI's IRQ priority (high enough to handle thermal/power-button promptly).
- Long AML method evaluations (e.g., DSDT initialization at boot) run at lower priority once normal operation has begun.

The bubble's SC is set by the supervisor; `core_class = Any` since ACPICA operations are infrequent and not throughput-critical.

---

## 3. C runtime shim (AC-D9)

### 3.1 The shim scope

ACPICA's source assumes a small subset of libc functions plus a "host OS layer" (the OSL). The shim implements the libc subset entirely in paideia-as:

| Symbol | Implementation |
|---|---|
| `malloc`, `realloc`, `free` | Slab allocator over the bubble's memory cap. Slab classes: 16, 32, 64, 128, 256, 512, 1024, 2048, 4096 bytes; larger allocations go to a dedicated pool. |
| `memcpy`, `memset`, `memcmp`, `memmove` | AVX-512 / AVX2-vectorized implementations from PaideiaOS's library. |
| `strcmp`, `strncmp`, `strlen`, `strcpy`, `strncpy` | Standard semantics; safety-checked (no buffer overrun by construction in the shim's bounds). |
| `assert(cond)` | Maps to a paideia-as panic effect that crashes the bubble (the supervisor restarts per AC-D7). |
| `setjmp`, `longjmp` | ACPICA uses these in limited ways (error unwinding). The shim provides a restricted implementation: jump-buffers are linear capabilities; a `longjmp` to a consumed buffer is detected and panics. |
| `printf` / `vprintf` family | Routes to a buffered write on the audit channel; format specifiers are implemented in paideia-as. |
| `qsort`, `bsearch` | Standard C library equivalents, paideia-as native. |

### 3.2 What is *not* in the shim

- File I/O (`fopen`, `fread`, etc.) — ACPICA's table loading uses OSL, not stdio.
- Network — never used by ACPICA.
- Signals — paideia-as has no signal model; ACPICA's pseudo-signal use (e.g., GPE dispatch) is via the OSL.
- Threads — ACPICA is fundamentally single-threaded inside the bubble; the OSL provides cross-bubble notification, not multi-threading.
- Floating point — ACPICA does not use FP.
- Locale / wchar — ACPICA does not internationalize.

### 3.3 Shim size

Target: under 4000 LOC of paideia-as for the shim. Each function has a one-line comment indicating its semantics and a link to the corresponding ACPICA header.

### 3.4 Phase-1 vs phase-2 implications

The shim is built in phase 2 (with paideia-as); phase 1 has no ACPICA, so no shim. Phase 1's hardcoded MADT/MCFG/FADT parser is direct NASM with no C interop.

---

## 4. OS Services Layer (OSL) bridge (AC-D2)

### 4.1 The OSL's role

ACPICA defines ~70 OSL functions (`AcpiOs*`). The host OS implements them. PaideiaOS's implementation maps each to a paideia-as effect.

### 4.2 Critical OSL functions and their capability mapping

| OSL function | paideia-as effect | Required capability |
|---|---|---|
| `AcpiOsMapMemory(addr, len)` | `!{mmio_map}` | An `MmioMemCap` covering `[addr, addr+len)`. The OSL verifies the bubble's cap-set; if no covering cap, returns failure. |
| `AcpiOsUnmapMemory(va, len)` | `!{mmio_unmap}` | Implicit; releases the mapping. |
| `AcpiOsReadPort(port, value, width)` | `!{port_read}` | A `port-cap` covering `port`. |
| `AcpiOsWritePort(port, value, width)` | `!{port_write}` | A `port-cap` covering `port`. |
| `AcpiOsReadPciConfiguration(...)` | `!{pcie_read}` | Routes to the PCIe enumeration server (E4) via IPC; the bubble does *not* directly read PCIe configuration. |
| `AcpiOsWritePciConfiguration(...)` | `!{pcie_write}` | Same. |
| `AcpiOsInstallInterruptHandler(vector, handler, ctx)` | `!{irq_install}` | The bubble's `irq-cap` for SCI. The handler is registered with the kernel's IRQ subsystem; when SCI fires, the kernel delivers via IPC. |
| `AcpiOsRemoveInterruptHandler(...)` | `!{irq_remove}` | Same. |
| `AcpiOsExecute(type, func, ctx)` | `!{spawn_helper}` | Spawns a deferred-work helper inside the bubble (no new process). Used by ACPICA for GPE method execution. |
| `AcpiOsSleep(ms)` / `AcpiOsStall(us)` | `!{time_wait}` | Direct paideia-as wait; for `AcpiOsStall(us)` <= 100 µs uses `TPAUSE` (per scheduler doc §8.2). |
| `AcpiOsGetTimer()` | `!{time_read}` | TSC read. |
| `AcpiOsAllocate(size)` / `AcpiOsFree(p)` | `!{heap_alloc}` / `!{heap_free}` | Routes to the bubble's slab heap (C runtime shim). |
| `AcpiOsCreateMutex(out)` / `AcpiOsAcquireMutex` / `AcpiOsReleaseMutex` / `AcpiOsDeleteMutex` | `!{mutex_*}` | Maps to a paideia-as capability-based lock (a linear cap; acquisition consumes; release re-mints). |
| `AcpiOsNotifyHandler(device, value)` | `!{notify_handler}` | Routes the notification to the driver server holding the device's capability via IPC. |
| `AcpiOsPrintf` / `AcpiOsVprintf` | `!{audit_log}` | Writes to the audit channel. |

### 4.3 The IPC layer for device events

When ACPICA needs to notify a device driver (e.g., "thermal zone TZ1 crossed threshold"):
1. ACPICA invokes `AcpiOsNotifyHandler(tz1_handle, value)`.
2. The OSL bridge translates: looks up `tz1_handle` in a registry of (handle → driver IPC endpoint).
3. The bridge constructs a typed IPC message (per the IPC primitive's session types) and sends to the driver's RecvCap.
4. The driver receives the typed notification, executes its policy, possibly invokes more ACPI methods.

### 4.4 Capability discovery at startup

At bubble startup, the supervisor mints and delivers:
- The set of `MmioMemCap`s covering the ACPI MMIO regions discovered from the FADT and other static tables (kernel-mode parsing of ACPI table headers happens before bubble start — phase 1 code).
- The set of `port-cap`s for ACPI I/O ports.
- The SCI `irq-cap`.

If the FADT references a region the supervisor's policy denies, that capability is omitted; ACPICA's later attempt to map it returns failure, and ACPICA gracefully degrades (logged to audit).

### 4.5 Why no inner sandbox for AML

AML executes inside the AML interpreter, which is part of ACPICA. The interpreter's only external effect is through OSL calls. Since the OSL is capability-checked, no AML method can do anything the bubble itself cannot. An AML method that tries to read a port the bubble has no cap for: the OSL returns failure; AML's error path runs; no system effect occurs.

Therefore the AML interpreter does *not* need a separate sandbox inside the bubble. The capability membrane is the sandbox.

---

## 5. ACPI table provenance (AC-D4)

### 5.1 The trust chain

ACPI tables originate from the UEFI firmware. The chain:
1. UEFI loads platform-specific tables from motherboard firmware.
2. UEFI measures the RSDP (Root System Description Pointer) and key tables into TPM PCR-1 (per TCG PC Client Platform Firmware Profile).
3. UEFI hands the RSDP to the PaideiaOS loader at boot.
4. The loader extends PCR-8 with the kernel image hash and PCR-1's value.
5. The kernel reads the tables from the RSDP-pointed locations.
6. The bubble receives the table-pointers as a list of `MmioMemCap`s.

The trust anchor is the TPM AK certificate (per `security/pq-trust-root.md` §9). A verifier of remote attestation checks PCR-1 against a known-good measurement for the boot's hardware model.

### 5.2 Sanity-check on parse

When ACPICA parses tables, the OSL provides additional checks:
- Table length must not exceed the declared MMIO region.
- Checksum must be valid (ACPI mandates).
- Header magic must match expected ('FACP', 'MADT', 'MCFG', 'DSDT', etc.).
- Recursive size checks (e.g., AML methods cannot exceed the DSDT).
- Vendor-specific magic-number checks for known-buggy patterns (the workaround catalog inherited from upstream ACPICA).

A failed check causes the table to be ignored; the bubble logs to audit and proceeds with what tables remained valid.

### 5.3 User DSDT override

For development and debugging, the boot loader supports a `dsdt=<path>` parameter. If specified, the loader reads a user-provided DSDT from the boot media and substitutes it for the firmware DSDT. The user-provided DSDT is *measured* into a different PCR (PCR-12, conventionally for OS-level overrides); remote attesters can distinguish.

### 5.4 PaideiaOS does not sign ACPI tables

Vendor firmware does not generally sign ACPI tables; PaideiaOS does not require signed ACPI tables. The integrity is via the measured boot path, not per-table signature. If a future ecosystem ships signed tables, PaideiaOS will accept them and verify before consumption.

---

## 6. ACPI event delivery

### 6.1 SCI (System Control Interrupt)

The SCI is the ACPI mechanism for delivering events from hardware to software. The bubble holds the SCI's `irq-cap`. On SCI:
1. Kernel's IRQ subsystem (C8) routes the interrupt to the bubble's installed handler (via the OSL's IPC-equivalent).
2. The bubble's main loop dispatches to ACPICA's `AcpiEvSciDispatch` (or equivalent).
3. ACPICA examines GPE registers and fixed-event status, identifies the event source.
4. ACPICA invokes the registered handler (an AML method or a C-language handler in the bubble itself).
5. The handler may issue OSL calls (notify drivers, change power state, etc.).

### 6.2 Power button / sleep button / lid switch

These are fixed events delivered via SCI; the bubble's policy on each is configurable. The default:
- Power button → IPC message to supervisor; supervisor decides (shutdown, suspend, ignore).
- Sleep button → IPC message to supervisor; same.
- Lid close → IPC message to power-management policy; default action: dim display, enter S3 after timeout.

### 6.3 Thermal alerts

ACPI thermal zones fire SCI when temperature crosses a threshold. ACPICA delivers the notification to the registered thermal handler (typically a thermal-policy server, separate from the bubble). The thermal server requests P-state changes via ACPICA's `_PSS` evaluation, or initiates active cooling (fan control via embedded controller).

### 6.4 PCIe hot-plug

PCIe hot-plug events arrive via SCI when the firmware's hot-plug controller fires. ACPICA evaluates the affected slot's `_EJ0` / `_DCK` methods; the resulting state is delivered to the PCIe enumeration server (E4) via IPC. The PCIe server then notifies the relevant driver framework (E3) for device removal or addition.

### 6.5 Battery / AC adapter

Battery state changes (level, charging) and AC adapter plug/unplug fire SCI; ACPICA evaluates the corresponding methods; results go to the battery server (a userspace process under E3). The battery server publishes the state to the supervisor for power-policy decisions.

---

## 7. Power, thermal, and CPU policy (AC-D6)

### 7.1 Division of labor

**Supervisor (policy):**
- Decides *when* to enter sleep states (S1, S3, S4, S5).
- Sets thermal thresholds for active cooling vs. throttling.
- Targets CPU P-states based on workload and energy policy.
- Coordinates with userspace (e.g., refuses suspend if a critical process objects).

**ACPICA bubble (execution):**
- Evaluates `_S3` (etc.) methods to construct the state-transition sequence.
- Programs the FADT control registers to enter sleep.
- Evaluates `_CST` to discover available C-states; reports to the supervisor.
- Evaluates `_PSS` to discover P-states; reports to the supervisor.
- On supervisor request, programs the EC (embedded controller) for fan/battery state.

### 7.2 Sleep state entry

```
1. Supervisor: decide to enter S3.
2. Supervisor → bubble: IPC request "enter S3".
3. Bubble: ACPICA evaluates _PTS (Prepare-To-Sleep), then _S3.
4. ACPICA returns the state-transition sequence.
5. Bubble → kernel: IPC request "execute sleep transition" with the sequence.
6. Kernel: save CPU state, write to PM1a/PM1b registers per the sequence.
7. CPU enters S3.

On wake:
1. CPU resumes from S3; kernel restores state.
2. Kernel → bubble: IPC notification "S3 wake".
3. Bubble: ACPICA evaluates _WAK; performs any post-wake work.
4. Bubble → supervisor: IPC "wake complete".
5. Supervisor resumes scheduled processes.
```

### 7.3 P-state transitions

The supervisor's CPU-policy decides a target P-state. The supervisor sends an IPC request to the bubble; the bubble evaluates `_PSS` (P-state Status), writes the resulting MSR values via `wrmsr`-equivalent OSL calls (mediated by an `msr-cap`), and reports back.

### 7.4 Thermal throttling

The thermal server (a separate userspace process) reads sensor values via the bubble (which queries `_TMP` AML methods). When thresholds are crossed, the thermal server requests:
- Passive cooling (P-state down-shift, via supervisor + bubble).
- Active cooling (fan up, via bubble → EC).
- Critical shutdown (the supervisor's emergency policy).

---

## 8. Audit integration

Every OSL call's outcome is audit-recorded (per pillar 6). The audit record:

```
acpica_audit_record:
   timestamp     : u64
   operation     : enum {map, unmap, port_read, port_write, irq_install, ...}
   target        : u64    // address, port number, vector
   capability_id : u64    // the cap consumed (if any)
   result        : enum {success, denied, failure}
   error_code    : u32    // ACPICA's status code
```

Records are batched and written to the audit channel; high-frequency operations (timer reads, port polls) are sampled rather than logged in full to avoid swamping the audit log.

A failed capability check (ACPICA attempting an operation the bubble has no cap for) is *always* logged in full; this is a signal of a misconfigured bubble or a buggy/malicious AML method.

---

## 9. Phase 1 vs phase 2

### 9.1 Phase 1 (no ACPICA)

A minimal ACPI table parser in NASM:
- Locate RSDP (search EBDA + BIOS area + UEFI handoff).
- Verify RSDP checksum.
- Read RSDT/XSDT, enumerate tables.
- Parse MADT for IOAPIC base, x2APIC presence, local APIC IDs.
- Parse MCFG for PCIe extended-configuration-space base addresses.
- Parse FADT for PM_TMR location and base power-management I/O ports.
- Hand a parsed structure to the kernel.

Total: ~2000 LOC. No AML interpretation. No vendor workarounds. No PCIe hot-plug. No thermal management. No power-state transitions.

The phase-1 kernel can boot and reach the root task; the root task spawns drivers using the parsed information. Power management is "always on at maximum"; thermal is not actively managed.

### 9.2 Phase 2 (ACPICA bubble online)

The supervisor starts the bubble at boot. The bubble brings up:
- AML interpreter.
- Namespace.
- GPE event handling.
- Power state transitions.
- PCIe hot-plug.
- Thermal management.

The phase-1 NASM parser is retained for the *kernel-internal* table reads (IOAPIC base etc.); the bubble has its own copy of the parser (ACPICA's). Both are valid; they agree.

### 9.3 Phase 3+ (refinements)

- Updated ACPICA upstream sync.
- Possibly: D8 advanced semantic-shell capabilities that query the ACPI namespace.
- Possibly: integration with D15 energy-aware scheduling for proactive P-state hints.

---

## 10. paideia-as implementation

### 10.1 Module layout

`src/userspace/acpica-bubble/` is the bubble:

```
src/userspace/acpica-bubble/
├── upstream/         # ACPICA upstream C sources (vendored)
│   ├── components/
│   ├── include/
│   └── ...
├── shim/             # C runtime shim (paideia-as)
│   ├── malloc.s
│   ├── string.s
│   ├── stdio_audit.s
│   └── setjmp_linear.s
├── osl/              # OS Services Layer bridge (paideia-as)
│   ├── memory.s      # AcpiOsMap/Unmap
│   ├── port.s        # AcpiOsReadPort/WritePort
│   ├── pcie.s        # PCIe config space via IPC
│   ├── irq.s         # AcpiOsInstallInterruptHandler
│   ├── time.s        # AcpiOsGetTimer/Sleep/Stall
│   ├── mutex.s       # AcpiOsCreate/Acquire/ReleaseMutex
│   ├── execute.s     # AcpiOsExecute (helper spawn)
│   ├── notify.s      # AcpiOsNotifyHandler routing
│   └── alloc.s       # AcpiOsAllocate/Free
├── server.s          # main loop, IPC entrypoints
├── boot.s            # bubble initialization
├── policy.s          # supervisor-facing API
└── audit.s           # audit emission
```

### 10.2 Build integration

The upstream C is compiled by a Nix-pinned C compiler (one of: GCC, Clang); the paideia-as shim and OSL are built by `paideia-as`; the two object sets are linked together to produce the bubble's executable. The linker (`paideia-link`) understands both object formats.

This is the one place in PaideiaOS where two compilers feed the same binary; the build system handles it as a special case documented in `design/toolchain/paideia-link.md` (future).

### 10.3 Calling convention adaptation

ACPICA's C code uses the System V AMD64 ABI; the OSL bridge functions are entry points called from C. They expose a System V ABI on the C side and use the PaideiaOS-native convention internally — this is exactly the System V bridge pattern from `custom-assembler.md` §8.6.

Specifically: when AcpiOsMapMemory is called from C, the System V calling convention places `addr` in RDI and `len` in RSI. The OSL bridge entry, after saving R15 and other PaideiaOS-callee-saved registers, performs the operation in the PaideiaOS-native convention, then returns under System V.

The boundary thunks add ~30 cycles per OSL call; ACPICA's call rate is low enough this is negligible.

---

## 11. Performance considerations

| Operation | Frequency | Budget | Notes |
|---|---|---|---|
| `AcpiOsGetTimer` | High (occasional polling) | ≤ 50 ns | TSC read; no OSL bridge cost on optimized path |
| MMIO read/write via OSL | Medium | ≤ 200 ns | Includes the bridge thunk |
| Port read/write via OSL | Medium | ≤ 200 ns | Same |
| AML method evaluation (simple, e.g., `_TMP`) | Low (event-driven) | ≤ 50 µs | ACPICA's interpretation |
| AML method evaluation (complex, e.g., `_PRT` at boot) | Once at boot | ≤ 100 ms | Bounded by AML complexity |
| Sleep state entry (S3) | Rare (user-triggered) | ≤ 500 ms wall-clock | Dominated by hardware transition |
| SCI dispatch latency | On event | ≤ 50 µs | Kernel IRQ → bubble IPC → ACPICA handler |
| PCIe hot-plug notification | Rare | ≤ 100 ms | Includes driver server notification |

Budgets are aspirational; actual numbers come from `design/acpi/perf-baselines.md` (future).

---

## 12. Verification

### 12.1 Capability-coverage tests

A test enumerates every OSL function PaideiaOS exposes and verifies:
- Each function is wrapped by the OSL bridge.
- Each function's required capability is documented.
- An attempt to invoke each function without the corresponding capability fails with the documented error code.
- The audit log records the failure.

### 12.2 Fuzz testing

Per `02-development-environment.md` §9.5, ACPI table parsers are a fuzz target. The corpus is seeded from:
- A wide vendor sample (collected from real motherboards via a separate corpus-collection script).
- Deliberately malformed tables (from the public AMLab corpus, TODO: verify).
- ACPICA's own internal test suite (the "ACPICA tests" upstream).

Crashes in ACPICA are filed upstream; PaideiaOS-side crashes in the shim or OSL are PaideiaOS bugs.

### 12.3 Vendor-quirk regression

A test boots PaideiaOS in QEMU with simulated ACPI tables from known-buggy motherboards (a corpus we maintain). Behavior should match the workaround catalog inherited from upstream ACPICA.

### 12.4 The supervisor restart loop

A failure-injection test crashes the bubble (via deliberate panic in the shim) and verifies the supervisor restarts it cleanly. The system should remain functional (with degraded power/thermal management during the restart window).

---

## 13. Open issues

| ID | Issue | Resolution |
|---|---|---|
| AC-O1 | ACPICA upstream commit pin — choose a stable revision and document the update cadence. | `design/acpi/upstream-tracking.md` (future) |
| AC-O2 | The `setjmp/longjmp` linear-capability model needs careful design — ACPICA's use is limited but not zero. | `design/acpi/setjmp-model.md` (future) |
| AC-O3 | Vendor-quirk corpus collection — the test corpus for buggy motherboards needs an ongoing collection effort. | `design/acpi/vendor-quirks.md` (future) |
| AC-O4 | The phase-1 NASM parser scope — exactly which tables are parsed and which are deferred. | `design/acpi/phase1-parser.md` (future) |
| AC-O5 | Bubble crash-recovery cost — measure the actual time-to-functional after restart; under 1 second target? | `design/acpi/restart-perf.md` (future) |
| AC-O6 | The thermal server, battery server, and power-policy server are referenced but not designed in this document. | `design/system/power-management.md` (future) |
| AC-O7 | C runtime shim's exact LOC — the 4000 LOC budget is a target; actual count is post-implementation. | `design/acpi/shim-audit.md` (future) |
| AC-O8 | Interaction with hot-plug for CPU offline/online — not addressed here; future. | `design/acpi/cpu-hotplug.md` (future) |
| AC-O9 | The bubble's interaction with TDX hosts — TDX guests have different ACPI semantics; clarify. | `design/security/tdx-acpi.md` (future) |
| AC-O10 | User-provided DSDT measurement: which PCR exactly, and how does remote attestation surface it? | `design/security/dsdt-override.md` (future) |
| AC-O11 | Audit-log sampling for high-frequency OSL calls — choose the sampling policy. | `design/audit/sampling.md` (future) |

---

## 14. References

### 14.1 ACPI

- *Advanced Configuration and Power Interface (ACPI) Specification*. UEFI Forum, current revision (6.5+ as of 2026).
- *ACPI Component Architecture (ACPICA) Documentation*. Intel, ongoing.
- *ACPICA Programmer's Reference and User Guide*. Intel.

### 14.2 ACPICA upstream

- ACPICA source repository: https://github.com/acpica/acpica (informative; pin a commit in Nix).

### 14.3 Measured boot

- TCG PC Client Platform Firmware Profile Specification, current revision.
- TPM 2.0 Library Specification.

### 14.4 PCI Express hot-plug

- PCI Express Base Specification 6.0, ch. 6 (hot-plug controllers).

### 14.5 Power management

- ACPI Specification chapters on global/CPU/device power states and sleep.

### 14.6 Vendor quirks

- Linux kernel `drivers/acpi/quirks.c` and related — illustrative reference for the extent of vendor brokenness.
- ACPICA's own quirk and workaround catalog.

---

*End of document.*
