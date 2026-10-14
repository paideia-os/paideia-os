# Multi-session capability-environment sharing

**Status:** draft (Wave UMB-W23 R139.M5, paideia-os#2643).
**Owner:** softarch (umbrella-decomp AISSUE discipline).
**Design doc for:** `src/kernel/core/svc/env_sharing.pdx`.
**Related substrates:**

- `src/kernel/core/cap/kind_cap_env.pdx` (R125.M1, #2591) — the per-session
  cap-env row pool.
- `src/kernel/core/svc/cap_minter.pdx` (R125.M2, #2592) — single-env sub-cap
  derivation.
- `src/kernel/core/svc/shell_session.pdx` (R127.M1, #2597) — the session row
  pool, with `SS_OFF_CAP_ENV` at `+16`.
- `src/kernel/core/svc/session_shutdown.pdx` (R139.M4, #2642) — the wholesale
  teardown pipeline. Shared records are torn down implicitly when the
  destination session is destroyed (its `cap_env` is zeroed by
  `_shell_session_destroy`'s cascade, leaving the share record in a
  "pointing-at-dead-slot" state that `_es_revoke` cleans up).

## 1. Problem statement

PaideiaOS places each shell session's capability flow in a dedicated
`KIND_CAP_ENV` row (R125.M1): a bounded six-slot environment of caps the
command dispatcher hands into every launched module. The invariant is
*bounded cap-flow at exec* — a command only ever reaches the caps the shell
decides to grant it, and nothing more.

Two shells running concurrently is now the common case:

- A **local** terminal shell plus an **R137 remote** shell that just KEM-
  handshaked into the same box with a user-level operator at each end.
- A **local** shell plus an **R135 WASI-jail-nested** shell whose jail
  supervisor pinned a cap-env slot the parent shell is also authorised
  against.
- Two **jail-nested** shells spawned from the same parent dispatcher,
  running in sibling jails, each with its own cap-env but sharing a parent
  resource.

In every pair there are moments when a cap minted in one session needs to
reach the other. Three concrete examples drive the design:

1. **Interactive mount handoff.** The local operator mounts a volume
   mid-session; the resulting `KIND_FS_HANDLE` is in the local shell's
   cap-env. The remote operator needs to list files on that volume. Without
   sharing, the remote shell has to re-mint — but it does not hold the
   privilege to call the mount daemon.
2. **Jail-sibling block-device access.** The jail parent minted a
   `KIND_BLKDEV` cap for a shared tmpfs file; sibling jail A needs read-only
   access, sibling jail B needs read-write. The parent should be able to
   hand each sibling a *narrowed* view.
3. **Live stdout record inspection.** A remote shell's command is streaming
   `R135.M4` stdout records; the local operator wants to inspect them live
   from their session.

The alternative to a share surface is **re-minting**. Re-minting requires
calling back to the originating daemon with the same arguments; it fails
whenever the receiving session lacks the privilege, which is exactly the
case where sharing is interesting. The other alternative — handing the
whole env across — breaks the bounded-cap-flow invariant and defeats R125.

## 2. Design goals

- **Narrow-only.** A shared cap carries a **strict subset** of the parent's
  rights. Widening is a privilege escalation and must be rejected inline.
- **Bounded.** The share table caps the simultaneous shares (16 records at
  M5). Pool exhaustion is a return code, not a kernel panic.
- **Tracked.** Every share is a row in a visible table. `_es_lookup_sharing`
  and `_es_revoke` operate on that table rather than walking the full
  cap_table. The receiving-side cap-env still carries only its own slots —
  the share record is kernel-only metadata.
- **No new storage path.** The derived cap lives in the destination
  session's existing `KIND_CAP_ENV` row at a free slot, reached by the
  same `cap_env_insert` the mint pipeline already uses. The destination
  shell sees the shared cap through its usual `cap_env_lookup` surface.
- **Idempotent revoke.** A double-revoke returns an error (so the caller
  learns), but never corrupts state (the record stays zeroed).

Non-goals at M5:

- **Lineage.** A later wave (R128) adds parent→child lineage so a parent
  revoke cascades to shared children; at M5 revoke is per-share.
- **Cross-boot persistence.** Shares live in RAM only; a chaos restart
  starts with an empty share table.
- **Op-dispatch surface.** M5 is direct-call. Section 5 proposes an op
  variant on `KIND_CAP_ENV` that a later wave can wire.

## 3. Interaction with R125.M2 cap-minter

The share operation is **a cap-minter op variant for two envs**. The
single-env form (`_cap_minter_derive`) and the cross-session form
(`_es_share`) share the same five-step inner spine:

1. Validate the parent cap exists in the source env (`cap_env_lookup`).
2. Load the parent cap_table descriptor (`parent_kind`, `parent_rights`,
   `parent_target_ptr`).
3. **Narrow-only invariant.** Enforce
   `(requested_rights & parent_rights) == requested_rights`.
4. Allocate: a free cap_table slot (reserved range), a free destination
   env slot.
5. Mint: `cap_mint_write(new_cap_idx, parent_kind, requested_rights,
   parent_target_ptr)` and `cap_env_insert(dst_env, dst_slot, new_cap_idx)`.

What differs:

| Aspect                    | `_cap_minter_derive` (R125.M2)         | `_es_share` (R139.M5)                           |
|---------------------------|----------------------------------------|-------------------------------------------------|
| Source env                | ambient `_cap_minter_active_env`       | explicit `src_session_id` → row[+16]            |
| Destination env           | same as source                         | explicit `dst_session_id` → row[+16]            |
| Cap_table reserved range  | `[192, 256)`                           | `[128, 192)` (disjoint; see §3.3)               |
| Record keeping            | none (lineage comes with R128)         | `_es_share_table` row (16 records × 32 B)       |
| Revoke surface            | none at M5                             | `_es_revoke(idx)` clears record + dst env slot  |
| Expected caller           | ring-3 derive-into-own-env             | shell supervisor (local or jail parent)         |

### 3.1 The cap_table reserved range

Both `_cap_minter_derive` and `_es_share` run against a Phase-2
`slab_alloc` stub that returns `CAP_SLAB_CAPACITY` unconditionally — using
it would make every call return `_ENV_FULL`. Until the slab is rewritten
with a lineage-aware free list (R128.M*), each module owns a fixed slice
of cap_table:

- `[0, 128)` — early-boot kernel-side mints, witness fixtures,
  ring-3 syscall-minted descriptors.
- `[128, 192)` — **R139.M5 env-sharing** (this module).
- `[192, 256)` — R125.M2 cap-minter.

When the real slab lands with lineage tracking, both reserved ranges
collapse: the slab hands back any free slot and `es_find_free_cap_slot`
becomes a no-op. The reserved-range comment in both modules names the
retirement path.

### 3.2 Share record publication order

A share record carries four u64 fields; the IN_USE flag is at `+24`.
The `_es_share` body writes the fields in this order:

1. `[+0]`  `(dst_sid << 32) | src_sid`     — identity pair
2. `[+8]`  `(dst_slot << 32) | src_slot`   — slot pair
3. `[+16]` `rights_mask`                   — the narrowed rights
4. `[+24]` `ES_FLAG_IN_USE`                — PUBLICATION (last)

At M5 everything is single-flow (`R139` is phase-2 kernel; cross-core
dispatch arrives with later waves). The release-ordered publication is a
**design invariant** rather than a hardware ordering guarantee today —
the cost is zero and the invariant is easy to assert at R145+ when
concurrent scanners come into scope.

`_es_revoke` zeroes in the same release order (flags last → FREE sentinel
published after the data fields clear). Both routines rely on the fact
that the FREE sentinel (`flags == 0`) is distinct from any IN_USE record
(bit 0 set).

### 3.3 Interaction with the frozen-env posture

A destination env that has been `cap_env_freeze`'d (R125.M1 §3)
refuses `cap_env_insert` with `CAP_ENV_ENV_FROZEN`. The shell freezes
its cap-env just before handing it to a `cmd_module` launch, so a
share attempt that targets a frozen env is **almost always a timing
bug in the caller** — the share should have landed before the receiving
shell froze.

At M5 we collapse frozen-env failures into `ES_ERR_POOL_FULL`:
`cap_env_insert` returns non-zero, and we treat it the same as any
other "cannot land the child cap" outcome. The ambiguity is harmless
because every share-against-frozen is a programming error. A later
wave MAY reserve a dedicated `ES_ERR_FROZEN` code (`0x1F12` is open
in our band) if a feedback path needs to distinguish them.

## 4. Narrow-only invariant check

The load-bearing check is one AND-and-compare:

```
    mov rax, requested_rights
    and rax, parent_rights
    cmp rax, requested_rights   ; equal iff requested is a subset of parent
    jne cmnt_de_widen
```

This formulation uses only `and reg,reg` and `cmp reg,reg` — no `not reg`
(paideia-as encoder gap). It is the SAME formulation used in
`_cap_minter_derive` step 7 (`cap_minter.pdx`), and is mirrored verbatim
in `_es_share` step 7 so a future reviewer can audit both callsites
against the same reference.

**Interaction with R125.M4 cap-check (syscall-cap-check.md).** A shared
cap is just another derived cap: its cap_table descriptor carries the
narrowed rights, and every syscall-time cap-check routes through the
same `cap_check(invocation, required_rights)` logic. There is no shared-
cap special case at check time, which is exactly the property we want:
a cap is a cap, regardless of how it was minted.

### 4.1 Example: narrowing a KIND_BLKDEV cap

Suppose jail parent `P` holds a `KIND_BLKDEV` cap at env slot 2 with
`rights = R_BLKDEV_READ | R_BLKDEV_WRITE | R_BLKDEV_IOCTL`.

To grant jail sibling `A` a **read-only** view:

```
_es_share(P.sid, A.sid, 2, R_BLKDEV_READ) -> (dst_slot << 2) | 0
```

The share pipeline:
1. Looks up `P.sid` → `src_env = P.cap_env_handle`.
2. Looks up `A.sid` → `dst_env = A.cap_env_handle`.
3. `parent_cap_idx = cap_env_lookup(src_env, 2)` — returns the cap_table
   row holding the KIND_BLKDEV descriptor.
4. Reads `parent_rights = R_BLKDEV_READ | R_BLKDEV_WRITE | R_BLKDEV_IOCTL`
   from the row.
5. Narrow check: `R_BLKDEV_READ & (READ|WRITE|IOCTL) == R_BLKDEV_READ` ✓.
6. Allocates a free cap_table slot in `[128, 192)`.
7. Allocates a free env slot in `A.cap_env`.
8. `cap_mint_write` with `rights = R_BLKDEV_READ`, same `kind`, same
   `target_ptr`.
9. `cap_env_insert(A.cap_env, dst_slot, new_cap_idx)`.
10. Writes a share record and returns `(dst_slot << 2) | 0`.

If `P` had instead asked for `R_BLKDEV_WRITE | R_BLKDEV_FORMAT`, the
narrow check would fail (parent lacks `R_BLKDEV_FORMAT`) and the share
would be refused with `ES_ERR_WIDEN`.

## 5. Public API and return codes

See `env_sharing.pdx` §2 for the authoritative API comments. Summary:

```
_es_init() -> ()                                  // boot scrub
_es_share(src_sid, dst_sid, src_slot, rights)
    -> (dst_slot << 2) | ES_OK                    // success
    -> ES_ERR_BAD_SESSION / _WIDEN / _POOL_FULL   // failure
_es_lookup_sharing(src_sid, src_slot)
    -> (dst_slot << 32) | idx                     // hit
    -> 0xFFFFFFFF                                 // miss
_es_revoke(idx) -> ES_OK | ES_ERR_BAD_SESSION
```

### 5.1 Return band 0x1F10..0x1F1F

Band audit (2026-10-14):
`grep -rnE '0x1F1[0-9]\b' src/kernel/` → zero hits.

- `ES_OK                 = 0`
- `ES_ERR_POOL_FULL      = 0x1F10`
- `ES_ERR_BAD_SESSION    = 0x1102`   (alias `SS_ERR_BAD_ID`)
- `ES_ERR_WIDEN          = 0x1F11`
- `0x1F12..0x1F1F`                   reserved for later milestones.

All codes fit `imm32` with bit 31 clear so `mov rax, imm32` emits the
7-byte zero-extending form (no `and r11, imm64` encoder gap).

The success-packed form `(dst_slot << 2) | ES_OK` is **disjoint** from
every `ES_ERR_*` code because env slots are in `[0, 6)` so
`(dst_slot << 2)` is in `[0, 24)` which is below the lowest error code
`0x1102`. Callers may treat the result as:

```
    if result < 24: success, dst_slot = result >> 2
    else:           error, errno = result
```

### 5.2 Lookup result encoding

The hit form packs `(dst_slot << 32) | share_record_idx`. The miss
sentinel is `0xFFFFFFFF`. A hit's low 32 bits (idx in `[0, 16)`) can
never reach `0xFFFFFFFF`, so the two spaces are disjoint. Callers test:

```
    if result == 0xFFFFFFFF: miss
    else:                    idx = result & 0xFFFFFFFF
                             dst_slot = result >> 32
```

(The `& 0xFFFFFFFF` is cheap and does not need the kernel-side encoder
pitfalls to be aware of — this is caller-side C-shaped code.)

### 5.3 Future op-dispatch variant

A later wave MAY lift the share surface into a cap-minter op variant
on `KIND_CAP_ENV` (reserved `CAP_ENV_OP_SHARE`, slot not yet assigned
in `kind_cap_env.pdx` — the current OP_MAX is 3 covering COUNT/LOOKUP/
IS_FROZEN/DERIVE). Encoding sketch:

```
op_arg[7:0]      = CAP_ENV_OP_SHARE
op_arg[15:8]     = src_env_slot
target_ptr[7:0]  = src_session_id
target_ptr[15:8] = dst_session_id
rights_mask      = cap-invoke payload word (separate from op_arg)
```

At M5 the standalone direct-call API avoids widening the handler's
`op_arg` encoding while the ring-3-caller env is still being lifted at
R125.M3+. The retirement path for the direct-call API lands when the
op-dispatch slot is wired and a ring-3 caller is in-tree.

## 6. Fingerprint discipline

Each of the three verbs emits exactly one fingerprint per outcome:

- `ENV_SHARE INIT OK`     — boot scrub success (unconditional on boot).
- `ENV_SHARE SHARE OK`    — successful share, KV = `src_sid`.
- `ENV_SHARE SHARE REJ`   — refused share, KV = `errno`.
- `ENV_SHARE LOOKUP OK`   — hit, KV = `idx` (packed result).
- `ENV_SHARE LOOKUP MISS` — miss, KV = `src_sid`.
- `ENV_SHARE REVOKE OK`   — successful revoke, KV = `idx`.
- `ENV_SHARE REVOKE REJ`  — bad idx or already-free, KV = `errno`.

Only the `OK` tags are extracted by the fingerprint-coverage gate
(`tools/verify-fingerprint-coverage.sh`); the `REJ` / `MISS` tags are
opaque to the gate so no allowlist entry is required for them. The
coverage gate allowlist (filed at wire-up time, when `_es_init` is
hoisted into `kernel_main.pdx`) will carry the standard
"direct-call substrate; no production caller at M5" clause mirroring
`HISTORY_SEG` / `CMD_AUDIT` / `SESSION_SHUTDOWN` entries, with the
retirement condition "a production caller (local shell `cap share`
builtin, or jail parent handoff) lands with an asserting smoke-mode
golden exercising at least one share + lookup + revoke roundtrip."

## 7. Smoke-mode roundtrip (future)

The acceptance test that will retire the fingerprint allowlist entries
is a smoke-mode golden with the shape:

```
# bringup
_shell_session_create(pid_a, "alice") -> sid_a
_shell_session_create(pid_b, "bob")   -> sid_b
# alice mints a cap at her slot 0 (test fixture via kernel-side mint)
# alice shares to bob with narrowed rights
_es_share(sid_a, sid_b, 0, R_READ) -> packed
# bob's env now has the shared cap at some slot
dst_slot = packed >> 2
cap_bob = cap_env_lookup(bob.cap_env, dst_slot)
# verify: cap_bob has R_READ only (narrowed)
# verify: cap_bob points at the SAME target_ptr as cap_alice
# alice revokes
_es_lookup_sharing(sid_a, 0) -> packed
idx = packed & 0xFFFFFFFF
_es_revoke(idx) -> ES_OK
# verify: cap_env_lookup(bob.cap_env, dst_slot) == 0 (slot cleared)
# verify: _es_lookup_sharing(sid_a, 0) == 0xFFFFFFFF (miss)
```

The golden lands with the next-wave production caller (either a `cap
share` shell built-in or the jail-parent handoff path).

## 8. Encoder discipline

Standard paideia-as posture (`feedback_pdx_encoder_pitfalls`):

- Module basename `EnvSharing` matches file basename `env_sharing.pdx`.
- Labels prefixed `es_` to stay clear of `ce_` (kind_cap_env), `cmnt_`
  (cap_minter), `ss_` (shell_session), `ssd_` (session_shutdown),
  `hs_` (history_segmentation).
- `cmp rN, 0` (never `test rN, rN`).
- Share record stride `32 = 2^5` → `shl rax, 5` (no `imul r, imm`).
- cap_table stride `24 = 8 + 16` → `(slot<<3) + (slot<<4)` (two shifts).
- u32 isolation via `shl 32 / shr 32` round-trip (never `and r11, 0xFFFFFFFF`).
- Narrow-only check via AND-and-compare (never `not reg`).
- Fingerprint `[u8; N]` with `N = len(string) + 1` (NUL counts).
- Single-line `pub let name = "..."` for every tag.

## 9. Design trade-offs considered

### 9.1 Why not call `_cap_minter_derive` into dst's env?

`_cap_minter_derive` reads the destination env from the ambient
`_cap_minter_active_env` global. Temporarily reassigning that global
across the share call would (a) create a half-committed window where
the global points at the dst env but the share has not yet landed, and
(b) require the caller to serialise against any other derive that is
also walking the ambient global. The direct standalone module is
simpler and safer.

### 9.2 Why a share table at all?

Alternative: don't track shares; make revoke walk the full cap_table
looking for descriptors whose `(kind, target_ptr)` matches a hint and
whose rights are a subset of some reference rights. Walking 256 slots
on every revoke is cheap, but the semantic is murky: there is no clean
"this is the one I minted" identifier. The table makes the revoke
unambiguous.

Alternative: add a `parent_cap_idx` field to the cap_table descriptor
(fourth u64, bumping stride from 24 to 32). This is the right eventual
answer (lineage, R128). At R139.M5 it would widen a load-bearing data
structure for one feature; a sibling table is cheaper now and converges
to the lineage design later.

### 9.3 Why 16 records?

The expected steady-state is "a handful of shares live at a time."
At 32 B/record and 16 records the pool is 512 B — negligible. If a
future caller shape wants more, bump `ES_RECORDS_MAX` (power-of-two
stride stays). The share-table scan is `O(ES_RECORDS_MAX)` so going
to 64 or 128 is still cheap.

### 9.4 Why disjoint cap_table ranges?

The Phase-2 slab stub returns `CAP_SLAB_CAPACITY` unconditionally.
Sharing the range `[192, 256)` with cap-minter would create a shared
free-list surface that neither module owns; disjoint ranges give each
module a scan it can audit alone. When the real slab lands with
lineage (R128), both reserved ranges collapse.

## 10. Follow-up slices

- **Wiring** — hoist `_es_init` into `kernel_main.pdx` right after
  `_ssd_init`. (Deferred to the next slice to keep this landing scoped
  to the module + design doc.)
- **Fingerprint allowlist** — add `ENV_SHARE *` entries to
  `tools/verify-fingerprint-coverage.sh` with the standard
  "direct-call substrate; no production caller at M5" clause.
- **Production caller** — either a `cap share` shell built-in that
  pairs with `cap list` / `cap drop`, or a jail-parent handoff path
  that uses `_es_share` to grant a sibling jail a narrowed view of a
  parent-held cap at jail-launch time.
- **Op variant** — reserve `CAP_ENV_OP_SHARE` in `kind_cap_env.pdx`
  and wire the dispatch arm (depends on the caller-context lift at
  R125.M3+).
- **Lineage** — R128 parent→child lineage retires the share table in
  favour of a cap_table-side lineage field.
