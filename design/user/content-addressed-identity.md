# Content-addressed identity — R106+ authoritative model

**Status:** Frozen decision (2026-09-03). Supersedes the R74 `/etc/passwd`
freeze in [etc-layout.md](etc-layout.md) §"Original (historical) freeze".

**Supersedes:**
- `design/user/etc-layout.md` §passwd (R74.M1-002 / paideia-os #1940) —
  retired in favor of content-addressed records.

**Depends on (paideia-as):**
- v0.24.0 `mldsa65_sign` intrinsic (already landed) — signing / verify.
- v0.33 `argon2id_derive`, `chacha20poly1305_seal`, `mlkem768_encap`
  intrinsics (in-flight, paideia-as milestone `v0.33 — post-quantum
  crypto substrate`) — KDF for passphrase → seed, AEAD for at-rest
  wrapping of derived secrets, and forward-secret session key
  encapsulation.

**Research lineage:**
- KeyKOS / EROS / seL4 — capabilities as the sole authorization primitive;
  no ambient authority; owners are cap-holders, not numeric ids.
- Plan 9 — per-user namespaces, no shared `/etc/passwd`, identity as a
  cryptographic keypair (`factotum`).
- Tahoe-LAFS — content addressing of user records; a record is named by
  the hash of its subject, not by a mutable table entry.
- sigstore / Rekor — signed records with a transparent grantor
  countersignature so a record's origin is publicly auditable.
- W3C Verifiable Credentials — a user record is a self-issued attestation
  countersigned by an issuer (here, a grantor), not a database row.
- SPKI / SDSI — locally-scoped names ("alice-at-this-host") that resolve
  to public keys, decoupling human-readable aliases from the identity
  they refer to.

---

## 1. Identity primitive

A **user** is an ML-DSA-65 keypair. The canonical identifier for that
user, everywhere in the OS, is:

    fp = SHAKE-256(pubkey)[0..32]      # 32-byte fingerprint
                                       # rendered as 64 lowercase hex chars

That fingerprint is the user's address. It appears:

- as the filename component of the user record
  (`/system/users/<fp>.pdxuser`),
- as the home-directory path component (`/home/<fp>/`),
- as the `owner_fingerprint` field on every capability record the user
  mints,
- as the subject of every alias record (`/system/aliases/<alias>.pdxalias`
  binds an alias string to a fingerprint).

There is **no** sequential `uid`/`gid`. There is no ambient identity
table. The fingerprint is the identity; anything that talks about a user
talks about that fingerprint.

Fingerprint width is fixed at 32 bytes so it fits one XMM register and
one filename component under PdxFS's 255-byte NAME_MAX, and so the
hex-rendered form (64 chars) fits inside a single ANSI terminal line
with room for a prefix.

---

## 2. User record: `/system/users/<pk_fingerprint>.pdxuser`

The authoritative on-disk record for a user. Signed. PdxFS lives under
`/system/users/` (the persistent PDXB volume that also hosts
`/system/aliases/`, `/system/caps/`, etc.).

### Schema (KIND_USER, freeze target R108.M2)

    struct PdxUserRecord@0.1 {
        magic:              [u8; 8]     = "PDXUSR01"
        record_version:     u16         = 1
        pubkey:             [u8; 1952]  // ML-DSA-65 public key
        fingerprint:        [u8; 32]    // SHAKE-256(pubkey)[0..32];
                                        // redundant with filename but
                                        // signed, so a rename cannot
                                        // silently retarget the record
        created_at:         u64         // nanoseconds since PaideiaOS
                                        // epoch (2025-01-01T00:00:00Z)
        alias_hint:         [u8; 32]    // owner-declared preferred alias;
                                        // authoritative alias binding
                                        // lives in the alias registry,
                                        // this field is a hint for
                                        // first-boot display only
        revoked_at:         u64         // 0 = live; non-zero = revoked
                                        // (see §8)
        delegated_caps_len: u16         // count of cap-refs granted at
                                        // record creation
        delegated_caps:     [CapRef; N] // KIND-tagged handles the user
                                        // is provisioned with
                                        // (e.g. KIND_HOME_ROOT for their
                                        // own /home/<fp>/, KIND_ELEVATE
                                        // for the founder's first boot)
        self_sig:           [u8; 3309]  // ML-DSA-65 sig over the record
                                        // by `pubkey` itself
        grantor_fingerprint:[u8; 32]    // countersigner's fingerprint;
                                        // for the founder, this is the
                                        // founder's own fp (self-issued)
        grantor_sig:        [u8; 3309]  // ML-DSA-65 sig over the record
                                        // by the grantor's key
    }

Signed by:

- the user's own key (self-attested: "this is my public key, this is my
  chosen alias hint, these are the caps I received"),
- a **grantor** who countersigns to establish origin. For the first user
  on a fresh install, the grantor is the founder themself (self-issued,
  matching the sigstore "root of trust" pattern). For any subsequently
  invited user, the grantor is any existing live user with a valid
  KIND_INVITE cap (see R109 M4).

Both signatures cover every field before `self_sig`. `grantor_sig` also
covers `self_sig` and `grantor_fingerprint` — so tampering with the
grantor identity, or splicing a valid self-sig onto a different
grantor's endorsement, breaks verification.

### Read path

Anything that needs to talk about a user opens
`/system/users/<fp>.pdxuser`, verifies both signatures via
`mldsa65_verify` against `pubkey` and the grantor's own pubkey (fetched
recursively — the grantor's fingerprint locates their record), and
caches the verified `PdxUserRecord` in a `KIND_USER` cap it hands out.

### Write path

Only the user themself can (re)issue their own record. Rotation and
revocation are §8.

---

## 3. Alias registry — `KIND_USER_ALIAS`

A separate, signed table binding human-readable aliases to fingerprints.
Kept separate from the user record so an alias can be renamed without
touching the record (and so the alias namespace can be enumerated
without walking every user record).

### On-disk

    /system/aliases/<alias>.pdxalias

### Schema (KIND_USER_ALIAS_RECORD, freeze target R108.M3)

    struct PdxAliasRecord@0.1 {
        magic:              [u8; 8]     = "PDXALS01"
        record_version:     u16         = 1
        alias:              [u8; 32]    // ASCII [a-z][a-z0-9_-]{0,30};
                                        // enforced at write time by
                                        // /bin/alias
        subject_fingerprint:[u8; 32]    // the user this alias resolves to
        created_at:         u64
        revoked_at:         u64
        subject_sig:        [u8; 3309]  // signed by the SUBJECT's key
                                        // (a user chooses their own alias)
    }

### The cap: `KIND_USER_ALIAS`

A read-only handle granting the holder the ability to resolve
`alias -> fingerprint` and, in reverse, `fingerprint -> alias` (for
pretty-printing). Held by:

- the shell (for tokenizer `~alice` expansion — see §4),
- `elevate` (for user-facing prompts that render aliases),
- any tool that displays user identity in a UI.

The cap does **not** grant write. Writing an alias record is a separate
capability (`KIND_ALIAS_MINT`), granted only to `/bin/alias`, which
enforces the ASCII-only shape, the uniqueness constraint (an alias binds
to exactly one live fingerprint at a time), and the subject-sig
requirement.

Alias policy: **first-come-first-served, per-live-record.** Two users
can hold the *same* alias only if one is revoked. A rename issues a new
`<newalias>.pdxalias` and revokes the old one in the same transaction.

---

## 4. Home directory shape

Canonical:

    /home/<pk_fingerprint>/

That is the only form the filesystem sees. `ls /home/` shows fingerprint
directories (64 hex chars each). The shell renders them as `~alias` via
reverse-alias-lookup when displaying paths for the user, but the on-disk
name is always the fingerprint.

### Tokenizer novel-tilde (R106.M4 syntax; R108.M4 real alias resolution)

The shell's tokenizer expands a leading `~` at **any** argv position
(not just argv[0]). Three forms:

| Form            | Resolution                                                |
|-----------------|-----------------------------------------------------------|
| `~`             | `$HOME` (the current session's home; equivalent to bare `cd`) |
| `~alice`        | `KIND_USER_ALIAS.lookup("alice") -> fp; /home/<fp>`       |
| `~<64-hex>`     | Literal fingerprint; `/home/<64-hex>` (no registry lookup) |

Failure modes are **hard errors**, not silent literals:

- `~unknown` where `unknown` is not a live alias → tokenizer error
  `E_ALIAS_UNRESOLVED: 'unknown'`, argv construction aborts, no exec.
- `~alice/foo` and `~alice` are both valid; the trailing path is
  concatenated after resolution.
- `~<40-hex>` (any hex length other than 64) → tokenizer error
  `E_FINGERPRINT_MALFORMED`.

Bare `cd` is a hard error with candidate suggestions (Plan 9 `rc`
lineage), not a POSIX-style silent chdir to `$HOME`:

    $ cd
    cd: ambiguous target. did you mean:
        cd ~           # chdir to your home
        cd -           # chdir to previous working directory
        cd /           # chdir to root
    cd: aborted; specify a target explicitly.

Rationale: bare `cd` in POSIX is a footgun (unambiguous chdir with
ambiguous author intent — did they mean home, root, or previous?);
PaideiaOS's shell will not carry that.

Cross-ref: shell tokenizer/dispatcher extraction to the new
`paideia-os/shell` satellite repo lands in R106.M4.

---

## 5. Capability model — no uid/gid, no ACLs

Object ownership and access are expressed as capability holds, not as
`(uid, gid, mode)` tuples.

- Every persistent object (file, directory, cap-mint gate, etc.) carries
  an `owner_fingerprint` in its metadata.
- Access to the object is gated by **holding a cap** whose `subject`
  matches (or is delegated from) that owner's fingerprint. There is no
  `world`/`group`/`other` shorthand; a permission is a cap-mint that has
  been delegated to a fingerprint.
- The `elevate` broker (existing) mediates cap delegation: a user with
  `KIND_ELEVATE` on some cap-mint may issue a subordinate cap to another
  user's fingerprint with reduced scope (time-bound, count-bound,
  op-bound). This is the KeyKOS/EROS pattern.

The user record's `delegated_caps` field (§2) is the initial cap
bundle each user boots with. For the founder that includes
`KIND_ELEVATE` on the root cap-tree. For invited users it is the
narrower set the inviter countersigned into the invite (R109 M4).

Practically: `/home/<fp>/` boots with `owner_fingerprint = <fp>`, a
mounted PdxFS subtree whose root inode's cap-mint issues only to `<fp>`
by default. Sharing a file with another user means issuing them a
subordinate cap via `elevate`, not `chmod`-ing anything.

---

## 6. First-boot founder provisioning

Interactive, one-shot, at the first boot on a fresh persistent volume
(when `/system/users/` is empty).

Sequence:

1. UART/TUI prompt: `PaideiaOS first boot. Choose a founder alias:`
   (validated against the alias-shape regex from §3).
2. `Set a passphrase:` (echoed once, confirmed once; passphrase is never
   stored).
3. `argon2id_derive(passphrase, salt=SHAKE-256("paideia-os:founder-seed-v1"),
   m=64MiB, t=3, p=1) -> 32-byte seed`.
4. `mldsa65_keygen(seed) -> (pubkey, secretkey)`. The secret key is
   wrapped with `chacha20poly1305_seal(secretkey, key=argon2id_derive(
   passphrase, salt=SHAKE-256("paideia-os:sk-wrap-v1"), ...))` and
   stored at `/system/keys/<fp>.sk.sealed`. The passphrase is scrubbed
   from memory and discarded; it is never persisted.
5. Compute `fp = SHAKE-256(pubkey)[0..32]`.
6. Compose `PdxUserRecord@0.1` with:
   - `pubkey`, `fingerprint = fp`, `created_at = now()`,
   - `alias_hint = <chosen alias>`, `revoked_at = 0`,
   - `delegated_caps = [KIND_HOME_ROOT(/home/<fp>/), KIND_ELEVATE(root),
     KIND_INVITE(unbounded)]`,
   - `self_sig = mldsa65_sign(record, secretkey)`,
   - `grantor_fingerprint = fp`, `grantor_sig = mldsa65_sign(...)` (self-
     issued for the founder — the sigstore root-of-trust pattern).
7. Write `/system/users/<fp>.pdxuser` atomically (WAL commit).
8. Write `/system/aliases/<alias>.pdxalias` with `subject_sig`.
9. `mkdir /home/<fp>/` with `owner_fingerprint = fp`.
10. Init hands the shell a `KIND_USER` cap for this user plus a
    `KIND_USER_ALIAS` read-only cap, and `HOME=/home/<fp>`.

Failure mode: if any step 6–9 fails, the WAL rolls back and the boot
retries the interactive prompt (idempotent).

After first boot, the founder can invite additional users via
`invite <alias>` (R109.M4), which mints a `KIND_INVITE` cap the invitee
redeems on their first login.

---

## 7. Persistence

Identity survives reboot because `/system/users/*.pdxuser`,
`/system/aliases/*.pdxalias`, and `/system/keys/*.sk.sealed` all live on
the persistent PdxFS volume (the same volume R106 makes `/home` live
on).

- Losing the volume = losing the identities (backup discipline is a
  future round).
- Losing the passphrase = losing access to the wrapped secret key; the
  founder must revoke and re-provision from a recovery cap (R109+ scope
  — recovery-cap design is out of scope for this doc).
- Copying the volume to another machine = copying the identities. The
  fingerprints are content-addressed, so they are stable across the
  move; nothing binds them to a specific machine (per-device
  attestation is §8 future work).

---

## 8. Threat model

**Passphrase compromise.** The attacker recovers `secretkey`, can sign
as the user. Mitigation: the compromised user issues a new
`PdxUserRecord` with `revoked_at = now()` under their old fingerprint,
provisions a fresh keypair (new fingerprint), and re-mints downstream
caps. Anything holding a cap subject-bound to the old fingerprint fails
verification once the revocation record is visible. This is the
sigstore Rekor pattern (append-only, revocation-by-record).

**Device compromise.** An attacker with physical access to an unsealed
running system inherits the ambient session caps. Out of scope for
R106–R109; the per-device attestation cap (`KIND_DEVICE_ATTEST`) that
would bind session caps to hardware is future work.

**No shared credentials.** Each user's keypair is theirs alone. There
is no `root` account, no `wheel` group, no shared passphrase. Elevated
operations are performed by delegation of a `KIND_ELEVATE` cap, not by
`su root`.

**Alias-hijack resistance.** An alias record must be signed by the
subject fingerprint (§3), so a third party cannot bind an alias to a
key they do not own. The uniqueness constraint (one live alias, one
fingerprint) is enforced by `/bin/alias` at write time and re-checked
by the shell tokenizer at read time.

**Grantor-transitive trust.** The record chain is:
`user -> grantor -> ... -> founder (self-issued)`. Verification walks
the chain; a broken link (missing grantor record, mismatched
fingerprint) fails the whole record. This is the SPKI/SDSI naming
graph, restricted to a single-rooted tree for R108.

---

## 9. Alignment with existing tree

### 9.1 R106 placeholder registry — `src/user/founder_constants.pdx`

R106.M1 (paideia-os #2228, **CLOSED** at commit 444da68) introduced
`src/user/founder_constants.pdx` (module `FounderConstants`) to isolate
the build-time placeholder fingerprint that gives the persistent-home
tree its final SHAPE (`/home/<64-hex-fp>/` per §4) before R108.M2
lands real Argon2id + ML-DSA-65 key generation. Every consumer that
would otherwise embed a literal placeholder string imports from this
module by name, so R108.M2 can retire the placeholder in a single
commit — flip the `fc_placeholder_*` symbols to the real founder
fingerprint (derived from `argon2id_derive` + `mldsa65_keygen` +
`SHAKE-256(pk)[0..32]`), and every path consumer picks up the change
through the linker.

Placeholder value: `deadbeef00000000000000000000000000000000000000000000000000000000`
(64 lowercase hex chars = 32 bytes decoded). The `deadbeef` prefix is
a widely-recognised sentinel; the all-zero tail is an additional
signal (a real SHAKE-256-drawn fingerprint has every bit populated).
No user can hold the ML-DSA-65 private key whose
`SHAKE-256(pk)[0..32]` equals `deadbeef00...` without breaking
SHAKE-256 preimage resistance.

Placeholder → rename map (R106 → R108.M2):

| R106 placeholder symbol                                | R108.M2 rename target                                              | Kind        |
|--------------------------------------------------------|--------------------------------------------------------------------|-------------|
| `src/user/founder_constants.pdx` (module)              | `src/user/founder_identity.pdx` (module `FounderIdentity`)         | file+module |
| `fc_placeholder_fp_hex : [u8; 65]`                     | `fc_founder_fp_hex : [u8; 65]`                                     | rodata      |
| `fc_placeholder_fp_hex_len : u64 = 64`                 | `fc_founder_fp_hex_len : u64 = 64` (width invariant)               | rodata      |
| `fc_placeholder_home_path : [u8; 71]` = `/home/deadbeef00…\0` | `fc_founder_home_path : [u8; 71]` = `/home/<real_fp_hex>\0`  | rodata      |
| `fc_placeholder_home_path_len : u64 = 70`              | `fc_founder_home_path_len : u64 = 70` (width invariant)            | rodata      |

Stable across the rename (not placeholders — kept as-is):

| Symbol                                        | Rationale                                                      |
|-----------------------------------------------|----------------------------------------------------------------|
| `FC_FINGERPRINT_BYTES : u64 = 32`             | Width primitive from §1 (SHAKE-256(pk)[0..32]); pre-real.      |
| `FC_FINGERPRINT_HEX_CHARS : u64 = 64`         | Hex-rendered width from §1; pre-real.                          |
| `fc_home_root_path : [u8; 6] = "/home\0"`     | Real `/home` root path (parent of every per-user home).        |
| `fc_home_root_path_len : u64 = 5`             | Wire length of the real `/home` root path.                     |

Current consumers of the placeholder symbols (as of R106.M1):

| Consumer                        | Symbols used                                                  | Notes                                                 |
|---------------------------------|---------------------------------------------------------------|-------------------------------------------------------|
| `src/user/rootfs_seed.pdx`      | `fc_home_root_path`, `fc_placeholder_home_path`               | `mkdir /home/` (0755) + `mkdir /home/<fp>/` (0700).   |
| `src/user/init.pdx` (R106.M2)   | `fc_placeholder_home_path`                                    | Composes `HOME=/home/<fp>` env for exec into `/bin/sh`. |
| `src/user/dispatch.pdx` / `shell.pdx` (R106.M3) | `fc_placeholder_home_path`                    | `/home/operator` retirement path.                     |

Retirement path: R108.M2 (see §9.2 round map row) rewrites the four
`fc_placeholder_*` symbols in place with the real founder fingerprint
after the interactive first-boot sequence (§6) computes it, renames
the module file to `founder_identity.pdx`, and every listed consumer
picks up the new value through the linker without any per-consumer
source edit.

### 9.2 Kernel-side scaffolds — `src/kernel/core/user/`

The following files under `src/kernel/core/user/` are arbitrated-0
scaffolds today (compiled, wired into boot, but no real crypto):

- `founder_home.pdx` — allocates `/home/<placeholder_fp>/` at rootfs
  seed. Flips to arbitrated-1 when R108.M1 lands signed-record I/O.
- `founder_keygen.pdx` — currently a stub that hardcodes a placeholder
  32-byte fingerprint. Flips to arbitrated-1 when `mldsa65_keygen` +
  `argon2id_derive` are available (paideia-as v0.33; R108.M1).
- `founder_cap_seed.pdx` — mints the founder cap bundle. Flips to
  arbitrated-1 when `delegated_caps` in the user record become the
  authoritative source (R108.M2).
- `user_registry.pdx` — in-memory registry of live users. Flips to
  arbitrated-1 when it becomes a *cache* over
  `/system/users/*.pdxuser` (R108.M2 read path).
- `user_delegation_record.pdx`, `user_event_signing.pdx`,
  `user_events_journal.pdx` — audit-log surface for cap delegations.
  Already signed via v0.24.0 `mldsa65_sign`; arbitrated-1. No change
  under this doc.
- `user_cap_mint.pdx`, `elevate_policy.pdx`, `elevate_smoke.pdx` —
  the elevation broker. Cap-model surface is already correct per §5;
  no change under this doc.
- `first_boot.pdx`, `first_boot_smoke.pdx`, `pass_readline.pdx` —
  first-boot flow scaffold. Flips to arbitrated-1 at R108.M2 when the
  §6 sequence becomes real.

Round map:

| Round  | Files that flip arbitrated-0 → arbitrated-1                              |
|--------|---------------------------------------------------------------------------|
| R108.M1 | `founder_keygen.pdx`, signed-record I/O primitives (new)                |
| R108.M2 | `user_registry.pdx`, `first_boot.pdx`, `founder_cap_seed.pdx`; `src/user/founder_constants.pdx` → `founder_identity.pdx` (see §9.1) |
| R108.M3 | (new) `alias_registry.pdx`, `/bin/alias`                                |
| R108.M4 | (shell repo) tokenizer novel-tilde real resolution via `KIND_USER_ALIAS` |
| R108.M6 | `founder_home.pdx` (owner_fingerprint = real founder fp)               |

---

## 10. Test discipline

Every arbitrated-1 flip lands with a boot smoke and a userspace
round-trip test. Standing set:

- **Signed-record round-trip** (`test_pdxuser_signed_roundtrip.pdx`):
  compose a synthetic `PdxUserRecord@0.1`, sign with a deterministic
  test key, write to a tmpfs `/system/users/`, read back, verify both
  sigs, compare fields byte-for-byte. Failure at any step is a boot
  panic under the test kernel.
- **Alias registry lookup** (`test_alias_lookup.pdx`): seed
  `/system/aliases/alice.pdxalias`, resolve `alice`, assert
  `subject_fingerprint` matches. Then rotate: write `bob.pdxalias`
  pointing at same fp, assert lookup succeeds for both. Then revoke
  `alice`, assert lookup fails with `E_ALIAS_UNRESOLVED`.
- **Founder-seeded boot** (`boot_r108_founder_first_boot`): boot with
  an empty `/system/users/`, drive the interactive prompt via a
  scripted UART fixture, verify `/system/users/<fp>.pdxuser` and
  `/home/<fp>/` exist after boot. Reboot. Verify the same fingerprint
  still owns `/home/<fp>/`.
- **Reboot persistence** (`boot_r108_founder_survives_reboot`): after
  the first-boot smoke, drop into shell, `echo hi > ~/probe.txt`,
  reboot, assert `cat ~/probe.txt` returns `hi`. This composes the
  R106 persistent-home smoke with the R108 identity smoke — both must
  be green together.

---

## Cross-references

- Wave plan: [../roadmap/persistent-home-wave.md](../roadmap/persistent-home-wave.md)
- R106 (persistent /home substrate, single-user path): wave-plan §R106.
- R107 (mount shape + devfs + file-bdev): wave-plan §R107.
- R108 (identity substrate, this document's implementation round):
  wave-plan §R108.
- R109 (multi-user session + login): wave-plan §R109.
- Retired: [etc-layout.md](etc-layout.md) §passwd.
- paideia-as v0.33 crypto substrate (Argon2id / ChaCha20-Poly1305 /
  ML-KEM-768): tracked in the paideia-as repo, milestone
  `v0.33 — post-quantum crypto substrate`.
- Shell tokenizer + dispatcher (novel-tilde, bare-cd error): the new
  `paideia-os/shell` satellite repo (Q8 extraction).
