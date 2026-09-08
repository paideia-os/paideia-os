# FrameCaptureView@0.1 — semantic-pipe schema

**Round:** R113.M7 (parent compositor+capture wave)
**Landing:** R113.M7-032 (paideia-os #2412) — schema declaration ONLY.
**Sibling:** R113.M7-033 (pool substrate + emitter; separate landing).
**Cross-repo consumers:** libpdx-semantic-pipe, postui, pdxwatch, svc-compositor.
**Related schemas:** SurfaceGeometry@0.1 (compositor), PdxFsDirEntry@0.1
(filesystem) — both live off of `svc.schema-registry`.

## 1. What this schema names

`FrameCaptureView@0.1` is the wire-record every consumer of the
compositor's frame-capture stream reads.  It carries just enough state
for a downstream tool to correlate one captured frame back to (a) the
surface it belongs to, (b) the region of that surface that changed,
(c) the pixel format the capture backend used, and (d) the wall-clock
moment the compositor decided to snapshot it — nothing else.

The tool set that consumes these records covers three concrete cases
that the R113 GPU-native compositor wave already anticipated:

1. `pdxwatch` renders a live per-surface capture stream for the
   dev-shell "see what a program is drawing" workflow.  It reads
   `frame_id` for de-duplication, `timestamp_ns` for pacing, and the
   `width/height/stride/format` quartet to point its own decoder at the
   right pixel layout.
2. `postui-record` (a follow-on tool, spec TBD) captures long-running
   surface streams to disk for post-hoc UI review.  It reads
   `surface_id` for grouping, `bbox_packed` for damage-aware storage
   compression, and `timestamp_ns` for the file's own timeline.
3. `svc-compositor` itself uses the record shape when re-broadcasting
   captured frames over the `KIND_FRAME_CAPTURE` (0x1BD) cap it mints
   at the M7-033 pool-substrate landing.  Every emitter serializes into
   this exact 96-byte record; every consumer deserializes from it.

Naming a schema (rather than passing each field as a separate wire
argument) is what lets a captured frame stream traverse the semantic-
pipe cleanly: the daemon `svc.schema-registry` resolves the string
`FrameCaptureView@0.1` to a `schema_id`, and downstream consumers
verify the incoming record's tag matches `FCV_SCHEMA_TAG` before
touching a single byte.

## 2. Wire form (96-byte fixed-shape record)

The record is a fixed 96 bytes on the wire, packed with no compiler-
inserted padding.  All multi-byte fields are little-endian x86_64
native order (the semantic-pipe is a same-host IPC; there is no
byte-order negotiation because there is no cross-architecture path
that would benefit from one).

```
FrameCaptureView@0.1 (FCV_RECORD_BYTES = 96)

  offset  size  field         type   meaning
  ------  ----  -----         ----   -------
    +0      8   frame_id      u64    monotonic sequence per compositor
                                     boot; 0 is reserved (sentinel).
    +8      8   timestamp_ns  u64    TSC-derived wall-clock nanoseconds
                                     at the moment vblank_handler queued
                                     the capture; the compositor's own
                                     TSC-to-ns calibration provides it.
   +16      8   surface_id    u64    KIND_SURFACE row id the captured
                                     frame belongs to; consumers correlate
                                     against surface_row_addr(surface_id).
   +24      8   bbox_packed   u64    packed damage bbox: bits [15:0] x,
                                     [31:16] y, [47:32] w, [63:48] h.
                                     (matches damage_region.pdx pack.)
   +32      4   format        u32    DRM_FOURCC (see surface_format.pdx
                                     N_SUPPORTED table); consumers check
                                     buffer_format_compat before decode.
   +36      4   width         u32    frame pixel width  (>= 1).
   +40      4   height        u32    frame pixel height (>= 1).
   +44      4   stride        u32    bytes per row (>= width * bpp).
   +48      4   reserved[0]   u32    reserved (zero on emit).
   +52      4   reserved[1]   u32    reserved (zero on emit).
   +56      4   reserved[2]   u32    reserved (zero on emit).
   +60     36   tail_pad      u8[36] reserved tail padding (zero on emit;
                                     see §2.1 for the sizing rationale).
```

Total: 32 (four u64 words) + 16 (four u32 damage/geometry words) + 12
(three explicit `reserved` u32 slots) + 36 (tail padding) = 96 bytes.

### 2.1  Why 96 bytes, not 60

The eleven declared fields total 60 bytes.  The record is padded to
96 bytes for three reasons:

1. **Cache-line pair alignment.**  96 bytes = 1.5 x 64-byte cache
   lines, and every emitter/consumer buffer holds records at a 32-byte
   stride that aligns each to a cache-line boundary.  A follow-on
   scatter-gather emitter can hand the whole record as a single I/O
   descriptor.
2. **Forward-compatible extension room.**  The M7-033 pool substrate
   will need one, and later landings will need more, per-frame
   telemetry slots (capture-backend id, GPU BO handle, dma-buf fd,
   present-fence cookie).  Bumping `<min>` for every new field would
   force every consumer library to re-bind; the schema-registry's
   in-place-add refusal (see `design/terminal/schema-registry.md` §5)
   makes reserving tail bytes the only cheap forward path.
3. **BLAKE3 alignment.**  When paideia-as ships the BLAKE3 intrinsic
   (see schema-registry §3), the wire-time fingerprint moves from an
   opaque `FCV_SCHEMA_TAG` u64 to `BLAKE3(name || 0x00 || packed_field_
   descriptors)[0..8]`.  Keeping the total record size a multiple of
   both 32 and 8 lets the BLAKE3 compressor consume it in whole blocks.

Tail bytes are written as zero on every emit; consumers ignoring the
tail is legal today, and any future field lands with a `<min>` bump so
old consumers keep reading the old (bytes-preserved) shape.

## 3. Schema tag

`FCV_SCHEMA_TAG = 0x4657434672616D46`

The 64-bit fingerprint every consumer verifies before touching a
`FrameCaptureView` byte.  The mnemonic is `FrameCFW` (little-endian
8-char, per the compositor-frame-capture-view naming convention);
the exact hex value is normative and lives verbatim in
`src/kernel/core/graphics/frame_capture_schema.pdx` §Constants so a
grep-verify against the value catches any accidental drift.

Once paideia-as ships BLAKE3 (schema-registry §3), the tag rotates
to the BLAKE3-derived form in the same release that flips every
schema-registry entry.  Bumping `<min>` at that point is mandatory:
the wire fingerprint changes so the schema is a new schema.

## 4. Capability kind

`KIND_FRAME_CAPTURE = 0x1BD`

Derived over `KIND_IPC_ENDPOINT` (= 5) at the M7-033 substrate
landing.  Slot allocation verified against the R101/R113 kind-id map
(`design/graphics/r101-kernel-plan.md` §5 + `src/kernel/core/cap/
kind_session.pdx` §KIND-ID SLOT ALLOCATION):

```
  0x1B0  KIND_PAGE_FLIP           (R104.M4-001)
  0x1B1  KIND_HOTPLUG_CHANNEL     (R105.M4-001)
  0x1B2  KIND_SCHEMA_HANDLE       (R90-XREPO.012.M3-001)
  0x1B3  KIND_VOLUME_SNAPSHOT     (LV11.M3-001)
  0x1B4  KIND_KEK                 (LV11.M5-001)
  0x1B5  KIND_HDR_METADATA        (user G6 Batch-1)
  0x1B6  KIND_TONEMAP_LUT         (user G6 Batch-1)
  0x1B7  KIND_REFERENCE_DISPLAY   (user G6 Batch-1)
  0x1B8  KIND_SURFACE             (R113.M1-001)
  0x1B9  KIND_SURFACE_COMMIT      (user G6 Batch-2)
  0x1BA  KIND_SUBSURFACE          (user subsurface_sync.pdx)
  0x1BB  reserved
  0x1BC  KIND_SESSION             (R113.M5-022)
  0x1BD  KIND_FRAME_CAPTURE       (THIS LANDING, R113.M7-032)
  0x1BE  KIND_CAPTURE             (R113.M7-036, #2416 -- capture-
                                   consent cap; distinct from this
                                   schema's endpoint)
  0x1BF  free
```

The identity is reserved AT THIS LANDING; the mint gate, row pool,
and cap-invoke dispatcher land at M7-033 alongside the emit path from
`vblank_handler`.  Consumers hold the cap purely as a receive handle
(no rights let a ring-3 caller mint a fresh row directly; the
compositor mints one per configured capture subscription).

`KIND_FRAME_CAPTURE` (this landing) MUST NOT be confused with
`KIND_CAPTURE` (0x1BE, R113.M7-036, paideia-os #2416, sibling wave):
the two are orthogonal concerns that a well-behaved consumer holds
BOTH of.  `KIND_CAPTURE` is the consent gate — a screenshot or
screencast requester proves it holds a live grant against the source
surface before the compositor releases pixel data at all.
`KIND_FRAME_CAPTURE` is the endpoint carrying `FrameCaptureView@0.1`
records once that consent gate has passed.  A consumer that holds
`KIND_FRAME_CAPTURE` without `KIND_CAPTURE` receives an endpoint that
will never deliver a record; the compositor's emit-side gate short-
circuits against the missing consent.  Splitting the two capabilities
this way keeps the consent policy (owned by the M7-036 broker) fully
decoupled from the record shape (owned by this schema).

## 5. Failure taxonomy

Band: `0xFFFFE2B0..0xFFFFE2BF`.  Sweep-verified 2026-09-08 against
`src/**/*.pdx` (empty match).  Neighbouring bands in the 0xFFFFE2xx
page (per `src/kernel/core/graphics/composite_plan.pdx` file header
§FAILURE TAXONOMY):

```
  0xFFFFE200..E20F   (free)
  0xFFFFE210..E21F   (free)
  0xFFFFE220..E22F   R113.M4-017 DMA-BUF import
  0xFFFFE230..E23F   (free, reserved for M4 follow-on)
  0xFFFFE240..E24F   R113.M4-020 COMPOSITE PLAN
  0xFFFFE250..E27F   (assorted M5 bands)
  ...
  0xFFFFE2A0..E2AF   (free)
  0xFFFFE2B0..E2BF   R113.M7-032 FRAME CAPTURE SCHEMA   (THIS FILE)
  0xFFFFE2C0..E2CF   (free, reserved for M7-033 pool substrate)
```

The schema-declaration landing itself is inert (it emits a boot
fingerprint and defines constants); no code paths in M7-032 return a
failure code.  The band is reserved so the sibling M7-033 landing
(which does add mint / dispatch / consume gates) has a pre-audited
range to draw from:

```
  0xFFFFE2BF  FCV_BAD_TAG          -- record header tag != FCV_SCHEMA_TAG
  0xFFFFE2BE  FCV_BAD_VERSION      -- version fields not (0, 1)
  0xFFFFE2BD  FCV_BAD_SURFACE      -- surface_id not live in KIND_SURFACE pool
  0xFFFFE2BC  FCV_BAD_FORMAT       -- format not in surface_format.pdx table
  0xFFFFE2BB  FCV_BAD_DIMS         -- width == 0 or height == 0
  0xFFFFE2BA  FCV_BAD_STRIDE       -- stride == 0 or stride < width * bpp
  0xFFFFE2B9  FCV_BAD_BBOX         -- bbox outside declared frame extent
  0xFFFFE2B8  FCV_BAD_TIMESTAMP    -- timestamp_ns < previous frame's
  0xFFFFE2B7  FCV_RESERVED_NONZERO -- reserved slots or tail-pad non-zero
  0xFFFFE2B6  FCV_TAIL_ENOSPC      -- capture-pool row-alloc full
  0xFFFFE2B0..0xFFFFE2B5              reserved for M7-033 follow-on
```

The five reserved codes at the low end of the band give M7-033 room to
add per-consumer subscription / drop-count / back-pressure error
returns without a fresh sweep.

## 6. Fingerprint (boot-visible)

`FRAME CAPTURE SCHEMA OK size=96`

Emitted once per boot by `frame_capture_schema_init` (called from
`kernel_main.pdx`'s init cascade) via `klog_s1_x1` with a single hex
KV pair `size=<FCV_RECORD_BYTES>`.  R51 wire form:

```
frame capture schema ok [legacy: FRAME CAPTURE SCHEMA OK] size=0x60
```

The tag is BOOT-VISIBLE.  Because no consumer of a
`FrameCaptureView@0.1` record exists yet in the default 14-mode smoke
matrix (both emitter and consumer land at M7-033), the fingerprint
sits on the `tools/verify-fingerprint-coverage.sh` allowlist with a
rationale line that names M7-033 as its natural pin-in-cascade landing.

The single hex KV was chosen over a wider record-shape summary
(`size=96 tag=0x... kind=0x1BD`) so a future golden line asserting
the fingerprint has one stable value (the record size) to pin without
also having to pin the tag or kind-id, which drift under the version
bump described in §3.

## 7. Sequencing

M7-032 (this landing) is DECLARATION-ONLY:

- `src/kernel/core/graphics/frame_capture_schema.pdx` declares
  constants (`KIND_FRAME_CAPTURE`, `FCV_SCHEMA_TAG`,
  `FCV_RECORD_BYTES`, per-field offsets, failure taxonomy).
- `frame_capture_schema_init` emits the boot fingerprint.
- No row pool, no mint gate, no cap-invoke dispatcher, no emit path.

M7-033 (sibling, deferred) lands the substrate:

- `_fcap_rows` pool + row layout.
- `frame_capture_mint` / `frame_capture_destroy`.
- `cap_handler_frame_capture` dispatcher (attached at
  `cap/invoke.pdx`'s 0x1BD arm).
- `frame_capture_emit_from_vblank` — the hook `vblank_handler` calls
  after `composite_plan_execute` completes.
- Schema-registry registration: at first-mint time the compositor
  calls `sreg_register("FrameCaptureView@0.1", ..., &FCV_SCHEMA_TAG,
  ...)` and stores the returned `schema_id` in the row.

Splitting the two landings this way lets the schema value AND the
`KIND_FRAME_CAPTURE` slot number reach every downstream repo
(`libpdx-semantic-pipe`, `postui`, `pdxwatch`) at M7-032 review time;
they can begin their own coding against a frozen shape while the
pool substrate finishes.

## 8. Encoder discipline (pdx v0.36+ pitfalls)

The `frame_capture_schema.pdx` file itself has zero asm bodies beyond
the boot fingerprint emitter; the following notes are for the sibling
M7-033 landing that consumes the same constants:

- The `FCV_SCHEMA_TAG` value (0x4657434672616D46) does NOT fit an
  imm32 — every load stages through `mov r64, imm64` (movabs).  Same
  discipline as `surface_format.pdx`'s tile-modifier constants.
- The `KIND_FRAME_CAPTURE` (0x1BD) constant is > 0xFF — every
  `cmp reg, 0x1BD` stages the value through r10/r11 first (same
  discipline as kind_nic / kind_tui_canvas / kind_schema_handle
  document at their file headers).
- Record-size constant 96 is imm8 and safe as a direct immediate.
- No `test rN, rN` — zero-checks use `cmp rN, 0` + `je/jne` per the
  repo-wide encoder-pitfall memo.

## 9. Cross-repo contract summary

```
Repo                        Consumes                        As of
----                        --------                        -----
libpdx-semantic-pipe        FCV_SCHEMA_TAG, FCV_RECORD_     M7-032
                            BYTES, per-field offsets        (this)
paideia-os (svc-compositor) all constants + KIND_FRAME_     M7-033
                            CAPTURE mint API                (deferred)
postui                      per-field offsets only          M7-033+
pdxwatch                    FCV_SCHEMA_TAG only             M7-033+
                            (used at bind-by-name time)
```

The library-side facade `libpdx-semantic-pipe::FrameCaptureView` will
mirror the kernel constants one-for-one; a companion sweep at
libpdx-semantic-pipe cuts a v-tick that publishes the client-facing
struct definition.  Both sides agree on 96-byte fixed shape from this
landing forward.
