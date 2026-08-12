# PaideiaOS — Next-Wave Derived-Kind Catalog

**Status:** Living document. First seed at R29.M0-001 (#1017).
**Scope:** Base + derived capability kinds introduced across the next-wave
rounds (R29+). Each entry records the runtime base kind (LAM kind-hint slot),
the descriptor-tail encoding, the rights bitmask, and the round/issue that
lands the derived kind. Structural companion to
`design/capabilities/linearity-and-tags.md` §3.1 and
`design/capabilities/derived-kinds.md` (Phase-2 catalog).

**Ordering discipline:** entries land in dependency order (base kinds before
their derived kinds) and reference their introducing GitHub issue. Every
`KIND_*` mentioned in `design/roadmap/next-wave-softarch.md` §3 or §4 has an
entry here before the corresponding round closes.

---

## Base kinds (R29+)

### `KIND_HW = 14` — hardware-adjacent base kind

**Introduced by:** R29.M0-001 (#1017). Promotes the previously-reserved
slot 14 (paideia-os prior label: "fault") per
`design/roadmap/next-wave-synthesis.md` §10 D6.

**Rationale.** The R29+ driver framework introduces a family of
hardware-adjacent capability kinds (interrupts, MSI-X vectors, IOMMU
domains, hardware timelines) that must be routed hot-path. Rather than
derive each from `KIND_DEVICE` (slot 10, which was overloaded across
device memory + config + register access), R29 opens a dedicated base
slot so the LAM kind-hint (4 bits) can fast-dispatch every
hardware-adjacent cap with a single `cmp rcx, 14; je call_kind_hw`
branch in `cap_invoke_dispatch`.

**Descriptor common header:** the 24-byte cap-table entry shape
inherited from `src/kernel/core/cap/mint.pdx`:

```
+0   kind:u64        = 14 (KIND_HW)
+8   rights:u64      = bitmask (see per-derived-kind tables below)
+16  target_ptr:u64  = pointer to the kind-specific tail (kernel-owned)
```

**Descriptor tail (base `KIND_HW` — no derived refinement):** empty. A
raw `KIND_HW` cap without a derived-kind tag is a *reservation marker*
only — it holds no hardware authority on its own. Derivation to one of
the R29.M1 concrete kinds (KIND_HW_INTERRUPT / KIND_HW_MSIX_VECTOR /
KIND_HW_DMA_DOMAIN / KIND_HW_TIMELINE) is required before any
hardware effect can be invoked.

**Rights bitmask (base):**

| Bit | Right | Meaning |
|-----|-------|---------|
| `RIGHT_OBSERVE` (0x400) | Read the kind label + presence | Introspection only. |
| `RIGHT_MINT`   (0x200) | Derive a concrete R29.M1 kind from this cap | Restricted to the supervisor / driver-registrar. |
| `RIGHT_REVOKE` (0x010) | Revoke the base + all derived children | Cascades per §7.5 of linearity-and-tags. |

All other rights bits (READ/WRITE/EXEC/INVOKE) are **denied** on a raw
`KIND_HW` cap — they are only meaningful on a derived cap where the tail
records the specific hardware handle. The mint gate at R29.M1 refines
the rights subset per derived kind (per the tables below).

**Dispatch today (R29.M0-001).** `cap_invoke_dispatch` has no branch for
`KIND_HW` yet; a freshly minted slot-14 cap falls through to the R8 MVP
identity return (`mov rax, rsi; ret` → returns `target_ptr`). This is
intentional — the dispatch branch + per-derived-kind handler set land as
a coordinated bundle in R29.M1.

**Boot witness.** `kernel_main.pdx §kind_hw_witness` mints a base
`KIND_HW` cap at cap_table slot 14 with `rights = RIGHT_OBSERVE |
RIGHT_MINT`, reads the descriptor back, asserts kind == 14 and rights ==
0x600, then emits `R29 KIND_HW OK`. This is a *structural* witness only
— it proves the enum slot is registered and mintable; the R29.M1
sub-issues add functional-dispatch witnesses per derived kind.

---

## Derived kinds over `KIND_HW` (R29.M1)

The four entries below are *planning skeletons* only — R29.M0-001 (this
issue) does not implement them. Each row is refined into a full spec by
the corresponding R29.M1 sub-issue when it lands.

### `KIND_HW_INTERRUPT` — landed by R29.M1-001..003 (#1019/#1020/#1021)

- **Runtime base kind:** `KIND_HW = 14`.
- **Derived-kind tag:** `0x140` (decimal 320; above the 4-bit base range,
  distinct from every existing derived-kind tag). LAM kind-hint remains
  slot 14 (KIND_HW) for fast-dispatch; the full `u64` kind field stored
  in the descriptor is what cap_invoke_dispatch compares against `0x140`
  to route to `cap_handler_hw_interrupt`.
- **Descriptor tail (finalized at R29.M1-002 #1020):** the cap
  descriptor's `target_ptr` slot holds a `row_id` in bits `[15:0]`; upper
  bits `[63:16]` MUST be zero. The actual 128-bit tail lives in
  `_hw_interrupt_table[row_id]`, a kernel-owned indirection table (32
  bytes / four u64s per row, 64 rows, `.bss`, `align 64`):
  - `[+0]` u64: `bits [31:0] = gsi (u32)` | `bits [39:32] = edge_or_level
    (u8; 0=edge, 1=level)` | `bits [63:56] = in_use flag`; bits `[55:40]`
    reserved (must be zero).
  - `[+8]` u64: `cpu_affinity_mask (u64)`.
  - `[+16]` u64: reserved (future: `polarity`, `ioapic_id`, `source_id`).
  - `[+24]` u64: reserved (future: `pending_count`, `last_ack_ns`).
- **Tail encoding rationale.** Softarch §3 R29 specifies the tail as
  `{gsi:u32, cpu_affinity_mask:u64, edge_or_level:u8}` — a 104-bit
  contract that cannot fit in the 64-bit `target_ptr`. Row indirection
  keeps the descriptor's shape unchanged and reserves 152 bits of
  headroom for R29.M2 (polarity/ioapic/source) without a descriptor
  layout change.
- **Rights (finalized at R29.M1-001 #1019):**
  - `R_HW_INT_INVOKE` (0x008 = `RIGHT_INVOKE`) — `OP_MASK` / `OP_UNMASK` /
    `OP_ACK` (deferred; stubs return `INVOKE_UNSUPPORTED` at R29.M1
    close, real bodies at R29.M2).
  - `R_HW_INT_REVOKE` (0x010 = `RIGHT_REVOKE`) — supervisor revoke.
  - `R_HW_INT_MINT`   (0x200 = `RIGHT_MINT`) — reserved for
    `KIND_HW_MSIX_VECTOR` derivation at R29.M1-004 (#1022); unused today.
  - `R_HW_INT_OBSERVE` (0x400 = `RIGHT_OBSERVE`) — `OP_QUERY_GSI` /
    `OP_QUERY_AFFINITY` / `OP_QUERY_TRIGGER`.
  - `R_HW_INT_ALL`    (0x618) — bitwise OR of all four; the only subset
    a supervisor-held cap ever needs.
- **Ops (op_arg[7:0]):**
  - `0 OP_QUERY_GSI`      — `R_HW_INT_OBSERVE` -> `gsi`.
  - `1 OP_QUERY_AFFINITY` — `R_HW_INT_OBSERVE` -> `cpu_affinity_mask`.
  - `2 OP_QUERY_TRIGGER`  — `R_HW_INT_OBSERVE` -> `edge_or_level`.
  - `3 OP_MASK`           — `R_HW_INT_INVOKE`  -> `INVOKE_UNSUPPORTED` (R29.M2).
  - `4 OP_UNMASK`         — `R_HW_INT_INVOKE`  -> `INVOKE_UNSUPPORTED` (R29.M2).
  - `5 OP_ACK`            — `R_HW_INT_INVOKE`  -> `INVOKE_UNSUPPORTED` (R29.M2).
- **Mint API (finalized at R29.M1-003 #1021).**
  `hw_int_cap_mint(slot, parent_slot, rights, gsi, cpu_affinity_mask,
  edge_or_level) -> u64`. Sequence: (1) bounds-check `slot` and
  `edge_or_level`; (2) `hw_int_check_parent_kind_hw(parent_slot)`
  asserts `cap_table[parent_slot].kind == 14` AND
  `rights & R_HW_INT_MINT != 0`; (3) `hw_int_rights_valid(rights)`;
  (4) `hw_int_tail_alloc` reserves + populates a row; (5) `cap_mint_write`
  writes the descriptor. Return: `HW_INT_MINT_OK` (0) on success, or one
  of `BAD_ARG`/`BAD_PARENT`/`BAD_RIGHTS`/`ENOSPC` (all `>= 0xFFFFFFFA`,
  disjoint from cap_mint_write's void return).
- **Revoke API (finalized at R29.M1-003 #1021).**
  `hw_int_cap_revoke(slot) -> u64`. Verifies `cap_table[slot].kind ==
  0x140`, extracts `row_id`, calls `hw_int_tail_free`, then clears the
  descriptor to (0,0,0). Idempotent on an already-null slot
  (`HW_INT_REVOKE_ALREADY`). Return codes disjoint from mint.
  **Cascade:** the `KIND_HW_MSIX_VECTOR` (#1022) revoke cascade is NOT
  performed here — landing when #1022 opens; the current implementation
  only frees the row and clears the parent descriptor.
- **Deprecation of pre-R29 `KIND_INTERRUPT = 9`.** The slot-9 kind
  (`src/kernel/core/cap/kind_interrupt.pdx` legacy stub) is deprecated
  at R29.M1-001 close but preserved as a compatibility alias until R30
  open. Both dispatch entries coexist in `invoke.pdx`:
  `cmp rcx, 9; je call_kind_interrupt` (legacy) and
  `cmp rcx, 0x140; je call_kind_hw_interrupt` (R29).
- **Boot witness.** `kernel_main.pdx §kind_hw_interrupt_witness` runs
  the full tail_alloc → decode → mint → dispatch → revoke loop against
  the KIND_HW parent minted at slot 14 (R29.M0-001). Twelve sub-tests
  covering happy path + three failure edges (BAD_ARG on
  `edge_or_level=2`; BAD_RIGHTS on `rights=0x04 EXEC`; BAD_PARENT on
  `parent_slot=0 KIND_PROCESS`). Emits `R29 KIND_INTERRUPT OK`.

### `KIND_HW_MSIX_VECTOR` — landed by R29.M1-004 (#1022)

- **Runtime base kind:** `KIND_HW = 14`.
- **Derived-kind tag:** `0x141` (adjacent to `KIND_HW_INTERRUPT`
  = `0x140`; distinct from every other derived-kind tag). LAM
  kind-hint remains slot 14 (KIND_HW); the full `u64` kind field is
  compared against `0x141` in `cap_invoke_dispatch` to route to
  `cap_handler_hw_msix_vector`.
- **Semantic layering.** Derives over `KIND_HW_INTERRUPT` (not
  directly over `KIND_HW`). A `KIND_HW_INTERRUPT` cap authorizes a
  line/GSI and MINTS N `KIND_HW_MSIX_VECTOR` children — one per MSI-X
  vector on the underlying device (e.g. NVMe with 4 MSI-X vectors →
  4 `KIND_HW_MSIX_VECTOR` children under one `KIND_HW_INTERRUPT`
  parent). This preserves the per-device authority boundary: a
  driver holds N children under exactly one interrupt-authority
  parent, and revoking the parent auto-revokes every child.
- **Descriptor tail (finalized at R29.M1-004 #1022):** the cap
  descriptor's `target_ptr` slot holds a `row_id` in bits `[15:0]`;
  upper bits `[63:16]` MUST be zero. The row lives in
  `_hw_msix_vector_table[row_id]` (32 bytes / four u64s per row,
  64 rows, `.bss`, `align 64`):
  - `[+0]` u64: `bits [31:0]  = msix_table_offset (u32; byte offset
    into the device's MSI-X table BAR)`,
    `bits [39:32] = parent_slot (u8; cap_table slot of the
    KIND_HW_INTERRUPT parent — used for O(N) cascade revocation)`,
    `bits [63:56] = in_use flag`; bits `[55:40]` reserved.
  - `[+8]` u64: `bits [31:0] = msix_data (u32; payload written to the
    MSI-X message-data register on vector arm)`; `bits [63:32]`
    reserved (future: `msix_addr_hi/lo` overrides, mask/pending
    shadow bits).
  - `[+16]` u64: reserved (future: `target_apic_id`, `delivery_mode`,
    `polarity`).
  - `[+24]` u64: reserved (future: `fire_count`, `last_fire_ns`).
- **Tail encoding rationale.** Storing `parent_slot` inside the row
  is what makes cascade revocation efficient. The parent's revoke
  (`hw_int_cap_revoke`) calls `msix_cascade_revoke_by_parent(slot)`
  which scans `cap_table[0..255]`; for each descriptor whose kind is
  `0x141`, it reads the row's `parent_slot` field and revokes iff
  it matches. Cost is O(256) per parent revoke — well below any
  hot-path threshold at R29 substrate stage. Stashing `parent_slot`
  in the descriptor's `rights` field was rejected because rights is
  a security-sensitive bitmask and repurposing bits would leak into
  the `msix_rights_valid` gate; the row is the correct home for
  hardware-shape metadata.
- **Rights (finalized at R29.M1-004 #1022):**
  - `R_MSIX_INVOKE` (0x008 = `RIGHT_INVOKE`) — query ops
    (OP_QUERY_TABLE_OFFSET / OP_QUERY_DATA / OP_QUERY_PARENT) plus
    OP_MASK / OP_UNMASK (real MSI-X wire-up at R29.M2).
  - `R_MSIX_REVOKE` (0x010 = `RIGHT_REVOKE`) — supervisor revoke path.
  - `R_MSIX_MINT`   (0x200 = `RIGHT_MINT`) — reserved for a future
    per-vector delegation path (unused at R29.M1-004).
  - `R_MSIX_ALL`    (0x218) — bitwise OR of the three; the only
    subset a supervisor-held cap ever needs.
  - **No `RIGHT_OBSERVE` branch.** The #1022 directive pins rights to
    `{MINT, REVOKE, INVOKE}` only. Query ops therefore gate on
    `RIGHT_INVOKE` (not `RIGHT_OBSERVE`) — the two are cleanly
    separated at the handler level.
- **Ops (op_arg[7:0]):**
  - `0 OP_QUERY_TABLE_OFFSET` — `RIGHT_INVOKE` -> `msix_table_offset`.
  - `1 OP_QUERY_DATA`         — `RIGHT_INVOKE` -> `msix_data`.
  - `2 OP_QUERY_PARENT`       — `RIGHT_INVOKE` -> `parent_slot`.
  - `3 OP_MASK`               — `RIGHT_INVOKE` -> `INVOKE_UNSUPPORTED` (R29.M2).
  - `4 OP_UNMASK`             — `RIGHT_INVOKE` -> `INVOKE_UNSUPPORTED` (R29.M2).
- **Mint API (finalized at R29.M1-004 #1022).**
  `msix_cap_mint(slot, parent_slot, rights, msix_table_offset,
  msix_data) -> u64`. Sequence: (1) bounds-check `slot < 256`;
  (2) `msix_check_parent_kind_hw_int(parent_slot)` asserts
  `cap_table[parent_slot].kind == 0x140` (KIND_HW_INTERRUPT) AND
  `rights & R_HW_INT_MINT != 0`; (3) `msix_rights_valid(rights)`;
  (4) `msix_tail_alloc` reserves a row and stashes
  `(msix_table_offset, msix_data, parent_slot)`; (5) `cap_mint_write`
  writes the descriptor. Return: `MSIX_MINT_OK` (0) on success, or
  one of `BAD_ARG` / `BAD_PARENT` / `BAD_RIGHTS` / `ENOSPC`
  (all `>= 0xFFFFFFEA`, disjoint from `HW_INT_MINT_*`).
- **Revoke API (finalized at R29.M1-004 #1022).**
  `msix_cap_revoke(slot) -> u64`. Verifies
  `cap_table[slot].kind == 0x141`, extracts `row_id`, frees the row,
  clears the descriptor to (0,0,0). Idempotent
  (`MSIX_REVOKE_ALREADY`). Return codes disjoint from mint.
  **Cascade path** — `msix_cascade_revoke_by_parent(parent_slot) ->
  count`: scans `cap_table[0..255]` for KIND_HW_MSIX_VECTOR children
  whose row's `parent_slot` matches; revokes each. Called from
  `hw_int_cap_revoke` BEFORE the parent frees its own row so the
  cascade can still observe the parent-slot metadata during
  row-decode. Returns the count of children revoked (informational).
- **Boot witness.** `kernel_main.pdx §kind_hw_msix_vector_witness`
  runs the full mint → dispatch → cascade-revoke loop:
  - Mints one KIND_HW_INTERRUPT parent at slot 15 (gsi=0x40).
  - Mints 4 KIND_HW_MSIX_VECTOR children at slots 16..19 with
    distinct `(offset, data)` tuples:
    - slot 16: `(0x00, 0x8001)`
    - slot 17: `(0x10, 0x8002)`
    - slot 18: `(0x20, 0x8003)`
    - slot 19: `(0x30, 0x8004)`
  - Verifies each `cap_table[16..19]` reads back `kind=0x141`,
    `rights=0x218`.
  - Round-trips OP_QUERY_TABLE_OFFSET / OP_QUERY_DATA /
    OP_QUERY_PARENT through `cap_invoke_dispatch` on all four
    children — 12 dispatch invocations total.
  - Failure edge: mint with `parent_slot=14` (KIND_HW, not
    KIND_HW_INTERRUPT) returns `MSIX_MINT_BAD_PARENT`.
  - Failure edge: `msix_rights_valid(0x800)` (bit not in R_MSIX_ALL)
    returns 0.
  - Revokes the parent at slot 15 → cascade auto-revokes all four
    children → verify each child slot and the parent slot are
    cleared (`kind=0`, `rights=0`, `target_ptr=0`). Emits
    `R29 KIND_MSIX_VECTOR OK`.

### `KIND_HW_DMA_DOMAIN` — planned for a later R29 milestone

- **Runtime base kind:** `KIND_HW = 14`.
- **Derived-kind tag:** `0x142`.
- **Descriptor tail:** `{iommu_ctx_ptr:u64, bdf:u16, ats_enabled:u1,
  pri_enabled:u1, address_width:u8}`.
- **Rights:** `RIGHT_MINT` (map / unmap a page into the domain),
  `RIGHT_REVOKE` (tear the domain down), `RIGHT_OBSERVE` (fault log).
- **Ops:** `OP_MAP`, `OP_UNMAP`, `OP_FLUSH`, `OP_QUERY_FAULT`.
- **Interaction with `KIND_PAGE = 4`:** a `KIND_PAGE` cap must accompany
  every `OP_MAP` — the domain cap authorizes the mapping site, the page
  cap authorizes the physical page. Cross-cap consent per the R29 IOMMU
  invariant.
- **Domain granularity — per-driver-process (D1.b).** One
  `KIND_HW_DMA_DOMAIN` per driver process, shared across every device
  the driver claims. Minted at driver-process spawn by the supervisor
  and delivered via the loader's `_init_caps` sidecar
  (`design/loader/init-caps-sidecar.md`); revoked on process exit,
  which tears down every context entry attributed to it. Full rationale
  (per-driver-process vs per-device vs per-firmware-image), the
  CNVi-shared-domain blast-radius acknowledgment, and the
  `dma_domain_attach(domain, bdf)` supervisor entry point are
  documented in `design/drivers/blob-policy.md` §2. This rule governs
  both blob-consuming drivers (Wi-Fi, BT, IPU6, GuC, SOF) and native
  drivers uniformly.

### `KIND_HW_TIMELINE` — planned for a later R29 milestone

- **Runtime base kind:** `KIND_HW = 14`.
- **Derived-kind tag:** `0x143`.
- **Descriptor tail:** `{monotonic_ns_offset:i64, resolution_ns:u32,
  source:{tsc=0|hpet=1|apic=2|dev_clock=3}, clock_id:u16}`.
- **Rights:** `RIGHT_READ` (sample current value), `RIGHT_OBSERVE`
  (metadata: resolution, source, drift bounds).
- **Ops:** `OP_SAMPLE`, `OP_QUERY_META`, `OP_WAIT_UNTIL` (blocking; may be
  gated behind a scheduler-context cap per R29.M4).
- **Foundational for:** every subsequent R30–R40 hardware clock-domain
  crossing carries a `KIND_HW_TIMELINE` cap. GPU→display, GPU→CPU,
  audio-mclk→CPU, USB-SOF→isoch endpoint, network-PTP→application all
  derive from this base (see `next-wave-softarch.md` §4).

---

## Driver runtime state (R29.M2)

The R29.M2 milestone (Lifecycle FSM real bodies + regression corpus)
introduces the *first non-capability* kernel-owned runtime table
described in this document: the driver-process descriptor. The two
subsystems are catalogued here because the descriptor is the substrate
KIND_DRIVER (R29.M3+) will name-and-authorise, and the FSM is the
sole legal state-machine every subsequent R29.M2..M7 op (start /
suspend / resume / handoff_begin / stop, plus the R29.M7 chaos-restart
cascade) drives.

### Driver descriptor table — landed by R29.M2-001 (#1023)

- **Storage:** `_driver_table` in `src/kernel/core/driver/driver_table.pdx`
  — 32 rows × 48 bytes = 1536 B `.bss`, `@align(64)`. `.bss` zero-init
  means every row starts with `in_use=0`; `driver_table_register` is the
  sole entry point to flip `in_use` to 1.
- **Row layout (48 B, six u64s):**
  - `[+0]` u64 header: `bits [7:0] = state` (`DRIVER_STATE_*`),
    `bits [15:8] = in_use` (0=free, 1=allocated), `bits [31:16] = reserved`,
    `bits [63:32] = pid` (u32).
  - `[+8]` u64: `caps_manifest_offset` (u32 low bits) — byte offset into
    the supervisor's per-driver manifest region.
  - `[+16]` u64: `name[0..7]`.
  - `[+24]` u64: `name[8..15]`.
  - `[+32]` u64: reserved — future `restart_count + last_restart_ns`.
  - `[+40]` u64: reserved — future `audit_seq + supervisor_hint`.
- **Capacity rationale:** 32 slots is one power-of-two above the T14 G4
  driver census (≈24 drivers at boot per `design/drivers/architecture.md`
  §2). Not sized to `cap_table` (256) because a driver-process density of
  256 exceeds the wire-in-hand shape of a laptop and would waste ~11 KiB.
- **Primitives:** `driver_table_register`, `driver_table_unregister`,
  `driver_table_slot_in_use`, `driver_table_read_state_byte`,
  `driver_table_write_state_byte`, `driver_table_read_pid`,
  `driver_table_read_caps_offset`, `driver_table_row_addr`.
- **Return codes:** `DRIVER_TABLE_REGISTER_OK` (0),
  `DRIVER_TABLE_REGISTER_BAD_SLOT` (0xFFFFFEFF),
  `DRIVER_TABLE_REGISTER_ALREADY_USED` (0xFFFFFEFE). Disjoint from the
  `DRIVER_LIFECYCLE_*` codes below so a mixed-caller trace remains
  observably distinct.

### Driver lifecycle FSM — landed by R29.M2-001 (#1023)

- **Module:** `src/kernel/core/driver/lifecycle.pdx`.
- **States (six):**

  | State | Value | Meaning |
  |------:|:-----:|---------|
  | `DRIVER_STATE_INIT`      | 0 | driver process spawned, capabilities plumbed, not yet running. |
  | `DRIVER_STATE_RUNNING`   | 1 | driver serving requests. |
  | `DRIVER_STATE_SUSPENDED` | 2 | paused (OS suspend, driver-directed pause, or supervisor policy). |
  | `DRIVER_STATE_HANDOFF`   | 3 | draining state to a replacement driver (graceful takeover). |
  | `DRIVER_STATE_STOPPING`  | 4 | committed to termination; queue is being drained. |
  | `DRIVER_STATE_STOPPED`   | 5 | terminal; supervisor may `driver_table_unregister` after reaping the process. |

- **Whitelist of nine legal transitions:**

  ```text
  Init      -> Running     (start)
  Running   -> Suspended   (suspend)
  Suspended -> Running     (resume)
  Running   -> Handoff     (handoff_begin — graceful takeover)
  Suspended -> Handoff     (handoff_begin from paused driver)
  Handoff   -> Stopping    (stop)
  Running   -> Stopping    (direct stop, no handoff)
  Suspended -> Stopping    (direct stop from paused driver)
  Stopping  -> Stopped     (final drain complete)
  ```

  Every other transition is rejected with `DRIVER_LIFECYCLE_ERR_INVALID_TRANSITION`.

- **Representation:** the whitelist is packed into a single u64
  constant `DRIVER_LIFECYCLE_TABLE = 0x00000020101A1C02`. Byte `i` holds
  the 6-bit bitmap of legal target states from state `i`. Transition
  check reduces to `(TABLE >> (cur * 8)) & (1 << new)` — O(1),
  branch-free (past the outer bounds gates), fuzz-friendly.
- **Primitives:**
  - `driver_lifecycle_transition_valid(cur, new) -> u64` — pure predicate;
    returns 1 iff the (cur, new) pair is on the whitelist. Exposed
    independently so R29.M2-005's fuzz corpus enumerates the 36-cell
    grid without touching `_driver_table`.
  - `driver_lifecycle_get_state(slot) -> u64` — returns current state
    byte (0..5) or `DRIVER_LIFECYCLE_ERR_BAD_SLOT` (slot out of range
    OR row not in_use).
  - `driver_lifecycle_transition(slot, new_state) -> u64` — validated
    FSM transition. Sequence: slot gate → new_state range gate →
    read cur → whitelist check → commit. Every gate returns a distinct
    error code.
- **Return codes:**
  - `DRIVER_LIFECYCLE_OK` (0).
  - `DRIVER_LIFECYCLE_ERR_BAD_SLOT` (0xFFFFFF01) — slot >= 32 OR not `in_use`.
  - `DRIVER_LIFECYCLE_ERR_UNKNOWN_STATE` (0xFFFFFF02) — `new_state` >= 6.
  - `DRIVER_LIFECYCLE_ERR_INVALID_TRANSITION` (0xFFFFFF03) — `(cur, new)`
    not on whitelist.
- **Boot witness:** `kernel_main.pdx §driver_lifecycle_witness` walks
  the full `Init → Running → Suspended → Running → Suspended → Handoff
  → Stopping → Stopped` chain, then exercises every rejection code
  (Stopped→Running, bogus state, bogus slot, unregistered slot). Emits
  `R29 LIFECYCLE FSM OK` on success — the R29.M2-001 boot fingerprint.
- **Concurrency:** R29.M2 substrate is single-flow pre-scheduler-bringup;
  no ABA guard, no per-row lock. SMP-safety revisits at R29.M7 (chaos-
  restart harness).
- **Downstream consumers** (all R29.M2..M7 issues):
  - `#1024` — driver_supervisor_channel wiring: RPC ops `start` /
    `suspend` / `resume` / `handoff_begin` / `stop` map 1:1 onto the
    six FSM transitions.
  - `#1025` — supervisor policy for driver-initiated `suspend` /
    `resume` (self-suspend on idle timeout).
  - `#1026` — handoff protocol (state serialisation over
    `driver_hotplug_channel`).
  - `#1027` — regression corpus: 36-cell fuzz grid via
    `driver_lifecycle_transition_valid`.
  - `#1028+` (R29.M3 registry v2) — persists the driver descriptor
    across restarts.
  - `#1035+` (R29.M6 audit surface) — every transition emits an audit
    record tagged with (slot, old, new, ts).

---

## Base kinds reserved for later rounds

### `KIND_RESERVED = 15` — confidential-computing / TDX (D1)

Slot 15 remains reserved per CAP-Q9. The R33+ confidential-computing
work (D1) will consume it. Slot 15 is currently *also* used as the
runtime base for the `KIND_DMESG` derived kind (logging-m9-001, tag
`0x16`) — this derivation pattern is orthogonal to any future D1 base
kind and will migrate to a derived-tag over the future D1 kind if a
collision arises.

---

## Change log

| Date | Round | Issue | Change |
|------|-------|-------|--------|
| 2026-08-12 | R29.M0 | #1017 | Initial doc + `KIND_HW = 14` base kind row + R29.M1 derived-kind skeletons. |
| 2026-08-12 | R29.M1 | #1019/#1020/#1021 | Refined `KIND_HW_INTERRUPT` row: finalized numeric tag (0x140), tail-encoding scheme (row indirection via `_hw_interrupt_table`), rights bitmask (`R_HW_INT_ALL = 0x618`), full mint/revoke API, dispatch handler. Landed by `src/kernel/core/cap/kind_hw_interrupt.pdx`. |
| 2026-08-12 | R29.M1 | #1022 | Landed `KIND_HW_MSIX_VECTOR = 0x141` — second derived kind over KIND_HW, layered atop `KIND_HW_INTERRUPT`. Row-indirection tail via `_hw_msix_vector_table` encoding `{msix_table_offset:u32, msix_data:u32, parent_slot:u8}`. Rights bitmask `R_MSIX_ALL = 0x218` (INVOKE/REVOKE/MINT). Full mint / revoke / cascade-revoke API + dispatch handler in `src/kernel/core/cap/kind_hw_msix_vector.pdx`. Cascade wired into `hw_int_cap_revoke` (calls `msix_cascade_revoke_by_parent` before freeing its own row). Design doc `KIND_HW_MSIX_VECTOR` row rewritten from planning skeleton to as-landed spec; `KIND_HW_DMA_DOMAIN` + `KIND_HW_TIMELINE` rows relabeled as "planned for a later R29 milestone" (issue-number attribution corrected — R29.M1 closes with two derived kinds landed). Closes R29.M1. |
| 2026-08-12 | R29.M2 | #1023 | Landed driver-process lifecycle FSM (Init/Running/Suspended/Handoff/Stopping/Stopped) with nine-transition whitelist packed as `DRIVER_LIFECYCLE_TABLE = 0x00000020101A1C02`. Landed 32-slot `_driver_table` (48 B rows in .bss) as the descriptor storage. Full primitives (`driver_lifecycle_transition`, `driver_lifecycle_get_state`, `driver_lifecycle_transition_valid`; `driver_table_register`, `driver_table_unregister`, `driver_table_slot_in_use`, `driver_table_read_state_byte`, `driver_table_write_state_byte`, `driver_table_read_pid`, `driver_table_read_caps_offset`, `driver_table_row_addr`) in `src/kernel/core/driver/lifecycle.pdx` + `driver_table.pdx`. Boot witness at `kernel_main.pdx §driver_lifecycle_witness` walks the full Init→Stopped path and exercises every rejection code — fingerprint `R29 LIFECYCLE FSM OK`. Opens R29.M2. |

---

## References

- `design/capabilities/linearity-and-tags.md` §3.1 — base kind hierarchy.
- `design/capabilities/derived-kinds.md` — Phase-2 derived-kind catalog.
- `design/roadmap/next-wave-synthesis.md` §10 D6 — slot 14 promotion decision.
- `design/roadmap/next-wave-softarch.md` §3 R29 — driver-framework maturation
  round detail; §4 for GPU/display timeline chain.
- `src/kernel/core/cap/kind.pdx` — the KIND_* enum.
- `src/kernel/core/cap/invoke.pdx` — dispatch table.
