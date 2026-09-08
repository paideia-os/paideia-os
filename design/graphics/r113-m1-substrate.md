# R113.M1 — KIND_SURFACE kernel-side substrate (freeze)

Status: FROZEN (osarch pass, 2026-09-08). Supersedes Wave 12 attempts.
Umbrella: R113 GPU-native compositor (#2380). Rollback trigger: #2423.

## 0. Why this doc exists

Wave 12 attempted to land R113.M1-001 (KIND_SURFACE mint+destroy),
M1-002 (surface commit protocol), and M1-004 (format negotiation) in
parallel. The attempt was rolled back for four independent
architectural collisions:

1. **Kind ID clash.** R113 M1-001 proposed `KIND_SURFACE = 0x1B5`,
   but that slot is already claimed by `KIND_HDR_METADATA` (G6.M4-003,
   #2237, `src/user/color/hdr_metadata_kind.pdx:140`). Independently,
   `KIND_SURFACE = 0x1B8` was ALREADY minted at
   `src/user/compositor/surface_kind.pdx:102` (G7.M2-001, Wave-0
   Batch-6, #2246) with three live downstream consumers:
   `window_kind.pdx`, `damage_kind.pdx`, `subsurface_sync.pdx`.

2. **Row layout mismatch.** M1-001's proposed row disagreed with
   M1-002's `SC_OFF_*` externs at every offset past +8; the two
   siblings would not have linked.

3. **Failure-band collision.** M1-002 attempted 0xFFFFEBA0..EBAF,
   byte-for-byte identical to `KIND_TOUCH_CONTACT` (B9-03, #2283,
   `src/user/input_server/touch_contact.pdx:284-303`).

4. **Fingerprint allowlist gap.** `SURFACE COMMIT OK` missing from
   `tools/verify-fingerprint-coverage.sh`.

This document freezes the shape (identity, row layout, rights,
accessors, failure band, pool substrate, bridge policy) so that a
retry of M1-001..M1-005 lands coherent siblings against a single
substrate. **No .pdx code is emitted here** — softarch retry
implements against these frozen values; debugger enforces them.

## 1. Identity (FROZEN — reused from pre-existing landing)

```
KIND_SURFACE                = 0x1B8      // KEYSTONE, frozen G7.M2-001 (#2246)
KIND_SURFACE_PARENT_KIND    = 5          // KIND_IPC_ENDPOINT
```

**Rationale (invariant preservation).** `KIND_SURFACE = 0x1B8` is
already live in three user-space kinds that name it as their
`SS_PARENT_KIND_SURFACE`, `DR_PARENT_KIND`, `WIN_PARENT_KIND`, and
`SS_CHILD_KIND_SURFACE` constants. Minting a second KIND_SURFACE at
a different slot would fork the compositor vocabulary in half.
Per [[feedback-spec-vs-codebase-conflicts]], when a round-plan literal
collides with a landed invariant, preserve the invariant. The R113
M1-001 issue text mentioning any other slot is superseded by this
doc.

**Explicit non-collision list.** These slots are TAKEN and must not
be considered for KIND_SURFACE re-mint:

| Slot     | Kind                          | File                                          |
|----------|-------------------------------|-----------------------------------------------|
| 0x1B5    | KIND_HDR_METADATA             | `src/user/color/hdr_metadata_kind.pdx:140`    |
| 0x1B6    | KIND_TONEMAP_LUT              | `src/user/color/tonemap_kind.pdx`             |
| 0x1B7    | KIND_REFERENCE_DISPLAY        | `src/user/color/reference_display_kind.pdx`   |
| **0x1B8**| **KIND_SURFACE (this doc)**   | **`src/user/compositor/surface_kind.pdx:102`**|
| 0x1B9    | KIND_SURFACE_COMMIT           | `src/user/compositor/surface_commit.pdx`      |
| 0x1BA    | KIND_SUBSURFACE               | `src/user/compositor/subsurface_sync.pdx:231` |
| 0x1C1    | KIND_WINDOW                   | `src/user/compositor/window_kind.pdx:168`     |
| 0x1D9    | KIND_DAMAGE_REGION            | `src/user/compositor/damage_kind.pdx:234`     |

## 2. Row layout — 64 bytes / 8 u64 words (FROZEN)

The kernel-side KIND_SURFACE row is the **authoritative** per-surface
state cell. User-space `surface_kind.pdx` (already landed) holds the
identity/rights/op catalog only; the *runtime data* lives here.

```
Offset  Word     Field                        Encoding
------  -------  ---------------------------  ----------------------------
+ 0     hdr      in_use[63:56]                top byte non-zero == live
                 generation[55:0]             56-bit LAM ABA counter
+ 8     ident    surface_id (u64)             full u64; monotonic, unique
+16     owner    owner_task_id (u64)          full u64; task cap-table id
+24     dims     wh_packed                    w[63:32] | h[31:0]   (u32,u32)
+32     format   format_fourcc[31:0]          DRM_FOURCC (M1-004)
                 flags[63:32]                 u32 (opaque, YCbCr, tile mode)
+40     state    state[63:48]                 u16 surface FSM ordinal
                 next_serial[47:0]            48-bit monotonic commit serial
+48     damage   dx[15:0]|dy[31:16]|          i16/i16/u16/u16 packed
                 dw[47:32]|dh[63:48]          pending damage bbox
+56     buffers  pending_bo[31:0]             u32 KIND_GPU_BO slot (M1-002)
                 current_bo[63:32]            u32 KIND_GPU_BO slot (M1-002)
```

**Alignment.** 8-byte within a row; row pool is 64-byte aligned so
each row also lands on a cache line. `@align(64)` on the `.bss`
declaration.

**Row byte constant:** `SURFACE_ROW_BYTES = 64`.

**Byte-offset constants exported for M1-002..M1-005 consumers:**

```
SRF_OFF_HDR         = 0
SRF_OFF_SURFACE_ID  = 8
SRF_OFF_OWNER       = 16
SRF_OFF_WH          = 24
SRF_OFF_FORMAT      = 32
SRF_OFF_STATE_SER   = 40
SRF_OFF_DAMAGE      = 48
SRF_OFF_BUFFERS     = 56
```

### 2.1 Reconciliation with the previous M1-002 SC_OFF_* contract

Wave 12's M1-002 SC_OFF_* offsets (`{hdr@0, sid@8, serial@16,
pending@24, pending_dmg@32, current@40, current_dmg@48, flags@56}`)
are **discarded**. They doubled the buffer/damage state on the row,
which the compositor model does not need: current-image damage is
NOT tracked on the surface row — it is tracked in KIND_DAMAGE_REGION
rows (`damage_kind.pdx`, slot 0x1D9), which was designed for exactly
this compression. Only *pending* damage lives on the surface row (as
a bbox), consumed at commit and folded into a KIND_DAMAGE_REGION
snapshot for age-aware repaint.

M1-002 softarch retry: swap all `SC_OFF_*` externs for the
`SRF_OFF_*` constants above, and use `surface_row_pending_get/set`
+ `surface_row_current_get/set` accessors (§4) instead of raw
addressing.

### 2.2 Field size rationale

* **surface_id: u64**. The compositor's largest expected working set
  is ~10k live surfaces; 32 bits would suffice, but u64 gives
  headroom to encode `(client_pid:32 | seq:32)` structured ids
  without a second sentinel word.
* **owner_task_id: u64**. Matches the kernel's task-cap-table u64
  slot id encoding.
* **wh: u32,u32**. Enough for 4Gpx × 4Gpx (16k-display heights fit
  comfortably in 16 bits; 32 bits future-proofs to 8k/12k).
* **format_fourcc: u32**. DRM_FOURCC is 4 ASCII bytes packed
  little-endian; a natural u32. See M1-004.
* **state: u16**. Surface FSM has ≤ 8 states (born, has_buffer,
  committed, scanout_pending, destroyed, etc.); 16 bits leaves room
  for a substate enum without a bump.
* **next_serial: u48**. 2^48 = 281 T commits; at 240 Hz sustained a
  surface exhausts 48 bits in ~37 000 years.
* **damage rect: i16/i16/u16/u16**. 32k × 32k window bounds, plus
  negative-origin overscan flourishes (matches damage_kind's rect
  semantics but tighter — for the surface row itself, one bbox is
  enough; per-rect precision lives in KIND_DAMAGE_REGION).
* **pending/current BO: u32 each**. KIND_GPU_BO row-id space is u32.

## 3. Rights bitmask — PRESERVE pre-existing, REJECT briefing

**FROZEN — use the pre-existing user-side surface_kind.pdx values.**

```
R_SURFACE_READ            = 0x001       // generic query
R_SURFACE_INVOKE          = 0x008       // permission to cap_invoke
R_SURFACE_REVOKE          = 0x010       // holder-side revoke
R_SURFACE_QUERY_GEOMETRY  = 0x020       // OP_QUERY_GEOMETRY/SCALE/TRANSFORM/VIEWPORT
R_SURFACE_ATTACH_BUFFER   = 0x040       // OP_ATTACH_BUFFER (pending state)
R_SURFACE_COMMIT          = 0x080       // OP_MINT_COMMIT_TXN
R_SURFACE_DAMAGE          = 0x100       // OP_DAMAGE_ADD (accumulate rects)
R_SURFACE_MINT            = 0x200       // OP_MINT_SUBSURFACE / OP_MINT_WINDOW
R_SURFACE_OBSERVE         = 0x400       // subscribe to KIND_PRESENT_FEEDBACK
R_SURFACE_ALL             = 0x7F9
```

### 3.1 Conflict with the R113 task briefing — flagged

The osarch briefing accompanying issue #2423 proposed a *different*
rights bitmask (`R_SURFACE_QUERY=0x001, R_SURFACE_COMMIT=0x002,
R_SURFACE_DAMAGE=0x004, R_SURFACE_ATTACH=0x008,
R_SURFACE_DESTROY=0x010, RIGHT_MINT=0x200, R_SURFACE_ALL=0x21F`).

Adopting the briefing verbatim would **collide** on every value the
already-landed user-side kinds gate on:

| Briefing name       | Value  | Pre-existing name at that value  | Semantic clash |
|---------------------|--------|----------------------------------|----------------|
| R_SURFACE_QUERY     | 0x001  | R_SURFACE_READ                   | rename OK      |
| R_SURFACE_COMMIT    | 0x002  | (unused; R_SURFACE_COMMIT=0x080) | **CLASH**      |
| R_SURFACE_DAMAGE    | 0x004  | (unused; R_SURFACE_DAMAGE=0x100) | **CLASH**      |
| R_SURFACE_ATTACH    | 0x008  | R_SURFACE_INVOKE                 | **CLASH**      |
| R_SURFACE_DESTROY   | 0x010  | R_SURFACE_REVOKE                 | rename OK      |
| RIGHT_MINT          | 0x200  | R_SURFACE_MINT                   | rename OK      |
| R_SURFACE_ALL       | 0x21F  | R_SURFACE_ALL = 0x7F9            | **CLASH**      |

Per [[feedback-spec-vs-codebase-conflicts]], the invariant (the
landed rights bitmask that three user-side kinds already gate on)
wins. The briefing's proposed values are **rejected**; the pre-
existing values are frozen.

### 3.2 Coarse-grain kernel dispatcher gate

The R113 kernel-side dispatcher expects a 5-way access gate (query,
commit, damage, attach, destroy). That gate is synthesized from the
pre-existing rights via named aliases exported by the substrate:

```
R_SURFACE_KGATE_QUERY   = R_SURFACE_READ | R_SURFACE_QUERY_GEOMETRY  // 0x021
R_SURFACE_KGATE_COMMIT  = R_SURFACE_COMMIT                            // 0x080
R_SURFACE_KGATE_DAMAGE  = R_SURFACE_DAMAGE                            // 0x100
R_SURFACE_KGATE_ATTACH  = R_SURFACE_ATTACH_BUFFER                     // 0x040
R_SURFACE_KGATE_DESTROY = R_SURFACE_REVOKE                            // 0x010
```

M1-001..M1-005 softarch retry gates on these aliases, not on
briefing-named literals.

## 4. Row accessors — frozen ABI (FROZEN)

Every accessor takes a `slot: u64` row index (not a pointer). All
return-shape sentinels use `SURFACE_BAD_SLOT` = 0xFFFFE110 (see §5).

```
// Liveness.
surface_row_valid       : (u64)      -> u64  !{mem} @{}
    // 1 iff slot < SURFACE_ROW_MAX and top byte of hdr is nonzero.

// Row base pointer (post-liveness).
surface_row_addr        : (u64)      -> u64  !{mem} @{}
    // Returns &_surface_table[slot * 64]; returns 0 on invalid slot.
    // Callers MUST prefer typed accessors below; raw addr is exported
    // for M1-002's commit-txn body, which performs an atomic
    // multi-field update no getter can express.

// Serial (state<<48 | next_serial).
surface_row_serial_get  : (u64)      -> u64  !{mem} @{}
    // Returns next_serial (low 48 bits); SURFACE_BAD_SLOT on invalid.
surface_row_serial_set  : (u64, u64) -> u64  !{mem} @{}
    // Write next_serial low-48 preserving state high-16.
    // Returns 0 | SURFACE_BAD_SLOT.

// Buffer double-buffer (pending/current BO slot pair).
surface_row_pending_get : (u64)      -> u64  !{mem} @{}
    // Returns pending_bo (low 32 bits of +56); 0 iff unset.
surface_row_pending_set : (u64, u64) -> u64  !{mem} @{}
    // Write pending_bo (u32); rejects bo >= 2^32.
    // Returns 0 | SURFACE_BAD_SLOT.
surface_row_current_get : (u64)      -> u64  !{mem} @{}
surface_row_current_set : (u64, u64) -> u64  !{mem} @{}
    // Mirror of pending_get/set for high 32 bits of +56.

// Atomic swap: current ← pending, pending ← 0, bump next_serial.
surface_row_swap        : (u64)      -> u64  !{mem} @{}
    // The frame-flip primitive M1-002 commit-txn body and M1-005
    // present-fence handler both call. Returns the NEW next_serial
    // (post-bump) or SURFACE_BAD_SLOT.
```

**Additional accessors M1-001 must export** (used by M1-003/M1-004):

```
surface_row_dims_get    : (u64)      -> u64  !{mem} @{}
    // Returns wh_packed (raw u64). Callers unpack.
surface_row_format_get  : (u64)      -> u64  !{mem} @{}
    // Returns format_fourcc | (flags<<32).
surface_row_format_set  : (u64, u64, u64) -> u64  !{mem} @{}
    // (slot, fourcc, flags) -> 0 | SURFACE_BAD_SLOT. M1-004.
surface_row_damage_get  : (u64)      -> u64  !{mem} @{}
    // Returns raw damage_rect word.
surface_row_damage_or   : (u64, u64) -> u64  !{mem} @{}
    // Union the passed rect (same packed shape) into the row's
    // pending damage bbox. Called by OP_DAMAGE_ADD path.
```

All accessors are ONE-arg or TWO/THREE-arg pure fn (no closures over
`unsafe` blocks). Every asm body uses `damage_kind`-style label
prefix `srow_` to stay out of the paideia-as reserved-keyword set
[[feedback-paideia-as-reserved-labels]].

## 5. Failure taxonomy — 0xFFFFE110..0xFFFFE11F (FROZEN)

**Verified free by tree-wide sweep** (see §5.1 verification). The
briefing suggested 0xFFFFE900..E94F but that page is 55%-consumed by
existing kernel-side kinds. The neighbouring compositor bands are
also saturated:

| Nearby band            | Owner                              |
|------------------------|------------------------------------|
| 0xFFFFEA20..EA2F       | KIND_SUBSURFACE (`subsurface_sync`)|
| 0xFFFFEAA0..EAAF       | KIND_WINDOW (`window_kind`)        |
| 0xFFFFEBA0..EBAF       | KIND_TOUCH_CONTACT (rollback flag) |
| 0xFFFFEBC0..EBCF       | KIND_DAMAGE_REGION (`damage_kind`) |
| 0xFFFFEE40..EE4F       | KIND_COLOR_PROFILE                 |
| 0xFFFFEEF1..EEFA       | KIND_SURFACE user-side mint refuse |

**Kernel-side substrate band (new, freshly claimed):**

```
SURFACE_OK                    = 0
SURFACE_TAIL_ENOSPC           = 0xFFFFE11F   // row pool full at mint
SURFACE_TAIL_BAD_ARG          = 0xFFFFE11E   // op_arg[63:8] != 0
SURFACE_MINT_BAD_OWNER        = 0xFFFFE11D   // owner_task_id == 0
SURFACE_MINT_BAD_DIMS         = 0xFFFFE11C   // w == 0 || h == 0
SURFACE_MINT_BAD_FORMAT       = 0xFFFFE11B   // fourcc not in known set
SURFACE_MINT_BAD_FLAGS        = 0xFFFFE11A   // flags contains unknown bit
SURFACE_MINT_BAD_RIGHTS       = 0xFFFFE119   // rights !subset R_SURFACE_ALL
SURFACE_ATTACH_BAD_BO         = 0xFFFFE118   // BO slot invalid or wrong kind
SURFACE_COMMIT_STALE_SERIAL   = 0xFFFFE117   // caller's serial < row's next_serial
SURFACE_SWAP_NO_PENDING       = 0xFFFFE116   // swap called with pending == 0
SURFACE_STATE_DESTROYED       = 0xFFFFE115   // op on a destroyed surface
SURFACE_DESTROY_ALREADY       = 0xFFFFE114   // double-destroy
SURFACE_GEN_MISMATCH          = 0xFFFFE113   // handle generation < row gen (LAM)
SURFACE_BAD_SLOT              = 0xFFFFE110   // slot out-of-range or not in-use

// Reserved for later use.
// 0xFFFFE112, 0xFFFFE111 — kept in-band for M2 additions

SURFACE_DECODE_BAD            = 0xFFFFFFFFFFFFFFFF  // generic decode reject
```

### 5.1 Sweep verification (2026-09-08)

```
$ grep -rho '0xFFFFE[0-9A-Fa-f]\{3\}' /home/snunez/Development/PaideiaOS/src | sort -u
```

Yielded 1528 unique in-use codes. Python check of 0xFFFFE110..0xFFFFE11F
against that set: 0 collisions. Kernel-side band, grep-clean.

## 6. Row pool substrate (FROZEN)

```
SURFACE_ROW_MAX     = 16                    // slots in pool
SURFACE_ROW_BYTES   = 64                    // per-row size (§2)
SURFACE_ROW_WORDS   = 8                     // per-row u64 count

// Pool total: 16 * 64 = 1024 bytes = 128 u64.
pub let mut _surface_table : [u64; 128] = uninit @align(64)
pub let mut _surface_stats : [u64; 4]   = uninit @align(64)

SURFACE_ST_MINTS    = 0
SURFACE_ST_DESTROYS = 1
SURFACE_ST_REFUSED  = 2
SURFACE_ST_COMMITS  = 3
```

**LAM header discipline:**

* On mint: scan `_surface_table` low-first for a slot with `in_use ==
  0` in the top byte; bump the low-56-bit generation, OR in
  `1<<56` (in_use marker), stamp the row's other 7 words.
* On destroy: increment generation (so a stale handle to the same
  slot is now-invalid), then clear the in_use marker byte.
* On every accessor: LAM path (kernel-side) also checks the caller's
  handle-encoded generation against the row's generation; mismatch
  returns `SURFACE_GEN_MISMATCH`. (The bare-slot accessors above
  skip this — they are for kernel-internal callers who resolved
  handle -> slot at cap_invoke entry. External clients traverse
  handle-to-slot via `cap_table` which performs the LAM check.)

**16 rows** is intentionally small for M1. R113.M2 (window-manager,
6 issues, umbrella #2380) sizes the working-set target at ~48 live
surfaces and will bump `SURFACE_ROW_MAX` (single-constant edit)
after M1 lands and boots.

**Sizing rationale.** 16 rows × 64 bytes = 1 KiB, one page-aligned
allocation. Same working-set posture as `_color_profile_table` (16
× 32 = 512 B) and `_window_table` (32 × 32 = 1 KiB). Boot cost is
one `bss` page.

## 7. Bridge policy — kernel-side substrate vs user-side vocabulary

The kernel-side substrate and the user-side `surface_kind.pdx`
declare the **same** `KIND_SURFACE = 0x1B8` but serve disjoint
purposes:

| Concern                          | User-side (`src/user/compositor/surface_kind.pdx`) | Kernel-side (this doc, R113.M1) |
|----------------------------------|----------------------------------------------------|--------------------------------|
| KIND_ID constant                 | `0x1B8` (frozen G7)                                | `0x1B8` (same value, cross-referenced) |
| Rights bitmask                   | Authority (frozen)                                 | Imports (§3)                    |
| Op catalog + failure taxonomy    | Authority (0xFFFFEEF1..EEFA)                       | Kernel-side band (0xFFFFE110..E11F, §5) |
| Runtime row / row pool           | *(none — vocabulary only)*                         | **Authority** (§2, §6)          |
| Row accessors (`surface_row_*`)  | *(none)*                                           | **Authority** (§4)              |
| Mint / destroy dispatchers       | *(deferred to kernel)*                             | **Authority** (M1-001)          |
| cap_invoke handler               | *(placeholder in user code)*                       | **Authority** (M1-001)          |
| Compositor-facing vocabulary constants (OP_MINT_SUBSURFACE, OP_MINT_WINDOW, etc.) | **Authority** | Imports |

**No duplication of the identity constant.** The kernel-side
substrate references the user-side declaration:

```
// src/kernel/core/cap/kind_surface.pdx (R113.M1-001)
use surface_kind from user.compositor.surface_kind
pub let KIND_SURFACE_ID : u64 = surface_kind.KIND_SURFACE   // 0x1B8, checked
```

(The exact import mechanism follows whatever the existing kernel
files use to reference user-space kind ordinals — see how
`cap_handler_tui_canvas.pdx` cites `KIND_TUI_CANVAS`. If no
cross-boundary reference is possible in paideia-as today, both sides
declare the literal `0x1B8` with a comment naming the other file as
authority, plus a build-time `tools/verify-kind-parity.sh` grep
check.)

**Boundary rule.** The kernel-side dispatcher is the SINGLE writer
to `_surface_table`. User-space compositors READ surface state via
copy-out ops (SURFACE_OP_QUERY_GEOMETRY etc., defined user-side) and
WRITE state only via cap_invoke → kernel dispatcher → typed
accessor. There is no user-space code path that touches
`_surface_table` directly; that boundary is what makes the LAM
generation counter meaningful.

## 8. Fingerprint tags (FROZEN — allowlist owed)

Kernel-side dispatchers emit these on successful mint / destroy /
commit / format-bind:

```
"surface mint ok [legacy: SURFACE MINT OK]\0"         // M1-001
"surface destroy ok [legacy: SURFACE DESTROY OK]\0"   // M1-001
"surface commit ok [legacy: SURFACE COMMIT OK]\0"     // M1-002
"surface fmt bind ok [legacy: SURFACE FMT BIND OK]\0" // M1-004
"surface present ok [legacy: SURFACE PRESENT OK]\0"   // M1-005
```

M1-001 softarch retry MUST also update
`tools/verify-fingerprint-coverage.sh` — either the emitter lands
in the same PR (preferred, coverage passes), or the allowlist gains
5 entries with reason `"R113.M1-00{1,2,4,5} kernel-side surface
substrate; dispatcher emitter lands in follow-on"`. The
allowlist-gap failure that surfaced in Wave 12's SURFACE COMMIT OK
is prevented by landing all 5 tags together.

## 9. Ordered milestone unblock

**R113.M1-001..M1-005 dependency graph (post-freeze):**

```
              +---------------------------+
              |   THIS DOC (freeze)       |
              +---------------------------+
                          |
              +-----------v-----------+
              | M1-001 substrate      |  <-- FIRST landing after this doc
              | - _surface_table      |
              | - surface_row_* ABI   |
              | - surface_mint        |
              | - surface_destroy     |
              | - cap_handler_surface |
              +-----------+-----------+
                          |
       +------------------+---------------+---------------+
       |                  |               |               |
       v                  v               v               v
   +--------+       +--------+       +--------+     +--------+
   | M1-002 |       | M1-003 |       | M1-004 |     | M1-005 |
   | commit |       | damage |       | format |     | present|
   | txn    |       | coalesc|       | negot. |     | fence  |
   +--------+       +--------+       +--------+     +--------+
```

**Order for softarch retry:**

1. **M1-001** (issue #2381) — lands substrate: `_surface_table`,
   `_surface_stats`, all `surface_row_*` accessors (§4), `surface_mint`,
   `surface_destroy`, `cap_handler_surface`. Also lands all 5
   fingerprint tags (§8) and allowlist entry. **This unblocks
   everything else.**
2. **M1-002 / M1-003 / M1-004 / M1-005 in parallel** (issues #2382,
   #2383, #2384, #2385) — each consumes M1-001's row + accessors.
   * M1-002 (commit): calls `surface_row_pending_get`, checks caller
     serial via `surface_row_serial_get`, on success calls
     `surface_row_swap` and emits SURFACE COMMIT OK.
   * M1-003 (damage compression): calls `surface_row_damage_or`
     during OP_DAMAGE_ADD; at commit reads `surface_row_damage_get`
     and folds into KIND_DAMAGE_REGION (`damage_kind.pdx`, 0x1D9,
     already landed).
   * M1-004 (format negotiation): calls `surface_row_format_set` at
     first attach, refuses second attach with different fourcc via
     `SURFACE_MINT_BAD_FORMAT`. Depends on a small `DRM_FOURCC`
     subset table (RGBA8888, XRGB8888, NV12, P010, ARGB2101010) — an
     M1-004-local constant, no kernel-wide table needed at M1.
   * M1-005 (present-fence): registers a KIND_PRESENT_FEEDBACK
     callback keyed on `next_serial`; the scanout-complete IRQ
     handler calls `surface_row_swap` and notifies feedback consumers.

**Downstream M2 sequencing** (R113.M2, umbrella #2380 — window
manager, 6 issues):

* M2-001 (surface role: toplevel) can start in parallel with M1-002
  once M1-001 lands — it extends `window_kind.pdx` (user-side, already
  live) with a *kernel-side* role annotation, and needs only
  `surface_row_valid` from the substrate.
* M2-002..M2-006 (popup, layer-shell, wl_shm fallback, z-order,
  focus) all depend on the M1 batch being fully green.

**M3 (input routing), M4 (rendering path), M5 (session/seat)** —
unchanged by this doc; they depend on M2 completion.

**Blocker cleared by landing this doc:** #2423, #2381, #2382,
#2383, #2384, #2385, and every downstream R113.M2+ issue.

## 10. Retry preconditions (checklist for softarch dispatch)

Before dispatching softarch to retry R113.M1-001:

- [ ] This doc lives at `design/graphics/r113-m1-substrate.md` and
      is committed.
- [ ] Softarch briefing cites this doc as the sole authority for
      row layout, rights, accessors, failure band.
- [ ] Softarch briefing explicitly says: "The rights bitmask in the
      original R113 M1 issue text (R_SURFACE_QUERY=0x001,
      R_SURFACE_COMMIT=0x002, ...) is SUPERSEDED by
      design/graphics/r113-m1-substrate.md §3."
- [ ] Softarch briefing explicitly says: "The row layout must match
      §2 byte-for-byte. Any deviation is rejected."
- [ ] Softarch briefing includes the full `surface_row_*` signature
      table from §4.
- [ ] Softarch briefing cites the failure band 0xFFFFE110..0xFFFFE11F
      from §5, verified free by 1528-code sweep.
- [ ] Softarch briefing cites the 5 fingerprint tags from §8 and
      requires an allowlist entry lands in the same PR.
- [ ] Debugger post-softarch verifies all of the above line-by-line.

## 11. Non-goals (deferred to later milestones)

* **Subsurface tree handling on the surface row.** Subsurfaces live
  on KIND_SUBSURFACE (0x1BA, `subsurface_sync.pdx`) edges, not on
  the surface row. The row does not carry parent/child pointers.
* **A11y binding on the surface row.** A11y trees bind to
  KIND_WINDOW (0x1C1), not KIND_SURFACE. The row does not carry an
  a11y ref.
* **Color profile ref on the surface row.** The R113 briefing named
  a KIND_COLOR_PROFILE cross-ref (mirroring surface_kind.pdx §Section
  1 mint-time gate). That gate lives in the user-side mint body,
  not on the row — the kernel-side row carries no color-profile
  slot. Color profiles bind to *commits*, not to surfaces, via a
  future M1 extension (deferred to R113.M4 rendering path).
* **DMA-BUF import.** Deferred to R113.M4 (rendering path).
* **Multi-plane format support** (NV12/P010 as separate planes) —
  M1-004 handles fourcc identity only; per-plane BO tracking is a
  KIND_GPU_BO concern, not a surface-row concern.
