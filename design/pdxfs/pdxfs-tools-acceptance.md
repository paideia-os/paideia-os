# pdxfs Tools — Final Acceptance Report (PFS-W, Waves 85 → 100)

**Status:** Terminal report. Closes `paideia-os#2584` (PFS-17 rollup).
**Scope wave band:** paideia-os monorepo waves 85–100 (2026-10-11 → 2026-10-13).
**Submodule heads at report time:**

| Submodule                      | SHA        | CHANGELOG asserts | Latest tag                   |
|--------------------------------|------------|-------------------|------------------------------|
| `tools/user/libpdx-volume`     | `8c78f50`  | **v1.1.10**       | `v1.1.5` (tag drift: 5 bumps lag) |
| `tools/user/mount.pdxfs`       | `2c4c386`  | **v1.1.7**        | `r64v2-closed` (no `vX.Y.Z` tag ever) |
| `tools/user/umount.pdxfs`      | `090d837`  | **v1.2.0**        | `r64v2-closed` (no `vX.Y.Z` tag ever) |

The tag drift is a documented finding — see §3 for the recommended terminal
tag discipline.

---

## 1 Executive Summary

The PFS-W wave band froze the four kernel ABI contracts the pdxfs toolchain
had been building against — `sys_mount`/`sys_umount` (PFS-01), `_init_caps`
cap-seed convention (PFS-02), ML-DSA-65 verify intrinsic adoption (PFS-04),
and the one-DEK-per-volume block-crypto contract (PFS-05) — then landed the
real kernel bodies and user-space adapters that stop-gaps were masking: a
real `PMT_OP_APPEND_ROW` arm on `KIND_PDXFS_MOUNT_TABLE` (PFS-10),
`VOL_OP_QUERY_DEVICE_SLOT` resolver (PFS-11), `KIND_DEK` substrate
(PFS-12A), `sys_dek_seal` seal-hop closing the plaintext-DEK gap (PFS-13),
and `pdxb_block_encrypt`/`_decrypt` real bodies against `sys_dek_apply`
(PFS-14). Dependency-order (PFS-06), snapshot chain walk (PFS-07), inode
quota (PFS-08), and `sys_vol_mint` (PFS-09) ship with real bodies and
per-case test matrices. The `--force` umount path is end-to-end against a
new kernel-side `VOL_OP_REVOKE_HANDLE` op (PFS-15). A ten-fixture smoke
corpus (PFS-16) classifies the surface honestly: three fixtures are GREEN
today, seven are BLOCKED each with a named unblock wave.

**What the operator can do today:**

- Mount a public volume whose backing device cap is seeded at image load,
  against the frozen path-based `sys_mount` ABI.
- Umount a mounted volume (plain path).
- Walk a snapshot chain via `snap_chain_walk` (returns the stub-chain shape
  until `KIND_BLOCK_CACHE` lands; see PFS-07 §Deferred).
- Enforce inode-path quota at commit time.
- Issue `sys_vol_mint` (sysno 135) from kernel-side callers.
- Issue `sys_dek_seal` (sysno 136) from mount.pdxfs's passphrase-fd arm.
- Issue `sys_dek_apply` (sysno 137) from libpdx-volume's crypto marshaller.
- Attempt `umount --force` and hit the reachable fail-closed arm
  `UMOUNT_ERR_NO_ELEVATE` (exit 10) until PFS-18 provisions the
  elevate-channel cap.

**What the operator cannot do today:**

- Mount a volume at `/system/...` end-to-end (needs PFS-02 kernel-side cap
  seed provisioned at image load; the user-space resolver is complete).
- Succeed `umount --force` with `revoked_handles > 0` (needs PFS-18
  elevate-channel broker-endpoint cap).
- Mount with `--passphrase-fd` end-to-end (needs PFS-12 Part B wire-through
  at mount.pdxfs's call site).
- Mint a KIND_VOLUME from a ring-3 CLI (needs PFS-19 `/bin/vol.pdxfs`).
- `mount --all` across a dep graph (needs PFS-20 `/etc/pdxfs/mounts.toml`
  ingest at init start).

---

## 2 Landed Waves — PFS-01 … PFS-16

Status taxonomy: **GREEN** = landing clean, all claims verified. **SPLIT**
= landing left a documented continuation ticket. **DOC** = design-only
landing (no code).

| PFS   | Wave | Date       | Feature                                           | Status | Issue(s)                      |
|-------|------|------------|---------------------------------------------------|--------|-------------------------------|
| PFS-01 | 85  | 2026-10-11 | `sys_mount`/`sys_umount` ABI freeze               | DOC    | #2568 closes                  |
| PFS-02 | 86  | 2026-10-11 | `_init_caps` seed convention (slots 4, 5)         | DOC    | #2569 closes                  |
| PFS-03 | —   | —          | (not landed in band — number reserved, no issue)  | —      | n/a                           |
| PFS-04 | 88  | 2026-10-11 | ML-DSA-65 verify intrinsic adoption contract      | DOC    | followup paideia-as#1604      |
| PFS-05 | 89  | 2026-10-11 | Block-crypto contract (one-DEK-per-volume, 1:128) | DOC    | #2572 closes; followup #2730  |
| PFS-06 | 89  | 2026-10-11 | Kahn's algorithm — `mount_table_sort_by_deps`     | GREEN  | #2573 closes                  |
| PFS-07 | 91  | 2026-10-11 | Real `snap_chain_walk` body (3-arg) + adaptation  | GREEN  | #2574 closes                  |
| PFS-08 | 92  | 2026-10-11 | Inode-path quota check + commit                   | GREEN  | #2575 closes                  |
| PFS-09 | 93  | 2026-10-11 | `sys_vol_mint` (sysno 135) + `vol_kind_mint`      | GREEN  | #2576 closes                  |
| PFS-10 | 94  | 2026-10-11 | Real `PMT_OP_APPEND_ROW` + path-based ABI adoption| GREEN  | #2577 closes                  |
| PFS-11 | 95  | 2026-10-11 | Real `VOL_OP_QUERY_DEVICE_SLOT` wire-through      | GREEN  | #2578 closes                  |
| PFS-12A| 96  | 2026-10-11 | `KIND_DEK` substrate (cap 0x1A4, 3 ops)           | SPLIT  | refs #2579 Part A; B/C → followups |
| PFS-13 | 97  | 2026-10-11 | `sys_dek_seal` (sysno 136) seal-hop               | GREEN  | #2731 closes                  |
| PFS-14 | 98  | 2026-10-12 | `sys_dek_apply` (sysno 137) + real block-crypto   | SPLIT  | #2732 closes; cont #2734 open |
| PFS-15 | 99  | 2026-10-13 | `VOL_OP_REVOKE_HANDLE` + `umount --force` wiring  | GREEN  | #2582 closes                  |
| PFS-16 | 100 | 2026-10-13 | 10-fixture smoke corpus (3 GREEN, 7 BLOCKED)      | GREEN  | #2583 partial-close           |
| PFS-17 | 100 | 2026-10-13 | **This report**                                   | GREEN  | #2584 (this ticket)           |

PFS-W delivered 15 landings against 16 reserved slots (PFS-03 was retired
without landing — its originally-planned scope was absorbed into PFS-04 at
design time and the issue number was never allocated).

---

## 3 Final Version Bumps and Recommended Tag Discipline

### 3.1 Bumps asserted in CHANGELOGs

| Submodule       | Prior shipped | Final asserted | Semantic class  | Last landing wave         |
|-----------------|---------------|----------------|-----------------|---------------------------|
| libpdx-volume   | v1.1.5        | **v1.1.10**    | 5 × patch       | PFS-14 (Wave 98)          |
| mount.pdxfs     | v1.1.3        | **v1.1.7**     | 4 × patch       | PFS-13 (Wave 97)          |
| umount.pdxfs    | v1.0.1 → v1.1 attempted during PFS-W, canon'd here | **v1.2.0**     | 1 × minor (new exit codes 10/11 + two new `result_code` words) | PFS-15 (Wave 99) |

Every patch bump is additive-and-signature-widening, with retired stubs
documented in each CHANGELOG's **Retired** block. The one minor bump
(umount.pdxfs v1.2.0) earns its slot via two new reachable exit codes
(`UMOUNT_ERR_NO_ELEVATE = 10`, `UMOUNT_ERR_REVOKE_FAIL = 11`) and two new
`result_code` lexemes (`NO_ELEVATE`, `REVOKE_FAIL`) in the mount-record
witness grammar; every pre-PFS-15 exit code and lexeme keeps its numeric
value and spelling, so the bump satisfies the libpdx-volume
backward-compatibility posture (`src/lpv_errors.pdx` §Compatibility).

### 3.2 Observed inconsistency — tag drift

The three submodule heads describe themselves (via `git describe`) as:

```
tools/user/libpdx-volume: v1.1.5-7-g8c78f50
tools/user/mount.pdxfs:   r64v2-closed-11-g2c4c386
tools/user/umount.pdxfs:  r64v2-closed-8-g090d837
```

That is: **`libpdx-volume` is 5 CHANGELOG bumps ahead of its last git tag**
(v1.1.5 → v1.1.6/7/8/9/10 all land in-band without a tag), and
**`mount.pdxfs` and `umount.pdxfs` have never carried a `vX.Y.Z` tag at
all** — their last tag `r64v2-closed` is a wave sigil, not a semver tag.
The CHANGELOG is the ground truth today; `find-paideia-as.sh`-style
version-discipline tooling would reject this on a strict-tag pass.

### 3.3 Recommended terminal tag discipline (PFS-17 action)

Tag the three submodules at their current `HEAD`:

```sh
# libpdx-volume
( cd tools/user/libpdx-volume &&
  git tag -a v1.1.10 -m "PFS-W close: real pdxb_block_encrypt/_decrypt (PFS-14)"
  git push origin v1.1.10 )

# mount.pdxfs
( cd tools/user/mount.pdxfs &&
  git tag -a v1.1.7 -m "PFS-W close: sys_dek_seal seal-hop (PFS-13)"
  git push origin v1.1.7 )

# umount.pdxfs
( cd tools/user/umount.pdxfs &&
  git tag -a v1.2.0 -m "PFS-W close: --force end-to-end (PFS-15)"
  git push origin v1.2.0 )
```

The outer monorepo does **not** bump a submodule reference as part of this
terminal action — the submodule heads are already at the right SHAs. The
tags are retroactive confirmations of what the CHANGELOGs already assert.

See §9.2 for the terminal recommendation on living-doc posture after this
tagging round.

---

## 4 Capabilities Delivered

### 4.1 Kernel capability kinds

| Capability                       | Kind id | Row width | Ops delivered this band       | Reserved rights                   |
|----------------------------------|---------|-----------|-------------------------------|-----------------------------------|
| `KIND_PDXFS_MOUNT_TABLE`         | `0x1A5` | existing  | `PMT_OP_APPEND_ROW` real body (PFS-10) | `R_PMT_WRITE` gates APPEND         |
| `KIND_DEK` (data-encryption key) | `0x1A4` | 64 B      | `SEAL` (stub, supervisor-only), `LOOKUP_BY_VOLUME`, `SCRUB` | `R_DEK_SEAL`/`READ`/`SCRUB` |
| `KIND_VOLUME`                    | existing | existing | `VOL_OP_QUERY_DEVICE_SLOT` (PFS-11, op 0), `VOL_OP_QUERY_HANDLE_COUNT` (op 10), `VOL_OP_REVOKE_HANDLE` (PFS-15, op 11) | `R_VOL_INVOKE` (0x008), `R_VOL_REVOKE` (0x010; new) |

`KIND_VOLUME.VOL_OP_MAX` was bumped 10 → 11. Op 11 is the only op in the
catalog that legitimately carries a nonzero `op_arg[63:8]` — the per-handle
index for the revoke sweep. Every other op still refuses one.

### 4.2 New syscalls

| sysno | Name              | Wave      | Signature (rdi, rsi, rdx, r10, r8)         | Return packing            |
|-------|-------------------|-----------|--------------------------------------------|---------------------------|
| 135   | `sys_vol_mint`    | PFS-09 / Wave 93 | `(desc_user_ptr, parent_cap_slot, …)`      | `(cap_handle << 2) \| status` |
| 136   | `sys_dek_seal`    | PFS-13 / Wave 97 | `(dek_user_page, volume_cap_slot, volume_id, …)` | `(row_id << 2) \| status`     |
| 137   | `sys_dek_apply`   | PFS-14 / Wave 98 | `(row_id, buf_user_ptr, lba, mode, volume_prefix_u64)` | `0` / error band              |

All three dispatch through the frozen SC+ entry via `dispatch.pdx`'s main
`cmp` cascade. The `sys_mount`/`sys_umount` pair (sysnos 75/76) was already
in dispatch before PFS-W began — PFS-01 only froze its ABI, PFS-10 landed
the real `PMT_OP_APPEND_ROW` arm the dispatch call reaches.

### 4.3 Boundary posture

The three new syscalls jointly close **GAP #P2** — the former "unwrapped
DEK survives in mount.pdxfs's private `.bss` past the KEK-unseal site"
posture. From Wave 98 forward, the 32-byte DEK never crosses the
user/kernel boundary in plaintext: `sys_dek_seal` writes the DEK into a
pinned `KIND_DEK` row in kernel space and returns only a `row_id`;
`sys_dek_apply` performs the per-block AEAD inside the kernel using that
row and never emits the key material back. User-space callers hold a
reference, not a key.

Formally, let $\mathcal{K}$ denote the set of plaintext DEK bytes, let
$\mathcal{U}$ denote the user-mode address space of any process, and let
$t_{\text{seal}}$ denote the clock tick at which `sys_dek_seal` returns.
Then

$$\forall t \geq t_{\text{seal}},\ \ \mathcal{K} \cap \mathcal{U}(t) = \emptyset,$$

holds by construction (every scrub-on-return path in `passphrase_wire_unlock`
executes before `ret`, and the kernel row is accessed only through
`sys_dek_apply` which copies ciphertext in and plaintext out, not the key).

### 4.4 Cap-table slot occupancy at image-load

Per PFS-02 (`init-caps-seed-convention.md` §2.3), the two seeded slots are:

- **Slot 4** — `KIND_PDXFS_MOUNT_TABLE` (0x1A5), rights 0x00A, singleton row.
- **Slot 5** — `KIND_IPC_ENDPOINT` (0x005), rights 0x00A, broker, BIDI,
  `endpoint_id = 16`.

`KIND_ELEVATE_CHANNEL` rows (used by `umount --force` and `/system` mounts)
are per-request state minted on demand from the slot-5 broker handle; they
are **not** stamped at image load. The elevate call path is complete on
the user side (mount.pdxfs `mint_wire.pdx`, umount.pdxfs `elevate.pdx`);
PFS-18 provisions the broker-endpoint cap at shell-session mint and makes
these mints reach a non-stub arm.

---

## 5 Design Contracts Frozen This Band

Five contracts under `design/pdxfs/` were made load-bearing by PFS-W. Each
is a terminal contract: downstream consumers reference these by section
anchor, and the §PFS-11 §PFS-12 extensions landed in-band are additive
rather than destructive.

| Doc                                                   | PFS   | LOC   | Frozen contract                                                        |
|-------------------------------------------------------|-------|-------|------------------------------------------------------------------------|
| `design/pdxfs/sys-mount-abi.md`                       | PFS-01 | 1106  | Path-based `sys_mount`/`sys_umount` ABI; four ABI surprises retired   |
| `design/pdxfs/init-caps-seed-convention.md`           | PFS-02 | 632   | Slot 4 = KIND_PDXFS_MOUNT_TABLE, Slot 5 = KIND_IPC_ENDPOINT broker    |
| `design/pdxfs/mldsa65-verify-intrinsic.md`            | PFS-04 | 591   | libpdx-volume adopts upstream paideia-as#1347 intrinsic; stub removal plan |
| `design/pdxfs/block-crypto-contract.md`               | PFS-05 | 558   | One DEK/volume (rejects HKDF-per-block); 12-byte nonce; 1:128 metadata |
| `design/pdxfs/sys-vol-mint-abi.md`                    | PFS-09 | 481   | sysno 135; 64B descriptor magic PDXV; `(cap_handle << 2) \| status`   |
| `design/pdxfs/sys-dek-seal-abi.md`                    | PFS-13 | 288   | sysno 136; three-level scrub (kernel + SDS_STAGING + userscratch)      |

Total: 3,656 LOC of ABI contract. **No contract was retracted or revised
destructively during the band.**

### 5.1 Contract abstracts (one line each)

- **`sys-mount-abi.md`** — Frozen path-based ABI at sysno 75/76. `sys_mount`
  takes `(dev_path_ptr, dev_path_len, mp_ptr, mp_len, mount_cap_slot)`;
  `sys_umount` mirrors with a length bound asymmetric by 1 (255 vs 256
  — documented, not an oversight). Error bands 0xED60..67 (mount) and
  0xED68..6E (umount). KIND_PDXFS_MOUNT_TABLE row shape fixed:
  `(mount_id u64, mp_hash u64, dev_cap u64, flags u64, result_code u32,
  stub_mask u32, time_ns u64)`.
- **`init-caps-seed-convention.md`** — Loader seeds exactly slots 4 and 5
  at image load from the ELF's `.caps.decl` sidecar. `sys_fork` does **not**
  copy; `sys_execve` reloads from the child image's own sidecar. The
  singleton-row specialisation on slot 4 and the broker-endpoint seed-time
  gate on slot 5 are the two kernel-side extensions this doc rests on.
- **`mldsa65-verify-intrinsic.md`** — Cross-repo adoption contract. The
  real ML-DSA-65 verify intrinsic shipped upstream in paideia-as#1347
  (toolchain v0.28.1); libpdx-volume's `pdxb_verify_inode_tail` /
  `pdxb_verify_superblock` call sites are the user-side adoption gap.
  NIST ACVP conformance vectors mirror tracked at paideia-as#1604.
- **`block-crypto-contract.md`** — One-DEK-per-volume (rejects HKDF-per-
  block on three grounds: boundary-crossing cost, nonce-space exhaustion
  parity, and tag-storage overhead). 12-byte deterministic nonce =
  `volume_prefix(4) || lba(8)`. Birthday bound at $2^{48}$ blocks per
  volume. 128 data blocks per metadata block (corrects the earlier
  `architecture.md §11.4` estimate of 256). ChaCha20-Poly1305 AEAD.
- **`sys-vol-mint-abi.md`** — sysno 135. Descriptor 64 B with magic
  `PDXV`. Return packed as $(h \ll 2) \mathbin{|} s$ where $h$ is the
  cap handle and $s \in \{0,1,2,3\}$ is a 2-bit status (`OK`, `INVALID`,
  `OUT_OF_ROWS`, `DENIED`). §6.1 names the consolidation path with the
  pre-existing sysno 114 to retire after PFS-19 picks a terminal number.
- **`sys-dek-seal-abi.md`** — sysno 136. Reads 32 B from a pinned user
  page into a `KIND_DEK` row via `kind_dek_mint_body`. Three-level scrub
  discipline: kernel scratch + `SDS_STAGING_SLOT = 138` cap +
  mount.pdxfs userscratches. Return packs $(r \ll 2) \mathbin{|} s$ where
  $r$ is the row id and $s \in \{0,1,2,3\}$ (`OK`, `INVALID_SLOT`,
  `INVALID_PAGE`, `MINT_FAILED`).

### 5.2 Non-contract follow-ups

- `block-crypto-contract.md` §5 (paired-metadata on-disk layout) is a
  frozen contract but has no on-disk implementation yet. PFS-14 landed the
  AEAD transport within a single 4112-byte user buffer; §5's persistent
  pairing is deferred to **PFS-14b** / `#2734`. The contract itself does
  not change.

---

## 6 Open Follow-ups Filed During PFS-W

| Issue  | Origin                           | Resolution at PFS-17 close                            |
|--------|----------------------------------|-------------------------------------------------------|
| #2730  | PFS-05 §Deferred                 | **Superseded by PFS-14** (Wave 98). Close as duplicate. |
| #2731  | PFS-12 Part A §Gap #P2           | **Landed Wave 97** (PFS-13). Closed in that commit.    |
| #2732  | PFS-13 §Deferred (block-crypto bodies) | **Landed Wave 98** (PFS-14). Closed in that commit.    |
| #2733  | Wave 97 R125.M3 softarch mid-task break | **Landed Wave 98** (R125.M3-CONT). Closed.             |
| #2734  | PFS-14 §Deferred (pdxb_block_meta.pdx) | **Open.** Scope at §6a below. Scheduled: PFS-14b.      |

### 6a #2734 — PFS-14b scope

The deferred continuation `pdxb_block_meta.pdx` module per PFS-05 §5. On-
disk 32-byte metadata records (`nonce[12] + tag[16] + flags[1] +
reserved[3]`), 128 records per metadata block, laid out at the tail of
each data region. Required reads/writes: `pdxb_block_meta_read`,
`pdxb_block_meta_write`. PFS-14 landed the AEAD transport within a single
user buffer (data[4096] + tag[16] = 4112 B); persisting those tags to
their own metadata block, pairing them with data LBAs across remount, and
QEMU round-trip smoke are the three deliverables of PFS-14b.

---

## 7 BLOCKED PFS-16 Fixtures and Unblock Routing

PFS-16 landed ten smoke fixtures under `tests/fixtures/pdxfs/`. Three are
GREEN at the PFS-17 close:

- **01 basic-mount-umount** — dry-run round trip against tmpfs.
- **07 snapshot-list** — reaches `SNAPSHOT_NOT_IMPL` (today's correct
  terminal state per PFS-07 §Deferred).
- **10 elevate-missing** — `/system/*` mount without an elevate cap →
  `NO_ELEVATE`.

Seven are BLOCKED. Each `blocked.txt` names the unblock wave:

| Fixture                       | Blocker                                                               | Unblock wave |
|-------------------------------|-----------------------------------------------------------------------|--------------|
| 02 mount-twice                | Kernel `sys_mount_body` has no duplicate-row refuse arm (no `MR_RESULT_ALREADY_MOUNTED` minted today). | **PFS-17 action: dup-mount refuse at `dispatch_mount` + libpdx-volume `mount_table_snapshot` query at mount.pdxfs pre-flight.** |
| 03 umount-not-mounted         | GREEN (verified mid-report) — reaches `MOUNT_NOT_FOUND`. See §7a note. | n/a          |
| 04 force-umount               | PFS-15's reachable arm is `UR_RC_NO_ELEVATE`; the `UR_RC_OK + revoked_handles > 0` shape needs an elevate-channel broker-endpoint cap provisioned at shell session mint. | **PFS-18** |
| 05 passphrase-fd-ok           | PFS-12A landed KIND_DEK; the mount.pdxfs call-site (`--passphrase-fd` → KEK derive → DEK unseal → `volume_bind`) is a documented deferral. | **PFS-12 Part B** |
| 06 passphrase-fd-wrong        | Same blocker as 05; `MR_RESULT_WRONG_PASSPHRASE` arm reaches once Part B lands. | **PFS-12 Part B** |
| 08 volume-mint                | PFS-09 landed `sys_vol_mint` at the syscall layer; no `/bin/vol.pdxfs` CLI exists. | **PFS-19** |
| 09 multivol-ordering          | PFS-06 landed Kahn's sort kernel-side; `--all` feeds its dep graph from a cap-env (`/etc/pdxfs/mounts.toml`) that isn't materialized at tmpfs seed time. | **PFS-20** |

### 7a Reconciliation note

`03-umount-not-mounted` was not listed as GREEN in the Wave 100 commit's
"3 GREEN fixtures" summary (basic-mount-umount, snapshot-list,
elevate-missing); however `tests/fixtures/pdxfs/03-umount-not-mounted/`
carries an `expected.golden` and no `blocked.txt`, which under PFS-16's
own classification scheme is the GREEN posture. The honest count is
either **3 or 4 GREEN** depending on whether 03's absence of
`blocked.txt` is interpreted as GREEN-by-omission. **Recommendation
(see §9 action list):** Wave 101 should either add `blocked.txt` to 03
with the real blocker (same `MR_RESULT_MOUNT_NOT_FOUND`-not-minted gap
as fixture 02) or reclassify it GREEN explicitly in
`tests/README-pdxfs-smoke.md`'s header count. This report counts 3 GREEN
by the Wave 100 commit's own claim.

### 7b Unblock-wave queue

PFS-W closes with four follow-up waves queued, each with a dedicated
scope:

- **PFS-17b** (dispatch-mount dup-refuse) — this ticket's own follow-up
  action (not the acceptance report itself).
- **PFS-18** (elevate-channel broker-endpoint cap provision at shell
  session mint; closes fixture 04).
- **PFS-19** (`/bin/vol.pdxfs` CLI scaffold mirroring mkfs.pdxfs's
  `PdxFsFormatRecord` emit shape; closes fixture 08).
- **PFS-20** (`/etc/pdxfs/mounts.toml` ingest at init start; closes
  fixture 09).
- **PFS-12 Part B** (mount.pdxfs call-site `--passphrase-fd` → `sys_dek_seal`
  → `volume_bind`; closes fixtures 05 + 06).
- **PFS-14b** (`pdxb_block_meta.pdx`; closes `#2734`).

---

## 8 Non-goals That Stayed Out of PFS Scope

The following were explicitly out of scope for PFS-W and remain so:

- **ext4 compatibility layer.** pdxfs is a clean-slate filesystem; no on-
  disk compatibility with ext4 at either superblock or inode-table layer
  is contemplated. A read-only ext4 adapter is a separate design slice
  pending research-bias review per the novel-clean-design directive.
- **FUSE adapter.** No user-mode-filesystem bridge is in scope. PaideiaOS
  has no FUSE substrate (there is no `KIND_FS_UPCALL` nor a user-mode
  dispatch hop); building one is a research track orthogonal to PFS-W.
- **Raw-device mount without `KIND_VOLUME`.** The `sys_mount` ABI
  (PFS-01) requires an authority capability. There is no path from a
  bare block-device cap to a mounted filesystem that bypasses
  `volume_cap_resolve`. This is a deliberate posture, not an oversight.

---

## 9 Smoke Results and Terminal Posture

### 9.1 PFS-16 harness summary

```
tools/run-pdxfs-smoke.sh      — per-fixture QEMU launcher
tests/README-pdxfs-smoke.md   — fixture catalog + unblock routing
tests/fixtures/pdxfs/01..10   — ten fixtures

GREEN at PFS-17 close:  3 (01, 07, 10)
BLOCKED at PFS-17 close: 7 (02, 04, 05, 06, 08, 09, plus 03 pending §7a reconciliation)
GREEN fraction:          30 % (3/10)
Reachable-today fraction after PFS-W: 100 % of what PFS-W promised to
                                      reach was reached.
```

The 30 % GREEN count is not a quality metric — it is a classification
honesty metric. The seven BLOCKED fixtures were landed deliberately with
`blocked.txt` rather than suppressed, so that the forward-wave queue
(PFS-18/19/20, PFS-12B, PFS-14b, PFS-17b) is visible from the test corpus
itself.

### 9.2 Terminal action — tag + living-doc posture

**This report is finalized at PFS-17 close.** The recommended terminal
action is:

1. **Tag the three submodules per §3.3.** Retroactive confirmation of
   CHANGELOG state.
2. **Keep this document as a living reference**, not a tombstone. The
   §7b unblock-wave queue names six scheduled follow-ups whose landings
   should update §7 and §9.1 in-place; §4 (capabilities) and §5
   (contracts) are frozen and should not be edited; §6 (follow-ups) is
   append-only.
3. **Reconcile fixture 03 per §7a** on the next PFS-wave landing.
4. **Close `#2584`** with a link to this document.

---

## 10 New Fingerprint Allowlist Entries (Waves 96–100)

Six substrate fingerprints were added to the allowlist in
`tools/verify-fingerprint-coverage.sh` during the PFS-W band. Each is
emitted unconditionally on boot but has no asserting smoke-mode golden
yet; each will retire from the allowlist when its named production
consumer lands.

| Fingerprint                       | Wave / Milestone      | Emitted from                                              | Retires with                        |
|-----------------------------------|-----------------------|-----------------------------------------------------------|-------------------------------------|
| `CAP_MINTER INIT OK`              | Wave 96 R125.M2       | `src/kernel/core/svc/cap_minter.pdx::_cap_minter_init`    | **R125.M3** (production dispatch)   |
| `CAP_MINTER DERIVE OK`            | Wave 96 R125.M2       | `_cap_minter_derive` (harness-only; stub `_set_active_env`) | **R125.M3** (IPC dispatch wire)     |
| `SHELL_SESSION INIT OK`           | Wave 98 R127.M1       | `src/kernel/core/svc/shell_session.pdx::_shell_session_init` | **R127.M2** (KIND_SHELL_SESSION + cap-invoke) |
| `SHELL_SESSION CREATE OK`         | Wave 98 R127.M1       | `_shell_session_create` (rodata-tag; unreachable at M1)   | **R127.M2** (CREATE op)             |
| `SHELL_SESSION STATE OK`          | Wave 98 R127.M1       | `_shell_session_set_state` (unreachable at M1)            | **R127.M2** (SET_STATE op)          |
| `SHELL_SESSION DESTROY OK`        | Wave 98 R127.M1       | `_shell_session_destroy` (unreachable at M1)              | **R127.M2** (DESTROY op)            |
| `SYSCALL CAP_CHECK TABLE OK`      | Wave 99 R125.M4       | `src/kernel/core/syscall/cap_check.pdx::_syscall_rights_table_init` | **R125.M5** (hard-fail flip)        |
| `KIND_SHELL_SESSION INIT OK`      | Wave 99 R127.M2       | `src/kernel/core/cap/kind_shell_session.pdx::kind_shell_session_init` | **R127.M3** (production dispatch)   |
| `KIND_SHELL_SESSION HANDLER OK`   | Wave 99 R127.M2       | `cap_handler_shell_session` (unreachable at M2)           | **R127.M3**                         |
| `KIND_SHELL_SESSION MINT OK`      | Wave 99 R127.M2       | `kind_shell_session_mint_body` (supervisor-only)          | **R127.M3**                         |
| `PERF SINK INIT OK`               | Wave 100 R141.M2      | `src/kernel/core/perf/perf_sink.pdx::_perf_sink_init`     | **R141.M3** (KIND_LOG_SINK wire)    |
| `PERF SINK DUMP OK`               | Wave 100 R141.M2      | `_perf_sink_dump_all` success tail                        | **R141.M3** (asserting consumer)    |

An additional runtime fingerprint `"CMDREG RELOADED rows=N errno=M"` was
added in **Wave 95 R123.M6** (`kind_cmd_module.pdx::kcm_hd_op_reload`).
It is a per-reload runtime emission, not a boot-time marker, so it does
not appear in `verify-fingerprint-coverage.sh`'s `ALLOWLIST`; it has no
retirement condition in the allowlist sense. The task brief lists it with
the allowlist set for completeness, hence this clarification. Shipped
with `R_CM_WRITE = 0x004` gate and `CRP_ERR_RELOAD_BUSY = 0x0C05`.

---

## 11 Band Timeline and Statistics

### 11.1 Timeline

```
Wave 85  2026-10-11  PFS-01  sys-mount ABI freeze                   [DOC]
Wave 86  2026-10-11  PFS-02  _init_caps seed convention             [DOC]
Wave 88  2026-10-11  PFS-04  mldsa65 verify adoption contract       [DOC]
Wave 89  2026-10-11  PFS-05  block-crypto contract                  [DOC]
Wave 89  2026-10-11  PFS-06  Kahn's sort real body                  [GREEN]
Wave 91  2026-10-11  PFS-07  snap_chain_walk real body + adaptation [GREEN]
Wave 92  2026-10-11  PFS-08  inode quota check + commit             [GREEN]
Wave 93  2026-10-11  PFS-09  sys_vol_mint (sysno 135)               [GREEN]
Wave 94  2026-10-11  PFS-10  PMT_OP_APPEND_ROW + path-based ABI     [GREEN]
Wave 95  2026-10-11  PFS-11  VOL_OP_QUERY_DEVICE_SLOT real wire     [GREEN]
Wave 96  2026-10-11  PFS-12A KIND_DEK substrate                     [SPLIT]
Wave 97  2026-10-11  PFS-13  sys_dek_seal (sysno 136)               [GREEN]
Wave 98  2026-10-12  PFS-14  sys_dek_apply + block-crypto bodies    [SPLIT]
Wave 99  2026-10-13  PFS-15  VOL_OP_REVOKE_HANDLE + umount --force  [GREEN]
Wave 100 2026-10-13  PFS-16  smoke corpus (3 GREEN, 7 BLOCKED)      [GREEN]
Wave 100 2026-10-13  PFS-17  this report                            [GREEN]
```

### 11.2 Statistics

- **Days elapsed**: 3 (Oct 11 → Oct 13, 2026).
- **Waves consumed**: 16 (wave 85 through wave 100, excluding wave 87 and
  wave 90 which were adjacent but non-PFS wave content).
- **Issues closed**: 15 — #2568, #2569, #2572, #2573, #2574, #2575, #2576,
  #2577, #2578, #2731, #2732, #2733, #2582, #2583 (partial), #2584 (this
  ticket).
- **Issues deferred open at PFS-17 close**: 1 — #2734 (PFS-14b
  continuation).
- **New kernel LOC** (approximate, excluding tests): ~5,100 across
  `sys_vol_mint_body.pdx` (646), `sys_dek_seal_body.pdx` (524),
  `sys_dek_apply_body.pdx` (639), `kind_dek.pdx` (1044),
  `kind_volume.pdx` deltas (REVOKE_HANDLE arm), dispatch/invoke deltas.
- **New design LOC**: 3,656 across six contracts under `design/pdxfs/`
  (sys-mount, init-caps-seed, mldsa65-verify, block-crypto, sys-vol-mint,
  sys-dek-seal) + 779 across this report and the fixture README.
- **CHANGELOG bumps per submodule**: libpdx-volume ×5, mount.pdxfs ×4,
  umount.pdxfs ×1.

## 12 Terminal Verdict

The pdxfs tooling slice entered PFS-W with four frozen ABIs promised but
not written down, three stop-gaps (dev-slot low-nibble resolver, plaintext
DEK in `.bss`, `--force` ELEV_DENY unreachable arm) actively masking
kernel-side gaps, and no honest smoke corpus. It exits PFS-W with:

- Five contracts frozen (3,656 LOC of ABI).
- Three new syscalls (135/136/137) carrying real bodies.
- One new capability kind (`KIND_DEK`) and one widened one (`KIND_VOLUME`
  with `R_VOL_REVOKE` and op 11).
- Three submodules bumped (one patch × 2, one minor × 1) with every
  retired stub documented in-place.
- Ten smoke fixtures with honest BLOCKED routing and six named unblock
  waves queued.

**The pdxfs tooling, as of PFS-17 close, is production-shaped for the
reachable surface and transparent about the unreachable surface.**
Tag the three submodules, close #2584, and resume the forward wave queue.

Closes paideia-os#2584.
