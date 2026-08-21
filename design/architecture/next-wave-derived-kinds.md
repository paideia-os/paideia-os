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
KIND_HW_TIMELINE) is required before any hardware effect can be
invoked. (The fourth skeleton originally listed here,
`KIND_HW_DMA_DOMAIN`, was renamed to `KIND_DMA_DOMAIN` and re-based over
`KIND_MEMORY` at R29.M5-001 #1036 — see "Derived kinds over
`KIND_MEMORY`" below.)

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

The entries below started as *planning skeletons* at R29.M0-001, each
refined into a full spec by its sub-issue when it lands. Two have landed
(`KIND_HW_INTERRUPT`, `KIND_HW_MSIX_VECTOR`); `KIND_HW_TIMELINE` remains
a skeleton. A fourth skeleton, `KIND_HW_DMA_DOMAIN`, left this family
entirely at R29.M5-001 (#1036) — see "Derived kinds over `KIND_MEMORY`".

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

> **`KIND_HW_DMA_DOMAIN` — retired name.** The DMA-domain skeleton that
> previously sat here has been renamed to **`KIND_DMA_DOMAIN`** and moved
> to its own section below, because it does *not* derive over `KIND_HW`.
> See "Derived kinds over `KIND_MEMORY` (R29.M5)" for the as-landed spec
> and the full naming rationale. No code ever referenced the old name, so
> this is a rename, not an alias.

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

## Derived kinds over `KIND_MEMORY` (R29.M5)

`KIND_MEMORY` is the name `design/roadmap/next-wave-softarch.md` §P10
uses for the memory base kind. In the closed 16-slot runtime enum that
base kind is **slot 4, `KIND_PAGE`** ("individual memory page or
region"; its dispatch chatter is literally `CAP INVOKE MEM`). R29.M5-001
binds the two names together once, in
`src/kernel/core/cap/kind.pdx` (`pub let KIND_MEMORY : u64 = 4`), so
that every derived kind specified as "derived over `KIND_MEMORY`" lands
on the same slot instead of drifting. This is an **alias, not a new base
kind** — the closed enum is unchanged.

### `KIND_DMA_DOMAIN` — landed by R29.M5-001 (#1036) + R29.M5-002 (#1037)

- **Runtime base kind:** `KIND_MEMORY = KIND_PAGE = 4`.
- **Derived-kind tag:** `0x142` (decimal 322). The full `u64` kind field
  is compared against `0x142` in `cap_invoke_dispatch` to route to
  `cap_handler_dma_domain`; the LAM kind-hint reads slot 4.

#### Naming + derivation reconciliation (resolved at #1036)

This doc previously carried a planning skeleton named
`KIND_HW_DMA_DOMAIN` with runtime base `KIND_HW = 14`, grouped with the
R29.M1 hardware-adjacent kinds. `design/roadmap/next-wave-softarch.md`
§3 R29 — and issues #1036/#1037, which are the binding specification —
name it `KIND_DMA_DOMAIN` and derive it over `KIND_MEMORY`. **The
softarch / issue form wins.** Rationale:

- **A DMA domain is a memory-access scope, not a device-authority
  handle.** It names the set of physical pages a bus-mastering device is
  permitted to reach. Deriving it over `KIND_HW` would let a holder of
  pure device authority manufacture new memory reach — the exact
  inversion of the R29 IOMMU invariant, under which the domain cap
  authorizes the mapping *site* and a `KIND_PAGE` cap authorizes the
  *page*. Deriving over `KIND_MEMORY` makes the mint gate structurally
  enforce "you cannot widen a device's reach beyond memory authority you
  already hold."
- **The name had to move with the base.** Keeping the `HW_` infix while
  changing the base would leave the name asserting a base kind that is
  no longer true, so `KIND_HW_DMA_DOMAIN` is *renamed*, not aliased. No
  code ever referenced the skeleton, so nothing breaks.
- **The numeric tag `0x142` is retained.** The `0x14x` block is the
  *R29-round* derived-kind block, not a base-slot encoding — the
  pre-existing derived tags already show no correspondence between tag
  prefix and base slot (`KIND_DRIVER = 0x15` has base 10;
  `KIND_DMESG = 0x16` has base 15). Keeping `0x142` leaves the R29 block
  contiguous (`0x140` interrupt / `0x141` msix / `0x142` dma domain /
  `0x143` timeline reserved) and avoids re-numbering a published value.

#### Descriptor tail (finalized at #1036/#1037)

The tail is `{iommu_ctx_id:u32, bus_dev_fn:u16, capacity_bytes:u64,
coherency:u8}` = 104 live bits, which does not fit the descriptor's
64-bit `target_ptr`. It therefore uses the **same row-indirection shape**
as `KIND_HW_INTERRUPT` (#1019) and `KIND_HW_MSIX_VECTOR` (#1022) — a
third encoding would fragment the revoke/cascade reasoning. `target_ptr`
holds a `row_id` in bits `[15:0]`; bits `[63:16]` MUST be zero.

Rows live in `_dma_domain_table` (32 rows × 32 bytes = 1024 B, `.bss`,
`align 64`), in `src/kernel/core/cap/kind_dma_domain.pdx`:

- `[+0]` u64: `bits [31:0] = iommu_ctx_id` (u32; VT-d context-entry id),
  `bits [47:32] = bus_dev_fn` (u16; PCI BDF — bus`[15:8]`, dev`[7:3]`,
  fn`[2:0]`), `bits [55:48] = coherency` (u8; `0` = coherent,
  `1` = non-coherent), `bits [63:56] = in_use` flag.
- `[+8]` u64: `capacity_bytes` — mapped-window ceiling. The one tail
  field that gets a whole word rather than a bitfield, because a 1 TiB
  GPU aperture must be representable.
- `[+16]` u64: `bits [7:0] = parent_slot` (u8; cap_table slot of the
  `KIND_MEMORY` ancestor, for O(N) cascade revocation — exactly as
  `KIND_HW_MSIX_VECTOR` stores its parent); `bits [63:8]` reserved.
- `[+24]` u64: reserved (R29.M5-003/004: `mapped_bytes` running total,
  ATS/PRI enable bits, `address_width`, fault counter).

**Table sizing.** `DMA_DOMAIN_MAX = 32`. One domain per driver process
(D1.b) and `_driver_table` is itself 32 slots, so 32 domains is exactly
the reachable ceiling — a larger table could not be filled by legal
minting.

#### Canonical tail word (#1037)

`dma_tail_pack(iommu_ctx_id, bus_dev_fn, coherency) -> u64` is THE
canonical encoding of the three bitfield members:

```
tail_word = (iommu_ctx_id & 0xFFFFFFFF)
          | ((bus_dev_fn  & 0xFFFF) << 32)
          | ((coherency   & 0xFF)   << 48)
```

It returns `0xFFFFFFFFFFFFFFFF` on malformed input (`ctx >= 2^32`,
`bdf >= 2^16`, `coherency > 1`). That sentinel can never collide with a
well-formed word, whose bits `[63:56]` are always zero — those bits
belong to the allocator's `in_use` flag, and a caller-supplied word with
them set is rejected.

The tail word is not cosmetic. SysV argument registers cap the mint
entry point at 6 arguments; a naive
`(slot, parent_slot, rights, ctx, bdf, capacity, coherency)` needs 7.
Folding the three bitfields into their on-row representation brings it
to 5 **and** makes the caller's argument byte-identical to what lands in
the row — so the encoding is defined in exactly one place, with no
reshuffle between API boundary and storage. `capacity_bytes` stays
separate because it is a full u64.

Decoders come in two families: `dma_tail_word_{ctx_id,bdf,coherency}`
operate on a packed word (round-trip assertable without touching the
table), and `dma_tail_decode_{ctx_id,bdf,capacity,coherency,parent}`
operate on a live row (bounds- + `in_use`-checked, returning
`DMA_DECODE_BAD` on a dead row so a legitimate zero value is never
confused with failure).

#### Rights (finalized at #1036)

- `R_DMA_INVOKE`  (`0x008` = `RIGHT_INVOKE`)  — query ops + `OP_FLUSH`.
- `R_DMA_REVOKE`  (`0x010` = `RIGHT_REVOKE`)  — supervisor teardown.
- `R_DMA_MINT`    (`0x200` = `RIGHT_MINT`)    — `OP_MAP` / `OP_UNMAP`.
- `R_DMA_OBSERVE` (`0x400` = `RIGHT_OBSERVE`) — `OP_QUERY_FAULT` and the
  canonical debug printer.
- `R_DMA_ALL`     (`0x618`) — bitwise OR of the four.

Unlike `KIND_HW_MSIX_VECTOR` (whose #1022 directive pinned rights to
`{MINT, REVOKE, INVOKE}`), this kind **does** carry `RIGHT_OBSERVE`: the
IOMMU fault stream is an observe-class channel, and a monitor should be
able to read DMA faults without holding authority to map pages. The
handler therefore gates **per-op**, not once at entry — mapping a page
into a device's reach is a strictly stronger authority than reading which
BDF the domain is bound to, and reading the fault log is strictly weaker.
A single entry gate would collapse all three into whichever was chosen,
which is precisely the over-grant this kind exists to prevent.

#### Ops (`op_arg[7:0]`) and required right

| Op | Code | Right | Behavior |
|----|------|-------|----------|
| `OP_QUERY_CTX_ID`    | 0 | INVOKE  | -> `iommu_ctx_id` |
| `OP_QUERY_BDF`       | 1 | INVOKE  | -> `bus_dev_fn` |
| `OP_QUERY_CAPACITY`  | 2 | INVOKE  | -> `capacity_bytes` |
| `OP_QUERY_COHERENCY` | 3 | INVOKE  | -> `coherency` |
| `OP_QUERY_PARENT`    | 4 | INVOKE  | -> `parent_slot` |
| `OP_MAP`             | 5 | MINT    | `INVOKE_UNSUPPORTED` (R29.M5-003) |
| `OP_UNMAP`           | 6 | MINT    | `INVOKE_UNSUPPORTED` (R29.M5-003) |
| `OP_FLUSH`           | 7 | INVOKE  | `INVOKE_UNSUPPORTED` (R29.M5-004) |
| `OP_QUERY_FAULT`     | 8 | OBSERVE | `INVOKE_UNSUPPORTED` (R29.M5-004) |
| `OP_DEBUG_PRINT`     | 9 | OBSERVE | canonical row printer -> `DMA_TAIL_OK` |

The rights gate runs **before** the unimplemented-op return, so an
unauthorized caller gets `INVOKE_DENIED` even for an op that is not yet
implemented.

**Interaction with `KIND_PAGE = 4`:** a `KIND_PAGE` cap must accompany
every `OP_MAP` — the domain cap authorizes the mapping site, the page cap
authorizes the physical page. Cross-cap consent per the R29 IOMMU
invariant. (`OP_MAP` lands at R29.M5-003.)

#### Canonical debug printer (#1037)

`dma_domain_debug_print(row_id)` emits one klog line per tail field at
`LEVEL_INFO` under `SUBSYS_CAP_`, all sharing the tag `DMA DOMAIN ROW`
so the five lines read as one record:

```
... |I|CAP_|DMA DOMAIN ROW row=0x0000000000000000
... |I|CAP_|DMA DOMAIN ROW ctx=0x00000000deadbeef
... |I|CAP_|DMA DOMAIN ROW bdf=0x0000000000000308
... |I|CAP_|DMA DOMAIN ROW cap=0x0000000040000000
... |I|CAP_|DMA DOMAIN ROW coh=0x0000000000000001
```

Five `klog_s1_x1` calls rather than one wide wrapper: the KV wrappers cap
out at what fits in SysV argument registers (`klog_s1_x2` already needs a
caller-side stack push for its second value), and a per-field line keeps
the printer's own failure mode trivial. A dead or out-of-range row prints
**nothing** and returns `DMA_DECODE_BAD` — a debug printer must never
emit fabricated field values for a row that does not exist. Reachable
through dispatch as `OP_DEBUG_PRINT` (needs `RIGHT_OBSERVE`).

#### Mint API

`dma_cap_mint(slot, parent_slot, rights, tail_word, capacity_bytes)`.
Sequence: (1) bounds-check `slot < 256`;
(2) `dma_check_parent_kind_memory(parent_slot)` asserts
`cap_table[parent_slot].kind == 4` (`KIND_MEMORY`) **and**
`rights & RIGHT_MINT != 0`; (3) `dma_rights_valid(rights)`;
(4) `dma_tail_alloc(tail_word, capacity_bytes, parent_slot)` reserves and
populates a row; (5) `cap_mint_write` writes the descriptor.

`capacity_bytes == 0` is rejected rather than silently accepted: a domain
that may map nothing is indistinguishable from no domain at all, and
admitting it would let a caller mint a cap whose only effect is to consume
a scarce IOMMU context id.

#### Revoke API + cascade

`dma_cap_revoke(slot)` verifies `kind == 0x142`, frees **and scrubs** the
row (zeroing all 32 bytes, which is what clears `in_use`, so no stale
`iommu_ctx_id` / `bdf` survives in the table), then clears the descriptor
to `(0,0,0)`. Idempotent (`DMA_REVOKE_ALREADY`). A non-matching kind is
refused (`DMA_REVOKE_WRONG_KIND`) — one kind's revoke may never clear
another kind's descriptor.

`dma_cascade_revoke_by_parent(parent_slot) -> count` scans
`cap_table[0..255]` for `KIND_DMA_DOMAIN` descriptors whose row records
that `parent_slot`, and revokes each. This is the real cascade edge:
tearing down the memory authority a domain was derived from must not
leave a live IOMMU context entry behind, because a stale context entry is
a device with reach into memory nobody owns any more. R29.M5-003 wires it
into driver-process teardown; until then it is a supervisor entry point
exercised by the boot witness. Cost is O(256) per parent revoke —
identical to the MSI-X cascade.

#### Failure taxonomy (each edge a distinct code)

Return-code block `0xFFFFFFD5..0xFFFFFFDF`, disjoint from `HW_INT_*`
(`0xFFFFFFF7..0xFFFFFFFF`) and `MSIX_*` (`0xFFFFFFE7..0xFFFFFFEF`) so a
witness failure names its originating kind unambiguously.

| Code | Name | Raised when |
|------|------|-------------|
| `0xFFFFFFDF` | `DMA_TAIL_ENOSPC` | no free row |
| `0xFFFFFFDE` | `DMA_TAIL_BAD_ARG` | reserved tail bits set / zero capacity / parent_slot ≥ 256 |
| `0xFFFFFFDD` | `DMA_TAIL_BAD_COHERENCY` | coherency field > 1 |
| `0xFFFFFFDC` | `DMA_MINT_BAD_PARENT` | parent is not `KIND_MEMORY`, or lacks `RIGHT_MINT` |
| `0xFFFFFFDB` | `DMA_MINT_BAD_RIGHTS` | rights not a subset of `R_DMA_ALL` |
| `0xFFFFFFDA` | `DMA_MINT_ENOSPC` | row table exhausted at mint |
| `0xFFFFFFD9` | `DMA_MINT_BAD_ARG` | slot out of range, or bad tail/capacity args |
| `0xFFFFFFD8` | `DMA_MINT_BAD_COHERENCY` | coherency out of range at mint |
| `0xFFFFFFD7` | `DMA_REVOKE_BAD_SLOT` | slot ≥ 256 |
| `0xFFFFFFD6` | `DMA_REVOKE_WRONG_KIND` | descriptor is not `KIND_DMA_DOMAIN` |
| `0xFFFFFFD5` | `DMA_REVOKE_ALREADY` | slot already null (idempotent) |
| `0xFFFFFFFFFFFFFFFF` | `DMA_DECODE_BAD` | encoder/decoder malformed input or dead row |

#### Domain granularity — per-driver-process (D1.b)

One `KIND_DMA_DOMAIN` per driver process, shared across every device the
driver claims — not one per device and not one per firmware image. The
`bus_dev_fn` field records the BDF the domain is *currently bound to*
(the primary function attached via the R29.M5-003 `dma_domain_attach`
path), not an exclusive ownership claim. Minted at driver-process spawn
by the supervisor and delivered via the loader's `_init_caps` sidecar
(`design/loader/init-caps-sidecar.md`); revoked on process exit, which
cascades through `dma_cascade_revoke_by_parent` and tears down every
context entry attributed to it. Full rationale (per-driver-process vs
per-device vs per-firmware-image), the CNVi-shared-domain blast-radius
acknowledgment, and the `dma_domain_attach(domain, bdf)` supervisor entry
point are documented in `design/drivers/blob-policy.md` §2. This rule
governs blob-consuming drivers (Wi-Fi, BT, IPU6, GuC, SOF) and native
drivers uniformly.

#### Boot witness

`kernel_main.pdx §kind_dma_domain_witness` (21 sub-tests, A..U; stage
tracker `_kind_dma_witness_stage`, values 1..40):

- Tail-word encoder round-trip, table-free:
  `dma_tail_pack(0xDEADBEEF, 0x0308, 1) == 0x00010308DEADBEEF`, and each
  field recovered by `dma_tail_word_*`.
- Encoder failure edges: `ctx >= 2^32`, `bdf >= 2^16`, `coherency = 2`.
- Mints a `KIND_MEMORY` parent at slot 24 (`rights = 0x618`), then two
  domains under it — slot 25 `(ctx=0xDEADBEEF, bdf=0x0308,
  capacity=0x40000000, coherency=1)` and slot 26 `(ctx=0x00C0FFEE,
  bdf=0x00F8, capacity=0x1000, coherency=0)`. The tuples differ in every
  field, and coherency takes both legal values, so a decode reading the
  wrong row could not pass.
- Round-trips all five query ops through `cap_invoke_dispatch` on both
  domains (10 dispatch invocations), asserting encode→decode identity for
  all four spec fields plus `parent_slot`.
- Failure edges, each asserting its own distinct code: bad parent kind
  (`parent_slot = 25`, a `KIND_DMA_DOMAIN`); illegal rights
  (`0x004 RIGHT_EXEC`) plus `dma_rights_valid(0x800) == 0`;
  out-of-range coherency via a hand-built tail word (proving the
  allocator re-checks rather than trusting its caller); zero capacity;
  row-table exhaustion (fills rows 2..31 directly, asserts low-first
  allocation, then a real mint reports `ENOSPC`, then releases them).
- Asserts slot 27 — the target of five failed mints — is still null.
- Exercises `OP_DEBUG_PRINT` and `OP_MAP` through dispatch.
- `dma_cascade_revoke_by_parent(24)` returns 2; both descriptors are
  cleared and both rows freed; double-revoke yields `REVOKE_ALREADY` and
  revoking the memory parent through the DMA path yields
  `REVOKE_WRONG_KIND` with the parent descriptor intact.
- Cleans up slot 24 so the cap table is left exactly as found. Emits
  `R29 KIND_DMA_DOMAIN OK`.

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
  constant `DRIVER_LIFECYCLE_TABLE = 0x00000020101A1C12` (widened from
  `0x00000020101A1C02` by R29.M7-001, #1044, which added the
  `Init -> Stopping` abandon edge so the walk to the terminal state is
  total over the state space). Byte `i` holds
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

### `KIND_ACPI_EVENT = 0x151` — landed by R30.M4-003 (#1068) / R30.M4-004 (#1069)

**Status.** **Landed.** `src/kernel/core/cap/kind_acpi_event.pdx`, with the
stream it binds to in `src/kernel/core/acpi/evt_stream.pdx` and the
readiness-gated SCI unmask in `src/kernel/core/acpi/sci_arm.pdx`. Full
design record: `design/kernel/r30-m4-sci-gpe-path.md` §§11–15.

#### Reconciliation with the R30.M2 planning row (resolved at #1068)

This row existed from #1059 as a planning skeleton with a fixed wire
format, specified as `0x21` over `KIND_NOTIFICATION = 12` with rights
`0x408`. Three of those decisions changed at implementation, for one
underlying reason, and the change is recorded here rather than silently
applied — the same treatment `KIND_DMA_DOMAIN` got at #1036.

**The underlying reason: the stream carries TWO sources, not one.** The
planning row was written from the evaluator's side, where the only event
is a firmware `Notify(Object, Value)` landing in the bounded userspace
ring. R30.M4 built the other half and found the second source: a
**General Purpose Event**, asserted by hardware, delivered through the
SCI, masked and queued by the kernel ISR. Those two mean different
things and impose different obligations — the GPE is *masked until the
subscriber acknowledges*, and the acknowledgement is a **write to the GPE
enable register**. A capability spec derived from only one of the two
sources could not gate the other.

| Decision | Planned (#1059) | Landed (#1068) | Why |
|---|---|---|---|
| Tag | `0x21` | `0x151` | `0x21` was chosen for adjacency to `KIND_ACPI = 0x20`. But every derived kind since R29 sits in a per-round block — `0x14x` for R29, `0x15x` opened by `KIND_OP_REGION = 0x150` for R30 — and that block is what a tag dump now groups by. `0x151` keeps R30 contiguous and keeps the low tag space clear for base-slot growth. |
| Base kind | `KIND_NOTIFICATION = 12` | `KIND_HW_INTERRUPT = 0x140` | The endpoint's holder may **acknowledge** a GPE, which re-enables a hardware source. `KIND_NOTIFICATION` cannot gate hardware authority. Deriving over the SCI's own interrupt capability makes the whole of the endpoint's reach strictly downstream of the interrupt whose delivery produces the events — a holder cannot manufacture event reach, or acknowledgement authority, without holding the line it comes from. The planning row's argument *against* `KIND_IPC_ENDPOINT` (5) stands untouched: this is still a one-way subscription with no reply channel. |
| Rights | `R_ACPI_EVENT_ALL = 0x408` | `R_ACPI_EVT_ALL = 0x618` | The planning row's reasoning — *a subscriber must not be able to inject a forged `Notify`, because a forged eject request is an eject the platform never issued* — is **correct and preserved**: there is no inject op on this kind and no op that writes a record into the stream. What it did not anticipate is that acknowledging is not injecting. It is a subscriber telling the kernel it has finished with an event *the kernel itself queued*, and `gpe_ack` refuses any index that is not actually pending. That needs `INVOKE`. `MINT` is admitted as subset-legal for a future per-device sub-endpoint; it grants nothing today because the mint path is kernel-side and is not an op on any capability. (The planning row also transposed two bit values: in this tree `INVOKE = 0x008`, `REVOKE = 0x010`, `MINT = 0x200`, `OBSERVE = 0x400`, so `0x408` was `OBSERVE|INVOKE`, not `OBSERVE|REVOKE`.) |

**The 32-byte wire format from #1059 was not discarded — it moved one
level down.** It described an *event*, and the capability describes a
*subscription*; keeping it as the capability's tail would have meant one
capability row per event. It is now the stream **record** layout in
`evt_stream.pdx` (§12.2 of the milestone doc), widened to 64 B to carry
the source discriminator the second source made necessary. `sequence`
survives as the record's `seq`, `drops_total` as the stream's `drops`
counter, and the localisability argument — *two records whose sequences
differ by more than one bracket the loss, so a subscriber re-enumerates
one bus instead of all of them* — is preserved verbatim and asserted by
the boot witness at stage 53.

#### Derivation gate

`acpi_evt_check_parent_hw_int(parent_slot)`:
`cap_table[parent_slot].kind == 0x140` **and** `rights & RIGHT_MINT`
(`0x200`). Both, not either — the kind says the holder may service the
line, `MINT` says it may hand that authority onward. Same shape as
`msix_check_parent_hw_int` (#1022) and `opregion_check_parent_base`
(#1061).

**The GSI is inherited, never accepted.** `acpi_evt_cap_mint` takes no
GSI argument; it reads the parent's `row_id` from `target_ptr[15:0]` and
asks `hw_int_tail_decode_gsi`. Same discipline `opregion_cap_derive`
applies to the address space: a field identifying *what the parent is*
must come from the parent, or the child's claim decouples from the
authority that was checked.

#### Tail encoding — row indirection via `_acpi_event_table`

8 rows × 32 B. Eight, not 32 or 256: an endpoint is a per-**process**
subscription, and per-GPE fan-out is carried by the `subscriber_id` the
GPE dispatch table already stores per event source, stamped on every
record. Sizing for processes rather than event sources is the whole
reason eight is enough.

```
+0  [7:0]    reserved       must be zero
+0  [15:8]   parent_slot    cap_table slot of the parent KIND_HW_INTERRUPT
+0  [47:16]  gsi            u32, INHERITED from the parent row at mint
+0  [55:48]  reserved       must be zero
+0  [63:56]  in_use         allocator flag (.bss zero-init => free at boot)
+8           subscriber_id  opaque, non-zero
+16          delivered      records accepted for this endpoint, lifetime
+24          acked          successful acknowledgements, lifetime
```

`delivered - acked` is the milestone's most useful single number: platform
events this endpoint was told about and never finished. It is the only
observable that catches a GPE which is masked, dispatched, handled and
never re-enabled — a device that works exactly once and reports no error
anywhere.

`tools/build.sh` asserts via `objdump -r` that `_acpi_event_table` is
relocated against from `kind_acpi_event.o` alone (with a vacuity guard
requiring the owner to reference it), which is what makes "the derivation
gate is the only path to a row" a property of the kernel rather than of
one file. The same assertion covers `_acpi_evt_ring` and
`_acpi_evt_state` in `evt_stream.o`.

#### Rights

`R_ACPI_EVT_ALL = 0x618` — `INVOKE` (0x008) | `REVOKE` (0x010) |
`MINT` (0x200) | `OBSERVE` (0x400). Validated as a **subset**, not an
equality, so a strictly weaker endpoint is expressible: an observe-only
monitor can read its own metadata and cannot acknowledge anything.

#### Ops (`op_arg[7:0]`) and required right

| Op | Code | Right | Returns |
|---|---|---|---|
| `OP_QUERY_GSI`        | 0 | OBSERVE | the inherited GSI |
| `OP_QUERY_PARENT`     | 1 | OBSERVE | parent `cap_table` slot |
| `OP_QUERY_SUBSCRIBER` | 2 | OBSERVE | opaque subscriber identity |
| `OP_QUERY_DELIVERED`  | 3 | OBSERVE | lifetime deliveries |
| `OP_QUERY_ACKED`      | 4 | OBSERVE | lifetime acknowledgements |
| `OP_QUERY_DEPTH`      | 5 | INVOKE  | stream depth |
| `OP_QUERY_DROPS`      | 6 | INVOKE  | stream ring drops |

Per-op gating rather than one entry gate: ops 0–4 read the endpoint's own
metadata, ops 5–6 read the **shared stream**, and a monitor holding only
`OBSERVE` must not learn the platform's event rate from a capability that
entitles it only to introspect itself.

**No `DRAIN` and no `ACK` op**, though both are real operations on this
capability. Draining copies a 64-byte record out, which a three-register
invocation cannot express without taking a destination pointer — and a
destination pointer across that boundary is exactly the aliasing the
`_acpi_evt_ring` confinement assertion exists to prevent. Both go through
`evt_stream.pdx` entries that the bound endpoint authorises.

#### Failure taxonomy — `0xFFFFFF90..0xFFFFFF9F`

Disjoint from every other band in tree (`chaos.pdx` `0xFFFFFFA0..AD`, GPE
path `0xFFFFFFB5..BE`, `KIND_OP_REGION` `0xFFFFFFC5..CF`,
`KIND_DMA_DOMAIN` `0xFFFFFFD5..DF`).

| Code | Name | Raised when |
|---|---|---|
| `0xFFFFFF9F` | `ACPI_EVT_TAIL_ENOSPC` | no free row |
| `0xFFFFFF9E` | `ACPI_EVT_TAIL_BAD_ARG` | reserved header bits set, or zero subscriber |
| `0xFFFFFF9D` | `ACPI_EVT_MINT_BAD_PARENT` | **the derivation gate** — parent is not a live `KIND_HW_INTERRUPT`, or lacks `RIGHT_MINT` |
| `0xFFFFFF9C` | `ACPI_EVT_MINT_BAD_RIGHTS` | rights not a subset of `R_ACPI_EVT_ALL` |
| `0xFFFFFF9B` | `ACPI_EVT_MINT_BAD_ARG` | slot ≥ 256, or a malformed header |
| `0xFFFFFF9A` | `ACPI_EVT_MINT_ENOSPC` | row table exhausted at mint |
| `0xFFFFFF99` | `ACPI_EVT_MINT_BAD_SUBSCRIBER` | subscriber identity is zero |
| `0xFFFFFF98` | `ACPI_EVT_REVOKE_BAD_SLOT` | slot ≥ 256 |
| `0xFFFFFF97` | `ACPI_EVT_REVOKE_WRONG_KIND` | descriptor is not `KIND_ACPI_EVENT` |
| `0xFFFFFF96` | `ACPI_EVT_REVOKE_ALREADY` | slot already null (idempotent) |
| `0xFFFFFF95` | `ACPI_EVT_NOT_READY` | acknowledgement with no endpoint bound |
| `0xFFFFFF94` | `ACPI_EVT_BIND_BAD_CAP` | bind target not a usable live endpoint with `INVOKE` |
| `0xFFFFFF93` | `ACPI_EVT_BIND_ALREADY` | the stream already has a consumer |
| `0xFFFFFF92` | `ACPI_EVT_NOT_BOUND` | unbind with nothing bound |
| `0xFFFFFF91` | `SCI_ARM_NOT_READY` | **unmask attempted before routing was ready** |
| `0xFFFFFF90` | `SCI_ARM_PROGRAM_FAILED` | the redirection entry could not be programmed |
| `0xFFFFFFFFFFFFFFFF` | `ACPI_EVT_DECODE_BAD` | dead row / malformed encoder input |

#### Revoke — no cascade, but it unbinds

Nothing in this tree derives from `KIND_ACPI_EVENT`, so there is no
cascade; an empty cascade call would be a hook that looks maintained and
is not. `acpi_evt_cap_revoke_inner` does call `acpi_evt_unbind_slot(slot)`
**before** freeing the row, so stream readiness falls in the same
operation that frees the endpoint. Revocation therefore *pushes* rather
than being polled, and `acpi_evt_ready()` can stay a latched read instead
of a descriptor re-validation — which would have forced the `{cap}`
capability up the entire SCI arming path.

#### Producer-side contract, unchanged from #1059

`src/user/aml/aml_ctl.pdx`, and `design/acpi/aml-evaluator.md` §18:
ring depth **32**, 32 B entries, `.bss`, never grown; **tail-drop**; a
drop is not an error; one step of interpreter fuel on both paths;
observability `{offered, drained, depth, drops}` plus the per-entry
sequence, invariant `offered == drained + depth + drops`.

The kernel-side stream reuses that discipline exactly, with **one extra
term** for the failure mode the userspace ring does not have — no
subscriber to route to:

```
offered == drained + depth + drops + unrouted
```

`drops` (the ring was full: the subscriber is alive but behind) and
`unrouted` (there was nobody to route to) are kept separate because they
are different problems with different fixes, and one number would make a
wedged subscriber and an absent one indistinguishable.

#### Boot witness

`tests/kernel/acpi/evt_route_synth.pdx` §`evt_route_witness`, sub-tests
A..G, fingerprint **`R30 ACPI EVENT ROUTE OK`**. Writes no IOAPIC
register: both arming calls resolve to GSI 0, which `sci_route_program`
refuses before any MMIO, so the readiness gate is exercised in *both*
directions without reprogramming the platform's interrupt controller
during boot. Stage table in `design/kernel/r30-m4-sci-gpe-path.md` §15.

#### Downstream consumers

R31 (thermal zone handling), R32 (EC query events), R33 (audio jack
detection), R35 (Thunderbolt hotplug).

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

## `KIND_OP_REGION` — landed by R30.M3-001 (#1061)

**Runtime base kind.** *Both* `KIND_MEMORY` (= `KIND_PAGE`, slot 4) and
`KIND_IO_PORT` (slot 11). This is the first derived kind in the catalog
whose base slot is **not a constant**, and the reason is stated below.

**Derived-kind tag.** `0x150` (decimal 336) — opens the R30 block. The
R29 block (`0x140` interrupt, `0x141` msix, `0x142` dma domain, `0x143`
timeline reserved) is left contiguous and untouched.

### Why this kind is the security boundary of R30

Every kind above it in this catalog authorises something the kernel
already mediates: a vector, an IOMMU context, a log ring. This one
authorises **touching a physical address named by a firmware table**.
ACPI tables are vendor-supplied, unsigned, and rewritable by anyone with
a flash programmer. `OperationRegion(FOO, SystemMemory, <addr>, <len>)`
places no constraint whatsoever on `<addr>`: it may name kernel text,
the page tables, a driver's bus-master buffer, or the ACPI supervisor's
own object arena.

Per `design/roadmap/next-wave-softarch.md` §3 R30 the design intent is
that *the OperationRegion abstraction becomes a cap, and no other
component of the system can silently poke a hardware address*. This kind
is that cap.

The invariant, and it is one sentence: **a window may be opened only
inside a window the caller already holds, and every access derives from
the held window's own recorded base and length — never from the address
the table asked for.**

### The derivation asymmetry

The address space decides which base kind the mint gate demands:

| Space | Keyword | Class | Required parent |
|-------|---------|-------|-----------------|
| `0x00` | SystemMemory | memory-like | `KIND_MEMORY` (4) |
| `0x01` | SystemIO | port-like | `KIND_IO_PORT` (11) |
| `0x02` | PCI_Config | memory-like | `KIND_MEMORY` (4) |
| `0x03` | EmbeddedControl | port-like | `KIND_IO_PORT` (11) |
| `0x05` | SystemCMOS | port-like | `KIND_IO_PORT` (11) |
| `0x06` | PciBarTarget | memory-like | `KIND_MEMORY` (4) |
| `0x0A` | PCC | memory-like | `KIND_MEMORY` (4) |
| `0x04` / `0x07` / `0x08` / `0x09` | SMBus / IPMI / GPIO / GenericSerialBus | **bus** | refused |

The reasoning is R29.M5-001's (#1036), one lattice over. A memory-space
window must derive over `KIND_MEMORY`, because deriving it over port
authority — or anything weaker — would let a holder of the lesser
authority *manufacture memory reach*. The converse holds symmetrically.
`opregion_space_base_kind` is the single table that decides, and the
mint gate consults it rather than accepting whichever parent the caller
presented.

PCI_Config is classed memory-like because this platform reaches
configuration space through the R22 ECAM aperture — an MMIO window — not
through the `0xCF8`/`0xCFC` port pair. Classing it port-like would make
the gate demand the wrong authority and make R30.M3-004's containment
check meaningless.

The four **bus** spaces are refused with `OPREG_MINT_BAD_SPACE`. Their
accesses are serial-bus transactions, not loads and stores; they have
their own capabilities in this round's catalog (`KIND_I2C_BUS`,
`KIND_I2C_SLAVE`, `KIND_GPIO_LINE`). Admitting them would force this
kind to carry a `{base, len}` pair that means nothing for them and a
containment check over a coordinate that is not an address.

Because one derived tag serves two base slots, the LAM kind-hint cannot
be a constant for this kind — which is exactly why `cap_invoke_dispatch`
compares the full `u64` kind field (`0x150`) rather than the 4-bit slot,
as it already does for every derived kind.

### Tail encoding — row indirection

`{space:u8, base:u64, len:u64, parent_slot:u8, parent_row:u16,
is_root:u1}` = 155 live bits, which does not fit the descriptor's 64-bit
`target_ptr`. As with `KIND_HW_INTERRUPT` / `KIND_HW_MSIX_VECTOR` /
`KIND_DMA_DOMAIN`, `target_ptr` carries `row_id` in bits `[15:0]` (bits
`[63:16]` must be zero) and the payload lives in a kernel-private table.

Row — `_op_region_table[row_id]`, 32 bytes:

| Offset | Bits | Field |
|--------|------|-------|
| `[+0]` | `[7:0]` | `space` |
| | `[15:8]` | `parent_slot` — the cap slot this row derived from |
| | `[16]` | `is_root` (1 = platform window, 0 = derived sub-window) |
| | `[23:17]` | reserved (must be zero) |
| | `[39:24]` | `parent_row` (`0xFFFF` for a root) |
| | `[55:40]` | reserved (must be zero) |
| | `[63:56]` | `in_use` |
| `[+8]` | u64 | `base` — physical address, or port number |
| `[+16]` | u64 | `len` — **bytes**; zero is refused at allocation |
| `[+24]` | u64 | reserved — R30.M4 access accounting |

`parent_slot` is one field for both lineages because the cascade walk
asks one question: *whose child is this?*

`opregion_tail_pack(space, parent_slot, is_root, parent_row)` is the
canonical encoder. It enforces the cross-field rule that `is_root == 1`
**requires** `parent_row == 0xFFFF`: a root row that also carried a
plausible `parent_row` would be revoked twice by the cascade, and the
second revoke would report `WRONG_KIND` against a descriptor another
mint had meanwhile reused. Making the combination unrepresentable is
cheaper than detecting it.

### Rights

| Right | Value | Authorises |
|-------|-------|------------|
| `R_OPREG_READ` | `0x001` | the window may be read |
| `R_OPREG_WRITE` | `0x002` | the window may be written |
| `R_OPREG_INVOKE` | `0x008` | the query ops |
| `R_OPREG_REVOKE` | `0x010` | supervisor teardown |
| `R_OPREG_MINT` | `0x200` | **derive** a sub-window |
| `R_OPREG_OBSERVE` | `0x400` | the canonical debug printer |
| `R_OPREG_ALL` | `0x61B` | the union |

READ and WRITE are separate — unlike `KIND_DMA_DOMAIN`, which folds
both into INVOKE — because a **read-only window** is a shape this round
needs: a thermal or battery region the supervisor may sample but must
never poke. Folding them would make that unexpressible and would mean
every region handed out for a query also carried the authority to write
hardware.

**Derive is monotone in rights as well as in extent:**
`(child_rights & parent_rights) == child_rights`. Without it the
containment check would hold on *addresses* while leaking authority on
*operations* — a read-only 4 KiB window could derive a writable 4 KiB
window inside itself.

### Acquisition — why "forgot to check the cap" is not expressible

`_op_region_table` has exactly **one writer**, `opregion_tail_alloc`,
with exactly **two callers**:

1. **Root** — `opregion_cap_mint_root(slot, parent_slot, rights, space,
   base, len)`. Demands a parent of the base kind the *space* requires,
   carrying `RIGHT_MINT`. Root windows encode **platform** knowledge (the
   firmware memory map, the ECAM aperture, the EC port pair) and are
   established by kernel-side boot code. It is deliberately **not an op
   on any capability**, so nothing holding only a `KIND_OP_REGION` can
   reach it — and therefore nothing a firmware table drives can widen its
   own reach.
2. **Derive** — `opregion_cap_derive(child_slot, parent_slot, rights,
   base, len)`. The path a firmware-declared region takes. Requires a
   live parent `KIND_OP_REGION` with `RIGHT_MINT`, checks rights
   monotonicity, and **containment-checks** `[base, base+len)` against
   the parent row's own extent. It takes **no space argument** — the
   space is inherited from the parent row, so a caller cannot relabel a
   memory window as an I/O window and route its accesses through a
   handler that reads a different namespace.

`tools/build.sh` asserts with `objdump -r` that `_op_region_table` is
relocated against from `kind_op_region.o` and **no other kernel object**.
That assertion is what upgrades "the containment check is the only path
to a row" from a claim about one file to a property of the whole kernel.
It lives in the build rather than in the pre-push hook so it runs on
every build, including inside the smoke matrix.

### Refusal, never truncation

An uncovered request returns `OPREG_MINT_NO_COVER` (`0xFFFFFFC5`) and
allocates nothing. It is **not** clipped to the permitted subrange.

This is the choice an implementation gets wrong by being helpful. Silent
truncation turns the capability system into an **oracle**: a table
declares a 4 GiB region, observes that accesses succeed up to offset *N*
and fail past it, and has thereby measured exactly how much of the
address space the supervisor holds — without ever being refused
anything. Refusal leaks one bit ("no"); truncation leaks the boundary.

### Containment is overflow-safe

`opregion_range_contains(o_base, o_len, i_base, i_len)` never adds two
caller-supplied 64-bit values, because `i_base + i_len` is precisely the
expression a firmware table controls both operands of. The naive
`i_base + i_len <= o_base + o_len` wraps for `i_base = 2^64-1,
i_len = 2` and reports **contained** for a window that starts at the top
of the address space and runs off the end of it. The gates are ordered
so both subtractions are proven non-underflowing before they are taken.
The same predicate, independently implemented, guards the userspace
handler (`aml_region_contains`) — the two live on opposite sides of a
privilege boundary and neither may depend on the other having run.

### Ops

| Op | Code | Right |
|----|------|-------|
| `QUERY_SPACE` | 0 | INVOKE |
| `QUERY_BASE` | 1 | INVOKE |
| `QUERY_LEN` | 2 | INVOKE |
| `QUERY_PARENT` | 3 | INVOKE |
| `QUERY_ROOT` | 4 | INVOKE |
| `DEBUG_PRINT` | 5 | OBSERVE |

There is deliberately **no access op**. Reading or writing a window is
not a three-register capability invocation — it needs a mapping, a width
and a direction — and it belongs to the userspace address-space handler
(#1062) acting on a mapping derived from this capability. A
poke-this-address op would recreate, one layer up, exactly the property
this kind exists to remove.

### Revoke + transitive cascade

`opregion_cap_revoke(slot)` verifies `kind == 0x150`, frees **and
scrubs** the row, and clears the descriptor. Scrubbing matters more here
than for any other kind: a stale row is a recorded permission to touch a
physical address.

`opregion_cascade_revoke_by_parent(parent_slot) -> count` is
**transitive**, which is the one place this cascade differs from
`KIND_DMA_DOMAIN`'s. A window may be derived from a window, so revoking
a root must reach its grandchildren; a surviving grandchild is a live
handle to an address whose only justification has been destroyed. It is
implemented as a **fixed-point loop** — repeat the full scan until a pass
revokes nothing — rather than as recursion, because recursion would put
an unbounded-depth call chain on a teardown path, which is exactly the
shape a hostile derivation chain would exploit. Termination: every
continuing pass frees at least one of `OPREG_MAX` rows, so at most
`OPREG_MAX + 1` passes run.

The closure falls out of the table state rather than a worklist: a row
whose recorded `parent_slot` no longer holds a `KIND_OP_REGION` is an
orphan and goes with its parent. Root rows are exempt from the orphan
test — their `parent_slot` legitimately names a `KIND_MEMORY` /
`KIND_IO_PORT` descriptor — and go only by direct match.

### Failure taxonomy

Block `0xFFFFFFC2..0xFFFFFFCF`, disjoint from `DMA_*`
(`0xFFFFFFD5..0xFFFFFFDF`), `MSIX_*` and `HW_INT_*`.

| Code | Name | Meaning |
|------|------|---------|
| `0xFFFFFFCF` | `OPREG_TAIL_ENOSPC` | no free row |
| `0xFFFFFFCE` | `OPREG_TAIL_BAD_ARG` | reserved bits set, or zero length |
| `0xFFFFFFCD` | `OPREG_TAIL_BAD_SPACE` | space not admitted |
| `0xFFFFFFCC` | `OPREG_TAIL_BAD_RANGE` | `base + len` wraps |
| `0xFFFFFFCB` | `OPREG_MINT_BAD_PARENT` | wrong parent kind, or no `RIGHT_MINT` |
| `0xFFFFFFCA` | `OPREG_MINT_BAD_RIGHTS` | not a subset of the parent's, or of `R_OPREG_ALL` |
| `0xFFFFFFC9` | `OPREG_MINT_ENOSPC` | row table full |
| `0xFFFFFFC8` | `OPREG_MINT_BAD_ARG` | slot out of range, or malformed header |
| `0xFFFFFFC7` | `OPREG_MINT_BAD_SPACE` | bus space, or unknown keyword |
| `0xFFFFFFC6` | `OPREG_MINT_BAD_RANGE` | `base + len` wraps |
| **`0xFFFFFFC5`** | **`OPREG_MINT_NO_COVER`** | **no held capability covers the range** |
| `0xFFFFFFC4` | `OPREG_REVOKE_BAD_SLOT` | slot out of range |
| `0xFFFFFFC3` | `OPREG_REVOKE_WRONG_KIND` | descriptor is not `KIND_OP_REGION` |
| `0xFFFFFFC2` | `OPREG_REVOKE_ALREADY` | already null (idempotent) |

### Table sizing

`OPREG_MAX = 32` rows × 32 B = 1024 B `.bss`, align 64. A real DSDT
declares on the order of a dozen `OperationRegion`s; 32 covers the
platform roots plus that with room.

### Boot witness

`kernel_main.pdx §kind_op_region_witness`, 24 sub-tests — fingerprint
`R30 KIND_OP_REGION OK`. It asserts both directions of the derivation
asymmetry, the overflow case of the containment predicate, the
`NO_COVER` refusal *and* that the refused slot stayed null, the per-op
rights gate, and the transitive cascade.

**Slot ordering in the witness is part of the fixture.** The window
chain is root=33 → child=32 → grandchild=30, i.e. **descending**, while
the cascade walks the cap table **ascending**. One pass therefore reaches
only the root. Laid out the other way round, a single-pass cascade would
happen to finish in one sweep and the fixed-point loop would be untested
while looking tested — mutation confirmed exactly that, and the layout
was changed in response.

### Naming note for the rest of R30 — resolved by #1569

The R30 catalog originally listed this arbitration capability as
`KIND_AML_SESSION`. **That name cannot be spelled kernel-side**:
`tools/lint-no-kernel-aml.sh` forbids any identifier beginning `aml`
under `src/kernel/**` (`design/acpi/no-aml-in-kernel.md` §3),
capabilities live in `src/kernel/core/cap/`, and the guardrail is not
negotiable — it is what keeps a bytecode interpreter out of ring 0.

**#1569 renamed it to `KIND_FW_SESSION` across the catalog before any
code was written against the old name**, and was filed deliberately
ahead of the issue that introduces the kind so that this iteration
starts from the right identifier rather than discovering the collision
at push time. The alternative — an allowlist entry carving out one
identifier — was rejected on principle: a constitutional boundary with
one exception is a boundary with a precedent for exceptions, and the
next one is argued from this one rather than from the rationale.

The rename is not merely a workaround. `KIND_FW_SESSION` is the more
accurate name: the capability arbitrates evaluation *sessions* against
**firmware-supplied** objects, and nothing about the arbitration is
specific to the AML bytecode language. The lint pushed the catalog
toward a better name, which is the behaviour one wants from a
guardrail placed at a real boundary.

The kind itself is specified below, landed by R30.M8-003 (#1083).

---

## `KIND_I2C_BUS = 0x152` / `KIND_I2C_SLAVE = 0x153` — landed by R30.M5-001 (#1070) / R30.M5-002 (#1071)

### Catalog reconciliation

There was **no planning row** for either kind. The R30 catalog named
`KIND_I2C_BUS` and `KIND_I2C_SLAVE` only in prose — in the
`KIND_OP_REGION` section's explanation of why the four *bus* address
spaces (`0x04` SMBus, `0x07` IPMI, `0x08` GeneralPurposeIO, `0x09`
GenericSerialBus) are refused there. No tag, no base, no tail, no rights
were ever fixed, so unlike `KIND_ACPI_EVENT` (#1068) there was nothing
to re-base and nothing to contradict. The sections below are the first
specification of either kind.

The `KIND_OP_REGION` prose stands unchanged and is now discharged: those
four spaces are bus spaces whose accesses are serial-bus *transactions*
rather than loads and stores, and the transaction authority for I²C is
`KIND_I2C_SLAVE`, not a `{base, len}` window.

### Why two kinds and not one

**I²C is a shared bus.** Every peripheral hangs off the same two wires
and the controller can address any of them. A component holding "the I²C
controller" therefore holds *every device on it*: the touchpad driver
could talk to the fingerprint reader, the sensor hub, or whatever else
the board designer found a free address for.

So per-device isolation on I²C is not a property of the hardware. It
does not exist unless the capability system manufactures it, and one
capability per *controller* cannot manufacture it. Hence the split:

| | holder | authorises |
|---|---|---|
| `KIND_I2C_BUS` | a **controller** driver | reading the bus's own properties; **minting slaves under it**. Nothing on the wire. |
| `KIND_I2C_SLAVE` | a **device** driver | exactly one address on exactly one bus. |

**The bus capability is deliberately non-transacting** — no read op, no
write op, and `RIGHT_READ` / `RIGHT_WRITE` are outside
`R_I2C_BUS_ALL` so no future op can quietly consume them. If the bus
could transact, the slave capability would be an optional courtesy and
per-device isolation would be decorative.

### Derivation

```
KIND_DEVICE (base slot 10)          R22's PCI device authority
      └── KIND_I2C_BUS   0x152      + RIGHT_MINT on the parent
            └── KIND_I2C_SLAVE 0x153  + RIGHT_MINT on the parent
```

`KIND_I2C_SLAVE` is a **leaf**: `R_I2C_SLAVE_ALL` deliberately excludes
`RIGHT_MINT`, so the lattice bottoms out and the cascade needs no fixed
point (contrast `KIND_OP_REGION`, where a window may derive a window).

**Which device tag.** R22 spells the PCI device authority two ways: base
slot `KIND_DEVICE = 10`, which real descriptors carry and `invoke.pdx`
routes; and derived tag `KIND_PCI_DEV = 0x30`, whose mint path
`device_cap_mint` is still R22-M3 scaffolding that **writes no
descriptor**. Gating on `0x30` would be a *vacuous* gate — it would
refuse nothing because nothing could satisfy it either. The gate uses
slot 10, matching `opregion_check_parent_base`'s use of slots 4 and 11,
and the boot witness both satisfies it and is refused by it.

### Controller identity is inherited, never argued

`i2c_bus_cap_mint(slot, parent_slot, rights, max_speed_hz)` has **no
controller argument**. The row's `controller_id` is the parent
`KIND_DEVICE` descriptor's own `target_ptr` (the `bdf_pack` key),
read out of the descriptor the gate just checked.

This is #1068's discipline (the GSI inherited from the parent
`KIND_HW_INTERRUPT` row) applied to identity. If the caller supplied it,
a holder of device A's capability could mint a bus claiming to be device
B's controller, and every audit record and every dump would be reporting
a claim rather than a checked fact.

`max_speed_hz` *is* an argument — it is a board property, not a
controller property — but its domain is closed to the four rates the
spec defines (100 k / 400 k / 1 M / 3.4 M). An unvalidated rate becomes
an unvalidated clock divider in #1072, and the failure mode of a wrong
divider is not a refusal but a bus that transacts and corrupts.

### Address confinement — the property, and how it is made structural

> A capability naming address A cannot be used to address B, and
> "address B instead" is not a request that can be **phrased**.

Three mechanisms, none of which is a check that could be forgotten:

1. **The resolvers take no address.** `i2c_slave_addr_of_slot(slot)` and
   `i2c_slave_row_addr(row_id)` are arity-one. There is no parameter for
   a caller-supplied address, so the transfer path #1073 builds on them
   physically cannot be handed one.
2. **No op takes an operand.** `cap_handler_i2c_slave` masks `op_arg` to
   its low byte before any dispatch decision, discarding the 56 bits a
   caller might hide an address in. `QUERY_ADDR` is introspection — a
   holder learning which device it owns — not addressing.
3. **`tools/build.sh` pins it.** The `i2c-addr-confine` step asserts the
   two literal signature lines, so a mutant that adds an `addr`
   parameter fails the *build*, not the review. The runtime half is
   sub-test O of the witness, which calls both resolvers with a
   neighbouring device's address loaded into every register such a
   parameter would arrive in.

The address *is* an argument at **mint**, and only there. Mint is the
authorising moment: gated on the bus capability with `RIGHT_MINT`, it is
where the platform decides which driver owns which device. Afterwards
the row is the sole source of truth.

### Address validity — refused per range, with distinct codes

7-bit mode (`I2C_ADDR_MODE_7BIT = 0`) admits **0x08..0x77** only:

| range | meaning | code |
|---|---|---|
| `0x00..0x07` | general call, CBUS, other-bus-format, future, Hs-mode master codes | `I2C_SLAVE_MINT_ADDR_RESERVED_LOW` `0xFFFFFF77` |
| `0x08..0x77` | **usable** | — |
| `0x78..0x7B` | **10-bit addressing prefix (11110xx)** | `I2C_SLAVE_MINT_ADDR_RESERVED_HIGH` `0xFFFFFF76` |
| `0x7C..0x7F` | reserved / device ID | `I2C_SLAVE_MINT_ADDR_RESERVED_HIGH` |
| `> 0x7F` | not a 7-bit address | `I2C_SLAVE_MINT_ADDR_RANGE` `0xFFFFFF78` |

The high range is confinement-critical, not spec pedantry: a 7-bit
capability minted at `0x78` would put the controller into 10-bit
framing, letting a capability that names *one* address reach a
256-address space.

10-bit mode (`= 1`) admits **0x000..0x3FF** entirely — the prefix
distinguishes the framing on the wire, so no 10-bit address collides
with a 7-bit device address. Any other mode →
`I2C_SLAVE_MINT_BAD_MODE 0xFFFFFF79`.

Three codes rather than one because the ends fail for different reasons
and an operator debugging a bad ACPI `_CRS` needs to know which.
**Refusal, never masking** — the `KIND_OP_REGION` argument again: a
driver silently moved from `0x00` to `0x40` would be talking to a device
it does not own, and the first symptom would surface in the *other*
driver.

### Address collision — the second mint is REFUSED

Key: **`(parent_row, mode, addr)`** → `I2C_SLAVE_MINT_ADDR_IN_USE`
(`0xFFFFFF75`).

*Why refuse rather than share.* An I²C peripheral is not a stateless
register file; the near-universal access pattern is "write the register
pointer, then read" — two transactions with device-side state between
them. Two independent owners interleaving those sequences do not get an
error, they get each other's data, silently, and no protocol-level
mechanism lets either notice. A device that genuinely must be shared
needs an **arbiter** — one holder that serialises access and exposes its
own interface — and an arbiter is a thing you *build*, not a thing you
get by minting the capability twice. Permitting the second mint would
make the broken configuration the easy one.

*Why the key is scoped to the bus.* 0x1A on the touchpad's controller
and 0x1A on the sensor hub are two devices on two pairs of wires. A
global address table would reject the second — not a conservative
failure, but one that makes an ordinary board unbootable. The witness
asserts this direction explicitly (sub-test M).

*Why mode is in the key.* 7-bit `0x1A` and 10-bit `0x01A` are different
byte sequences on the wire and may legitimately coexist (sub-test N).

### Tail encoding — row indirection

Both kinds use the family's row indirection: `target_ptr` holds
`row_id` in bits [15:0] and the payload lives in a kernel-owned private
table.

`_i2c_bus_table[row_id]`, 8 rows × 32 B:

| off | field |
|---|---|
| `+0` | `[7:0]` parent_slot · `[55:8]` reserved · `[63:56]` in_use |
| `+8` | `controller_id` — the parent `KIND_DEVICE`'s `target_ptr`. **Inherited.** Zero refused. |
| `+16` | `max_speed_hz` — one of the four validated rates |
| `+24` | `num_slaves` — live derived-slave count |

`_i2c_slave_table[row_id]`, 32 rows × 32 B:

| off | field |
|---|---|
| `+0` | `[7:0]` parent_slot · `[23:8]` **parent_row** · `[39:24]` addr · `[47:40]` mode · `[55:48]` reserved · `[63:56]` in_use |
| `+8` | `driver_hint` — opaque owner identity, non-zero (zero is the "unclaimed" sentinel) |
| `+16` / `+24` | reserved — #1073 transfer counters |

`parent_row` rather than `parent_slot` is the **cascade and uniqueness
key**: a cap slot can later hold a different bus, a live row_id cannot.

`num_slaves` has exactly **two mutators**,
`i2c_bus_note_slave_added` / `_removed`, exported across the object
boundary precisely because `tools/build.sh` forbids `kind_i2c_slave.o`
from touching `_i2c_bus_table`.

### Rights

| | bits | value |
|---|---|---|
| `R_I2C_BUS_ALL` | INVOKE \| REVOKE \| MINT \| OBSERVE | `0x618` |
| `R_I2C_SLAVE_ALL` | READ \| WRITE \| INVOKE \| REVOKE \| OBSERVE | `0x41B` |

Bus has **no READ/WRITE** (it authorises no transaction). Slave has
**no MINT** (it is a leaf). Slave's READ/WRITE are reserved though
nothing consumes them yet: reserving now means a capability minted today
with `0x418` will still be *refused* a transfer when #1073 lands, rather
than silently acquiring transfer authority on the day the op appears.

### Revoke + cascade

`i2c_bus_cap_revoke(slot)` **cascades first**, then frees its own row.
`i2c_slave_cascade_revoke_by_bus_row(bus_row)` has two phases:

* **Phase 1, by descriptor** — every `cap_table` slot holding a
  `KIND_I2C_SLAVE` whose row records this bus row.
* **Phase 2, by row** — every live row recording this bus row even if no
  descriptor points at it. This is what makes "no row leak" *structural*:
  a stranded row still occupies an address on a bus that no longer
  exists, so the next legitimate mint at that address would be refused
  `ADDR_IN_USE` **by a ghost**.

After the cascade a non-zero `num_slaves` is reported
(`I2C_BUS_REVOKE_SLAVES_LIVE 0xFFFFFF84`) but does **not** abort the
teardown: a revoke that refuses to finish would leave the bus alive,
which is strictly worse than a completed teardown with a named anomaly
in the audit record.

Free is **scrub** in both kinds. For slaves that matters specifically
because the address is the uniqueness key — an unscrubbed freed row is
the ghost above.

### What a slave capability does NOT yet permit

Holding a `KIND_I2C_SLAVE` today permits reading back its own address,
mode, parent bus and driver hint (`INVOKE`), the canonical dump
(`OBSERVE`), and being revoked. It does **not** permit, and no code
would honour:

* any transaction on the wire — no read, write, combined write-then-read
  or SMBus block transfer. **R30.M5-004 (#1073)** defines the transfer
  channel;
* bringing the controller up, programming its divider, or touching any
  controller register — those live behind the parent `KIND_DEVICE`'s
  BARs, which **R30.M5-003 (#1072)** maps;
* deriving anything (leaf kind, no `RIGHT_MINT`);
* any bus-level operation. A slave holder cannot even count its
  siblings.

### Failure taxonomy

`KIND_I2C_BUS` occupies `0xFFFFFF83..0xFFFFFF8F`; `KIND_I2C_SLAVE`
occupies `0xFFFFFF70..0xFFFFFF7F` (sixteen codes, the exact width of the
band). Both are disjoint from `ACPI_EVT_*` `0xFFFFFF90..9F`,
`DRV_RESTART_*` `0xFFFFFFB5..BE`, `OPREG_*` `0xFFFFFFC2..CF`, `DMA_*`
`0xFFFFFFD5..DF`, `MSIX_*` `0xFFFFFFE7..EF` and `HW_INT_*`
`0xFFFFFFF7..FF` — and from **each other**, which matters more here than
usual because the two kinds refuse for structurally similar reasons and
a shared band would make "which of the two refused" a guess.

| code | name |
|---|---|
| `0xFFFFFF8F` | `I2C_BUS_TAIL_ENOSPC` |
| `0xFFFFFF8E` | `I2C_BUS_TAIL_BAD_ARG` |
| `0xFFFFFF8D` | `I2C_BUS_MINT_BAD_PARENT` |
| `0xFFFFFF8C` | `I2C_BUS_MINT_BAD_RIGHTS` |
| `0xFFFFFF8B` | `I2C_BUS_MINT_BAD_ARG` |
| `0xFFFFFF8A` | `I2C_BUS_MINT_ENOSPC` |
| `0xFFFFFF89` | `I2C_BUS_MINT_BAD_SPEED` |
| `0xFFFFFF88` | `I2C_BUS_MINT_BAD_CONTROLLER` |
| `0xFFFFFF87` | `I2C_BUS_REVOKE_BAD_SLOT` |
| `0xFFFFFF86` | `I2C_BUS_REVOKE_WRONG_KIND` |
| `0xFFFFFF85` | `I2C_BUS_REVOKE_ALREADY` |
| `0xFFFFFF84` | `I2C_BUS_REVOKE_SLAVES_LIVE` |
| `0xFFFFFF83` | `I2C_BUS_COUNT_BAD_ROW` |
| `0xFFFFFF7F` | `I2C_SLAVE_TAIL_ENOSPC` |
| `0xFFFFFF7E` | `I2C_SLAVE_TAIL_BAD_ARG` |
| `0xFFFFFF7D` | `I2C_SLAVE_MINT_BAD_PARENT` |
| `0xFFFFFF7C` | `I2C_SLAVE_MINT_BAD_RIGHTS` |
| `0xFFFFFF7B` | `I2C_SLAVE_MINT_BAD_ARG` |
| `0xFFFFFF7A` | `I2C_SLAVE_MINT_ENOSPC` |
| `0xFFFFFF79` | `I2C_SLAVE_MINT_BAD_MODE` |
| `0xFFFFFF78` | `I2C_SLAVE_MINT_ADDR_RANGE` |
| `0xFFFFFF77` | `I2C_SLAVE_MINT_ADDR_RESERVED_LOW` |
| `0xFFFFFF76` | `I2C_SLAVE_MINT_ADDR_RESERVED_HIGH` |
| `0xFFFFFF75` | `I2C_SLAVE_MINT_ADDR_IN_USE` |
| `0xFFFFFF74` | `I2C_SLAVE_MINT_BAD_HINT` |
| `0xFFFFFF73` | `I2C_SLAVE_REVOKE_BAD_SLOT` |
| `0xFFFFFF72` | `I2C_SLAVE_REVOKE_WRONG_KIND` |
| `0xFFFFFF71` | `I2C_SLAVE_REVOKE_ALREADY` |
| `0xFFFFFF70` | `I2C_SLAVE_BUS_LOST` |

### Boot witness

`tests/kernel/cap/i2c_cap_synth.pdx §i2c_cap_witness`, sub-tests A..T
(twenty stages) — fingerprint **`R30 KIND_I2C OK`**. Cap slots 34..45,
disjoint from every other witness's set; both exits clear them and reset
both row tables.

Sub-test **O** is the runtime mutant: it calls `i2c_slave_addr_of_slot`
and the dispatch handler with a *neighbouring device's* address loaded
into `rsi`/`rdx`/`rcx`/`r8`/`r9` and packed into the upper 56 bits of
`op_arg`, and asserts the answer is still the capability's own address in
every case.

---

## `KIND_GPIO_LINE = 0x154` — landed by R30.M6-001 (#1075)

### Catalog reconciliation

There was **no planning row**. The R30 catalog named `KIND_GPIO_LINE`
only in the round summary's "new capabilities" list, with the deliverable
line "kind + tail {controller_id, pin, direction, pull}". No tag, no
base, no rights and no gate were ever fixed, so — as with the I²C pair —
there was nothing to re-base and nothing to contradict. The section below
is the first specification of the kind.

The planning line's four tail fields all survive, in a different shape:
`controller_id` is a `bdf_pack` key inherited from the parent, `pin` is
the absolute pin number, and `direction` / `pull` are the reserved bits
`[55:48]` of the header word that R30.M6-004 (#1078) populates. Two
fields the planning line did not anticipate are added, and they are the
substance of the milestone: **`community` and `pad_index`**, derived at
mint, because on this hardware the pin number is not the pad index.

### Why this kind is more dangerous than `KIND_I2C_SLAVE`

Same structural problem — one component must own one endpoint on a
fabric that has no protection domain — with a categorically different
failure mode.

Addressing the wrong device on I²C produces a **data error**: the wrong
peripheral answers, or none does, and something downstream notices.
Acting on the wrong pin produces a **physical state change with no error
path at all**. A pad controller owns every pin on the package: device
reset asserts, power-rail enables, write-protect straps, firmware-flash
control. There is no NACK, no arbitration loss, no status bit that says
"that was the wrong pin". The pin becomes whatever the last writer made
it, and the first symptom appears in whatever hardware the pin controls.

Two consequences run through the whole design:

* **nothing is clamped.** Every out-of-range or unmapped input is
  refused, because clamping picks *some* pin.
* **every field that selects a pad is confined**, not just the pin.

### Derivation — over `KIND_DEVICE`, in two halves

The gate demands `kind == KIND_DEVICE (10)` carrying `RIGHT_MINT`, and
then demands something the kind check cannot express: **the device must
be a probed, identified pad controller**.

The controller identity is read from the parent descriptor's
`target_ptr` — inherited, never argued, the discipline
`i2c_bus_parent_controller_id` established — and looked up in
`_lpss_gpio_ctrl` via `lpss_gpio_resolve_pin`. A `KIND_DEVICE`
capability for the network card passes the kind check and is refused
`GPIO_LINE_MINT_NO_CONTROLLER`.

That second half is what makes the gate mean anything. A pad controller
is not distinguishable from any other PCI function by capability kind,
so a gate that only checked the kind would let any device-capability
holder mint pins — except that it cannot *name* the controller, because
the identity is inherited. The lookup is the check that the inheritance
landed on a pad controller.

Unlike `KIND_I2C_SLAVE`, the parent is a **base slot** rather than a
derived tag. There is no intermediate "the pads are configured"
authority to derive over the way `KIND_I2C_BUS` proves a controller was
brought up at a validated rate; the machine-side lookup stands in for
it, and stating that honestly is better than inventing a ceremonial
intermediate kind.

### The community mapping — derived, never supplied

`gpio_line_cap_mint(slot, parent_slot, rights, pin, driver_hint)` takes
a **pin** and nothing else about location. The community and the
community-relative pad index are computed once, at mint, and stored.

```
community  = the c with c.pin_base <= pin < c.pin_base + c.npins
pad_index  = pin - c.pin_base
reg offset = c.reg_off + c.padbar + pad_index * stride
```

For the first community `pin_base` is 0 and `pad_index == pin`. **The
mapping is the identity there and nowhere else.** A driver that skips
the subtraction is correct on every pin of community 0 and drives the
wrong pin on every pin of every other community, silently.

Making the caller supply the community would put that arithmetic — whose
failure mode is "a different pin than intended, with no error" — in
every caller. Deriving it once, from the one table that knows the
geometry, removes the class of bug rather than relocating it. See
`design/drivers/lpss-gpio-controller.md` §2.

### Pin validity — refused per reason, never clamped

| condition | code |
|---|---|
| `pin >= GPIO_PIN_MAX (512)` | `GPIO_LINE_MINT_PIN_RANGE` |
| no community of this controller covers it | `GPIO_LINE_MINT_PIN_UNMAPPED` |
| the parent names no probed pad controller | `GPIO_LINE_MINT_NO_CONTROLLER` |

Three codes, because they are three different operator problems: a pin
that cannot be represented, a pin the platform did not route on this
part, and a device capability for something that is not a pad controller
at all. Collapsing them would make a driver bound to the wrong PCI
function look like a driver asking for a pin the board does not have.

The range check runs **before** the mapping, so an unrepresentable pin is
refused as unrepresentable rather than as unrouted.

### Pin collision — the second mint is REFUSED

Two live line capabilities for the same `(controller_id, pin)` are
refused with `GPIO_LINE_MINT_PIN_IN_USE`.

The I²C argument for refusing a duplicate address was that two owners
interleaving register-pointer-then-read sequences silently read each
other's data. The GPIO argument is stronger **in kind**, not in degree.

A pin has **one state**. It is not a transaction that can be serialised,
retried or arbitrated; it is a voltage on a net. Two drivers each
believing they own a reset line do not race for a resource — one holds
the device in reset and the other releases it, and which one wins is
whichever wrote last. Neither can detect the other. And unlike a bus
transaction, the loser's failure does not surface in the loser's driver;
it surfaces in whatever hardware the pin controls.

There is also **no arbiter shape that fixes it afterwards**. On I²C a
shared device can be fronted by one holder that serialises access,
because the underlying operation is a transaction with a beginning and
an end. A pin's state has no end. The only coherent way to share one is
for exactly one component to own it and expose its own interface — which
starts with the capability being unique.

**The key is scoped to the controller.** A machine with two pad
controllers numbers each one's pins from zero; a global pin table would
refuse the second and make an ordinary board unbootable.

**The key is the absolute pin, not `(community, pad_index)`.** They are
equivalent within a controller, but the absolute pin is the number the
platform description carries, so the uniqueness test applies to what the
caller asked for. It also makes the following true and testable: **the
same pad index in two different communities coexists.** Community 0 pad
5 and community 1 pad 5 are different absolute pins on different
register windows, and a key that looked only at the pad index would
wrongly refuse the second.

### Pin confinement — the property, and how it is made structural

> The pin comes from the capability row, never from the caller.

**Six** signatures are arity-pinned by `tools/build.sh`
(`[gpio-pin-confine]`), not one:

```
pub let gpio_line_row_pin            : (u64) -> u64
pub let gpio_line_pin_of_slot        : (u64) -> u64
pub let gpio_line_community_of_slot  : (u64) -> u64
pub let gpio_line_pad_of_slot        : (u64) -> u64
pub let gpio_line_ctrl_of_slot       : (u64) -> u64
pub let gpio_line_pad_off_of_slot    : (u64) -> u64
```

Six rather than one because the register address is
`community.reg_off + community.padbar + pad_index * stride`: a
caller-supplied **community** reaches a different pin exactly as surely
as a caller-supplied pin does, and a caller-supplied **pad index** more
surely still. A confinement guarding only the pin number would leave two
doors into the same room. (This is #1073's argument for pinning
`i2c_slave_mode_of_slot` and `i2c_slave_bus_row_of_slot` alongside the
address resolver — every field that participates in selecting the
physical target *is* the target.)

On top of that, `lpss_gpio_pad_off` — the raw
`(controller, community, pad) -> offset` arithmetic, with no capability
anywhere — is confined by `objdump -r` to its own object and to
`kind_gpio_line.o`. That makes `gpio_line_pad_off_of_slot(slot)` the
**only route in the kernel from anything to a pad register address**:
capability in, address out, no other parameter. R30.M6-004 (#1078) is
the issue that will write PADCFG registers, and this check decides what
address it is able to write to.

The dispatch handler masks `op_arg` to its low byte, closing the last
channel a caller might use to smuggle a pin into an invocation.

### Tail encoding — row indirection via `_gpio_line_table`

Row — 32 bytes, `GPIO_LINE_MAX = 32`:

| off | field |
|---|---|
| `+0` `[7:0]` | `parent_slot` — the `KIND_DEVICE` slot at mint; audit and query only |
| `+0` `[23:8]` | `pin` — u16, **absolute** on the controller, `< 512` |
| `+0` `[39:24]` | `pad_index` — u16, **community-relative**, derived at mint |
| `+0` `[47:40]` | `community` — u8 |
| `+0` `[55:48]` | reserved, must be zero — #1078's direction / pull / trigger |
| `+0` `[63:56]` | `in_use` |
| `+8` | `controller_id` — `bdf_pack` key, **inherited**. The cascade key and the first term of the uniqueness key |
| `+16` | `driver_hint` — opaque, non-zero; zero is the "unclaimed" sentinel and is refused |
| `+24` | reserved, must be zero — #1078's edge-interrupt subscription state |

`gpio_line_tail_pack` enforces the cross-field rule `pad_index <= pin`
(a community-relative index can never exceed the absolute pin it was
derived from), so a row whose recorded pin and recorded register address
disagree is unrepresentable rather than something every consumer has to
decide about.

`tools/build.sh` asserts by `objdump -r` that no object other than
`kind_gpio_line.o` relocates against `_gpio_line_table`.

### Rights

| bit | name | status |
|---|---|---|
| `0x001` | `R_GPIO_LINE_READ` | reserved for #1077's level get |
| `0x002` | `R_GPIO_LINE_WRITE` | reserved for #1077's level set |
| `0x004` | `R_GPIO_LINE_CONFIG` | reserved for #1078's direction / pull / trigger |
| `0x008` | `R_GPIO_LINE_INVOKE` | the query ops |
| `0x010` | `R_GPIO_LINE_REVOKE` | teardown |
| `0x400` | `R_GPIO_LINE_OBSERVE` | the canonical printer |
| `0x41F` | `R_GPIO_LINE_ALL` | OR of the six |

`RIGHT_MINT (0x200)` is **absent and its absence is structural**: there
is nothing below a single pin on a single controller, and a MINT bit no
gate reads is the shape that later acquires a meaning nobody audited.

**`CONFIG` is separate from `WRITE`**, and on this kind that separation
carries more weight than `READ`/`WRITE` does. Driving an output that
firmware already configured as an output is ordinary. Turning an *input*
into an output is not: a pin firmware left as an input may be a strap
another device is driving, and reconfiguring it starts a contention on a
physical net. "May toggle this line, may not change what kind of line it
is" has to be expressible.

All three are reserved **now** for #1071's stability reason: a
capability minted today will still be refused a level change when #1077
lands, instead of silently acquiring the authority to drive a pin on the
day the op appears.

### Ops (`op_arg[7:0]`) and required right

| op | name | right | returns |
|---|---|---|---|
| 0 | `QUERY_PIN` | `INVOKE` | absolute pin |
| 1 | `QUERY_COMM` | `INVOKE` | community id |
| 2 | `QUERY_PAD` | `INVOKE` | pad index |
| 3 | `QUERY_CTRL` | `INVOKE` | parent cap slot |
| 4 | `QUERY_HINT` | `INVOKE` | driver hint |
| 5 | `DEBUG_PRINT` | `OBSERVE` | canonical row dump |

Query only. **No get, no set, no configure**, and holding every right in
`R_GPIO_LINE_ALL` still cannot reach a pad register through this
capability — asserted by the witness, which drives ops 6 and 7 (where
#1077 and #1078 will put them) and gets `INVOKE_UNSUPPORTED`.

### Revoke, and the controller cascade

`gpio_line_cap_revoke` scrubs the row and clears the descriptor. It
**does not touch the pad**, and that is deliberate rather than an
omission: "return the pin to a safe state" has no meaning this kernel
could supply, because whether high or low is safe is a property of the
board. Driving a reset line to a guessed level on revoke would be a
worse bug than any this kind prevents.

`lpss_gpio_release` calls `gpio_line_cascade_revoke_by_controller`
**before** it revokes the window or frees its own row. Two phases:

* **Phase 1**, by descriptor — every `cap_table` slot holding a
  `KIND_GPIO_LINE` whose row records this controller.
* **Phase 2**, by row — every live row recording this controller even if
  no descriptor points at it. Phase 2 is what makes "no row leak"
  structural: a descriptor cleared by some other path would otherwise
  strand its row forever, and a stranded row still holds a **pin** on a
  controller that no longer exists — so the next legitimate mint of that
  pin would be refused `IN_USE` by a ghost. On this kind the ghost may
  hold the only way to bring a device out of reset.

Keyed on `controller_id` rather than the parent cap slot: a slot can be
reused by a different device, a part's bdf key names the part. A single
level suffices — this kind is a leaf.

### Failure taxonomy — `0xFFFFFF10..0xFFFFFF1F`

Sixteen codes, exactly the band width, between `GPIO_IO_*`
(`0xFFFFFF08..0F`) below and `LPSS_GPIO_*` (`0xFFFFFF20..2F`) above.
Three adjacent, disjoint bands, and the adjacency is the point: all
three layers refuse for structurally similar reasons during a probe, and
a shared band would make "which layer refused" a guess.

### Boot witness

`tests/kernel/cap/gpio_cap_synth.pdx §gpio_cap_witness`, sub-tests A..O
(fifteen stages) — fingerprint **`R30 KIND_GPIO OK`**. Cap slots 64..79,
disjoint from every other witness's set; both exits revoke the windows
and clear the slots.

It builds its controller through the **shipping** allocator and the
shipping community API, so it tests the shape the machine has.

Two sub-tests carry the milestone:

* **F** — the mapping outside community 0, asserted through the
  capability against independently computed offsets, read back through
  the seam, and asserted **against the two wrong answers** an identity
  mapping (`0x18D0`) and a community-0-only mapping (`0x650`) would
  give. Deleting the `pin - pin_base` subtraction fails this at stage 6.
* **J** — the runtime mutant: all five capability-form resolvers and the
  dispatch handler called with a *neighbouring pin's* number, community,
  pad index, register offset and the other controller's identity loaded
  into `rsi`/`rdx`/`rcx`/`r8`/`r9` and packed into the upper 56 bits of
  `op_arg`. Every answer is still the capability's own.

Sub-test **L** manufactures a **ghost row** — a minted line whose
descriptor is then cleared by hand — so phase 2 of the cascade is
exercised rather than assumed.

Ordering note: this witness runs **after**
`tests/kernel/drivers/gpio/lpss_gpio_synth.pdx`, the opposite way round
from the I²C pair. There the capability witness ran first and the driver
consumed its kinds; here the capability depends on the driver, because a
line mint resolves its pin through the controller's community table.

---

## `KIND_FW_SESSION = 0x155` — landed by R30.M8-002 (#1083) / R30.M8-003 (#1084)

Full design: `design/acpi/firmware-session-arbitration.md`.

### Catalog reconciliation — the rename

The R30 catalog named this `KIND_AML_SESSION`. **That identifier cannot
be spelled in `src/kernel/core/cap/`**: `tools/lint-no-kernel-aml.sh`
refuses any identifier beginning `aml` under `src/kernel/**`. #1569
renamed it to `KIND_FW_SESSION` *before any code existed against the old
name*, rather than weakening the lint — see the naming note under
`KIND_OP_REGION` above. Base, tail and purpose are otherwise unchanged
from the planning row.

### Derivation — over `KIND_IPC_ENDPOINT`, in two halves

```
KIND_IPC_ENDPOINT (base slot 5)     the supervisor conversation
      └── KIND_FW_SESSION  0x155    + RIGHT_MINT on the parent
                                    + the parent's INHERITED endpoint id
                                      registered for the requested domain
```

A kind check alone is **empty** here, and more obviously so than for any
previous kind: every IPC endpoint in the system is a
`KIND_IPC_ENDPOINT`, the shell's stdout included. The second half —
`fw_ep_domains(inherited_eid)` non-zero *and* the requested domain bit
set — is what refuses an ordinary endpoint carrying `RIGHT_MINT`. This
is the `KIND_GPIO_LINE` (#1075) shape: kind check plus an inherited
identity that must resolve in a table the platform wrote.

`KIND_FW_SESSION` is a **leaf**: `R_FW_SESSION_ALL` excludes
`RIGHT_MINT`, so the lattice bottoms out and no fixed point is needed.

### Tail encoding — row indirection, path stored whole

The tail `{scope_path:[u8;64], op_region_domain:u8}` is 65 bytes against
a 64-**bit** `target_ptr`, so it lives in a private table.
`target_ptr` = row id in `[15:0]`, owning slot in `[31:16]`.

**Two tables, because a capability names a session and arbitration is
about the object** (N sessions to 1 object):

| table | rows | fields |
|---|---|---|
| `_fw_object_table` | 8 × 128 B | `hdr{in_use:u8, domain:u8, path_len:u8}`, `holder:u64` (= row + 1, 0 unclaimed), `depth:u64`, `refcount:u64`, `scope_path[64]` |
| `_fw_session_table` | 16 × 16 B | `hdr{in_use:u8, domain:u8, parent_slot:u8}`, `object_index:u64` |
| `_fw_ep_registry` | 8 × 16 B | `endpoint_id:u64` (0 = empty), `domain_mask:u64` |

Putting the claim in the *session* row would give every session its own
claim — every holder would successfully claim, observe that it held it,
and write concurrently with every other holder. `fw_object_alloc`
therefore **finds first and allocates second**, and the witness asserts
ten sessions leave `fw_objects_live()` at 1.

Object rows are padded 96 → 128 B so the row index is a shift;
paideia-as has no `mul`.

**The scope path is stored in full, not hashed.** A collision would
merge two firmware objects into one arbitration domain — a writer on the
EC excluding a writer on an unrelated scope, and, worse, two paths that
*should* share an object failing to exclude each other. Comparison
requires equal lengths first and then all bytes; stopping at a shared
prefix or a NUL would make `\_SB.PCI0.LPCB.EC0` and
`\_SB.PCI0.LPCB.EC0X` the same object. The kernel does not parse the
path and must not — it is a firmware namespace this ring is forbidden to
interpret.

### Rights — `R_FW_SESSION_ALL = 0x41B`

| bit | right | authorises |
|---|---|---|
| `0x001` | `READ` | sampling the object |
| `0x002` | `WRITE` | modifying it, **and taking the claim** |
| `0x008` | `INVOKE` | reading back the row's own object and domain |
| `0x010` | `REVOKE` | being revoked |
| `0x400` | `OBSERVE` | holder, depth, canonical dump |

`RIGHT_MINT` (`0x200`) is outside the mask — leaf kind. Taking the claim
requires `WRITE` even though it stores nothing, because its whole effect
is to exclude other writers, and a read-only holder that could exclude
writers could stall the platform stack. The converse configuration is
legitimate and is why the two are separate bits: a session needing a
consistent multi-read snapshot takes the claim precisely so nobody
writes underneath it.

### Ops (`op_arg[7:0]`) and required right

| op | name | right |
|---|---|---|
| 0 | `QUERY_OBJ` | `INVOKE` |
| 1 | `QUERY_DOMAIN` | `INVOKE` |
| 2 | `QUERY_HOLDER` | `OBSERVE` |
| 3 | `QUERY_DEPTH` | `OBSERVE` |
| 4 | `CLAIM` | `WRITE` |
| 5 | `UNCLAIM` | `WRITE` |
| 6 | `DEBUG_PRINT` | `OBSERVE` |

No op takes an object, a scope or a domain: `op_arg` is masked to its low
byte on entry and the object a session acts on comes from its own row.
`tools/build.sh` pins the arities of `fw_session_claim`,
`fw_session_unclaim` and `fw_session_row_obj`.

### The claim

Recursive for the same session (a method evaluating a method against the
same object must not deadlock against itself); **refused** for a
different one (`FW_SESSION_CLAIM_HELD` — no queue, because there is
nowhere to park a waiter and a silent grant is a data race dressed as
success); released only at depth 1→0, since an inner release would let a
second session write in the middle of the outer session's update.

`holder` stores `row + 1`: row 0 is legitimate, and a raw row id would
make "row 0 holds it" and "nobody holds it" the same bit pattern.

### Revoke

Releases the claim if this session held it **at any depth** — a claim
left held by a dead session excludes every other writer on that object
forever — then frees the row, decrements the object refcount and frees
the object row at 0. Both mint and revoke go through `cap_mint_write`,
so this module adds no second descriptor writer (#1579).

### Failure taxonomy — `0xFFFFFE10..0xFFFFFE1F`, a NEW BAND

The `0xFFFFFFxx` band is **exhausted** — two free runs of eight and
nothing wider, while every previous derived kind took a contiguous
sixteen. Splitting across two holes would have made the taxonomy
discontiguous for no reason but scarcity and left the next kind worse
off, so `0xFFFFFExx` is opened here as the successor band.

### Boot witness

`tests/kernel/cap/fw_session_cap_synth.pdx`, sections A..I — fingerprint
`R30 KIND_FW_SESSION OK`, cap slots 160..175.

Sections C–F cover the gate in both directions, the shared-object
property, prefix-sharing scopes not merging, and the claim's recursion
and refusals. **Sections G–H are R30.M8-003 (#1084)**: ten evaluators,
interleaved at operation granularity, asserting linearizability defined
as (L1) mutual exclusion checked between *every* pair of adjacent steps,
(L2) no lost updates, and (L3) non-vacuity. Phase A's schedule is
hand-derived from the failure modes rather than round-robin; Phase B
rotates the starting session so all ten complete an episode. See
`design/acpi/firmware-session-arbitration.md` §10–§11.

---

## `KIND_EC_QUERY = 0x156` — landed by R31.M1-002 (#1090)

Full design: `design/drivers/embedded-controller-kernel-path.md`.

### Catalog reconciliation

The R31 catalog named this kind and said nothing else about it;
`design/acpi/crash-isolation.md` recorded it as "a *planned* R31 kind"
and `design/roadmap/next-wave-synthesis.md` listed the tail as
`{ec_addr, notify_bitmap}`. Both are honoured. The tail is those two
fields plus the inherited endpoint identity and a delivery counter, and
the name was checked against `tools/lint-no-kernel-aml.sh` before it was
committed to — `ec_query` matches none of `\baml`, `\bdsdt`, `\bssdt`,
`\bacpica`, `\_SB_`, `\_SB.`, in code or in `justification:` strings.
That check was made rather than assumed, because #1569 records
`KIND_AML_SESSION` meeting exactly this collision at push time.

### Derivation — over `KIND_IPC_ENDPOINT`, in two halves

```
KIND_IPC_ENDPOINT (5)          KIND_OP_REGION (0x150, space 0x03)
    + RIGHT_MINT                          + RIGHT_MINT
   "where you are told"            "which controller, and that
          \                          firmware declared it"
           \                            /
            +------ both required -----+
                        |
                 KIND_EC_QUERY (0x156)
       ec_addr and endpoint_id both INHERITED
```

The kind half is **empty on its own** — every endpoint in the machine is
a `KIND_IPC_ENDPOINT`, the shell's stdout included — which is the #1075
lesson's second instance and the reason the gate has a second half at
all. That half is a second capability argument rather than a registry
lookup: `region_slot` must be a live `KIND_OP_REGION` carrying
`RIGHT_MINT`, over `OPREG_SPACE_EC (0x03)`, with a declared length in
1..256. Its two failure classes stay distinct — `MINT_BAD_REGION` for
"that is not a region capability", `MINT_BAD_SPACE` for "it is one, over
the wrong space or of an impossible size" — because the fixes differ.

Neither `ec_addr` nor `endpoint_id` is an argument. Both are read from
the parents, the discipline `acpi_evt_cap_mint` uses for the GSI: a
subscription stamped with controller A's address while its region
capability names controller B would pass both halves and then misreport,
for its whole life, which machine's events it received.

### Tail encoding — row indirection

| table | rows | fields |
|---|---|---|
| `_ec_query_table` | 8 × 64 B | `[+0]` hdr `{parent_slot:8, region_slot:8, region_row:16, in_use:8}`, `[+8]` `ec_addr`, `[+16..+40]` `notify_bitmap` (256 bits, one per query byte), `[+48]` `endpoint_id`, `[+56]` `delivered` |

`target_ptr` holds the `row_id`. Stride 64 is a power of two so the index
is a `shl 6` — paideia-as has no `mul`. Eight rows because a subscription
is per-**process**, not per-event-source; fan-out across the 256 query
bytes is the bitmap's job.

**The bitmap starts full and only ever narrows.** `ec_query_row_narrow`
clears one bit; there is no primitive that sets one, and `tools/build.sh`
greps for the natural names of a widening mutant. Starting full is not a
weakening: the gate already proved the minter holds a region capability
over the controller's whole EmbeddedControl space, so the child begins
with no more than its parent. Taking the mask as a mint argument is not
expressible — 256 bits plus four other arguments is eight registers and
SysV has six — and every workaround loses `_Qxx` values real firmware
uses or hands a raw pointer across the confinement boundary.

### Rights — `R_EC_QUERY_ALL = 0x41A`

| bit | right | authorises |
|---|---|---|
| 0x002 | WRITE | narrow the notify bitmap. A WRITE right for an operation that can only remove reach, because the row is mutated and an OBSERVE-only holder must not be able to silence a subscription somebody else depends on. |
| 0x008 | INVOKE | interrogate the routing filter. Separate from OBSERVE because which events a holder watches for is a statement about the holder, not about the capability. |
| 0x010 | REVOKE | tear the subscription down. |
| 0x400 | OBSERVE | read controller address, endpoint identity, region row, delivery count. |

`RIGHT_MINT (0x200)` is **deliberately absent**: this kind is a leaf of
the lattice, and a MINT bit no gate accepts as a parent right would be a
rights bit that looks like authority and confers none. Requests naming it
are refused (`MINT_BAD_RIGHTS`), never silently stripped.

### Ops (`op_arg[7:0]`) and required right

| op | name | right |
|---|---|---|
| 0 | `QUERY_ADDR` | OBSERVE |
| 1 | `QUERY_ENDPOINT` | OBSERVE |
| 2 | `QUERY_DELIVERED` | OBSERVE |
| 3 | `QUERY_WANTS` (query byte in `op_arg[15:8]`) | INVOKE |
| 4 | `UNSUBSCRIBE` (query byte in `op_arg[15:8]`) | WRITE |
| 5 | `QUERY_REGION` | OBSERVE |

No op takes a controller address. The query byte in `[15:8]` is a value,
not an authority: it selects a bit of this row's own bitmap and can reach
no other row. There is no "deliver an event" op — delivery copies a
record into the shared stream, which a three-register invocation cannot
express without a destination pointer.

### The routing selector

`ec_query_row_target(row_id, ec_addr, query_byte)` returns the endpoint
identity or 0, and `ec_query_row_covers(row_id, ec_addr)` returns
whether the row names the controller at all. `core/acpi/ec_route.pdx`
fans out through those two and never touches `_ec_query_table`, which is
what lets the confinement assertion in `tools/build.sh` survive contact
with its first consumer. Both arities are pinned.

### Revoke

`ec_query_cap_revoke` frees the row, then clears the descriptor with
`cap_mint_write(slot, 0, 0, 0)` (#1579) so the owner column's
unconditional clear (#1587) lands on the teardown path too. The free
scrubs the endpoint identity, the controller address **and** the bitmap:
a row reused without scrubbing the bitmap would hand the next holder a
subscription silently missing whatever the previous holder unsubscribed
from, which presents as a device that works for one process and not the
next. **No cascade** — nothing derives from a subscription, and an empty
cascade call would be a hook that looks maintained and is not. Added to
`cap_revoke_slot`'s per-kind dispatch in `core/cap/owner.pdx`, because a
tail-table kind left off that list leaks its row.

### Not loader-seedable

Deliberately absent from `KIND_SEEDABLE_TABLE`. #1597 refuses a kind
defined by its derivation, and this is the strongest case for that rule
so far: both parents are load-bearing, one supplies the controller
address the row records, and a sidecar entry would create a subscription
to an address taken from untrusted image bytes with no region capability
behind it.

### Failure taxonomy — `0xFFFFFE00..0F`

Disjoint from `KIND_FW_SESSION` (`0xFFFFFE10..1F`) and the owner column
(`0xFFFFFE2B..2F`); the whole `0xFFFFFFxx` page is exhausted.

`OK 0`, `TAIL_ENOSPC ..0F`, `TAIL_BAD_ARG ..0E`, `MINT_BAD_PARENT ..0D`,
`MINT_BAD_RIGHTS ..0C`, `MINT_BAD_ARG ..0B`, `MINT_ENOSPC ..0A`,
`MINT_BAD_REGION ..09`, `MINT_BAD_SPACE ..08`, `MINT_BAD_EID ..07`,
`REVOKE_BAD_SLOT ..06`, `REVOKE_WRONG_KIND ..05`, `REVOKE_ALREADY ..04`,
`NARROW_BAD_ARG ..03`, `DECODE_BAD` all-ones.

### Boot witness

`tests/kernel/cap/ec_query_synth.pdx`, fingerprint
`R31 KIND_EC_QUERY OK`, cap slots 200..211. Stages cover both halves of
the gate in both directions, the leaf-rights refusal, the bitmap starting
full and narrowing by exactly one bit across a word boundary, the three
separable authority classes in the handler, row exhaustion, and revoke
including the wrong-kind refusal. Mutation-tested: dropping the second
half's kind check gives `line=12`, accepting the wrong space `line=13`,
admitting `RIGHT_MINT` `line=14`, over-clearing the bitmap `line=17`.


---

## Change log

| Date | Round | Issue | Change |
|------|-------|-------|--------|
| 2026-08-12 | R29.M0 | #1017 | Initial doc + `KIND_HW = 14` base kind row + R29.M1 derived-kind skeletons. |
| 2026-08-12 | R29.M1 | #1019/#1020/#1021 | Refined `KIND_HW_INTERRUPT` row: finalized numeric tag (0x140), tail-encoding scheme (row indirection via `_hw_interrupt_table`), rights bitmask (`R_HW_INT_ALL = 0x618`), full mint/revoke API, dispatch handler. Landed by `src/kernel/core/cap/kind_hw_interrupt.pdx`. |
| 2026-08-12 | R29.M1 | #1022 | Landed `KIND_HW_MSIX_VECTOR = 0x141` — second derived kind over KIND_HW, layered atop `KIND_HW_INTERRUPT`. Row-indirection tail via `_hw_msix_vector_table` encoding `{msix_table_offset:u32, msix_data:u32, parent_slot:u8}`. Rights bitmask `R_MSIX_ALL = 0x218` (INVOKE/REVOKE/MINT). Full mint / revoke / cascade-revoke API + dispatch handler in `src/kernel/core/cap/kind_hw_msix_vector.pdx`. Cascade wired into `hw_int_cap_revoke` (calls `msix_cascade_revoke_by_parent` before freeing its own row). Design doc `KIND_HW_MSIX_VECTOR` row rewritten from planning skeleton to as-landed spec; `KIND_HW_DMA_DOMAIN` + `KIND_HW_TIMELINE` rows relabeled as "planned for a later R29 milestone" (issue-number attribution corrected — R29.M1 closes with two derived kinds landed). Closes R29.M1. |
| 2026-08-12 | R29.M2 | #1023 | Landed driver-process lifecycle FSM (Init/Running/Suspended/Handoff/Stopping/Stopped) with nine-transition whitelist packed as `DRIVER_LIFECYCLE_TABLE = 0x00000020101A1C02`. Landed 32-slot `_driver_table` (48 B rows in .bss) as the descriptor storage. Full primitives (`driver_lifecycle_transition`, `driver_lifecycle_get_state`, `driver_lifecycle_transition_valid`; `driver_table_register`, `driver_table_unregister`, `driver_table_slot_in_use`, `driver_table_read_state_byte`, `driver_table_write_state_byte`, `driver_table_read_pid`, `driver_table_read_caps_offset`, `driver_table_row_addr`) in `src/kernel/core/driver/lifecycle.pdx` + `driver_table.pdx`. Boot witness at `kernel_main.pdx §driver_lifecycle_witness` walks the full Init→Stopped path and exercises every rejection code — fingerprint `R29 LIFECYCLE FSM OK`. Opens R29.M2. |
| 2026-08-12 | R29.M2 | #1024 | Elaborator witness — a driver claiming `!{Mmio}` without holding `paideia.mmio` fails elaboration (paideia-as gate `c768935`). No paideia-os code touched. |
| 2026-08-12 | R29.M2 | #1025 | Landed `driver_hotplug_channel` schema constants. Session-typed stream (bus driver → userspace driver-loader) with two v1 opcodes — `DRV_HP_OP_DEVICE_ARRIVED = 0x01` (24-byte record carrying `{bdf, vendor, device, class_code, device_cap:Cap<KIND_DEVICE>}`) and `DRV_HP_OP_DEVICE_DEPARTED = 0x02` (8-byte record carrying `{bdf, reason}`). Constants in `src/kernel/core/driver/hotplug_schema.pdx`; wire spec at `design/ipc/driver-hotplug-schema.md`. Wire encoders / decoders deferred to R29.M3 registry v2 (per doc §7 rationale). |
| 2026-08-12 | R29.M2 | #1026 | Landed driver lifecycle FSM fuzz witness — 1000-iter Knuth LCG (A=0x5851F42D4C957F2D, C=0x14057B7EF767814F, seed=0x0BADBEEFC0FFEE01) over 3-bit (cur, new) slices from LCG state bits [42:40] / [50:48] (values in [0..8) so ~25% out-of-range). Per-iter asserts the transition-whitelist predicate (`driver_lifecycle_transition_valid`) agrees with the stateful primitive (`driver_lifecycle_transition`) on both direction (rc == 0 iff predicate == 1) and state-mutation (state == new on OK; state unchanged on any error). Witness at `kernel_main.pdx §driver_lifecycle_fuzz_witness` — fingerprint `R29 LIFECYCLE FUZZ OK`. Pure test artifact; no new kernel functionality. |
| 2026-08-12 | R29.M2 | #1027 | Landed `driver_lifecycle_channel` schema constants. Request/reply RPC (userspace driver-lifecycle-supervisor → driver process) with six v1 commands — `DRV_LC_OP_START/INIT_DONE/SUSPEND/RESUME/HANDOFF_BEGIN/STOP = 0x01..0x06` — each mapping 1:1 onto an FSM edge from the R29.M2-001 whitelist. Ack rep is 8 bytes `{driver_slot:u16, rc:u32}` with error codes `DRV_LC_ACK_ERR_{BAD_SLOT, INVALID_TRANS, TIMEOUT, DEVICE_GONE, CAP_MISSING, INTERNAL}` that mirror `DRIVER_LIFECYCLE_ERR_*`. Reply-bit-7 convention shared with `ipc/frame.pdx`. Constants in `src/kernel/core/driver/lifecycle_schema.pdx`; wire spec at `design/ipc/driver-lifecycle-schema.md`. R29.M2-004 fuzz witness (#1026 same wave) exercises the kernel-side coupling directly; wire encoders and canonical example driver (`lpss_uart`) deferred to R30 (per doc §7 rationale). Closes R29.M2. |
| 2026-08-14 | R29.M5 | #1036/#1037 | Landed `KIND_DMA_DOMAIN = 0x142` — **renamed from the `KIND_HW_DMA_DOMAIN` planning skeleton and re-based from `KIND_HW` (14) to `KIND_MEMORY` (= `KIND_PAGE`, 4)** per softarch §3 R29 and the issue text; rationale is that a DMA domain is a memory-access scope, so the mint gate must require memory authority, not device authority. Added the `KIND_MEMORY = 4` name binding in `kind.pdx` so document vocabulary and runtime enum stop drifting. Row-indirection tail via `_dma_domain_table` (32 rows × 32 B) encoding `{iommu_ctx_id:u32, bus_dev_fn:u16, capacity_bytes:u64, coherency:u8, parent_slot:u8}`. Canonical tail-word encoder `dma_tail_pack` + word-level and row-level decoders (#1037), plus canonical debug printer `dma_domain_debug_print` (five-line `DMA DOMAIN ROW` record) reachable via `OP_DEBUG_PRINT`. Rights bitmask `R_DMA_ALL = 0x618` (INVOKE/REVOKE/MINT/OBSERVE) with **per-op** gating rather than a single entry gate. Full mint / revoke / cascade-revoke API + dispatch handler in `src/kernel/core/cap/kind_dma_domain.pdx`; dispatch branch in `invoke.pdx`; chatter tag `cap_dma_dom_msg` in `tags.pdx`. Failure taxonomy `0xFFFFFFD5..0xFFFFFFDF`, disjoint from `HW_INT_*` and `MSIX_*`. Boot witness `kernel_main.pdx §kind_dma_domain_witness` (21 sub-tests) — fingerprint `R29 KIND_DMA_DOMAIN OK`. Opens R29.M5. |
| 2026-08-15 | R29.M7 | #1044/#1047/#1048 | Landed cascade restart — supervisor tree, restart budget, ChannelDead. Supervisor tree is recorded in the driver descriptor's previously-reserved `[+40]` **supervision word** (`parent_slot:5 | parent_present:1 | perm_failed:1 | restart_count:8 | incarnation:8 | window_start_coarse:40`), with `driver_sup_set_parent` refusing any edge that would close a cycle so every subtree walk is total. Restart strategy is **one-for-one across siblings with a mandatory downward cascade**: kill set = subtree(D), restart set = {D}; descendants are stopped and unregistered rather than restarted, because their capabilities were minted against an incarnation that no longer exists and the restarted D re-enumerates them. Justified by R29's own capability partitioning — siblings share no writable object (one `KIND_DMA_DOMAIN` each per D1.b), so one-for-all buys nothing; and a child's authority is *derived* from its parent's, so the downward cascade is forced rather than chosen. `DRIVER_LIFECYCLE_TABLE` widened `0x00000020101A1C02` → `0x00000020101A1C12` to add the `Init -> Stopping` abandon edge (already the documented intent of the R29.M5-003 signature-failure path, previously unreachable) so `driver_restart_force_stop` is total over the state space. Re-arming is **not** an FSM edge: `Stopped` stays terminal, and `driver_table_rearm_incarnation` retires one incarnation and installs the next, gated on Stopped + no-live-DMA-domain + not-permanently-failed. Budget: 5 restarts per 32768 coarse ticks (TSC >> 20, ≈11 s at 3 GHz) carried in the supervision word; exceeding it latches `perm_failed`, leaving the node in the FSM's own terminal state — escalation is the *absence* of a re-arm, and its terminality is enforced at the store rather than by supervisor convention. ChannelDead: the endpoint row's reserved `[+40]` becomes a **driver binding word** (`driver_slot:5 | bound:1 | dead:1 | incarnation:8`); `driver_restart_reap_endpoints` latches `dead` before detaching each parked waiter and wakes it, and both `sys_ipc_recv_body` and `sys_ipc_send_body` gate on `endpoint_is_dead` returning `-ECONNRESET` (104). Stale capabilities cannot attach to a restarted instance: `endpoint_bind_driver` refuses a dead row (`EP_BIND_ERR_DEAD`) with no revival operation, and `endpoint_attach_ok` additionally requires the incarnation to match. Three audit events (`DRV_AUDIT_EV_RESTART/ESCALATE/CHANDEAD` = 4/5/6, all `kind = 0` so cap-kind balances stay exact). New `src/kernel/core/driver/restart.pdx`; design doc `design/drivers/cascade-restart.md`. Boot witness `kernel_main.pdx §r29_cascade_restart_witness` (40 sub-tests over a four-node tree) — fingerprint `R29 CASCADE RESTART OK`. |
| 2026-08-15 | R30.M2 | #1058/#1059/#1060 | Added `KIND_ACPI_EVENT = 0x21` as a **planning row with a fixed wire format**, derived over `KIND_NOTIFICATION` (12) with rights `R_ACPI_EVENT_ALL = 0x408` (OBSERVE + REVOKE; deliberately no INVOKE, so a subscriber cannot forge an eject request, and no MINT, so the subscriber set stays the supervisor's). The capability itself is **not minted** — R30.M2 landed only the *producer*, because AML `Notify` delivery is a bounded userspace ring rather than an IPC send and the capability sits on the supervisor-to-consumer hop that R30.M4 wires. The 32-byte row is a transcription of the ring entry `src/user/aml/aml_ctl.pdx` now produces, carrying `sequence` and `drops_total` so a lossy stream is *localisably* lossy: two records whose sequences differ by more than one bracket the loss and a subscriber re-enumerates one bus instead of all of them. Producer contract: depth 32, tail-drop (never overwrite-oldest, so bounded loss never becomes reordering), a drop is a counted event and not a latched error, one step of interpreter fuel on both the accepted and the dropped path, and the invariant `offered == drained + depth + drops`. |

| 2026-08-15 | R30.M3 | #1061/#1062 | Landed `KIND_OP_REGION = 0x150` — the address-space window capability and **the security boundary of R30**: the first kind whose base slot is not a constant (`KIND_MEMORY` 4 for memory-like spaces, `KIND_IO_PORT` 11 for port-like ones, decided by `opregion_space_base_kind` so a port holder cannot manufacture memory reach). Row-indirection tail via `_op_region_table` (32 × 32 B) encoding `{space:u8, base:u64, len:u64, parent_slot:u8, parent_row:u16, is_root:u1}`. Two mint paths and no third: a **root** path demanding the base-kind parent the space requires, reachable only from kernel-side boot code and deliberately not an op on any capability; and a **derive** path — the one a firmware-declared region takes — which inherits the space from its parent and containment-checks the request, **refusing with `OPREG_MINT_NO_COVER` rather than clipping**, because truncation would turn the capability system into an address oracle. Containment is overflow-safe (never forms `base + len`). Rights `R_OPREG_ALL = 0x61B` with READ/WRITE separate so a read-only window is expressible, and derive monotone in rights as well as extent. Transitive cascade revoke as a fixed-point scan (a window may derive a window; recursion on a teardown path is the shape a hostile chain exploits). `tools/build.sh` asserts via `objdump -r` that `_op_region_table` is relocated against from `kind_op_region.o` alone, which is what makes "the containment check is the only path to a row" a property of the kernel rather than of one file. Boot witness `§kind_op_region_witness` (24 sub-tests) — fingerprint `R30 KIND_OP_REGION OK`; its slot ordering is descending on purpose so the cascade's fixed point is genuinely exercised. Userspace half (#1062) is the SystemMemory handler in `src/user/aml/aml_region.pdx`. Opens R30.M3. |
| 2026-08-15 | R30.M4 | #1068/#1069 | Landed `KIND_ACPI_EVENT = 0x151` — **re-tagged from the `0x21` planning row and re-based from `KIND_NOTIFICATION` (12) to `KIND_HW_INTERRUPT` (`0x140`)**; reconciliation table in the row above. The forcing fact is that the event stream carries **two sources**, not the one the planning row was written from: a firmware `Notify` (informational, nothing to acknowledge) and a hardware **GPE** arriving through the SCI (masked until acknowledged, and the acknowledgement is a *write to the GPE enable register*). `KIND_NOTIFICATION` cannot gate hardware authority, so the endpoint derives over the SCI's own interrupt capability and the gate demands `kind == 0x140` **and** `RIGHT_MINT`; the GSI is **inherited** from the parent row rather than accepted as an argument, so a child cannot misreport which line its events came from. Rights widened `0x408` → `R_ACPI_EVT_ALL = 0x618`: the planning row's no-forged-`Notify` argument is preserved (there is no inject op and no op that writes a record), but acknowledging is not injecting and needs `INVOKE`. Row indirection via `_acpi_event_table` (8 rows × 32 B, sized for **processes** not event sources) encoding `{parent_slot:u8, gsi:u32, subscriber_id:u64, delivered:u64, acked:u64}`; `delivered - acked` is the standing observable for a GPE that is masked, dispatched, handled and never re-enabled. The #1059 32-byte wire format was not discarded — it moved one level down to the stream **record** (64 B, `evt_stream.pdx`), widened by the source discriminator plus a redundant `NEEDS_ACK` flag so what a subscriber *owes* is a field of its own. Bounded stream depth 32 with tail-drop, and the #1059 identity gains one term for the failure mode that ring lacks: `offered == drained + depth + drops + unrouted`, with ring-full and no-subscriber counted **separately** because a wedged subscriber and an absent one need different fixes. `sci_arm` (`core/acpi/sci_arm.pdx`) refuses `SCI_ARM_NOT_READY` without touching the IOAPIC until an endpoint is bound, which is what closes the ordering #1066 left open by programming the SCI masked. Revocation *pushes*: revoke unbinds the stream in the same operation that frees the row. The ISR call-target allowlist in `tools/build.sh` is **unchanged** — the no-subscriber audit record reuses `drv_audit_emit`, already on it. Failure band `0xFFFFFF90..9F`. Boot witness `tests/kernel/acpi/evt_route_synth.pdx` (sub-tests A..G) — fingerprint `R30 ACPI EVENT ROUTE OK`. Closes R30.M4. |
| 2026-08-15 | R30.M5 | #1070/#1071 | Landed the I²C capability **pair** — `KIND_I2C_BUS = 0x152` over `KIND_DEVICE` (base slot 10) and `KIND_I2C_SLAVE = 0x153` over the bus. **No planning row existed for either**: the R30 catalog named them only in `KIND_OP_REGION`'s prose about refusing the four bus address spaces, with no tag, base, tail or rights fixed, so unlike #1068 there was nothing to re-base. Two kinds rather than one because I²C is a *shared bus*: the controller can address every peripheral on it, so a single per-controller capability makes per-device isolation decorative. The bus cap is therefore **non-transacting by construction** — no read/write op and `RIGHT_READ`/`RIGHT_WRITE` outside `R_I2C_BUS_ALL = 0x618`, so no later op can quietly consume them — and the only path to the wire is a slave cap naming one address. Controller identity is **inherited** from the parent `KIND_DEVICE` descriptor's `target_ptr` (the mint has no controller argument), extending #1068's GSI-inheritance discipline to identity; bus rate is an argument but with a **closed domain** of the four spec rates, because an unvalidated rate becomes an unvalidated clock divider in #1072 and a wrong divider does not refuse, it corrupts. Gates on base slot 10 rather than R22's derived `KIND_PCI_DEV = 0x30` because `device_cap_mint` still writes no descriptor — a `0x30` gate would be *vacuous*. **Address confinement is structural**: both resolvers (`i2c_slave_addr_of_slot`, `i2c_slave_row_addr`) are arity-one, no op takes an operand (`op_arg` masked to its low byte before any dispatch decision), and `tools/build.sh`'s new `i2c-addr-confine` step pins both literal signature lines so a mutant that adds an `addr` parameter fails the *build*; the runtime half is witness sub-test O, which loads a neighbouring device's address into every register such a parameter would arrive in. 7-bit addressing admits `0x08..0x77` with **distinct codes per reserved range** (`0x00..0x07` LOW, `0x78..0x7F` HIGH — the high one confinement-critical, since `0x78..0x7B` is the 10-bit prefix and a 7-bit cap there would reach a 256-address space); 10-bit admits all of `0x000..0x3FF`. Duplicate `(parent_row, mode, addr)` is **refused** `ADDR_IN_USE`, because two owners of one I²C part interleave register-pointer-then-read sequences and silently read each other's data with no protocol-level way to notice — a shared device needs an arbiter, which is built, not minted twice; the key is **scoped to the bus**, since a global table would reject 0x1A-on-two-controllers and make an ordinary board unbootable. Row indirection via `_i2c_bus_table` (8 × 32 B) and `_i2c_slave_table` (32 × 32 B), both confined by `objdump -r` to their owning object — which is *why* the bus's live-device count has exactly two mutators, `i2c_bus_note_slave_added`/`_removed`. Bus revoke **cascades** in two phases, by descriptor and then by row; phase 2 is what makes "no row leak" structural, since a stranded row would refuse the next legitimate mint at that address by a ghost. `KIND_I2C_SLAVE` is a **leaf** (no `RIGHT_MINT`), so no fixed point is needed. A slave cap does **not** yet permit any transaction, any controller register access, or any bus operation — #1072 maps the BARs and #1073 defines the transfer channel. Failure bands `0xFFFFFF83..8F` (bus) and `0xFFFFFF70..7F` (slave), disjoint from each other and from every other kind. Boot witness `tests/kernel/cap/i2c_cap_synth.pdx` (sub-tests A..T) — fingerprint `R30 KIND_I2C OK`. Opens R30.M5. |

---

## References

- `design/capabilities/linearity-and-tags.md` §3.1 — base kind hierarchy.
- `design/capabilities/derived-kinds.md` — Phase-2 derived-kind catalog.
- `design/roadmap/next-wave-synthesis.md` §10 D6 — slot 14 promotion decision.
- `design/roadmap/next-wave-softarch.md` §3 R29 — driver-framework maturation
  round detail; §4 for GPU/display timeline chain.
- `src/kernel/core/cap/kind.pdx` — the KIND_* enum.
- `src/kernel/core/cap/invoke.pdx` — dispatch table.
| 2026-08-15 | R30.M5 | #1072/#1073 | Landed the **LPSS I²C controller** and the **`i2c_transfer_channel`** — the two issues that turn the #1070/#1071 capability pair from structure into traffic. **Identification carries no device-ID table**, deliberately: a table is a claim about which silicon exists, wrong the moment a machine ships that its author had not seen, and its failure shape is the worst available — a present, healthy, *unprobed* controller and a silent log. Two stages instead: a loose PCI **class** candidate filter (`0x0C/0x80` or `0x11/0x80`, both seen in the wild for LPSS depending on firmware), then confirmation against **`IC_COMP_TYPE == 0x44570140`**, the constant every Synopsys `DW_apb_i2c` instance carries regardless of vendor, wrapper or SoC generation — an answer from the *part*, so it is right on silicon nobody here has seen. A class-matched candidate that fails stage 2 is `REJECTED` and **logged at LEVEL_ERROR with its BDF**, because "something is at this address and it is not what we expected" is the sentence that turns an unexplained dead touchpad into a bug report. The one vendor-specific fact — Intel's private reset at BAR0+0x204 — is gated on VID 0x8086 recorded at probe, and **released before** the identity read, an ordering that reversed rejects every Intel controller on the machine since the block reads back zero until then. **The BAR is reached only through a capability**: `lpss_i2c_bind_window` mints a `KIND_OP_REGION` root over space `PCI_BAR` (0x06, memory-like → demands a `KIND_MEMORY` parent with `RIGHT_MINT`) whose base and length are **inherited from the probed row, never argued** — a caller-supplied base would let a memory-authority holder mint a window over any address and call it a controller, i.e. #1061's own hole reopened by its client. The seam (`dw_io.pdx`) stores the **cap slot, not the address**, and re-resolves it per access, so a revoke takes effect immediately, a read-only window refuses writes, and out-of-window offsets are refused rather than clamped; `objdump -r` asserts that no object under `core/drivers/i2c/` other than `dw_io.o` relocates against `opregion_row_base`/`_len`, the only two functions that can turn a capability into a physical address. **Divider provenance is a stated ladder**: firmware-supplied HCNT/LCNT (best, deferred — needs the interpreter hop), computed from an ic_clk drawn from a **closed domain** of the three shipped Intel frequencies (implemented), or **refused** `INIT_CLK_UNKNOWN` — never defaulted, because a wrong divider does not error, it mis-clocks on a cold boot at the customer's desk. Counts at 100 MHz are `(397,469)/(57,129)/(23,49)/(3,11)`; the last is *below the core's hcnt minimum of 6*, which is why High-speed is refused rather than clamped (and refused twice over — it also needs a master-code preamble). **Bring-up ordering is the milestone's ordering claim**: disable, **poll `IC_ENABLE_STATUS` not `IC_ENABLE`** (the core's enable is asynchronous, and DesignWare *accepts and discards* configuration written while enabled), configure, enable, poll — asserted by **trace position**, since both orders leave identical final state. Only the count bank the rate uses is programmed, because the rate lives in the bus capability and a rate change is a different capability, not a register poke. **`i2c_transfer_channel`** (`{write, read, write_read, smbus_op}`, replies `| 0x80`) has **no address field in any revision**, two must-be-zero fields so a v2 cannot add one silently, and four kernel primitives plus three arity-one resolvers (`addr`/`mode`/`bus_row` — mode and bus row each being *half of an address* on a shared bus) whose seven literal signatures `tools/build.sh` now pins. `WRITE_READ` is its own opcode because a STOP between the pointer write and the read releases the bus and returns a different register's contents with **no error anywhere**; the engine emits exactly one RESTART and one STOP, asserted from the command-flag trace. `IC_TAR` is programmed **every** transfer and never cached: a stale target reaches the wrong device at full speed, which is the one failure the capability pair exists to prevent. Rights are **per direction** with three distinct refusals, consuming the `READ`/`WRITE` bits #1071 reserved so a capability minted before this landing is refused rather than silently widened — and `WRITE_READ` needs `WRITE` because the command byte moves the device's register pointer. Every wait is **bounded by an iteration budget** (reproducible, and independent of TSC calibration) with distinct codes per wait, and every loop checks for an abort *first*, since an aborted core holds its TX FIFO and would otherwise turn a NACK into a timeout. **NACK is an outcome**: `IC_CLR_TX_ABRT` is read on every abort path before any decoding — omitting it leaves the next transfer by any driver facing a latched abort — and the three real-world facts (nothing there / rejected a byte / lost arbitration) get three codes with the raw source retained. **Wedged bus: tier 1 implemented** (`IC_ENABLE.ABORT` + cycle, recovering every case where the master is stuck); **tier 2 deferred with its reason** — freeing a slave that latched SDA low needs SCL pulsed at the pad, i.e. `KIND_GPIO_LINE` from R30.M6 — and the state is *handled*: detected behaviourally at three consecutive failures (one can be a transient arbitration loss), latched, fast-failing without touching a register, with `lpss_i2c_unwedge` as the named exit. New bands `DW_IO_*` `0xFFFFFF30..3F`, `LPSS_I2C_*` `0xFFFFFF40..5F`, `I2C_XFER_*` `0xFFFFFF60..6F`, disjoint from each other and from every existing band. Seam pattern follows `gpe_io.pdx`, with the synthetic side a **device model** rather than a RAM buffer (read-to-clear registers clear, a commanded STOP raises STOP_DET, an armed NACK aborts) — without which "a NACK does not wedge the controller" would be unobservable. paideia-as#1312 does **not** apply: no port I/O here, and MMIO already carries the cap/effect coupling R29.M2-002 landed. Boot witness `tests/kernel/drivers/i2c/lpss_i2c_synth.pdx` (sub-tests A..R) — fingerprint `R30 LPSS I2C OK`, placed after the #1070/#1071 witness because both reset the bus and slave tables. Closes R30.M5. |
| 2026-08-15 | R30.M5 | #1074 | Landed the **interrupt-driven I²C transfer engine**, closing R30.M5. **Path choice is "both", and the shape of "both" is the whole design**: two engines is not a performance question, it is a drift question — a NACK decoding one way on one path and another on the other, depending on which boot phase a caller ran in. So (a) the error handling is **not duplicated, it is called**: both engines decode aborts through the same `dw_xfer_check_abort`, resolve rights through the same `i2c_xfer_resolve`, retarget through the same `i2c_xfer_set_target` and check the same wedge latch, and the witness asserts the same armed abort yields the same code through `i2c_xfer_write` and `i2c_xfer_irq_write`; (b) the interrupt engine has **one implementation and only its caller varies** — `dw_i2c_isr_body` *is* the engine, called by a trampoline when a vector is bound and by `dw_irq_wait` from thread context when none is (today, and early boot forever), so the boot path cannot diverge from the interrupt path because it is the same function; (c) the polled engine stays for bring-up and SMBus as **distinct entry points, not a mode flag**, since a hidden flag is exactly how one call comes to behave two ways. **FSM state ownership is a baton, not a lock.** `_dw_irq_ctx[ctrl]` (128 B, cache-line aligned, `objdump -r`-confined) has exactly ONE field written by both contexts — `state`, written only by LOCK-prefixed CAS/xchg — and every other field has one writer at a time, chosen by that word: thread in `SETUP`, ISR in `ARMED`/`RUNNING`, the `CLOSING` winner in `CLOSING`, thread again once terminal. Publish is `CAS(SETUP→ARMED)` with the **software arm strictly before the hardware arm** (the `IC_INTR_MASK` write), so the first interrupt cannot find an unpublished row; return is field stores then `atomic_store(state, DONE|ABORT)`, TSO-ordered, so a thread that has seen `DONE` has seen everything that produced it. **Termination is an exclusive claim** through a distinct `CLOSING` state, because the ISR on a STOP_DET and the thread on an exhausted budget can decide simultaneously and a single CAS would publish before the outcome was written — the caller would be told "timed out" about a transfer that completed. Two concurrent service routines are excluded by a gate the loser **declines rather than spins on**, which is sound because the source is a level and is the only exclusion an ISR may use. **TX_EMPTY is a level, not an event** (`TXFLR <= IC_TX_TL`, and bring-up sets `IC_TX_TL = 0`), so it is true forever once the FIFO drains: a driver that leaves it unmasked completes correctly and takes an interrupt per EOI until the STOP lands, with nothing in final state recording it. Masked at ONE point — `dwi_isr_tx_masked`, the instant the command carrying `DW_CMD_STOP` is accepted, the earliest moment with nothing left to send — and the POSITION is recorded (`masked_at`) so the witness asserts *which* command, since masking at the first byte leaves an identical final mask and is wrong. Measured by a **level-triggered delivery pump** over a model extended to compute `IC_INTR_STAT = raw & mask`, hold TX_EMPTY from enable, follow RX_FULL with the queue, and **arm a commanded STOP as a countdown rather than reporting it instantly** — with a zero-length interval the storm cannot exist. A one-byte write costs exactly two service events; sub-test U puts the mask back by hand and asserts the same measurement exceeds ten, because *a ceiling nothing can breach proves nothing*. **Address NACK and data NACK stay distinct** and the data NACK reports `pushed − IC_TXFLR − 1` acknowledged bytes read at the abort — not the number pushed, since the core flushes the FIFO and the NACKed byte never landed; a caller assuming "all of it" would leave a device holding a half-applied multi-byte register write. Making that testable forced two model corrections of things `dw_regs.pdx` had asserted in prose since #1072 without modelling: an abort can now let N commands through first, and an abort **clears `IC_STATUS.TFNF`** with `IC_CLR_TX_ABRT` restoring it. **`dw_isr.pdx` is one function** so `objdump -r` can bound it: new `[dw-isr-allowlist]` with eleven targets and a vacuity guard, **separate from** `[sci-isr-allowlist]` and neither widening the other; two fixed bursts (8/8) so cost does not grow with transfer length. **The polled engine also gained the claim**: until #1074 two CPUs could interleave `IC_DATA_CMD` writes into one FIFO under one `IC_TAR` — one device's bytes under another's address, no error anywhere — an R18-SMP exposure nothing had closed. The claim is a **single global cell** because the seam has one binding; per-controller would let two controllers repoint it under each other. Also fixed: `dw_io_trace_append` reserves with `lock xadd`, since the ISR shares the seam and a read-modify-write loses one record and *aliases* another, which is the exact corruption that makes an ordering assertion say the opposite of the truth. New band `I2C_IRQ_*` `0xFFFFFFE0..E6`, closing the gap between `DMA_*` and `MSIX_*`; only THREE codes are new (`BUSY`, `NOT_OWNER`, `BAD_STATE`/`BAD_IDX`) because everything else reuses the polled taxonomy — the completion timeout is `I2C_XFER_TIMEOUT_STOP`, which is exactly right since the terminal states are STOP_DET or abort. Four interrupt entry points added to the signature pin set. Vector allocation, IDT install and EOI belong to R30.M6's `KIND_HW_MSIX_VECTOR` binding; the routine is written so binding one **adds a caller, not a code path**. Boot witness sub-tests S..X — second fingerprint `R30 LPSS I2C IRQ OK`. **Closes R30.M5.** |
| 2026-08-15 | R30.M6 | #1075/#1076 | Landed `KIND_GPIO_LINE = 0x154` — derived over `KIND_DEVICE` with a two-part gate (kind + RIGHT_MINT, then the inherited identity must resolve to a probed pad controller). Row-indirection tail via `_gpio_line_table` encoding `{parent_slot:u8, pin:u16 absolute, pad_index:u16 community-relative, community:u8}` plus an inherited `controller_id`. Rights `R_GPIO_LINE_ALL = 0x41F`, with `CONFIG` split from `WRITE`. Community/pad mapping DERIVED at mint by `lpss_gpio_resolve_pin`; six resolver signatures arity-pinned and `lpss_gpio_pad_off` confined, so `gpio_line_pad_off_of_slot` is the only capability-to-pad-address route. Duplicate `(controller, pin)` refused; out-of-range and unmapped pins refused with distinct codes, never clamped. Two-phase controller cascade via `lpss_gpio_release`. Driver half in `core/drivers/gpio/{lpss_gpio,gpio_io}.pdx` with `design/drivers/lpss-gpio-controller.md`. Witnesses `R30 LPSS GPIO OK` + `R30 KIND_GPIO OK`. Opens R30.M6. |
| 2026-08-16 | R30.M8 | #1569/#1083/#1084 | Landed `KIND_FW_SESSION = 0x155`, **renamed from the catalog's `KIND_AML_SESSION` by #1569** before any code existed against the old name — capabilities live in `src/kernel/core/cap/` and `tools/lint-no-kernel-aml.sh` refuses any identifier beginning `aml` there, so the catalog name and the file's address were in direct contradiction; the lint was left alone, and the new name is the more accurate one since what is arbitrated is an evaluation *session* against a *firmware-supplied* object. Derived over `KIND_IPC_ENDPOINT` (base slot 5) with a two-part gate whose first half is **emptier than any previous kind's** — every endpoint in the system is a `KIND_IPC_ENDPOINT`, the shell's stdout included — so the second half requires the parent's **inherited** endpoint id to be registered in `_fw_ep_registry` for the requested op-region domain, the `KIND_GPIO_LINE` (#1075) shape. **Two tables, not one**, because a capability names a session and arbitration is about the object (N:1): `_fw_object_table` (8 × 128 B) carries the claim, depth, refcount and the whole 64-byte scope path; `_fw_session_table` (16 × 16 B) carries the object index. Putting the claim in the session row would give every session its own, so every holder would claim successfully, observe that it held it, and write concurrently with all the others — a failure with **no symptom on the claiming side**, surfacing as a firmware object with interleaved half-updates; `fw_object_alloc` therefore finds first and allocates second, and the witness asserts ten sessions leave one object row. The **path is stored whole, not hashed**, and compared length-first then bytewise: a collision merges two arbitration domains, and a comparison stopping at a shared prefix or a NUL would make `\_SB.PCI0.LPCB.EC0` and `\_SB.PCI0.LPCB.EC0X` the same object — the fixture's two paths share 17 bytes and differ in the 18th for exactly that reason. Rights `R_FW_SESSION_ALL = 0x41B`; the claim requires `WRITE` because its whole effect is to exclude other writers, while `WRITE` and the claim stay separate bits so a consistent-snapshot reader can hold one without the other. Claim is recursive for the same session, **refused** (`CLAIM_HELD`, no queue) for a different one, and released only at depth 1→0; `holder` stores `row + 1` because row 0 is legitimate and a raw id would make 'row 0 holds it' and 'nobody holds it' the same bit pattern. Revoke releases a held claim at any depth — a claim held by a dead session excludes every other writer forever — and frees the object row at refcount 0. Both mint and revoke go through `cap_mint_write`, adding no second descriptor writer (#1579). **New failure band `0xFFFFFE10..1F`**: the `0xFFFFFFxx` band is exhausted at two free runs of eight, and splitting across them would have made the taxonomy discontiguous for no reason but scarcity while leaving the next kind worse off. **#1084 is sections G–H of the same witness**: ten evaluators interleaved at operation granularity, asserting linearizability *defined before it is claimed* — (L1) mutual exclusion checked between every pair of adjacent steps rather than at the end, since every episode terminates with an UNCLAIM and the quiescent final state is consistent with any amount of overlap; (L2) no lost updates, the object's value equalling the completed-write count; (L3) non-vacuity, asserted as exact step and blocked-step totals because a schedule that silently stopped contending would still clear a floor. Each episode is five separate steps (CLAIM/READ/BUMP/WRITE/UNCLAIM) so another session can be scheduled between the read and the write, and a session proceeds on **its own successful claim** rather than on the object's holder field — modelling it the other way would build the property under test into the harness. Phase A's 14-step schedule is hand-derived from the two failure modes (two sessions both observing the object free; a release landing between another session's check and its use); Phase B rotates the starting session each pass, without which session 0 would win every pass and the other nine would never complete an episode. Boot witness `tests/kernel/cap/fw_session_cap_synth.pdx` (A..I) — fingerprint `R30 KIND_FW_SESSION OK`. Closes R30.M8. |
| 2026-08-17 | R31.M1 | #1089/#1090/#1091 | Landed `KIND_EC_QUERY = 0x156` — the right to be told that ONE embedded controller raised ONE of a named set of query events — plus the kernel's transaction gate (`core/drivers/ec/ec_access.pdx`) and query router (`core/acpi/ec_route.pdx`). Derives over `KIND_IPC_ENDPOINT` in **two halves** for the second time in the tree, because the kind half admits every endpoint in the machine; the second half is a second capability argument, a live `KIND_OP_REGION` over `OPREG_SPACE_EC` with a declared length in 1..256, and both `ec_addr` and `endpoint_id` are inherited rather than argued. Row indirection via `_ec_query_table` (8 x 64 B) carrying a 256-bit notify bitmap that **starts full and only ever narrows** — there is no widening primitive and `tools/build.sh` greps for one. Rights `R_EC_QUERY_ALL = 0x41A`, `RIGHT_MINT` deliberately excluded (leaf). Band `0xFFFFFE00..0F`. Added to `cap_revoke_slot`'s per-kind dispatch; NOT added to `KIND_SEEDABLE_TABLE`, per #1597's rule against seeding a kind defined by its derivation. `acpi_evt_offer` gained its **third source**, `ACPI_EVT_SRC_EC_QUERY = 3` — the extension its own R30.M4 justification anticipated when it put `NEEDS_ACK` in a field of its own; a query is not an acknowledging source, so `flags` stays 0. Three boot fingerprints (`R31 KIND_EC_QUERY OK`, `R31 EC ACCESS OK`, `R31 EC QUERY ROUTE OK`), eight mutants each caught with its own tag. **#1091's decoder half was already done** in ring 3 (R30.M7 / #1080) and was not rebuilt — `design/acpi/no-aml-in-kernel.md` forbids it in the kernel, and what was missing was the routing. **This path is NOT arbitrated against SMM**: the Global Lock is inert in production because #1580 has not plumbed the FACS address or the PM1 control port, and `ec_access_arbitrated()` is pinned at 0 by the boot witness so the commit that closes #1580 breaks the pin and must rewrite the claim. See `design/drivers/embedded-controller-kernel-path.md` §0. |
| 2026-08-20 | R40.M5 | #1364 | R40.M5 closure — enumerated every derived kind minted between R29 and R40 (0x140..0x181) in a single summary table (§"R40.M5 closure catalogue" below), cross-referenced to its `src/kernel/core/cap/kind_*.pdx` and its failure-taxonomy band, and classified its derivation discipline (LINEAR / SEALED / plain-derived). Design doc only, no source changes — the tags, bases, rights and bands are the ones already in `kind.pdx`. **Ordering guarantee:** the derived-kind range is 0x140..0x181 with **no gaps** — every value from 0x140 through 0x181 (66 slots) is either landed or reserved-in-place, so a future kind lands at 0x182 without displacing anything below. |

---

## R40.M5 closure catalogue (0x140..0x181)

Populated by R40.M5-002 (#1364) at the r40-camera-wwan close. One row per
derived-kind tag; where a kind carries an explicit LINEAR or SEALED
discipline the "Discipline" column names it, otherwise the column reads
`derived` (plain derivation, no re-parenting refusal, no opacity gate).
The "Band" column is the kind's own failure-taxonomy band as declared in
its `pub let` refusal constants; any driver or channel that emits
alongside the kind owns a disjoint band declared in its own module.
Every source file lives under `src/kernel/core/cap/kind_*.pdx` unless
otherwise noted.

### R29 — driver-framework maturation (three derived kinds)

| Tag    | Kind name                | Parent (base)                     | Purpose                                                                                     | Discipline                    | Band                | Source                          |
|--------|--------------------------|------------------------------------|---------------------------------------------------------------------------------------------|-------------------------------|---------------------|---------------------------------|
| 0x140  | `KIND_HW_INTERRUPT`      | `KIND_HW = 14`                    | Vector + CPU affinity + trigger mode; the R29.M1 hardware-interrupt authority.              | derived (leaf-until-MSIX)     | 0xFFFFFFF7..FD      | `kind_hw_interrupt.pdx`         |
| 0x141  | `KIND_HW_MSIX_VECTOR`    | `KIND_HW_INTERRUPT = 0x140`       | MSI-X vector under an interrupt parent; layered over HW_INTERRUPT.                          | derived                       | 0xFFFFFFE7..E9      | `kind_hw_msix_vector.pdx`       |
| 0x142  | `KIND_DMA_DOMAIN`        | `KIND_MEMORY = 4`                 | IOMMU-scoped memory-access domain; rebased from `KIND_HW_DMA_DOMAIN` at R29.M5-001 (#1036). | derived (per-op gated)        | 0xFFFFFFD5..DF      | `kind_dma_domain.pdx`           |

### R30 — platform-firmware substrate (six derived kinds)

| Tag    | Kind name                | Parent (base)                     | Purpose                                                                                     | Discipline                    | Band                | Source                          |
|--------|--------------------------|------------------------------------|---------------------------------------------------------------------------------------------|-------------------------------|---------------------|---------------------------------|
| 0x150  | `KIND_OP_REGION`         | `KIND_MEMORY = 4` or `KIND_IO_PORT = 11` (per space) | Address-space window; the R30 security boundary.                                            | derived (transitive-cascade)  | 0xFFFFFFC2..CF      | `kind_op_region.pdx`            |
| 0x151  | `KIND_ACPI_EVENT`        | `KIND_HW_INTERRUPT = 0x140`       | Subscriber-to-ACPI-event-stream cap; rebased from the `0x21` planning row at R30.M4 (#1068).| derived                       | 0xFFFFFF90..9F      | `kind_acpi_event.pdx`           |
| 0x152  | `KIND_I2C_BUS`           | `KIND_DEVICE = 10`                | I²C bus authority; non-transacting by construction.                                         | derived                       | 0xFFFFFF83..8F      | `kind_i2c_bus.pdx`              |
| 0x153  | `KIND_I2C_SLAVE`         | `KIND_I2C_BUS = 0x152`            | Single addressable peripheral on a bus.                                                     | derived (leaf, no MINT)       | 0xFFFFFF70..7F      | `kind_i2c_slave.pdx`            |
| 0x154  | `KIND_GPIO_LINE`         | `KIND_DEVICE = 10`                | Pin authority behind a probed pad controller.                                               | derived                       | 0xFFFFFF10..1F      | `kind_gpio_line.pdx`            |
| 0x155  | `KIND_FW_SESSION`        | `KIND_IPC_ENDPOINT = 5`           | Evaluation session against a firmware-supplied object; **the LINEARIZABILITY witness lives here** (R30.M8-003 #1084). | linearizable-on-object        | 0xFFFFFE10..1F      | `kind_fw_session.pdx`           |

### R31 — sensors, actuators, hot-keys (nine derived kinds)

| Tag    | Kind name                | Parent (base)                     | Purpose                                                                                     | Discipline                    | Band                | Source                          |
|--------|--------------------------|------------------------------------|---------------------------------------------------------------------------------------------|-------------------------------|---------------------|---------------------------------|
| 0x156  | `KIND_EC_QUERY`          | `KIND_IPC_ENDPOINT = 5`           | Right to be told that one EC raised one named query event.                                  | derived (leaf, no MINT)       | 0xFFFFFE00..0F      | `kind_ec_query.pdx`             |
| 0x157  | `KIND_THERMAL_ZONE`      | `KIND_DEVICE = 10`                | ACPI thermal zone (temperatures, trip points).                                              | derived                       | 0xFFFFFE30..3F      | `kind_thermal_zone.pdx`         |
| 0x158  | `KIND_BATTERY`           | `KIND_DEVICE = 10`                | ACPI battery reading + capacity scale.                                                      | derived                       | 0xFFFFFE40..4F      | `kind_battery.pdx`              |
| 0x159  | `KIND_COOLING_DEVICE`    | `KIND_DEVICE = 10`                | ACPI cooling-device level authority (0..max).                                               | derived                       | 0xFFFFFE50..5F      | `kind_cooling_device.pdx`       |
| 0x15A  | `KIND_BACKLIGHT`         | `KIND_DEVICE = 10`                | Backlight level authority (PWM or DPAUX backend).                                           | derived                       | 0xFFFFFE70..7F      | `kind_backlight.pdx`            |
| 0x15B  | `KIND_HID_DEVICE`        | `KIND_DEVICE = 10`                | HID device (touchpad, trackpoint, keyboard) authority.                                       | derived                       | 0xFFFFFE80..8F      | `kind_hid_device.pdx`           |
| 0x15C  | `KIND_HID_EVENT`         | `KIND_IPC_ENDPOINT = 5`           | Subscriber-to-HID-event-stream cap.                                                          | derived                       | 0xFFFFFE90..9F      | `kind_hid_event.pdx`            |
| 0x15D  | `KIND_SENSOR_CHANNEL`    | `KIND_IPC_ENDPOINT = 5`           | Subscriber-to-sensor-hub (ALS/ACCEL/GYRO) event stream.                                     | derived                       | 0xFFFFFEA0..AF      | `kind_sensor_channel.pdx`       |
| —      | `KIND_THERMAL_POLICY` (§) | —                                 | Not a derived-kind row — thermal_policy is a `.bss` map, not a cap; see `core/policy/thermal_policy.pdx`. | n/a                           | n/a                 | `core/policy/thermal_policy.pdx` |

### R33 — audio (five derived kinds)

| Tag    | Kind name                | Parent (base)                     | Purpose                                                                                     | Discipline                    | Band                | Source                          |
|--------|--------------------------|------------------------------------|---------------------------------------------------------------------------------------------|-------------------------------|---------------------|---------------------------------|
| 0x15E  | `KIND_AUDIO_CONTROLLER`  | `KIND_DEVICE = 10`                | HDA / SST audio controller authority.                                                       | derived                       | 0xFFFFFEB0..BF      | `kind_audio_controller.pdx`     |
| 0x15F  | `KIND_PCM_STREAM`        | `KIND_IPC_ENDPOINT = 5`           | PCM stream endpoint (playback/capture).                                                     | derived (LINEAR on identity)  | 0xFFFFFEC0..CF      | `kind_pcm_stream.pdx`           |
| 0x160  | `KIND_AUDIO_CLOCK`       | `KIND_HW = 14`                    | Audio-domain clock frequency authority.                                                     | derived                       | 0xFFFFFED0..DF      | `kind_audio_clock.pdx`          |
| 0x161  | `KIND_AUDIO_ROUTE`       | `KIND_IPC_ENDPOINT = 5`           | Route / gain / mute matrix; "LINEAR on identity, DYNAMIC on state" (kind.pdx §KIND_AUDIO_ROUTE). | LINEAR-on-identity            | 0xFFFFFEE0..EF      | `kind_audio_route.pdx`          |

### R34/R35 — USB / mass-storage / hotplug (nine derived kinds)

| Tag    | Kind name                | Parent (base)                     | Purpose                                                                                     | Discipline                    | Band                | Source                          |
|--------|--------------------------|------------------------------------|---------------------------------------------------------------------------------------------|-------------------------------|---------------------|---------------------------------|
| 0x162  | `KIND_USB_DEVICE`        | `KIND_DEVICE = 10`                | Enumerated USB device authority.                                                            | derived                       | 0xFFFFFDE0..EF      | `kind_usb_device.pdx`           |
| 0x163  | `KIND_USB_HUB`           | `KIND_USB_DEVICE = 0x162`         | Hub-class device (port-tree authority).                                                     | derived                       | 0xFFFFFEF0..FF      | `kind_usb_hub.pdx`              |
| 0x164  | `KIND_USB_INTERFACE`     | `KIND_USB_DEVICE = 0x162`         | One interface-descriptor's authority within a device.                                       | derived                       | 0xFFFFFBB0..BF      | `kind_usb_interface.pdx`        |
| 0x165  | `KIND_USB_ENDPOINT`      | `KIND_IPC_ENDPOINT = 5`           | One endpoint-descriptor's authority under an interface.                                     | derived                       | 0xFFFFFBC0..CF      | `kind_usb_endpoint.pdx`         |
| 0x166  | `KIND_MSC_LUN`           | `KIND_USB_INTERFACE = 0x164`      | Mass-storage-class LUN authority under a USB interface.                                     | derived                       | 0xFFFFFBA0..AF      | `kind_msc_lun.pdx`              |
| 0x167  | `KIND_SCSI_DEVICE`       | `KIND_MSC_LUN = 0x166`            | SCSI target under a mass-storage LUN.                                                       | derived                       | 0xFFFFFB70..7F      | `kind_scsi_device.pdx`          |
| 0x168  | `KIND_USB_URB`           | `KIND_IPC_ENDPOINT = 5`           | Single-USB-request-block authority (transient).                                             | derived                       | 0xFFFFFB60..6F      | `kind_usb_urb.pdx`              |
| 0x169  | `KIND_ISOCH_STREAM`      | `KIND_USB_ENDPOINT = 0x165`       | xHCI isochronous stream cap (webcam / UAC).                                                 | derived                       | 0xFFFFFAC0..CF      | `kind_isoch_stream.pdx`         |
| 0x16A  | `KIND_FP_SENSOR`         | `KIND_DEVICE = 10`                | Fingerprint sensor device authority.                                                        | derived                       | 0xFFFFFA80..8F      | `kind_fp_sensor.pdx`            |

### R35 — Thunderbolt / hotplug / DMA attestation (four derived kinds)

| Tag    | Kind name                | Parent (base)                     | Purpose                                                                                     | Discipline                    | Band                | Source                          |
|--------|--------------------------|------------------------------------|---------------------------------------------------------------------------------------------|-------------------------------|---------------------|---------------------------------|
| 0x16B  | `KIND_PCIE_HOTPLUG_EVENT`| `KIND_IPC_ENDPOINT = 5`           | PCIe hotplug (slot-power / link-training / present-detect) subscriber.                      | derived                       | 0xFFFFFA30..3F      | `kind_pcie_hotplug_event.pdx`   |
| 0x16C  | `KIND_TB_DOMAIN`         | `KIND_DEVICE = 10`                | Thunderbolt controller / domain root authority.                                             | derived                       | 0xFFFFF9F0..FF      | `kind_tb_domain.pdx`            |
| 0x16D  | `KIND_TB_ROUTE`          | `KIND_IPC_ENDPOINT = 5`           | Path / route through a Thunderbolt topology.                                                | derived                       | 0xFFFFF9A0..AF      | `kind_tb_route.pdx`             |
| 0x16E  | `KIND_DMA_ATTESTATION`   | `KIND_IPC_ENDPOINT = 5`           | Consent-dialog attestation the user is about to admit a foreign DMA-master.                 | derived                       | 0xFFFFF950..5F      | `kind_dma_attestation.pdx`      |

### R36 — display / mode-set (five derived kinds)

| Tag    | Kind name                | Parent (base)                     | Purpose                                                                                     | Discipline                    | Band                | Source                          |
|--------|--------------------------|------------------------------------|---------------------------------------------------------------------------------------------|-------------------------------|---------------------|---------------------------------|
| 0x16F  | `KIND_DISPLAY_ENGINE`    | `KIND_DEVICE = 10`                | Iris Xe display engine (power well + link-clock PLL root).                                  | derived                       | 0xFFFFF7C0..CF      | `kind_display_engine.pdx`       |
| 0x170  | `KIND_DISPLAY_OUTPUT`    | `KIND_DEVICE = 10`                | One physical/virtual output (eDP / DP-Alt / HDMI).                                          | derived                       | 0xFFFFF780..8F      | `kind_display_output.pdx`       |
| 0x171  | `KIND_MODESET_TXN`       | `KIND_IPC_ENDPOINT = 5`           | Atomic mode-set transaction; **LINEAR** (see kind.pdx §KIND_MODESET_TXN).                    | **LINEAR** (no MINT bit)      | 0xFFFFF730..3F      | `kind_modeset_txn.pdx`          |
| 0x172  | `KIND_DISPLAY_MODE`      | `KIND_MEMORY = 4`                 | Timing / resolution / refresh-rate ordinal for a mode set.                                  | derived                       | 0xFFFFF720..2F      | `kind_display_mode.pdx`         |
| 0x173  | `KIND_DISPLAY_PLANE`     | `KIND_MEMORY = 4`                 | Framebuffer plane authority under a modeset.                                                | derived                       | 0xFFFFF6E0..EF      | `kind_display_plane.pdx`        |

### R37 — GPU (four derived kinds)

| Tag    | Kind name                | Parent (base)                     | Purpose                                                                                     | Discipline                    | Band                | Source                          |
|--------|--------------------------|------------------------------------|---------------------------------------------------------------------------------------------|-------------------------------|---------------------|---------------------------------|
| 0x174  | `KIND_GPU_BO`            | `KIND_MEMORY = 4`                 | GPU buffer object (tile + cache class).                                                     | derived                       | 0xFFFFF640..4F      | `kind_gpu_bo.pdx`               |
| 0x175  | `KIND_GPU_VM`            | `KIND_IPC_ENDPOINT = 5`           | Per-process GPU virtual address space (PPGTT).                                              | derived                       | 0xFFFFF5F0..FF      | `kind_gpu_vm.pdx`               |
| 0x176  | `KIND_GPU_CONTEXT`       | `KIND_IPC_ENDPOINT = 5`           | LRC-backed GPU context (execlists); **LINEAR**.                                             | **LINEAR** (no MINT bit)      | 0xFFFFF5A0..AF      | `kind_gpu_context.pdx`          |
| 0x177  | `KIND_GPU_SUBMIT`        | `KIND_IPC_ENDPOINT = 5`           | Single GPU batch-buffer submission (transient); **LINEAR**.                                 | **LINEAR** (no MINT bit)      | 0xFFFFF560..6F      | `kind_gpu_submit.pdx`           |

### R38 — WiFi (four derived kinds)

| Tag    | Kind name                | Parent (base)                     | Purpose                                                                                     | Discipline                    | Band                | Source                          |
|--------|--------------------------|------------------------------------|---------------------------------------------------------------------------------------------|-------------------------------|---------------------|---------------------------------|
| 0x178  | `KIND_WIFI_PHY`          | `KIND_DEVICE = 10`                | WiFi PHY (radio) authority.                                                                 | derived                       | 0xFFFFF470..7F      | `kind_wifi_phy.pdx`             |
| 0x179  | `KIND_WIFI_VIF`          | `KIND_IPC_ENDPOINT = 5`           | Virtual interface (STA/AP/MONITOR mode) under a PHY.                                        | derived                       | 0xFFFFF460..6F      | `kind_wifi_vif.pdx`             |
| 0x17A  | `KIND_WIFI_SCAN_TXN`     | `KIND_IPC_ENDPOINT = 5`           | Active-scan transaction; **LINEAR** (no re-parenting).                                       | **LINEAR** (no MINT bit)      | 0xFFFFF450..5F      | `kind_wifi_scan_txn.pdx`        |
| 0x17B  | `KIND_WIFI_KEY`          | `KIND_MEMORY = 4`                 | PTK/GTK key material; **SEALED** (opaque to userland).                                       | **SEALED** (no op reads material) | 0xFFFFF3E0..EF      | `kind_wifi_key.pdx`             |

### R39 — Bluetooth (two derived kinds)

| Tag    | Kind name                | Parent (base)                     | Purpose                                                                                     | Discipline                    | Band                | Source                          |
|--------|--------------------------|------------------------------------|---------------------------------------------------------------------------------------------|-------------------------------|---------------------|---------------------------------|
| 0x17C  | `KIND_BT_GATT_CONNECTION`| `KIND_IPC_ENDPOINT = 5`           | ATT / GATT connection to a remote peer.                                                     | derived                       | 0xFFFFF320..2F      | `kind_bt_gatt_connection.pdx`   |
| 0x17D  | `KIND_BT_PAIRING`        | `KIND_MEMORY = 4`                 | LE Secure Connections pairing key material; **SEALED**.                                     | **SEALED** (no op reads material) | 0xFFFFF2F0..FF      | `kind_bt_pairing.pdx`           |

### R40 — camera + WWAN (four derived kinds)

| Tag    | Kind name                | Parent (base)                     | Purpose                                                                                     | Discipline                    | Band                | Source                          |
|--------|--------------------------|------------------------------------|---------------------------------------------------------------------------------------------|-------------------------------|---------------------|---------------------------------|
| 0x17E  | `KIND_CSI_CAMERA`        | `KIND_DEVICE = 10`                | MIPI-CSI camera-sensor authority (identity frozen at mint).                                 | derived (QUERY-only ops)      | 0xFFFFF230..3F      | `kind_csi_camera.pdx`           |
| 0x17F  | `KIND_IPU6_STREAM`       | `KIND_IPC_ENDPOINT = 5`           | IPU6 streaming session over a camera.                                                       | derived (QUERY-only ops)      | 0xFFFFF1F0..FF      | `kind_ipu6_stream.pdx`          |
| 0x180  | `KIND_WWAN_MODEM`        | `KIND_DEVICE = 10`                | M.2 WWAN modem device authority (Intel / Fibocom).                                          | derived (QUERY-only ops)      | 0xFFFFF1C0..CF      | `kind_wwan_modem.pdx`           |
| 0x181  | `KIND_MBIM_SESSION`      | `KIND_IPC_ENDPOINT = 5`           | MBIM control session over a WWAN modem.                                                     | derived (QUERY-only ops)      | 0xFFFFF1B0..BF      | `kind_mbim_session.pdx`         |
| 0x182  | `KIND_BT_ADAPTER`        | `KIND_DEVICE = 10`                | Bluetooth adapter on CNVi bus (R39.M1).                                                     | derived (QUERY + STATE ops)   | 0xFFFFF140..4F      | `kind_bt_adapter.pdx`           |
| 0x183  | `KIND_BT_HCI_CHANNEL`    | `KIND_IPC_ENDPOINT = 5`           | HCI transport channel (CMD/EVT/ACL/SCO) bound to one adapter.                               | derived (QUERY-only ops)      | 0xFFFFF130..3F      | `kind_bt_hci_channel.pdx`       |
| 0x184  | `KIND_BT_L2CAP_CHANNEL`  | `KIND_IPC_ENDPOINT = 5`           | Live L2CAP channel (cid, psm, mtu, credits) over an HCI transport slice.                    | derived (QUERY-only ops)      | 0xFFFFF100..0F      | `kind_bt_l2cap_channel.pdx`     |
| 0x185  | `KIND_DISPLAY_TIMELINE`  | `KIND_HW = 14`                    | G1 opener: drm-syncobj-shaped display timeline, one per (engine, output). Signalled by vblank ISR (G1.M1-003), waited on via `wait_scanout` (G1.M1-004). The primitive that makes P1 (no implicit sync) expressible across the G-round. Rights include `R_DPT_WRITE` (signal authority) but `R_MINT` is ABSENT — leaf kind. | derived (QUERY-only ops; signal helper exposed) | 0xFFFFF6A0..AF | `kind_display_timeline.pdx` |
| 0x186  | `KIND_VRR_RANGE`         | `KIND_DISPLAY_MODE = 0x172` (over `KIND_MEMORY = 4`) | G1.M2: Variable Refresh Rate range for one output (min_refresh_mhz, max_refresh_mhz, min_frametime_ns). Minted from the DPCD 0x00080 probe cross-checked against the EDID range descriptor (G1.M2-001 #1432). Consumed by adaptive-sync arming on the modeset transaction (G1.M2-004 #1435). Units are mHz throughout to represent fractional-Hz DP §3.5.2.6 ranges without lossy conversion. | derived (QUERY-only ops) | 0xFFFFF670..7F | `kind_vrr_range.pdx` |
| 0x188  | `KIND_SCANOUT_LEASE`     | `KIND_DISPLAY_PLANE = 0x173` (over `KIND_MEMORY = 4`) | G2 opener: the leased, LINEAR authority to scan out ONE display plane directly for a fullscreen client, without a compositor round-trip. Row tail: `{output_slot:u8, timeline_slot:u8, plane_slot:u16, state:u8, lease_ns_expiry:u64}`. Three states — GRANTED (1), REVOKED (2), EXPIRED (3) — transitioning only out of GRANTED. Mint refuses a zero timeline_slot (P1: implicit sync forbidden), a zero expiry (G2.M3-002 safety-net auto-revoke needs a deadline), and any plane_slot == SL_RESERVED_PLANE_SLOT (P8: pipe 0's primary plane is reserved for the recovery console; refused with SL_MINT_RESERVED = 0xFFFFF615 rather than a generic BAD_PLANE so the operator sees the P8 rule). Rights include neither `R_MINT` — leaf kind — so the direct-scanout tree cannot deepen. The scanout driver (`drivers/dpy/scanout.pdx`) is the ONE other writer of the row table, and only through the `sl_row_transition` selector. | derived (QUERY-only ops; grant/revoke/expiry helpers exposed) | 0xFFFFF611..1D (SHARED with `cache_policy.pdx` 0xFFFFF610/61E/61F markers) | `kind_scanout_lease.pdx` |

### Summary counts and free bands

- **Derived-kind values landed:** 52 (0x140..0x142, 0x150..0x186, 0x188; 0x143..0x14F reserved; 0x187 KIND_VMD_ENDPOINT).
- **Base kinds parented over:** `KIND_MEMORY = 4` (7 kinds), `KIND_IPC_ENDPOINT = 5` (21 kinds), `KIND_DEVICE = 10` (13 kinds), `KIND_IO_PORT = 11` (co-parent for `KIND_OP_REGION`), `KIND_HW = 14` (2 kinds), plus derived-parent chains: `KIND_HW_INTERRUPT`, `KIND_I2C_BUS`, `KIND_USB_DEVICE`, `KIND_USB_INTERFACE`, `KIND_USB_ENDPOINT`, `KIND_MSC_LUN`.
- **LINEAR kinds (5):** `KIND_MODESET_TXN`, `KIND_GPU_CONTEXT`, `KIND_GPU_SUBMIT`, `KIND_WIFI_SCAN_TXN`, plus the identity-LINEAR discipline on `KIND_AUDIO_ROUTE`.
- **SEALED kinds (2):** `KIND_WIFI_KEY`, `KIND_BT_PAIRING`.
- **Linearizable-on-object (1):** `KIND_FW_SESSION` (the arbitration is on the object, not the session cap).
- **QUERY-only kinds (4):** `KIND_CSI_CAMERA`, `KIND_IPU6_STREAM`, `KIND_WWAN_MODEM`, `KIND_MBIM_SESSION` (R40 pattern — identity fields frozen at mint; the only mutator is the revoke helper).
- **Next free derived-kind tag:** `0x189` (opens G3).
- **Adjacent-below free failure band:** `0xFFFFF170..7F` (16-wide; reserved for the R41 opener). `0xFFFFF180..8F` was allocated at R40.M5-001 (#1363) for `core/audit/audit_schema.pdx`.

### Migration table — audit-emit sites still on `drv_audit_emit`

R40.M5-001 (#1363) landed the canonical `audit_schema` wrapper. The
subsystems below still call `drv_audit_emit` directly with their own
principal layout; migrating each to `audit_emit(kind, slot, evt, at,
result, payload_lo)` (with `at = aud_pack_at(actor, target)`) is a
per-round refactor whose landing gate is that the corresponding
subscriber decodes with the schema's `aud_prin_*` unpackers. Order
below is chronological (round the audit-emitting code first landed):

| Round | Subsystem                 | File                                                    | Notes                                                                                |
|-------|---------------------------|---------------------------------------------------------|--------------------------------------------------------------------------------------|
| R29   | driver lifecycle          | `core/driver/lifecycle.pdx`                             | `DRV_AUDIT_EV_HANDOFF` on the committed edge — already uses `kind=0`.                |
| R29   | driver process death      | `core/driver/process_death.pdx`                         | `DRV_AUDIT_EV_RESTART` with outcome distinguishing supervisor / cascade / death.     |
| R29   | driver restart            | `core/driver/restart.pdx`                               | `DRV_AUDIT_EV_CHANDEAD` per channel torn down at restart.                            |
| R30   | ACPI SCI ISR              | `core/acpi/sci_isr.pdx`                                 | GPE storm-retirement + unrouted-event audit records; on the ISR call-target allowlist. |
| R31   | embedded-controller gate  | `core/drivers/ec/ec_access.pdx`                         | `DRV_AUDIT_EV_EC_XACT` per transaction (subject = EC address).                       |
| R37   | GPU register audit        | `core/drivers/gpu/gpu_reg_audit.pdx`                    | Per-register-window audit; owns its own `_graud_*` state.                            |
| R37   | GPU GTT scan-out          | `core/drivers/gpu/gtt_scanout.pdx`                      | Scan-out-tear diagnostic records.                                                    |
| R37   | GPU stress                | `core/drivers/gpu/gpu_stress.pdx`                       | Long-run stress episode records.                                                     |
| R37   | GPU reset                 | `core/drivers/gpu/gpu_reset.pdx`                        | Engine-reset audit records.                                                          |
| R34   | mass-storage LUN          | `core/cap/kind_msc_lun.pdx`                             | Audited outer mint / revoke.                                                         |
| R35   | Thunderbolt consent       | `core/drivers/tb/consent_dialog.pdx`                    | Consent-dialog audit records.                                                        |
| R36   | modeset transaction       | `core/cap/kind_modeset_txn.pdx`                         | Audited outer mint / revoke for a LINEAR kind.                                       |
| R31   | backlight cap             | `core/cap/kind_backlight.pdx`                           | Audited outer mint / revoke.                                                         |
| R39   | BT pairing cap            | `core/cap/kind_bt_pairing.pdx`                          | Audited outer mint / revoke for a SEALED kind.                                       |

Migration is not scoped to a single round because the wrapper is a
CONVERGENCE point rather than a compatibility shim: the underlying ring
in `core/driver/audit_channel.pdx` stays authoritative, the seal + gap
discipline is unchanged, and a subscriber that today reads
`drv_audit_field(back, 4)` and unpacks its own layout keeps working
after any given call site migrates. What migration BUYS is a single
decoder path for every audit-adjacent event across the tree; the
landing bar for each row is one working consumer that reads through
`aud_prin_actor` / `aud_prin_target` / `aud_prin_payload_lo` rather
than the subsystem's private packing.
