# Kernel Capability Kind Taxonomy

## 1. Purpose and scope

paideia-os is a pure capability-based microkernel: every kernel object a
process can name is reached through a capability descriptor, and every
descriptor carries a **kind**. This document is the first exhaustive,
design-level enumeration of every `KIND_*` the kernel defines — it
supersedes ad hoc file-by-file reading of `src/kernel/core/cap/` as the
way to answer "what capability kinds exist and what can you do with
one." It was produced by enumerating **112** `kind_*.pdx` files under
`src/kernel/core/cap/` plus the closed base enum in `kind.pdx`, and by
grepping every file for its canonical hex identity and its
mint/query/revoke operation surface rather than reading each file's
prose in full.

Scope note: a handful of kinds the closed enum registers are
implemented **outside** the `kind_*.pdx` naming convention (legacy
files such as `driver_cap.pdx`, `blkdev_cap.pdx`, `udp_socket_cap.pdx`,
or the newer `net/tcp_socket.pdx` / `net/udp_socket.pdx`). Those are
included in the table below and flagged in §5 rather than silently
dropped, since a taxonomy that only covers the `kind_` prefix would
undercount the real kind space.

## 2. Base kind space

The base kind space is a **closed enum of 16 entries** (`Kind.KIND_*`
in `kind.pdx`), encoded in 4 LAM tag bits so `cap_invoke_dispatch`'s
fast path can route on a hardware-cheap field:

| ID | Base kind | Notes |
|---|---|---|
| 0 | `KIND_NULL` | placeholder, unused descriptor |
| 1 | `KIND_PROCESS` | TCB pointer, CSpace root |
| 2 | `KIND_THREAD` | scheduler context (Phase-1 legacy name) |
| 3 | `KIND_PAGE_TABLE` | paging structures |
| 4 | `KIND_PAGE` (alias `KIND_MEMORY`) | individual page/region; derivation root for the entire memory-authority family |
| 5 | `KIND_IPC_ENDPOINT` | send/recv IPC primitive; derivation root for sessions, sockets, TTY, surfaces, seats, elevate channels, and most "being told about X" subscription kinds |
| 6 | `KIND_IPC_PORT` | port-mapped I/O capability |
| 7 | `KIND_SCHED_CTX` | budget/period/priority donation (seL4-MCS style) |
| 8 | `KIND_TIMER` | event scheduling / wakeup |
| 9 | `KIND_INTERRUPT` | legacy vector+affinity cap; deprecated in favor of `KIND_HW_INTERRUPT`, kept as a compatibility alias |
| 10 | `KIND_DEVICE` | device memory + config; derivation root for the ACPI/PCI/HID/audio/storage/network device family |
| 11 | `KIND_IO_PORT` | I/O port access |
| 12 | `KIND_NOTIFICATION` | async signaling primitive |
| 13 | `KIND_REPLY` | RPC return-path endpoint |
| 14 | `KIND_HW` | hardware-adjacent base (promoted from a "fault" placeholder at R29.M0-001, #1017); shelters `KIND_HW_INTERRUPT` / `KIND_HW_MSIX_VECTOR` / `KIND_AUDIO_CLOCK` / `KIND_DISPLAY_TIMELINE` / `KIND_USER` |
| 15 | `KIND_RESERVED` | reserved for confidential-computing/TDX; also the nominal base `KIND_DMESG` derives from |

The enum is full and frozen — a 17th base kind would need a
major LAM-layout event (`kind.pdx` header comment, restated at R29.M0-001).

**Derived kinds** refine a base kind's rights and descriptor tail
without occupying a new LAM slot. A derived kind still carries its
parent's base kind in the LAM hint (so `cap_invoke_dispatch`'s coarse
routing still works), but the value the dispatcher actually compares
is the **full u64 kind field**, not the 4-bit slot — so many derived
kinds share one LAM hint (every `KIND_IPC_ENDPOINT`-derived kind, for
instance, shares LAM slot 5). Two derivation styles coexist:

- **Early out-of-band tags** (`KIND_DRIVER = 0x15`, `KIND_DMESG =
  0x16`) — small values just above the 4-bit range, predating the R29
  convention.
- **The `0x140`–`0x1FF` block**, the dominant shape from R29 onward.
  `kind_surface.pdx`'s own header is the clearest statement of the
  pattern in the tree: `KIND_SURFACE = 0x1B8` is declared as "a derived
  kind built on `KIND_SURFACE_BASE = 5` (`= KIND_IPC_ENDPOINT`)" — the
  base kind supplies the LAM-hint slot and the coarse rights lattice,
  while the derived tag is what `cap_invoke_dispatch` actually
  switches on (`cmp rcx, 0x1b8; je call_kind_surface`) and what the
  kind-specific row table, rights bitmask, and mint/destroy pair are
  privately owned by. Because kernel-side and user-side pieces of a
  derived kind cannot share a symbol (paideia-as has no cross-boundary
  import mechanism), `kind_surface.pdx` also documents the fallback
  discipline every derived kind with a user-side sibling follows:
  declare the identity literal on both sides with a cross-reference
  comment, and reconcile them with a build-time grep-based
  `verify-kind-parity.sh` check rather than a real import.

## 3. Full table

97 of the 112 `kind_*.pdx` files declare their own derived-kind hex
identity; the rest either implement one of the 16 base kinds directly
(no separate ID — the base enum value *is* the kind), or are shared
tail-accessor libraries with no kind identity of their own
(`kind_blkdev.pdx`). "Query/accessor family" names the dominant prefix
of a kind's read-only row accessors (e.g. `srf_*` on `KIND_SURFACE`
covers `surface_row_valid` / `surface_row_addr` / `surface_row_*_get`)
rather than every individual function. "Consumer" names an explicit
cross-reference where the file states one; otherwise it names the
functional subsystem by convention per this document's grouping.

### 3.1 Core, scheduling, and hardware-adjacent

| Kind | Hex ID | Mint op | Query/accessor family | Revoke/destroy op | Consumer |
|---|---|---|---|---|---|
| `KIND_NULL` | 0x0 | — | — | — | kernel-internal, unused sentinel |
| `KIND_PROCESS` | 0x1 | `cap_handler_process` `OP_CREATE` (allocates `_process_pool` slot, `aspace_create`) | `OP_GET_ASPACE_ROOT` | none (no slot-recycle path) | scheduler / process pool, `kind_process.pdx` |
| `KIND_THREAD` | 0x2 | `cap_handler_thread` `OP_CREATE` | — | `OP_START` is lifecycle, not a query; no destroy op | scheduler, `kind_thread.pdx` |
| `KIND_PAGE_TABLE` | 0x3 | structural stub only — real `OP_MAP`/`OP_UNMAP` deferred to R14 (4 blockers documented in-file) | — | — | mm, deferred landing, `kind_page_table.pdx` |
| `KIND_PAGE` / `KIND_MEMORY` | 0x4 | `cap_handler_page` `OP_READ`/`OP_WRITE` (R12 test buffer only) | — | — | memory subsystem; root base for `KIND_MEMORY`-derived family below |
| `KIND_SCHED_CTX` | 0x7 | `cap_handler_sched` `OP_YIELD` | — | — | scheduler, `kind_sched.pdx` |
| `KIND_TIMER` | 0x8 | `cap_handler_timer` `OP_ARM`/`OP_CANCEL` | `OP_READ_TSC` | `OP_CANCEL` | LAPIC/TSC-deadline timer, `kind_timer.pdx` |
| `KIND_INTERRUPT` | 0x9 | structural stub, `INVOKE_UNSUPPORTED` on every op | — | — | legacy/deprecated — superseded by `KIND_HW_INTERRUPT`; kept as compat alias |
| `KIND_DEVICE` | 0xA | `cap_handler_dev` `OP_MAP_MMIO` | — | — | `kind_dev.pdx`; root base for the ACPI/PCI/audio/storage/net device family below |
| `KIND_IO_PORT` | 0xB | — | — | — | **no implementing file found** — base kind is declared but has no `kind_io_port.pdx`/handler in the tree (see §5) |
| `KIND_HW` | 0xE | none (identity-fallthrough at this landing) | — | — | shelters the R29 hardware-adjacent family (below); no dispatch branch of its own |
| `KIND_RESERVED` | 0xF | — | — | — | reserved for confidential-computing/TDX; nominal base for `KIND_DMESG` |
| `KIND_DRIVER` | 0x15 | `driver_cap.pdx` — manifest accessors + rights/kind predicates real, but the doc's own header calls this "HONEST SCOPE": the descriptor write reuses the cap subsystem's existing mem-operand gate rather than a dedicated mint | manifest field-offset accessors | none found | driver registration (D7-004, #262); file does **not** follow the `kind_*.pdx` naming convention |
| `KIND_DMESG` | 0x16 | none — installed once by the boot witness in `kernel_main.pdx` | `OP_READ_TAIL`, `OP_STAT` | none | `dmesg` tool / klog observability, `kind_dmesg.pdx` |
| `KIND_HW_INTERRUPT` | 0x140 | `hw_int_cap_mint_inner` | `cap_handler_hw_interrupt` dispatch | `hw_int_cap_revoke` (cascades to child `KIND_HW_MSIX_VECTOR` rows via `msix_cascade_revoke_by_parent`) | interrupt routing, `kind_hw_interrupt.pdx` |
| `KIND_HW_MSIX_VECTOR` | 0x141 | `msix_cap_mint_inner` | — | `msix_cap_revoke` | MSI-X vector allocation under a `KIND_HW_INTERRUPT` parent, `kind_hw_msix_vector.pdx` |
| `KIND_DMA_DOMAIN` | 0x142 | `dma_cap_mint_inner` | — | `dma_cap_revoke` (`dma_cascade_revoke_by_parent` on memory teardown) | per-driver-process IOMMU domain, one per driver process, `kind_dma_domain.pdx` |

### 3.2 IPC, sessions, and per-user identity

| Kind | Hex ID | Mint op | Query/accessor family | Revoke/destroy op | Consumer |
|---|---|---|---|---|---|
| `KIND_IPC_ENDPOINT` | 0x5 | `endpoint_cap_mint` — gate-only (`endpoint_tail_valid` + `endpoint_rights_valid`); real descriptor write deferred until `cap_revoke` has a real body | `endpoint_tail_decode_id`, `endpoint_tail_decode_dir` | none — explicitly deferred pending `cap/revoke.pdx §R12-m5-001` | IPC substrate; root base for the enormous `KIND_IPC_ENDPOINT`-derived family throughout this table |
| `KIND_IPC_PORT` | 0x6 | `cap_handler_ipc_port` `OP_SEND` | `OP_RECV` | none | port-mapped I/O, `kind_ipc_port.pdx` |
| `KIND_NOTIFICATION` | 0xC | `cap_handler_notification` `OP_SIGNAL` | `OP_POLL` | `OP_WAIT` consumes, no separate destroy | async signaling, `kind_notification.pdx` |
| `KIND_REPLY` | 0xD | `cap_handler_reply` `OP_REPLY` (one-shot) | `OP_STATUS` | consumed-flag is one-shot; no slot-recycle revoke | RPC return path, foundational for `SIGCHLD` wait, `kind_reply.pdx` |
| `KIND_ELEVATE_CHANNEL` | 0x191 | `elevate_channel_cap_mint_inner` | `ELVC_OP_QUERY_REQ_ID`/`PID`/`KIND`/`RIGHTS`/`STATE`/`EXPIRE`/`BROKER` | `elevate_channel_cap_revoke` | privilege-elevation broker |
| `KIND_SCHEMA_HANDLE` | 0x1B2 | `kind_schema_handle_mint_body` (via `ksh_row_alloc`) | — | none found (gap) | semantic-schema lookup / `libpdx-semantic-pipe` |
| `KIND_TTY` | 0x197 | `tty_cap_mint_inner` | `TTY_OP_QUERY_ROWS`/`COLS`/`ID`/`BYTES`, `GET_ATTR` | `tty_cap_revoke` | shell, pager, line-discipline tools |
| `KIND_SESSION` | 0x1BC | `session_mint` | — | `session_destroy` | compositor session model; consumer `src/user/compositor/window_kind.pdx`, `popup_positioning.pdx` |
| `KIND_SEAT` | 0x1BF | `seat_create` (default seat 0 minted at boot by `kind_seat_init`) | — | `seat_destroy` | multi-seat input routing; consumer `src/user/input_server/seat_kind.pdx` |
| `KIND_USER` | 0x190 | `user_cap_mint_inner` | — | none found (gap) | per-account identity; design authority `design/user/model.md` |

### 3.3 Storage / PdxFS

| Kind | Hex ID | Mint op | Query/accessor family | Revoke/destroy op | Consumer |
|---|---|---|---|---|---|
| `KIND_PDXFS_FILE` | 0x195 | `pdxfs_file_cap_mint_inner` | `PFF_OP_QUERY_INODE`/`LEN`/`MODE`/`BIRTH`/`MTIME`/`REFS`, `PFF_OP_READ_BYTES` | `pdxfs_file_cap_revoke` | PdxFS syscall block (sysnos 70–107) |
| `KIND_PDXFS_MOUNT_TABLE` | 0x1A5 | `kind_pdxfs_mount_table_mint` | `PMT_OP_READ_ROW`, `PMT_OP_QUERY_SLOT_COUNT` | `pmt_cap_revoke` | `sys_mount`/`sys_mountinfo` |
| `KIND_PDXFS_TXN` | 0x196 | `pdxfs_txn_cap_mint_inner` | — | `pdxfs_txn_cap_revoke` | `sys_pdxfs_txn_open`/`commit`/`abort` (sysnos 70, 104–105) |
| `KIND_INODE_HANDLE` | 0x1A2 | `inode_handle_cap_mint_inner` (parent gate: live `KIND_PDXFS_FILE` = 0x195) | — | `inode_handle_cap_revoke` | `sys_pdxfs_stat_by_inode` (sysno 106) |
| `KIND_VOLUME` | 0x1A0 | `volume_cap_mint_inner` (marshalled by `sys_volume_mint`, sysno 114) | — | `volume_cap_revoke` | libpdx-volume |
| `KIND_VOLUME_SNAPSHOT` | 0x1B3 | `kind_volume_snapshot_mint_body` (via `kvs_row_alloc`) | `kvs_row_created_tsc` | none found (gap) | libpdx-volume v1.1.0 |
| `KIND_KEK` | 0x1B4 | `kind_kek_mint_body` (via `kek_row_alloc`) | — | none found (gap) | libpdx-volume key-encryption-key handle |
| `KIND_SIG_KEY` | 0x1A3 | `sig_key_cap_mint_inner` | — | `sig_key_cap_revoke` | post-quantum signature key handle, `design/filesystem/volume-fs-substrate.md` |
| `KIND_TLS_TRUST` | 0x1A7 | `kind_tls_trust_mint_body` (via `tls_trust_tail_alloc`) | — | none found (gap) | TLS trust-anchor store |
| `KIND_BLOCK_CACHE` | 0x1A1 | `kind_block_cache_mint` | — | `block_cache_cap_revoke` | `design/filesystem/r52-implementation-plan.md` |
| `KIND_BLKDEV` | 0x42 | none — dual-kind-minted over an NVMe or AHCI parent row, never minted standalone | `blkdev_row_family`/`parent_slot`/`features`/`attest_key`/`max_transfer_blocks`/`dma_domain_slot` | none — shared substrate, revoked with its parent | unified block-device tail accessor library shared by `kind_nvme_namespace.pdx` and `kind_ahci_port.pdx`; **not itself a mintable standalone kind** |
| `KIND_AHCI_CONTROLLER` | 0x19A | `ahci_ctrl_probe_and_mint` (real mint: `ahci_ctrl_cap_mint_inner`) | — | `ahci_ctrl_cap_revoke` | AHCI/SATA driver |
| `KIND_AHCI_PORT` | 0x19B | `ahci_port_dual_kind_mint` (real mint: `ahci_port_cap_mint_inner`) | — | `ahci_port_cap_revoke` | AHCI/SATA driver, dual-mints `KIND_BLKDEV` tail |
| `KIND_NVME_CONTROLLER` | 0x198 | `nvme_ctrl_probe_and_mint` (real mint: `nvme_ctrl_cap_mint_inner`) | — | `nvme_ctrl_cap_revoke` | NVMe driver |
| `KIND_NVME_NAMESPACE` | 0x199 | `nvme_ns_dual_kind_mint` (real mint: `nvme_ns_cap_mint_inner`) | — | `nvme_ns_cap_revoke` | NVMe driver, dual-mints `KIND_BLKDEV` tail (`KIND_BLKDEV_TAG` alias = 0x42) |
| `KIND_VMD_ENDPOINT` | 0x187 | `vmd_endpoint_cap_mint_inner` | — | none found (gap) | Intel VMD (Volume Management Device) PCIe-to-NVMe bridging |
| `KIND_DMA_ATTESTATION` | 0x16E | `dma_attest_cap_mint_inner` | — | `dma_attest_cap_revoke` | DMA-transfer integrity attestation |

### 3.4 Display / GUI / GPU

| Kind | Hex ID | Mint op | Query/accessor family | Revoke/destroy op | Consumer |
|---|---|---|---|---|---|
| `KIND_SURFACE` | 0x1B8 | `surface_mint` | `surface_row_valid`/`addr`/`serial_get`/`pending_get`/`current_get`/`dims_get`/`format_get`/`damage_get`, `surface_row_swap` | `surface_destroy` | postui compositor; user-side canonical authority `src/user/compositor/surface_kind.pdx` (see §6 in the previous revision of this doc; full row layout in file header) |
| `KIND_DISPLAY_BACKEND` | 0x1AE | `kind_display_backend_mint_body` (via `dpyb_tail_alloc`) | — | `kind_display_backend_revoke_body` | `sys_display_enumerate`/`sys_framebuffer_create` (sysnos 108–109) |
| `KIND_DISPLAY_ENGINE` | 0x16F | `display_engine_cap_mint_inner` | — | `display_engine_cap_revoke` | display pipeline / mode-setting |
| `KIND_DISPLAY_OUTPUT` | 0x170 | `display_output_cap_mint_inner` | — | `display_output_cap_revoke` | parent of `KIND_PAGE_FLIP` |
| `KIND_DISPLAY_MODE` | 0x172 | `display_mode_cap_mint_inner` | — | `display_mode_cap_revoke` | mode-setting substrate |
| `KIND_DISPLAY_PLANE` | 0x173 | `display_plane_cap_mint_inner` | — | `display_plane_cap_revoke` | scanout plane management |
| `KIND_DISPLAY_TIMELINE` | 0x185 | `dpt_cap_mint_inner` | — | none found (gap) | GPU/display fence timeline (base `KIND_HW`) |
| `KIND_MODESET_TXN` | 0x171 | `modeset_txn_cap_mint_inner` | — | `modeset_txn_cap_revoke` | atomic mode-set transaction |
| `KIND_SCANOUT_LEASE` | 0x188 | `sl_cap_mint_inner` | — | none found (gap) | scanout plane leasing (base `KIND_MEMORY`, via `KIND_DISPLAY_PLANE`) |
| `KIND_VRR_RANGE` | 0x186 | `vrr_cap_mint_inner` | — | none found (gap) | variable refresh rate |
| `KIND_FRAMEBUFFER` | 0x1AF | `kind_framebuffer_mint_simple` | `FB_OP_QUERY_WIDTH`/`HEIGHT`/`STRIDE`/`FORMAT`/`VA` | `kind_framebuffer_revoke_body` | `sys_framebuffer_create`/`_map` (sysnos 109–110); `design/graphics/authority-boundary.md` |
| `KIND_PAGE_FLIP` | 0x1B0 | `kind_page_flip_mint_body` (via `pgfl_tail_alloc`) | — | `kind_page_flip_revoke_body` | `sys_page_flip`/`_wait` (sysnos 111–112), base `KIND_DISPLAY_OUTPUT` |
| `KIND_HOTPLUG_CHANNEL` | 0x1B1 | `kind_hotplug_channel_mint_body` (via `hpch_tail_alloc`) | — | `kind_hotplug_channel_revoke_body` | `sys_display_hotplug_subscribe` (sysno 113) |
| `KIND_GPU_BO` | 0x174 | `gpu_bo_cap_mint_inner` | — | `gpu_bo_cap_revoke` | GPU buffer object (base `KIND_MEMORY`) |
| `KIND_GPU_VM` | 0x175 | `gpu_vm_cap_mint_inner` | — | `gpu_vm_cap_revoke` | GPU virtual address space |
| `KIND_GPU_CONTEXT` | 0x176 | `gpu_ctx_cap_mint_inner` | — | `gpu_ctx_cap_revoke` | GPU submission context |
| `KIND_GPU_SUBMIT` | 0x177 | `gpu_submit_cap_mint_inner` | — | `gpu_submit_cap_revoke` | GPU command-buffer submission |
| `KIND_VK_SURFACE` | 0x189 | `vks_tail_alloc` (substrate only) | `vks_row_output`/`fmt`/`extent_w`/`h`/`scale_num`/`den`, `vks_find_by_key` | **none found — no `_cap_mint`/`_cap_revoke` wrapper at all** (see §5) | Vulkan WSI surface |
| `KIND_VK_SWAPCHAIN_IMAGE` | 0x18A | `vksi` tail-alloc (substrate present, alloc fn not directly matched) | `vksi_row_bo`/`surface`/`index`/`mode`/`gpu_tl`/`dpy_tl`/`state`/`present_id`/`target_pts` | **none found** (see §5) | Vulkan swapchain image (base `KIND_MEMORY`, over `KIND_GPU_BO`) |
| `KIND_VELLO_SCENE` | 0x18D | `vs_tail_alloc` (substrate only) | `vs_row_bo`/`paths`/`bytes`/`samples`/`flags`, `vs_find_by_key` | **none found** (see §5) | Vello 2D renderer scene (over `KIND_GPU_BO`) |
| `KIND_VELLO_RENDERER` | 0x18E | `vr_tail_alloc` (substrate only) | `vr_row_ctx`/`tile_size`/`samples`/`coarse`/`cursor`/`caps` | **none found** (see §5) | Vello renderer instance (over `KIND_GPU_CONTEXT`) |
| `KIND_FONT_ATLAS` | 0x18B | `fa_tail_alloc` (substrate only) | `fa_row_key`/`bo`/`width`/`height`/`format`/`glyphs` | **none found** (see §5) | text-rendering font atlas (over `KIND_GPU_BO`) |
| `KIND_TEXT_SHAPE` | 0x18C | `ts_tail_alloc` (substrate only) | `ts_row_script`/`dir`/`atlas`/`glyphs`/`ext_w`/`ext_h`/`scale_n`/`scale_d` | **none found** (see §5) | text-shaping cache |
| `KIND_COLOR_PROFILE` | 0x18F | `cp_tail_alloc` (substrate only) | `cp_row_colour`/`transfer`/`matrix`/`prim`/`has_icc`/`icc_ref` | **none found** (see §5) | color management pipeline |
| `KIND_TUI_CANVAS` | 0x1A6 | `kind_tui_canvas_mint_body` (via `tui_canvas_tail_alloc`) | — | `kind_tui_canvas_revoke_body` | terminal-UI canvas substrate |
| `KIND_CAPTURE` | 0x1BE | `capture_grant` | — | `capture_revoke` | screen-capture grant; broker holds GRANT+MINT+REVOKE |
| `KIND_SCREENCAST` | 0x1C0 | `screencast_start` (gated on a live `KIND_CAPTURE`) | — | `screencast_stop` | screen-recording session |
| `KIND_A11Y_NODE` | 0x1E6 | `a11y_node_cap_mint` | `ANODE_OP_QUERY_PARENT`/`ROLE`/`LABEL_PTR`/`LABEL_LEN` | `a11y_node_cap_revoke` | accessibility tree exposed to assistive-technology clients |

### 3.5 USB and mass storage class

| Kind | Hex ID | Mint op | Query/accessor family | Revoke/destroy op | Consumer |
|---|---|---|---|---|---|
| `KIND_USB_DEVICE` | 0x162 | `usb_device_cap_mint_inner` | — | `usb_device_cap_revoke` | USB device enumeration |
| `KIND_USB_HUB` | 0x163 | `usb_hub_cap_mint_inner` | — | `usb_hub_cap_revoke` | USB hub topology (base `KIND_USB_DEVICE`) |
| `KIND_USB_INTERFACE` | 0x164 | `usb_interface_cap_mint_inner` | — | `usb_interface_cap_revoke` | USB interface descriptor (base `KIND_USB_DEVICE`) |
| `KIND_USB_ENDPOINT` | 0x165 | `usb_endpoint_cap_mint_inner` | — | `usb_endpoint_cap_revoke` | USB endpoint (base `KIND_IPC_ENDPOINT`) |
| `KIND_USB_URB` | 0x168 | `usb_urb_cap_mint_inner` | — | `usb_urb_cap_revoke` | USB request block (base `KIND_IPC_ENDPOINT`) |
| `KIND_ISOCH_STREAM` | 0x169 | `isoch_stream_cap_mint_inner` | — | `isoch_stream_cap_revoke` | USB isochronous stream (base `KIND_USB_ENDPOINT`) |
| `KIND_MSC_LUN` | 0x166 | `msc_lun_cap_mint_inner` | — | `msc_lun_cap_revoke` | USB mass-storage class LUN (base `KIND_USB_INTERFACE`) |
| `KIND_SCSI_DEVICE` | 0x167 | `scsi_device_cap_mint_inner` | — | `scsi_device_cap_revoke` | SCSI command translation over `KIND_MSC_LUN` |

### 3.6 Networking, Wi-Fi, Bluetooth, WWAN

| Kind | Hex ID | Mint op | Query/accessor family | Revoke/destroy op | Consumer |
|---|---|---|---|---|---|
| `KIND_NIC` | 0x1AD | `nic_mint_ok_msg`/`kind_nic_mint_body` (via `nic_tail_alloc`) | — | none found (gap) | network interface card, base `KIND_DEVICE` |
| `KIND_TCP_SOCKET` | 0x1AB | implemented in `net/tcp_socket.pdx`, **not** `cap/kind_*.pdx` | — | — | `sys_socket`/TCP block (sysnos 87–102) |
| `KIND_TCP_LISTENER` | 0x1AC | implemented in `net/tcp_socket.pdx` | — | — | `sys_listen`/`sys_accept` |
| `KIND_UDP_SOCKET` | 0x1A8 | implemented in `net/udp_socket.pdx`; a legacy `udp_socket_cap.pdx` (`udp_socket_cap_mint`) also exists at a different historical tag (0x50) — see §5 | — | — | `sys_sendto`/`recvfrom` (sysnos 96–97) |
| `KIND_WIFI_PHY` | 0x178 | `wifi_phy_cap_mint_inner` | — | none found (gap) | Wi-Fi radio (base `KIND_DEVICE`) |
| `KIND_WIFI_VIF` | 0x179 | `wifi_vif_cap_mint_inner` | — | none found (gap) | Wi-Fi virtual interface (base `KIND_IPC_ENDPOINT`) |
| `KIND_WIFI_SCAN_TXN` | 0x17A | `wifi_scan_cap_mint_inner` | — | none found (gap) | Wi-Fi scan transaction (base `KIND_IPC_ENDPOINT`) |
| `KIND_WIFI_KEY` | 0x17B | `wifi_key_cap_mint_inner` | — | none found (gap) | Wi-Fi key material (base `KIND_MEMORY`) |
| `KIND_BT_ADAPTER` | 0x182 | `bt_adapter_cap_mint_inner` | — | none found (gap) | Bluetooth adapter (base `KIND_DEVICE`) |
| `KIND_BT_HCI_CHANNEL` | 0x183 | `bt_hci_chan_cap_mint_inner` | — | none found (gap) | Bluetooth HCI transport (base `KIND_IPC_ENDPOINT`) |
| `KIND_BT_L2CAP_CHANNEL` | 0x184 | `bt_l2cap_chan_cap_mint_inner` | — | none found (gap) | Bluetooth L2CAP channel (base `KIND_IPC_ENDPOINT`) |
| `KIND_BT_GATT_CONNECTION` | 0x17C | `bt_gatt_conn_cap_mint_inner` | — | none found (gap) | Bluetooth GATT connection (base `KIND_IPC_ENDPOINT`) |
| `KIND_BT_PAIRING` | 0x17D | `bt_pairing_cap_mint_inner` | — | `bt_pairing_cap_revoke` | Bluetooth pairing state (base `KIND_MEMORY`) |
| `KIND_WWAN_MODEM` | 0x180 | `wwan_modem_cap_mint_inner` | — | none found (gap) | WWAN modem (base `KIND_DEVICE`) |
| `KIND_MBIM_SESSION` | 0x181 | `mbim_session_cap_mint_inner` | — | none found (gap) | MBIM session over WWAN modem (base `KIND_IPC_ENDPOINT`) |
| `KIND_PCIE_HOTPLUG_EVENT` | 0x16B | `pcie_hp_evt_cap_mint_inner` | — | `pcie_hp_evt_cap_revoke` | PCIe hotplug event subscription (base `KIND_IPC_ENDPOINT`) |
| `KIND_TB_DOMAIN` | 0x16C | `tb_domain_cap_mint_inner` | — | `tb_domain_cap_revoke` | Thunderbolt security domain (base `KIND_DEVICE`) |
| `KIND_TB_ROUTE` | 0x16D | `tb_route_cap_mint_inner` | — | `tb_route_cap_revoke` | Thunderbolt route (base `KIND_IPC_ENDPOINT`) |

### 3.7 Audio

| Kind | Hex ID | Mint op | Query/accessor family | Revoke/destroy op | Consumer |
|---|---|---|---|---|---|
| `KIND_AUDIO_CONTROLLER` | 0x15E | `audio_ctrl_cap_mint_inner` | — | `audio_ctrl_cap_revoke` | HDA controller (base `KIND_DEVICE`) |
| `KIND_AUDIO_CLOCK` | 0x160 | `audio_clock_cap_mint_inner` | — | `audio_clock_cap_revoke` | audio clock domain (base `KIND_HW`) |
| `KIND_AUDIO_ROUTE` | 0x161 | `audio_route_cap_mint_inner` | — | `audio_route_cap_revoke` | audio routing graph (base `KIND_IPC_ENDPOINT`) |
| `KIND_PCM_STREAM` | 0x15F | `pcm_stream_cap_mint_inner` (linear — no reparent once minted) | — | `pcm_stream_cap_revoke` | PCM audio stream (base `KIND_IPC_ENDPOINT`) |

### 3.8 Power, ACPI, thermal

| Kind | Hex ID | Mint op | Query/accessor family | Revoke/destroy op | Consumer |
|---|---|---|---|---|---|
| `KIND_OP_REGION` | 0x150 | `opregion_cap_mint_root`/`_inner` (ROOT path, platform-privileged) or DERIVE path (containment-checked) | query-only ops by design — no "poke this address" op | `opregion_cap_revoke` (`opregion_cascade_revoke_by_parent` is transitive) | ACPI OperationRegion address-space window; base varies (`KIND_MEMORY` or `KIND_IO_PORT`) per requested space |
| `KIND_ACPI_EVENT` | 0x151 | `acpi_evt_cap_mint_inner` | — | `acpi_evt_cap_revoke` | ACPI general-purpose event (base `KIND_HW_INTERRUPT`) |
| `KIND_FW_SESSION` | 0x155 | `fw_session_cap_mint` | — | `fw_session_cap_revoke` | one evaluation session against one firmware object (base `KIND_IPC_ENDPOINT`); named to avoid the forbidden "AML" token per `tools/lint-no-kernel-aml.sh` |
| `KIND_EC_QUERY` | 0x156 | `ec_query_cap_mint_inner` (second gate arg: live `KIND_OP_REGION` with space=EC) | — | `ec_query_cap_revoke` | embedded-controller query subscription; **not loader-seedable** |
| `KIND_THERMAL_ZONE` | 0x157 | `thermal_zone_cap_mint_inner` | — | `thermal_zone_cap_revoke` | ACPI thermal zone trip points (base `KIND_DEVICE`); **not loader-seedable** |
| `KIND_BATTERY` | 0x158 | `battery_cap_mint_inner` | — | `battery_cap_revoke` | battery pack identity/state (base `KIND_DEVICE`); **not loader-seedable** |
| `KIND_COOLING_DEVICE` | 0x159 | `cooling_cap_mint_inner` | — | `cooling_cap_revoke` | ACPI cooling device (base `KIND_DEVICE`); **not loader-seedable** |
| `KIND_BACKLIGHT` | 0x15A | `backlight_cap_mint_inner` (one-cap-per-panel invariant) | — | `backlight_cap_revoke` | display backlight (base `KIND_DEVICE`); **not loader-seedable** |

### 3.9 HID and sensor input

| Kind | Hex ID | Mint op | Query/accessor family | Revoke/destroy op | Consumer |
|---|---|---|---|---|---|
| `KIND_HID_DEVICE` | 0x15B | `hid_device_cap_mint_inner` | — | `hid_device_cap_revoke` | HID peripheral identity (base `KIND_DEVICE`); no setter reachable through dispatch |
| `KIND_HID_EVENT` | 0x15C | `hid_event_cap_mint_inner` | — | `hid_event_cap_revoke` | HID event-class subscription, key = (endpoint_id, event_type_mask); **not loader-seedable** |
| `KIND_SENSOR_CHANNEL` | 0x15D | `sensor_channel_cap_mint_inner` | — | `sensor_channel_cap_revoke` | ALS/accel/gyro subscription, key = (endpoint_id, sensor_type); rate change = revoke+remint; **not loader-seedable** |
| `KIND_FP_SENSOR` | 0x16A | `fp_sensor_cap_mint_inner` | — | `fp_sensor_cap_revoke` | fingerprint sensor (base `KIND_DEVICE`) |

### 3.10 Misc: buses, camera, generic hardware fabric

| Kind | Hex ID | Mint op | Query/accessor family | Revoke/destroy op | Consumer |
|---|---|---|---|---|---|
| `KIND_I2C_BUS` | 0x152 | `i2c_bus_cap_mint_inner` | — | `i2c_bus_cap_revoke` | I2C bus controller |
| `KIND_I2C_SLAVE` | 0x153 | `i2c_slave_cap_mint_inner` (derives over `KIND_I2C_BUS`, not `KIND_DEVICE`) | — | `i2c_slave_cap_revoke` | I2C slave device |
| `KIND_GPIO_LINE` | 0x154 | `gpio_line_cap_mint_inner` (second-half gate against probed pad-controller table) | — | `gpio_line_cap_revoke` | GPIO line |
| `KIND_CSI_CAMERA` | 0x17E | `csi_camera_cap_mint_inner` | — | none found (gap) | MIPI CSI camera sensor (base `KIND_DEVICE`) |
| `KIND_IPU6_STREAM` | 0x17F | `ipu6_stream_cap_mint_inner` | — | none found (gap) | Intel IPU6 camera capture stream (base `KIND_IPC_ENDPOINT`) |

## 4. Base kinds without a distinct table entry above

`KIND_IPC_PORT` (6), `KIND_NOTIFICATION` (12) and `KIND_REPLY` (13)
appear in §3.2; `KIND_PROCESS`/`THREAD`/`PAGE_TABLE`/`PAGE`/`SCHED_CTX`/
`TIMER`/`INTERRUPT`/`DEVICE`/`IO_PORT`/`HW`/`RESERVED` appear in §3.1.
Every base kind (0–15) has exactly one row somewhere in §3 except
`KIND_NULL`, which is a sentinel with no handler by design.

## 5. Gaps and inconsistencies observed

**Kinds with a mint/substrate path but no discoverable revoke.**
`kind_surface.pdx` itself sets the precedent for reading this
correctly: its header documents that 3 of its 5 R113.M1 fingerprint
tags ("commit", "fmt bind", "present") are "not yet wired" — landed as
data-only tags with allowlist entries naming the follow-on issues that
wire the emitters, not silently forgotten. The same "landed but
partial" shape recurs, without an equivalent allowlist comment, across
a wide swath of the display/GPU pipeline and several other subsystems:
`KIND_VK_SURFACE`, `KIND_VK_SWAPCHAIN_IMAGE`, `KIND_VELLO_SCENE`,
`KIND_VELLO_RENDERER`, `KIND_FONT_ATLAS`, `KIND_TEXT_SHAPE`,
`KIND_COLOR_PROFILE` all have a full row-allocation substrate
(`*_tail_alloc`/`*_tail_valid`/`*_tail_free`) and a complete read-only
accessor family, reachable through a real `cap_handler_*` dispatcher —
but **no separately named `_cap_mint`/`_cap_revoke` wrapper at all**.
`_tail_free` exists on most of these (the storage is reclaimable) but
nothing in the kind's own file calls it from a cap-level revoke path,
so the primitive is dead code from the capability system's point of
view today. A further group has a mint wrapper but no matching revoke:
`KIND_SCHEMA_HANDLE`, `KIND_USER`, `KIND_VOLUME_SNAPSHOT`, `KIND_KEK`,
`KIND_VMD_ENDPOINT`, `KIND_DISPLAY_TIMELINE`, `KIND_SCANOUT_LEASE`,
`KIND_VRR_RANGE`, `KIND_NIC`, `KIND_WIFI_PHY`, `KIND_WIFI_VIF`,
`KIND_WIFI_SCAN_TXN`, `KIND_WIFI_KEY`, `KIND_BT_ADAPTER`,
`KIND_BT_HCI_CHANNEL`, `KIND_BT_L2CAP_CHANNEL`, `KIND_BT_GATT_CONNECTION`,
`KIND_WWAN_MODEM`, `KIND_MBIM_SESSION`, `KIND_CSI_CAMERA`, and
`KIND_IPU6_STREAM`. None of these carry an in-file comment explaining
the omission the way `kind_surface.pdx` does for its three unwired
tags — a reader has no way to tell "deliberately deferred" from
"forgotten" without checking each kind's own issue history.

**`KIND_IO_PORT` (base slot 11) has no implementing file.** Every
other base kind has at least a stub or real `cap_handler_*` under
`src/kernel/core/cap/`; grepping the tree for a `kind_io_port.pdx` or
an `OP_`-dispatch handler naming base kind 11 returns nothing. Slot 11
is also reused as one of the two possible bases for `KIND_OP_REGION`
(port-like address spaces), so the slot is live in the rights lattice
without ever having its own base-kind handler.

**Kinds implemented outside the `kind_*.pdx` naming convention.**
`KIND_DRIVER` (0x15) lives in `driver_cap.pdx`, not `kind_driver.pdx`;
its own header calls the mint path "HONEST SCOPE" — real predicates,
but the descriptor write reuses a generic mem-operand gate rather than
a dedicated `driver_cap_mint`. `KIND_UDP_SOCKET` (0x1A8) has **two**
implementations: a legacy `udp_socket_cap.pdx` (`udp_socket_cap_mint`)
that a comment trail suggests predates the current tag, and the live
`net/udp_socket.pdx` substrate the syscall table cites for sysnos
96/97 — worth a close look to confirm the legacy file is fully
superseded and not still reachable from any dispatch path.
`KIND_TCP_SOCKET` / `KIND_TCP_LISTENER` live in `net/tcp_socket.pdx`,
and `KIND_BLKDEV` (0x42) is a shared tail-accessor library
(`kind_blkdev.pdx`) with no mint of its own — it exists only as a
dual-kind tail dual-minted by `KIND_NVME_NAMESPACE` and
`KIND_AHCI_PORT`. None of these four break the capability system, but
a reader searching only `cap/kind_*.pdx` for "every kind" — as this
survey's own file list initially did — will miss them.

**No hex-ID collisions found.** Grepping every `pub let KIND_*_ID`/
`KIND_*` hex declaration across all 112 `kind_*.pdx` files plus
`kind.pdx` turned up no two distinct kinds sharing one derived-kind
tag. The nearest thing to a collision is intentional aliasing, not a
conflict: `KIND_BLKDEV_TAG` (`kind_nvme_namespace.pdx`) and
`KIND_BLKDEV` (`kind_blkdev.pdx`) both name 0x42 by design (the dual-
kind-mint tail), and `KIND_HW_MSIX_PARENT` (`kind_hw_msix_vector.pdx`)
is a documented alias for `KIND_HW_INTERRUPT` = 0x140, not a second
kind. `kind_surface.pdx`'s own header records a near-miss from
history rather than one live today: Wave 12 rolled back `KIND_SURFACE`
three times for "four independent collisions (kind-id, row layout,
failure band, fingerprint allowlist gap)" before landing at 0x1B8 —
evidence that this class of collision is a real, recurring failure
mode in this tree even though the current snapshot is clean.

## 6. Cross-references

- `src/kernel/core/cap/kind.pdx` — base 16-kind enum plus the identity/
  rights/base-parent rationale for most of the `0x140`–`0x1B4` derived
  block, all in one file's comments.
- `src/kernel/core/cap/kind_*.pdx` (112 files) — per-kind mint/query/
  revoke bodies; grep `OP_[A-Z_]+\s*:\s*u64` in a given file for its op
  table, `_cap_mint`/`_mint_inner`/`_mint_body`/`_cap_revoke`/`_destroy`
  for its lifecycle functions.
- `src/kernel/core/cap/kind_surface.pdx` — the most heavily documented
  kind in the tree; the worked template for reading any row-indirected
  derived kind (identity, rights bitmask, LAM-generation row header,
  failure-band convention, fingerprint-tag landing discipline).
- `design/architecture/caps-decl-format.md` — exec-time capability
  narrowing via `caps.decl`, independent of per-kind mint gates.
- `design/architecture/next-wave-derived-kinds.md` — design-time specs
  for the R29/R30/R32 derived-kind waves cited throughout §3.
- `design/graphics/authority-boundary.md` — `KIND_FRAMEBUFFER`/
  `KIND_PAGE_FLIP` rights discipline.
- `design/user/syscall-table.md` — the syscall numbers that marshal
  several storage/display/GUI kinds across the user/kernel boundary
  (`sys_volume_mint`, `sys_framebuffer_create`, `sys_page_flip`, etc.).
- `src/user/compositor/surface_kind.pdx` — user-side canonical
  authority for `KIND_SURFACE` identity and rights.
