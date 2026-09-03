# Persistent /home + content-addressed identity — R106+ wave plan

**Status:** Frozen decision (2026-09-03). Four-round wave delivering
multi-user persistent `/home` with content-addressed identity.

**Supersedes / extends:**
- `design/user/persistent-home.md` (R65v2) — R106 is the successor
  round; R65v2 delivered probe + mount attempt + shell chdir wired
  against tmpfs. R106 closes the loop on the storage side.
- `design/user/etc-layout.md` §passwd — retired in favor of the
  content-addressed identity model described in
  `design/user/content-addressed-identity.md`.

**Anchor design docs:**
- `design/user/content-addressed-identity.md` — identity primitive,
  record schema, alias registry, capability model, threat model.
- `design/user/persistent-home.md` — R65v2 pipeline this wave builds on.

**Cross-repo dependencies:**

| Dep                                                       | Blocks                     | Repo                             |
|-----------------------------------------------------------|----------------------------|----------------------------------|
| paideia-as v0.33 (Argon2id + ChaCha20-Poly1305 + ML-KEM-768) | R108.M1 signed-record I/O | `paideia-os/paideia-as`         |
| paideia-as v0.24.0 ML-DSA-65 (already landed)             | R108 signature primitives | `paideia-os/paideia-as`          |
| New satellite: `paideia-os/shell`                          | R106.M4 tokenizer         | `paideia-os/shell` (created this wave) |

**Wave discipline (Q10=A):** hard-close each round; per-round issues are
created just-in-time at the round's kickoff (not batch-created for the
whole wave up front). R106 issues land now; R107/R108/R109 milestones
open at round-turnover only.

---

## Round dependency graph

```
                                              paideia-as v0.24.0
                                              (ML-DSA-65, done)
                                                     │
                                                     ▼
    R106                R107               [R108 needs both]
  persistent      mount shape +        ┌──▶  identity substrate
    /home    ───▶  devfs +      ───────┤    (signed records, alias
  substrate      file-bdev             │    registry, founder flow)
  (single-user                         │              │
   path)                               ▲              ▼
                                       │            R109
                                       │      multi-user session
                                paideia-as v0.33   + login
                              (Argon2id, ChaCha,
                                 ML-KEM-768)
                              ── parallel work; lands
                                 before R108 kickoff ──

  Also parallel: paideia-os/shell satellite repo scaffold
  (this wave) — R106.M4 lands the tokenizer + dispatcher there,
  not in the monorepo.
```

Legend:
- `───▶` sequential dependency (blocks kickoff of the next round).
- `▲` cross-repo dependency (must land before the target round starts).

---

## R106 — persistent /home substrate, single-user path

~15 issues, 6 milestones. Extends R65v2's pipeline (probe + mount
attempt + shell chdir + envp) with **real persistence** on the storage
side, still on the single-user path. Introduces a **placeholder
fingerprint** for `/home/<fp>/` so the tree can adopt the R108
addressing shape now, without waiting for real crypto.

The R65v2 hardcode `/home/operator` is retired in this round in favor
of `/home/<founder_fp_placeholder>/` — where `<founder_fp_placeholder>`
is a build-time constant 64-hex string that R108.M2 will overwrite with
a real Argon2id-derived fingerprint. Doing the path rename now means
R108 does not have to touch every consumer.

### Milestones

- **M1 — rootfs seed extends to /home + /home/<founder_fp_placeholder>/.**
  Extend `src/user/rootfs_seed.pdx` to `mkdir /home/` and
  `mkdir /home/<placeholder_fp>/` at boot. Boot smoke asserts both
  directories exist and are empty.

- **M2 — init envp: HOME=/home/<fp>; shell reads it + chdirs.**
  R65v2 landed `_init_envp` with a hardcoded `HOME=/home/operator`.
  Retarget to `HOME=/home/<placeholder_fp>`. Shell's chdir-on-entry
  reads envp `HOME` and chdirs there (already correct in R65v2 shape;
  regression-test the retargeting).

- **M3 — retire the /home/operator hardcode across init.pdx +
  dispatch.pdx.** Grep-and-replace every literal `/home/operator` in
  the tree with either the placeholder constant or a symbolic reference
  through envp. Includes a compile-time assertion in `init.pdx` that
  `HOME` matches the placeholder constant so the two stay in sync.

- **M4 — bare-cd errors; tokenizer accepts leading `~` in ANY argv
  position (self-only for now).** Lands in the new `paideia-os/shell`
  satellite repo (not this monorepo — Q8 extraction). Bare `cd` prints
  the ambiguous-target error with candidate suggestions (Plan 9 `rc`
  lineage). Tokenizer expands `~` → `$HOME` and `~<64-hex>` → literal
  `/home/<64-hex>` at any argv position. `~alice` returns
  `E_ALIAS_UNRESOLVED` until R108.M4 lands the alias registry — the
  error path is exercised now so R108 only has to swap the resolver.

- **M5 — boot smoke: `boot_r106_persistent_home` two-phase.**
  Phase A: boot, `echo hi > /home/<placeholder_fp>/probe.txt`, capture
  UART. Phase B: reboot (same volume), `cat
  /home/<placeholder_fp>/probe.txt`, assert `hi`. Requires the R65v2
  mount plumbing to actually persist; if `backend_id=5` is still stubbed
  when M5 lands, this smoke fails and forces the R107 file-bdev work to
  be pulled forward as a hard prerequisite (see R107.M1).

- **M6 — R106 closure.** Round-retrospective doc, `r106-closed` git
  tag, submodule bump if any paideia-as work was pulled in.

### Cross-repo obligations R106 discharges

- Shell repo scaffold exists and hosts the R106.M4 landing (that
  scaffold is created up-front in this wave, before R106 kickoff — see
  §"Cross-repo scaffolding" below).

---

## R107 — mount shape + devfs + file-bdev

~15 issues, 6 milestones. Closes the R65v2 gap: `sys_mount`'s
`backend_id=5` (`PDXFS_BLOCK`) is a stub today. R107 delivers a real
block-device backend and the two dev-path resolvers (file-bdev + devfs)
that R65v2's design has been waiting on.

### Milestones

- **M1 — file_bdev.pdx: KIND_BLOCK_DEVICE over file fd.**
  New `src/kernel/core/block/file_bdev.pdx`. Exposes a
  `KIND_BLOCK_DEVICE` cap whose backing is a file fd (typically opened
  on `/var/pdxfs/home.img`). Read/write/sync are file-fd operations.
  Boot smoke: mint a file-bdev cap over a synthetic image, issue a
  512-byte read/write, verify content survives an `fsync`.

- **M2 — devfs backend + /dev/nvme0 node registration from
  KIND_BLOCK_DEVICE registry.** Devfs is a synthetic FS whose entries
  reflect a live registry of `KIND_BLOCK_DEVICE` caps. Boot registers
  `/dev/nvme0` if the NVMe driver has produced a cap. Boot smoke:
  `sys_open("/dev/nvme0", O_RDONLY)`, `sys_read(4096)`, verify a
  non-zero-page returns.

- **M3 — sys_mount backend_id=5 real arm.** Replaces the R65v2
  `UNIMPL` stub. Accepts a mount-source path, resolves it via devfs to a
  `KIND_BLOCK_DEVICE` cap (real devfs node OR file-bdev over
  `/var/pdxfs/home.img`), and binds a PDXB filesystem on top. Boot
  smoke: mount a formatted file-image at `/home/<placeholder_fp>/`,
  write, unmount, remount, read back.

- **M4 — init probes /home/<fp>/ as a separate mount.** Init's probe
  order (from R65v2 §2): try `/dev/nvme0` first, then
  `/var/pdxfs/home.img`, then fall back to root-volume subdir. R107.M4
  makes each of those a live backend, not a fallthrough.

- **M5 — `boot_r107_home_mount_variants` smoke.** Two boot runs in the
  smoke harness: one with `/var/pdxfs/home.img` present (file-bdev
  path), one with a QEMU-attached NVMe blob (devfs path). Both must
  reach the R106.M5 write/read/reboot loop green.

- **M6 — R107 closure.** Round-retrospective, `r107-closed` tag.

---

## R108 — identity substrate

~30 issues, 8 milestones. DEPENDS ON paideia-as v0.33-crypto-kdf.
Implements `design/user/content-addressed-identity.md` end-to-end: the
signed user record, alias registry, first-boot founder provisioning,
and the tokenizer's real alias resolution.

### Milestones

- **M1 — pdxfs signed-record read/write primitives.**
  New `src/kernel/core/pdxfs/signed_record.pdx`: write path
  `pdxfs_write_signed(path, record, secretkey)` (composes record, calls
  `mldsa65_sign`, atomic-writes to `<path>.tmp`, WAL-commits rename).
  Read path `pdxfs_read_signed(path, pubkey) -> record | E_SIG_INVALID`.
  Requires paideia-as v0.24.0 ML-DSA-65 (already landed).

- **M2 — `/system/users/<fp>.pdxuser` schema freeze + first-boot founder
  provisioning UX.** Freeze `PdxUserRecord@0.1` (schema from
  content-addressed-identity.md §2). Flip `founder_keygen.pdx`,
  `first_boot.pdx`, `founder_cap_seed.pdx`, `user_registry.pdx` from
  arbitrated-0 to arbitrated-1 (real crypto). Interactive prompt reads
  passphrase, runs `argon2id_derive` (paideia-as v0.33) + `mldsa65_keygen`,
  computes `fp`, composes+signs record, writes to
  `/system/users/<fp>.pdxuser`, opens `/home/<fp>/` (renaming the
  R106 placeholder in place — the placeholder-constant registry is
  updated in the same commit).

- **M3 — KIND_USER_ALIAS cap + `/system/aliases/<alias>.pdxalias`
  schema.** Freeze `PdxAliasRecord@0.1`. New `alias_registry.pdx` +
  `/bin/alias` tool. Founder's alias is written in the same first-boot
  transaction as their user record (§6 of the identity doc). Test:
  round-trip an alias, revoke, reissue.

- **M4 — shell `~alice` real resolution via KIND_USER_ALIAS.**
  Lands in the `paideia-os/shell` satellite repo. Tokenizer's
  `~<alias>` path now calls `KIND_USER_ALIAS.lookup`. `E_ALIAS_UNRESOLVED`
  becomes reachable via a real registry (not just a static stub).

- **M5 — `elevate` broker acquires KIND_USER_ALIAS at boot; passes handle
  to shell via envp.** Elevate mints the read-only alias cap once at
  boot and passes the handle number as `PDX_ALIAS_CAP=<n>` in the
  shell's envp. Tokenizer picks it up.

- **M6 — retire arbitrated-0 gates in `src/kernel/core/user/*.pdx`.**
  Sweeping flip: every file in the alignment table from
  content-addressed-identity.md §9 that has not already been flipped in
  M1–M5 flips here. `founder_home.pdx` gets its `owner_fingerprint`
  from the real founder record.

- **M7 — `boot_r108_founder_first_boot` end-to-end smoke.**
  Fresh volume boot, scripted-UART first-boot prompt, verify
  `/system/users/<fp>.pdxuser` + `/system/aliases/<alias>.pdxalias` +
  `/home/<fp>/` all exist and verify. Then the composed
  `boot_r108_founder_survives_reboot` smoke: write a probe, reboot,
  read back.

- **M8 — R108 closure.** Round-retrospective, `r108-closed` tag,
  paideia-as v0.33 submodule bump confirmed.

### Cross-repo blocker

R108.M1 is blocked on paideia-as v0.33 landing (Argon2id and
ChaCha20-Poly1305 intrinsics). ML-KEM-768 is not on the R108 critical
path (used for R109 session-key encapsulation) but is bundled into v0.33
because they land as one crypto substrate release.

---

## R109 — multi-user session + login

~25 issues, 8 milestones. Adds the login screen, `su`, invite/redeem,
per-user home permissions, and session substrate.

### Milestones

- **M1 — session substrate.** Per-session capability set: a
  `KIND_SESSION` cap that scopes every child process's ambient caps to
  the caps the session was attached with. Session-key derivation via
  `argon2id_derive(passphrase, per-session-salt)` (paideia-as v0.33).

- **M2 — login screen (TUI).** Boot lands on a login TUI, not on an
  auto-attached founder shell. Enter alias + passphrase → resolve alias
  → open `/system/users/<fp>.pdxuser` → unseal secret key via
  `chacha20poly1305_open` (paideia-as v0.33) → verify a
  liveness-challenge signature → attach `delegated_caps` to a new
  `KIND_SESSION` → spawn shell.

- **M3 — `su <alias>` and `logout` builtins.** `su` re-prompts for the
  target user's passphrase (no ambient su-authority; even the founder
  supplies the passphrase). `logout` scrubs the session cap set.

- **M4 — invite flow: `invite <alias>` mints a KIND_INVITE cap.** New
  user redeems it at first login. The invite cap carries the grantor's
  countersignature so the invitee's `PdxUserRecord` can be composed
  with a valid `grantor_sig` on first boot.

- **M5 — per-user home directory permissions.** Only the owner's caps
  can write to `/home/<fp>/`. Sharing a file with another user is a
  delegation via `elevate`, not a `chmod`. Verified by a two-user smoke
  where `~alice` cannot write to `/home/<bob_fp>/foo`.

- **M6 — session persistence within a boot; not across reboots.**
  Attached caps survive `fork`/`exec` within one boot. A reboot wipes
  session caps — the user must log in again. (Persistent sessions are
  future work.)

- **M7 — `boot_r109_multi_user_session` smoke.** Two seeded users
  (`alice`, `bob`). Login as alice → write `/home/<alice_fp>/a`. Logout,
  login as bob → attempt to write `/home/<alice_fp>/b` (must fail with
  `E_CAP_DENIED`), write `/home/<bob_fp>/b` (must succeed). Logout,
  login as alice → read back `a`.

- **M8 — R109 closure.** Round-retrospective, `r109-closed` tag.
  Wave-close doc — retrospective across the whole R106–R109 arc.

---

## Cross-repo scaffolding (up-front, before R106 kickoff)

Two out-of-round obligations land at wave-plan time (i.e., alongside
this document), not inside any specific round:

1. **paideia-os/shell satellite repo created.** Empty scaffold: MIT
   LICENSE, README, STATUS placeholder, tools/build.sh shape, empty
   src/ tests/ design/ dirs, .gitignore. R106.M4 lands the tokenizer +
   dispatcher there.

2. **paideia-as v0.33 milestone opened + issues filed.** Argon2id,
   ChaCha20-Poly1305, ML-KEM-768 intrinsics + v0.33 integration issue.
   Runs in parallel with paideia-os R106/R107; must be closed before
   R108 kickoff.

Both are pre-R106 chores, filed at the same time as this wave plan.

---

## Round-close checklist (identical shape across R106–R109)

Each round's M-final produces:

- Round-retrospective doc under `design/round-retrospectives/`.
- Git tag `<round>-closed` on the closing commit.
- Submodule-bump commit if any paideia-as work was pulled in.
- Master `STATUS.md` update.
- Next round's milestone opened + first M issues filed.
