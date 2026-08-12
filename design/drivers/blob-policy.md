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
- `assets/keys/paideia-root-dev.pub` (current dev root; production
  `paideia_root_pk` lands at R32).

*End of document.*
