# PaideiaOS — Driver Framework

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Architectural specification of the PaideiaOS driver framework: the distributed hierarchical model where each bus driver acts as a mini-framework for its children; the three-tier organization (bus / class / device); driver lifecycle including the hard-restart-default and opt-in live-handoff (Q14); the capability set granted to drivers; the hot-plug protocol; power-management integration; failure containment; and the future-hook for blob drivers (Q6).

**Hard inputs (do not relitigate):**
- `design/00-feature-inventory.md` — E3 (driver framework: hierarchical, hot-pluggable), E4 (PCIe / NVMe / xHCI enumeration), E11 (hot-plug event bus), U3 (USB), U4 (audio), U5 (GPU), U12 (sensors), U13 (Bluetooth), U14 (Wi-Fi).
- `design/01-foundational-decisions.md` — Q6 (open-source-only GPU; blob path designed-in as future capability), Q14 (hard restart default; opt-in live state-handoff), Q9 (no POSIX; WASM jail for foreign software — relevant if a driver wraps a foreign component), Q13 (typed records; Cap'n Proto at boundaries).
- `design/02-development-environment.md` — driver server roles in CI; fuzz targets include driver IPC interfaces.
- `design/toolchain/custom-assembler.md` — substructural lattice, algebraic effects (Q-A3), functor modules (Q-A7), unsafe blocks.
- `design/ipc/wait-free-dataflow.md` — session-typed channels are the inter-driver communication substrate; slot-cap economy for backpressure.
- `design/capabilities/linearity-and-tags.md` — derived kinds via type system; the supervisor mints capabilities; revocation cascade.
- `design/kernel/memory-model.md` — IOMMU-isolated capability-mediated memory; `MmioMemCap` derived kind.
- `design/kernel/scheduler.md` — `reserved_core_cap` for time-critical drivers; SC donation; soft RT.
- `design/security/pq-trust-root.md` — driver binaries are release-line signed; the algorithm catalog tracks valid signing keys.
- `design/acpi/acpica-bubble.md` — ACPI events (hot-plug, thermal, power buttons) are routed to driver framework via IPC.

---

## 0. Decisions summary

### 0.1 Inherited (already binding)

| Source | Constraint |
|---|---|
| Pillar 3 (microkernel) | Drivers are userspace processes. The kernel routes interrupts and provides IOMMU isolation; it does not embed driver code. |
| Pillar 9 (hierarchically defined) | The framework structure mirrors the hardware bus hierarchy. Hot-pluggable. |
| Pillar 6 (security by construction) | Every driver action is capability-checked; misbehavior is contained at the capability boundary. |
| Q14 | Hard restart on driver update is the default; live state-handoff is opt-in for drivers that need continuity. |
| Q6 | Open-source-only GPU drivers in phase 1–2; blob drivers possible later behind an IOMMU-isolation capability. |
| Q13 | Cross-host pipelines serialize via Cap'n Proto; intra-host uses typed in-process records. The handoff state-snapshot format follows the same rule. |
| IPC primitive | Wait-free dataflow channels with session types are the only inter-process communication; drivers consume and produce typed channels. |

### 0.2 New decisions in this document (all taken without questionnaire)

| # | Choice | Rationale |
|---|---|---|
| DR-D1 | Framework architecture | **Distributed hierarchical**: the supervisor handles policy + global registration; each *bus driver* acts as a mini-framework for its downstream devices. No separate "Driver Manager" process. Pillar 9 literal reading; matches hardware hierarchy fractally; pillar 3 (microkernel) minimizes central state. |
| DR-D2 | Three-tier driver organization | **Bus drivers** (PCIe, USB hub, virtio bus) — enumerate child devices. **Class drivers** (HID, block, network) — implement protocol-level semantics. **Device drivers** — handle specific hardware. Each is a userspace process; class drivers are *not* libraries linked into device drivers. |
| DR-D3 | Driver capability model | A driver is a process holding a `driver_cap` (derived kind over the `process` base kind). Each driver receives a specific capability set at start: its device's `MmioMemCap`s, `port-cap`s, `irq-cap`s, a `pager_cap` for its AS, send/recv caps for IPC, and an audit-channel cap. |
| DR-D4 | Device-driver matching | Phase 1–2: classical VID/PID + class triple match against a supervisor-maintained driver registry. Phase 3+: schema-extensible matching, where drivers advertise what protocol schemas they fulfill and devices advertise what schemas they require. |
| DR-D5 | Hot-plug protocol | New device discovery → bus driver emits `device_arrived` event on its hot-plug channel → supervisor receives, consults registry, picks a driver, mints capabilities, spawns the driver. Removal → bus driver emits `device_departed` → driver receives, finishes pending I/O, exits → supervisor reclaims caps. |
| DR-D6 | Driver-to-driver communication | Drivers consume each other's services via wait-free dataflow IPC with session-typed channels. A filesystem driver holds a `Channel(BlockDeviceSchema)` to its block-device driver; the schema is a functor signature per Q-A7. |
| DR-D7 | Driver lifecycle states | Init → Running → Suspended → Stopping → Stopped, plus Crashing → Restarting and (opt-in) → Handoff. The transitions are an explicit FSM specified in §5. |
| DR-D8 | Power management | Drivers participate in S3/S4/S5 transitions via `Suspend`/`Resume` algebraic effects. The supervisor coordinates with the ACPI bubble per `acpi/acpica-bubble.md` §7; the bubble notifies drivers via their typed channels. |
| DR-D9 | Failure containment | Driver process death = its devices are reclaimed; pending I/O is aborted; clients of the driver's services receive `ChannelDead` per IPC §9.1. The supervisor's restart policy (per Q14) decides whether to respawn. |
| DR-D10 | Live state-handoff | Drivers opting into Q14 handoff implement a `serialize_state` effect producing a Cap'n Proto snapshot; the supervisor stores it; the replacement driver consumes it on start. The schema is per-driver. |
| DR-D11 | Blob driver future hook | A `blob_driver_cap` derived kind defines the contract: same `driver_cap` interface, but the supervisor mints with stricter IOMMU isolation (per-device IOMMU domain), no audit-channel write capability (the blob is untrusted), and no `reserved_core_cap`. The framework code does not change when blobs are introduced. |

### 0.3 Three meta-positions

1. **The framework is the pattern, not a component.** There is no single "driver framework process". The pattern is: the supervisor + the bus drivers collectively *are* the framework. A PCIe bus driver enumerates PCIe devices and is a framework for them; a USB hub driver enumerates USB devices and is a framework for them; a virtio bus driver is a framework for virtio devices. Each is a peer of the others under the supervisor. This is pillar 9 ("hierarchically defined") taken at face value.

2. **Class drivers are services, not libraries.** A USB HID class driver runs as its own process; a USB mouse driver and a USB keyboard driver each consume the HID class service via session-typed IPC. Sharing happens at the protocol level (the HID class understands HID), not at the link level. This is pillar 3 (microkernel) preferred over the Linux-style "class driver as kernel library" approach.

3. **Hot-plug is the default model, not a special case.** Even at boot, "static" devices arrive via the same hot-plug channel (the bus driver enumerates and emits `device_arrived` for each device discovered). There is no separate static-device path. This makes the boot path and the runtime path identical, simplifying verification.

---

## 1. Architectural overview

```
                          ┌─────────────────────────────────────────┐
                          │              Supervisor                  │
                          │  - registry: (VID, PID, class) → driver │
                          │  - capability minting                   │
                          │  - lifecycle policy                     │
                          │  - audit log writes                     │
                          └────────┬────────────────────────────────┘
                                   │ wait-free IPC
                ┌──────────────────┼─────────────────────────────────┐
                │                  │                                  │
                ▼                  ▼                                  ▼
        ┌──────────────┐  ┌──────────────┐                  ┌──────────────┐
        │ PCIe bus     │  │ ACPI bubble  │                  │ Virtio bus   │
        │ driver       │  │ (events)     │                  │ driver       │
        │ - enumerates │  │              │                  │ - enumerates │
        │ - hot-plug   │  │              │                  │ - hot-plug   │
        │ - per-device │  │              │                  │ - per-device │
        │   sub-frame  │  │              │                  │   sub-frame  │
        └──────┬───────┘  └──────────────┘                  └──────┬───────┘
               │                                                   │
               │ enumerates                                        │
               ├────────────────────┬─────────────────────┐        │
               ▼                    ▼                     ▼        ▼
       ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
       │ NVMe device  │    │ NIC device   │    │ USB host     │
       │ driver       │    │ driver       │    │ controller   │
       │              │    │              │    │ (xHCI)       │
       │              │    │              │    │ - bus driver │
       └──────┬───────┘    └──────┬───────┘    │ for USB     │
              │                   │            └──────┬───────┘
              │ provides          │ provides          │
              │ BlockDeviceSchema │ NetIfSchema       │ enumerates
              ▼                   ▼                   │
       ┌──────────────┐    ┌──────────────┐           │
       │ Block class  │    │ Network      │           │
       │ driver       │    │ stack (E7)   │           │
       │ - implements │    │              │           │
       │ block-level  │    │              │           │
       │ semantics    │    │              │           │
       └──────┬───────┘    └──────────────┘           │
              │                                       │
              │ provides BlockSchema                  │
              ▼                                       │
       ┌──────────────┐                  ┌────────────┴───────────┐
       │ FS server    │                  │ USB HID class driver   │
       │ (E17)        │                  │ - implements HID       │
       │              │                  └────────────┬───────────┘
       └──────────────┘                               │
                                                      │ provides HidSchema
                                  ┌───────────────────┼───────────────────┐
                                  ▼                                       ▼
                          ┌──────────────┐                        ┌──────────────┐
                          │ Mouse device │                        │ Keyboard     │
                          │ driver       │                        │ device       │
                          └──────────────┘                        │ driver       │
                                                                   └──────────────┘
```

---

## 2. The distributed hierarchical framework (DR-D1)

### 2.1 No central "Driver Manager"

PaideiaOS does *not* have a single driver-framework process. The framework is a *pattern* enacted collectively by:
- **The supervisor**: holds the global driver registry, decides which driver matches a discovered device, mints capabilities, and watches for crashes.
- **The bus drivers**: enumerate their children; emit hot-plug events; mediate child-device-to-supervisor communication.

A USB device's chain of authority: supervisor → xHCI driver (USB host controller) → USB device. Each tier of the chain holds the capabilities to authorize the next tier.

### 2.2 Why distributed

- **Pillar 9 literal reading.** "Hierarchically defined" means the *framework* is hierarchical, not just the data structures.
- **Pillar 3 (microkernel).** A central driver-manager process would be additional state and additional code. The pattern avoids it.
- **Fractal scaling.** PCIe-to-PCIe bridges, USB hubs, and Thunderbolt's tree of buses all naturally fit the recursive pattern.
- **Failure isolation.** A bug in the USB subsystem cannot affect the NVMe subsystem because they are entirely separate processes communicating only through typed channels.

### 2.3 Who does what

| Actor | Responsibilities |
|---|---|
| Supervisor | Driver registry; capability minting; lifecycle policy (when to restart, when to give up); audit log; coordination of cross-bus events. |
| Bus driver | Bus enumeration; child-device discovery; hot-plug event emission; per-device resource discovery (BARs for PCIe; endpoints for USB); IRQ allocation for children. |
| Class driver | Protocol-level semantics (e.g., "a block device is a sequence of N-byte blocks accessible via read/write"); aggregation of device-specific drivers. |
| Device driver | Hardware-specific operations: ring management, interrupt handling, vendor extensions. |

### 2.4 Distributed registration

When a driver process starts, it registers with the supervisor by sending a typed `driver_registered` message on its registration channel:

```paideia-as
message DriverRegistered = {
  driver_id        : DriverId
  provides_schemas : List<SchemaId>
  consumes_schemas : List<SchemaId>
  capabilities     : DriverCapabilityRequest
}
```

The supervisor records the registration; any pending devices matching the driver's schemas are routed to it.

---

## 3. Three-tier organization (DR-D2)

### 3.1 Bus drivers

A bus driver enumerates the devices attached to a bus. Examples:
- **PCIe enumerator**: walks the PCIe configuration space (MCFG region from ACPI); discovers devices; reads VID/PID/class.
- **USB hub driver**: a hub is an enumerable device that exposes downstream ports; the hub driver enumerates connected devices.
- **Virtio bus driver**: handles virtio devices on a host (typically PCIe-attached but with virtio-specific enumeration).
- **i2c bus driver**: i2c is a serial bus with addressed slaves; the bus driver enumerates by address.

Each bus driver:
- Provides a hot-plug channel on which `device_arrived` and `device_departed` events are emitted.
- Maintains a list of currently-attached devices with their resources.
- Resolves resource conflicts at the bus level (PCIe BAR allocation, USB endpoint allocation).
- Forwards events from above (e.g., system suspend) to its children.

### 3.2 Class drivers

A class driver implements a protocol-level abstraction. Examples:
- **HID class**: human-interface devices over USB or PS/2; processes report descriptors; produces typed input events.
- **Mass storage class**: block-device semantics over USB, NVMe, virtio-blk, etc.; produces a `BlockDeviceSchema` channel.
- **Network class**: produces typed packet streams; consumes packets to transmit.
- **Audio class**: PCM stream production and consumption.

A class driver:
- Consumes device-specific channels from device drivers below it.
- Provides protocol-typed channels upward (to filesystems, network stack, semantic shell).
- Does *not* know about specific hardware; only about the class protocol.

### 3.3 Device drivers

A device driver handles a specific piece of hardware. Examples:
- **NVMe driver**: implements the NVMe queue protocol; submits I/O commands; handles completion interrupts.
- **Intel iGPU driver**: implements iGPU command submission, memory management, display output.
- **Realtek r8169 NIC driver**: handles the specific Realtek family of network controllers.
- **xHCI driver**: USB host controller (note: this is both a bus driver for USB and a device driver for the xHCI PCIe device — a node serves dual roles in the hierarchy).

A device driver:
- Holds the device's resources (MMIO, ports, IRQs).
- Implements vendor-specific quirks.
- Provides a class-conformant channel (or multiple, if the device supports multiple classes).

### 3.4 Why class drivers as services, not libraries

In Linux, USB-HID class is a kernel module statically linked into individual device drivers. In PaideiaOS:
- HID class driver is its own process.
- USB mouse device driver runs as its own process and *consumes* the HID class driver's service.
- Sharing of HID protocol code happens at the IPC interface level — the HID class driver does the parsing of HID report descriptors *once*, and exposes typed input events.

This is pillar 3 (microkernel) preferred:
- Failure isolation: HID class crash doesn't kill the mouse driver (the mouse driver receives `ChannelDead` and restarts on a fresh HID class driver).
- Memory isolation: HID parsing bugs don't affect device-driver memory.
- Capability discipline: the HID class driver holds *no* hardware capabilities; only schema-typed IPC channels.

---

## 4. Driver capability set (DR-D3)

### 4.1 The `driver_cap` derived kind

A driver is a process holding a `driver_cap` (derived from the `process` base kind). The cap declares:
- The driver's identity (`driver_id`).
- The capabilities it received at start.
- The lifecycle state (per §5).
- The audit attribution.

### 4.2 Typical capability set

A device driver for a PCIe NIC typically receives:

| Capability | Purpose |
|---|---|
| `MmioMemCap` for the device's BARs | MMIO register access |
| `MmioMemCap` for the device's MSI-X table | MSI-X interrupt configuration |
| `port-cap` (rare for PCIe; common for legacy ISA) | Port I/O |
| `irq-cap` for assigned MSI/MSI-X vectors | Interrupt handling |
| `pager_cap` for its own AS | Memory management within the driver |
| Send and Recv `Channel(...)` caps | IPC with bus driver above, class driver and supervisor |
| `audit-channel cap` | Audit log writes |
| `iommu_cap` for its device | DMA buffer setup |
| (optional) `reserved_core_cap` | Time-critical drivers (NIC poll-mode, audio) |
| (optional) `handoff_cap` | Drivers opting into Q14 live handoff |

A class driver typically receives a smaller set: pager cap, channel caps for the protocols it implements and consumes, audit cap. *No hardware capabilities* — class drivers don't touch hardware.

A bus driver receives bus-enumeration capabilities (e.g., access to PCIe configuration space for the PCIe enumerator) and the hot-plug-channel send cap.

### 4.3 Capability minting at driver start

The supervisor's start sequence for a device driver:

```
1. Receive device_arrived event from the bus driver.
2. Match the device against the registry (per §6).
3. Compute the required capability set based on the device's resources.
4. Mint each capability (the substructural lattice ensures uniqueness):
   - Retype memory regions as MmioMemCaps for the BARs.
   - Mint port-caps for the I/O ports.
   - Mint irq-cap for the assigned interrupt vector.
   - Mint or fork channel caps for IPC.
5. Start the driver process; pass the capability bundle via initial-caps mechanism.
6. The driver enters Init state.
```

### 4.4 Capability transfer in driver-to-driver IPC

When a class driver hands a service channel to a consumer (e.g., the block class driver hands a `BlockDeviceSchema` channel to the FS), the transfer is via the IPC primitive's capability transport (per IPC §5). The receiving driver holds the channel; the originating class driver retains its `Recv` side; the channel itself is owned by the supervisor's registry for revocation purposes.

### 4.5 Per-device IOMMU isolation

Every device driver receives an `iommu_cap` for *only* its device. The IOMMU subsystem (per kernel C10 / `kernel/memory-model.md`) enforces that DMA from a device targets only memory the driver has explicitly mapped. A buggy or malicious driver cannot DMA to arbitrary memory — the IOMMU rejects.

This is the foundation for the blob driver future hook (DR-D11): a blob driver receives the same iommu_cap but no other broader capabilities; its damage radius is its device's memory only.

---

## 5. Driver lifecycle (DR-D7)

### 5.1 The state machine

```
                ┌──────────┐
                │  Init    │
                └────┬─────┘
                     │ initialization complete
                     ▼
                ┌──────────┐  Suspend   ┌──────────┐
                │ Running  │ ────────►  │ Suspended│
                │          │ ◄──────── │          │
                └────┬─────┘  Resume    └──────────┘
                     │
        ┌────────────┼────────────┐
        │ stop_request           │ crash
        ▼                        ▼
   ┌──────────┐             ┌──────────┐
   │ Stopping │             │ Crashing │
   └────┬─────┘             └────┬─────┘
        │                        │
        ▼                        ▼
   ┌──────────┐             ┌──────────┐
   │ Stopped  │             │ Restart  │── per Q14 policy
   └──────────┘             └────┬─────┘
                                 │
                                 ▼ (back to Init, possibly with handoff state)

   Special transition (opt-in per Q14):
   Running → Handoff → Stopping  (state snapshot serialized, then driver exits)
   Init    ← Handoff             (new driver consumes snapshot at start)
```

### 5.2 State semantics

| State | Meaning |
|---|---|
| **Init** | Driver process started; reading initial capabilities; allocating internal structures; not yet handling requests. |
| **Running** | Normal operation; handling IPC; processing device events. |
| **Suspended** | Power-management-driven: device powered down; in-flight I/O paused; some state preserved in RAM. |
| **Stopping** | Graceful shutdown initiated: completing pending I/O, releasing capabilities, preparing to exit. |
| **Stopped** | Process has exited; capabilities reclaimed; the supervisor's registry records the absence. |
| **Crashing** | Unexpected termination detected by the supervisor (process death not preceded by Stopping). |
| **Restart** | Supervisor's policy decided to respawn; a new driver process is being started. |
| **Handoff** | The driver is preparing a state snapshot per Q14; will then transition to Stopping. |

### 5.3 State transitions

The transitions are effect operations on the driver's capability set:

```paideia-as
effect DriverLifecycle {
  op start_request   : (caps : DriverCapBundle) -> unit                // Init
  op init_complete   : unit -> unit                                   // → Running
  op suspend_request : (target_state : PowerState) -> SuspendResponse // Running → Suspended
  op resume_request  : unit -> ResumeResponse                          // Suspended → Running
  op stop_request    : (reason : StopReason) -> unit                  // Running → Stopping
  op begin_handoff   : (snapshot_cap : SnapshotCap) -> HandoffResponse // Running → Handoff
  op exit            : (exit_code : i32) -> unit                       // Stopping → Stopped
}
```

Each operation is handled by the driver; the handler may emit further effects (e.g., a `BlockDeviceClient` request to flush pending I/O during `suspend_request`).

### 5.4 The supervisor's lifecycle policy

The supervisor watches all drivers and decides on:
- When to send `stop_request` (planned shutdown).
- When to send `suspend_request` (power management).
- When to restart after `Crashing` (per Q14 default: yes; per supervisor's policy in failure analysis).
- When to invoke handoff during driver update (per Q14 opt-in).

---

## 6. Device matching (DR-D4)

### 6.1 Phase 1–2: classical triple matching

The supervisor's registry maps `(VID, PID, Class)` triples to driver identifiers. When a bus driver emits `device_arrived` with a triple, the supervisor:
1. Looks up the triple in the registry.
2. If found: starts that driver.
3. If not found: emits an `unmatched_device` audit event; the device is left without a driver.

A driver registers at install time:

```paideia-as
message DriverRegistration = {
  driver_id     : DriverId
  matches       : List<(VID, PID, ClassMask)>
  driver_binary : Capability<Process>     // the executable
  required_caps : DriverCapabilityRequest
}
```

### 6.2 Wildcard matching

A driver may match a wildcard, e.g., `(VID=0x10ec, PID=*, Class=NetworkController)` to claim all Realtek network controllers. The supervisor's matching prefers more-specific matches over wildcards; ties are broken by the audit log's documented policy.

### 6.3 Phase 3+: schema-extensible matching

In phase 3+, devices may advertise additional schema information beyond the legacy triple. A device might say: "I implement `NvmeSchema` v1.4 plus `NvmeOverFabricsSchema` v0.9". Drivers register the schemas they fulfill. The matching is schema-aware.

This phase 3+ work is sketched in `design/drivers/schema-matching.md` (future) and will tie in with the semantic-shell's typed pipelines (Q13).

### 6.4 Manual override

A boot-time parameter `driver_force=VID:PID:driver_id` can override the registry, useful for development and debugging. Manual overrides are logged.

---

## 7. Hot-plug protocol (DR-D5)

### 7.1 Event flow

```
1. Bus driver detects new device (e.g., USB enumeration after port reset).
2. Bus driver reads device descriptors (USB device descriptor; PCIe configuration space).
3. Bus driver constructs the device's (VID, PID, Class) triple and resource description.
4. Bus driver sends device_arrived on its hot-plug channel.

   message DeviceArrived = {
     bus_driver_id : DriverId
     device_id     : DeviceId
     triple        : (VID, PID, Class)
     resources     : ResourceMap
       (MMIO ranges, port ranges, IRQ vectors, descriptors,
        bus-specific metadata)
   }

5. Supervisor receives device_arrived.
6. Supervisor matches against registry (§6).
7. If a driver is selected: supervisor mints capabilities, starts the driver, passes the device's caps.
8. The driver enters Init, then Running, then handles the device.
```

### 7.2 Removal

```
1. Bus driver detects device removal (USB disconnect; PCIe surprise-removal indication).
2. Bus driver sends device_departed on its hot-plug channel.

   message DeviceDeparted = {
     bus_driver_id : DriverId
     device_id     : DeviceId
     reason        : DepartureReason
   }

3. Supervisor receives device_departed.
4. Supervisor sends stop_request to the device's driver with reason = DeviceRemoved.
5. Driver enters Stopping; aborts in-flight I/O; sends Stopped notifications to clients.
6. Driver exits.
7. Supervisor reclaims the device's capabilities (revocation cascade).
```

### 7.3 Surprise removal

If a device is physically removed before the bus driver can issue a graceful `device_departed` (e.g., a USB cable yanked), MMIO/port access from the driver returns failure responses. The bus driver detects this and emits `device_departed` retroactively. The driver's pending I/O fails with `DeviceGone`; clients are notified.

### 7.4 Hot-add at boot

At boot, the bus driver enumerates all already-attached devices and emits `device_arrived` for each. There is *no* distinction between boot-discovered and runtime-discovered devices — both use the same hot-plug channel. This is per §0.3 meta-position 3.

---

## 8. Driver-to-driver communication (DR-D6)

### 8.1 Service channels

A driver consuming another's service holds a session-typed channel to it. Examples:

- The FS server holds `Channel(BlockDeviceSchema)` to the block class driver, which holds `Channel(NvmeSchema)` to the NVMe device driver.
- The network stack holds `Channel(NetIfSchema)` to each NIC driver.
- The semantic shell holds typed channels to userspace servers exposing schemas.

### 8.2 Schema as functor signature

Per Q-A7, each schema is a functor signature:

```paideia-as
signature BlockDeviceSchema =
  protocol : SessionType !{ ... read/write protocol ... }
  block_size : u32
  capacity_bytes : u64
  effects : EffectRow !{block_read, block_write, block_flush}
```

A class driver provides a *structure* matching the signature for each device it manages; a consumer holds a `Channel(BlockDeviceSchema)` to that structure. The session-type protocol drives the wire format.

### 8.3 Multiple devices, multiple channels

A class driver may manage many devices simultaneously. It maintains a channel per device. A new device's arrival triggers minting of a new channel (with a fresh schema instance); the consumer is notified via a service-registry update.

### 8.4 Service-registry pattern

The supervisor maintains a service registry mapping `(schema, identifier)` to active service channels. A consumer wanting a service:
1. Queries the supervisor for `Channel(BlockDeviceSchema)` with desired properties (e.g., "the first block device").
2. Supervisor returns a channel cap.
3. Consumer uses the channel.

This is reminiscent of microkernel name-server patterns but is *typed*: the consumer can only request schemas it understands.

---

## 9. Power-management integration (DR-D8)

### 9.1 System-level transitions

When the supervisor decides to enter S3, the sequence is:

```
1. Supervisor → ACPI bubble: "begin S3 prep"
2. Supervisor enumerates all Running drivers.
3. Supervisor sends suspend_request(S3) to each driver in topological order (leaves first, buses last).
4. Each driver:
   a. Completes pending in-flight I/O (or marks as needing resume).
   b. Saves device state to driver-internal memory or device-specific persistent storage.
   c. Puts the device into the requested power state.
   d. Responds with SuspendComplete.
5. When all drivers are Suspended, supervisor → ACPI bubble: "execute S3"
6. ACPICA bubble + kernel execute the S3 transition.

On wake:
1. CPU resumes from S3.
2. ACPICA bubble notifies supervisor of wake.
3. Supervisor enumerates Suspended drivers in topological order (buses first, leaves last).
4. Supervisor sends resume_request to each.
5. Each driver:
   a. Restores device state.
   b. Reinitializes hardware as needed.
   c. Resumes pending I/O.
   d. Responds with ResumeComplete.
6. System fully resumed.
```

### 9.2 Per-device power management

Many devices support runtime power management (e.g., NVMe PS states, NICs with runtime suspend). The driver can transition its device between full-power and low-power states without supervisor involvement; the supervisor observes via audit log entries.

### 9.3 Power-policy effect

The supervisor exposes a power-policy effect that drivers can query:

```paideia-as
effect PowerPolicy {
  op query_policy : unit -> PowerPolicy   // current energy budget, etc.
  op request_state : (target : PowerState) -> Response
}
```

This lets drivers cooperate with the system's energy strategy (D15 future).

---

## 10. Failure containment and restart (DR-D9, Q14 default)

### 10.1 What happens when a driver crashes

```
1. Kernel detects unexpected driver-process death (page fault, illegal instruction,
   panic effect, etc.).
2. Kernel reclaims the driver's capabilities into the supervisor's death-handler channel.
3. Supervisor receives crash notification:

   message DriverCrashed = {
     driver_id : DriverId
     reason    : CrashReason       // page_fault, panic, oom, killed_by_supervisor
     last_known_state : LifecycleState
   }

4. Supervisor logs to audit channel.
5. Supervisor's policy decides:
   a. Restart (default per Q14): start a fresh driver with the same capability set.
   b. Failover (if a replication policy is configured): activate a standby driver.
   c. Give up: leave the device without a driver; emit unmatched_device event.
6. Clients of the dead driver receive ChannelDead on their session channels (per IPC §9.1).
7. If restart succeeds, clients can reconnect via the service registry.
```

### 10.2 Cascade limits

If a driver crashes repeatedly (e.g., 3 times in 60 seconds), the supervisor's policy escalates to "give up" rather than infinite restart loops. The threshold is configurable per driver.

### 10.3 Damage radius

A driver's damage radius is bounded by its capability set:
- Memory: only its own AS plus IOMMU-bound device memory.
- Devices: only those whose caps it holds.
- IPC: only the channels it has endpoints on.

No driver crash can corrupt the kernel, the supervisor, the audit log, or other drivers' state. This is pillar 3 (microkernel) + pillar 6 (security) at work.

---

## 11. Live state-handoff (DR-D10, Q14 opt-in)

### 11.1 Drivers opting in

A driver opts into handoff by holding a `handoff_cap` granted by the supervisor at start. The cap implies:
- The driver implements `serialize_state` and `deserialize_state` operations.
- The driver's state has a well-defined Cap'n Proto schema (registered in the schema registry per §6.3).
- The supervisor will use handoff (rather than hard restart) for driver updates.

### 11.2 The handoff sequence

```
1. Supervisor decides to update driver D to version D'.
2. Supervisor sends begin_handoff(snapshot_cap) to D.
3. D enters Handoff state.
4. D serializes its state to a SnapshotCap-allocated buffer:
   - In-flight I/O: outstanding tags + recovery markers.
   - Connection state: session-type FSM positions for each open channel.
   - Device-specific state: queue depths, configuration, etc.
5. D responds with handoff_complete; transitions to Stopping.
6. D exits.
7. Supervisor starts D' with the snapshot:
   D' enters Init; reads the snapshot; reconstructs state; transitions to Running.
8. Active channel sessions continue from where they left off:
   - Open files remain open.
   - Active TCP connections survive.
   - In-flight I/O completes after the new driver is running.
```

### 11.3 Schema versioning

The snapshot schema is per-driver. When D and D' have different schema versions, D' provides a `migrate_snapshot` step. The supervisor offers a versioned schema registry; drivers register their supported schema-version range.

If schemas are incompatible (the gap is too wide), the supervisor falls back to hard restart.

### 11.4 Handoff timing budget

The handoff window (per IPC §9.2 default) is 5 seconds. If D' fails to take over within the window, the channel transitions to dying; clients see `ChannelDead`. The window is configurable per driver.

### 11.5 Drivers that benefit

- NIC drivers: TCP connections survive driver update.
- NVMe drivers: in-flight I/O is not aborted.
- USB host controllers: enumerated devices stay enumerated.
- Audio drivers: stream continuity (with possibly brief artifact).

Drivers that do *not* benefit (most): power button, sensors, periodic batch operations.

---

## 12. Blob driver future hook (DR-D11, Q6)

### 12.1 The `blob_driver_cap` derived kind

Phase 1–2: PaideiaOS ships open-source drivers only. Phase 3+ may host vendor blob drivers (NVIDIA modern, certain Wi-Fi chipsets) under strict isolation. The framework already accommodates this:

- A blob driver is a process holding `blob_driver_cap` (derived from `driver_cap`).
- The blob's capability set is *strictly smaller* than a regular driver's:
  - `MmioMemCap` for its device only.
  - `iommu_cap` for its device only (per-device IOMMU domain).
  - `pager_cap` for its own AS.
  - Send/recv caps for *only* the IPC channels the supervisor designated.
  - No `audit-channel cap` (the blob is untrusted; the supervisor's blob-watcher logs externally).
  - No `reserved_core_cap`.
  - No `relax-mitigations`.
- The supervisor's blob-watcher process audits all blob driver IPC and resource use.
- A blob driver's crash is treated the same as any other (restart per policy).
- A blob driver may use full hardware capabilities (it's a real driver), but its damage is bounded.

### 12.2 Why this works today

The framework code (supervisor, bus drivers, class drivers, lifecycle FSM, IPC patterns) does *not* change to support blob drivers. The only difference is that blob driver processes are started with a different capability set. No new mechanism, no new IPC, no new framework — just a different cap bundle.

This is the cleanest possible "designed-in future hook" from Q6.

### 12.3 What's needed at the time of activation

When PaideiaOS decides to enable blob drivers (phase 3+):
1. Define the `blob_driver_cap` derived kind in the type system.
2. Implement the blob-watcher process (audit + anomaly detection).
3. Document the threat model and user-consent flow.
4. Update the registry to permit `blob_driver` entries.

None of this requires changes to the framework documents (this one) or the underlying primitives. Q6's "designed-in" promise is honored by *not changing anything now*.

---

## 13. paideia-as implementation

### 13.1 Module layout

The framework is not a single directory; it's distributed across:

```
src/userspace/drivers/framework/    # the framework's shared schemas and patterns
├── schema.s                          # DriverRegistration, DeviceArrived, etc.
├── lifecycle.s                       # the DriverLifecycle effect declarations
├── powerpolicy.s                     # PowerPolicy effect declarations
├── handoff.s                         # snapshot serialization helpers
└── audit.s                           # standard audit emission patterns

src/userspace/drivers/pcie/           # PCIe bus driver
src/userspace/drivers/usb-xhci/       # xHCI controller (bus + device)
src/userspace/drivers/usb-hub/        # USB hub driver
src/userspace/drivers/virtio-bus/     # virtio bus driver
src/userspace/drivers/nvme/           # NVMe device driver
...

src/userspace/drivers/class/block/    # block class driver
src/userspace/drivers/class/net/      # network class driver
src/userspace/drivers/class/hid/      # HID class driver
src/userspace/drivers/class/audio/    # audio class driver
...
```

### 13.2 Phase 1 vs phase 2

Phase 1 (NASM bootstrap):
- A minimal "driver" pattern in NASM: a process that holds MMIO caps + IRQ cap, exposes a simple IPC interface.
- The PCIe enumerator is a phase-1 deliverable (needed for any PCIe device including the disk for boot).
- The NVMe driver is a phase-1 deliverable (needed for storage at boot).
- The xHCI driver may be deferred to phase 2 if no USB needed for boot.
- No class drivers, no hot-plug, no lifecycle FSM beyond Init → Running.

Phase 2 (paideia-as coexistence):
- Full framework: bus driver pattern, class drivers, lifecycle FSM, hot-plug channels, suspend/resume.
- Handoff support comes online for the drivers that opt in.
- Power management integration with the ACPI bubble.

Phase 3+ (paideia-as canonical):
- Schema-extensible matching.
- Blob driver activation (if pursued).
- Audio, GPU, Bluetooth, Wi-Fi class drivers reach maturity.

### 13.3 Calling convention

Drivers use the standard PaideiaOS calling convention. R12 holds the driver_cap; R13/R14 hold IPC arguments; R15 holds the effect environment with installed handlers for `DriverLifecycle`, `PowerPolicy`, and the driver-class-specific effects.

---

## 14. Performance considerations

| Operation | Budget | Substrate |
|---|---|---|
| Hot-plug event → driver start | ≤ 50 ms | bare-metal |
| Driver init (typical) | ≤ 100 ms | bare-metal |
| Driver-to-driver IPC round-trip | ≤ 1 µs | bare-metal (per IPC §12) |
| Suspend request → SuspendComplete | ≤ 100 ms per driver | bare-metal |
| Resume request → ResumeComplete | ≤ 100 ms per driver | bare-metal |
| Handoff (state ≤ 1 MiB) | ≤ 500 ms | bare-metal |
| Hard restart (default) | ≤ 200 ms | bare-metal |
| Crash detection latency | ≤ 10 ms | bare-metal |

Aspirational; per-driver baselines come from `design/drivers/perf-baselines.md` (future).

---

## 15. Verification

### 15.1 Per-driver test patterns

Every driver ships with:
- Lifecycle FSM tests (every transition exercised).
- Capability-coverage tests (the driver attempts to use each cap; missing caps produce expected failures).
- Crash-and-restart tests (simulated crashes; supervisor restart timing).
- Handoff tests (if applicable).

### 15.2 Cross-driver integration tests

End-to-end paths exercised in CI:
- PCIe enumerator → NVMe driver → block class driver → FS server: write a file.
- PCIe enumerator → NIC driver → network class → network stack: TCP connection.
- PCIe enumerator → xHCI → USB hub → USB device → HID class driver: keyboard event.

### 15.3 Fuzz testing

Driver IPC interfaces are fuzz targets per `02-development-environment.md` §9.5. The fuzzer sends malformed messages on session-typed channels; the driver must either reject (with documented error code) or handle gracefully without crashing.

### 15.4 Hot-plug stress

A test repeatedly attaches and detaches simulated devices; the supervisor must keep up; no capability leaks.

---

## 16. Open issues

| ID | Issue | Resolution |
|---|---|---|
| DR-O1 | Schema-extensible matching for phase 3+ — concrete schema language and matching algorithm. | `design/drivers/schema-matching.md` (future) |
| DR-O2 | Blob driver activation policy — user-consent flow, threat model documentation. | `design/drivers/blob-policy.md` (future) |
| DR-O3 | Schema versioning for handoff — concrete migration framework. | `design/drivers/handoff-schemas.md` (future) |
| DR-O4 | Driver-registry storage — is it a CoW FS file, an in-memory structure, or a kernel-side artifact? | `design/system/driver-registry.md` (future) |
| DR-O5 | Resource conflict resolution — when two drivers could match a device, the supervisor needs documented tiebreaker rules. | `design/drivers/resource-arbitration.md` (future) |
| DR-O6 | Driver versioning and rollback — how does the supervisor handle a driver update that crashes immediately? | `design/drivers/version-rollback.md` (future) |
| DR-O7 | The driver-binary signature — every driver binary is release-line-signed per the PQ trust root, but the verification step in the supervisor needs concrete spec. | `design/security/driver-signing.md` (future) |
| DR-O8 | Bus driver enumeration order at boot — does PCIe enumerate before USB? Before virtio? Does it matter? | `design/drivers/boot-enumeration-order.md` (future) |
| DR-O9 | The CPU-hotplug case (CPU online/offline) — is the CPU a "device" in the framework? | `design/drivers/cpu-hotplug.md` (future) |
| DR-O10 | Cascade-restart policy — concrete numbers and behavior on persistent failure. | `design/system/restart-policy.md` (future) |
| DR-O11 | Per-driver test corpus — how is each driver's correctness verified? | `design/drivers/per-driver-tests.md` (future) |
| DR-O12 | Performance baselines — first bare-metal measurements drive `perf-baselines.md`. | `design/drivers/perf-baselines.md` (future) |

---

## 17. References

### 17.1 Microkernel driver frameworks

- Klein, G. et al. *seL4: Formal Verification of an OS Kernel*. SOSP 2009. (Driver model context.)
- Härtig, H. et al. *The Performance of µ-Kernel-Based Systems*. SOSP 1997. (Foundational microkernel driver performance.)
- Genode OS Framework documentation. (Distributed userspace driver pattern, comparable to PaideiaOS's.)
- Fuchsia / Zircon driver model documentation. (Modern microkernel driver framework.)

### 17.2 Hardware buses

- PCI Express Base Specification 6.0. (PCIe enumeration, hot-plug.)
- USB 3.2 Specification (USB device enumeration).
- xHCI Specification 1.2.
- Virtio Specification 1.2.

### 17.3 Hot-plug and lifecycle

- ACPI Specification chapters on hot-plug events.
- USB Implementers Forum: hot-plug guidance.

### 17.4 IOMMU and DMA isolation

- Intel VT-d Architecture Specification.
- *DMA Protection on Modern Systems*. Various academic references on IOMMU effectiveness.

### 17.5 Live update / handoff

- Linux kexec / kpatch documentation (illustrative; PaideiaOS's handoff is process-level, not kernel-level).
- *Live Update for OS Kernels*. (Research literature.)

---

*End of document.*
