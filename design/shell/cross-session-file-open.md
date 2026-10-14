# Cross-session file-open (R139.M6, paideia-os #2644)

Status: landed (Wave UMB-W24, 2026-10-14)
Scope: pure-kernel .pdx (`src/kernel/core/svc/cross_session_open.pdx`)
Depends on: R139.M5 (env sharing, #2643); R125.M1 (KIND_CAP_ENV); R125.M2 (cap-minter); R127.M1 (shell_session daemon)

---

## 1. The user-facing problem

R139.M5 (`env_sharing.pdx`) landed the **push-direction** primitive:

```
_es_share(src_sid, dst_sid, src_slot, rights) -> packed u64
```

The owner of a cap in `src_sid`'s env hands a narrowed copy to a
destination session it names. That shape is exactly right for the
cases where the source session **knows the destination up front** —
the jail supervisor pinning a tmpfs cap into a sibling jail, the KEM
handshake pre-populating caps in a freshly-attached remote shell.

It is the **wrong** shape for the paradigmatic interactive case the
user types every day:

```
$ fileref /mnt/log.txt @sid=3
```

Here the **requesting** session (the shell that just read `@sid=3`)
names a target session + slot, pulls the cap, and lands it in its
own env. The target session cannot predict the moment of the pull —
it may be a batch pipeline, a daemonised remote shell, a long-running
build job — and should not be forced to call `_es_share`
preemptively against every session that *might* want to reach into
it.

R139.M6 lifts the push primitive into a **request / allowance**
model that:

1. preserves the capability-system narrow-only invariant,
2. puts the policy gate under the **target session's** control,
3. reuses R139.M5's share-record table and release-ordered
   publication for the actual mint,
4. retires the "re-open the file from the requester side" workaround
   (which breaks for file-caps the requester doesn't have the
   authority to re-open: NET-caps minted by the kernel, pdxfs caps
   under a jail root the requester cannot see, stdout-record streams
   that only exist in a running pipeline).

---

## 2. The two-primitive design

### 2.1 Allowance (target side)

```
_cso_allow(target_sid, target_env_slot, max_rights) -> errno
```

The target session **pre-authorises** one of its env slots to be
pulled by any requester. The `max_rights` field is the **ceiling**
rights for pulls — a target session that opened a file RW can offer
it RO (`max_rights = RIGHT_READ`) and no subsequent request can lift
to RW even if the request asks for it.

The allowance is stored in a bounded table — 16 records × 32 B,
same geometry as R139.M5's share table — keyed uniquely on
`(target_sid, target_env_slot)`. A duplicate `_cso_allow` on an
already-live pair is a **no-op success** (idempotent re-auth): the
`max_rights` is overwritten so the target can lift or lower the
ceiling without first revoking.

Record layout:

| offset | field              | notes                                   |
| -----: | ------------------ | --------------------------------------- |
|   `+0` | `target_sid`       | low 32 = sid; high 32 reserved          |
|   `+8` | `target_env_slot`  | low 32 = slot; high 32 reserved         |
|  `+16` | `max_rights`       | ceiling rights (narrow lattice)         |
|  `+24` | `flags`            | bit 0 = `IN_USE`; published **last**    |

Return codes:

| code                    | value   | fired by                                   |
| ----------------------- | ------- | ------------------------------------------ |
| `CSO_OK`                | `0`     | allowance recorded (or already-live)       |
| `CSO_ERR_BAD_SESSION`   | `0x1102`| bad `target_sid`, slot out of range, or    |
|                         |         | target slot empty (no cap at that slot)    |
| `CSO_ERR_POOL_FULL`     | `0x1F22`| allowance table full (> 16 live offers)    |

### 2.2 Request (requester side)

```
_cso_request(req_sid, tgt_sid, tgt_slot, rights_mask) -> packed u64
```

The requester asks for a narrowed child of `(tgt_sid, tgt_slot)` to
land in its own env. Returns a packed u64:

- success: `(dst_env_slot << 2) | CSO_OK` — status in `[0, 4)`,
  dst_env_slot in `[0, 6)`, so the packed success is in `[0, 24)`
  and disjoint from every `CSO_ERR_*` code (lowest at `0x1102`).
- failure: `CSO_ERR_*`.

Return codes:

| code                    | value   | fired by                                   |
| ----------------------- | ------- | ------------------------------------------ |
| `CSO_OK`                | `0`     | shared cap minted at `dst_env_slot`        |
| `CSO_ERR_NO_PERMISSION` | `0x1F20`| no allowance for `(tgt_sid, tgt_slot)`     |
| `CSO_ERR_BAD_SESSION`   | `0x1102`| bad req/tgt sid, slot out of range, or     |
|                         |         | `_es_share` reported `ES_ERR_BAD_SESSION`  |
| `CSO_ERR_WIDEN`         | `0x1F21`| `rights_mask` ⊄ `allowance.max_rights`,    |
|                         |         | OR `_es_share` reported `ES_ERR_WIDEN`     |
| `CSO_ERR_POOL_FULL`     | `0x1F22`| `_es_share` could not allocate (M5 share   |
|                         |         | table / cap_table reserved range / dst env |
|                         |         | all full)                                  |

### 2.3 Revoke (requester side)

```
_cso_revoke(requester_sid, requester_slot) -> errno
```

Drop a shared cap in `requester_sid`'s env. Finds the M5 share-record
keyed on `(dst_sid == requester_sid AND dst_env_slot ==
requester_slot AND IN_USE)` via a reverse scan on
`_es_share_table`, then delegates teardown to `_es_revoke`.

| code                  | value    | fired by                               |
| --------------------- | -------- | -------------------------------------- |
| `CSO_OK`              | `0`      | share revoked                          |
| `CSO_ERR_BAD_SESSION` | `0x1102` | bad `req_sid` / no matching live share |

### 2.4 Withdraw allowance (target side)

```
_cso_revoke_allowance(target_sid, target_env_slot) -> errno
```

Clear a standing offer. **Does not** invalidate caps that were
already pulled against this allowance — those live in requester envs
and the requesters drop them via `_cso_revoke`. This matches the
"offer withdrawn, prior deliveries honoured" discipline used by
every allowance-shaped protocol (POSIX `setuid` after fd-open, SPKI
delegations, OAuth refresh-token revocation).

| code                  | value    | fired by                                |
| --------------------- | -------- | --------------------------------------- |
| `CSO_OK`              | `0`      | allowance cleared                       |
| `CSO_ERR_BAD_SESSION` | `0x1102` | bad `tgt_sid` / no live allowance pair  |

---

## 3. Permission model

### 3.1 The two-layer narrow check (defense-in-depth)

`_cso_request` enforces narrow-only at **two independent layers**:

**(A) POLICY gate** (this module, step 5):

```
(rights_mask & allowance.max_rights) == rights_mask
```

This enforces the **target session's** chosen ceiling: "I,
`target_sid`, will let requesters pull a child of slot `tgt_slot`
with up to `max_rights`." The target session owns this policy —
it's the user-facing surface where "offer this file RO" is spoken.

**(B) CAPABILITY-SYSTEM invariant** (delegated to `_es_share` §4):

```
(rights_mask & parent_cap.rights) == rights_mask
```

Enforces that the mint cannot widen beyond what the **parent cap**
already holds. This is the global capability-system invariant: a
derived cap is always a strict subset of its parent. The
`_es_share` module owns this check and does not know about
allowances.

Both checks compose to:

```
rights_mask ⊆ min(allowance.max_rights, parent_cap.rights)
```

Both are implemented as `and reg, reg; cmp reg, reg; jne` — never
`not reg` (paideia-as encoder gap).

Why both? Because they protect against orthogonal failures:

- **(A) alone** would let a target that **lost** some rights on its
  own cap (e.g. after an in-session narrow via `_cmnt_derive`) still
  advertise the pre-narrow rights to requesters, violating (B).
- **(B) alone** would let any session with knowledge of a target
  session's slot pull **all** the parent cap's rights, violating
  the target's choice of what to expose.

### 3.2 Who can call what

At R139.M6 all four entry points are **kernel-trusted** direct
calls. The arguments carry the session-ids and the kernel does not
yet verify that the caller is **running under** `req_sid` or
`tgt_sid`. This is the same posture as R139.M5's `_es_share` and
R125.M2's `_cmnt_derive`.

A future wave (see §6) will lift the entry points into
`KIND_SHELL_SESSION` op variants, at which point the caller's
proving-of-identity is mediated by the cap-invoke rights check
(`RIGHT_INVOKE` on a cap that targets a specific session row).

Until then, the direct-call shape is bounded by the fact that only
kernel-trusted dispatch arms (the shell daemon's command handler,
the TUI's keybind router, the jail supervisor) ever reach these
symbols — ring-3 ELF code cannot call them.

### 3.3 Lifetime invariants

- **Allowance withdrawal does not revoke live shares.** A target
  that calls `_cso_revoke_allowance` only blocks **future**
  requests; caps already pulled survive until the requester calls
  `_cso_revoke`.
- **Session shutdown revokes allowances AND shares.** When a
  session's `ssd_teardown` runs (R139.M4), its cap-env is torn down
  along with all records in `_es_share_table` where that session
  is the `src_sid` or `dst_sid` AND any records in
  `_cso_allow_table` where that session is `target_sid`. This
  wiring is deferred to the integration PR that lands the first
  user-facing caller; the M6 module ships the primitives.
- **Share-record transparency.** `_cso_revoke` identifies the
  share-record via a reverse scan on `_es_share_table` keyed on
  `(dst_sid, dst_slot)`. This is linear in the share-table size
  (16) — fast enough that we do not maintain a redundant
  reverse-index.

---

## 4. Interaction with R139.M5

R139.M6 is a **thin UX layer** over R139.M5. It does **not**
duplicate M5's record publication, cap_table reserved range, or
cap-rights narrow check; it **delegates** the actual mint by calling
`_es_share(tgt_sid, req_sid, tgt_slot, rights_mask)` after its own
policy check.

| concern                            | owned by     |
| ---------------------------------- | ------------ |
| allowance table + policy ceiling   | M6 (this)    |
| policy narrow check                | M6 (this)    |
| share-record table + layout        | M5           |
| release-ordered record publication | M5           |
| cap_table reserved range `[128,192)`| M5          |
| capability-rights narrow check     | M5           |
| cap-env slot allocation            | M5           |
| teardown of a single share         | M5           |

Return-code remap at the delegation boundary:

| M5 return                 | M6 translation           |
| ------------------------- | ------------------------ |
| `(slot << 2) \| 0`         | pass through (success)   |
| `ES_ERR_BAD_SESSION 0x1102`| `CSO_ERR_BAD_SESSION`   |
| `ES_ERR_WIDEN 0x1F11`     | `CSO_ERR_WIDEN 0x1F21`   |
| `ES_ERR_POOL_FULL 0x1F10` | `CSO_ERR_POOL_FULL 0x1F22`|

The `WIDEN` remap preserves the error class but keeps the CSO error
in its own band — a caller inspecting codes can tell at a glance
whether the fault was at the policy gate (M6 band `0x1F2x`) or at
the capability-system gate (M5 band `0x1F1x`).

---

## 5. Shell-level UX surface

The `fileref /mnt/log.txt @sid=3` grammar is parsed by the shell
command dispatch (R127.M3+ `cmd_dispatch`) into the following
sequence:

```
# 1. Resolve @sid=3 to a session_id (shell_jobs maintains a table of
#    live sibling sessions by name; R133 landed this).
tgt_sid = _shell_jobs_resolve("sid=3")

# 2. Resolve /mnt/log.txt within the TARGET session's namespace.  R125.M3
#    exposes a kernel helper _ss_resolve_path(sid, path_bytes) that returns
#    the env_slot holding the file-cap, provided the target shell has
#    pre-registered an offer on that slot.
tgt_slot = _ss_resolve_path(tgt_sid, "/mnt/log.txt")

# 3. Pull.  rights_mask is derived from the shell's open-mode flags
#    (default is RIGHT_READ for `fileref`; `fileref -w` lifts to RIGHT_WRITE).
r = _cso_request(my_sid, tgt_sid, tgt_slot, RIGHT_READ)
if (r & 0x3) != 0 { /* error path */ }
my_slot = r >> 2
# 4. The shell binds the resulting cap to a local name under /tmp/.cso-<my_slot>
#    so downstream commands (cat, grep) can reference it.
```

For step 2 to succeed the target session must have called
`_cso_allow(tgt_sid, tgt_slot, max_rights)` **before** the request.
In the common case this is wired into the target shell's `cd`
command: entering a directory that holds `.pdx-share` metadata
registers allowances for every file in the directory.

An explicit `offer` command drives this directly from the user side:

```
# Target session (sid=3)
$ offer /var/log/build.log --max rw
offer: slot 2 open to any sid, up to RIGHT_READ|RIGHT_WRITE

# Requester session (sid=5)
$ fileref /var/log/build.log @sid=3
fileref: pulled from sid=3:slot=2 as RIGHT_READ, bound to slot 4
```

For the daemonised remote-shell case, allowance pre-registration is
batched into the KEM-handshake acceptance step (R137.M1): the remote
shell declares a set of standing allowances in its handshake
payload, and the local daemon calls `_cso_allow` on each when the
session is instantiated.

### 5.1 Error visibility

Fingerprints emitted by the kernel-side primitives (see §6 of
`cross_session_open.pdx` and the per-function justifications) make
every outcome observable:

```
CSOPEN INIT OK
CSOPEN ALLOW OK   tgt_sid=0x3
CSOPEN ALLOW REJ  errno=0x1102
CSOPEN REQUEST OK req_sid=0x5
CSOPEN REQUEST REJ errno=0x1F20
CSOPEN REVOKE OK  req_sid=0x5
CSOPEN REVOKE REJ errno=0x1102
```

Any shell-visible error can be grepped out of the klog ring with the
subsys tag `user`; the shell's error-reporting layer translates the
numeric codes to human strings.

---

## 6. Deferred: KIND_SHELL_SESSION dispatch arms

A later wave may lift the direct-call API into cap-invoke op
variants on `KIND_SHELL_SESSION`:

```
OP_OPEN_FOREIGN   op_arg[7:0]=0x12, op_arg[15:8]=tgt_slot
                  target_ptr=(tgt_sid<<32)|req_sid
                  rights_mask passed in a cap-invoke payload word

OP_ALLOW_OPEN    op_arg[7:0]=0x13, op_arg[15:8]=tgt_slot
                  max_rights in a payload word
```

Advantages of the lift:

- caller identity is mediated by `RIGHT_INVOKE` on the target
  session's cap (eliminates the "trusted direct call" posture of M6);
- a ring-3 caller can invoke without a trusted dispatch arm;
- cap-flow bookkeeping (R141) sees the request as an ordinary
  cap-invoke edge rather than an opaque kernel helper call.

Costs of the lift:

- widens the KIND_SHELL_SESSION op switch, which is already dense;
- introduces a payload-word negotiation for `rights_mask` /
  `max_rights`, which the current op switch does not have a pattern
  for (R137's remote-shell op variants push payloads through a
  separate scratch region; this is still being standardised at
  R142).

At M6 the standalone direct-call API keeps the dispatch narrow while
the ring-3-caller env is still being wired at R125.M3+. The lift is
tracked by issue `paideia-os#<future>`; the module layout here is
designed to retire cleanly when it lands (the `_cso_request` /
`_cso_allow` entry points become the op-variant handlers wholesale).

---

## 7. Encoder discipline (paideia-as pitfalls cited)

The module adheres to the standing paideia-as encoder-pitfall list
(`feedback_pdx_encoder_pitfalls`):

- `cmp rN, 0` — never `test rN, rN`
- `shl rN, 5` — allowance-row stride 32 (power-of-two; no `imul`)
- `shl rN, 7` — shell_session row stride 128 (ditto)
- `shl rN, 32 / shr rN, 32` — u32 field isolation (no `and r11, imm64`)
- `mov rax, imm32` — every return code has bit 31 clear
- Single-line `pub let name = "..."`
- Module basename `CrossSessionOpen` matches `cross_session_open.pdx`
- Fingerprint `[u8; N]` with `N = len(string) + 1` (NUL counted)
- Narrow-check uses `and reg,reg; cmp reg,reg; jne` (no `not reg`)

Stack discipline (SysV, entry `rsp%16==8`; `pushes * 8 + sub ≡ 8 mod 16`):

| function                | pushes | sub |
| ----------------------- | -----: | --: |
| `_cso_init`             |      1 |   0 |
| `_cso_allow`            |      3 |   0 |
| `_cso_request`          |      5 |   0 |
| `_cso_revoke`           |      3 |   0 |
| `_cso_revoke_allowance` |      3 |   0 |

Return-code band `0x1F20..0x1F2F` (clean per
`grep -rnE '0x1F2[0-9]\b' src/kernel/` 2026-10-14) sits adjacent to
R139.M5's ES band `0x1F10..0x1F1F` and R139.M3's HS band `0x1F00`.

---

## 8. Testing posture

At M6 the module ships with its `_cso_init` symbol and the four
public entry points. No boot-time functional test is wired yet;
coverage is deferred to the integration PR that lands:

- `_cso_init` call-site in `kernel_main.pdx` (after `_es_init`);
- unit smoke in `src/kernel/core/svc/smoke/cross_session_open_smoke.pdx`
  exercising allow -> request -> revoke -> revoke-allowance round-trip;
- fingerprint allow-list entry for the five OK tags in
  `tools/hw-smoke-fingerprints.md`.

The module's correctness at M6 landing is proven by:

1. **Static grep**: every M6 primitive's dependencies
   (`_es_share`, `_es_revoke`, `_es_share_table`, `cap_env_lookup`,
   `ss_row_in_use`, `_shell_session_pool`, `klog_s1`,
   `klog_s1_x1`, `SUBSYS_USER`) resolve to live symbols in the
   current tree (verified at write-time).
2. **Encoder-pitfall adherence** (§7).
3. **Return-code band disjointness** (§5 of the .pdx header).
4. **Register plan math** (§6 of the .pdx header, reproduced in §7
   here).

---

## 9. Retirement path

When any of the following land, this module becomes narrower:

- **KIND_SHELL_SESSION op lift** (§6): `_cso_request` /
  `_cso_allow` become op-variant handlers and the direct-call API
  retires.
- **Slab allocator with lineage tracking** (R128.M*): the cap_table
  reserved range `[128, 192)` (owned by R139.M5) collapses and
  M5's `es_find_free_cap_slot` disappears, but M6 is unaffected
  (it never touches cap_table directly).
- **Session-shutdown wiring for shares and allowances**
  (R139.M7+): a sid teardown triggers automatic revoke of every
  allowance where `target_sid == sid` and every share where
  `src_sid == sid OR dst_sid == sid`. The M6 module exposes
  the primitives (`_cso_revoke_allowance`,
  `_cso_revoke`); the wiring is a separate slice.

Full retirement happens only if the request/allow model itself is
replaced (e.g. by a persistent cap-store that preserves file-caps
across session boundaries). The current design assumes session-
local cap-envs with pull-on-demand sharing; that assumption is
load-bearing for the whole R139 line.

---

Closes paideia-os#2644.
