# Kernel Capability Kind Taxonomy (ξ-01)

## 1. Purpose and scope

paideia-os is a pure capability-based microkernel: every kernel-mediated
resource a process can name is reached through a capability descriptor
`{kind: u64, rights: u64, target_ptr: u64}` (24 bytes) stored in a
256-slot `cap_table`. Every descriptor carries a **kind**, and every
kind is defined in its own `src/kernel/core/cap/kind_*.pdx` file (112
files at this writing) or, for the 16 base kinds, in
`src/kernel/core/cap/kind.pdx`.

This document is a full enumeration of that kind space: canonical hex
ID, derivation base, rights-ceiling constant, op-surface size, and
consuming subsystem, for every kind found in the tree today. It is a
reference document, not a design proposal — every row is read directly
out of source, and every claim of "real" vs. "stub" status is taken
from the implementing file's own comments, not inferred.

This is ξ-01 in a five-document wave written together this session. It
is prerequisite reading for two sibling documents:

- `design/architecture/syscall-table-v2.md` (ξ-02) — the syscall
  surface that resolves cap-table slots and invokes them.
- `design/architecture/security-model-overview.md` (ξ-05) — the
  security argument that depends on the derivation lattice this
  document catalogs.

Both may or may not exist on disk at the moment this file is read; they
are part of the same wave regardless.

## 2. Two kind spaces

**Base kinds** are a closed 16-entry enum (`Kind.KIND_*` in
`kind.pdx`), encoded in 4 LAM tag bits so the fast-dispatch path can
route on a hardware-cheap field. Per `kind.pdx`'s own header: "the
kernel's descriptor-table dispatch on kind is an exhaustive switch...
the closed 16-kind enum." The enum is full (slots 0–15 all assigned)
and frozen — adding a 17th base kind would require a major LAM-layout
event, and `kind.pdx` says so explicitly (line 38: "any future
post-D6 base-kind addition would need to displace slot 15 and require
a major-version event").

**Derived kinds** refine a base kind's rights and descriptor tail
without occupying a new LAM slot. A derived kind's descriptor still
carries its parent's base kind in the 4-bit LAM hint (so the
fast-dispatch path still routes correctly), but the full `kind` field
that `cap_invoke_dispatch` actually compares is a wider numeric tag —
either a small out-of-band value chosen ad hoc early on (`KIND_DRIVER
= 0x15`, `KIND_DMESG = 0x16`), or, from the R29 wave onward, a value in
a contiguous `0x140`–`0x1FF` block allocated in order as each round
lands. Every dispatcher compares the **full u64 kind field**
(`cmp rcx, 0x1b8; je call_kind_surface`), never just the 4-bit slot,
because many derived kinds share one LAM hint — every
`KIND_IPC_ENDPOINT`-derived kind (sessions, subscriptions, TTYs,
sockets, surfaces, seats, screencasts — over 30 of the 98 derived kinds
below) shares LAM slot 5.

## 3. Base kind enum (closed, `kind.pdx`)

| ID | Kind | Description |
|---|---|---|
| 0 | `KIND_NULL` | placeholder, unused descriptor |
| 1 | `KIND_PROCESS` | TCB pointer, CSpace root |
| 2 | `KIND_THREAD` | scheduler context (inherited Phase-1 name) |
| 3 | `KIND_PAGE_TABLE` | address-space paging structures (PML4 root) |
| 4 | `KIND_PAGE` (alias `KIND_MEMORY`) | individual memory page or region; derivation base for the entire memory-authority family (pdxfs, volumes, GPU buffers, framebuffers, crypto keys, ...) |
| 5 | `KIND_IPC_ENDPOINT` | send/recv IPC primitive endpoint; derivation base for the largest derived-kind family (sessions, sockets, TTY, surfaces, seats, GPU contexts, wireless VIFs, ...) |
| 6 | `KIND_IPC_PORT` | port-mapped I/O capability |
| 7 | `KIND_SCHED_CTX` | budget/period/priority donation, seL4-MCS style |
| 8 | `KIND_TIMER` | event scheduling and wakeups |
| 9 | `KIND_INTERRUPT` | vector number + CPU affinity mask (legacy; see §7) |
| 10 | `KIND_DEVICE` | device memory region and configuration; derivation base for the ACPI/PCI/USB/audio/storage/display device family |
| 11 | `KIND_IO_PORT` | I/O port access, per driver |
| 12 | `KIND_NOTIFICATION` | async signaling primitive (counting semaphore + payload) |
| 13 | `KIND_REPLY` | one-shot return-path endpoint for RPC |
| 14 | `KIND_HW` | hardware-adjacent base (promoted from a "fault" placeholder at R29.M0-001, #1017); shelters `KIND_HW_INTERRUPT`/`KIND_HW_MSIX_VECTOR`/`KIND_AUDIO_CLOCK`/`KIND_DISPLAY_TIMELINE`/`KIND_USER` |
| 15 | `KIND_RESERVED` | reserved for confidential-computing/TDX (CAP-Q9); also the nominal base for `KIND_DMESG` |

`KIND_MASK = 0xF` extracts the kind from LAM tag bits 53–50.

### Base-kind handler status

Each base kind has its own `kind_*.pdx` handler file (`kind_process`,
`kind_thread`, `kind_page_table`, `kind_page`, `kind_ipc`,
`kind_ipc_port`, `kind_sched`, `kind_timer`, `kind_interrupt`,
`kind_dev`, `kind_notification`, `kind_reply`), plus two more that
implement derived kinds carried at out-of-band tags above the 4-bit
range (`kind_dmesg`, `kind_blkdev`). Status, read from each file's own
header:

| File | Base kind | Status |
|---|---|---|
| `kind_process.pdx` | 1 | Real. `OP_CREATE` allocates a process-pool slot + fresh PML4 via `aspace_create`; `OP_GET_ASPACE_ROOT` reads it back. |
| `kind_thread.pdx` | 2 | Partially real. `OP_CREATE` allocates a thread-pool slot; `OP_START` is a stub that "returns 0 (OK) — real scheduler enqueue deferred to R14." |
| `kind_page_table.pdx` | 3 | **Stub.** Header states plainly: "Real handler deferred to R14... Kind=3 remains a fallthrough (mov rax, rsi; ret) exactly as today." Four named blockers (arg encoding, no current-aspace resolver, huge-page walker collision, no userspace minter). |
| `kind_page.pdx` | 4 | Real. `OP_READ`/`OP_WRITE` against a fixed kernel test buffer, with bounds-checked index and rights gating. |
| `kind_ipc.pdx` | 5 | Real. `OP_SEND`/`OP_RECV` wrap `ipc_enqueue`/`ipc_dequeue`; header notes the channel is currently global, with "scoped channel invocation deferred to R13." |
| `kind_ipc_port.pdx` | 6 | Real. `OP_SEND`/`OP_RECV` against a 64-slot `_port_pool`, with would-block semantics on full/empty. |
| `kind_sched.pdx` | 7 | Real. `OP_YIELD` wraps `sched_yield`. |
| `kind_timer.pdx` | 8 | Real. `OP_ARM`/`OP_CANCEL`/`OP_READ_TSC` against the LAPIC TSC-deadline MSR. |
| `kind_interrupt.pdx` | 9 | **Stub, and deprecated.** Header: "R13-m6-006... KIND_INTERRUPT structural stub. Real body deferred to R14... Emits cap_int_msg, returns INVOKE_UNSUPPORTED for every op." `kind.pdx` additionally marks slot 9 "deprecated at R29.M1-001 close but preserved as compatibility alias" in favor of `KIND_HW_INTERRUPT` (0x140). |
| `kind_dev.pdx` | 10 | Real but narrow. One op (`OP_MAP_MMIO`) wired to `request_mmio_mapping`, hardcoded to LAPIC test arguments (`phys=0xFEE00000`) — a real handler, not yet a general MMIO-request path. |
| `kind_notification.pdx` | 12 | Real. `OP_SIGNAL`/`OP_WAIT`/`OP_POLL` against a 64-slot pool, counting-semaphore + last-write-wins payload semantics. |
| `kind_reply.pdx` | 13 | Real. `OP_REPLY` (one-shot consume) / `OP_STATUS` against a 64-slot pool. |
| `kind_dmesg.pdx` | 15 (derived tag 0x16) | Real. `OP_READ_TAIL`/`OP_STAT` against the kernel log ring; read-only (`RIGHT_READ` only, no mutation ops). |
| `kind_blkdev.pdx` | dual (rides NVMe-namespace or AHCI-port row, family byte at target_ptr[23:16]) | Real. Row-indirection accessor layer over the two families' own tables; `KIND_BLKDEV = 0x42` is declared not in this file but in `src/kernel/core/cap/blkdev_cap.pdx` — an exception to the one-constant-per-file convention every other kind follows. |

`KIND_IO_PORT` (11) has no dedicated `kind_io_port.pdx` handler file in
the tree — it is a live base slot (used as a derivation parent by
`KIND_OP_REGION`'s port-space rows) with no standalone cap-invoke
handler found under `src/kernel/core/cap/`.

## 4. The derived-kind lattice

A derived kind is defined by two things: which base kind it rides for
LAM fast-dispatch, and — the part that actually carries the security
argument — which *parent capability* its mint gate demands. The
pattern recurring across nearly every derived-kind header in the tree
is: **the kind check alone is an empty gate**. Stating "derives over
KIND_DEVICE" or "derives over KIND_IPC_ENDPOINT" discriminates nothing
by itself, because every PCI function in the machine is a
`KIND_DEVICE` and every endpoint in the system — the shell's stdout
included — is a `KIND_IPC_ENDPOINT`. The actual authority check is
always a second condition: the parent slot must carry `RIGHT_MINT`,
and often a specific *inherited identity* (a GSI, a bus address, a
device key) must be read out of the parent's own row rather than
accepted as a caller-supplied argument. `kind_gpio_line.pdx` states the
resulting rule as plainly as any file in the tree: "THE PIN COMES FROM
THE CAPABILITY ROW, NEVER FROM THE CALLER" — and the same sentence,
with a different noun, appears verbatim in `kind_i2c_slave.pdx`
("THE ADDRESS COMES FROM THE CAPABILITY ROW...") and
`kind_acpi_event.pdx` (the GSI "is INHERITED, never accepted").

The derivation is also **monotone**: a child can never hold more reach
than its parent already proved. `kind_op_region.pdx` states this
explicitly (line 185 of that file, at its rights-and-derivation
section): "DERIVE IS MONOTONE. `opregion_cap_derive` requires
`(child_rights & parent_rights) == child_rights`. A sub-window can only
ever be narrower in rights as well as in extent, so no chain of
derivations can end up holding more than its root did." The same file
makes the point concrete: "a read-only 4 KiB window could [otherwise]
derive a writable 4 KiB window inside itself" if the containment check
covered addresses but not rights.

Two structural consequences follow from "closed base enum, open
derived-kind lattice":

- **A derived kind can itself be a parent.** The lattice is not one
  level deep. `KIND_I2C_SLAVE` (0x153) derives over `KIND_I2C_BUS`
  (0x152), not over the `KIND_DEVICE` base slot directly.
  `KIND_ACPI_EVENT` (0x151) derives over `KIND_HW_INTERRUPT` (0x140),
  itself a derived kind. `KIND_USB_HUB`/`KIND_USB_INTERFACE` derive
  over `KIND_USB_DEVICE`; `KIND_MSC_LUN` over `KIND_USB_INTERFACE`;
  `KIND_SCSI_DEVICE` over `KIND_MSC_LUN` — a four-deep chain rooted at
  `KIND_DEVICE`. Revoking a node in the chain must cascade: several
  files implement `*_cascade_revoke_by_parent` walks, and
  `kind_op_region.pdx` runs its cascade as a fixed-point loop
  specifically because "a window may be derived from a window" — a
  single pass would leave a grandchild row alive.
- **The base slot can vary per row of the same kind.** `KIND_OP_REGION`
  (0x150) is the one exception to "one derived kind, one fixed base":
  a memory-space region derives over `KIND_MEMORY` (4) and a port-space
  region over `KIND_IO_PORT` (11), decided per-row by
  `opregion_space_base_kind`. Because the base slot is not a constant
  for this kind, `kind.pdx` notes the dispatcher must compare the full
  `0x150` tag rather than rely on the LAM hint at all.

## 5. Full derived-kind enumeration

One row per `kind_*.pdx` file that is not itself a base-kind handler
(98 files; see §3 for the other 14). "Rights ceiling" is the `_ALL`
constant (the OR of every legal rights bit, used as the mint-time
subset check) where the file names one. "Ops" is the `OP_MAX` /
`*_OP_MAX` constant where the file uses the numbered-op-code dispatch
pattern; several kinds instead expose a small fixed set of named
functions (mint/destroy/query) with no numbered op table, marked
"n/a (named fns)". Consumer is cited by name where a file's header
names one; "kernel-internal substrate" is the honest default where
nothing is named — most of these have not had their user-side
consumer traced for this pass.

| Hex ID | Kind | Base | Rights ceiling | Ops | Consumer |
|---|---|---|---|---|---|
| 0x15 | `KIND_DRIVER` | KIND_DEVICE (10) | — (reservation only) | n/a | No `kind_driver.pdx` implementation exists; declared in `kind.pdx` as "driver refinement expressed in the descriptor's kind-specific tail" but never given a handler file. Reservation-only. |
| 0x50 | `KIND_UDP_SOCKET` (legacy) | KIND_MEMORY (4) | `R_UDP_ALL`=0x07 | n/a | **Retired.** `udp_socket_cap.pdx`'s R27.M6 value; `kind.pdx` explicitly retires it ("treated as dead weight per issue #2008... a stale reference to it must fail loudly") in favor of the unrelated 0x1A8 below. |
| 0x140 | `KIND_HW_INTERRUPT` | KIND_HW (14) | `R_HW_INT_ALL`=0x618 | n/a (named fns) | Kernel-internal substrate: GSI/affinity/trigger-mode authority; parent for MSI-X vectors and ACPI events below. |
| 0x141 | `KIND_HW_MSIX_VECTOR` | KIND_HW_INTERRUPT (0x140) | `R_MSIX_ALL`=0x218 | n/a (named fns) | Kernel-internal substrate; one row per MSI-X vector under a parent interrupt line. |
| 0x142 | `KIND_DMA_DOMAIN` | KIND_MEMORY (4) | `R_DMA_ALL`=0x618 | n/a (named fns) | IOMMU domain, one per driver process; consumer is the driver-process teardown path. |
| 0x150 | `KIND_OP_REGION` | KIND_MEMORY (4) *or* KIND_IO_PORT (11), per-row | `R_OPREG_ALL`=0x61B | n/a (query-only fns, deliberately no "poke" op) | ACPI firmware-table window authority; consumer is the ring-3 ACPI supervisor. |
| 0x151 | `KIND_ACPI_EVENT` | KIND_HW_INTERRUPT (0x140) | `R_ACPI_EVT_ALL`=0x618 | n/a (named fns) | ACPI platform-event (GPE/SCI) subscriber; consumer is the ACPI event-dispatch supervisor. |
| 0x152 | `KIND_I2C_BUS` | KIND_DEVICE (10) | `R_I2C_BUS_ALL`=0x618 | n/a (named fns; no transact op by design) | I2C controller driver. Deliberately non-transacting — see §4. |
| 0x153 | `KIND_I2C_SLAVE` | KIND_I2C_BUS (0x152) | `R_I2C_SLAVE_ALL`=0x41B | n/a (named fns) | Per-device I2C driver (touchpad, fingerprint reader, sensor hub, battery gauge). |
| 0x154 | `KIND_GPIO_LINE` | KIND_DEVICE (10) (`GPIO_LINE_PARENT_KIND`=10) | `R_GPIO_LINE_ALL`=0x41F | `GPIO_LINE_OP_MAX`=13 | Pad-controller pin driver (reset lines, power-rail enables, write-protect straps). |
| 0x155 | `KIND_FW_SESSION` | KIND_IPC_ENDPOINT (5) | `R_FW_SESSION_ALL`=0x41B | `FW_SESSION_OP_MAX`=6 | ACPI supervisor conversation session; named to avoid the forbidden "AML" token per `tools/lint-no-kernel-aml.sh`. |
| 0x156 | `KIND_EC_QUERY` | KIND_IPC_ENDPOINT (5) + 2nd-arg live `KIND_OP_REGION` (space=EC) | `R_EC_QUERY_ALL`=0x41A | `EC_QUERY_OP_MAX`=6 | Embedded-controller query-event subscriber. Not loader-seedable. |
| 0x157 | `KIND_THERMAL_ZONE` | KIND_DEVICE (10) | `R_THERMAL_ALL`=0x41B | `THERMAL_OP_MAX`=8 | Thermal-management supervisor; unit is deci-Kelvin throughout. Not loader-seedable. |
| 0x158 | `KIND_BATTERY` | KIND_DEVICE (10) | `R_BATTERY_ALL`=0x41B | `BATTERY_OP_MAX`=9 | Power-management supervisor; units are percent/mWh/mV. Not loader-seedable. |
| 0x159 | `KIND_COOLING_DEVICE` | KIND_DEVICE (10) | `R_COOLING_ALL`=0x41B | `COOLING_OP_MAX`=8 | Thermal-management supervisor (fan/throttle/power-state control). Not loader-seedable. |
| 0x15a | `KIND_BACKLIGHT` | KIND_DEVICE (10) | `R_BACKLIGHT_ALL`=0x41B | `BACKLIGHT_OP_MAX`=8 | Compositor (one-cap-per-panel invariant enforced structurally, issue #1106). Not loader-seedable. |
| 0x15b | `KIND_HID_DEVICE` | KIND_DEVICE (10) | `R_HID_ALL`=0x41B | `HID_OP_MAX`=8 | HID class-driver-in-ring-3. No setter for identity/transport/report-count. Not loader-seedable. |
| 0x15c | `KIND_HID_EVENT` | KIND_IPC_ENDPOINT (5) | `R_HID_EVENT_ALL`=0x41B | `HID_EVT_OP_MAX`=4 | HID input event subscriber; key = (endpoint_id, event_type_mask). Not loader-seedable. |
| 0x15d | `KIND_SENSOR_CHANNEL` | KIND_IPC_ENDPOINT (5) | `R_SENSOR_ALL`=0x41B | `SENSOR_OP_MAX`=7 | ALS/accel/gyro sensor subscriber; rate changes require revoke+remint. Not loader-seedable. |
| 0x15e | `KIND_AUDIO_CONTROLLER` | KIND_DEVICE (10) | `R_AUDIO_CTRL_ALL`=0x41B | `AUDIO_CTRL_OP_MAX`=8 | HDA audio subsystem; `bar_handle` is opaque, never dereferenced by this kind. Not loader-seedable. |
| 0x15f | `KIND_PCM_STREAM` | KIND_IPC_ENDPOINT (5) | `R_PCM_STREAM_ALL`=0x41B | `PCM_STREAM_OP_MAX`=9 | Audio subsystem PCM stream; linear (no reparent) once minted. |
| 0x160 | `KIND_AUDIO_CLOCK` | KIND_HW (14) | `R_AUDIO_CLOCK_ALL`=0x41B | `AUDIO_CLOCK_OP_MAX`=6 | Audio subsystem clock domain feeding PCM streams. |
| 0x161 | `KIND_AUDIO_ROUTE` | KIND_IPC_ENDPOINT (5) | `R_AUDIO_ROUTE_ALL`=0x41B | `AUDIO_ROUTE_OP_MAX`=8 | Audio subsystem routing graph. |
| 0x162 | `KIND_USB_DEVICE` | KIND_DEVICE (10) | `R_USB_DEVICE_ALL`=0x619 | `USBD_OP_MAX`=4 | USB stack; root of the USB derived-kind chain (hub/interface/endpoint below). |
| 0x163 | `KIND_USB_HUB` | KIND_USB_DEVICE (0x162) | `R_USB_HUB_ALL`=0x419 | `USBH_OP_MAX`=5 | USB hub driver. |
| 0x164 | `KIND_USB_INTERFACE` | KIND_USB_DEVICE (0x162) | `R_USB_IF_ALL`=0x619 | `USBIF_OP_MAX`=7 | USB class-driver interface binding. |
| 0x165 | `KIND_USB_ENDPOINT` | KIND_IPC_ENDPOINT (5) | `R_USB_EP_ALL`=0x419 | `USBEP_OP_MAX`=7 | USB transfer endpoint. |
| 0x166 | `KIND_MSC_LUN` | KIND_USB_INTERFACE (0x164) | `R_MSC_LUN_ALL`=0x619 | `MSCLUN_OP_MAX`=3 | USB mass-storage class LUN. |
| 0x167 | `KIND_SCSI_DEVICE` | KIND_MSC_LUN (0x166) | `R_SCSI_DEV_ALL`=0x419 | `SCSIDEV_OP_MAX`=5 | SCSI-over-USB storage stack. |
| 0x168 | `KIND_USB_URB` | KIND_IPC_ENDPOINT (5) | `R_USB_URB_ALL`=0x419 | `URB_OP_MAX`=5 | USB request-block transfer primitive. |
| 0x169 | `KIND_ISOCH_STREAM` | KIND_USB_ENDPOINT (0x165) | `R_ISOCH_STREAM_ALL`=0x419 | `ISOCH_OP_MAX`=6 | USB isochronous stream (audio/video class drivers). |
| 0x16a | `KIND_FP_SENSOR` | KIND_DEVICE (10) | `R_FP_SENSOR_ALL`=0x419 | `FP_OP_MAX`=8 | Fingerprint-sensor driver. |
| 0x16b | `KIND_PCIE_HOTPLUG_EVENT` | KIND_IPC_ENDPOINT (5) | `R_PCIE_HP_EVT_ALL`=0x419 | `PCIE_HP_EVT_OP_MAX`=6 | PCIe hotplug event subscriber. |
| 0x16c | `KIND_TB_DOMAIN` | KIND_DEVICE (10) | `R_TB_DOMAIN_ALL`=0x419 | `TB_DOM_OP_MAX`=7 | Thunderbolt domain controller. |
| 0x16d | `KIND_TB_ROUTE` | KIND_IPC_ENDPOINT (5) | `R_TB_ROUTE_ALL`=0x419 | `TB_RTE_OP_MAX`=8 | Thunderbolt route/tunnel authority. |
| 0x16e | `KIND_DMA_ATTESTATION` | KIND_IPC_ENDPOINT (5) | `R_DMA_ATTEST_ALL`=0x419 | `DMA_ATT_OP_MAX`=7 | DMA-attestation record consumer (security-relevant IOMMU audit trail). |
| 0x16f | `KIND_DISPLAY_ENGINE` | KIND_DEVICE (10) | `R_DISPLAY_ENGINE_ALL`=0x419 | `DPY_ENG_OP_MAX`=7 | Display/GPU subsystem. |
| 0x170 | `KIND_DISPLAY_OUTPUT` | KIND_DEVICE (10) | `R_DISPLAY_OUTPUT_ALL`=0x419 | `DPO_OP_MAX`=7 | Display subsystem; parent of `KIND_PAGE_FLIP`. |
| 0x171 | `KIND_MODESET_TXN` | KIND_IPC_ENDPOINT (5) | `R_MODESET_TXN_ALL`=0x419 | `MTX_OP_MAX`=5 | Display modeset transaction (compositor atomic-modeset path). Linear. |
| 0x172 | `KIND_DISPLAY_MODE` | KIND_MEMORY (4) | `R_DISPLAY_MODE_ALL`=0x419 | `DPM_OP_MAX`=7 | Display mode descriptor. Mint is a documented stub for one implicit field: "refresh_hz and flags are IMPLICIT in this milestone... `mode_enum.pdx` will replace this stub with a seventh-arg-carrying wrapper" (kind_display_mode.pdx). |
| 0x173 | `KIND_DISPLAY_PLANE` | KIND_MEMORY (4) | `R_DISPLAY_PLANE_ALL`=0x419 | `DPP_OP_MAX`=7 | Display/GPU scanout plane; parent of `KIND_SCANOUT_LEASE`. |
| 0x174 | `KIND_GPU_BO` | KIND_MEMORY (4) | `R_GPU_BO_ALL`=0x41B | `KGB_OP_MAX`=6 | GPU buffer object; parent of the Vulkan/Vello render-object family below. |
| 0x175 | `KIND_GPU_VM` | KIND_IPC_ENDPOINT (5) | `R_GPU_VM_ALL`=0x41B | `KGVM_OP_MAX`=5 | GPU virtual-address-space; header marks it LEAF. |
| 0x176 | `KIND_GPU_CONTEXT` | KIND_IPC_ENDPOINT (5) | `R_GPU_CTX_ALL`=0x41B | `KGCTX_OP_MAX`=7 | GPU rendering context. Linear. |
| 0x177 | `KIND_GPU_SUBMIT` | KIND_IPC_ENDPOINT (5) | `R_GPU_SUB_ALL`=0x41B | `KGSUB_OP_MAX`=6 | GPU command submission. Linear. |
| 0x178 | `KIND_WIFI_PHY` | KIND_DEVICE (10) | `R_WPHY_ALL`=0x419 | `WPHY_OP_MAX`=6 | WiFi PHY driver. |
| 0x179 | `KIND_WIFI_VIF` | KIND_IPC_ENDPOINT (5) | `R_WVIF_ALL`=0x41B | `WVIF_OP_MAX`=7 | WiFi virtual interface. |
| 0x17a | `KIND_WIFI_SCAN_TXN` | KIND_IPC_ENDPOINT (5) | `R_WSCN_ALL`=0x41B | `WSCN_OP_MAX`=6 | WiFi scan transaction. Linear. |
| 0x17b | `KIND_WIFI_KEY` | KIND_MEMORY (4) | `R_WKEY_ALL`=0x418 | `WKEY_OP_MAX`=7 | WiFi encryption key. SEALED — no op exposes the raw key bytes (header: "them expose the underlying bytes"). |
| 0x17c | `KIND_BT_GATT_CONNECTION` | KIND_IPC_ENDPOINT (5) | `R_KBGC_ALL`=0x41B | `KBGC_OP_MAX`=7 | Bluetooth GATT connection. |
| 0x17d | `KIND_BT_PAIRING` | KIND_MEMORY (4) | `R_BTP_ALL`=0x418 | `BTP_OP_MAX`=8 | Bluetooth pairing state. SEALED — no op exposes the LTK bytes. |
| 0x17e | `KIND_CSI_CAMERA` | KIND_DEVICE (10) | `R_CCAM_ALL`=0x419 | `CCAM_OP_MAX`=7 | MIPI CSI camera driver. |
| 0x17f | `KIND_IPU6_STREAM` | KIND_IPC_ENDPOINT (5) | `R_IPU6S_ALL`=0x419 | `IPU6S_OP_MAX`=7 | Intel IPU6 camera ISP stream. |
| 0x180 | `KIND_WWAN_MODEM` | KIND_DEVICE (10) | `R_WWM_ALL`=0x419 | `WWM_OP_MAX`=6 | WWAN/cellular modem driver. |
| 0x181 | `KIND_MBIM_SESSION` | KIND_IPC_ENDPOINT (5) | `R_MBS_ALL`=0x419 | `MBS_OP_MAX`=6 | MBIM (mobile broadband) session. |
| 0x182 | `KIND_BT_ADAPTER` | KIND_DEVICE (10) | `R_KBA_ALL`=0x419 | `KBA_OP_MAX`=6 | Bluetooth adapter/controller. |
| 0x183 | `KIND_BT_HCI_CHANNEL` | KIND_IPC_ENDPOINT (5) | `R_KBHC_ALL`=0x41B | `KBHC_OP_MAX`=5 | Bluetooth HCI transport channel. |
| 0x184 | `KIND_BT_L2CAP_CHANNEL` | KIND_IPC_ENDPOINT (5) | `R_KBL2C_ALL`=0x41B | `KBL2C_OP_MAX`=7 | Bluetooth L2CAP channel. |
| 0x185 | `KIND_DISPLAY_TIMELINE` | KIND_HW (14) | `R_DPT_ALL`=0x41B | `DPT_OP_MAX`=4 | Display/GPU explicit-sync timeline. |
| 0x186 | `KIND_VRR_RANGE` | KIND_MEMORY (4) (parented from `KIND_DISPLAY_MODE`) | `R_VRR_ALL`=0x419 | `VRR_OP_MAX`=5 | Variable-refresh-rate range descriptor. |
| 0x187 | `KIND_VMD_ENDPOINT` | KIND_DEVICE (10) | `R_KVE_ALL`=0x419 | `KVE_OP_MAX`=4 | Intel VMD (Volume Management Device) endpoint. |
| 0x188 | `KIND_SCANOUT_LEASE` | KIND_MEMORY (4) (via `KIND_DISPLAY_PLANE`) | `R_SL_ALL`=0x419 | `SL_OP_MAX`=6 | Display scanout-plane lease. |
| 0x189 | `KIND_VK_SURFACE` | KIND_IPC_ENDPOINT (5) | `R_VKS_ALL`=0x619 | `VKS_OP_MAX`=7 | Vulkan presentation surface. |
| 0x18a | `KIND_VK_SWAPCHAIN_IMAGE` | KIND_MEMORY (4) (over `KIND_GPU_BO`) | `R_VKSI_ALL`=0x419 | `VKSI_OP_MAX`=8 | Vulkan swapchain image. |
| 0x18b | `KIND_FONT_ATLAS` | KIND_MEMORY (4) (over `KIND_GPU_BO`) | `R_FA_ALL`=0x619 | `FA_OP_MAX`=6 | Text-rendering font atlas. |
| 0x18c | `KIND_TEXT_SHAPE` | KIND_MEMORY (4) | `R_TS_ALL`=0x619 | `TS_OP_MAX`=9 | Text shaping result buffer. |
| 0x18d | `KIND_VELLO_SCENE` | KIND_MEMORY (4) (over `KIND_GPU_BO`) | `R_VS_ALL`=0x619 | `VS_OP_MAX`=6 | Vello (GPU vector) renderer scene graph. |
| 0x18e | `KIND_VELLO_RENDERER` | KIND_IPC_ENDPOINT (5) (over `KIND_GPU_CONTEXT`) | `R_VR_ALL`=0x619; also `VR_CAP_ALL`=0x00FF (separate constant, purpose not disambiguated in this pass) | `VR_OP_MAX`=7 | Vello renderer instance. |
| 0x18f | `KIND_COLOR_PROFILE` | KIND_MEMORY (4) | `R_CP_ALL`=0x619 | `CP_OP_MAX`=7 | Display color-management profile. |
| 0x190 | `KIND_USER` | KIND_HW (14) | `R_USER_ALL`=0x619 | `USER_OP_MAX`=7 | User-identity/session-account capability. |
| 0x191 | `KIND_ELEVATE_CHANNEL` | KIND_IPC_ENDPOINT (5) | `R_ELVC_ALL`=0x418 | `ELVC_OP_MAX`=8 | Privilege-elevation request channel; a race-detection writer (`elevate_channel_row_set_expire`) explicitly never no-ops on a reaped row so "a stubbed broker can surface the race in its own audit trail" — the broker consumer is still being built out. |
| 0x195 | `KIND_PDXFS_FILE` | KIND_MEMORY (4) | `R_PDXFS_FILE_ALL`=0x61B | `PFF_OP_MAX`=7 | PdxFS filesystem open-file handle; parent of `KIND_INODE_HANDLE`. |
| 0x196 | `KIND_PDXFS_TXN` | KIND_MEMORY (4) | `R_PDXFS_TXN_ALL`=0x618 | `PXT_OP_MAX`=11 (widened from 6; the R42-PREP-007 stub-return sentinel `PXT_STUB_OK` is fully retired as of R52.M6-006, #1714 — a stub that has since been resolved, not a live gap) | PdxFS transaction (COMMIT/ABORT/CREATE/RENAME/UNLINK all delegate to real WAL + directory-op bodies). |
| 0x197 | `KIND_TTY` | KIND_IPC_ENDPOINT (5) | `R_TTY_ALL`=0x69A | `TTY_OP_MAX`=13 | Shell / line-discipline TTY. |
| 0x198 | `KIND_NVME_CONTROLLER` | KIND_DEVICE (10) | `R_NVMEC_ALL`=0x61F | `NVMEC_OP_MAX`=8 | NVMe storage controller. |
| 0x199 | `KIND_NVME_NAMESPACE` | KIND_MEMORY (4) | `R_NVMEN_ALL`=0x41F | `NVMEN_OP_MAX`=7 | NVMe namespace; dual-mints a sibling `KIND_BLKDEV` (0x42) row. |
| 0x19a | `KIND_AHCI_CONTROLLER` | KIND_DEVICE (10) | `R_AHCIC_ALL`=0x43F | `AHCIC_OP_MAX`=4 | AHCI (SATA) HBA controller. Revoke was landed as a stub at R51.M5-001 with the header noting "cascade widens at M5-004... once KIND_AHCI_PORT exists" — resolved by the time `KIND_AHCI_PORT` below landed. |
| 0x19b | `KIND_AHCI_PORT` | KIND_MEMORY (4) | `R_AHCIP_ALL`=0x41F | `AHCIP_OP_MAX`=7 | AHCI port; dual-mints a sibling `KIND_BLKDEV` row. Its own revoke primitive originally landed with a "CASCADE STUB" per its header — verify current status against `kind_ahci_port.pdx` directly before relying on cascade-on-revoke behavior. |
| 0x1a0 | `KIND_VOLUME` | KIND_MEMORY (4) | `R_VOL_ALL`=0x43B | `VOL_OP_MAX`=10 | Storage volume (libpdx-volume). |
| 0x1a1 | `KIND_BLOCK_CACHE` | KIND_MEMORY (4) | `R_BC_ALL`=0x41B | `BC_OP_MAX`=8 | Block-device cache layer. |
| 0x1a2 | `KIND_INODE_HANDLE` | KIND_MEMORY (4); mint additionally gated on live parent `KIND_PDXFS_FILE` (0x195) | `R_INDH_ALL`=0x43B | `IH_OP_MAX`=5 | PdxFS inode handle. |
| 0x1a3 | `KIND_SIG_KEY` | KIND_MEMORY (4) | `R_SIGK_ALL`=0x439 | `SIGK_OP_MAX`=6 | Post-quantum signature key handle. |
| 0x1a5 | `KIND_PDXFS_MOUNT_TABLE` | KIND_MEMORY (4) | `R_PMT_ALL`=0x41B | `PMT_OP_MAX`=4 | PdxFS mount table. One accessor is a documented stub: "Returns 0 (stub) — real body needs cross-module `_mount_table[]` write access" (kind_pdxfs_mount_table.pdx). |
| 0x1a6 | `KIND_TUI_CANVAS` | KIND_MEMORY (4) | `R_TUI_ALL`=0x63A | `TUI_OP_MAX`=7 | Text-UI canvas buffer. |
| 0x1a7 | `KIND_TLS_TRUST` | KIND_MEMORY (4) | `R_TLS_TRUST_ALL`=0x001 | `TLS_TRUST_OP_MAX`=7 | TLS trust-store handle. |
| 0x1a8 | `KIND_UDP_SOCKET` (current) | KIND_IPC_ENDPOINT (5) | 0x00B (`R_UDP_READ\|WRITE\|INVOKE`; no separately named `_ALL` constant in `net/udp_socket.pdx`) | n/a; not dispatched through `cap_invoke_dispatch` — resolved directly by socket syscalls | Network stack; `sys_socket`/`sys_send`/`sys_recv` family. Root-minted, no parent-cap argument. Distinct from, and deliberately not aliased with, the retired 0x50 tag above. |
| 0x1ab | `KIND_TCP_SOCKET` | KIND_IPC_ENDPOINT (5) | not captured this pass | n/a; resolved directly by socket syscalls | Network stack (`src/kernel/core/net/tcp_socket.pdx`, `tcp.pdx` — not a `kind_*.pdx` file; see §6 naming exception). |
| 0x1ac | `KIND_TCP_LISTENER` | KIND_IPC_ENDPOINT (5) | not captured this pass | n/a | Network stack, same file as above. |
| 0x1ad | `KIND_NIC` | KIND_DEVICE (10) | `R_NIC_ALL`=0x001 | `NIC_OP_MAX`=2 | Network interface controller. |
| 0x1ae | `KIND_DISPLAY_BACKEND` | KIND_DEVICE (10) | `R_DPYB_ALL`=0x001 | `DPYB_OP_MAX`=0 | Display backend selection. Zero ops — an identity/marker capability with no invoke surface at all; confirm this is intentional rather than an unwired stub before relying on it. |
| 0x1af | `KIND_FRAMEBUFFER` | KIND_MEMORY (4) | `R_FB_ALL`=0x007 | `FB_OP_MAX`=4 | Framebuffer mapping; `sys_framebuffer_create`/`map`. |
| 0x1b0 | `KIND_PAGE_FLIP` | KIND_DISPLAY_OUTPUT (0x170) | `R_FLIP_ALL`=0x003 | `PGFL_OP_MAX`=2 | Display page-flip / vsync wait; `sys_page_flip*`. |
| 0x1b1 | `KIND_HOTPLUG_CHANNEL` | KIND_IPC_ENDPOINT (5) | `R_HPCH_ALL`=0x003 | `HPCH_OP_MAX`=2 | Display hotplug subscription; `sys_display_hotplug_subscribe`. |
| 0x1b2 | `KIND_SCHEMA_HANDLE` | KIND_MEMORY (4) | `R_KSH_ALL`=0x003 | `KSH_OP_MAX`=1 | Semantic-schema lookup handle. |
| 0x1b3 | `KIND_VOLUME_SNAPSHOT` | KIND_VOLUME (0x1a0) | `R_KVS_ALL`=0x007 | `KVS_OP_MAX`=2 | Storage volume snapshot (libpdx-volume). |
| 0x1b4 | `KIND_KEK` | KIND_MEMORY (4) | `R_KEK_ALL`=0x00F | `KEK_OP_MAX`=3 | Key-encryption-key handle (libpdx-volume crypto). A `KEK_STUB_SENTINEL` (0xFFFFEB57) is reserved in the failure-code table alongside comments naming WRAP/UNWRAP/DERIVE_CHILD — check `kind_kek.pdx` directly for whether those three ops are wired or still return the sentinel. |
| 0x1b8 | `KIND_SURFACE` | KIND_IPC_ENDPOINT (5) | `R_SURFACE_ALL`=0x7F9 | n/a (named fns) | postui compositor. Fully real: 16-row pool, LAM-generation header, exercised mint/destroy bodies. Identity authority is `src/user/compositor/surface_kind.pdx:102`, not this kernel file, per that file's own cross-reference comment. |
| 0x1bc | `KIND_SESSION` | KIND_IPC_ENDPOINT (5), abstract — concrete substrate parent is nil (root of its own sub-graph) | `R_SESSION_ALL`=0x639 | n/a (named fns) | Display-manager/shell/lock-screen session lifecycle. Real substrate (16-row pool); policy (who creates sessions, seat bindings at login) explicitly deferred to a follow-on session-manager landing. |
| 0x1be | `KIND_CAPTURE` | KIND_IPC_ENDPOINT (5), abstract | `R_CAPTURE_ALL`=0x639 | n/a (named fns: grant/revoke/check) | Screenshot/screencast consent gate. Real substrate (16-row pool); broker policy (who may mint, UX prompting, default grant duration) explicitly deferred to a follow-on capture-broker landing. |
| 0x1bf | `KIND_SEAT` | KIND_IPC_ENDPOINT (5) | `R_SEAT_ALL`=0x639 | n/a (named fns) | Compositor multi-seat input routing. Real substrate (8-row pool); the multi-seat input dispatcher that reads it is a follow-on landing. |
| 0x1c0 | `KIND_SCREENCAST` | KIND_IPC_ENDPOINT (5), abstract | `R_SCREENCAST_ALL`=0x439 | n/a (named fns) | Live screen-capture session (compositor); depends on a `KIND_CAPTURE` grant plus a `KIND_FRAME_CAPTURE` (0x1BD) transport endpoint. |
| 0x1e6 | `KIND_A11Y_NODE` (kernel) | none — same-kind self-reference (`parent_node_id` names another live `KIND_A11Y_NODE` row, not a parent-cap slot) | `R_A11Y_NODE_ALL`=0x419 | `ANODE_OP_MAX`=4 | Accessibility tree exposed to assistive-technology clients. Kernel-native; explicitly distinct from a same-named but differently-scoped userspace ordinal `0x1E2` in `src/user/a11y/kind_a11y_node.pdx`, whose own header says its row-pool substrate "DOES NOT EXIST YET" — that one is a stub, this kernel one is real. |

Rows without a captured rights/op value ("not captured this pass") were
not re-derived from source for this document; grep the cited file
directly.

## 6. Naming-convention exceptions found

Three files break the "one `kind_*.pdx` file declares its own
`KIND_X` constant" pattern this document otherwise relies on:

- `KIND_BLKDEV` (0x42) is declared in `blkdev_cap.pdx`, not in
  `kind_blkdev.pdx` — the latter is a row-indirection accessor layer
  written afterward (R51.M7-001, #1669) that reuses the constant.
- `KIND_TCP_SOCKET`/`KIND_TCP_LISTENER` (0x1AB/0x1AC) and
  `KIND_UDP_SOCKET` (0x1A8) are declared in `kind.pdx` but implemented
  in `src/kernel/core/net/tcp.pdx`, `tcp_socket.pdx`, and
  `udp_socket.pdx` — there is no `kind_tcp_socket.pdx` or (current)
  `kind_udp_socket.pdx` file. All three are also explicitly **not**
  dispatched through `cap_invoke_dispatch`; the header for 0x1A8 states
  "every UDP-socket op flows through the SC+ 87/88/91/92/93 syscalls,
  which resolve the cap_table slot directly... A stray cap_invoke on
  this slot falls through to `invoke.pdx`'s identity-return default,
  harmlessly."
- A retired `KIND_UDP_SOCKET` value (0x50, `udp_socket_cap.pdx`,
  R27.M6 #994) numerically collides in *name* but not in *value* with
  the current 0x1A8 kind of the same name. `kind.pdx` documents this
  as a deliberate non-alias, not a live bug, but it means a
  tree-wide grep for `KIND_UDP_SOCKET` returns two unrelated constants.

## 7. Failure-band allocation map (partial)

Most derived-kind files claim a dedicated hex range for their own
`INVOKE`/`MINT` failure codes, stated in the header as verified free
against sibling kinds at landing time. This is a best-effort partial
extraction — the following bands were found via a targeted grep for
"Failure taxonomy" / "FAILURE TAXONOMY" / "FAILURE BAND" headers across
`kind_*.pdx` (91 of 112 files carry such a marker); a handful of older
files (the base-kind handlers in §3, and a few early derived kinds that
predate the convention) use ad hoc sentinel values instead and are not
listed here.

| Band | Kind |
|---|---|
| 0xFFFFEA00–0xFFFFEA0F | `KIND_A11Y_NODE` |
| 0xFFFFEB00–0xFFFFEB0F | `KIND_ELEVATE_CHANNEL` |
| 0xFFFFEB30–0xFFFFEB3F | `KIND_DISPLAY_BACKEND` |
| 0xFFFFEB40–0xFFFFEB4F | `KIND_FRAMEBUFFER` |
| 0xFFFFEB50–0xFFFFEB5F | `KIND_PAGE_FLIP` |
| 0xFFFFEB57 | `KEK_STUB_SENTINEL` (within KIND_KEK's own band, see §5) |
| 0xFFFFEB60–0xFFFFEB6F | `KIND_HOTPLUG_CHANNEL` |
| 0xFFFFEC00–0xFFFFEC0F | `KIND_ELEVATE_CHANNEL` (SECTION 3, a second cited band — see file for which supersedes) |
| 0xFFFFEC00–0xFFFFEC7F | AHCI/NVMe R48b..R51.M4 shared bands |
| 0xFFFFEC80–0xFFFFEC8F | `KIND_AHCI_CONTROLLER` |
| 0xFFFFEC80–0xFFFFEC84 (+spillover 0xFFFFEC90–98) | `KIND_AHCI_PORT` |
| 0xFFFFECC0–0xFFFFECCF | `KIND_BLKDEV` |
| 0xFFFFED30–0xFFFFED37 | `KIND_BLOCK_CACHE` (R52.M7 band) |
| 0xFFFFEE20–0xFFFFEE2F | `KIND_FONT_ATLAS` |
| 0xFFFFEE40–0xFFFFEE4F | `KIND_COLOR_PROFILE` |
| 0xFFFFE110–0xFFFFE11F | `KIND_SURFACE` (kernel-side; user-side mint validators at 0xFFFFEEF1–0xFFFFEEFA in `src/user/compositor/surface_kind.pdx`) |
| 0xFFFFE2D0–0xFFFFE2DF | `KIND_CAPTURE` |
| 0xFFFFF130–0xFFFFF13F | `KIND_BT_HCI_CHANNEL` |
| 0xFFFFF140–0xFFFFF14F | `KIND_BT_ADAPTER` |
| 0xFFFFF100–0xFFFFF10F | `KIND_BT_L2CAP_CHANNEL` |
| 0xFFFFF1F0–0xFFFFF1FF | `KIND_IPU6_STREAM` |
| 0xFFFFF230–0xFFFFF23F | `KIND_CSI_CAMERA` |
| 0xFFFFF2F0–0xFFFFF2FF | `KIND_BT_PAIRING` |
| 0xFFFFF320–0xFFFFF32F | `KIND_BT_GATT_CONNECTION` |
| 0xFFFFF560–0xFFFFF56F | `KIND_GPU_SUBMIT` |
| 0xFFFFF5A0–0xFFFFF5AF | `KIND_GPU_CONTEXT` |
| 0xFFFFF5F0–0xFFFFF5FF | `KIND_GPU_VM` |
| 0xFFFFF640–0xFFFFF64F | `KIND_GPU_BO` |
| 0xFFFFF6A0–0xFFFFF6AF | `KIND_DISPLAY_TIMELINE` |
| 0xFFFFF6E0–0xFFFFF6EF | `KIND_DISPLAY_PLANE` |
| 0xFFFFF720–0xFFFFF72F | `KIND_DISPLAY_MODE` |
| 0xFFFFF730–0xFFFFF73F | `KIND_MODESET_TXN` |
| 0xFFFFF780–0xFFFFF78F | `KIND_DISPLAY_OUTPUT` |
| 0xFFFFF7C0–0xFFFFF7CF | `KIND_DISPLAY_ENGINE` |
| 0xFFFFFA80–0xFFFFFA8F | `KIND_FP_SENSOR` |
| 0xFFFFFAC0–0xFFFFFACF | `KIND_ISOCH_STREAM` |
| 0xFFFFFE00–0xFFFFFE0F | `KIND_EC_QUERY` |
| 0xFFFFFE10–0xFFFFFE1F | `KIND_FW_SESSION` |
| 0xFFFFFE40–0xFFFFFE4F | `KIND_BATTERY` |
| 0xFFFFFE50–0xFFFFFE5F | `KIND_COOLING_DEVICE` |
| 0xFFFFFE70–0xFFFFFE7F | `KIND_BACKLIGHT` |
| 0xFFFFFE80–0xFFFFFE8F | `KIND_HID_DEVICE` |
| 0xFFFFFE90–0xFFFFFE9F | `KIND_HID_EVENT` |
| 0xFFFFFEB0–0xFFFFFEBF | `KIND_AUDIO_CONTROLLER` |
| 0xFFFFFECC0–0xFFFFFECDF | `KIND_AUDIO_CLOCK` |
| 0xFFFFFEE0–0xFFFFFEEF | `KIND_AUDIO_ROUTE` |
| 0xFFFFF950–0xFFFFF95F | `KIND_DMA_ATTESTATION` |
| 0xFFFFFF90–0xFFFFFF9F | `KIND_ACPI_EVENT` |

A dedicated band-audit pass (checking every one of the 91 claimed
ranges against every other for accidental overlap, and filling in the
~20 derived kinds not shown here) is out of scope for this document —
each band above was read from its own file's header comment and taken
at face value, not cross-verified against its neighbors.

## 8. Open gaps and stub kinds

Adversarial-verification pass over every "gate-only" / "stub" /
"scaffolding" / "deferred" / "SCOPE OF THIS LANDING" marker found
across `kind_*.pdx` during this document's research. Several are
historical stubs the tree has since resolved; they are listed with
that resolution noted so this section does not overstate current gaps.

**Genuinely incomplete today:**

- `kind_page_table.pdx` (base kind 3) — real handler deferred to R14;
  every `KIND_PAGE_TABLE` invocation is currently an identity
  fallthrough. Four named blockers (arg-encoding ABI, no
  current-aspace resolver, huge-page walker collision, no userspace
  minter).
- `kind_interrupt.pdx` (base kind 9) — structural stub returning
  `INVOKE_UNSUPPORTED` for every op; superseded in practice by
  `KIND_HW_INTERRUPT` (0x140) but kept as a compatibility alias per
  `kind.pdx`.
- `kind_thread.pdx`'s `OP_START` — stubbed to unconditionally return
  success; real scheduler enqueue deferred.
- `kind_dev.pdx` (base kind 10) — one real op (`OP_MAP_MMIO`), hardcoded
  to LAPIC test arguments rather than a general caller-supplied MMIO
  request.
- `kind_i2c_bus.pdx`'s mint gate deliberately checks the *base* slot
  (`KIND_DEVICE`=10) rather than the more specific derived
  `KIND_PCI_DEV` (0x30) tag, because — per its own comment —
  `device_cap_mint` "is still R22-M3 scaffolding that writes no
  descriptor: a 0x30 gate would be vacuous." I.e., the PCI-device
  derived-kind mint path this gate would ideally use is itself
  unimplemented.
- `kind_display_mode.pdx`'s mint hardcodes `refresh_hz=60` and
  `flags=0` as "IMPLICIT in this milestone," with a named follow-on
  file (`mode_enum.pdx`) expected to add the missing argument.
- `kind_pdxfs_mount_table.pdx` has at least one accessor that is a
  literal stub: "Returns 0 (stub) — real body needs cross-module
  `_mount_table[]` write access."
- `KIND_DRIVER` (0x15) has no implementing `kind_*.pdx` file at all —
  declared in `kind.pdx`, never given a handler.
- `KIND_TCP_SOCKET`/`LISTENER` rights ceilings were not captured this
  pass (file not read in detail) — flagged rather than guessed.
- `KIND_KEK`'s WRAP/UNWRAP/DERIVE_CHILD ops and `KIND_DISPLAY_BACKEND`'s
  zero-op surface (`DPYB_OP_MAX`=0) both warrant a direct read of their
  files before depending on them — this pass could not confirm real
  vs. stub from the header grep alone.
- `KIND_ELEVATE_CHANNEL`'s privilege-elevation broker is explicitly
  still being built ("a stubbed broker can surface the race in its own
  audit trail") — the capability's row substrate is real, the
  consuming broker is not yet.
- `KIND_SESSION`, `KIND_CAPTURE`, `KIND_SEAT`, `KIND_SCREENCAST`
  (0x1BC, 0x1BE, 0x1BF, 0x1C0) are all real, exercised kernel-side row
  substrate — but every one of their own headers explicitly defers the
  *policy* layer above them (session-manager, capture-broker,
  multi-seat input dispatcher) to follow-on landings not yet in the
  tree. Treat the mechanism as real and the policy as absent, not the
  other way around.
- `KIND_A11Y_NODE` exists as **two unrelated capabilities of the same
  name**: this kernel one (0x1E6, real) and a userspace one (0x1E2, in
  `src/user/a11y/kind_a11y_node.pdx`) whose own header says its
  substrate "DOES NOT EXIST YET" and every op is a stub returning
  `NODE_NOT_INIT`. A future reconciliation is noted as still undecided
  in both files' headers.

**Historical stubs, resolved (listed so a stale "stub" grep hit is not
mistaken for a live gap):**

- `KIND_PDXFS_TXN`'s R42-PREP-007 `PXT_STUB_OK` sentinel — fully
  retired at R52.M6-006 (#1714); COMMIT/ABORT/CREATE/RENAME/UNLINK all
  delegate to real journal/directory-op bodies now.
- `KIND_AHCI_CONTROLLER`'s revoke — landed as a stub at R51.M5-001,
  explicitly "widens at M5-004... once KIND_AHCI_PORT exists," which
  it now does.
- Several base-kind handlers (`kind_dev`, `kind_ipc`, `kind_page`,
  `kind_process`, `kind_sched`, `kind_thread`) carry a dead
  `*_STUB_SENTINEL` constant left over from an earlier stub phase,
  explicitly commented "NOT referenced in real body" — these are inert
  historical markers, not evidence of an unimplemented handler.

**Endpoint mint gate (background item from the task brief, re-verified
here):** `kind_endpoint.pdx`'s own header still describes
`endpoint_cap_mint` as "gate-only... real slab_alloc + descriptor slab
write deferred until cap_revoke grows a real body." `cap_revoke` did
grow a real body afterward, at R31.M1-1589
(`src/kernel/core/cap/revoke.pdx`) — meaning the precondition
`kind_endpoint.pdx`'s own comment names for un-deferring its mint gate
has been met. This document did not re-read `kind_endpoint.pdx` end to
end to confirm the mint body itself was updated to match; treat the
file's self-description as possibly stale and verify directly before
relying on it either way.

**`KIND_AHCI_PORT`'s revoke** — its header describes a "revoke
primitive with a CASCADE STUB" at original landing (R51.M5-004,
#1660); unlike the controller's stub above, no later comment in the
grep results confirmed this one was subsequently widened. Verify
`kind_ahci_port.pdx` directly before depending on cascade-on-revoke
for AHCI ports.

## 9. Cross-references

- `src/kernel/core/cap/kind.pdx` — base 16-kind enum plus every
  post-R29 derived kind's identity/rights/base-parent rationale, in
  one file's comments.
- `src/kernel/core/cap/kind_*.pdx` (112 files) — per-kind mint/query/
  revoke bodies; grep `_OP_MAX\s*:\s*u64` for a given file's op-table
  size, `_cap_mint`/`_mint`/`_destroy`/`_cap_revoke` for its lifecycle
  functions.
- `design/architecture/syscall-table-v2.md` (ξ-02) — the syscall
  surface that resolves and invokes these cap-table slots.
- `design/architecture/security-model-overview.md` (ξ-05) — the
  security argument built on the monotone-derivation property this
  document documents structurally (§4).
- `design/architecture/caps-decl-format.md` — exec-time capability
  narrowing via `caps.decl`.
- `design/architecture/next-wave-derived-kinds.md` — design-time specs
  for several R29/R30/R32 derived kinds cited above.
- `src/user/compositor/surface_kind.pdx` — canonical user-side identity
  authority for `KIND_SURFACE`.
- `src/user/a11y/kind_a11y_node.pdx` — the unrelated userspace
  accessibility-node kind sharing a name with §5's 0x1E6 entry.
