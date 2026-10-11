# ML-DSA-65 Verify Intrinsic — Cross-Repo Contract for pdxfs Userspace

**Status:** Intrinsic already landed in paideia-as (closes
`paideia-os/paideia-as#1347`, shipped v0.28.1, current workspace at
v0.37.0). This document is the **adoption contract** between the
intrinsic and its userspace consumer `tools/user/libpdx-volume`.
Parent paideia-os ticket: `paideia-os/paideia-os#2571` (PFS-04).

**Wave:** PFS-W2 (pdxfs tools AISSUE wave).

**Doc-only landing.** No code changes in this landing — the real
`pdxb_verify_*` bodies in `libpdx-volume` and the test promotion of
`test_pdxb_sigverify.pdx` are tracked on separate adoption tickets
(see §6, §7).

---

## 1. Overview

Two complementary roles exist across the paideia-as ↔ paideia-os
boundary:

- **Producer:** `paideia-as` ships `MlDsa65::verify`, a stdlib trait
  method lowered by the elaborator to an extern-C thunk
  `mldsa65_verify_runtime_entry` in `paideia-pq-sign::ffi`. The thunk
  dispatches to the FIPS 204 round-3 verify primitive implemented in
  Rust (`crate::mldsa::MlDsa65Marker::verify`).

- **Consumer:** `tools/user/libpdx-volume` carries two fail-closed
  verify STUBS today (`pdxb_verify_superblock`,
  `pdxb_verify_inode_tail`) that are the mandated call sites for every
  pdxfs mount-time superblock gate and every pdxfs walker's per-inode
  integrity check.

The historical premise — "paideia-as has no verify intrinsic, only
sign" — was true as of libpdx-volume M3-002 (paideia-as v0.24.0) and
remained the libpdx-volume STATUS.md gap bullet through v1.1.5.
That premise is **no longer true as of paideia-as v0.28.1
(2026-09-02)**, which landed `MlDsa65::verify` end-to-end via
`paideia-as#1347`. The libpdx-volume stubs are now gated purely on an
adoption pass, not a cross-repo intrinsic landing.

### 1.1 Call direction

```
┌─────────────────────────────────────────────────────────────┐
│ libpdx-volume (ring 3, satellite userspace)                 │
│                                                             │
│   pdxb_verify_superblock  ──┐                               │
│   pdxb_verify_inode_tail  ──┼─► MlDsa65::verify (stdlib)    │
│                             │                               │
└─────────────────────────────┼───────────────────────────────┘
                              │  (elaborator lowers to call)
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ paideia-pq-sign::ffi (Rust extern "C")                      │
│                                                             │
│   mldsa65_verify_runtime_entry(                             │
│     msg_ptr, msg_len,                                       │
│     sig_ptr, sig_len,                                       │
│     pubkey_ptr, pubkey_len)  -> i64                         │
│                                                             │
└─────────────────────────────┬───────────────────────────────┘
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ MlDsa65Marker::verify (crate::mldsa, RustCrypto ml-dsa)     │
│   FIPS 204 §5.3 Verify algorithm                            │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Why the compact-ABI surface exists in parallel

`crates/paideia-as-stdlib/pdx/crypto/mldsa_65_c.pdx` publishes a
narrower `MlDsa65C::verify` whose return type is `u32` (not `i64`) and
whose link target is a satellite-build-friendly `mldsa65_verify`
thunk (no std linkage). The compact surface is for mkfs.pdxfs-shaped
no-std binaries. **libpdx-volume uses the std-linked `MlDsa65::verify`
form**, which carries the full `-1 / -2 / -3` return-code tri-split
documented in `mldsa.pdx` §Return codes — mandatory for the superblock
`repair vs eviction` diagnostic split (see §2.3 below).

---

## 2. ABI

### 2.1 Trait signature (consumer-facing)

```pdx
// crates/paideia-as-stdlib/pdx/mldsa.pdx (verbatim)

fn verify(
  msg_ptr:    u64,
  msg_len:    u64,
  sig_ptr:    u64,
  sig_len:    u64,
  pubkey_ptr: u64,
  pubkey_len: u64,
) -> i64 !{crypto, mem} @{paideia.crypto};
```

### 2.2 System-V register map

| Reg | Argument       | Type        | Constraint                     |
|-----|----------------|-------------|--------------------------------|
| RDI | `msg_ptr`      | `*const u8` | May be NULL only if `msg_len == 0` |
| RSI | `msg_len`      | `u64`       | Any value in `[0, 2^63)`       |
| RDX | `sig_ptr`      | `*const u8` | MUST be non-NULL, 3309 bytes   |
| RCX | `sig_len`      | `u64`       | MUST equal `MLDSA65_SIG_LEN = 3309` |
| R8  | `pubkey_ptr`   | `*const u8` | MUST be non-NULL, 1952 bytes   |
| R9  | `pubkey_len`   | `u64`       | MUST equal `MLDSA65_PK_LEN = 1952` |
| RAX | return code    | `i64`       | See §2.3                       |

Clobbers follow SysV: callee preserves RBX, R12–R15, RBP, RSP; all
other GPRs may be clobbered. XMM/YMM state is unspecified across the
boundary (the thunk is Rust and may use SSE2 freely).

### 2.3 Return-code contract

| Value | Mnemonic                           | Semantics                                                                 |
|-------|------------------------------------|---------------------------------------------------------------------------|
|  `0`  | `PDX_MLDSA_OK`                     | Signature authenticates under `(pubkey, msg)`.                            |
| `-1`  | `PDX_MLDSA_ERR_INVALID_PARAM`      | A required pointer was NULL (sig/pk), or `msg_ptr` NULL with `msg_len != 0`. |
| `-2`  | `PDX_MLDSA_ERR_LENGTH`             | `sig_len != 3309` or `pubkey_len != 1952`.                                |
| `-3`  | `PDX_MLDSA_ERR_AUTHENTICATION`     | Signature does not authenticate — a genuine verification failure.         |

**Diagnostic split rationale.** `libpdx-volume#16 pdxb_verify_superblock`
needs to distinguish a malformed on-disk header (recoverable through
the superblock-repair path) from a real tamper (which eagerly evicts
the volume). The `-2 / -3` split in the Rust thunk (`ffi.rs` lines
184–228) is deliberate: `MlDsa65Marker::verify` itself returns a plain
`bool`, so splitting lengths from authentication happens upstream of
the borrow — never constructing a slice under a spurious length.

### 2.4 FIPS 204 parameter floor

ML-DSA-65 is the strength-category-3 parameter set of FIPS 204
(Module-Lattice-Based Digital Signature Standard):

| Parameter        | Value   | Notes                                      |
|------------------|---------|--------------------------------------------|
| `q` (modulus)    | `8380417` | Prime, satisfies `q ≡ 1 (mod 512)`         |
| `n` (ring deg)   | `256`   | Fixed across all ML-DSA variants           |
| `(k, l)`         | `(6, 5)` | Matrix dimensions                          |
| `η` (noise)      | `4`     | Secret-polynomial bound                    |
| `γ_1`            | `2^19`  | Mask bound                                 |
| `γ_2`            | `(q-1)/32` | Low-bits bound                          |
| `τ`              | `49`    | Hamming-weight of challenge                |
| `β = τ·η`        | `196`   | Rejection bound                            |
| `ω`              | `55`    | Hint-polynomial Hamming bound              |
| `MLDSA65_PK_LEN` | `1952`  | Encoded public-key length                  |
| `MLDSA65_SK_LEN` | `32`    | Compact seed form (not full 4000-byte sk)  |
| `MLDSA65_SIG_LEN`| `3309`  | Encoded signature length                   |

The Rust implementation underneath (`RustCrypto/signatures ml-dsa
0.1.x`) is a FIPS 204 round-3 compliant primitive validated against
the NIST ACVP vector corpus — see §5.

---

## 3. Call-Site Inventory

Grep performed at libpdx-volume `HEAD = dd856c0` (v1.1.5):

```
$ grep -n "pub let pdxb_verify_" src/*.pdx
src/pdxb_checksum.pdx:261:  pub let pdxb_verify_checksum : (u64, u64) -> u64
src/pdxb_sign.pdx:509:  pub let pdxb_verify_inode_tail : (u64, u64, u64, u64, u64, u64) -> u64
src/pdxb_sign.pdx:550:  pub let pdxb_verify_superblock : (u64, u64, u64, u64) -> u64
```

Three `pdxb_verify_*` symbols; **two are ML-DSA verify sites**, the
third is CRC32C and is not in scope:

### 3.1 In-scope sites (ML-DSA-65 fail-closed stubs)

| Site                              | File                 | LOC   | Current body                                                                              | Current failure mode                                                                 |
|-----------------------------------|----------------------|-------|-------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------|
| `pdxb_verify_inode_tail`          | `src/pdxb_sign.pdx`  | 509   | Fail-closed STUB. Dereferences none of its six args; unconditionally returns `PDXB_VER_ERR_NOT_IMPLEMENTED = 0xFFFFFFFFFFFFFFFF`. | Mount-time + walker-time per-inode integrity check always returns NOT_IMPLEMENTED. Caller sees nonzero and aborts; no inode is ever read as "verified". |
| `pdxb_verify_superblock`          | `src/pdxb_sign.pdx`  | 550   | Fail-closed STUB. Dereferences none of its four args; unconditionally returns the same sentinel.                                 | Mount-time superblock-signature gate always returns NOT_IMPLEMENTED. mount.pdxfs cannot wire a sign-check gate until this is a real body. |

### 3.2 Out-of-scope site

| Site                     | File                      | Primitive | Why out-of-scope                             |
|--------------------------|---------------------------|-----------|----------------------------------------------|
| `pdxb_verify_checksum`   | `src/pdxb_checksum.pdx:261` | CRC32C   | Classical hash integrity, not ML-DSA. Already a real body (M1-002, landed). |

### 3.3 Test site

`tests/test_pdxb_sigverify.pdx` (M4-002, landed as a sentinel-only
driver): calls `pdxb_verify_inode_tail` against a `.bss`-stamped
"zero-signature-placeholder" fixture and asserts the fail-closed
sentinel comes back verbatim. Returns `0` if the stub's output
matches `PDXB_VER_ERR_NOT_IMPLEMENTED`, `1` otherwise — the `1` path
is intentional: it tells adoption pass that the stub discipline
changed and the driver needs a real round-trip body.

**Promotion target** (adoption ticket, not this doc):

1. Add a sign-then-verify-OK case: `MlDsa65::sign` the fixture,
   `pdxb_verify_superblock` it, assert `PDXB_VER_OK = 0`.
2. Add a tamper-signature case: flip one byte in the signature
   placeholder, assert `-3` (authentication failed).
3. Add a bad-length case: pass `sig_len = 3310`, assert `-2`.

---

## 4. Implementation Sketch (Reference — Already Landed Upstream)

**Scope note.** This section is **historical / reference**. The
implementation already landed in paideia-as#1347 (v0.28.1,
2026-09-02). It is reproduced here so a future libpdx-volume
maintainer debugging an unexpected return code can reach the right
file and function without a cross-repo scavenger hunt.

### 4.1 FIPS 204 §5.3 Verify algorithm (summary)

Given `(pk, msg, σ)`:

1. Decode `pk` into `(ρ, t₁)` via `pkDecode` (FIPS 204 §8.2).
2. Decode `σ` into `(c̃, z, h)` via `sigDecode` (FIPS 204 §8.3).
3. Reject if `||z||_∞ ≥ γ_1 − β` (early range check).
4. Expand the public matrix `Â := ExpandA(ρ)` using SHAKE-128.
5. Compute `μ := CRH(tr || msg)` where `tr := CRH(pk)`.
6. Recompute `w'_1 := UseHint(h, Az − c·2^d·t₁)` in NTT domain.
7. Recompute `c̃' := CRH(μ || w1Encode(w'_1))`.
8. Accept iff `c̃' == c̃` **and** `||h||₁ ≤ ω` **and** the length
   constraints held at step 3.

### 4.2 Primitives in paideia-as-crypto

The verify path reuses the primitives already standing for the
sign path (`paideia-as#1330`, v0.26 landing):

- **SHAKE-256** (via `sha3` crate, same instantiation as sign).
- **Modular arithmetic over `Z/qZ`** with `q = 8380417` — the shared
  `polynomial::Poly` type parameterised on `Modulus<8380417>`.
- **Number-Theoretic Transform** (NTT / inv-NTT) over `Z_q` with the
  primitive 256-th root `ζ = 1753`.
- **Matrix expansion** `ExpandA : {0,1}^256 → R_q^{k×l}` via
  rejection-sampled SHAKE-128.
- **Hint-polynomial encoding** `UseHint` and `w1Encode` (FIPS 204
  §4.1).

All reused verbatim from the already-landed sign direction — the
difference is that verify recomputes `w'_1` from the challenge `c`
and the hint `h`, while sign generates `(z, h)` under rejection
sampling.

### 4.3 Rust realisation

```rust
// crates/paideia-pq-sign/src/ffi.rs lines 184–228 (verbatim shape)

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mldsa65_verify_runtime_entry(
    msg_ptr:    *const u8,
    msg_len:    usize,
    sig_ptr:    *const u8,
    sig_len:    usize,
    pubkey_ptr: *const u8,
    pubkey_len: usize,
) -> i64 {
    // Guard 1: null-pointer discipline (returns -1).
    // Guard 2: length discipline (returns -2) — UPSTREAM of the slice
    //          build, so we never materialise a slice under a bad length.
    // Verify:  MlDsa65Marker::verify(&pk, msg, &sig) — returns bool.
    //          true  -> 0 (OK)
    //          false -> -3 (AUTHENTICATION)
}
```

The underlying `MlDsa65Marker::verify` is the thin wrapper over
`ml_dsa::MlDsa65::verify` from the RustCrypto `ml-dsa 0.1.x` crate.

### 4.4 Elaborator wiring

`crates/paideia-as-elaborator/src/stdlib_lowering/mldsaops.rs` holds
the `MlDsa65::verify` recipe. It emits a plain SysV `call
mldsa65_verify_runtime_entry;` with the six arguments already in the
correct registers (RDI, RSI, RDX, RCX, R8, R9) — no stack spill
needed, since the ABI arity is exactly 6.

Routing happens at `stdlib_lowering/mod.rs:263`:
```rust
"MlDsa65" => mldsaops::try_lower(method_name, mode, arg_ids, arena),
```

### 4.5 Consumer-side skeleton (for the adoption ticket)

The real body of `pdxb_verify_superblock` (as it will land under the
adoption ticket) is a straight parallel of the existing
`pdxb_sign_superblock` real body:

```pdx
pub let pdxb_verify_superblock : (u64, u64, u64, u64) -> u64 !{} @{} =
  // Args SysV: rdi=sb_ptr, rsi=sig_ptr, rdx=sig_len, rcx=pub_key_slot
  //
  // 1. Load pubkey from pub_key_slot (ambient capability, resolved
  //    via a separate paideia-as-side intrinsic — tracked on a
  //    different ticket; today the signer-side analogue already
  //    reaches a dev-key via the same convention).
  // 2. Compute message span: msg_ptr = sb_ptr, msg_len = 696
  //    (PDXB_D_OFF_SIG from pdxb_superblock.pdx).
  // 3. Marshal MlDsa65::verify args:
  //      rdi=msg_ptr, rsi=696, rdx=sig_ptr, rcx=3309,
  //      r8=pubkey_ptr, r9=1952
  // 4. call MlDsa65::verify;
  // 5. Translate i64 → u64 sentinel band:
  //      rc  0 -> PDXB_VER_OK           (0)
  //      rc -1 -> PDXB_VER_ERR_PARAM    (band 0x0601)
  //      rc -2 -> PDXB_VER_ERR_LENGTH   (band 0x0602)
  //      rc -3 -> PDXB_VER_ERR_BADSIG   (band 0x0603)
  //      else  -> PDXB_VER_ERR_UNKNOWN  (band 0x06FF)
```

**Encoder pitfalls** (per `feedback_pdx_encoder_pitfalls` memory):

- The `0xFFFFFFFFFFFFFFFF`-shaped sentinels exceed the 32-bit
  cmp-imm sign-extend bound: stage via a `mov r10, imm64` and use
  `cmp rax, r10`, never a direct `cmp rax, imm64`.
- `test rN,rN` is unsupported — use `cmp rax, 0` instead.
- Labels must not collide with reserved keywords (`loop`, `if`,
  `verify` itself) — prefix with the function name: `pdxb_vs_ok`,
  `pdxb_vs_param`, `pdxb_vs_len`, etc.
- The 2-op `imul r, imm` form is not supported — this body does not
  need it, but any sizing math must use 3-op `imul rN, rM, imm`.

---

## 5. Testing

### 5.1 NIST ACVP conformance

The underlying `ml-dsa 0.1.x` crate is validated against the NIST
ACVP (Automated Cryptographic Validation Protocol) vector set at
upstream CI. The paideia-as workspace additionally pins **sign-side**
ACVP vectors under `paideia-as#525` (closed, v0.33 bundle).

A **verify-side** ACVP conformance pass remains an open follow-up —
see §6.2. The pdxfs adoption pass is unblocked by the upstream
RustCrypto validation; a native-side verify-ACVP sweep is defense in
depth, not a gate.

### 5.2 Corpus sweep (libpdx-volume side)

`tests/test_pdxb_sigverify.pdx` (sentinel-only today) becomes a
three-case round-trip at adoption:

| Case                   | Setup                                                     | Expected rc                            |
|------------------------|-----------------------------------------------------------|----------------------------------------|
| OK                     | `MlDsa65::sign` fixture; verify against the matching pk    | `0` (`PDXB_VER_OK`)                    |
| Tamper-signature       | Flip one byte in the signature placeholder                 | `-3` → `PDXB_VER_ERR_BADSIG`           |
| Tamper-message         | Flip one byte in the superblock payload before verify       | `-3` → `PDXB_VER_ERR_BADSIG`           |
| Bad length (sig)       | Pass `sig_len = 3310`                                      | `-2` → `PDXB_VER_ERR_LENGTH`           |
| Bad length (pk)        | Pass `pubkey_len = 1953`                                   | `-2` → `PDXB_VER_ERR_LENGTH`           |
| NULL sig_ptr           | Pass `sig_ptr = 0`, legal `sig_len`                        | `-1` → `PDXB_VER_ERR_PARAM`            |

Each case lands as a distinct test function in
`tests/test_pdxb_sigverify.pdx` under the standard libpdx-audit
test-driver convention (one `.pdx` file, one `run` entry per case,
returning `0` on pass).

### 5.3 Fixture sources

Three fixtures are needed, all under `tests/qemu/keys/`:

- `pdxb-dev.mldsa65.sk` (32-byte seed) — already landed per
  `design/architecture.md` §8.3 (dev keypair under
  `tests/qemu/keys/`).
- `pdxb-dev.mldsa65.pub` (1952-byte public key) — already landed,
  same provenance; is the half the stub's `pub_key_slot` argument
  points at today but which currently resolves to nothing (§8.3 of
  the libpdx-volume architecture doc notes this).
- `tsv_fixture` — the existing `.bss`-stamped 4096-byte zeroed
  buffer, reused verbatim for the OK + tamper cases.

### 5.4 Property: sign-then-verify is total

Across the fixture + the dev key, every output of
`pdxb_sign_superblock` MUST verify under
`pdxb_verify_superblock(sb_bytes, sig, 3309, pub_key_slot)`. The
adoption pass asserts this as the OK case; a QEMU smoke follow-up
sweeps the property across a random payload corpus.

---

## 6. Cross-Repo Coordination

### 6.1 paideia-as side — DONE

The intrinsic is already shipped. Timeline:

| Event                                               | Tag        | Date       |
|-----------------------------------------------------|------------|------------|
| `MlDsa65::sign` trait + lowering                    | v0.26.0    | 2026-07-xx |
| `paideia-as#1347` — `MlDsa65::verify` lands         | **v0.28.1**| **2026-09-02** |
| Satellite-runtime shim for sign (NO_SIGNER sentinel) | v0.36.41  | 2026-09-xx |
| Current workspace                                   | **v0.37.0**| 2026-10-xx |

Any libpdx-volume adoption pass pins paideia-as `>= v0.28.1`. The
current `tools/paideia-as/` submodule is **well past** that floor at
v0.37.0.

**No new paideia-as implementation ticket is needed.** The dispatch
premise ("the paideia-as toolchain has no `MlDsa65::verify`") was
authored against the libpdx-volume v1.1.5 STATUS.md gap bullet, which
had gone stale against the already-landed intrinsic.

### 6.2 Legitimate paideia-as follow-up (optional, non-blocking)

One narrow, additive follow-up is worth filing on the paideia-as side
to harden the verify path against NIST drift:

> **[paideia-as] ML-DSA-65 verify: NIST ACVP conformance vectors
> (mirror of #525 for the verify direction).**
>
> `paideia-as#525` landed sign-side NIST ACVP vectors; the verify
> direction has only the upstream `ml-dsa` crate's own vectors + the
> libpdx-volume sign-then-verify round-trip under
> `tests/test_pdxb_sigverify.pdx`. A native-side verify-ACVP sweep
> under `tests/paideia-pq-sign/` would:
>
> - Confirm the FFI thunk's length-gate / null-gate boundary
>   behaviours (which the upstream crate's test vectors don't
>   exercise, since they bypass the extern-C surface).
> - Pin the `-1 / -2 / -3` return-code semantics across a RustCrypto
>   major bump.

This is defense-in-depth and does not gate the libpdx-volume
adoption. Filed as a sibling of this doc; see §Deliverable in the
dispatch summary.

### 6.3 paideia-os side — adoption

The libpdx-volume adoption pass is **not scoped to this doc** — it's
its own ticket, tracked as the natural continuation of
`paideia-os/paideia-os#2571`. The adoption-pass TODO:

1. Rewrite `pdxb_verify_superblock` (real body per §4.5 skeleton).
2. Rewrite `pdxb_verify_inode_tail` (same shape, different offsets).
3. Promote `tests/test_pdxb_sigverify.pdx` to the §5.2 corpus.
4. Bump libpdx-volume to v1.2.0 (MINOR — new verify behaviour, no
   ABI surface break).
5. Update libpdx-volume `STATUS.md`: remove the "mldsa65_verify
   intrinsic" deferred bullet, mark `pdxb_verify_*` as landed.
6. Submodule-bump under paideia-os; close `paideia-os#2571`.

### 6.4 Version-synchronisation discipline

Per `feedback_paideia_as_version_discipline`:

- No paideia-as `workspace.version` bump is owed by this doc (no
  code touched).
- No paideia-as `CHANGELOG.md` entry is owed.
- No `find-paideia-as.sh` strict-version-check change.

### 6.5 Design-doc cross-references

- Producer: `tools/paideia-as/crates/paideia-as-stdlib/pdx/mldsa.pdx`
  (trait declaration).
- Producer: `tools/paideia-as/crates/paideia-pq-sign/src/ffi.rs`
  lines 184–228 (FFI thunk).
- Producer: `tools/paideia-as/crates/paideia-as-elaborator/src/stdlib_lowering/mldsaops.rs`
  (recipe).
- Consumer: `tools/user/libpdx-volume/design/architecture.md` §8.4
  (stub rationale — will be retired at adoption).
- Consumer: `tools/user/libpdx-volume/src/pdxb_sign.pdx` lines 509
  (`pdxb_verify_inode_tail`), 550 (`pdxb_verify_superblock`).
- Kernel-side mount gate: `design/filesystem/volume-fs-substrate.md`
  §6.4 ("mount-time superblock-signature gate — enforceable once the
  verify intrinsic lands"). The intrinsic has landed; the gate's
  enforcement is now bottlenecked on §6.3 step 1.

---

## 7. Rollout

### 7.1 Posture today

- paideia-as: intrinsic shipped, stable, in production use upstream
  by every `.pdxpkg install-time` gate.
- libpdx-volume: both verify sites still fail-closed STUBS.
- Every pdxfs consumer that would call `pdxb_verify_superblock` /
  `pdxb_verify_inode_tail` either (a) does not yet exist (mount.pdxfs
  mount-time gate), or (b) treats a nonzero return as "signature
  check skipped" (not reachable in production builds).

### 7.2 Stays fail-closed until

The adoption ticket per §6.3 lands. **No partial / per-site rollout.**
Both `pdxb_verify_*` sites move in a single libpdx-volume MINOR bump
because:

1. Both share one body shape (§4.5); diverging them during the
   adoption pass creates two different translation tables for the
   `i64 → u64` sentinel map.
2. The test driver (`test_pdxb_sigverify.pdx`) covers both via one
   corpus (§5.2); splitting the adoption splits the test into two
   drivers.
3. The STATUS.md deferred bullet names both at once; a half-adoption
   leaves STATUS.md in an inconsistent state.

### 7.3 Semver impact

- libpdx-volume `v1.1.5 → v1.2.0`: **MINOR**. New verify behaviour.
  Public symbol list unchanged. The sentinel band
  (`PDXB_VER_ERR_*`, 0x0600..0x06FF) is already reserved per
  `src/lpv_errors.pdx` line 18; new sentinels added within it do not
  break the ABI.
- paideia-as: no version impact from this doc. Any §6.2 ACVP
  follow-up is a patch-tag addition.
- paideia-os: submodule bump after the libpdx-volume MINOR tag; no
  own version impact.

### 7.4 Reversibility

If the adoption pass surfaces an unexpected consumer-side issue
(e.g. the dev key's `pub_key_slot` resolution turns out to need its
own paideia-as side intrinsic — the sign-side analogue reaches a
dev-key via a different path, documented in `architecture.md` §8.3),
the fallback is a one-line revert of `pdxb_verify_superblock` /
`pdxb_verify_inode_tail` back to the fail-closed sentinel. The
sentinel is **documented as part of the public contract** at
`src/lpv_errors.pdx` line 18, so reverting is a semver-patch
(sentinel-emitting stub re-published), not a semver-major.

### 7.5 Decommissioning this doc

Once:

- The adoption ticket lands and libpdx-volume ships ≥ v1.2.0.
- `STATUS.md` is updated (§6.3 step 5).
- `test_pdxb_sigverify.pdx` is the §5.2 corpus.

…this doc stays in the tree as the **historical contract record** —
a future reader asking "why does `pdxb_verify_superblock` wrap
`MlDsa65::verify` through this specific `-1 / -2 / -3` sentinel
translation" lands here. Do not delete it after adoption; append a
"Status: Adopted at libpdx-volume v1.2.0" line to §Status.

---

## Appendix A — Why not the compact `MlDsa65C::verify` surface?

The compact ABI in
`tools/paideia-as/crates/paideia-as-stdlib/pdx/crypto/mldsa_65_c.pdx`
declares a parallel `verify(msg_ptr, msg_len, sig_ptr, sig_len,
pk_ptr) -> u32` surface with:

- `u32` return (not `i64`) — collapses the `-1 / -2 / -3` tri-split
  into a single `0 = OK / 1 = FAIL` binary.
- No `pubkey_len` argument — the length is implicit at `MLDSA65_PK_LEN`.
- Links to a no-std thunk `mldsa65_verify` (not
  `mldsa65_verify_runtime_entry`).

That surface is for mkfs.pdxfs-shaped satellite binaries that avoid
the std-linked `paideia-pq-sign` archive. **libpdx-volume is std-linked
by construction** (it links the full paideia-os userspace runtime at
mount.pdxfs time), so the fuller trait form is strictly better: the
diagnostic split (§2.3) is load-bearing for the superblock
`repair vs eviction` policy that mount.pdxfs's §6.4 gate will
enforce.

A future `KIND_CAP_ENV`-shaped mount gate running from the kernel
side (hypothetical — not currently designed) might prefer the compact
surface. If that happens, add a §Appendix B at that point.

---

## Appendix B — Encoder-pitfall checklist (paideia-as-side, for the adoption pass)

Reproduced from `feedback_pdx_encoder_pitfalls` so the adoption pass
has it one search away:

- `test rN, rN` — unsupported in the paideia-as encoder; use `cmp
  rax, 0; jne/je` instead.
- `and r11, imm64` — not supported; stage via `mov r10, imm64; and
  r11, r10`.
- 2-op `imul r, imm` — not supported; use 3-op `imul rN, rM, imm`.
- Multiline `pub let = "..."` — the string must be single-line; wrap
  via escape sequences, don't newline inside the literal.
- Module basename must match the `pub mod` name — a mismatch is a
  silent build-skip, not an error.
- Fingerprint tag size off-by-one — the tag runs over the module
  name's length, not the length-plus-NUL.
- Labels colliding with reserved keywords (`loop`, `if`, `verify`)
  fail to parse — prefix with the function name.

The adoption pass's `pdxb_verify_superblock` real body is small
(roughly 25 lines of asm); every one of these pitfalls is a
hit-the-first-time risk.
