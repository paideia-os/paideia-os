# Recovery Failure — Key Loss Consequences

**R48.M6-005 (#1548)**
**Status:** design decision (2026-08-21)
**Depends on:** `design/user/model.md` §8 (Recovery + key loss)

---

## 1. What this document is

`design/user/model.md` §8 states the load-bearing decision: **there is
no back door**. This document is the *full accounting* of the
consequences of that decision, per key-loss scenario, per user role.
It is the reference an operator reaches for when a `user_sk` has gone
missing and they need to know what — precisely — is recoverable and
what is not.

It is **not** a set of "recovery procedures" in the traditional sense.
Every scenario below terminates in one of three outcomes:

- **Recovery via cap-tree walking** — the specific user's caps are
  reconstructed by an authority the model already recognizes
  (founder, in most cases), typically at the cost of a fresh
  `KIND_USER` mint that severs continuity with the old identity.
- **Signed-backup restore** — the user's data is recoverable from a
  signed external backup; identity is not.
- **Loss** — the caps and/or data are stranded. No mechanism recovers
  them.

## 2. Scenario matrix

| Actor       | What is lost                       | Consequence                                                          | Rationale (see §3) |
|-------------|------------------------------------|----------------------------------------------------------------------|--------------------|
| Ordinary user | `user_sk` only (passphrase forgotten, no MFA) | Cascade revoke by founder; new `KIND_USER` mint; home subtree transferred by delegation. | §3.1               |
| Ordinary user | `user_sk` + MFA token (both destroyed)         | Same as above; MFA loss doesn't change the recovery path.            | §3.1               |
| Ordinary user | Home subtree corrupt (sk intact)               | Signed-backup restore under existing identity; sk re-signs restored inodes. | §3.2               |
| Ordinary user | Home subtree deleted (`user remove --wipe`)    | If within 24h and `undo` cap held: recoverable via pdx-journal. Else: loss. | §3.2               |
| Founder     | `user_sk` only                                 | **Loss.** Machine bricked to its data. Reinstall + backup restore is the only path. | §3.3               |
| Founder     | `user_sk` + machine's `machine_sk` (TPM wiped) | **Loss.** As above; TLS server identity also lost, requiring re-attestation on remote clients. | §3.3, §3.4         |
| Any user    | Encrypted vault contents (KDF unlock key lost) | Vault contents are unrecoverable; other caps unaffected.             | §3.5               |
| Any user    | Signed backup file corrupt                     | **Loss.** No secondary source of truth in the model.                  | §3.6               |

## 3. Rationale, per scenario

### 3.1 Ordinary user, sk lost

- Founder holds the `KIND_USER` root cap for every user they minted.
  A `user remove alice` cascades every cap alice held into the void;
  a subsequent `user add alice` mints a fresh keypair.
- The old home subtree can be transferred to the new alice via a
  founder-signed delegation of the subtree cap. The new alice's
  `user_sk` re-signs the inodes at first write (PdxFS v1's signed-
  inode migration path).
- **Audit trail:** the founder-recovery event is journaled to
  `/system/audit/user-events/`, signed by founder. Alice sees, in her
  fresh session's audit view, that her identity was reconstituted at
  a specific tick.

### 3.2 Home subtree corrupt / deleted

- **Corrupt (sk intact):** the user restores from their own signed
  backup. PdxFS v1 verifies each inode's signature against the
  restoring user's `user_pk`; a signature mismatch surfaces as a
  `KIND_SIGNATURE` fault at first read of the affected inode. The
  user resigns via a `pdx repair` sweep.
- **Deleted (`user remove --wipe`) within 24 h:** the pdx-journal
  entry for the wipe is still live; a founder-held `undo` cap
  reverses it (per `design/tooling/plan.md` I5). After 24 h the
  journal has GC'd and the data is permanently gone.

### 3.3 Founder, sk lost

- **The model deliberately does not offer founder recovery.** A
  founder-recovery mechanism is a persistent kernel-level backdoor;
  it would sit outside the cap lattice by definition. Under Pillar 3
  (userspace-first, no in-kernel superuser), no such mechanism can
  be added without invalidating the model.
- The recovery path is: **reinstall PaideiaOS**, then restore user
  data from signed backups under a new founder identity. Every
  restored user's inodes are re-signed under the new user identity
  at first write (§3.2's PdxFS v1 signed-inode migration).
- **Preventive discipline:** MFA is strongly recommended for founder
  specifically because §8's "there is no back door" is inflexible.
  The user model recommends passphrase + hardware token for the
  founder role by default.

### 3.4 Machine identity lost (`machine_sk`)

- Independent of user identity. Loss of `machine_sk` invalidates the
  TLS server-side identity that remote clients pinned against — every
  remote client will TOFU-prompt on next connect (§6.3 of model.md).
- Attestation records signed by the old `machine_sk` are still
  verifiable against the record they signed; new attestations require
  the new `machine_sk`.
- **Not recoverable.** A machine-identity recovery mechanism would
  allow re-signing the historical attestation record — indistinguishable
  from an attacker forging one. The correct path is: distribute the
  new `machine_pk` fingerprint through an out-of-band channel and
  let clients re-pin.

### 3.5 Vault contents lost (KDF unlock key)

- The `vault` tool (per `design/tooling/plan.md`) encrypts secrets
  under a KDF-derived key. Losing the KDF unlock key (typically a
  separate passphrase) makes the vault's contents unrecoverable.
- Other caps are unaffected — the `KIND_USER` cap is orthogonal to
  vault contents.

### 3.6 Signed backup corrupt

- The signed backup is the last line of defense. If it is corrupt,
  there is no secondary source of truth in the model. The
  recommendation is redundant, geographically-distributed backups
  (which is orthogonal to the OS design — a policy for the operator).

## 4. What we deliberately DID NOT design

For completeness, the following were considered and rejected:

- **"Recovery codes" issued at user creation.** A recovery code is
  functionally a second passphrase — it either grants full authority
  (a shell as the user), which is the very setuid-superuser pattern
  the model rejects, or it grants a specific narrow authority (a
  KIND_USER remint), which is what founder already provides at zero
  additional cryptographic footprint. Adding recovery codes is pure
  cost with no additional expressiveness.

- **Cross-machine identity federation for recovery.** A user identity
  portable across machines could serve as a "recovery source" — but
  the same portability lets any of those machines forge caps under
  the user's identity if it is compromised. The model chose
  per-machine identity; recovery scenarios inherit that choice.

- **Founder-key escrow via a hardware token.** An escrow token is a
  founder-key holder in another form; whoever holds the escrow token
  is functionally an unaudited co-founder. The model refuses shared
  founder authority (§3.4 "only one founder exists at a time");
  escrow would silently violate that.

- **"Emergency shell" from an installer boot.** A booted installer
  that could open a shell in the installed system would be a full
  authentication bypass. The installer can *reinstall* — replacing
  the entire founder identity — but cannot re-open the existing
  identity's authority. This is intentional and load-bearing.

## 5. What the operator should do

- **Back up.** The single most important discipline is that every
  user (especially founder) backs up their home subtree under their
  `user_sk`'s signature to durable external storage on a schedule
  the operator can articulate.
- **MFA the founder.** Hardware token (FIDO2-analog) or biometric
  reader is strongly recommended for the founder role specifically
  because §3.3's rationale is inflexible.
- **Journal the backup discipline.** The `pdx backup` tool
  (P2 in `design/tooling/plan.md`) writes an audit event on every
  successful backup — audit inspection surfaces "this account has
  not backed up in N days" as a warning surface for the tool
  ecosystem.

## 6. Relationship to the audit journal

Every recovery action lands as an audit event under
`/system/audit/user-events/`:

- Founder-triggered cascade revoke + re-mint of a user identity:
  `UEJ_KIND_REVOKE` + `UEJ_KIND_CREATE` events, signed by founder.
- Signed-backup restore: no journal entry today (out of scope for
  this milestone); the tool ecosystem lands one at P2.

## 7. Open questions

Deferred to a second design pass, driven by first-user feedback:

- **Should founder loss trigger a machine-wide klog banner on every
  boot until a new founder is provisioned?** Argues yes — makes the
  state visible; argues no — a stolen device would broadcast its
  vulnerability. Deferred pending user-testing.
- **Should the `vault` tool support Shamir-style secret-sharing so
  multiple parties can jointly recover?** Argues yes — matches
  operator practice; argues no — introduces a distributed-trust
  posture the rest of the model does not have. Deferred.

---

**Status:** Ready for filing as the R48.M6-005 completion note.
Cross-referenced from `design/user/model.md` §8 as the full
consequence table.
