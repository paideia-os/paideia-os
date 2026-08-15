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
| 2026-08-12 | R29.M2 | #1024 | Elaborator witness — a driver claiming `!{Mmio}` without holding `paideia.mmio` fails elaboration (paideia-as gate `c768935`). No paideia-os code touched. |
| 2026-08-12 | R29.M2 | #1025 | Landed `driver_hotplug_channel` schema constants. Session-typed stream (bus driver → userspace driver-loader) with two v1 opcodes — `DRV_HP_OP_DEVICE_ARRIVED = 0x01` (24-byte record carrying `{bdf, vendor, device, class_code, device_cap:Cap<KIND_DEVICE>}`) and `DRV_HP_OP_DEVICE_DEPARTED = 0x02` (8-byte record carrying `{bdf, reason}`). Constants in `src/kernel/core/driver/hotplug_schema.pdx`; wire spec at `design/ipc/driver-hotplug-schema.md`. Wire encoders / decoders deferred to R29.M3 registry v2 (per doc §7 rationale). |
| 2026-08-12 | R29.M2 | #1026 | Landed driver lifecycle FSM fuzz witness — 1000-iter Knuth LCG (A=0x5851F42D4C957F2D, C=0x14057B7EF767814F, seed=0x0BADBEEFC0FFEE01) over 3-bit (cur, new) slices from LCG state bits [42:40] / [50:48] (values in [0..8) so ~25% out-of-range). Per-iter asserts the transition-whitelist predicate (`driver_lifecycle_transition_valid`) agrees with the stateful primitive (`driver_lifecycle_transition`) on both direction (rc == 0 iff predicate == 1) and state-mutation (state == new on OK; state unchanged on any error). Witness at `kernel_main.pdx §driver_lifecycle_fuzz_witness` — fingerprint `R29 LIFECYCLE FUZZ OK`. Pure test artifact; no new kernel functionality. |
| 2026-08-12 | R29.M2 | #1027 | Landed `driver_lifecycle_channel` schema constants. Request/reply RPC (userspace driver-lifecycle-supervisor → driver process) with six v1 commands — `DRV_LC_OP_START/INIT_DONE/SUSPEND/RESUME/HANDOFF_BEGIN/STOP = 0x01..0x06` — each mapping 1:1 onto an FSM edge from the R29.M2-001 whitelist. Ack rep is 8 bytes `{driver_slot:u16, rc:u32}` with error codes `DRV_LC_ACK_ERR_{BAD_SLOT, INVALID_TRANS, TIMEOUT, DEVICE_GONE, CAP_MISSING, INTERNAL}` that mirror `DRIVER_LIFECYCLE_ERR_*`. Reply-bit-7 convention shared with `ipc/frame.pdx`. Constants in `src/kernel/core/driver/lifecycle_schema.pdx`; wire spec at `design/ipc/driver-lifecycle-schema.md`. R29.M2-004 fuzz witness (#1026 same wave) exercises the kernel-side coupling directly; wire encoders and canonical example driver (`lpss_uart`) deferred to R30 (per doc §7 rationale). Closes R29.M2. |
| 2026-08-14 | R29.M5 | #1036/#1037 | Landed `KIND_DMA_DOMAIN = 0x142` — **renamed from the `KIND_HW_DMA_DOMAIN` planning skeleton and re-based from `KIND_HW` (14) to `KIND_MEMORY` (= `KIND_PAGE`, 4)** per softarch §3 R29 and the issue text; rationale is that a DMA domain is a memory-access scope, so the mint gate must require memory authority, not device authority. Added the `KIND_MEMORY = 4` name binding in `kind.pdx` so document vocabulary and runtime enum stop drifting. Row-indirection tail via `_dma_domain_table` (32 rows × 32 B) encoding `{iommu_ctx_id:u32, bus_dev_fn:u16, capacity_bytes:u64, coherency:u8, parent_slot:u8}`. Canonical tail-word encoder `dma_tail_pack` + word-level and row-level decoders (#1037), plus canonical debug printer `dma_domain_debug_print` (five-line `DMA DOMAIN ROW` record) reachable via `OP_DEBUG_PRINT`. Rights bitmask `R_DMA_ALL = 0x618` (INVOKE/REVOKE/MINT/OBSERVE) with **per-op** gating rather than a single entry gate. Full mint / revoke / cascade-revoke API + dispatch handler in `src/kernel/core/cap/kind_dma_domain.pdx`; dispatch branch in `invoke.pdx`; chatter tag `cap_dma_dom_msg` in `tags.pdx`. Failure taxonomy `0xFFFFFFD5..0xFFFFFFDF`, disjoint from `HW_INT_*` and `MSIX_*`. Boot witness `kernel_main.pdx §kind_dma_domain_witness` (21 sub-tests) — fingerprint `R29 KIND_DMA_DOMAIN OK`. Opens R29.M5. |
| 2026-08-15 | R29.M7 | #1044/#1047/#1048 | Landed cascade restart — supervisor tree, restart budget, ChannelDead. Supervisor tree is recorded in the driver descriptor's previously-reserved `[+40]` **supervision word** (`parent_slot:5 | parent_present:1 | perm_failed:1 | restart_count:8 | incarnation:8 | window_start_coarse:40`), with `driver_sup_set_parent` refusing any edge that would close a cycle so every subtree walk is total. Restart strategy is **one-for-one across siblings with a mandatory downward cascade**: kill set = subtree(D), restart set = {D}; descendants are stopped and unregistered rather than restarted, because their capabilities were minted against an incarnation that no longer exists and the restarted D re-enumerates them. Justified by R29's own capability partitioning — siblings share no writable object (one `KIND_DMA_DOMAIN` each per D1.b), so one-for-all buys nothing; and a child's authority is *derived* from its parent's, so the downward cascade is forced rather than chosen. `DRIVER_LIFECYCLE_TABLE` widened `0x00000020101A1C02` → `0x00000020101A1C12` to add the `Init -> Stopping` abandon edge (already the documented intent of the R29.M5-003 signature-failure path, previously unreachable) so `driver_restart_force_stop` is total over the state space. Re-arming is **not** an FSM edge: `Stopped` stays terminal, and `driver_table_rearm_incarnation` retires one incarnation and installs the next, gated on Stopped + no-live-DMA-domain + not-permanently-failed. Budget: 5 restarts per 32768 coarse ticks (TSC >> 20, ≈11 s at 3 GHz) carried in the supervision word; exceeding it latches `perm_failed`, leaving the node in the FSM's own terminal state — escalation is the *absence* of a re-arm, and its terminality is enforced at the store rather than by supervisor convention. ChannelDead: the endpoint row's reserved `[+40]` becomes a **driver binding word** (`driver_slot:5 | bound:1 | dead:1 | incarnation:8`); `driver_restart_reap_endpoints` latches `dead` before detaching each parked waiter and wakes it, and both `sys_ipc_recv_body` and `sys_ipc_send_body` gate on `endpoint_is_dead` returning `-ECONNRESET` (104). Stale capabilities cannot attach to a restarted instance: `endpoint_bind_driver` refuses a dead row (`EP_BIND_ERR_DEAD`) with no revival operation, and `endpoint_attach_ok` additionally requires the incarnation to match. Three audit events (`DRV_AUDIT_EV_RESTART/ESCALATE/CHANDEAD` = 4/5/6, all `kind = 0` so cap-kind balances stay exact). New `src/kernel/core/driver/restart.pdx`; design doc `design/drivers/cascade-restart.md`. Boot witness `kernel_main.pdx §r29_cascade_restart_witness` (40 sub-tests over a four-node tree) — fingerprint `R29 CASCADE RESTART OK`. |

---

## References

- `design/capabilities/linearity-and-tags.md` §3.1 — base kind hierarchy.
- `design/capabilities/derived-kinds.md` — Phase-2 derived-kind catalog.
- `design/roadmap/next-wave-synthesis.md` §10 D6 — slot 14 promotion decision.
- `design/roadmap/next-wave-softarch.md` §3 R29 — driver-framework maturation
  round detail; §4 for GPU/display timeline chain.
- `src/kernel/core/cap/kind.pdx` — the KIND_* enum.
- `src/kernel/core/cap/invoke.pdx` — dispatch table.
