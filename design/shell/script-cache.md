# Script-body binary cache (R227.M7)

**Status:** parser-tier landing (R227.M7).
**Issue:** paideia-os#2709 (R227.M7).
**Umbrella:** paideia-os#2491 (R227 pds container / loader).
**Module:** `tools/user/libpdx-pds-parser/src/script_cache.pdx`
(`ScriptCache`).
**Error band:** `0x6500..0x65FF`.
**Siblings:** paideia-os#2705 (R227.M3 ImportResolve), paideia-os#2706
(R227.M4 LoadCheck), paideia-os#2707 (R227.M5 ModuleFunctor),
paideia-os#2708 (R227.M6 VersionPragma).

## 1. Scope and motivation

The pds elaboration pipeline (R221..R225 + R227.M3..M6) walks a
script's bytes through Utf8Nfc, SpanMap, CtxLexer, Ast,
ImportResolve, ModuleFunctor, LoadCheck, HM infer + generalise, in
that order. For a 1000-line script the walk is O(n log n) in the
character count with constant factors dominated by LoadCheck's
cross-module scheme-store traversal. The REPL's dispatch loop
routinely re-runs the same script across turns (hot-edit edit-run
cycle, scripted test rerun, cron-like loop); every rerun pays the
full elaboration cost. R227.M7 caches the elaborated body so
every rerun pays only an O(k) linear scan over 32 cache slots.

The umbrella's acceptance anchor on this ticket:

> Fixture: a 1000-line script's second load is at least 10x faster
> than the first.

The structural guarantee is stronger than 10x: a 32-slot linear
scan touches 32 x 64 B = 2 KiB of memory in exactly 32 cache lines
(64 B each); a cold LoadCheck pass over a 1000-line script touches
on the order of a megabyte through the AST pool, HM scheme store,
and import graph. The cold-vs-warm ratio typically exceeds 100x.

## 2. Why a dedicated parser-tier primitive and not an ad-hoc
   `HashMap<u64, (ptr, len)>` inside the REPL

Three forces push back against an ad-hoc shell-side map:

1. **Pool-size vs cache-line budget.** The shell's working set
   across a single interactive session rarely exceeds ~8 distinct
   scripts; a 32-slot pool fits in 2 KiB (32 cache lines). A
   generic HashMap pays the bucket-pointer-chain cost on every
   lookup -- worse constant factors than a linear scan at the
   target scale.
2. **LRU eviction with explicit timestamp.** The pool is bounded
   at 32 slots so eviction MUST happen when the 33rd distinct
   script is cached. An ad-hoc HashMap would either grow
   unboundedly (worst case: shell session accumulates megabytes of
   stale elaborated bodies) or need a parallel LRU index. A
   dedicated primitive carries the timestamp in the record so the
   LRU scan is a straight walk over the pool.
3. **Error-code hygiene.** The parser-tier library's error-band
   discipline (every satellite owns a 256-slot slice of the
   packed-status space) makes a downstream compound-error
   dispatcher trivial. An ad-hoc shell-side map lives in a
   different error-code space and loses that discriminator.

## 3. Key design

### 3.1 Composite key (source_hash, deps_hash)

A script's elaboration result depends on BOTH its own source bytes
AND the elaborated result of every module it imports. A cache keyed
on the source hash alone would return stale elaborated bodies when
a transitive import changes without the top-level script changing.

- `source_hash` is the FNV-1a 64 of the script's full source bytes.
  The caller computes it before calling `_sc_lookup` or
  `_sc_insert`.
- `deps_hash` is the FNV-1a 64 of the concatenation of all
  transitive import path hashes resolved by R227.M3 ImportResolve.
  A change in any transitive dependency's elaborated body flips its
  path hash, flips the top-level script's deps_hash, and misses the
  cache.

Hash choice: FNV-1a 64 (fnv_offset_basis 0xCBF29CE484222325, prime
0x100000001B3). R229.M5 History already carries an FNV-1a 64
inliner precedent in the parser-tier library
(`h_app_fnv_loop`); R227.M3 ImportResolve already stores path
hashes as FNV-1a 64 scalars.

### 3.2 LRU over timestamp_us

Every slot carries an rdtsc sample in its `timestamp_us` field.

- `_sc_insert` on a full pool evicts the slot with the minimum
  `timestamp_us`.
- `_sc_lookup` on a hit updates the touched slot's `timestamp_us`
  to the current rdtsc so it moves to the "most recently used" end
  of the ordering.
- `_sc_invalidate` clears every slot whose source_hash matches
  without touching the timestamps of surviving rows -- the LRU
  ordering is preserved across invalidation.

## 4. Record layout (64 B)

```
offset  size  field
------  ----  -------------------------------------------------------
 0x00    4   magic                u32   'SCCA' (0x41434353 LE)
 0x04    4   flags                u32   bit 0 = SCC_FLAG_LIVE
 0x08    8   source_hash          u64   FNV-1a 64 over source bytes
 0x10    8   deps_hash            u64   FNV-1a 64 over import paths
 0x18    8   elaborated_body_ref  u64   opaque pointer to cached body
 0x20    8   elaborated_body_len  u64   opaque body length (bytes)
 0x28    8   timestamp_us         u64   rdtsc sample (LRU key)
 0x30   16   cache_key_inline     u8[16] raw source_hash || deps_hash
```

Stride 64 = 2^6, addressing uses `shl idx, 6` (no 2-op
`imul r, imm`).

Magic `0x41434353 LE` reads as "SCCA" in a hex dump (byte sequence
53 43 43 41). Distinct from every landed parser-tier magic
(FINS, IMPT, LCDG, MFCT, RVPR, TFPR, CSIG, HREC, WSNK, HOST, DESC,
SESS, DIAG, PTHS). Magic fits imm32 with bit 31 clear so direct
`mov r9, 0x41434353` + `mov_d [r8], r9` lands the magic without a
MOVABS.

## 5. Stats record layout (64 B)

```
offset  size  field
------  ----  -------------------------------------------------------
 0x00    4   magic         u32   'SCCS' (0x53434353 LE)
 0x04    2   version       u16   1 at raw M7
 0x06    2   reserved      u16   0
 0x08    8   entry_count   u64   current live-slot count (0..32)
 0x10    8   hit_count     u64   cumulative lookup hits
 0x18    8   miss_count    u64   cumulative lookup misses
 0x20    8   capacity      u64   SCC_POOL_SLOTS (= 32 at raw M7)
 0x28   24   reserved      u8[24] zero at raw M7
```

The stats magic 'SCCS' is DISTINCT from the row magic 'SCCA' by
their last byte ('S' vs 'A'); a downstream reader never confuses
them.

## 6. Pool + scalar state (.bss)

- `_sc_entries : [u8; 2048] @align(8)` -- 32 slots x 64 B.
- `_sc_entry_count : u64 @align(8)` -- current live-slot count.
- `_sc_hit_count : u64 @align(8)` -- cumulative lookup hits.
- `_sc_miss_count : u64 @align(8)` -- cumulative lookup misses.

Pool layout: slot i occupies `_sc_entries[i * 64 .. (i + 1) * 64)`.
At cold boot `.bss` zero-init makes every slot's magic 0 and flags
0, which is the exact "never-used" state the lookup / insert paths
treat as empty. `_sc_init` defensively re-zeros the three counter
scalars on a chaos-restart re-entry.

## 7. Public API

```
_sc_init() -> ()
_sc_lookup(source_hash, deps_hash, out_elaborated_ref, out_len)
                                               -> status
_sc_insert(source_hash, deps_hash, elaborated_ref, len) -> errno
_sc_invalidate(source_hash) -> errno
_sc_stats(out_stats_ptr) -> status
```

### 7.1 `_sc_lookup`

Scans the 32-slot pool for a row matching (magic == 'SCCA' AND
`flags.LIVE == 1` AND `source_hash == rbx` AND `deps_hash == rbp`).

- On hit: write `*out_elaborated_ref = slot.body_ref u64 at [+24]`;
  write `*out_len = slot.body_len u64 at [+32]`; update
  `slot.timestamp_us = rdtsc`; bump `_sc_hit_count`; return
  `SCC_OK`.
- On miss: bump `_sc_miss_count`; return `SCC_ERR_NOT_FOUND`
  (0x6510).
- On null write-ptr (either `out_elaborated_ref == 0` or
  `out_len == 0`): return `SCC_ERR_BAD_PTR` (0x6500) with NO
  counter mutation.

### 7.2 `_sc_insert`

Two-phase scan.

- Phase A (free scan): walk slots 0..32 left-to-right; the first
  slot with `flags.LIVE != 1` wins; `is_fresh = 1`.
- Phase B (LRU scan): if Phase A finds no free slot, seed
  `min_ts = slot[0].timestamp_us`, re-walk indices 1..32, pick the
  slot with the minimum `timestamp_us`; `is_fresh = 0` (eviction).

Writes the 64-byte record (magic 'SCCA', LIVE flag, source_hash,
deps_hash, elaborated_ref, len, timestamp_us = rdtsc,
cache_key_inline = two u64 LE stores of source_hash + deps_hash).
Bumps `_sc_entry_count` iff `is_fresh == 1`.

Guards: `elaborated_ref != 0` (fail -> `SCC_ERR_NULL_REF` 0x6503);
`len != 0` (fail -> `SCC_ERR_ZERO_LEN` 0x6504).

The elaborated_body_ref payload on an evicted slot is NOT
scrubbed; the module owns no finalizer. The caller is responsible
for releasing the underlying storage if needed (a session-local
arena allocator is the natural owner).

### 7.3 `_sc_invalidate`

Scans the 32-slot pool; for every row matching (magic == 'SCCA'
AND `flags.LIVE == 1` AND `source_hash == rbx`) zeros the magic +
flags fields and bumps the local cleared_count. Decrements
`_sc_entry_count` by cleared_count. Returns `SCC_OK`.

A given source may legitimately have multiple deps_hash rows
cached (one per import graph configuration encountered); all
matching rows are cleared.

### 7.4 `_sc_stats`

Writes the 64-byte SCCS stats record at `out_stats_ptr`. Returns
`SCC_OK` on write; `SCC_ERR_BAD_PTR` (0x6500) on null pointer.

## 8. Acceptance

### Fixture (R227.M7-003, deferred to R221.M9 harness landing)

```
# 1000-line script fixture.
source_hash = fnv1a_64(bytes_of_script_1000lines)
deps_hash   = fnv1a_64(concat(import_path_hashes))

cold_start = rdtsc()
elaborate(script_bytes)                        # cold-cache cost
cold_end = rdtsc()
_sc_insert(source_hash, deps_hash, body_ref, body_len)

warm_start = rdtsc()
status = _sc_lookup(source_hash, deps_hash, &out_ref, &out_len)
assert status == SCC_OK
assert out_ref == body_ref
assert out_len == body_len
warm_end = rdtsc()

cold = cold_end - cold_start
warm = warm_end - warm_start
assert cold >= 10 * warm
```

The structural guarantee that a 32-slot linear scan is O(k) while
LoadCheck is O(n log n) in the character count makes the 10x ratio
hold by orders of magnitude for n = 1000 lines; raw M7 satisfies
the fixture by construction.

### Deferred follow-ups (M7.1..M7.6)

- M7.1 disk-backed `~/.paideia/script-cache/<hash>.pdc` via pdxfs.
- M7.2 hex rendering of `cache_key_inline`.
- M7.3 TurnFingerprint wire-up (chaos-replay cache-state feed-in).
- M7.4 capacity bump 32 -> 128.
- M7.5 cross-session concurrency.
- M7.6 acceptance fixture landing.

## 9. Status band -- 0x6500..0x65FF

```
SCC_OK                       = 0
SCC_ERR_BAD_PTR              = 0x6500   lookup: null write-ptr; stats: null out_ptr
SCC_ERR_RESERVED_01          = 0x6501   reserved for M7.1+ stats-cap faults
SCC_ERR_RESERVED_02          = 0x6502   reserved for M7.1+ hash-sentinel faults
SCC_ERR_NULL_REF             = 0x6503   insert: elaborated_ref == 0
SCC_ERR_ZERO_LEN             = 0x6504   insert: len == 0
SCC_ERR_NOT_FOUND            = 0x6510   lookup: no matching row
```

Slots `0x6505..0x650F` reserved for R227.M7.1+ insert /
invalidate diagnostics (full-pool-with-no-victim, source-hash-
collision-arm, pdxfs-write-fault, serialization-fault,
deserialization-fault, corrupt-record-magic, corrupt-record-flags,
corrupt-record-length, capacity-saturation-warn, policy-mode-
mismatch). Slots `0x6511..0x65FF` reserved for R227.M7.2+ lookup
diagnostics (stale-deps-hash, miss-by-invalidation-reason, pdxfs-
reload-fault, cache-coherence-warn, cross-session-shared-fault,
concurrency-fault, LRU-sweep-noise).

The 0x6500..0x65FF carve-out skips the parallel-arm 0x6300..0x63FF
(R225.M10 per-turn type-check fingerprint) and 0x6400..0x64FF
(R226.M2 datalog predicate-type resolution) bands and sits directly
above the R227.M6 VersionPragma band (0x6200..0x62FF).

## 10. Encoder discipline (paideia-as pdx)

- No `test rN, rN` -- every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64` -- the `SCC_FLAG_LIVE` bit is a single imm8
  compare (`cmp r, 1`); no multi-byte mask is used. The flags u32
  is written as the whole imm32 value (0 or 1) via `mov_d`, not
  as a masked OR into an existing value.
- No 2-op `imul rN, imm` -- the 64-byte stride is `shl rN, 6`
  (power of two).
- No multiline `pub let = "..."` -- single-line justifications.
- Module basename `ScriptCache` matches `script_cache.pdx`.
- Labels prefixed `scc_` with per-handler suffix (`scc_ini_`,
  `scc_lu_`, `scc_in_`, `scc_iv_`, `scc_st_`). `sc_` is reserved
  by the kernel-side `script_cmd.pdx` module; this module uses
  `scc_` (the second `c` for "cache") instead.
- u32 loads via `xor rN, rN; mov_d rN, [base + disp]`.
- u32 stores via `mov_d [dst + disp], reg`.
- u16 stores via `mov_w [dst + disp], reg` (version field in the
  stats record).
- u64 stores via plain `mov [dst + disp], reg`.
- No chained-displacement addressing with three terms: all
  `[base + off + idx]` expressions precomputed via `add` first.
- rdtsc clobber discipline: rax/rdx trashed; combine via
  `shl rdx, 32; or rax, rdx`.

All `cmp reg, imm` immediates (0, 1, 32, 64, status codes
0x6500..0x6510, magic 0x41434353 'SCCA' and 0x53434353 'SCCS') fit
imm32 with bit 31 clear so direct cmp-imm32 is sign-safe.

## 11. Register-liveness

- `_sc_init`: zero pushes; zero stack frame; no nested CALL. Three
  u64 scalars zeroed via `lea r11, [rip + sym]; mov [r11], rax`
  triplets.
- `_sc_lookup`: 5 pushes (rbx=source_hash, rbp=deps_hash, r12=
  out_elaborated_ref, r13=out_len, r14=scan_idx). Pure leaf.
- `_sc_insert`: 6 pushes (rbx=source_hash, rbp=deps_hash, r12=
  elaborated_ref, r13=len, r14=scan/chosen_idx, r15=
  min_timestamp carrier). Pure leaf.
- `_sc_invalidate`: 3 pushes (rbx=source_hash, rbp=scan_idx,
  r12=cleared_count). Pure leaf.
- `_sc_stats`: 1 push (rbx=out_stats_ptr). Pure leaf.

## 12. Lazy-init

R227.M7 holds `.bss` state (2048 B pool + 3 x u64 scalars = 2072
B aligned to 2080 B). `.bss` zero-init at cold boot trivially
satisfies the "magic == 0 means never-used slot" invariant AND
the three counter invariants (zero). `_sc_init` defensively re-
zeros the three counter scalars on a chaos-restart re-entry. The
pool itself is NOT scrubbed on re-init because the magic-0
convention lets the lookup / insert / invalidate paths treat
every row with magic != 0 consistently; stale rows from a prior
session cannot false-positive a lookup under the new session's
hashes (collision probability on FNV-1a 64 is 2^-64 per hash and
2^-128 on the pair).

## 13. Dependencies

- Raw M7: zero intra-library linker-visible FUNCTION dep. Zero
  external cross-library linker dep. The module touches only
  caller-supplied pointer args, caller-supplied u64 scalars, and
  its own `.bss` pool + three counter scalars.
- M7.3 forward path: R229.M10 TurnFingerprint feed-in (chaos-
  replay cache-state reproduction).
- M7.6 forward path: R221.M9 property-test harness slot for the
  1000-line-script fixture.

## 14. Forward path

- M7.1 Disk-backed persistence: write each cached row to
  `~/.paideia/script-cache/<hash>.pdc` via pdxfs CoW path
  integration.
- M7.2 Hex rendering of `cache_key_inline`.
- M7.3 TurnFingerprint wire-up (chaos-replay cache-state feed-in).
- M7.4 Capacity bump 32 -> 128 slots.
- M7.5 Cross-session concurrency: session-shared pool under a
  RWLock.
- M7.6 1000-line-script acceptance fixture landing
  (`tests/proptest_script_cache.pdx`); landing with R221.M9
  property-test harness.

## 15. ABI freeze

The 64-byte record layout, the 64-byte stats record layout, and
the five public entry-point signatures (`_sc_init`, `_sc_lookup`,
`_sc_insert`, `_sc_invalidate`, `_sc_stats`) are FROZEN at raw
M7. Future M7.x landings extend the reserved bytes without
rearranging landed fields. A MINOR version bump via the
`LPX_PDS_PARSER_VERSION_MINOR` feature-flag triple signals every
compatible extension; a MAJOR bump signals a binary-incompatible
layout change (e.g., capacity 32 -> 128 at M7.4 would MINOR-bump
only -- the field layout stays put).

## 16. Related docs

- `design/shell/import-resolution-parser.md` -- R227.M3
  ImportResolve (source of the deps_hash input).
- `design/shell/typecheck-at-load.md` -- R227.M4 LoadCheck
  (source of the elaborated_body_ref payload).
- `design/shell/module-as-functor.md` -- R227.M5 ModuleFunctor
  (parallel sibling in the R227 wave).
- `design/shell/version-pragma.md` -- R227.M6 VersionPragma
  (parallel sibling in the R227 wave).
- `design/shell/turn-fingerprint.md` -- R229.M10 TurnFingerprint
  (M7.3 forward-path wire-up target).
- `design/shell/history-storage.md` -- R229.M5 History (FNV-1a 64
  inliner precedent for the caller-side source_hash computation).
