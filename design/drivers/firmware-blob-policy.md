# PaideiaOS — Drivers: Firmware-Blob Lifecycle Policy

**Status:** Draft v0.1 (Wave 59 — paideia-os#2558 and successor issues
I8/G7/D17-D20).
**Date:** 2026-10-10.
**Scope:** The *operational* firmware-blob policy for paideia-os: how a
vendor firmware image enters the source tree, how it is measured and
signed at build time, how a driver asks the kernel for it, how it is
upgraded or rolled back in a running system, and what the operator
sees on the boot witness and in the audit log when any of that
happens. Complementary to `design/drivers/blob-policy.md`, which
fixes the *architectural* trust model (dual signature, per-driver-
process IOMMU domain, full audit access); this doc fixes the
*lifecycle* that produces, delivers, and retires the signed artefacts
that policy acts on.
**Authorities cited:**
- `design/drivers/blob-policy.md` §1 (D1.a dual-signature trust model
  and the `.pdxsig` manifest shape); §2 (D1.b IOMMU-domain granularity
  this doc inherits); §3 (D1.c full audit access this doc inherits).
- `design/security/pq-trust-root.md` §PQ-Q3 (ML-DSA-65 algorithm
  selection) and §PQ-Q9 (key rotation cadence).
- `design/security/algorithm-catalog.md` (algorithm identifier
  registry).
- `design/security/secure-boot.md` SB-D4 (TPM PCR 0–7 extended by
  firmware; PaideiaOS claims PCR 7 for the firmware-blob measurement
  chain within the ranges the TCG spec reserves for OS-controlled
  policy data).
- `design/filesystem/pdxfs-lite-format.md` (the on-disk container the
  release-build stitches firmware into).
- `tools/paideia-as/CHANGELOG.md` entry for v0.36.55 (BLAKE3
  stdlib-lowering hook and the `paideia_crypto_blake3_hash` FFI
  thunk this doc builds on).
- `design/roadmap/next-wave-synthesis.md` §10 D1 and the Wave 59
  issue plan (paideia-os#2558 fetcher, I8 GuC manifest, G7 GuC
  loader, D17–D20 Wi-Fi / BT / fingerprint / camera placeholders).

---

## 0. Executive summary

Vendor firmware blobs enter paideia-os through exactly one path: a
reviewed commit under `firmware/<vendor>/<name>.<ver>.bin`,
accompanied by a `LICENSE.redist` sidecar and a per-blob
`<name>.<ver>.manifest.toml`. The build system (`tools/build.sh`)
computes a BLAKE3 fingerprint over every blob under that directory,
emits a release-wide `firmware/MANIFEST.pdxfw`, and signs the
manifest with the Paideia release-line ML-DSA-65 key under the same
`.pdxsig` convention `design/drivers/blob-policy.md` §1.3 fixes for
driver blobs. The signed manifest, its signature, and the blob bytes
themselves are stitched into the kernel's signed section at build
time so that the firmware set and the kernel image are a single
atomic release artefact — no mutable mount, no fetch-at-boot, no
network dependency, no device whose firmware is not pinned to a kernel
version.

At boot, the kernel's firmware subsystem walks the manifest, verifies
every entry's BLAKE3 fingerprint against the embedded bytes, extends
the manifest hash into TPM PCR 7 (the `fw-blob` chain), and makes the
set available through a single kernel-side service:
`cap_firmware_lookup(name, version) → Cap<KIND_FIRMWARE_BLOB>`.
Driver processes do not open files, do not parse manifests, and never
touch unverified bytes. A driver that needs the Intel GuC image calls
`cap_firmware_lookup("intel/guc-adls", "70.20.0")`, receives a sealed
capability naming the already-verified blob, and either begins the
load or discovers that its minimum-version floor refuses what the
release contains and declines to start.

The policy this document fixes is the shape of that whole flow — not
the trust architecture (fixed in `blob-policy.md`) but the shipping,
measurement, upgrade, and witness layers that surround it. The three
decisions that carry the most weight are:

- **No proprietary blob lives in the tree without a sidecar license.**
  Every file under `firmware/<vendor>/` is paired with
  `firmware/<vendor>/LICENSE.redist` (or
  `firmware/<vendor>/<name>.LICENSE.redist` for per-blob terms); a
  CI gate refuses the merge if the sidecar is absent or the file
  predates it. Section 1.4 fixes the rule and the enforcement.
- **Build-time measurement is the trust ground, not boot-time.** The
  BLAKE3 fingerprint, the manifest, and the signature are produced
  by the release build; the boot path verifies them, it does not
  re-create them. Section 2 fixes the measurement geometry; section
  6 fixes the build-pipeline shape.
- **The firmware capability is forward-compatible but
  rollback-protected.** A newer blob may be loaded by an older
  driver when the manifest marks it compatible, but no driver loads a
  blob whose version is below its own compiled `min_version`. Section
  5 fixes the rules and the emergency override.

Everything below is spec-level: no Paideia-ASM is written here, and
no implementation issue is closed by this document alone. It unblocks
paideia-os#2558 (Wave 59 I7 firmware fetcher), I8 (GuC manifest), G7
(GuC loader body), and the D17–D20 placeholder drivers for Wi-Fi,
Bluetooth, fingerprint reader, and camera.

---

## 1. Blob provenance

### 1.1 The two source classes

A vendor firmware blob enters paideia-os through one of two paths,
and the path determines the review checklist that gates the merge:

| Class | Source | Example | Review path |
|---|---|---|---|
| **Upstream** | `linux-firmware.git` at a pinned SHA, specific file paths quoted | Intel iwlwifi UMAC (`iwlwifi-ty-a0-gf-a0-89.ucode`); Intel BT HCI (`ibt-20-1-4.sfi`); Realtek SOF topology | §1.2 workflow |
| **Vendor-provided** | Direct from vendor (archived mail or NDA-governed drop) | Intel GuC and HuC for Alder Lake / Raptor Lake iGPU (sometimes pre-public); fingerprint-sensor firmware | §1.3 workflow |

The division is operational, not architectural: once a blob is in the
tree, both classes carry the same measurement, the same signature,
and are indistinguishable to drivers. The distinction only governs
*how we audit the artefact's authenticity before admitting it* — the
upstream path piggybacks on `linux-firmware`'s own review substrate,
while the vendor-provided path puts that burden on Paideia release
engineering directly.

### 1.2 Upstream workflow (pinned linux-firmware)

The canonical reference for every blob we import from `linux-firmware`
is a tuple:

```
UPSTREAM_SHA      = <40-hex git commit from linux-firmware.git>
UPSTREAM_PATH     = <path within that tree, e.g. "iwlwifi-ty-a0-gf-a0-89.ucode">
UPSTREAM_WHENCE   = <URL of the upstream commit as recorded on kernel.org>
UPSTREAM_LICENSE  = <SPDX identifier of the governing redistribution licence>
```

The tuple lives in the per-blob `<name>.<ver>.manifest.toml` sidecar
(§6.2 schema). It never lives in a comment in the Paideia-ASM caller;
every consumer reaches it through the manifest reader so that
provenance is a single structured record, not a scatter of free text
across drivers.

**Merge gate.** Importing a new blob is a pull request that:

1. Adds `firmware/<vendor>/<name>.<ver>.bin` with the exact bytes
   of `linux-firmware.git@UPSTREAM_SHA:UPSTREAM_PATH`.
2. Adds `firmware/<vendor>/<name>.<ver>.manifest.toml` with
   provenance, measurement, signature-pending markers, and licence
   fields populated.
3. Adds or updates `firmware/<vendor>/LICENSE.redist` (or the
   per-blob variant) with the SPDX text and any redistribution notes.
4. Links in the PR description to the upstream `linux-firmware`
   commit; CI's provenance gate (§6.4) fetches that commit's
   recorded blob and asserts a bytewise equality with the file in
   the PR before the build will begin.
5. Is reviewed by at least one release-engineering reviewer who signs
   off on the licence, the version string, and the manifest fields.

The provenance gate's bytewise equality check is deliberate: it
denies a merge where the Paideia copy of the blob diverges from the
upstream it names, even by a single byte. Divergence always means
one of two things — the upstream SHA is wrong, or the file has been
tampered with — and both are blockable at review.

### 1.3 Vendor-provided workflow

Blobs that arrive directly from a vendor (not through
`linux-firmware`) require a stricter check because there is no second
party already attesting to the artefact's provenance. The merge gate
is:

1. The vendor's own signature on the blob is verified against a key
   that paideia-os pins in `assets/keys/` as a `vendor_<name>` role
   (per `design/drivers/blob-policy.md` §1.8 keyring layout).
2. The vendor's release-notes correspondence (email thread, NDA
   drop manifest) is archived under
   `assets/firmware-provenance/<vendor>/<name>-<ver>.txt`. The file
   is in-tree, not in a separate repo, so a reviewer can audit the
   provenance alongside the blob.
3. The `UPSTREAM_WHENCE` field in the manifest names the
   provenance file rather than a URL; the `UPSTREAM_SHA` field is
   set to the blob's own SHA-256 (the vendor rarely gives us a git
   SHA to pin to).
4. Review requires two release-engineering reviewers (one more than
   upstream-sourced blobs), and the merge is gated on a
   release-engineering sign-off recorded in the PR description.

The vendor-signature check is **the vendor half** of the dual
signature `blob-policy.md` §1.1 requires at *load time*: the merge
gate is the point at which we convince ourselves the vendor
signature is one we trust. If we accept the blob and merge it, every
subsequent load replays the same vendor-signature check against the
same pinned key — the merge gate is not a license to skip the load
check, it is a license to let the load check be meaningful.

### 1.4 The "no proprietary blob without a sidecar license" rule

**This rule is absolute, non-overridable, and enforced at merge:**

> No file may exist under `firmware/<vendor>/` whose contents are
> covered by proprietary redistribution terms unless a sidecar
> `LICENSE.redist` (or `<name>.LICENSE.redist`) is present in the
> same directory and committed in the *same* PR as the blob.

The rule is wider than the files themselves because the harm it
protects against is distribution of a redistributable we cannot
account for. Three concrete enforcement points:

- **Pre-merge CI gate.** `tools/ci/check-firmware-licenses.sh`
  (invoked by `tools/build.sh` as a pre-build step) walks
  `firmware/<vendor>/` for every subdirectory with at least one
  `.bin` file. If the directory contains no `LICENSE.redist` *and*
  there is no `<name>.LICENSE.redist` matching every blob in the
  directory, the build fails before any compile step runs.
- **Per-PR grep gate.** The GitHub-side check runs
  `tools/ci/pr-license-grep.sh` against the diff. A PR whose diff
  adds or modifies a `.bin` under `firmware/` and does *not* also
  touch a `LICENSE.redist` is auto-labelled `needs-license-review`
  and refused merge until the licence sidecar is included.
- **Build-time manifest field.** Every entry in
  `firmware/MANIFEST.pdxfw` carries an SPDX license identifier (§6.2)
  — a manifest that is produced for a blob the licence file does not
  cover is a logical contradiction, and `MANIFEST.pdxfw` production
  fails fast on it.

There is no development-time override for this rule. The alternative
("let it in and we'll backfill the licence") is how proprietary
material drifts into trees; the alternative is refused by
construction.

The rule applies equally to upstream-sourced blobs: an upstream
licence covering `linux-firmware` as a whole does not transitively
cover an individual file we pull out of it, so each blob carries its
own licence record under `firmware/<vendor>/<name>.LICENSE.redist`
(or inherits from `firmware/<vendor>/LICENSE.redist` when every
blob in that vendor directory shares identical terms).

### 1.5 The review workflow

Each firmware-import PR records a short review digest in the PR
description, independently of commit messages:

```
Blob: firmware/intel/guc-adls.70.20.0.bin
Provenance: upstream linux-firmware @ a3f7d1c  (iwlwifi-...)
            OR vendor drop (archived under assets/firmware-provenance/...)
Bytewise upstream check: PASS / N/A for vendor
Vendor signature check: PASS (key: intel-firmware-guc-adls-2026)
Sidecar license: firmware/intel/guc-adls.LICENSE.redist (SPDX: ...)
Manifest check: PASS
Reviewer(s): <names>, <names>
```

The digest exists so that a release-engineering review can be
reconstructed from the PR history without walking a review tool's
own records. It is the layer of attestation that bridges
`blob-policy.md`'s runtime signature checks with the human review
that produced the artefacts being checked.

---

## 2. Measurement

### 2.1 Why BLAKE3 and not SHA3-256

`blob-policy.md` §1.3 fixes the `.pdxsig` manifest's `blob_hash`
field to SHA3-256 for runtime signature verification. That decision
was taken when paideia-as had no fast tree-hash primitive. v0.36.55
of paideia-as landed `Blake3::hash` as a first-class stdlib operation
with an FFI thunk to the `paideia-as-crypto::blake3` backend
(`paideia_crypto_blake3_hash`), and we have been using it for module
fingerprinting and PAX chunk hashing since then.

For the firmware subsystem the trade-off is different from the
signature-verification path:

- **Signatures bind to one hash.** The runtime verifier reads the
  manifest's `hash_algo_id`; changing it on the firmware side costs
  nothing because the manifest declares the algorithm it used.
- **Firmware measurement is amortised at build time, not boot
  time.** BLAKE3 is faster than SHA3-256 by a factor of 5–10 on
  our target silicon; across a release that contains 30+ MB of
  firmware the win is meaningful.
- **PCR extension still runs SHA-256.** TPM 2.0 PCR banks are the
  TCG's choice, not ours. The hash we extend into PCR 7 is a
  SHA-256 of the manifest's own BLAKE3 fingerprint set — the TPM
  commitment is a layer above the primary measurement, as §2.4
  details.

The firmware-measurement path therefore uses BLAKE3 (algorithm
identifier `0x0004` in the algorithm catalog — reserved for
`BLAKE3-256`), and the `.pdxsig`-shaped manifest records the
algorithm choice explicitly so that a future rotation to a different
primitive is a one-field edit, not a rewrite.

### 2.2 Per-blob fingerprint

Each blob is measured by its 32-byte BLAKE3 output over the exact
bytes committed under `firmware/<vendor>/<name>.<ver>.bin`:

```
fp_blob = BLAKE3( blob_bytes )   // 32 bytes, little-endian
```

The fingerprint is:

- Recorded in the per-blob `<name>.<ver>.manifest.toml`.
- Recorded in the release-wide `firmware/MANIFEST.pdxfw`.
- Included in the `KIND_FIRMWARE_BLOB` capability a driver receives
  from `cap_firmware_lookup` (§4.2), so that a consumer can carry
  the measurement into its own audit records without a lookup.

A blob whose two per-location fingerprints disagree is a logical
contradiction (the manifest was produced from a different source
than the committed bytes); the build fails before signing.

### 2.3 Release-wide manifest and its fingerprint

The build concatenates per-blob manifest records into
`firmware/MANIFEST.pdxfw` (§6.3 schema) and takes the BLAKE3
fingerprint of the serialised manifest:

```
fp_manifest = BLAKE3( serialised_manifest_bytes )
```

`fp_manifest` is the summary that stands for the whole firmware set
in one 32-byte scalar. It is what the kernel's firmware subsystem
exposes through `cap_firmware_manifest()` for diagnostics, and it is
the primary input to the PCR 7 extension (§2.4). A tampered blob
anywhere in the set changes `fp_manifest`, and the TPM record changes
with it.

### 2.4 TPM PCR 7 (`fw-blob`) extension at boot

The kernel firmware subsystem extends PCR 7 twice during boot:

| Order | Measurement | Why separately |
|---|---|---|
| 1 | SHA-256 of `fp_manifest` | Covers the manifest-as-a-whole; a single scalar an operator can quote against the release's manifest to validate the set in one comparison |
| 2 | SHA-256 of concatenated `(name_bytes || version_bytes || fp_blob)` for every entry, in manifest order | Covers the per-blob set; makes a tampered single blob visible in the quote even if the manifest's own hash is lifted from a different release |

PCR 7's TCG-defined use ("secure-boot policy") already carries the
SecureBoot variable set and the signature database; we extend a
third class of measurement into the same PCR because (a) the TCG
spec allows OS-controlled policy data in PCR 7 at the kernel's
discretion once firmware has handed control over, and (b) the
measurement is policy data in exactly the sense PCR 7 is for — it
pins the firmware set the running kernel admitted. The alternative
of a bespoke PCR (10, 11, …) was rejected because remote attesters
already consume PCR 7 and we gain nothing by splintering the
measurement surface.

The two extensions happen in `kernel_main` *after* the manifest's
signature verification succeeds and *before* any driver that might
request a firmware blob has started. A failing signature verification
is not extended; the operator sees `FW SIG REJECT reason=<...>`
(§7.2) and the firmware subsystem refuses every subsequent
`cap_firmware_lookup`.

### 2.5 Why PCR 7 is not the trust ground

PCR 7's extension is a *witness* of what the kernel admitted; it is
not the gate that admits a blob. Three reasons:

- **A compromised kernel can extend any value it chooses.** The PCR
  is only trustworthy if a measured-boot chain reaches it; it is a
  record for a remote attester, not a self-check.
- **The signature verification is the real gate.** PCR 7 is
  downstream of §3 and runs only on verified manifests; it adds no
  check we did not already perform.
- **The PCR serves attestation, not boot-decision logic.** Nothing
  on the local system reads PCR 7 to decide whether to permit a
  firmware load; that decision lives in the signature verifier.

The measurement is nevertheless load-bearing for remote-attestation
flows (`design/security/runtime-attestation.md`), where a signed
quote over PCR 7 lets a counterparty confirm that the firmware set
the attesting system is running is the one its release artefact
names.

---

## 3. Signing

### 3.1 The signed object

The signed object is `firmware/MANIFEST.pdxfw` as a byte stream, not
any individual blob and not the kernel image as a whole. The
signature is produced by the release-build process using the Paideia
release-line private key (ML-DSA-65), which lives in the networked
HSM per `design/security/pq-trust-root.md` §PQ-Q4 ("release-line →
networked HSM at the CI release runner").

The signature is stored alongside the manifest at
`firmware/MANIFEST.pdxfw.pdxsig`, formatted per `blob-policy.md`
§1.3 (`.pdxsig` manifest format), with the following field choices:

| Field | Value |
|---|---|
| `magic` | `0x50445853` (`'PDXS'`) |
| `version` | `1` |
| `algorithm_id` | `0x0001` (ML-DSA-65) |
| `blob_hash` | `fp_manifest` padded to 32 bytes (left as BLAKE3-256) |
| `hash_algo_id` | `0x0004` (BLAKE3-256) |
| `blob_len` | serialised manifest length |
| `signer_pk_id` | fingerprint of the active release-line key |
| `timestamp` | release-build timestamp (seconds since epoch) |
| `vendor_sig_alg` | `0x0000` (no vendor signature on the manifest itself) |
| `vendor_pk_id` | zero |
| `vendor_sig` | zero |
| `paideia_sig` | ML-DSA-65 signature over the preceding bytes |

The `vendor_*` fields are deliberately zero because the manifest is
a Paideia artefact — the vendor never sees it, never signs it, and
its signature on individual blobs is captured in each per-blob
record (§6.2 `vendor_sig_hex` field) rather than at the
manifest-of-manifests level. The parser `blob-policy.md` §1.3.1
describes handles zero-vendor cases through the `vendor_sig_len = 0`
path.

### 3.2 Why a manifest-level signature rather than per-blob signatures

Each blob already carries its own vendor signature where the vendor
provided one (and `blob-policy.md` §1 handles the runtime verification
of that per-blob material in the dual-signature flow at load time).
What this document is signing is **the set that constitutes "this
release's firmware"** — the fact that a blob is in the manifest at a
given version, licensed under a given SPDX identifier, with a given
BLAKE3 fingerprint. The questions this signature answers are:

- "Did a Paideia release-build produce this manifest?"
- "Does the set of blobs the kernel has at boot match the set the
  release intended?"
- "Has anyone edited the version numbers, the fingerprints, or the
  licence identifiers since the release was cut?"

Per-blob Paideia signatures (as `blob-policy.md` describes for
individual drivers' blobs) answer the first and third questions for
one blob; they do not answer the "does the set match" question. The
manifest-level signature makes the set a first-class artefact and
makes release-set tampering visible with one check rather than
`N` checks.

The per-blob dual-signature verification `blob-policy.md` §1.9
specifies still runs at load time — the manifest signature is a
*gate* on the set, not a replacement for the per-blob gates.

### 3.3 Key lifecycle

The release-line ML-DSA-65 key rotates on the schedule
`design/security/pq-trust-root.md` §PQ-Q9 fixes (1-year cadence,
event-driven on compromise). A key rotation requires:

1. Re-signing `firmware/MANIFEST.pdxfw` under the new key.
2. Updating `signer_pk_id` in the `.pdxsig`.
3. Publishing the new release's `MANIFEST.pdxfw.pdxsig` through
   the standard release channel.

Rotations do not require re-signing or re-releasing the blobs
themselves — the blobs are vendor-signed where applicable, and
Paideia's measurement+signature covers the manifest. A key rotation
is therefore the lightest-weight release-ops event in the firmware
subsystem.

### 3.4 Scaffold-epoch handling

Until R32 provisions the production `paideia_root_pk` (per
`blob-policy.md` §1.7), the manifest signature is bytewise zero.
The firmware subsystem recognises the all-zero signature as
`BLOB_UNSIGNED_SCAFFOLD` (per `blob-policy.md`'s verdict taxonomy),
logs `FW SIG UNSIGNED name=MANIFEST`, and continues at the current
development epoch. The witness tag is `W` severity (dmesg only, not
forwarded to `/system/audit`) — identical to the per-blob scaffold
handling, so an operator does not see a lonely error-severity
manifest signature failure next to the warn-severity per-blob
failures of the same release.

At R32 close, the scaffold logic retires and a bytewise-zero
manifest signature becomes `BLOB_ERR_PAIDEIA_SIG_BAD` — the firmware
subsystem refuses every `cap_firmware_lookup` and the kernel comes
up with no drivers that need firmware. That is the only safe state
for a release-mode kernel whose signed artefact set did not verify.

---

## 4. Driver access

### 4.1 The `cap_firmware_lookup` call

Drivers request firmware blobs through exactly one kernel-side
operation:

```
cap_firmware_lookup(name_ptr: u64, name_len: u64,
                    version_ptr: u64, version_len: u64)
  -> Cap<KIND_FIRMWARE_BLOB>  or  FW_LOOKUP_ERR_*
```

Semantics:

- `name` is the UTF-8-encoded blob identifier (e.g., `intel/guc-adls`,
  `intel/iwlwifi-ty-a0-gf-a0`). The leading vendor prefix matches
  the directory layout under `firmware/`.
- `version` is the UTF-8-encoded version string as it appears in the
  per-blob manifest. The firmware subsystem does **not** parse the
  version string — the string is treated as a label; version
  ordering is decided by the manifest's own `version_ordinal` field
  (§6.2). This keeps vendor-specific version schemes (`70.20.0` vs
  `v2.3-rc1` vs `0x6a7b`) out of the kernel's comparison logic.
- The returned capability is a `KIND_FIRMWARE_BLOB` sealed to the
  calling driver's process by the standard capability-mint
  machinery. The capability contents are fixed in §4.2.
- Error returns are enumerated in §4.3.

The call is total and never blocks: at boot the firmware subsystem
has loaded, verified, and indexed the whole manifest; a lookup is
an O(log N) table walk over an array of 30-ish entries.

### 4.2 `KIND_FIRMWARE_BLOB` capability contents

The capability's payload is a 56-byte record:

| Offset | Size | Field | Notes |
|---:|---:|---|---|
| 0 | 8 | `phys_base` | Physical address of the blob in the kernel-owned R-X region |
| 8 | 8 | `size` | Blob length in bytes |
| 16 | 32 | `fingerprint` | 32-byte BLAKE3 digest from the manifest |
| 48 | 2 | `algo_id` | Hash algorithm (`0x0004` BLAKE3-256 at R? and forward) |
| 50 | 2 | `kind_tag` | `KIND_FIRMWARE_BLOB = 0x002F` (reserved in next-wave-derived-kinds) |
| 52 | 4 | `rights_bits` | `RIGHT_READ`, no mint/revoke/forward |

The blob bytes live in a kernel-owned region marked R-X and never
writable from userspace. A driver's DMA engine, however, can read
from the physical range — that is the point of handing `phys_base`
to the driver — and the driver either copies the blob into its own
device-visible memory or feeds the physical address directly to a
DMA descriptor (as the GuC loader does; §8.2).

Rights are intentionally sparse. The driver cannot mint, revoke, or
forward the capability. It cannot modify the blob. It can hold the
cap for the lifetime of the driver process and release it on exit.
`RIGHT_READ` is implicit — reading via DMA is the operation the cap
authorises, not a separate right.

### 4.3 Lookup failure modes

| Code | Name | Meaning |
|---|---|---|
| `0xFFFFFCE0` | `FW_LOOKUP_ERR_UNKNOWN_NAME` | No manifest entry matches `name`. |
| `0xFFFFFCE1` | `FW_LOOKUP_ERR_UNKNOWN_VERSION` | A manifest entry matches `name` but not `version`. |
| `0xFFFFFCE2` | `FW_LOOKUP_ERR_MANIFEST_UNVERIFIED` | Manifest signature did not verify at boot; the whole subsystem is sealed. |
| `0xFFFFFCE3` | `FW_LOOKUP_ERR_BLOB_UNVERIFIED` | Per-blob fingerprint re-check failed at lookup time (a page-level tampering guard). |
| `0xFFFFFCE4` | `FW_LOOKUP_ERR_BAD_ARG` | Null pointer or zero length. |
| `0xFFFFFCE5` | `FW_LOOKUP_ERR_ROLLBACK_BLOCKED` | Caller's compiled `min_version` is above the requested version; §5.3. |

The sixth code is the version-rollback guardrail (§5). A driver
whose source carries `min_version = "70.19.0"` and asks for
`version = "70.18.0"` does not get a cap — the firmware subsystem
treats the request as a bug worth refusing rather than a load worth
performing.

### 4.4 Why the driver does not see the file path

Driver code never names a path under `firmware/`. The reasons map
one-to-one onto the properties this policy requires:

- **Measurement happens at build time.** A driver that opened a file
  would be reading unverified bytes until it computed its own
  fingerprint, which defeats the point of a verified set.
- **The manifest is the source of truth.** A driver that bypassed
  the manifest could load a blob the release did not acknowledge.
- **PdxFS mounts are irrelevant to firmware.** The signed section
  the kernel stitches at build time (§6.3) is addressed by physical
  range, not by filesystem path; a driver trying to open a
  filesystem path for firmware is doing something wrong.
- **Audit attribution is cleaner.** Every firmware load is a
  `cap_firmware_lookup` call that lands in one audit record with a
  consistent shape; a mix of path-based and cap-based loads would
  split the audit surface.

---

## 5. Version lifecycle

### 5.1 The version model

Each manifest entry carries three version-related fields:

| Field | Role |
|---|---|
| `version` | Human-readable identifier (e.g., `70.20.0`). What the driver asks for. |
| `version_ordinal` | 64-bit monotonic ordinal assigned at manifest-build time. Drivers compare ordinals, not strings. |
| `compatible_with` | Array of other `version_ordinal` values this blob is backwards-compatible with — i.e., "a driver that was built against any of these ordinals can safely consume this blob". |

The ordinal is assigned by the release build in the order blobs
appear in `linux-firmware`'s own version history for that vendor
(and set manually for vendor-provided blobs). It is **not** derived
from the version string — a vendor whose scheme is non-monotonic
would otherwise confuse the ordering logic, and we want the kernel's
decision not to depend on parsing a vendor's version grammar.

### 5.2 Forward compatibility

A driver compiled against ordinal `K` may consume a blob at ordinal
`N > K` when the manifest's `compatible_with` field for ordinal `N`
contains `K`. The firmware subsystem performs the check at lookup
time: the request from a driver carries no compatibility array of its
own, but the driver's compiled `min_version` + `pinned_version`
pair (next section) tells the subsystem which window to accept.

The compatibility array is a positive declaration: Intel asserts (via
their release notes and our manifest-import review) that GuC 70.21.0
is drop-in compatible with GuC 70.20.0 — if that assertion is in the
array, the newer blob is accepted for a driver that asked for 70.20.0;
if it is not, the older-named request fails back with
`FW_LOOKUP_ERR_UNKNOWN_VERSION` and the driver sees the mismatch.

### 5.3 Rollback protection

Every driver carries two compiled-in version fields:

```
min_version:     string    // the oldest blob this driver source will accept
pinned_version:  string    // the version this driver was tested against
```

When a driver calls `cap_firmware_lookup(name, pinned_version)`:

1. The subsystem resolves `pinned_version` to its ordinal in the
   manifest.
2. It also resolves the compiled `min_version` to an ordinal (looked
   up as a secondary metadata field that is embedded next to the
   caller's PAX binary, out of band of the lookup call).
3. If the manifest's current blob for that `name` has
   `version_ordinal >= min_version_ordinal` AND
   (`version_ordinal == pinned_version_ordinal` OR
   `pinned_version_ordinal ∈ compatible_with` list), the lookup
   succeeds.
4. Otherwise it returns `FW_LOOKUP_ERR_ROLLBACK_BLOCKED` or
   `FW_LOOKUP_ERR_UNKNOWN_VERSION` as appropriate.

The `min_version` field is the "no-rollback-below-this" guardrail.
A driver whose code assumes a kernel-side ABI the blob only exposes
from version `70.19.0` onward sets `min_version = "70.19.0"`; a
release that shipped `70.18.0` (because, say, the newer release had
been pulled for a vendor-side bug) does not get used by that driver.
The driver refuses to start rather than attempt an incompatible
load.

### 5.4 Emergency pin override

For debug scenarios (reproducing a load with a specific blob version
to narrow down a vendor-side regression), the kernel supports an
`emergency_pin` capability (`KIND_FW_EMERGENCY_PIN`), which:

- Is minted *only* at boot, *only* when the kernel command line
  carries the specific token `fw.emergency_pin=<name>:<version>`.
- Is minted *only* when `blob-policy.md`'s `relax-mitigations`
  capability has also been granted (per the elevate-broker policy
  in `design/security/elevate-policy-format.md`), so an operator
  cannot pin without having already crossed the elevate boundary.
- Permits one driver to consume the specified blob *regardless* of
  `min_version` guard. The `compatible_with` guard also softens:
  the driver sees whatever version it asked for even if the
  manifest and the driver disagree about compatibility.
- Emits a load-time witness `FW LOAD EMERGENCY_PIN name=<...>
  ver=<...>` (§7.1) and an audit record at `LEVEL_ERROR` — using an
  emergency pin is loud and durable in the audit log.

Three constraints keep the override from decaying into a general
backdoor: the command-line requirement means it cannot be enabled
on a running system without reboot; the `relax-mitigations`
dependency means it cannot be enabled on a locked-down production
image; and the audit record at `LEVEL_ERROR` means its use is
visible to anyone reading the audit log a week later. The override
exists for the one scenario where it is unambiguously the right tool
(bisecting a vendor regression against a stable kernel), and it is
designed to be the wrong tool for anything else.

### 5.5 Deprecation and retirement

A manifest may mark an entry `deprecated = true` and set
`deprecated_as_of_release = "<release-tag>"`. A deprecated entry is
still loadable (it does not immediately break drivers that depend
on it), but:

- A `cap_firmware_lookup` for a deprecated blob emits a `W`-severity
  witness `FW LOAD DEPRECATED name=<...> ver=<...>` once per boot.
- The retirement release (two cycles after deprecation) removes the
  entry from the manifest; any driver still asking for it gets
  `FW_LOOKUP_ERR_UNKNOWN_VERSION`.

The two-release deprecation window is the firmware-side mirror of
the kernel's broader deprecation policy, which gives downstream
code a predictable migration period rather than a sudden break.

---

## 6. Build-time packaging

### 6.1 On-disk layout

Firmware lives under one tree, structured by vendor:

```
firmware/
├── intel/
│   ├── LICENSE.redist
│   ├── guc-adls.70.20.0.bin
│   ├── guc-adls.70.20.0.manifest.toml
│   ├── huc-adls.9.0.0.bin
│   ├── huc-adls.9.0.0.manifest.toml
│   ├── iwlwifi-ty-a0-gf-a0-89.bin
│   ├── iwlwifi-ty-a0-gf-a0-89.manifest.toml
│   ├── ibt-20-1-4.bin
│   ├── ibt-20-1-4.manifest.toml
│   └── ipu6-raptorlake.1.0.0.bin        (D20 placeholder)
├── realtek/
│   ├── LICENSE.redist
│   ├── sof-alc287.1.4.2.bin
│   └── sof-alc287.1.4.2.manifest.toml
├── goodix/
│   ├── goodix-fp-553c.LICENSE.redist
│   ├── goodix-fp-553c.1.0.0.bin         (D19 placeholder)
│   └── goodix-fp-553c.1.0.0.manifest.toml
└── MANIFEST.pdxfw            (release-wide; produced by tools/build.sh)
   MANIFEST.pdxfw.pdxsig       (signature over MANIFEST.pdxfw)
```

### 6.2 Per-blob manifest schema

Each `<name>.<ver>.manifest.toml` has the following keys:

```toml
[blob]
name              = "intel/guc-adls"
version           = "70.20.0"
version_ordinal   = 42                             # assigned by build
size              = 491520
fingerprint       = "7f3a2b…c91d"                  # BLAKE3-256, hex
hash_algo_id      = 0x0004

[provenance]
upstream_sha      = "a3f7d1c6b4e5…9f8"             # linux-firmware commit
upstream_path     = "i915/adls_guc_70.20.0.bin"
upstream_whence   = "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/commit/?id=a3f7d1c6"
upstream_license  = "MIT"                           # SPDX identifier

[vendor_signature]
present           = true
algorithm         = "RSA-2048"
pk_id             = "intel-firmware-guc-adls-2026"
sig_hex           = "..."                           # vendor-published signature

[compatibility]
min_kernel_round  = 37                              # earliest round the blob was reviewed against
compatible_with   = [40, 41]                        # ordinals of older blobs this is drop-in for
deprecated        = false

[consumer]
expected_driver   = "i915_driver"                   # informational
notes             = "AdLS Gen12 GuC v70.20.0; required by GuC submission mode"
```

The build validates the file at ingest: every field is required
except `vendor_signature.sig_hex` (which is empty for blobs without
a vendor signature, like IPU6 at some drops) and
`compatibility.compatible_with` (defaults to the empty array). An
invalid or missing field is a build-time failure.

### 6.3 `MANIFEST.pdxfw` production

`tools/build.sh` runs a `pack-firmware` step before kernel link:

```
pack-firmware:
  1. For each firmware/<vendor>/<name>.<ver>.bin:
     a. Verify a matching <name>.<ver>.manifest.toml exists.
     b. Verify LICENSE.redist (or <name>.LICENSE.redist) exists.
     c. Compute fp_blob = BLAKE3(bin bytes).
     d. Compare fp_blob to the manifest's `fingerprint` field; fail on mismatch.
  2. Concatenate per-blob records in a canonical byte order (sorted by name).
  3. Emit firmware/MANIFEST.pdxfw as a packed binary record set
     (schema: name_len | name | ver_len | ver | ordinal | size |
              phys_offset | fingerprint | compat_list_len | compat_list).
  4. Compute fp_manifest = BLAKE3(MANIFEST.pdxfw bytes).
  5. Call out to the release-signing HSM:
       pdx-sign --key release-line-pq --algo ml-dsa-65
                --out firmware/MANIFEST.pdxfw.pdxsig MANIFEST.pdxfw
  6. Stitch firmware/MANIFEST.pdxfw, firmware/MANIFEST.pdxfw.pdxsig,
     and every per-blob .bin into the kernel-signed section at a
     known physical offset; record phys_offset per entry in the
     binary manifest record.
```

Step 5 is skipped in scaffold-epoch builds; the signature file is
all zero and the all-zero handling §3.4 describes carries the kernel
through boot. Steps 1–4 are not skipped — the measurements and the
manifest are always produced.

### 6.4 CI gates

The build is driven by `tools/build.sh`; the CI gates layer onto it:

- **License gate** (§1.4): refuses to build if any blob lacks a
  licence sidecar.
- **Provenance gate** (§1.2 for upstream blobs): fetches the pinned
  `linux-firmware` commit and asserts bytewise equality.
- **Fingerprint gate** (§6.3 step 1d): refuses to pack if a
  computed fingerprint disagrees with the per-blob manifest.
- **Ordinal gate**: refuses two entries sharing a `name` from
  carrying the same `version_ordinal`.
- **Compatibility-array gate**: refuses a `compatible_with` entry
  that names an ordinal higher than the entry's own ordinal
  (compat windows look backward, never forward).
- **Signature gate** (post-R32): refuses to publish a release where
  `MANIFEST.pdxfw.pdxsig` would be zero-bytes outside the scaffold
  epoch.

The gates fire in the order listed; the first failure stops the
build. The build log always names which gate rejected which blob,
so a release-engineering reviewer sees in one place why the merge
is being refused.

---

## 7. Witnessing

### 7.1 `FW LOAD` lines

Every successful `cap_firmware_lookup` emits a boot-time or
run-time witness:

```
<tsc>|<cpu>|I|DRV_FW|FW LOAD OK name=<name> ver=<version> hash=<hex16>
```

Where `<hex16>` is the first 8 bytes (16 hex characters) of
`fp_blob` — enough to correlate against the manifest without
flooding the log with the full 64-character digest. The full digest
is in the capability payload the caller holds.

Variant tags:

| Tag | Severity | When |
|---|---|---|
| `FW LOAD OK` | `I` | Normal case: lookup succeeded, blob verified, cap minted |
| `FW LOAD DEPRECATED` | `W` | §5.5 — the entry is marked deprecated |
| `FW LOAD EMERGENCY_PIN` | `E` | §5.4 — override in effect |
| `FW LOAD ROLLBACK_BLOCKED` | `E` | §5.3 — driver's `min_version` refused the manifest's blob |
| `FW LOAD UNKNOWN` | `E` | Name or version not in manifest |

Severity `E` reaches the audit log; severity `W` is dmesg-only;
severity `I` is dmesg-only (per `blob-policy.md` §1.10.2's level
mapping, which this subsystem reuses verbatim).

### 7.2 `FW SIG` lines

Signature outcomes are witnessed independently of lookups so that
the kernel's manifest-verification result is visible in one line
at the top of the boot log, before any driver's lookup produces a
subsidiary line:

```
<tsc>|<cpu>|I|DRV_FW|FW SIG OK name=MANIFEST signer=<pk_id>
<tsc>|<cpu>|E|DRV_FW|FW SIG REJECT name=MANIFEST reason=<code>
<tsc>|<cpu>|W|DRV_FW|FW SIG UNSIGNED name=MANIFEST reason=scaffold
```

`<code>` is the raw `BLOB_ERR_*` verdict code from the dual-signature
verifier (per `blob-policy.md` §1.9), so an operator sees the same
vocabulary at the firmware-manifest level and at per-driver blob
levels.

The emitter for both tag families is `src/kernel/core/firmware/
witness.pdx` (to be landed under paideia-os#2558). The subsystem tag
`DRV_FW` is deliberately a firmware-subsystem tag rather than a
per-driver tag — a release-engineering reviewer greps the audit log
for `DRV_FW` to see the firmware set's whole lifecycle in one filter.

### 7.3 Boot-witness stages

The kernel's firmware subsystem contributes stages to the top-level
boot witness, in the order:

1. Manifest located in the kernel-signed section (presence check).
2. Manifest length matches the signed-section descriptor.
3. Manifest signature verified (or scaffold).
4. PCR 7 extension emitted.
5. Per-blob fingerprint re-check succeeded for every entry.
6. Lookup index built; cardinality asserted equal to the manifest's
   count.

Boot fails *loud* on stages 1, 2, 5, 6 (release-mode kernel refuses
to come up without a usable firmware set). Stages 3 and 4 are
scaffold-tolerant: a scaffold-epoch kernel emits `FW SIG UNSIGNED`
and continues; a release-mode kernel treats stage 3 failure as a
hard halt.

---

## 8. First consumers

The policy's first consumers are the Wave 59 issues that this
document unblocks. Each row names the driver, the blobs it loads
from the manifest, and the version floor it carries.

| Issue | Driver | Blobs loaded | `min_version` floor | Notes |
|---|---|---|---|---|
| **I7 (paideia-os#2558)** | — | — | — | The firmware fetcher itself: it builds the manifest, verifies signatures, extends PCR 7, and serves `cap_firmware_lookup`. §4 is its external contract. |
| **I8** | `i915_driver` (manifest half) | `intel/guc-adls`, `intel/huc-adls` | GuC 70.19.0 / HuC 9.0.0 | Pre-G7: lands the manifest records and asserts their presence; no load yet. |
| **G7** | `i915_driver` (loader half) | Same as I8 | Same as I8 | Implements the actual DMA-to-WOPCM transfer that consumes the cap I8 made available. §4.2 fixes the cap shape G7 depends on. |
| **D17** | `cnvi_driver` (Wi-Fi placeholder) | `intel/iwlwifi-ty-a0-gf-a0-89` | iwlwifi 89.0 | Placeholder: establishes the lookup path and the cap handoff; actual UMAC admission lands in a later wave. |
| **D18** | `bt_hci_driver` (BT placeholder) | `intel/ibt-20-1-4` | ibt 20.1.4 | Placeholder: same shape as D17; shares the CNVi driver process per `blob-policy.md` §2.1. |
| **D19** | `goodix_fp_driver` (fingerprint placeholder) | `goodix/goodix-fp-553c` | 1.0.0 | Placeholder; vendor-provided drop with per-blob licence sidecar. |
| **D20** | `ipu6_driver` (camera placeholder) | `intel/ipu6-raptorlake` | 1.0.0 | Placeholder; IPU6 licence procurement is a known risk (per next-wave-synthesis R5). |

The placeholder drivers (D17–D20) in Wave 59 are *not* fully
booting those devices — they are landing the capability handoff so
that the subsequent waves implement real admission on a stable
substrate. D17–D20 each:

- Call `cap_firmware_lookup` for their blob at process startup.
- Record the returned cap's `fingerprint` field in their first audit
  record.
- Decline to proceed past that point until the respective subsequent
  wave implements device bring-up.

That shape means the firmware subsystem is exercised by every
blob-consuming driver early in Wave 59, which both validates the
policy under realistic load and surfaces manifest-side bugs before
any driver tries to DMA its blob into hardware.

### 8.1 I7 (paideia-os#2558) scope summary

I7 implements the kernel-side substrate this document specifies:

- `src/kernel/core/firmware/manifest_reader.pdx` — parses the packed
  `MANIFEST.pdxfw`.
- `src/kernel/core/firmware/verify.pdx` — invokes the dual-signature
  verifier `blob-policy.md` §1.9 landed, scoped to the manifest's
  `.pdxsig`.
- `src/kernel/core/firmware/pcr_extend.pdx` — the TPM PCR 7
  extension sequence of §2.4.
- `src/kernel/core/firmware/lookup.pdx` — `cap_firmware_lookup` and
  the index.
- `src/kernel/core/firmware/witness.pdx` — the §7 witness emitter.
- `src/kernel/boot/kernel_main.pdx` — the stage sequence of §7.3.

### 8.2 G7 handoff mechanics (illustrative)

G7's GuC-load path exercises the cap in the shape every driver will:

```
cap = cap_firmware_lookup("intel/guc-adls", "70.20.0")
     // returns KIND_FIRMWARE_BLOB with phys_base, size, fingerprint

// Record the fingerprint in the driver's audit stream (per blob-policy §3.5)
drv_audit_emit(FW_LOAD_RECEIVED, KIND_FIRMWARE_BLOB,
               subject=cap.id, principal=driver_pid,
               outcome=cap.fingerprint[0..8])

// Program the GT DMA engine to copy cap.phys_base..cap.phys_base+cap.size
// into WOPCM (GuC-owned memory window).
gt_dma_submit(src_phys=cap.phys_base, len=cap.size,
              dst_wopcm=guc_wopcm_base)

// Wait for the DMA completion fence (not shown).
```

The driver never touches blob bytes with its CPU; the DMA engine
is the consumer. This is deliberate — the kernel-owned R-X region
is readable by the IOMMU-mediated DMA engine but not directly by
the driver process's load/store path. A driver that needed to
*parse* a blob (e.g., extract an embedded header) would copy it
through a scratch page it owns, and the fingerprint in the cap is
how that driver confirms the parse was done against the same bytes
the fingerprint named.

---

## 9. Out of scope

- **Blobs installed outside the release build.** User-installed
  blobs (e.g., an out-of-tree driver's firmware) are governed by
  `blob-policy.md` §6 (phase-3 user-consent flow); the mechanism in
  this document only covers blobs stitched into the kernel image
  at release build.
- **Per-blob Paideia re-signing.** This document signs the manifest.
  Per-blob Paideia re-signatures (as `blob-policy.md` §1.1 requires
  for individual driver blobs under the dual-signature trust model)
  are produced by the same release-signing pass but recorded in each
  per-blob manifest's `paideia_sig` field, not here. The two
  signatures carry complementary information; this document does
  not substitute for the per-blob signatures.
- **TPM-sealed blob decryption.** The `KIND_FIRMWARE_BLOB` capability
  always carries the plaintext blob's physical range. Future
  DRM-shaped firmware handling (vendors that require sealed
  transport) would need a `KIND_FIRMWARE_SEALED_BLOB` of its own,
  outside this policy.
- **Network fetch.** No path in this policy touches the network.
  Firmware is stitched at build time; a kernel that boots without
  its firmware set is a bug in the release pipeline, not a case for
  a boot-time fetch to compensate.
- **Hot-reload.** A running kernel never swaps firmware under a
  driver. Firmware changes happen at release boundaries, through
  a rebuild and reboot. The emergency-pin mechanism of §5.4 is
  reboot-scoped, not runtime-scoped.

---

## 10. Future work

### 10.1 Vendor-signature algorithm catalog

Each vendor currently uses a different signature algorithm (Intel
RSA-2048 for GuC/HuC, Intel RSA-2048 for iwlwifi, Realtek RSA-3072
for SOF, Goodix ECDSA-P256 for the fingerprint firmware). The
algorithm catalog (`design/security/algorithm-catalog.md`) tracks
these; a future update will consolidate the per-vendor rows into a
`vendor_sig_profiles.toml` under `firmware/` so that per-blob
manifests reference profile IDs rather than inline algorithm
parameters. Scoped to post-Wave 59.

### 10.2 Delta updates

If a vendor ships two consecutive blob versions whose on-wire delta
is small, the signed-manifest approach supports a delta
representation (a `delta_from = <ordinal>` field in the per-blob
manifest). Build-side tooling and runtime handling for delta
firmware are a future-work item, blocked on a vendor providing a
delta scheme we can validate.

### 10.3 Attestation integration

The PCR 7 measurements of §2.4 feed `design/security/
runtime-attestation.md`'s quote-generation flow. The attestation
side of that integration lands in the attestation subsystem, not
here; this policy only guarantees that the measurement is extended
on every boot and that `cap_firmware_manifest()` surfaces
`fp_manifest` for the attester to quote.

### 10.4 Firmware debug mode under TDX

Server builds under TDX need the firmware-signature verification
to run inside the TDX measured launch window so that the attestation
report binds the firmware set to the TDX session. The server-side
build pipeline is a future scoping task; this policy's structure
(sign at build time, verify at kernel entry, extend into PCR) maps
cleanly onto that extension.

---

## 11. Change log

| Date | Round | Issue | Change |
|---|---|---|---|
| 2026-10-10 | Wave 59 | #2558 | v0.1 draft — unblocks the Wave 59 firmware-fetcher (I7), GuC manifest (I8), GuC loader (G7), and D17–D20 placeholders. |

---

## 12. References

- `design/drivers/blob-policy.md` — the architectural trust model
  this document builds on (D1.a dual signature, D1.b IOMMU domain,
  D1.c full audit).
- `design/security/pq-trust-root.md` §PQ-Q3 and §PQ-Q9.
- `design/security/algorithm-catalog.md` — algorithm-ID assignments
  (ML-DSA-65 = `0x0001`, BLAKE3-256 = `0x0004`).
- `design/security/secure-boot.md` SB-D4 — TPM PCR extension model.
- `design/security/runtime-attestation.md` — the attester consumer
  of §2.4's PCR 7 extensions.
- `design/filesystem/pdxfs-lite-format.md` — the on-disk container
  the stitched kernel section inherits from.
- `tools/paideia-as/CHANGELOG.md` v0.36.55 — the BLAKE3 stdlib hook
  the build-time measurement path consumes.
- `design/roadmap/next-wave-synthesis.md` §10 D1 and the Wave 59
  issue plan.
- `firmware/intel/LICENSE.redist` and `firmware/realtek/LICENSE.redist`
  — the two sidecar licences in the initial Wave 59 import set.
- `src/kernel/core/firmware/*.pdx` — the I7 (#2558) module set
  §8.1 enumerates.
- `src/kernel/core/drivers/gpu/guc_verify.pdx` — the R37.M2 vendor
  blob gate that pre-dated this policy; G7's loader consumes the
  cap this policy mints instead of re-implementing a bespoke read
  path.

*End of document.*
