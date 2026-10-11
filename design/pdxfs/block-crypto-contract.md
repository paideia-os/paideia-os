# pdxfs block-crypto contract — PFS-05 (design-only wave)

**Status:** DESIGN FROZEN (bodies deferred to follow-up).
**Wave:** PFS-W3 (PFS-05, parent `paideia-os/paideia-os#2572`).
**Scope:** The on-wire + in-memory contract that `libpdx-volume`'s
`pdxb_block_encrypt` / `pdxb_block_decrypt` MUST honour, plus the
paired-metadata on-disk layout the pdxfs CoW block-write path reads
and writes alongside the ciphertext block. Doc-only — real bodies
land in a sibling follow-up ticket enumerated in §7.
**Supersedes / aligns with:**
- `tools/user/libpdx-volume/src/pdxb_crypto.pdx` (fail-closed stubs
  at lines 363-381 — this doc is their adoption gate).
- `tools/user/libpdx-volume/design/architecture.md` §11.4 (the
  "paired-block vs inline-trailer" trade-off; this doc completes
  that write-up).
- `tools/user/libpdx-volume/src/pdxb_superblock.pdx` lines 764-874
  (superblock offsets `PDXB_D_OFF_WRAPPED_DEK = 192`,
  `PDXB_D_OFF_KDF_SALT = 240`, `PDXB_D_OFF_WRAP_NONCE = 256` and
  the paired-block scheme comment).
- `src/kernel/core/cap/kind_kek.pdx` (KIND_KEK = 0x1B4, derived
  over KIND_MEMORY — the capability holder this contract plugs
  into).
- `design/filesystem/volume-fs-substrate.md` §502 ("Encryption at
  rest. Signed-inode-tail is R52; per-block encryption is R54+
  (needs KIND_KEK and per-block IV discipline)") — this doc is
  the delivery of that R54+ IV discipline.

---

## §1 Overview

### 1.1 Who calls

Three consumers at the real-body landing (§7):

1. **`libpdx-volume`'s own `pdxb_block_encrypt` / `pdxb_block_decrypt`**
   (`tools/user/libpdx-volume/src/pdxb_crypto.pdx`) — the library
   entry points this contract specifies. Today they are fail-closed
   stubs returning `LPV_CRYPTO_ERR_NOT_IMPL = 0x0901`.
2. **The pdxfs CoW block-write path**
   (`src/kernel/core/fs/pdxfs/{cow_write.pdx, nvme_write.pdx}`) will
   invoke the real bodies via a client-side helper that mkfs.pdxfs /
   mount.pdxfs embed. No kernel-side call-site exists at this
   landing — the kernel block-write path is unaware of the encrypted
   data path and will remain so until the real bodies ship.
3. **`mount.pdxfs` `--passphrase-fd` wiring** (PFS-12 — see
   `tools/user/mount.pdxfs/STATUS.md` M6-004 and the "PFS-12 call-
   site wiring" bullet). The DEK derived through
   `pdxb_kek_derive → pdxb_dek_unwrap` reaches `pdxb_block_encrypt` /
   `pdxb_block_decrypt` after this landing closes.

### 1.2 What for

Encrypt-at-rest for pdxfs volumes. The design frontier is twofold:
guarantee ChaCha20-Poly1305 AEAD *nonce uniqueness* across every
block in the volume for the DEK's lifetime, and keep the paired
authentication tag + nonce reachable from the block-read path at
constant extra I/O cost. The two decisions this doc freezes are
**(a) how the DEK is derived from the KEK**, and **(b) where the
per-block (nonce, tag) pair lives on disk**. Section 2 fixes the
ABI; §3 the DEK derivation; §4 the nonce discipline; §5 the paired-
metadata layout.

### 1.3 Why this is a design-only wave

ChaCha20-Poly1305 misuse is a one-shot catastrophic failure
(any nonce reuse against the same key leaks the ciphertext XOR
difference verbatim, breaking confidentiality AND authenticity for
every reused pair). Freezing the derivation + nonce discipline
before writing a line of asm is the only responsible shape. The
fail-closed stubs that ship today prevent *any* caller from reaching
a wrong implementation; this doc is the gate on the real-body
follow-up.

---

## §2 ABI

### 2.1 Signatures

Both entry points keep their currently-landed arity (4 args) — the
caller supplies the DEK and the per-block output cursors; no cap-
slot is taken, following the "zero cap-invoke" discipline that
every other libpdx-volume helper honours (`architecture.md` §8.2).

```
fn pdxb_block_encrypt(dek_ptr:   u64,
                      block_ptr: u64,
                      nonce_ptr: u64,
                      out_tag_ptr: u64) -> u64
  !{crypto, mem} @{paideia.crypto}

fn pdxb_block_decrypt(dek_ptr:   u64,
                      block_ptr: u64,
                      nonce_ptr: u64,
                      tag_ptr:   u64) -> u64
  !{crypto, mem} @{paideia.crypto}
```

Argument shape:

- `dek_ptr` — pointer to the caller's 32-byte DEK buffer (unwrapped
  from the superblock's `wrapped_dek` slot via the already-landed
  `pdxb_dek_unwrap`). Zero DEKs are rejected with
  `LPV_CRYPTO_ERR_BAD_KEY_LEN = 0x0905` (same sentinel used for the
  current KEK gate in `pdxb_dek_wrap`).
- `block_ptr` — pointer to a 4096-byte volume block. Encrypt is
  **in-place**: on return `block_ptr[0..4096)` holds the ciphertext.
  Decrypt mirrors: on authenticated return `block_ptr[0..4096)` holds
  the plaintext; on tag mismatch the buffer is scrubbed to zero
  before `LPV_CRYPTO_ERR_TAG_MISMATCH = 0x0904` is returned (fail-
  closed; no plaintext leaked).
- `nonce_ptr` — pointer to the 12-byte nonce. For encrypt this is
  the SOURCE: the caller computed it per §4. For decrypt this is
  the nonce the paired-metadata record returned.
- `out_tag_ptr` (encrypt) / `tag_ptr` (decrypt) — pointer to the
  16-byte Poly1305 authentication tag slot. Encrypt writes; decrypt
  reads.

### 2.2 Return taxonomy

Both functions return a `u64` sentinel from the already-reserved
`LPV_CRYPTO_*` band (`pdxb_crypto.pdx` lines 93-99):

| Sentinel                           | Meaning                                   |
|------------------------------------|-------------------------------------------|
| `LPV_CRYPTO_OK = 0`                | success                                   |
| `LPV_CRYPTO_ERR_AEAD_FAIL = 0x0903`| ChaCha20-Poly1305 intrinsic refused args  |
| `LPV_CRYPTO_ERR_TAG_MISMATCH = 0x0904` | decrypt only; buffer scrubbed         |
| `LPV_CRYPTO_ERR_BAD_KEY_LEN = 0x0905` | DEK buffer sanity-check failed         |

The current `LPV_CRYPTO_ERR_NOT_IMPL = 0x0901` sentinel the stubs
return is retired at the follow-up landing (it was the gate this
doc now closes).

### 2.3 Effect / capability discipline

`!{crypto, mem}` matches the sibling `pdxb_dek_wrap` / `_unwrap`
one-for-one — the real bodies compose a ChaCha20-Poly1305 call
(`!{crypto}`) with reading/writing the in-place block buffer
(`!{mem}`). `@{paideia.crypto}` is the capability every call to the
`ChaCha20Poly1305::seal` / `::open` intrinsic needs.

---

## §3 DEK derivation

### 3.1 Volume-wide single-DEK discipline (adopted)

The DEK is **one per volume**, derived once at mkfs-time and
unwrapped at mount-time. This matches the already-landed on-disk
shape (`pdxb_superblock.pdx` offsets 192/240/256: a single
`wrapped_dek` + `kdf_salt` + `wrap_nonce` triple per superblock)
and the parent-issue brief's own paragraph ("DEK scope: one DEK per
volume (not per-file)").

The dispatch brief for this wave proposed an alternative
`HKDF-SHA256(KEK, "pdxfs-block-dek-v1", block_hash)` per-block
derivation. We **do not adopt it** at this landing for three
compounding reasons documented here so the trade-off is reversible
if the balance shifts:

1. **No HKDF-SHA256 intrinsic exists** in paideia-as today.
   `tools/paideia-as/crates/paideia-as-stdlib/pdx/crypto/` ships
   only `argon2id`, `chacha20_poly1305`, `mldsa_65_c`, `ml_kem_768`.
   A per-block HKDF derivation would force an upstream intrinsic
   wave (SHA-256 + HKDF-Expand) before libpdx-volume could proceed.
2. **`block_hash` is self-referential.** For encrypt, hashing the
   plaintext leaks a plaintext-pinned deterministic artifact; for
   decrypt the plaintext is unavailable until *after* the DEK is
   known. Using the ciphertext hash breaks determinism (ciphertext
   changes between writes). Neither choice composes.
3. **Per-block DEK is a defence-in-depth gain against KEK compromise
   at a specific threat profile** (an attacker who obtains a single
   DEK sees exactly one block of plaintext). pdxfs's current threat
   model treats the KEK itself as the trust anchor (sealed under a
   future hardware RoT per `kind_kek.pdx` §1); if the KEK leaks,
   every per-block DEK derived from it leaks too, so the per-block
   derivation adds no defence against the attacker the volume-DEK
   scheme already assumes compromises everything.

The HKDF-per-block variant is tracked for a future revisit under
`§7.2 Rejected alternatives` of this doc.

### 3.2 KEK → DEK derivation (frozen)

The DEK is produced at mkfs-time by the already-landed primitive
chain, with no new intrinsic required:

```
  passphrase  (ring-3 input, PFS-12 --passphrase-fd)
      │
      │  pdxb_kek_derive(passphrase, kdf_salt, Argon2id-RFC-9106-SG)
      ▼
  KEK[32]  — never persisted; held in-memory
      │
      │  CSPRNG → DEK[32]  (fresh random per mkfs)
      │  CSPRNG → wrap_nonce[12]  (fresh random per mkfs)
      │
      │  pdxb_dek_wrap(KEK, DEK, wrap_nonce)
      ▼
  wrapped_dek[48]  — written to superblock+192
  wrap_nonce[12]   — written to superblock+256
  kdf_salt[16]     — written to superblock+240
```

Mount reverses: `pdxb_kek_derive` reconstructs KEK from the user's
passphrase + the on-disk `kdf_salt`; `pdxb_dek_unwrap` recovers
DEK from the on-disk `wrapped_dek` under KEK + `wrap_nonce`. The
32-byte DEK then lives in the mount's protected memory region (a
future KIND_MEMORY cap gated by RIGHT_READ, provisioned by the
mount's init-caps seed per PFS-02's `design/pdxfs/init-caps-seed-
convention.md`) for the lifetime of the mount. On umount the DEK
region is scrubbed to zero.

### 3.3 DEK lifetime + rekey discipline

The DEK is **immutable for the volume's lifetime**. Rekeying (DEK
rotation under the same passphrase, or passphrase rotation re-
wrapping the same DEK) is explicitly deferred to a future wave
(`§7.3`); the on-disk shape has room for a `wrapped_dek_v2` slot
in the superblock reserved region (offsets 268-696 are free).

The 96-bit nonce birthday bound for ChaCha20-Poly1305 under a
single DEK is 2^48 encryptions before the probability of a nonce
collision exceeds 2^-32 (RFC 8439 §4). Section 4.2 shows this
bounds pdxfs volumes to 2^48 block writes per DEK — adequate for
multi-petabyte volumes without rekeying.

---

## §4 Nonce discipline

### 4.1 Deterministic LBA-indexed nonce (adopted)

For every block write the 12-byte nonce is:

```
  nonce[12] = volume_prefix[4] || LE_u64(blk_lba)
```

where `volume_prefix[4]` is the first 4 bytes of the superblock's
`kdf_salt` (`sb+240..244`) — a 32-bit per-volume constant drawn
from CSPRNG at mkfs-time. `blk_lba` is the 64-bit **logical block
address** of the block being encrypted on the backing device
(data region offset, not file offset).

This gives:

- **Cross-volume uniqueness** — two volumes with distinct
  `kdf_salt` have distinct `volume_prefix`, so the same `blk_lba`
  on two volumes produces distinct nonces. Nonce reuse across
  volumes under *the same DEK* is already impossible (DEKs are
  distinct per volume per §3.2), but the prefix is defence-in-
  depth: if a future rekey wave allows DEK sharing across volumes,
  this prefix preserves the uniqueness invariant.
- **Within-volume uniqueness** — follows directly from the pdxfs
  CoW invariant: every block write targets a *new* `blk_lba`
  (`src/kernel/core/fs/pdxfs/cow_write.pdx` §2 "monotonic bump
  allocator"; `nvme_write.pdx` §3). No LBA is overwritten in-place.
  Freed LBAs are reclaimed only through the §6 GC pathway, which
  bumps the LBA out of the live set entirely before any later
  write can land on it.

### 4.2 Birthday bound + fail-safe

`blk_lba` is 64-bit, but the nonce only has 96 bits of total
input. The CoW LBA space is bounded by the backing device's block
count: a 1 PiB NVMe at 4 KiB blocks is 2^38 LBAs, well under the
2^48 birthday bound. Volumes larger than 2^48 blocks (1 EiB at
4 KiB) must rekey.

The real-body implementation MUST assert `blk_lba < 2^48` at the
encrypt entry (one-cycle compare + `jae` to a new sentinel
`LPV_CRYPTO_ERR_LBA_EXHAUSTED = 0x0906`). This fails safe: a volume
approaching the limit refuses writes rather than silently reusing
a nonce.

### 4.3 LBA reclamation (CoW GC)

`src/kernel/core/fs/pdxfs/cow_gc.pdx` reclaims blocks whose
reference count has reached zero. A reclaimed `blk_lba` MAY be
re-handed to a later write (the bump allocator's wraparound is
disabled per `cow_write.pdx` §4, but a future compaction wave may
re-use freed LBAs). If a reused LBA produces the same nonce as a
prior write, nonce reuse is catastrophic. Three defences:

1. **Paired-metadata record scrubbing on reclaim.** `cow_gc`'s
   reclaim path (future PFS-11 wire-in) MUST zero the paired-
   metadata record for the freed `blk_lba` before releasing the
   LBA to the allocator (§5.3). A zeroed record carries the
   `META_FLAG_FREE = 0x01` sentinel in the record's flag byte;
   a reader that encounters this flag on a decrypt call returns
   `LPV_CRYPTO_ERR_TAG_MISMATCH` (the record IS absent;
   deterministically failing the decrypt is correct).
2. **Per-volume epoch counter in the superblock.** A new 8-byte
   `epoch` slot at `sb+268..276` (currently reserved; §5.5)
   participates in the nonce prefix once rekey wires in. For
   this landing the epoch is zero and the nonce formula in §4.1
   stands as written; the real-body implementation reads
   `sb+268` and tolerates zero (today's value) exactly like a
   fresh mkfs.
3. **CoW invariant assertion.** The pdxfs block-write path
   maintains an in-memory bitmap of "LBAs written this epoch";
   a repeat write to the same LBA in the same epoch panics
   (same discipline `wal.pdx` §4 uses for the WAL `head_lba`).

### 4.4 Nonce origin — mkfs vs runtime

- **mkfs** generates the first `volume_prefix` and writes it into
  `kdf_salt[0..4]`. The remaining 12 bytes of `kdf_salt` continue
  to serve the Argon2id KDF per §3.2; the overload is safe because
  Argon2id's salt uniqueness requirement is satisfied by any
  12-byte prefix of a 16-byte random blob.
- **runtime** derives the per-block nonce purely from the block's
  own `blk_lba` and the mounted volume's cached `volume_prefix`.
  No system entropy is consumed per block (CSPRNG is used only
  at mkfs-time for the DEK, the wrap_nonce, and the kdf_salt).

---

## §5 Paired-metadata storage

### 5.1 Paired-block scheme (adopted; architecture.md §11.4 confirmed)

For every 128 contiguous data blocks there is ONE metadata block
holding the (nonce, tag, flags) records. This fits paideia-os's
frozen 4 KiB block-device granularity without the inline-trailer
scheme's 4124-byte addressable-unit cascade across every block
driver (`architecture.md` §11.4 trade-off).

The ratio is **1 metadata block per 128 data blocks** (not the 16
hinted in `architecture.md` §11.4). Each record is 32 bytes:

```
  struct PdxbBlockMetaRecord {   // 32 bytes
    [+0]   nonce       [u8; 12]
    [+12]  tag         [u8; 16]
    [+28]  flags       u8        // bit 0 = META_FLAG_FREE
                                 // bit 1 = META_FLAG_WRITING
                                 // bits 2..7 reserved
    [+29]  reserved    [u8; 3]
  }
```

128 records × 32 B = 4096 B — exactly fills one metadata block.
No wasted bytes; no addressability change.

### 5.2 Metadata block LBA derivation

The metadata region sits at the **tail** of the data region, not
interleaved. mkfs computes:

```
  data_region_lba_count = <superblock-derived data blocks>
  meta_block_count      = ceil(data_region_lba_count / 128)
  meta_region_lba_start = data_region_lba_start + data_region_lba_count

  record_block_for(blk_lba) =
      meta_region_lba_start + (blk_lba - data_region_lba_start) / 128
  record_offset_for(blk_lba) =
      ((blk_lba - data_region_lba_start) % 128) * 32
```

The tail layout is chosen over interleaved so the existing block
allocator (`cow_write.pdx`'s bump cursor) walks a contiguous data
region unaware of the metadata. The allocator's upper bound is
clamped at `data_region_lba_start + data_region_lba_count` by the
same bounds check it already applies for the device.

Metadata-region sizing: a 1 TiB volume (2^28 data blocks) adds
2^21 metadata blocks = 8 GiB. The ~0.78% overhead is bounded and
scales linearly.

### 5.3 Superblock anchors (new fields in the reserved region)

Three u64 slots in the currently-reserved superblock region
(offsets 268-696 are free per `pdxb_superblock.pdx`):

```
  [+268]  epoch_counter        u64  // §4.3 defence #2
  [+276]  meta_region_lba_start u64  // §5.2
  [+284]  meta_block_count     u64  // §5.2
```

All three fall inside the signed range `[0, 696)`
(`pdxb_superblock.pdx` §2.1), so tampering with them fails the
superblock signature. The accessors
`pdxb_sb_get_meta_region_lba_start` /
`pdxb_sb_set_meta_region_lba_start` land as follow-up library
work (symmetric with the already-landed `pdxb_sb_get_wrapped_dek`
pair).

### 5.4 Read-amplification bound

Every block read now costs 2 I/Os (data + metadata) at worst case.
The metadata block cache (future PFS-13) amortises this: a 128-block
sequential scan reads ONE metadata block for ALL 128 data blocks.
The library-side caching discipline is caller-owned (libpdx-volume
has no cap-invoke path to the block cache); mount.pdxfs embeds the
cache alongside its block-read helper.

Writes cost 3 I/Os: data write, metadata read-modify-write (the
record for the written LBA must be updated in-place; the 127 other
records in the same metadata block are preserved). The RMW is
atomic across the pair under the WAL (`src/kernel/core/fs/pdxfs/
wal.pdx`): both the data block LBA and the metadata block LBA join
the same transaction. On WAL replay both land together or neither.

### 5.5 Interaction with existing superblock crypto slots

The already-landed `wrapped_dek` + `kdf_salt` + `wrap_nonce`
(offsets 192/240/256) carry the **volume-level** DEK material (§3).
The new paired-metadata records (§5.1-5.3) carry the **per-block**
AEAD material. The two are orthogonal: the volume-level slots are
read ONCE at mount (to derive the DEK); the per-block records are
read on EVERY block I/O.

---

## §6 Call-site inventory

Grep `pdxb_block_encrypt | pdxb_block_decrypt` across the whole
tree today surfaces four sites. None drives real crypto; all four
are gated by the fail-closed stub bodies this doc is the adoption
contract for.

| Call site                                                       | Shape today                                               | Shape after real-body landing                     |
|-----------------------------------------------------------------|-----------------------------------------------------------|---------------------------------------------------|
| `tools/user/libpdx-volume/src/pdxb_crypto.pdx` L363-381          | fail-closed stubs returning `LPV_CRYPTO_ERR_NOT_IMPL`     | real bodies composing ChaCha20Poly1305::seal/open |
| `tools/user/libpdx-volume/doc/libpdx-volume.pdxdoc` L375         | doc-only reference to "stubs pending"                     | doc flipped to "landed; see §2 ABI"               |
| `tools/user/libpdx-volume/CHANGELOG.md` L285, L344               | v1.1.0 "Deferred substrate" bullet                        | v1.1.6+ entry closing the deferral                |
| `tools/user/mount.pdxfs/STATUS.md` L106, L401                    | PFS-12 call-site dep bullet ("depends on PFS-05 bodies")  | the dep closes; PFS-12 unblocks                   |

No kernel-side site (the pdxfs block-write path neither calls these
helpers nor is aware of per-block encryption today). The real
kernel wiring is PFS-11's scope, downstream of this doc + the
real-body follow-up.

---

## §7 Rollout + rejected alternatives

### 7.1 Rollout order

1. **This doc lands** (PFS-W3, this wave) — the design contract
   freezes. Stubs stay fail-closed; no caller changes.
2. **Follow-up ticket (filed in §7.4)** lands real bodies in
   `src/pdxb_crypto.pdx`. The stub returns disappear; the new
   sentinels (`LPV_CRYPTO_ERR_LBA_EXHAUSTED` and any additions)
   enter the public band. libpdx-volume bumps a minor release
   (`1.2.0`) because the public API's error surface widens.
3. **mkfs.pdxfs follow-up** (PFS-10) wires the superblock
   `epoch_counter` / `meta_region_lba_start` / `meta_block_count`
   setters at image creation; mkfs reserves the metadata region
   and writes an all-zero initial metadata block set.
4. **mount.pdxfs follow-up** (PFS-12) composes
   `--passphrase-fd → pdxb_kek_derive → pdxb_dek_unwrap →
   pdxb_block_encrypt/decrypt`.
5. **pdxfs kernel block-write path** (PFS-11) wires the actual
   encrypt-on-write + decrypt-on-read gate behind the superblock's
   `PDXB_FLAG_ENCRYPTED` bit; v1 (unencrypted) and v2 (encrypted)
   volumes coexist by the flag's own switch.

Fail-closed semantics stay in force at every step. A v2 (encrypted)
volume mounted against a build that has not yet shipped the real
bodies refuses the mount with `LPV_CRYPTO_ERR_NOT_IMPL`; no block
is ever written in cleartext under a flag that claims encryption.

### 7.2 Rejected alternatives

- **HKDF-SHA256 per-block DEK derivation** (dispatch-brief
  suggestion). Rejected per §3.1's three-point rationale: no HKDF
  intrinsic exists; the `block_hash` input is self-referential; the
  defence gain misaligns with the KEK-is-trust-anchor threat model.
  Revisit if (a) a SHA-256 + HKDF intrinsic lands in paideia-as,
  AND (b) the threat model shifts to assume per-block DEK compromise
  distinct from KEK compromise.
- **Inline-trailer scheme (4124-byte on-disk unit).** Rejected per
  `architecture.md` §11.4: paideia-os block devices are frozen at
  4 KiB addressable units; a 4124-byte unit cascades across every
  block driver. The 2× I/O cost of paired blocks is bounded and
  cacheable.
- **1 metadata block per 16 data blocks** (`architecture.md`
  §11.4 initial sketch). Rejected: 16 × (12 + 16) = 448 bytes
  leaves 3648 bytes unused per metadata block (89% waste). The
  128-ratio adopted in §5.1 fills the metadata block exactly.
- **XChaCha20-Poly1305 for the extended 192-bit nonce.** Rejected
  at this landing: no XChaCha intrinsic in paideia-as. A future
  rekey wave that targets volumes beyond 2^48 blocks will revisit;
  the §4.2 fail-safe makes the ceiling an explicit refuse rather
  than a silent nonce reuse.

### 7.3 Explicitly deferred

- **DEK rotation / passphrase rotation.** The on-disk shape has
  room (sb+268 onwards is reserved, with the three §5.3 slots the
  only commitments made at this landing). A future `wrapped_dek_v2`
  + a rekey op body land in a separate wave.
- **Hardware root-of-trust sealing of the KEK.** `kind_kek.pdx`
  §1 already carries this deferral; this doc inherits it. At MVP
  the KEK derives entirely from the passphrase.

### 7.4 Follow-up ticket

Filed in-wave as the real-body implementation ticket; see §6 of
this doc for the four call sites and §2.1 for the ABI the ticket
MUST adopt verbatim.

---

## §8 Encoder discipline notes (forward-looking)

The real-body wave touches `src/pdxb_crypto.pdx` and will hit the
same pdx encoder pitfalls `pdxb_dek_wrap` / `_unwrap` already
navigate. In particular:

- **In-place AEAD is NOT a single intrinsic call.** ChaCha20-
  Poly1305 writes ciphertext + tag to a distinct `out_ptr`. The
  real body MUST allocate a 4112-byte `.bss` scratch (ciphertext
  slot + tag slot), call `ChaCha20Poly1305::seal` into it, then
  memcpy the ciphertext back into `block_ptr`. The scratch is
  single-writer by the same discipline as `lpv_aead_scratch`
  (non-reentrant; a global comment at the scratch declaration).
- **A 4096-byte memcpy via `rep movsq`** is the cleanest shape;
  `rep movsq` is not currently emitted by any libpdx-volume
  helper but the encoder supports it. Fallback: a 512-iteration
  qword load/store loop with `cmp rcx, 512; jne` discipline.
- **`block_hash` sentinel path (if §7.2 is ever revisited):** the
  SHA-256 intrinsic would need to be defined per the same
  `trait + plain-lambda-body` shape every other crypto intrinsic
  in `pdxb_crypto.pdx` follows (module header lines 51-61).

---

## §9 References

- `tools/user/libpdx-volume/src/pdxb_crypto.pdx` — stub bodies +
  the already-landed KEK/DEK primitives this contract extends.
- `tools/user/libpdx-volume/src/pdxb_superblock.pdx` lines 764-874
  — `wrapped_dek` / `kdf_salt` / `wrap_nonce` accessors.
- `tools/user/libpdx-volume/design/architecture.md` §8.2, §11.4 —
  the "raw-ptr not cap-slot" + "paired-block scheme" rationales
  this doc builds on.
- `src/kernel/core/cap/kind_kek.pdx` — KIND_KEK ordinal, mint
  gates, and MVP stub-sentinel discipline.
- `src/kernel/core/fs/pdxfs/cow_write.pdx`, `cow_gc.pdx`,
  `nvme_write.pdx`, `wal.pdx` — the CoW invariant this contract
  relies on for nonce uniqueness (§4.1, §4.3, §5.4).
- `design/filesystem/volume-fs-substrate.md` §502 — the
  encryption-at-rest commitment this contract delivers.
- `design/pdxfs/init-caps-seed-convention.md` (PFS-02) — the
  mount's init-caps shape that provisions the KEK + mount-table
  caps the DEK unwrap chain consumes.
- RFC 8439 (ChaCha20-Poly1305 AEAD) §4 — the 2^48-write
  birthday-bound this contract honours.
- RFC 9106 (Argon2) §4 — the recommended-profile parameters
  `pdxb_kek_derive` already uses (64 MiB, 3 iterations, 1 lane).
