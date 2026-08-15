# PaideiaOS — IPC Schema: `driver_audit_channel`

**Status:** Design v1.0 (record ring + emit + reader + reconciliation landed;
cross-process wire framing deferred — see §9)
**Date:** 2026-08-14
**Round:** R29.M6-001..004 (issues #1040, #1041, #1042, #1043)
**Companion:** `design/roadmap/next-wave-softarch.md` §3 R29,
`design/drivers/blob-policy.md` §3 (D1.c — audit access: FULL),
`design/ipc/driver-hotplug-schema.md` (one-way stream template),
`src/kernel/core/driver/audit_channel.pdx` (this schema, in code).

---

## 1. Purpose

`driver_audit_channel : Channel(DriverAuditSchema)` is the **sealed,
one-way** stream on which the kernel records every capability mint,
every capability revoke, and every driver handoff. The receiving end is
`audit_supervisor`; the subject of the records — the driver being
audited — is never a sender and never a reader.

Two properties motivate the whole design:

1. **The record must exist even when nobody remembered to write it.**
   Emission is a property of the mint/revoke/handoff *primitives*, not
   of their call sites (§5). A call site can be forgotten; a primitive
   cannot be, because there is exactly one of it.

2. **The absence of a record must be as visible as its presence.**
   An audit trail that can be silently truncated is worse than none: it
   converts "no evidence" into "evidence of nothing". §4 defines what
   sealing means concretely and how a reader detects a hole.

---

## 2. Endpoint and direction

- **Emitter:** the kernel's capability layer and driver lifecycle FSM.
  Not the driver. A driver has no send handle, no emit entry point, and
  no capability that gates emission (§4.4).
- **Receiver:** `audit_supervisor` — the only holder of a read handle.
- **Direction:** one-way. There are no reply opcodes and no
  back-pressure path: the emitter never blocks on the reader, because a
  reader that could stall the emitter is a reader that could suppress
  records by refusing to drain.
- **Substrate at R29:** an in-kernel 128-record ring (`audit_channel.pdx`),
  drained in-process by the boot witness and by `safectl`. §9 records
  what changes when the channel becomes a real cross-process endpoint.

---

## 3. Record layout

Eight `u64` fields, 64 bytes, one cache line. 128 records = 8 KiB `.bss`.

| # | Field       | Meaning |
|---|-------------|---------|
| 0 | `seq`       | This record's own sequence number. Assigned at emit from a counter that is monotonic across the whole boot and **never masked**. Stored *in* the record — see §4.2. |
| 1 | `event`     | `DRV_AUDIT_EV_MINT` (1), `DRV_AUDIT_EV_REVOKE` (2), `DRV_AUDIT_EV_HANDOFF` (3). |
| 2 | `kind`      | Capability kind for mint/revoke — `0x140` KIND_HW_INTERRUPT, `0x141` KIND_HW_MSIX_VECTOR, `0x142` KIND_DMA_DOMAIN. `0` for handoff (a handoff is not a capability event). |
| 3 | `subject`   | What the event was about: the target `cap_table` slot for mint/revoke, the `driver_table` slot for handoff. |
| 4 | `principal` | Who/what authorised it: the parent cap slot for mint, the revoked slot's own id for revoke, the **from-state** for handoff. |
| 5 | `outcome`   | `0` on success; otherwise the primitive's verbatim error code (`HW_INT_MINT_*`, `MSIX_REVOKE_*`, `DMA_MINT_*`, …). |
| 6 | `ts`        | Raw TSC at emit. Ordering is carried by `seq`; `ts` exists for correlation with the durable log, not for ordering. |
| 7 | `seal`      | The chained seal word covering fields 0..6 and the previous record's seal (§4.3). |

### 3.1 Why refusals are recorded

`outcome != 0` records are emitted, not dropped. A refused mint creates
no descriptor, so it is invisible to any state-based check — and a
supervisor repeatedly attempting mints it is not entitled to is exactly
the pattern an audit trail exists to surface. The reconciliation
harness (§6) therefore counts only `outcome == 0` records, while the
stream retains all of them.

### 3.2 There is no provenance field

The record carries no "blob-loaded" bit, no image-origin field, and no
trust-tier. This is deliberate and is the mechanism by which D1.c
(§7) is enforced structurally rather than by convention: the audit
layer cannot special-case a blob driver because it is not told which
drivers are blob drivers.

---

## 4. Sealing semantics

"Sealed" is the load-bearing word in the R29 softarch line
`driver_audit_channel : Channel(DriverAuditSchema)` — one-way, sealed.
It decomposes into four concrete, checkable properties.

### 4.1 Append-only

`drv_audit_emit` is the only writer of the ring and of `_drv_audit_seq`.
No exported function erases a record, rewinds the sequence counter, or
accepts a caller-supplied `seq` or `seal`. Both are derived inside the
emitter. The ring's drop-oldest wrap is the only way a record leaves,
and it is accounted for by §4.2.

### 4.2 Gap-evident

Each record stores its own `seq` (field 0). A reader walking back from
the head requires:

> the record at back-distance `d` MUST carry
> `seq == drv_audit_seq() - 1 - d`, for every `d` in `[0, retained)`.

`drv_audit_gap_check()` enforces exactly this rule and returns
`DRV_AUDIT_ERR_GAP` on the first violation. This is what makes deletion
and reordering detectable rather than merely improbable: overwriting a
retained record with a plausible-looking one leaves its `seq` wrong
relative to its position, and removing one shifts every later record's
position relative to its stored `seq`.

Wrap is *not* a gap. `drv_audit_seq()` reports the number of records
ever emitted, `drv_audit_retained()` the number still held. A reader
that finds `seq > retained` knows precisely how many records the ring
forgot — a ring that silently forgets how much it forgot is not an
audit surface.

### 4.3 Tamper-evident

Field 7 is a hash chain:

```
seal(n) = mix(seal(n-1), fields 0..6 of record n)
seal(-1) = DRV_AUDIT_SEAL_IV
```

`mix` folds the seven fields with the golden-ratio constant
`0x9E3779B97F4A7C15` and a 29-bit left rotation, one field at a time.
`drv_audit_seal_mix` is the single definition, used by both the emitter
and the verifier, so the two cannot drift.

`drv_audit_seal_check()` recomputes the chain across the retained
window and returns `DRV_AUDIT_ERR_SEAL` on the first mismatch. Mutating
any field of any retained record breaks its own seal *and* every later
seal; there is no single-record edit that survives.

The oldest retained record cannot be checked — its predecessor's seal
has been dropped by the wrap — so verification covers
`[oldest+1, head]`. That boundary is stated rather than papered over;
closing it requires persisting the chain head at wrap, which belongs
with the durable-log work in §9.

This is a **detection** primitive, not a cryptographic one. `mix` is
not a MAC; an attacker with arbitrary kernel write can recompute the
chain. It defeats the realistic failure — a partial overwrite, a
truncation, a stale or duplicated record — not an adversary who already
owns the ring. The cryptographic upgrade path is §9.

### 4.4 Unsuppressable

There is no capability whose absence prevents emission and no
capability whose possession permits suppression: `drv_audit_emit` is
declared `capabilities: {}`. This is the sense in which the audited
driver "cannot unseal the session" — not that it is denied a right, but
that no such right exists to be acquired, delegated, or stolen.

Correspondingly, emission never fails and never returns a status. A
failable audit write invites callers to ignore the failure, and an
emitter that can be made to fail is an emitter that can be suppressed.

---

## 5. Emission sites (#1041)

Emission is wired **inside** the primitives, as a thin wrapper around
the verified inner body:

| Primitive | File | Event |
|-----------|------|-------|
| `hw_int_cap_mint` | `cap/kind_hw_interrupt.pdx` | MINT, kind `0x140` |
| `hw_int_cap_revoke` | `cap/kind_hw_interrupt.pdx` | REVOKE, kind `0x140` |
| `msix_cap_mint` | `cap/kind_hw_msix_vector.pdx` | MINT, kind `0x141` |
| `msix_cap_revoke` | `cap/kind_hw_msix_vector.pdx` | REVOKE, kind `0x141` |
| `dma_cap_mint` | `cap/kind_dma_domain.pdx` | MINT, kind `0x142` |
| `dma_cap_revoke` | `cap/kind_dma_domain.pdx` | REVOKE, kind `0x142` |
| `driver_lifecycle_transition` (to `Handoff`) | `driver/lifecycle.pdx` | HANDOFF |

### 5.1 Why a wrapper and not an edit to each exit path

Each of these primitives has four to six exit labels carrying different
error codes. Instrumenting every label means six chances to forget one
and a register-preservation argument at each. Instead the public symbol
becomes a three-push wrapper that saves the identifying arguments,
calls the (renamed, otherwise untouched) `*_inner` body, and emits with
the inner's return value as `outcome`. Every exit path is covered by
construction, the verified bodies are unchanged, and callers see the
same symbol with the same ABI.

### 5.2 Cascades emit per child

`hw_int_cap_revoke` cascades into `msix_cascade_revoke_by_parent`,
which calls the **public** `msix_cap_revoke` — so each cascaded child
emits its own REVOKE record before the parent's. The audit stream
therefore contains one revoke per descriptor actually destroyed, which
is the precondition for §6 to be a real conservation check rather than
a count of top-level calls.

### 5.3 Handoff emits only on the committed edge

`driver_lifecycle_transition` emits when — and only when — a transition
to `DRIVER_STATE_HANDOFF` has been committed to the descriptor. A
*refused* transition is not a handoff, and recording refusals here would
let the lifecycle fuzzer flood the ring with non-events.

---

## 6. Descriptor-count reconciliation (#1042)

**Invariant.** Live capability descriptors are conservable across
driver churn: every successful mint is matched by exactly one
successful revoke, and a driver restart cascade leaks nothing.

The harness reconciles two *independently derived* numbers:

- **Audit-derived:** `drv_audit_balance_since(kind, from_seq)` walks the
  retained stream and computes `(+1 per successful mint) - (1 per
  successful revoke)` for that kind, over records with `seq >= from_seq`.
- **State-derived:** `drv_audit_live_count(kind)` scans all 256
  `cap_table` descriptors and counts live ones of that kind.

`drv_audit_reconcile(kind, from_seq, base_live)` returns `0` iff

```
base_live + balance_since(kind, from_seq) == live_count(kind)
```

where `base_live` is the live count sampled at `from_seq`. Deriving the
two sides from different substrates is the point: a check that read the
same table twice would agree with itself no matter what the audit stream
said.

Failure modes are distinguished rather than collapsed:

- `DRV_AUDIT_ERR_WINDOWED` — `from_seq` is older than the retained
  window, so the balance would be computed over a truncated history.
  The harness reports that it *cannot* answer instead of returning a
  wrong answer. `drv_audit_window_ok(from_seq)` is the same test,
  callable on its own.
- `DRV_AUDIT_ERR_MISMATCH` — the two sides disagree. Either a
  descriptor was created or destroyed without a record (an emission
  gap), or a record claims a descriptor that is not there (a leak, or a
  cascade that freed rows without revoking descriptors).

The second is the bug class a cascade-revoke defect produces, and it is
detected in the direction that matters: a cascade that frees a row but
leaves the descriptor live shows up as `live_count` exceeding the
audit-derived balance, without anyone having to think to check that
particular table.

---

## 7. Blob-driver audit parity (D1.c, #1043)

`design/drivers/blob-policy.md` §3 fixes the rule: blob-consuming
drivers get the **same** audit access as native drivers — full read and
write, no separate blob-watcher, no read-only view, no filtered stream.

The implementation position is stronger than "we chose not to
discriminate": **the audit layer is not given the information required
to discriminate.** Per §3.2 no record field encodes provenance, and no
function in `audit_channel.pdx` takes a provenance, image-origin, or
trust-tier argument — `drv_audit_emit` is arity-5 and none of the five
is one. Every reader (`drv_audit_field`, `drv_audit_balance_since`,
`drv_audit_reconcile`, …) is likewise provenance-blind.

Consequently a blob-loaded driver and a native driver that perform the
same capability operations produce field-identical records modulo
subject/principal/seq/ts, and any future attempt to gate on provenance
must first add a field or a parameter — a visible, reviewable change,
not a quiet conditional. The boot witness pins this with a differential
test (§8 stages 22–24) that fails if either the record contents or the
reader results diverge between the two paths.

---

## 8. Boot witness

`src/kernel/boot/kernel_main.pdx` § `drv_audit_witness`, marker
`R29 DRIVER AUDIT OK`. Stage map (written to `_drv_audit_wit_stage`
before each gate):

```
 0  baseline: seq0 / live0 sampled, KIND_HW parent minted at slot 110
 1  mint 0x140 at slot 111 -> OK, seq advanced by exactly 1
 2  newest record: event/kind/subject/principal/outcome all correct
 3  newest record's stored seq == seq0                   [§4.2]
 4  gap check clean
 5  seal check clean
 6  second mint -> stored seq is seq0+1                  [monotone]
 7  refused mint (slot 999) -> record present, outcome != 0   [§3.1]
 8  balance_since == 2 (the refusal is not counted)
 9  revoke one -> balance 1
10  revoke other -> balance 0
11  reconcile == 0                                        [§6]
12  gap + seal still clean after the churn
13  poke a retained record's outcome -> seal check trips  [§4.3]
14  restore -> seal check clean again
15  poke a retained record's seq -> gap check trips       [§4.2]
16  restore -> gap check clean again
17  window_ok(seq0) == 1, window_ok(head+1) == 0
18  cascade: parent + 2 MSI-X children, revoke parent
19  cascade left one REVOKE record per child              [§5.2]
20  reconcile clean for BOTH 0x140 and 0x141              [no leak]
21  handoff transition -> HANDOFF record, from-state carried
22  refused transition emits nothing                      [§5.3]
23  blob-path mint/revoke vs native-path mint/revoke:
    event/kind/outcome fields identical                   [§7]
24  both paths reconcile to zero identically              [§7]
```

Stages 13–16 are the ones that make the sealing claim non-vacuous: a
gap check that never trips and a seal check that never trips are
indistinguishable from `return 0`.

---

## 9. Deferred

- **Cross-process framing.** At R29 the channel is an in-kernel ring
  with in-kernel readers. The wire form reuses the 8-byte header from
  `design/ipc/frame.pdx` with `op = DRV_AUDIT_OP_RECORD (0x01)` and the
  64-byte record as payload; `reply_endpoint_id` MUST be 0 (one-way,
  §2). Landing it belongs with the `audit_supervisor` process.
- **Durable drain.** Forwarding to `/system/audit/log.pdaudit` through
  `klog_audit_forward` is deliberately *not* wired: at INFO level it
  would put ~40 lines per boot on the console, and at ERROR level it
  would hand an unprivileged writer a console amplifier. The drain is
  the supervisor's job, on the supervisor's schedule.
- **Chain-head persistence at wrap** (§4.3), which closes the
  unverifiable-oldest-record boundary.
- **Cryptographic seal.** `mix` becomes a keyed MAC once R32 lands a
  real primitive; the field is already 64 bits wide and the verifier is
  already a single function, so the swap is local.

---

## 10. References

- `design/roadmap/next-wave-softarch.md` §3 R29 — `driver_audit_channel`
  as a sealed one-way session.
- `design/drivers/blob-policy.md` §3 — D1.c, audit access FULL.
- `design/ipc/driver-hotplug-schema.md` — one-way stream template.
- `src/kernel/core/driver/sig_telemetry.pdx` — the record-ring shape
  this schema follows (blob-policy §1.10).
- `src/kernel/core/klog/audit.pdx` — the durable audit bridge (§9).
