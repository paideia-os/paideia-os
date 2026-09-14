# Kernel Capability Kind Taxonomy

## 1. Purpose and scope

paideia-os is a pure capability-based microkernel: every kernel object a
process can name is reached through a capability descriptor, and every
descriptor carries a **kind**. This document enumerates the full kind
space as it exists in the tree today — base kinds and derived kinds —
with each kind's canonical identifier, its rights bitmask family, its
mint/query/revoke operation surface where the kernel exposes one, and
the consuming subsystem or repo. It is a reference document, not a
proposal: every entry below is read directly out of
`src/kernel/core/cap/kind_*.pdx` (112 files at this writing) plus the
base enum in `src/kernel/core/cap/kind.pdx`. Where a kind's op surface
was not read line-by-line for this pass, the table cites the file to
consult directly — do not treat this document as more authoritative
than the source it summarizes.

## 2. Two kind spaces

**Base kinds** are a closed 16-entry enum (`Kind.KIND_*` in
`kind.pdx`), encoded in 4 LAM tag bits so the fast-dispatch path can
route on a hardware-cheap field. The enum is full and frozen; adding a
17th base kind would require a major LAM-layout event.

**Derived kinds** refine a base kind's rights and descriptor tail
without occupying a new LAM slot. A derived kind still carries its
*parent's* base kind in the LAM hint (so `cap_invoke_dispatch`'s
coarse routing still works), but the full `kind` field the kernel
compares is a wider numeric tag — either a small out-of-band value
(`KIND_DRIVER = 0x15`, `KIND_DMESG = 0x16`) or, from the R29 wave
onward, a value in the `0x140`–`0x1FF` range. `cap_invoke_dispatch`
compares the **full u64 kind field**, not just the 4-bit slot, so
multiple derived kinds can share one LAM hint (e.g. every
`KIND_IPC_ENDPOINT`-derived kind — sessions, subscriptions, TTYs,
sockets, surfaces, seats — shares LAM slot 5).

## 3. Base kind enum (closed, `kind.pdx`)

| Kind | ID | Notes |
|---|---|---|
| `KIND_NULL` | 0 | placeholder / unused descriptor |
| `KIND_PROCESS` | 1 | TCB pointer, CSpace root |
| `KIND_THREAD` | 2 | scheduler context (Phase 1 legacy name) |
| `KIND_PAGE_TABLE` | 3 | paging structures |
| `KIND_PAGE` (alias `KIND_MEMORY`) | 4 | individual page/region; derivation base for the entire memory-authority family |
| `KIND_IPC_ENDPOINT` | 5 | send/recv IPC primitive; derivation base for sessions, sockets, TTY, surfaces, seats, elevate channels |
| `KIND_IPC_PORT` | 6 | port-mapped I/O capability |
| `KIND_SCHED_CTX` | 7 | budget/period/priority donation (seL4-MCS style) |
| `KIND_TIMER` | 8 | event scheduling/wakeup |
| `KIND_INTERRUPT` | 9 | legacy vector+affinity cap, deprecated in favor of `KIND_HW_INTERRUPT` (kept as compat alias) |
| `KIND_DEVICE` | 10 | device memory + config; derivation base for the ACPI/PCI/HID/audio/storage device family |
| `KIND_IO_PORT` | 11 | I/O port access |
| `KIND_NOTIFICATION` | 12 | async signaling primitive |
| `KIND_REPLY` | 13 | RPC return-path endpoint |
| `KIND_HW` | 14 | hardware-adjacent base (R29.M0-001); shelters `KIND_HW_INTERRUPT`/`KIND_HW_MSIX_VECTOR` |
| `KIND_RESERVED` | 15 | reserved for confidential-computing/TDX; also the nominal base for `KIND_DMESG` |

## 4. Derived kinds by family

Identity, base parent, and defining file for every derived kind found
under `src/kernel/core/cap/`. "Ops" gives the mint/query/revoke surface
where directly verified; consult the cited file for kinds marked
"see file" — every derived kind follows the same shape (a `*_cap_mint`
or `*_mint` gate, an `OP_QUERY_*`/`OP_*` dispatch table, and a
`*_cap_revoke`/`*_destroy` leaf).

### 4.1 Early derived tags (pre-0x140 range)

| Kind | ID | Base | File |
|---|---|---|---|
| `KIND_DRIVER` | 0x15 | KIND_DEVICE (10) | device_cap.pdx |
| `KIND_DMESG` | 0x16 | KIND_RESERVED (15) | kind.pdx (inline) |
| `KIND_UDP_SOCKET` (legacy tag) | 0x50 | — | udp_socket_cap.pdx (superseded — see §4.5) |

### 4.2 R29 hardware-adjacent family (base `KIND_HW`=14 / `KIND_MEMORY`=4)

| Kind | ID | Base | Mint/Query/Revoke | File |
|---|---|---|---|---|
| `KIND_HW_INTERRUPT` | 0x140 | KIND_HW | GSI/affinity/trigger row; handler `cap_handler_hw_interrupt` | kind_hw_interrupt.pdx |
| `KIND_HW_MSIX_VECTOR` | 0x141 | KIND_HW (parented under 0x140) | per-vector row; cascade-revoked by parent's `hw_int_cap_revoke` via `msix_cascade_revoke_by_parent` | kind_hw_msix_vector.pdx |
| `KIND_DMA_DOMAIN` | 0x142 | KIND_MEMORY | per-driver-process IOMMU domain; `dma_cascade_revoke_by_parent` on memory teardown | kind_dma_domain.pdx |

### 4.3 R30 firmware/ACPI family (0x150–0x159)

| Kind | ID | Base | Ops highlights | File |
|---|---|---|---|---|
| `KIND_OP_REGION` | 0x150 | KIND_MEMORY or KIND_IO_PORT (space-dependent — `opregion_space_base_kind` decides) | mint via ROOT (platform-privileged) or DERIVE (containment-checked); query-only ops, no poke op by design; `opregion_cascade_revoke_by_parent` is transitive | kind_op_region.pdx |
| `KIND_ACPI_EVENT` | 0x151 | KIND_HW_INTERRUPT (0x140) | — | kind_acpi_event.pdx |
| `KIND_I2C_BUS` | 0x152 | — | — | kind_i2c_bus.pdx |
| `KIND_I2C_SLAVE` | 0x153 | — | — | kind_i2c_slave.pdx |
| `KIND_GPIO_LINE` | 0x154 | — | second-half gate against probed pad-controller table | kind_gpio_line.pdx |
| `KIND_FW_SESSION` | 0x155 | KIND_IPC_ENDPOINT (5) | one evaluation session per firmware object; named to avoid the forbidden "AML" token (`tools/lint-no-kernel-aml.sh`) | kind_fw_session.pdx |
| `KIND_EC_QUERY` | 0x156 | KIND_IPC_ENDPOINT (5), 2nd arg = live `KIND_OP_REGION` (space=EC) | not loader-seedable (derivation-defined kind) | kind_ec_query.pdx |
| `KIND_THERMAL_ZONE` | 0x157 | KIND_DEVICE (10) | mint checks device key/uniqueness/threshold plausibility only — zone identity is a ring-3 (AML-walking) fact; not loader-seedable | kind_thermal_zone.pdx |
| `KIND_BATTERY` | 0x158 | KIND_DEVICE (10) | percent/mWh/mV units, no control-path conversion; not loader-seedable | kind_battery.pdx |
| `KIND_COOLING_DEVICE` | 0x159 | KIND_DEVICE (10) | state is an opaque ordinal (ACPI 6.5 §11.7); not loader-seedable | kind_cooling_device.pdx |

### 4.4 Input, sensor, audio, wireless family (0x15a–0x18f)

| Kind | ID | Base | Notes | File |
|---|---|---|---|---|
| `KIND_BACKLIGHT` | 0x15a | KIND_DEVICE | one-cap-per-panel invariant enforced structurally | kind_backlight.pdx |
| `KIND_HID_DEVICE` | 0x15b | KIND_DEVICE | no setter for identity/transport/report count | kind_hid_device.pdx |
| `KIND_HID_EVENT` | 0x15c | KIND_IPC_ENDPOINT | subscription record, key = (endpoint_id, event_type_mask) | kind_hid_event.pdx |
| `KIND_SENSOR_CHANNEL` | 0x15d | KIND_IPC_ENDPOINT | key = (endpoint_id, sensor_type); rate change = revoke+remint | kind_sensor_channel.pdx |
| `KIND_AUDIO_CONTROLLER` | 0x15e | KIND_DEVICE | opaque `bar_handle`, never dereferenced by this kind | kind_audio_controller.pdx |
| `KIND_PCM_STREAM` | 0x15f | KIND_IPC_ENDPOINT | linear (no reparent) once minted; audio_clock_slot fixed | kind_pcm_stream.pdx |
| `KIND_AUDIO_CLOCK` | 0x160 | — | — | kind_audio_clock.pdx |
| `KIND_AUDIO_ROUTE` | 0x161 | — | — | kind_audio_route.pdx |
| `KIND_USB_DEVICE` | 0x162 | — | — | kind_usb_device.pdx |
| `KIND_USB_HUB` | 0x163 | — | — | kind_usb_hub.pdx |
| `KIND_USB_INTERFACE` | 0x164 | — | — | kind_usb_interface.pdx |
| `KIND_USB_ENDPOINT` | 0x165 | — | — | kind_usb_endpoint.pdx |
| `KIND_MSC_LUN` | 0x166 | — | — | kind_msc_lun.pdx |
| `KIND_SCSI_DEVICE` | 0x167 | — | — | kind_scsi_device.pdx |
| `KIND_USB_URB` | 0x168 | — | — | kind_usb_urb.pdx |
| `KIND_ISOCH_STREAM` | 0x169 | — | — | kind_isoch_stream.pdx |
| `KIND_FP_SENSOR` | 0x16a | — | fingerprint sensor | kind_fp_sensor.pdx |
| `KIND_PCIE_HOTPLUG_EVENT` | 0x16b | — | — | kind_pcie_hotplug_event.pdx |
| `KIND_TB_DOMAIN` | 0x16c | — | Thunderbolt domain | kind_tb_domain.pdx |
| `KIND_TB_ROUTE` | 0x16d | — | Thunderbolt route | kind_tb_route.pdx |
| `KIND_DMA_ATTESTATION` | 0x16e | — | — | kind_dma_attestation.pdx |
| `KIND_DISPLAY_ENGINE` | 0x16f | — | — | kind_display_engine.pdx |
| `KIND_DISPLAY_OUTPUT` | 0x170 | — | parent of `KIND_PAGE_FLIP` | kind_display_output.pdx |
| `KIND_MODESET_TXN` | 0x171 | — | — | kind_modeset_txn.pdx |
| `KIND_DISPLAY_MODE` | 0x172 | — | — | kind_display_mode.pdx |
| `KIND_DISPLAY_PLANE` | 0x173 | — | — | kind_display_plane.pdx |
| `KIND_GPU_BO` | 0x174 | — | GPU buffer object | kind_gpu_bo.pdx |
| `KIND_GPU_VM` | 0x175 | — | — | kind_gpu_vm.pdx |
| `KIND_GPU_CONTEXT` | 0x176 | — | — | kind_gpu_context.pdx |
| `KIND_GPU_SUBMIT` | 0x177 | — | — | kind_gpu_submit.pdx |
| `KIND_WIFI_PHY` | 0x178 | — | — | kind_wifi_phy.pdx |
| `KIND_WIFI_VIF` | 0x179 | — | — | kind_wifi_vif.pdx |
| `KIND_WIFI_SCAN_TXN` | 0x17a | — | — | kind_wifi_scan_txn.pdx |
| `KIND_WIFI_KEY` | 0x17b | — | — | kind_wifi_key.pdx |
| `KIND_BT_GATT_CONNECTION` | 0x17c | — | Bluetooth GATT | kind_bt_gatt_connection.pdx |
| `KIND_BT_PAIRING` | 0x17d | — | — | kind_bt_pairing.pdx |
| `KIND_CSI_CAMERA` | 0x17e | — | — | kind_csi_camera.pdx |
| `KIND_IPU6_STREAM` | 0x17f | — | Intel IPU6 camera stream | kind_ipu6_stream.pdx |
| `KIND_WWAN_MODEM` | 0x180 | — | — | kind_wwan_modem.pdx |
| `KIND_MBIM_SESSION` | 0x181 | — | — | kind_mbim_session.pdx |
| `KIND_BT_ADAPTER` | 0x182 | — | — | kind_bt_adapter.pdx |
| `KIND_BT_HCI_CHANNEL` | 0x183 | — | — | kind_bt_hci_channel.pdx |
| `KIND_BT_L2CAP_CHANNEL` | 0x184 | — | — | kind_bt_l2cap_channel.pdx |
| `KIND_DISPLAY_TIMELINE` | 0x185 | — | — | kind_display_timeline.pdx |
| `KIND_VRR_RANGE` | 0x186 | — | variable refresh rate | kind_vrr_range.pdx |
| `KIND_VMD_ENDPOINT` | 0x187 | — | Intel VMD | kind_vmd_endpoint.pdx |
| `KIND_SCANOUT_LEASE` | 0x188 | — | — | kind_scanout_lease.pdx |
| `KIND_VK_SURFACE` | 0x189 | — | Vulkan surface | kind_vk_surface.pdx |
| `KIND_VK_SWAPCHAIN_IMAGE` | 0x18a | — | — | kind_vk_swapchain_image.pdx |
| `KIND_FONT_ATLAS` | 0x18b | — | — | kind_font_atlas.pdx |
| `KIND_TEXT_SHAPE` | 0x18c | — | — | kind_text_shape.pdx |
| `KIND_VELLO_SCENE` | 0x18d | — | Vello renderer scene | kind_vello_scene.pdx |
| `KIND_VELLO_RENDERER` | 0x18e | — | — | kind_vello_renderer.pdx |
| `KIND_COLOR_PROFILE` | 0x18f | — | — | kind_color_profile.pdx |

### 4.5 Session, security, storage, socket family (0x190–0x1c0)

| Kind | ID | Base | Ops highlights | File |
|---|---|---|---|---|
| `KIND_USER` | 0x190 | — | — | kind_user.pdx |
| `KIND_ELEVATE_CHANNEL` | 0x191 | KIND_IPC_ENDPOINT (5) | ops: `ELVC_OP_QUERY_REQ_ID/PID/KIND/RIGHTS/STATE/EXPIRE/BROKER`, `ELVC_OP_SET_EXPIRE`, `ELVC_OP_DEBUG_PRINT`; `elevate_channel_cap_revoke`. Consumer: privilege-elevation broker (fail-closed design, see §5). | kind_elevate_channel.pdx |
| `KIND_SCHEMA_HANDLE` | 0x1b2 | KIND_MEMORY | semantic-schema lookup handle | kind_schema_handle.pdx |
| `KIND_VOLUME` | 0x1a0 | KIND_MEMORY | — | kind_volume.pdx |
| `KIND_BLOCK_CACHE` | 0x1a1 | KIND_MEMORY | — | kind_block_cache.pdx |
| `KIND_INODE_HANDLE` | 0x1a2 | KIND_MEMORY (parent gate: `KIND_PDXFS_FILE`=0x195) | — | kind_inode_handle.pdx |
| `KIND_SIG_KEY` | 0x1a3 | KIND_MEMORY | PQ signature key handle (see §5) | kind_sig_key.pdx |
| `KIND_PDXFS_MOUNT_TABLE` | 0x1a5 | KIND_MEMORY | — | kind_pdxfs_mount_table.pdx |
| `KIND_TUI_CANVAS` | 0x1a6 | KIND_MEMORY | — | kind_tui_canvas.pdx |
| `KIND_TLS_TRUST` | 0x1a7 | KIND_MEMORY | — | kind_tls_trust.pdx |
| `KIND_UDP_SOCKET` | 0x1a8 | — | consumer: `sys_socket`/`sendto`/`recvfrom` (sysnos 87–97) | kind.pdx / net/udp_socket.pdx |
| `KIND_NIC` | 0x1ad | KIND_DEVICE | — | kind_nic.pdx |
| `KIND_TCP_SOCKET` | 0x1ab | — | mint: `tcp_socket_mint_child`; consumer: sysnos 87–102 TCP block | net/tcp_socket.pdx |
| `KIND_DISPLAY_BACKEND` | 0x1ae | KIND_DEVICE | consumer: `sys_display_enumerate`/`sys_framebuffer_create` (sysnos 108–109) | kind_display_backend.pdx |
| `KIND_FRAMEBUFFER` | 0x1af | KIND_MEMORY | ops: `FB_OP_QUERY_WIDTH/HEIGHT/STRIDE/FORMAT/VA`; mint gated on `R_FB_MAP` (0x001), backend row liveness, dim validity; consumer: `sys_framebuffer_create`/`sys_framebuffer_map` (sysnos 109–110), design/graphics/authority-boundary.md | kind_framebuffer.pdx |
| `KIND_PAGE_FLIP` | 0x1b0 | KIND_DISPLAY_OUTPUT (0x170) | consumer: `sys_page_flip`/`sys_page_flip_wait` (sysnos 111–112) | kind_page_flip.pdx |
| `KIND_HOTPLUG_CHANNEL` | 0x1b1 | KIND_IPC_ENDPOINT | consumer: `sys_display_hotplug_subscribe` (sysno 113) | kind_hotplug_channel.pdx |
| `KIND_VOLUME_SNAPSHOT` | 0x1b3 | KIND_VOLUME (0x1a0) | consumer: libpdx-volume v1.1.0 | kind_volume_snapshot.pdx |
| `KIND_KEK` | 0x1b4 | KIND_MEMORY | key-encryption-key handle; consumer: libpdx-volume | kind_kek.pdx |
| `KIND_SURFACE` | 0x1b8 | KIND_IPC_ENDPOINT | full row/rights/op detail in §6; consumer: postui compositor (user-side authority `src/user/compositor/surface_kind.pdx`) | kind_surface.pdx |
| `KIND_SESSION` | 0x1bc | KIND_IPC_ENDPOINT | — | kind_session.pdx |
| `KIND_CAPTURE` | 0x1be | KIND_IPC_ENDPOINT | screen-capture handle | kind_capture.pdx |
| `KIND_SEAT` | 0x1bf | KIND_IPC_ENDPOINT | ops: `seat_destroy`; consumer: compositor input-routing seat model | kind_seat.pdx |
| `KIND_SCREENCAST` | 0x1c0 | KIND_IPC_ENDPOINT | — | kind_screencast.pdx |
| `KIND_PDXFS_FILE` | 0x195 | KIND_MEMORY (= KIND_PAGE) | ops: `PFF_OP_QUERY_INODE/LEN/MODE/BIRTH/MTIME/REFS`, `PFF_OP_DEBUG_PRINT`, `PFF_OP_READ_BYTES`; `pdxfs_file_cap_revoke`; consumer: PdxFS syscall block (sysnos 70–107) | kind_pdxfs_file.pdx |
| `KIND_PDXFS_TXN` | 0x196 | KIND_MEMORY | consumer: `sys_pdxfs_txn_open/commit/abort` (sysnos 70, 104–105) | kind_pdxfs_txn.pdx |
| `KIND_TTY` | 0x197 | KIND_IPC_ENDPOINT | ops: `TTY_OP_WRITE/READ`, `QUERY_ROWS/COLS/ID/BYTES`, `SET_RAW/COOKED/ECHO_ON/ECHO_OFF`, `GET_ATTR`, `SET_VMIN/VTIME`, `DEBUG_PRINT`; `tty_cap_revoke`; consumer: shell, doc pager, line-discipline tools | kind_tty.pdx |
| `KIND_NVME_CONTROLLER` | 0x198 | KIND_DEVICE | — | kind_nvme_controller.pdx |
| `KIND_NVME_NAMESPACE` | 0x199 | KIND_MEMORY | tag alias `KIND_BLKDEV_TAG`=0x42 | kind_nvme_namespace.pdx |
| `KIND_AHCI_CONTROLLER` | 0x19a | KIND_DEVICE | — | kind_ahci_controller.pdx |
| `KIND_AHCI_PORT` | 0x19b | KIND_MEMORY | — | kind_ahci_port.pdx |
| `KIND_A11Y_NODE` | 0x1e6 | KIND_IPC_ENDPOINT | ops: `ANODE_OP_QUERY_PARENT/ROLE/LABEL_PTR/LABEL_LEN`, `ANODE_OP_DEBUG_PRINT`; `a11y_node_cap_mint`/`a11y_node_cap_revoke`; consumer: accessibility tree exposed by the compositor to assistive-technology clients | kind_a11y_node.pdx |

Base-kind columns left "—" above were not re-derived for this pass;
grep `KIND_<NAME>_BASE` in the corresponding file for the authoritative
parent.

## 5. Naming and numbering conventions

- **LAM-hint vs. full-kind dispatch.** Every dispatcher compares the
  full `u64` kind field (`cmp rcx, 0x1b8; je call_kind_surface`), never
  just the 4-bit LAM slot, because many derived kinds share a slot
  (§2). The LAM slot is a *hint* for fast paths only.
- **Row-indirection tail.** A kind whose live state exceeds 64 bits
  (the `target_ptr` field) stores `target_ptr = row_id` and keeps the
  real fields in a private fixed-size table (e.g. `_surface_table`,
  `_op_region_table`, `_dma_domain_table`). This is the dominant shape
  from `KIND_HW_INTERRUPT` onward.
- **LAM generation header.** Row-table kinds prefix each row with a
  64-bit header: top byte = `in_use` marker, low 56 bits = a
  monotonically bumped generation counter (ABA-hazard guard). See
  `kind_surface.pdx` §Row layout for the canonical shape
  (`hdr = ((old_gen+1) & 0x00FFFFFFFFFFFFFF) | (1<<56)`).
- **Failure-band convention.** Kernel-side substrate failure codes
  cluster in a per-kind `0xFFFFEnnn`-style band reserved at design time
  and verified free against the full failure-code tree before landing
  (e.g. `KIND_SURFACE` owns `0xFFFFE110`–`0xFFFFE11F`). User-facing mint
  validators use a disjoint band (`KIND_SURFACE`'s user-side failures
  sit at `0xFFFFEEF1`–`0xFFFFEEFA`).
- **Not-loader-seedable kinds.** A kind *defined by its derivation*
  (its identity comes from validating a parent capability, not from an
  argument) is deliberately excluded from the loader's cap-seeding
  table — seeding one would manufacture a root with no real parent.
  `KIND_EC_QUERY`, `KIND_THERMAL_ZONE`, `KIND_BATTERY`,
  `KIND_COOLING_DEVICE`, `KIND_BACKLIGHT`, `KIND_HID_EVENT`, and
  `KIND_SENSOR_CHANNEL` all carry this restriction explicitly in
  `kind.pdx`.
- **Rights bitmask layout.** Rights are always a `u64` bitmask with
  low bits reserved for the base primitive (READ=0x001, WRITE=0x002,
  INVOKE=0x008, REVOKE=0x010) and higher bits for kind-specific
  operations (e.g. `KIND_SURFACE`'s `R_SURFACE_MINT`=0x200,
  `R_SURFACE_OBSERVE`=0x400). An `_ALL` constant is the OR of every
  legal bit for that kind, used as the mint-time subset check.
- **`caps.decl` narrowing.** Independent of per-kind mint gates, every
  user-space image declares its maximum capability set in a
  `caps.decl` file (see `design/architecture/caps-decl-format.md`);
  `sys_execve`'s reconciler narrows inherited caps to that declaration,
  never widens.

## 6. Worked example: KIND_SURFACE (0x1b8)

`kind_surface.pdx` is the most fully documented kind in the tree and is
a useful template for reading any other row-indirected kind:

- Identity: `KIND_SURFACE_ID = 0x1B8`, base `KIND_IPC_ENDPOINT` (5).
- Rights: `R_SURFACE_READ/INVOKE/REVOKE/QUERY_GEOMETRY/ATTACH_BUFFER/
  COMMIT/DAMAGE/MINT/OBSERVE`, `R_SURFACE_ALL = 0x7F9`.
- Row: 16 rows × 64 bytes, LAM-generation header at +0, `surface_id`
  at +8, `owner_task_id` at +16, packed width/height at +24, format
  at +32, state+serial at +40, damage bbox at +48, pending/current
  buffer objects at +56.
- Mint (`surface_mint`): gates owner≠0, w/h≠0, format≠0, then a
  low-first free-slot scan; on success bumps
  `_surface_stats[SURFACE_ST_MINTS]` and emits a fingerprint log line.
- Destroy (`surface_destroy`): bumps generation, clears `in_use`,
  bumps `_surface_stats[SURFACE_ST_DESTROYS]`.
- Failure band: `0xFFFFE110`–`0xFFFFE11F` (kernel-side); user-side mint
  validators use `0xFFFFEEF1`–`0xFFFFEEFA` (declared in the sibling
  file `src/user/compositor/surface_kind.pdx`, the *canonical* identity
  authority — this kernel file mirrors the literal with a
  cross-reference comment, since paideia-as has no cross-boundary
  import mechanism).

## 7. Cross-references

- `src/kernel/core/cap/kind.pdx` — base 16-kind enum + every derived
  kind's identity/rights/base-parent rationale in one file's comments.
- `src/kernel/core/cap/kind_*.pdx` (112 files) — per-kind mint/query/
  revoke bodies; grep `OP_[A-Z_]+\s*:\s*u64` in a given file for its
  op table, `_cap_mint`/`_mint`/`_destroy`/`_cap_revoke` for its
  lifecycle functions.
- `design/architecture/caps-decl-format.md` — exec-time capability
  narrowing via `caps.decl`.
- `design/architecture/next-wave-derived-kinds.md` — design-time specs
  for several R29/R30/R32 derived kinds cited above.
- `design/graphics/authority-boundary.md` — `KIND_FRAMEBUFFER`/
  `KIND_PAGE_FLIP` rights discipline.
- `src/user/compositor/surface_kind.pdx` — user-side canonical
  authority for `KIND_SURFACE` identity and rights.
