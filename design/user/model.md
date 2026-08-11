# PaideiaOS User Management — Design

**Status:** proposal (2026-08-11)
**Scope:** how users are represented, created, authenticated, delegated to, and removed on PaideiaOS.
**Depends on:** the capability model (KIND_ enum, linear caps, cascade revocation), the ML-DSA-65 root key from R32, PdxFS v1 (R42) for durable + snapshotted per-user home partitions.
**Does not depend on:** Unix uid/gid, `/etc/passwd`, PAM, setuid, capabilities(7). All of these are replaced by the model below.

---

## 0. Reading order

- §1 executive summary (what "user" means)
- §2 identity, authentication, credentials
- §3 the first user — `founder`
- §4 creating additional users
- §5 elevation model (no setuid, no `sudo`)
- §6 remote users + logins from other machines
- §7 removal / deletion
- §8 recovery + key loss
- §9 signed on-disk representation
- §10 relationship to other subsystems (drivers, home partitions, audit)
- §11 readiness — what's landed today, what's missing, staged rollout
- §12 open questions

---

## 1. Executive summary

A user in PaideiaOS is not a uid/gid integer. A user is:

1. **A signing identity** — an ML-DSA-65 keypair `(user_pk, user_sk)`, minted at account creation, using the same PQ signature infrastructure as the R32 root, PdxFS v1 signed inodes, firmware blobs (D1.a), and tool packages (D4). The public key is the canonical identity; the display name is just a mutable label.
2. **A root capability** — `Cap<KIND_USER, {pk_fingerprint, quota_bytes, created_ns, delegated_by: Option<user_pk>}>`, minted at account creation and held by the user's login session. Every per-file / per-network / per-device cap the user ever holds derives from this root. Revoking `KIND_USER` cascades: every downstream cap dies, no scavenger hunts.
3. **A home subtree** — a PdxFS v1 subtree rooted at the user's `KIND_USER` cap. Trash journal for I5 undo (per `design/tooling/plan.md`) lives here. No other user holds a cap over this subtree unless the owner explicitly delegates.

There is no `/etc/passwd`. The user registry is a set of signed records under `/system/users/<pk_fingerprint>.pdxuser`, each countersigned by the enclosing supervisor. The kernel does not maintain a user table — user identity is a userspace concept enforced entirely by capability holds.

---

## 2. Identity, authentication, credentials

### 2.1 Keys at rest

`user_sk` is stored encrypted at `<home>/.identity/user_sk.enc`. Encryption:

- Argon2id-KDF (`memory=256 MB, iterations=4, parallelism=4`) over the user's passphrase produces a 32-byte unlock key.
- ChaCha20-Poly1305 seals `user_sk` under the unlock key. Nonce is stored alongside.
- No plaintext `user_sk` ever at rest. In-memory during a session, held in a `Cap<KIND_MEMORY>` marked non-swappable + zeroed-on-drop.

`user_pk` is stored plaintext at `<home>/.identity/user_pk.pdxid` and also copied to `/system/users/<pk_fingerprint>.pdxuser` (see §9).

### 2.2 Authentication paths

**Interactive local (fb-console or GUI):**
1. User selects account (displayed by display name; internal lookup by `pk_fingerprint`).
2. Prompt for passphrase.
3. Argon2id-KDF derives unlock key.
4. Decrypt `user_sk.enc` → `user_sk` in memory.
5. Session process is minted `Cap<KIND_USER>` after the supervisor verifies a signed challenge signed by `user_sk`.
6. Passphrase and unlock key are zeroed from memory.
7. `user_sk` remains resident for the session (auto-lock after idle configurable).

**Programmatic (script, service, cron-analog):**
- The parent process delegates a sub-cap of its `KIND_USER` to the child. No re-authentication. Holds prove authorization; the initial passphrase-unlock happens once per interactive login.

**Remote (via `remote` tool over TCP + TLS 1.3 + ML-KEM):**
- Mutual signature: client signs a server-generated challenge with `user_sk`; server verifies against the account's `user_pk`.
- No passwords transit the wire, ever.
- Session runs under a delegated `Cap<KIND_USER>` scoped to the ML-KEM-negotiated session; disconnect revokes.

**Hardware token (optional):**
- FIDO2 / U2F equivalent — a hardware device holds a private key that signs the login challenge instead of the software `user_sk`.
- Fingerprint reader (R32 substrate) acts as a local biometric factor that unlocks the software `user_sk` in the TPM-analog secure enclave.

### 2.3 Multi-factor policy

Two orthogonal factors, both configurable per user:

- **Something you know** — passphrase.
- **Something you have** — hardware token OR biometric.

Enforcement: `founder` can require MFA for all accounts, or leave it per-user. Default: passphrase-only for `founder`'s initial creation; passphrase + biometric encouraged for subsequent users where hardware supports it.

---

## 3. The first user — `founder`

`founder` is a **role**, not a fixed name. The account created at first-boot after the installer completes hardware detection and initial partition provisioning. Its role — holding the seed mint of every root capability — is the load-bearing part.

### 3.1 First-boot flow

```
[installer completes; UEFI hands off; kernel_main_uefi has established supervisor]

┌────────────────────────────────────────────────────────────┐
│ Welcome to PaideiaOS.                                       │
│ Setting up the first user of this machine.                  │
│                                                             │
│ Display name:  santiago                                     │
│ Login name:    santiago                                     │
│ Passphrase:    ****************                             │
│ Confirm:       ****************                             │
│                                                             │
│ Optional: enroll fingerprint now? [y/N]                     │
└────────────────────────────────────────────────────────────┘

[installer:]
  Generating ML-DSA-65 keypair for founder... done.
  Deriving Argon2id unlock key... done.
  Sealing user_sk under unlock key... done.
  Creating home subtree at /home/santiago... done.
  Signing initial capability tree with paideia_root_pk... done.
  Writing signed user record to /system/users/<fp>.pdxuser... done.

Founder account created. Reboot to log in.
```

### 3.2 What `founder` holds

At creation, `founder` receives an **initial mint** of every base capability:

| Cap | Scope |
|-----|-------|
| `KIND_SUPERVISOR` | full-system administrative authority (mint/delegate/revoke authority for everything below) |
| `KIND_PDXFS(root)` | the entire disk partition tree |
| `KIND_HW` | mint authority for all downstream hardware kinds (KIND_INTERRUPT, KIND_MSIX_VECTOR, KIND_DMA_DOMAIN, KIND_HW_TIMELINE) |
| `KIND_NETWORK(*)` | every configured interface, unrestricted |
| `KIND_DEVICE(*)` | every PCI / xHCI device |
| `KIND_DRIVER(*)` | mint authority for every driver process |
| `KIND_SYSTEM_LOG` | full read/write on the audit journal |
| `KIND_USER(founder)` | founder's own user root cap |

Notably absent: `founder` does NOT hold caps into other users' home subtrees. Founder can *revoke* those users (which cascades their caps) but not silently read their files. If founder wants access, they mint a delegation from that user's `KIND_USER` — which requires the target user to sign the delegation, or is recorded audibly in the audit log as a supervisor override.

### 3.3 Founder is not magic

`founder` is a userspace process holding caps. The kernel does not special-case `founder`'s syscalls. Every cap check runs the same code path a low-privilege user's request runs. `founder`'s power is entirely a function of *what it holds*, not *what it is*. This is a strict adherence to Pillar 3 (userspace-first): there is no in-kernel superuser.

Consequences:
- If founder's session drops `KIND_HW`, it can no longer mint IRQ endpoints — same as any other process would experience.
- If founder's `user_sk` is lost, the caps are stranded; no back-door recovery from the kernel.
- Audit records supervisor-authorized operations by cap-fingerprint, not by "root did this".

### 3.4 Founder rotation

If `santiago` wants to hand off the machine to `alice` permanently:
```
santiago$ founder transfer alice
```
This creates the delegation record (§9) transferring every founder-scoped root cap to alice. Alice becomes founder; santiago becomes an ordinary user (or is removed entirely, at santiago's option). Signed by santiago; countersigned by paideia_root (which is where the ML-DSA-65 root key held during setup lives).

Only one founder exists at a time.

---

## 4. Creating additional users

### 4.1 Command

```
santiago$ user add alice
Display name: Alice Chen
Passphrase for alice: **************
Confirm:              **************
Optional: enroll fingerprint now? [y/N] y

Generating ML-DSA-65 keypair for alice... done.
Delegating capabilities from founder:
  KIND_PDXFS (subtree: /home/alice)                       [signed]
  KIND_NETWORK (interfaces: em0; layers: tcp, udp)         [signed]
  KIND_TTY (any allocated)                                 [signed]
  KIND_USER(alice) rooted under KIND_USER(santiago)        [signed]
  quota_bytes: 100 GiB
  MFA required: passphrase + fingerprint

Delegation record signed. Countersigned by supervisor. Journaled to
/system/audit/user-events/<ts>-alice-created.pdxevent.

Alice may now log in.
```

### 4.2 What happens under the hood

1. `user add` runs as a userspace tool (§ `user` in the tooling plan) holding `Cap<KIND_SUPERVISOR>` — usually invoked by `founder`.
2. The tool prompts for the new user's information + MFA choices.
3. Generates a fresh ML-DSA-65 keypair for the new user.
4. Derives an unlock key from the new user's passphrase; seals `user_sk`.
5. Provisions the home subtree on PdxFS v1 (creates the CoW root).
6. Mints sub-caps from founder's roots:
   - `KIND_PDXFS(subtree=/home/alice)` — sub-cap of founder's `KIND_PDXFS(root)`.
   - `KIND_NETWORK(interfaces=em0; layers=tcp,udp)` — sub-cap of founder's `KIND_NETWORK(*)`.
   - `KIND_TTY(any)` — sub-cap of a global TTY pool.
   - `KIND_USER(alice, delegated_by=santiago)`.
7. Writes the delegation record to `/system/audit/user-events/`. Records include the caps minted, their scopes, and the founder signature.
8. Writes the signed user record to `/system/users/<fp>.pdxuser` (see §9).

### 4.3 Delegating without being founder

Any user holding `Cap<KIND_USER>` may create a sub-user under themselves, IF they hold enough scope to mint. Alice can create `alice-work` as a sub-user with a subset of her own caps; the sub-user is a child of alice in the cap tree, and cascade-revokes when alice is revoked.

Practical use: multi-tenant setups without giving every tenant founder access.

---

## 5. Elevation — no setuid, no `sudo`

Traditional Unix `sudo` is a setuid binary that runs as root and re-authenticates. This model has three problems:
- It grants a whole *identity* (root), not a specific operation.
- The setuid mechanism relies on kernel special-casing that's a persistent attack surface.
- Time-bounding is manual and often forgotten.

PaideiaOS replaces `sudo` with **per-operation, time-bounded, cap-delegation via `elevate`.**

### 5.1 Command

```
alice$ elevate 'pkg install ls' --for 60s
Requesting caps from founder for the target operation:
  KIND_PDXFS(write, /pkgs)
  KIND_NETWORK(fetch, pkgs.paideia-os)
  KIND_SIGNATURE(verify, paideia_root_pk)
Duration: 60 seconds
Founder's approval channel notified. Awaiting response...
```

Meanwhile, in founder's active session (or via the `elevate` daemon in their absence):

```
[santiago's terminal]
Elevation request from alice:
  Operation: pkg install ls
  Caps requested: KIND_PDXFS(write, /pkgs), KIND_NETWORK(fetch, pkgs.paideia-os),
                  KIND_SIGNATURE(verify, paideia_root_pk)
  Duration: 60s
Approve? [Y/n] Y
Signed. Delegation valid for 60 seconds from now.
```

Back in alice's session:
```
Elevation granted. Executing: pkg install ls
[install proceeds]
[after 55 seconds] pkg install ls succeeded.
[after 60 seconds] Delegation expired. Caps returned.
```

### 5.2 Automated approval

For unattended flows (services, cron-analog), approvers can register `elevate-policy` rules:

```
santiago$ elevate-policy add \
  --for alice \
  --op-matches 'pkg install *' \
  --caps 'KIND_PDXFS(write, /pkgs), KIND_NETWORK(fetch, pkgs.paideia-os)' \
  --max-duration 300s \
  --rate-limit '5/hour'
```

Signed policy record. Automates approval for the matching operation subset, still time-bounded and rate-limited.

### 5.3 Non-existence of "shell as root"

There is no `sudo -s` analog. You cannot get a shell holding founder's full cap bundle without founder explicitly delegating that (which they never should — the model discourages the pattern). Every elevation is per-operation. This eliminates the class of accidents where a user runs a destructive command in the wrong terminal because they forgot they had a root shell open.

---

## 6. Remote users + logins from other machines

### 6.1 Machine identity vs user identity

Separately from user identity, every PaideiaOS machine has its own ML-DSA-65 keypair (`machine_pk`, `machine_sk`) minted at first-boot and held by the supervisor in a TPM-analog secure enclave. Machine identity is used for:
- TLS server-side authentication (`fetch` verifies the server against a pinned `machine_pk`).
- Attestation (a remote party can verify what code the machine is running).
- Signing machine-scoped records like audit logs.

Machine identity is orthogonal to user identity. A single user (identified by their `user_pk`) can hold accounts on multiple machines; the delegation for their `KIND_USER` on each machine is signed independently by each machine's founder.

### 6.2 Remote login (via the `remote` tool)

Prereq: TCP + TLS 1.3 + ML-KEM key exchange, which is the "post-R27 network gap" flagged in `design/tooling/priority-and-release.md`.

Flow:
```
alice@laptop$ remote santiago@workstation.local

[remote:]
  Resolving workstation.local... 192.168.1.20
  TLS 1.3 handshake with ML-KEM-768 key exchange...
    server machine_pk fingerprint: sha3_256(f2b8..a1c3)
    known-hosts match: YES (last seen 2026-08-08)
  Presenting user identity to workstation...
    signing challenge with alice's user_sk (unlock passphrase if needed)
    passphrase: **************
  Workstation replies:
    verified alice@laptop against local record for alice
    minting session Cap<KIND_USER(alice)> valid for 4 hours
  Session established.

alice@workstation:~$ 
```

At session end (explicit `exit`, TCP close, or idle timeout), the session cap is revoked and every downstream cap alice minted during the session dies. No lingering processes owned by "alice" — the cap-cascade cleans up.

### 6.3 First-time SSH-analog trust

The `remote` tool prompts on first connect (like SSH's TOFU):

```
alice@laptop$ remote santiago@workstation.local
Server machine_pk fingerprint: sha3_256(f2b8..a1c3)
This is a first-time connection. Trust this machine? [y/N/details]
```

On `details`, `remote` shows the full attestation chain and lets the user pin. Pinned fingerprints live in `<home>/.remote/known-machines.pdxdata`.

---

## 7. Removal / deletion

### 7.1 Basic case

```
santiago$ user remove alice
```

Effect:
1. Alice's `Cap<KIND_USER(alice)>` is revoked. Cascade: every cap minted from it is instantly dead. Running processes owned by alice terminate cleanly (SIGTERM equivalent via cap revocation, followed by cap-force-drop after grace period).
2. Alice's session (if active anywhere) terminates.
3. Alice's home subtree is preserved by default. `--wipe` argument shreds it (journaled through pdx-journal so `undo` can recover for 24 hours, then permanently gone).
4. Alice's user record at `/system/users/<fp>.pdxuser` is marked `revoked` (not deleted — the fingerprint remains blacklisted; future `user_pk == alice_pk` submissions are rejected).
5. Audit event written.

### 7.2 Sub-user cascade

If alice has sub-users (say, `alice-work`), revoking alice cascades to them. This is per the linear-cap semantics: children can't outlive their parent.

### 7.3 Founder cannot self-remove

Founder must transfer the role (§3.4) first. `user remove founder` fails with:
```
error: cannot remove the founder. Transfer the role first with:
       founder transfer <new-founder>
```

---

## 8. Recovery + key loss

**The uncomfortable truth:** there is no back door. If a user loses their `user_sk` and has no MFA fallback, that user is inaccessible. This is a deliberate consequence of the cap model — any recovery mechanism is a capability laundering hole.

### 8.1 What we DO offer

**For an ordinary user (not founder):**
- Founder holds the KIND_USER root cap. They can revoke the lost user + create a new one, transferring the old user's home subtree (if desired) via a founder-signed delegation.
- Founder's involvement is audit-logged.

**For founder:**
- Founder loss = machine is bricked to its data. Recovery is: reinstall, restore from signed backups.
- Rationale: a founder-recovery mechanism would be a persistent kernel backdoor, incompatible with the cap model.
- MFA is strongly recommended for founder specifically to make key loss less likely.

### 8.2 Backups

Every user should back up their home subtree, signed by their `user_sk`, to external durable storage. On disaster recovery, the backup can be restored:
- If the same machine + same founder: founder mints a fresh `KIND_USER` for the user and restores the subtree under it.
- If a new machine: install PaideiaOS with a new founder, then restore the backup as a new user's home. The signatures on the backup files may need re-signing under the new user identity (this is the standard PdxFS v1 signed-inode migration path — separate design).

---

## 9. Signed on-disk representation

### 9.1 `/system/users/<fp>.pdxuser` — the user record

Format (Paideia data-record encoding):
```
version: u16          // = 1
kind: u8              // 0 = active, 1 = revoked
pk_fingerprint: [u8;32]  // sha3_256(user_pk)
user_pk: [u8;1952]       // ML-DSA-65 public key bytes
display_name: [u8;64]    // UTF-8, null-padded
login_name: [u8;32]      // UTF-8, null-padded, lowercase
created_ns: u64
delegated_by: Option<[u8;32]>   // parent user fingerprint (None for founder)
mfa_required: u8          // bitmask: 0x01 passphrase, 0x02 hardware, 0x04 biometric
quota_bytes: u64
supervisor_sig: [u8;3293]  // ML-DSA-65 signature by supervisor over the record
```

Read by the supervisor at boot to populate the runtime user map. Read by `user list` to display the roster.

### 9.2 `<home>/.identity/user_sk.enc` — encrypted secret key

Format:
```
version: u16          // = 1
kdf_id: u8            // = 1 (argon2id)
kdf_params: [u8;16]   // memory, iterations, parallelism, reserved
kdf_salt: [u8;32]
aead_id: u8           // = 1 (chacha20poly1305)
aead_nonce: [u8;12]
sealed_sk: [u8;4032 + 16]  // ML-DSA-65 sk + Poly1305 tag
```

Owner-only cap on this file. Loss of `.identity/` = user_sk is unrecoverable.

### 9.3 `/system/audit/user-events/*.pdxevent` — audit trail

Every user create / remove / delegation / elevation is journaled here. Each event signed by the actor. Log is append-only; entries never mutate.

### 9.4 `/system/keys/paideia_root.pk` — the root key

Read-only public copy of the root key that signs the machine's initial founder record. Held in the secure enclave; a signed copy on disk for cross-verification.

---

## 10. Relationship to other subsystems

### 10.1 Drivers (R29+)

Driver processes are minted their caps by founder (or by the supervisor delegating on founder's behalf). Drivers do NOT hold `KIND_USER` — they hold hardware caps (`KIND_INTERRUPT`, `KIND_DMA_DOMAIN`, etc.) directly. A user requests driver services via the driver's IPC channel; the request may carry a delegated sub-cap over the specific device (e.g., "read this specific PdxFS partition" derives to "read this specific NVMe range").

### 10.2 PdxFS v1 (R42)

Home subtree roots are minted as PdxFS v1 subtree caps. The KIND_PDXFS cap's tail records the subtree root inode + mode bits (r/w/x from the perspective of the cap-holder, not the file). PdxFS v1's per-file signature verification checks the file's `signed_by` field against the user_pk of the caller — corruption or tampering surfaces as a `KIND_SIGNATURE` fault.

### 10.3 The audit journal (R29 + R42)

Every mint / delegate / revoke of `KIND_USER` and every `elevate` grant lands in `/system/audit/`. The journal is the ground truth for who did what. It's readable by anyone holding `KIND_SYSTEM_LOG`, which by default is founder + audit-role delegates.

### 10.4 The semantic terminal (R41 / R44)

Login lands the user in the semantic terminal (fb-console frontend at R41; GPU-native at R44). The terminal itself is a userspace process minted a session cap; every command it spawns is a sub-cap of the terminal's cap, itself a sub-cap of the user's `KIND_USER`.

### 10.5 Tooling ecosystem (§`user`, `pass`, `vault`, `elevate`, `caps` in `design/tooling/`)

- `user` — the CRUD tool for accounts.
- `pass` — passphrase change + MFA management.
- `vault` — encrypted-at-rest secrets manager, per-user, backed by `user_sk`.
- `elevate` — per-operation cap delegation.
- `caps` — inspection: `caps show alice` prints alice's cap tree, `caps audit /home/alice` shows who's currently minted caps into her subtree.

All P1 tools per `design/tooling/priority-and-release.md`. Earliest implementation at T5–T6 (R53–R55).

---

## 11. Readiness — what's landed, what's missing, staged rollout

### 11.1 What's landed (as of 2026-08-11, MVP `mvp-v0.1` at 836ec0d)

| Building block | Where | Status |
|-----------------|-------|--------|
| ML-DSA-65 signing infra | R25.M5 (PdxFS-lite ML-DSA fixtures) | scaffolded; used for PdxFS + firmware blob signing paths |
| Capability model (16 base kinds + linear semantics) | R2/R3 + refinements through R29 | operational |
| Process abstraction | R15.M5 | operational |
| Supervisor userspace process pattern | R20.M4 (ACPI supervisor) | proven; template for the future user supervisor |
| PdxFS-lite (v0) | R25 | working; signed inodes scaffolded but not enforced end-to-end |
| fb-console + tty (color TUI) | R23 | working (color TUI viable) |
| VFS + basic filesystem | R16 | working |
| Shell with line reader + fork/exec | R17 | working |
| ACPI supervisor as an isolated userspace-privileged process | R20.M4 | working — the model for the user supervisor |

### 11.2 What's missing (blocks the model)

Hard blockers — the user model as designed cannot ship without these:

| Missing piece | Where it should land | Owner (rough) | Notes |
|---------------|----------------------|---------------|-------|
| **PdxFS v1** (CoW + journal + snapshots + real signed inodes) | **R42** (in next-wave milestone catalogue) | filesystem team | Home subtrees + trash + user records need durable + signed storage. Absolute prerequisite for any user model beyond throwaway toys. |
| **`KIND_USER` derived-kind slot** | New R29 sub-milestone or R42.M-user | capability team | Derives over KIND_HW (slot 14) or a new "identity" family. Adds `pk_fingerprint`, quota, delegated_by tail. |
| **Argon2id-KDF stdlib** | New paideia-as bundle (`v0.33-crypto-kdf` or similar) — not currently on catalogue | paideia-as team | Needed for passphrase-derived unlock keys. Blocks §2.1. |
| **ChaCha20-Poly1305 AEAD** | Same paideia-as bundle | paideia-as team | Needed to seal `user_sk`. Blocks §2.1. |
| **Passphrase readline widget on fb-console** | New paideia-os round (post-R23; likely R41 sem-terminal-fb or a small user-substrate round R43-ish) | terminal team | Currently we only have R17 shell's line reader; a masking readline for passphrases needs a separate widget. |
| **Signed user record parser + writer** | R42-adjacent | filesystem team | Reads `/system/users/*.pdxuser`, verifies supervisor signature, populates runtime map. |
| **Supervisor process for user management** | New round `r43-user-supervisor` (proposed) | supervisor team | Runs like `acpi_supervisor` at R20.M4; owns the user table + cap-mint authority + audit journaling. |
| **`user` / `pass` / `vault` / `elevate` tools** | Tooling waves R53-R56 per priority-and-release | tooling team | Requires all of the above. Cannot ship until supervisor exists. |
| **TCP + TLS 1.3 + ML-KEM** | Post-R27 network gap (est. R43-R46) | networking team | Blocks §6 remote login. Note: multiple tools already flagged blocked on this. |
| **Machine identity + secure enclave** | R32 (partial) + a new round for the TPM-analog enclave | crypto team | R32 landed root key; secure enclave for `machine_sk` at rest is unscoped. |
| **Hardware token / fingerprint wiring** | R32 (fingerprint hardware) + a new binding to auth path | crypto team | R32 substrate lands the reader driver; wiring to §2.2 hardware-token path is separate. |

### 11.3 Suggested staged rollout

Given the missing pieces, here's a credible staging:

**Stage 0 — Now through R41 (no user model beyond `whoami`-analog).** Single-tenant, no login, no cap-per-user. Everything runs under an implicit "root" that holds all caps. Sufficient for kernel + driver development.

**Stage 1 — R42 (Single-user + persistence).** PdxFS v1 lands. Ship a minimal single-user model:
- `founder` account is created at first boot (interactive prompt lives in R23 fb-console).
- Passphrase-derived unlock (Argon2id + ChaCha20-Poly1305 — file a new paideia-as bundle to land these).
- `KIND_USER` cap minted at boot after unlock.
- Home subtree provisioned on PdxFS v1.
- No additional-user support yet. No `elevate`. No remote login.
- **Effort:** ~4–6 weeks parallel with R42 substrate work. New round `r43-founder-substrate` (~15 issues).

**Stage 2 — R44 (User supervisor + delegation).** After sem-terminal-gui lands:
- New round `r45-user-supervisor` (~20 issues) — isolated supervisor process owning the user table, mint authority for `KIND_USER`, audit journaling.
- `user add` / `user remove` for creating additional users under founder.
- Home-subtree quota enforcement.
- `elevate` prototype (interactive approval only; no policy rules yet).
- **Effort:** ~6–8 weeks. Needs `r43-founder-substrate` closed.

**Stage 3 — Post-TCP-TLS (est. R47 or later).** After the network gap fills:
- Remote login (§6) becomes possible.
- `remote` tool ships.
- Machine identity fully wired (attestation + known-hosts).
- **Effort:** ~4 weeks post-TCP-TLS.

**Stage 4 — Tooling waves (R53+).** `user`, `pass`, `vault`, `elevate` tools ship as first-class per the tooling plan.

### 11.4 The overall readiness number

**Founder-only single-user (Stage 1) is ~2 substrate rounds away** (R42 for PdxFS v1 + a new `r43-founder-substrate` round), plus a new paideia-as bundle for Argon2id + ChaCha20-Poly1305. Wall-clock: ~3-4 months into the next-wave schedule.

**Multi-user + delegation (Stage 2) is ~4 substrate rounds away.** Wall-clock: 6-9 months in.

**Full model with remote + tools (Stage 4) is ~10-14 months into the next-wave.**

Nothing on the R29-R47 next-wave catalogue currently touches user management. Filing the missing rounds (`r43-founder-substrate`, `r45-user-supervisor`, plus a paideia-as `v0.33-crypto-kdf` bundle) is the first concrete action if we want this on the roadmap. That filing can happen after the current in-flight God-file refactor lands.

---

## 12. Open questions

Deferred until we're closer to Stage 1:

- **Guest accounts:** should there be a special short-lived account with no home subtree, useful for one-off machine access? Or is that handled by an ephemeral sub-user under founder?
- **Group / role abstractions:** if alice and bob need to share a project folder, do we introduce a `KIND_GROUP` cap, or just mint a delegated sub-cap into each?
- **Cross-machine identity federation:** is `user_pk` machine-local, or can a user establish "same identity" across their laptop + workstation + server? (Argues for user_pk being portable, but that has cap-forgery implications if any machine is compromised.)
- **Founder role plurality:** should we allow more than one founder for organizational deployments? Current answer is "no — one founder at a time; multi-tenancy is handled by delegation." Revisit if the model chafes.
- **Passphrase policy:** are we going to enforce complexity / length / disallow-common-passwords? Current answer: enforce a minimum of 12 characters, warn on breach-list hits (a la Have-I-Been-Pwned integration), don't dictate structure.
- **MFA fallback:** if the hardware token dies and passphrase-only is disabled, is there a "recovery code" mechanism? Currently answered "no — that's a laundering hole." Revisit if usability testing shows this is a dealbreaker.
- **Time-limited accounts:** should we support "this account expires 2026-12-31"? Easy to add via a `expires_ns` field in the user record; deferring unless requested.

These are *not* blockers on beginning the design. They're refinements for the second design pass, driven by first-user feedback.

---

**Ready for filing** as part of the next-wave milestone extension (new rounds `r43-founder-substrate`, `r45-user-supervisor`, plus paideia-as `v0.33-crypto-kdf`). Would recommend filing after the current in-flight God-file refactor lands, to avoid GitHub-API race with concurrent bulk-file work if any.
