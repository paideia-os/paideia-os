# PaideiaOS — Drivers: Blob-Driver Capability Policy

**Status:** Draft v0.2 (R29.M0-002, #1018).
**Date:** 2026-08-12.
**Scope:** Load-time trust model, IOMMU-domain granularity, and audit
access for every driver whose device requires a vendor-supplied
firmware blob. Supersedes the Phase-3 v0.1 consent-flow sketch (which
this document absorbs and generalizes).
**Authorities cited:**
- `design/roadmap/next-wave-synthesis.md` §10 D1 (dual-signature +
  per-driver-process IOMMU + full audit — user-resolved 2026-08-11).
- `design/drivers/framework.md` §12 (blob-driver hook; DR-D11).
- `design/security/pq-trust-root.md` §0.2 (PQ-Q3 algorithm selection,
  ML-DSA-65 for release-signed artifacts).
- `design/tooling/plan.md` D4 (the tool-package dual-sign analog).
- `design/loader/init-caps-sidecar.md` (loader seed-caps contract).
- `design/architecture/next-wave-derived-kinds.md` `KIND_HW_DMA_DOMAIN`.

---

## 0. Executive summary

Vendor firmware blobs are a permanent fact of the T14 G4 hardware
surface. Wi-Fi (Intel AX211 UMAC), camera (Intel IPU6 pipeline),
integrated GPU submission fast-path (Intel GuC + HuC), Bluetooth
(Intel BT HCI patch RAM), and audio DSP (Realtek SOF topology) each
require a signed opaque binary produced outside the Paideia project.
PaideiaOS cannot audit that code; it can only bound its damage. This
policy fixes the three narrow architectural questions the R29 driver
substrate must answer before any blob-consuming driver boots: (a) who
must sign the blob, (b) how much of the DMA fabric it can address,
and (c) whether it can talk to the audit spine.

The three answers, resolved by the user on 2026-08-11 and now
load-bearing for R38 (Wi-Fi), R39 (BT), R40 (camera + WWAN), R37 (GuC
firmware on the GPU submission path), and R33 (SOF audio topology),
are: **dual signature** (every blob carries both a vendor signature
AND a Paideia manifest re-sign under `paideia_root_pk` from R32);
**per-driver-process IOMMU domain** (one `KIND_HW_DMA_DOMAIN` per
driver process, shared across every device that driver claims); and
**full audit access** (blob-holding drivers get the same read + write
audit capability that native drivers hold). Each is a
blast-radius-versus-operational-simplicity trade decided in favor of
the simpler shape, with acknowledged consequences documented below.

This document is a policy specification, not an implementation. It
freezes the vocabulary the R29 driver framework, the R32 PQ trust
root, and the R38/R39/R40 blob-consumers all reference. The concrete
implementation is enumerated across R29.M4 (signature verifier
#1032, pinned keyring reader #1033, dual-signature enforcement
#1034, signing-failure telemetry #1035), R29.M5 (KIND_DMA_DOMAIN
introduction #1036–#1038, kernel IOMMU switching #1039), and R29.M6
(blob-driver audit parity #1043). The vendor-key material lands in
`assets/keys/` at R32 open. The per-consumer wiring lands in each
consumer round's `blob_bundle.pdx` follow-up. Anything named here as
"future work" is unblocked but not in-scope for R29.M0.

---

## 1. D1.a — Signing trust model: DUAL SIGNATURE

### 1.1 The two-key requirement

Every blob under `assets/firmware/<vendor>/<device>.fw` must arrive
alongside a `.pdxsig` manifest that carries **two** signatures, both
verified before the loader hands the blob to the driver process:

1. **Vendor signature.** The blob's original signature, produced by
   the vendor (Intel, Realtek) under the vendor's private key,
   verified against a pinned vendor pubkey that PaideiaOS ships in
   `assets/keys/`.
2. **Paideia manifest re-sign.** A separate ML-DSA-65 signature over
   `(sha3_256(blob), signer_pk, timestamp)`, produced during Paideia
   release engineering under `paideia_root_pk` (the R32 root key), and
   verified against the same anchored root the boot chain uses.

A blob missing either signature is refused at load. A blob that
verifies against only the vendor signature is refused. A blob that
verifies against only the Paideia manifest is refused. There is no
"emergency" or "development" flag that bypasses either check in the
default build; the development override (if any) lives behind a
`relax-mitigations`-shaped capability that is itself audited, per the
pattern in `design/security/pq-trust-root.md`.

### 1.2 Vendor key pinning

Vendor keys live under `assets/keys/` with the following layout:

```
assets/keys/
  paideia-root-dev.pub                     (exists; ML-DSA-65 dev root)
  intel-firmware-ax211-2026.pk             (R32.M?)
  intel-firmware-ipu6-2026.pk              (R32.M?)
  intel-firmware-guc-adl-2026.pk           (R32.M?)
  intel-firmware-huc-adl-2026.pk           (R32.M?)
  intel-firmware-bt-hci-2026.pk            (R32.M?)
  realtek-firmware-sof-alc287-2026.pk      (R32.M?)
```

The `<year>` suffix is deliberate: vendor keys rotate, and PaideiaOS
pins the specific key each blob was signed under. The signature-
verification path looks up the pinned key by `(vendor, device_family,
year_or_epoch)` rather than by a generic "vendor pubkey" — this
prevents a vendor key compromise from silently covering every past
release.

Vendor-key rotation is the vendor's operational concern; Paideia
tracks new vendor keys in the algorithm catalog
(`design/security/algorithm-catalog.md`) alongside the algorithm
identifier and valid-since/valid-until window. Rolling a vendor key
requires a Paideia release (the pinned key file changes on disk); it
is not a live-patchable configuration.

### 1.3 Paideia manifest format (`.pdxsig`)

```
struct BlobManifest {
  magic         : u32  = 0x50445853,  // 'PDXS' ASCII, little-endian
  version       : u16  = 1,
  algorithm_id  : u16,                // ML-DSA-65 = 0x0001
  blob_hash     : [u8; 32],           // sha3_256(blob)
  blob_len      : u64,
  signer_pk_id  : [u8; 16],           // key identifier (paideia_root_pk fingerprint)
  timestamp     : u64,                // seconds since epoch (release-signed)
  vendor_sig_alg: u16,                // for vendor sig (e.g. ECDSA-P384 = 0x0100)
  vendor_pk_id  : [u8; 16],           // pinned vendor key fingerprint
  vendor_sig    : [u8; VSIG_LEN],     // VSIG_LEN per vendor_sig_alg
  paideia_sig   : [u8; 3309],         // ML-DSA-65 signature over prior bytes
}
```

Manifest is little-endian, packed, self-describing. The `vendor_sig`
length is variable per `vendor_sig_alg`, so the parser reads
`vendor_sig_alg` first and consults the algorithm catalog for the
signature length. `paideia_sig` covers all preceding bytes including
`vendor_sig`.

### 1.4 The `blob_load(fw_path)` verification pipeline

```
blob_load(fw_path) -> Cap<KIND_MEMORY, .blob>  or  BlobRejected
{
  1. Open fw_path; read blob bytes into a supervisor-owned page.
  2. Open fw_path.pdxsig; parse BlobManifest per §1.3.
  3. Reject if magic != 'PDXS' or version != 1.
  4. Compute h = sha3_256(blob); reject if h != manifest.blob_hash.
  5. Look up pinned Paideia key by manifest.signer_pk_id;
     reject if not found or key valid-window expired.
     Verify paideia_sig with ML-DSA-65 over the manifest prefix
     (all bytes up to but excluding paideia_sig itself).
     Reject on verify-fail.
  6. Look up pinned vendor key by (vendor_from_fw_path, manifest.vendor_pk_id);
     reject if not found or key valid-window expired.
     Verify vendor_sig per manifest.vendor_sig_alg over blob bytes.
     Reject on verify-fail.
  7. Emit blob_load_ok audit event with { fw_path, blob_hash,
        signer_pk_id, vendor_pk_id, timestamp }.
  8. Mint Cap<KIND_MEMORY, .blob> handing the (page, blob_len)
     to the caller; the memory is R-X only, not writable.
}
```

The order is deliberate: Paideia signature is verified *before* the
vendor signature, so a bad `.pdxsig` (the more likely failure mode
during Paideia release ops) is caught without consulting a vendor
signature that might be structurally hard to fail-fast on.

### 1.5 Failure-mode taxonomy

| Failure | Audit event | User-visible surface |
|---|---|---|
| Missing `.pdxsig` file | `blob_load_no_manifest` | Driver refuses to start; supervisor logs "no manifest for `<fw_path>`". |
| Manifest magic/version bad | `blob_load_bad_manifest` | Same. |
| `blob_hash` mismatch | `blob_load_hash_mismatch` | Same; indicates blob was tampered or manifest is stale. |
| Paideia sig verify-fail | `blob_load_paideia_sig_fail` | Same; indicates the Paideia key roll was missed OR the blob is untrusted. Elevated severity. |
| Vendor sig verify-fail | `blob_load_vendor_sig_fail` | Same; the vendor never signed this bit pattern. Highest severity — attempted supply-chain substitution. |
| Both sigs fail | `blob_load_both_sig_fail` | Same; catastrophic — highest severity, alert emitted. |

There is no fallback path. A blob-consuming driver whose blob fails
verification does not start; the driver's device is left in its
firmware-less state (Wi-Fi radio unresponsive, camera unusable, GPU
falls back to KMD-managed submission for GuC-optional workloads).
`safectl` surfaces the affected device with the specific audit event
code so the operator can act.

### 1.6 Acknowledged trade-off

Emergency vendor security updates cannot ship to end users until
Paideia release engineering re-signs the new blob under
`paideia_root_pk`. In the worst case (Intel ships an out-of-band
Wi-Fi CVE patch), the window between vendor publication and
Paideia-signed availability is bounded by release engineering
turn-around (target: 48 h for a security-marked blob update; see
future work §7.2). This is the price of the dual-signature guarantee
and is accepted as a matter of principle: the Paideia project vouches
for every bit that runs under its trust root.

### 1.7 Verdict taxonomy and the all-zero-signature scaffold epoch

*(R29.M4-001, #1032. Implemented in
`src/kernel/core/driver/sig_verify.pdx`.)*

Sections 1.1–1.5 describe the policy as it will stand once R32 has
provisioned `paideia_root_pk` and landed the ML-DSA-65 primitive. Until
then the tree is in what this document names the **scaffold epoch**: no
signing key exists, so every signature field the build produces is
bytewise zero — the `.pdxsig` section from `tools/sign-efi.sh`, the
PdxFS-lite superblock signature, the registry-v2 signature field. R25.M5
and R28.M1 both call this the "dev bypass"; the name understates it, and
the understatement is the risk.

The danger is precise. When every signature in the tree is all zeros,
the path of least resistance is to let all-zero mean "acceptable" so the
boot log stays quiet. Do that and the scaffold becomes permanent: on the
day R32 lands, an unsigned artifact still verifies, and nothing in the
log ever changed to say so. The verifier therefore treats an all-zero
signature as its own verdict — **structurally well formed, provably NOT
signed** — numerically distinct from success.

`driver_sig_verify(artifact_ptr, artifact_len, sig_ptr, sig_len, pk_ptr)`
and its explicit-algorithm form
`driver_sig_verify_algo(algo_id, …)` return exactly one of:

| Verdict | Value | Meaning | Reachable at R29? |
|---|---|---|---|
| `SIG_OK` | `0` | Real ML-DSA-65 verification succeeded. | **No.** Reserved for R32. No path in `sig_verify.pdx` returns it. |
| `SIG_UNSIGNED_SCAFFOLD` | `1` | Well-formed artifact, well-formed pk, bytewise-zero signature. **Not a pass.** | Yes — the normal R29 outcome. |
| `SIG_BAD_ALGO` | `0xFFFFFD80` | `algo_id` is not ML-DSA-65. | Yes |
| `SIG_BAD_ARTIFACT` | `0xFFFFFD81` | `artifact_ptr` is null. | Yes |
| `SIG_BAD_ARTIFACT_LEN` | `0xFFFFFD82` | `artifact_len` is zero. | Yes |
| `SIG_BAD_SIG_PTR` | `0xFFFFFD83` | `sig_ptr` is null. | Yes |
| `SIG_BAD_LENGTH` | `0xFFFFFD84` | `sig_len != 3309` (FIPS 204 §5.4). | Yes |
| `SIG_BAD_PK_PTR` | `0xFFFFFD85` | `pk_ptr` is null. | Yes |
| `SIG_BAD_PK_ALIGN` | `0xFFFFFD86` | `pk_ptr` is not 64-byte aligned, so it did not come from the keyring (§1.8). | Yes |
| `SIG_UNVERIFIABLE` | `0xFFFFFD87` | Real signature material present; no crypto substrate to judge it. **Not a pass.** R32 dependency. | Yes |

Two invariants make the R32 transition a safe one-line flip rather than
an audit of every call site:

1. **`SIG_OK` is unreachable at R29.** It appears in `sig_verify.pdx`
   only as a constant and inside `driver_sig_verdict_is_ok`. R32 wires
   it to the lattice verifier and nothing else ever returns it.
2. **`driver_sig_verdict_is_ok(v)` is the only sanctioned accept test.**
   It answers 1 for `SIG_OK` and 0 for everything else, including
   `SIG_UNSIGNED_SCAFFOLD`. Consumers route their accept/reject decision
   through it rather than open-coding a comparison, because the natural
   open-coded shorthand for "OK or the scaffold case" (`cmp rax, 1;
   jbe`) would silently accept unsigned artifacts.

**R29 consumer discipline: log and continue.** A `SIG_UNSIGNED_SCAFFOLD`
verdict loads the artifact and records that it loaded unsigned.
`driver_sig_scaffold_epoch()` reports whether the scaffold is still live
(1 at R29), giving consumers one symbol to gate that behaviour on.

**R32 flips it to reject.** In the commit that lands
`src/kernel/core/crypto/ml_dsa/verify.pdx` and provisions real keys:
`_sig_scaffold_epoch` becomes 0, the `SIG_UNVERIFIABLE` arm becomes a
call into the lattice verifier (which may then return `SIG_OK`), and the
`SIG_UNSIGNED_SCAFFOLD` arm is retired. Consumers change from logging to
refusing per §1.5. No verdict value is renumbered.

The `SIG_BAD_*` gates run in the order algorithm, artifact pointer,
artifact length, signature pointer, signature length, pk pointer, pk
alignment — chosen so that no gate dereferences a pointer an earlier
gate has not validated, and so a short signature buffer yields
`SIG_BAD_LENGTH` rather than an over-read.

No lattice arithmetic lives in `sig_verify.pdx`. A subtly wrong
hand-rolled ML-DSA-65 verifier that returns `SIG_OK` is strictly more
dangerous than no verifier at all, because every consumer downstream
would then be trusting a number nobody checked.

### 1.8 Keyring layout, roles, and embedding

*(R29.M4-002, #1033. Implemented in
`src/kernel/core/driver/keyring.pdx`.)*

**On-disk layout.** One file per key under `assets/keys/`, each exactly
1952 bytes (ML-DSA-65 `pk_bytes`, FIPS 204 §5.4). At R29 the three
pinned dev keys are:

```
assets/keys/
  paideia-root-dev.pub        role paideia_root    (from R28.M1, #1001)
  intel-firmware-dev.pub      role vendor_intel
  realtek-firmware-dev.pub    role vendor_realtek
```

All three are 1952 zero bytes at this epoch — see §1.7. The production
layout in §1.2, with its year-suffixed per-device-family keys, is the
R32 shape; it becomes a second index level under the same role ids
rather than a change to the reader's interface.

**Roles, not filenames.** Lookup is by role, because a role is the
question a caller actually has ("who is supposed to have signed this
Intel firmware blob?") and it is stable across the key rotations the
filename encodes.

| Role | Id | Algorithm | pk length |
|---|---|---|---|
| `paideia_root` | 0 | ML-DSA-65 (`algorithm_id = 1`) | 1952 |
| `vendor_intel` | 1 | ML-DSA-65 | 1952 |
| `vendor_realtek` | 2 | ML-DSA-65 | 1952 |

**Embedded at build time, not read from a filesystem.** The keys are
`@include_bytes`'d into `.rodata`, exactly as
`src/kernel/boot/verify_self.pdx` embeds the root key for the EFI
self-check. This is not a convenience. The PdxFS-lite superblock is
itself signature-checked, so reading trust anchors off a mounted volume
would make the anchors depend on a verification that depends on the
anchors. The only honest resolution is that the root of trust must exist
before any storage does and must be covered by whatever signature covers
the kernel image. The keys are consequently available at the first
instruction of `kernel_main` — before ACPI, PCI, NVMe, or mount — with
no init step, no allocation, and no failure mode between boot and first
lookup. The cost is that rotating a key requires a kernel rebuild, which
§1.2 already states as policy.

Each blob is `@align(64)`: the R32 lattice verifier burst-loads key
words in aligned 64-byte chunks, and the alignment doubles as the
provenance proxy that `SIG_BAD_PK_ALIGN` checks. The `[u8; 1952]` type
is the build-time length check — `@include_bytes` on a file of any other
size fails the build, so the 1952-byte invariant is established before
the kernel exists.

**Reader interface.**

| Entry point | Contract |
|---|---|
| `keyring_lookup(role_id)` | Public-key VA on a hit, else `KEYRING_ERR_NO_SUCH_KEY` (`0xFFFFFD60`). Checked: validates role range, `algorithm_id == 1`, declared `pk_len == 1952`, and a non-null resolved address. |
| `keyring_pk_ptr(role_id)` | Raw role→address resolver; 0 for an unknown role. Exists so `keyring_fsck` can obtain an address without going through the validation it is testing. |
| `keyring_meta_field(role, field)` | Bounds-checked read of `{role_id, algorithm_id, pk_len, reserved}`. Both bounds precede the address arithmetic — the 96-byte table abuts 5856 bytes of key material. |
| `keyring_fingerprint(role_id)` | FNV-1a-64 over the role's 1952 bytes, for logs and witnesses. **Non-cryptographic**; never an input to a trust decision. SHA3-256 replaces it at R32. |
| `keyring_keys_distinct()` | 1 if all three roles carry different material. **0 at R29** — the three dev keys are the same zeros. Reported, not enforced; R32 must flip it. |
| `keyring_fsck()` | `KEYRING_OK`, or the first failure's code with the offending role in `keyring_fsck_bad_role()`. |

`keyring_lookup` collapses four distinct failure conditions into one
error code deliberately: from the caller's position they are the same
fact — there is no usable ML-DSA-65 key for this role — and a caller
able to distinguish "role unknown" from "role declares the wrong
algorithm" would be tempted to reach past the keyring for the bytes
anyway. The distinctions live in `keyring_fsck`, where they drive a
repair rather than a fallback.

**fsck properties**, checked for each of the three entries, fail-fast:

| Property | Failure code |
|---|---|
| `meta[i].role_id == i` (table is index-addressed everywhere else) | `KEYRING_ERR_BAD_ROLE_ID` `0xFFFFFD61` |
| `meta[i].algorithm_id == 1` (ML-DSA-65) | `KEYRING_ERR_BAD_ALGO` `0xFFFFFD62` |
| `meta[i].pk_len == 1952` | `KEYRING_ERR_BAD_PK_LEN` `0xFFFFFD63` |
| `keyring_pk_ptr(i) != 0` | `KEYRING_ERR_NULL_PK` `0xFFFFFD64` |

The `pk_len` check is the one #1033 names. It is not redundant with the
embedded blob: the blob's true size is fixed at 1952 by its type, while
`pk_len` is the number this module *believes*. fsck proves the two agree
— the pair that would otherwise drift apart the first time someone
edited one of them.

Public-key *addresses* are deliberately absent from the metadata table.
A static initializer holding the address of another static needs a
relocation in otherwise position-independent `.rodata` and would force
an init pass — the exact pre-first-use dependency the embedding decision
was made to avoid. `keyring_pk_ptr` resolves role→address with a
rip-relative `lea` per role instead.

Error-code blocks are disjoint by design so a failure is never
misclassified where it surfaces: `0xFFFFFD0x` registry schema,
`0xFFFFFD2x` registry I/O, `0xFFFFFD4x` registry query, `0xFFFFFD6x`
keyring, `0xFFFFFD8x` signature verdict.

**Boot witness.** `sig_keyring_witness` in
`src/kernel/boot/kernel_main.pdx` runs 29 gates over both modules and
emits `R29 SIG KEYRING OK`. Stage 16 is the one that matters:
`driver_sig_verdict_is_ok(SIG_UNSIGNED_SCAFFOLD) == 0`.

---

## 2. D1.b — IOMMU domain granularity: PER-DRIVER-PROCESS

### 2.1 The rule

Every driver process holds exactly one `KIND_HW_DMA_DOMAIN`
capability, minted at driver-process spawn by the supervisor. Every
device that driver claims (via the framework's device-arrival
handshake, `design/drivers/framework.md` §5) is mapped into that
single domain. Devices held by different driver processes live in
different domains; devices held by the same driver share a domain.

For blob-consuming drivers this means: the Intel CNVi PHY driver
(`cnvi_driver`) holds *one* domain, and both the Wi-Fi and Bluetooth
sub-devices — which share the CNVi transport per Intel's on-die
topology (see `design/roadmap/next-wave-synthesis.md` §2, R39 depends
on R38) — map into it. The IPU6 driver (`ipu6_driver`) holds a
separate domain covering the IPU MMU and every attached CSI-2 sensor
lane. The GuC/HuC firmware ring is inside the `i915_driver`'s domain,
not a separate one — the GuC executes on the GPU and cannot address
memory outside the GPU's IOMMU context regardless.

### 2.2 Rationale (versus per-device and per-firmware-image)

- **Versus per-device:** Per-device would require one
  `KIND_HW_DMA_DOMAIN` per BDF the driver holds, which for CNVi means
  the driver juggles a domain per {Wi-Fi PHY, BT HCI, WWAN companion
  when installed}. The domain-switching cost on the hot IPC-to-DMA
  path is measurable (an IOTLB flush at minimum, per
  `design/roadmap/next-wave-osarch.md` §R41 discussion). Blob drivers
  are already the most performance-sensitive class in the system
  (Wi-Fi RX ring can hit 10⁶ pkts/s at high MCS); imposing a domain
  switch per device would push us into per-op flush pathologies.
- **Versus per-firmware-image:** Per-firmware-image would demand a
  new domain each time the driver reloads its firmware (e.g., iwlwifi
  reloading UMAC on regulatory change or after a resume). Domain
  churn on the resume path is the wrong shape for a design that must
  reach S0i3 idle within tight ACPI budgets (R31.M4). Also the
  firmware-image identity is opaque to the IOMMU; there is nothing
  the hardware can enforce.
- **Chose per-process for two reasons:** simplicity (one domain per
  restart-unit maps onto the supervisor's failure-domain model at
  `design/drivers/framework.md` §11), and the blast-radius trade is
  bounded (see below).

### 2.3 Blast-radius acknowledgment

A compromised Intel AX211 UMAC blob can, in principle, issue DMA
reads and writes into any page mapped into the CNVi driver's shared
domain. That includes the Bluetooth HCI command/event rings if BT is
active in the same process. The observable consequences are:

- UMAC can read BT pairing state (LTK/IRK material lives in
  `KIND_BT_PAIRING` sealed caps that are only decrypted at HCI-side
  point-of-use; a UMAC DMA read of the ring buffer sees only
  ciphertext OR HCI-framed commands, not raw key material, because
  the sealer is a userspace boundary the UMAC cannot cross).
- UMAC can inject synthetic HCI events into the BT ring. The BT
  supervisor validates every event's structure and every state
  transition; injection is bounded to what an authenticated HCI
  command shape allows. It cannot pivot to code execution in the BT
  process.
- UMAC cannot address memory in any *other* driver process (per-
  process domain isolation still holds); cannot address kernel
  memory (kernel is in its own IOMMU domain); cannot address
  supervisor memory.

This is a real blast-radius that per-device isolation would prevent.
The decision is that the operational simplicity is worth the cost;
the sealed-cap discipline for keys and the schema-validated ring
consumer contain the exploit in every realistic case.

### 2.4 Implementation shape

The driver-lifecycle supervisor (`design/drivers/framework.md`
§4) mints `KIND_HW_DMA_DOMAIN` at driver-process spawn, before the
first `device_arrived` message (per R29.M5-003 #1038). The domain
cap is delivered via the loader's `_init_caps` sidecar
(`design/loader/init-caps-sidecar.md`) — one slot per driver process,
minted with `RIGHT_MINT | RIGHT_REVOKE | RIGHT_OBSERVE`. As each
device arrives, the driver passes the domain cap plus the device's
BDF to the supervisor's `dma_domain_attach(domain, bdf)` operation
(per R29.M5-004 #1039), which programs the VT-d context entries
under kernel supervision. `OP_MAP` on the domain publishes a page to
hardware; `OP_UNMAP` reclaims it. On driver-process exit the domain
cap is revoked, which tears down every context entry and IOTLB entry
attributed to it — the pattern documented in
`design/architecture/next-wave-derived-kinds.md`
`KIND_HW_DMA_DOMAIN` §"Ops".

---

## 3. D1.c — Audit access: FULL

### 3.1 The rule

Blob-consuming driver processes receive the same audit-channel
capability that native drivers hold: `KIND_AUDIT_CHANNEL` with
`RIGHT_WRITE`, minted at driver-process spawn, delivered via the same
`_init_caps` sidecar. Blob drivers emit lifecycle events, error
events, and per-op audit records into the same audit spine every
other driver uses (per R29.M6-004 #1043). There is no separate
"blob-watcher" audit sidecar-process, no external log-shim, no
read-only audit view.

### 3.2 What this changes versus the Phase-3 v0.1 sketch

The v0.1 draft of this document (and `design/drivers/framework.md`
§12.1) proposed *denying* audit-write to blob drivers under the
theory that untrusted code should not be able to write into the audit
log. The R29 synthesis reverses that decision. The new position:

- The audit spine already assumes non-privileged writers; it is
  designed to *log* driver behavior, including malicious behavior.
  Blob-driver audit records are attributed to the blob driver's
  process identity exactly as any other; a compromised blob writing
  self-serving records to the log is a *feature* (the operator can
  see the record and correlate it with real symptoms), not a
  vulnerability.
- The alternative (external blob-watcher intercepting IPC to
  synthesize audit) requires a second privileged process, another
  IPC hop on every driver op, and a lossy filter for what to log
  (the blob-watcher has to infer intent from wire traffic). This is
  operational complexity without proportionate blast-radius
  reduction — the same information reaches the audit log via
  direct-write.
- Linux firmware-loading drivers (iwlwifi, i915, ipu6-drivers) all
  write to the kernel log on the same footing as any other driver;
  operators expect this shape. Diverging without a concrete
  blast-radius win is speculative complexity.

### 3.3 Rationale

Operational simplicity dominates: the same audit vocabulary, the same
retention policy, the same offline analysis tooling apply to blob and
native drivers uniformly. The one layer of blast-radius reduction
this decision forgoes — a compromised blob cannot flood the audit log
because it cannot write to it — is instead addressed by the audit
spine's per-writer rate limiter (`design/audit/`; landed in R14) and
by the supervisor's chaos-restart policy, which kills a driver whose
audit rate exceeds a per-round threshold.

### 3.4 Reconciliation with `framework.md` §12.1

`design/drivers/framework.md` §12.1 DR-D11 says "no `audit-channel
cap` (the blob is untrusted; the supervisor's blob-watcher logs
externally)". That sentence is superseded by this document per the
R29 synthesis. `framework.md` should be updated at R29.M6 (Audit
surface) with a note pointing here; that update is out of scope for
this R29.M0-002 issue.

---

## 4. Interaction with the R29 driver framework

### 4.1 Where `blob_load` fires

`blob_load(fw_path)` is invoked by the driver process itself, not by
the loader, on the driver's *first-use* code path — typically inside
the device-arrival handler for the first device that requires the
blob. This is deliberate:

- The blob's identity depends on the device's model/stepping (iwlwifi
  picks its UMAC per PHY variant; IPU6 picks its pipeline per sensor
  present). Only the driver knows what to load.
- Firmware loading is I/O-bound (multi-MB reads from `pdxfs`); doing
  it lazily keeps driver-process spawn fast and keeps the supervisor
  off the critical path.
- Failure is a driver-side condition, not a framework-side condition;
  a failed `blob_load` leaves the driver in the same state as any
  first-use device-initialization failure and is handled by the
  standard lifecycle FSM (`design/drivers/framework.md` §4).

The `blob_load` primitive itself lives in a shared library
(`src/userspace/drivers/framework/blob_load.pdx`, landed with R29.M4
signature-verifier work — #1032 verifier core, #1033 keyring, #1034
dual-sig gate, #1035 telemetry) so every blob driver invokes the
same verified code path.

### 4.2 Interaction with `loader_seed_caps`

The loader plumbs two blob-specific `_init_caps` sidecar entries into
every blob-consuming driver at spawn:

1. `KIND_HW_DMA_DOMAIN` — the per-driver-process domain (§2.4).
2. `KIND_HW` reservation — the base slot 14 handle the driver refines
   into `KIND_HW_INTERRUPT` / `KIND_HW_MSIX_VECTOR` handles when it
   claims its devices' IRQ vectors.

No blob-specific *capability kind* exists. There is no `blob_driver_cap`
in the kind enum (the DR-D11 name is retained as a documentation
handle only; it is not a distinct `KIND_*`). What makes a driver
"blob" is that its startup path calls `blob_load(...)` before opening
any device MMIO; the framework does not distinguish it from any other
driver in its capability shape.

### 4.3 Loader-side sidecar shape (illustrative)

Every blob-driver process has the same first four `_init_caps`
slots: `KIND_HW_DMA_DOMAIN` (§2.4), `KIND_AUDIT_CHANNEL` write
(§3.1), a base `KIND_HW` handle for IRQ refinement, and
`KIND_PDXFS_READ` for `blob_load` to open the firmware path.
Additional slots vary per driver (MMIO caps, DMA-consent tokens,
IPC endpoints to the class driver, sealed-key caps for BT/Wi-Fi).

---

## 5. Consumers

| Round | Driver | Blob(s) | Domain shared with |
|---|---|---|---|
| **R38** | `cnvi_driver` (Wi-Fi + BT PHY) | Intel AX211 UMAC | R39 BT (same process) |
| **R38** | (companion) | Intel AX211 iwlwifi MVM | R38 Wi-Fi |
| **R39** | `bt_hci_driver` | Intel BT HCI patch RAM | R38 (shared CNVi PHY) |
| **R40** | `ipu6_driver` | Intel IPU6 pipeline firmware | R40 camera sensors |
| **R37** | `i915_driver` (GPU exec) | Intel GuC + HuC firmware | R37 GPU submission ring |
| **R33** | `sof_audio_driver` | Realtek SOF ALC287 topology | (SOF is the only blob in the audio path; standalone process) |

Each row is a driver-process granule for §2.1: each driver process
gets exactly one `KIND_HW_DMA_DOMAIN`. R38 + R39 share a process
(the CNVi transport is shared silicon); R37 GuC firmware executes on
the GPU inside the `i915_driver`'s existing domain and does not mint a
new one.

WWAN (R40) is expected to be a UVC-class USB device without firmware
loading in the initial R40 scope; if a WWAN blob is later required
(Fibocom/Qualcomm MBIM), it is a new driver process with its own
domain — it does not join the CNVi process.

---

## 6. What's out of scope

- No implementation code. The `blob_load` primitive lands at R29.M4;
  vendor-key material lands at R32 open; per-consumer wiring is per-
  round.
- No policy for *user*-installed blobs (e.g., an out-of-tree NVIDIA
  driver a user opts into). The Phase-3 v0.1 user-consent flow
  handles that class; this R29 policy governs vendor blobs that ship
  with PaideiaOS itself.
- No unsigned-blob development override. If one is required (e.g.,
  for reverse-engineering work) it will be a `relax-mitigations`-
  shaped audited capability defined in R29.M4.
- No policy for TPM-sealed blob decryption. If a future vendor
  requires DRM-shaped firmware handling, the KEM discipline from
  `design/security/pq-trust-root.md` §PQ-Q6 applies unchanged.

---

## 7. Future work

### 7.1 R32 landing: real `paideia_root_pk` provisioning

The R32 milestone (per next-wave-synthesis §6, paideia-as v0.27
bundle) lands the operational key material. Until then, `blob_load`
verifies against the development root (`assets/keys/paideia-root-
dev.pub`). Every blob currently in-tree is dev-signed; production
release engineering re-signs against the real root at R32 close.

### 7.2 Emergency vendor security-update re-sign workflow

Documented cadence: a vendor-published firmware security update
triggers a Paideia release-engineering action within 48 h to re-sign
and publish through the standard release channel. If the vendor's
key changed with the update, `assets/keys/` gets a new pinned entry
in the same release. Longer-term the workflow is folded into
`design/tooling/plan.md` D4's package pipeline. Tracking: file at
R32 open.

### 7.3 Key rotation ceremony

`paideia_root_pk` rotation is governed by
`design/security/pq-trust-root.md` §PQ-Q9 (5-year cadence for root,
event-driven on compromise). Blob-manifest re-signing across a root
rotation is a one-shot batch job producing new `.pdxsig` files for
every in-tree blob under the new key; documented at R32 close.

### 7.4 Cross-round consumer completeness check

At R40 close, every row in §5 must have a live `blob_load` invocation
in its driver source. R40.M-close acceptance checks this by grep +
symbol-table walk; if any consumer landed without the guarded load,
the round fails.

---

## 8. Change log

| Date | Round | Issue | Change |
|---|---|---|---|
| 2026-06-17 | Phase-3 | (design) | v0.1 draft — user-consent flow for
end-user-installed blobs. |
| 2026-08-12 | R29.M0 | #1018 | v0.2 rewrite — captures D1.a/D1.b/D1.c
per synthesis §10. Absorbs and generalizes v0.1. |
| 2026-08-14 | R29.M4 | #1032 | §1.7 added — signature verdict taxonomy
and the all-zero-signature scaffold epoch. `SIG_UNSIGNED_SCAFFOLD` is a
verdict distinct from `SIG_OK`; `SIG_OK` is unreachable until R32. |
| 2026-08-14 | R29.M4 | #1033 | §1.8 added — pinned keyring layout, the
three R29 roles, the build-time embedding rationale, the reader
interface, and the fsck property table. |

---

## 9. References

- `design/roadmap/next-wave-synthesis.md` §10 D1.
- `design/drivers/framework.md` §12 (DR-D11 hook; §12.1 to be updated
  at R29.M6 for the D1.c reversal).
- `design/architecture/next-wave-derived-kinds.md` `KIND_HW_DMA_DOMAIN`.
- `design/security/pq-trust-root.md` §0.2 (PQ-Q3), §PQ-Q9 (rotation).
- `design/security/algorithm-catalog.md` (algorithm IDs referenced by
  `.pdxsig` manifests).
- `design/loader/init-caps-sidecar.md` (delivery vehicle for the
  DMA-domain + audit caps).
- `design/tooling/plan.md` §D4 (parallel dual-sign construction for
  user-tool packages).
- `assets/keys/paideia-root-dev.pub`, `assets/keys/intel-firmware-dev.pub`,
  `assets/keys/realtek-firmware-dev.pub` (current dev keyring, §1.8;
  production keys land at R32).
- `src/kernel/core/driver/sig_verify.pdx` (§1.7 verdict taxonomy).
- `src/kernel/core/driver/keyring.pdx` (§1.8 keyring + reader + fsck).
- `src/kernel/boot/verify_self.pdx` (the R28.M1 EFI self-check that
  established the embedding convention §1.8 follows).

*End of document.*
