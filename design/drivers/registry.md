---
issue: 2521
wave: 59
item: D4
round: R29+ (standalone)
subsystem: drivers / registry
topic: Driver registry v2 — signed-manifest + rollback-token substrate for every bound driver `.pdx` module
touching:
  - src/kernel/core/drv/registry.pdx             (new; this PR — structural skeleton + 5 entrypoints)
  - src/kernel/core/driver/sig_verify.pdx        (R29.M4-001 — reused via driver_sig_verify_algo surface)
  - src/kernel/core/driver/keyring.pdx           (R29.M4-004 — reused for paideia_root_pk)
  - src/kernel/core/cap/kind.pdx                 (KIND_DRIVER = 0x15 pre-existing; KIND_ROLLBACK_TOKEN = 0x160 new, this PR §2.2)
  - tests/fingerprints/drv_registry.golden       (new; this PR)
prereqs:
  - "paideia-os#1032 (driver_sig_verify_algo surface) — LANDED R29.M4-001"
  - "paideia-os#1035 (SUBSYS_DRV_ klog subsystem tag) — LANDED R29.M4-004"
  - "paideia-os#1028..#1031 (persisted registry v2 — the on-disk sibling) — LANDED R29.M3"
  - "paideia-os#2500 (firmware blob-policy.md — companion doc for firmware blobs) — LANDED Wave 59"
consumers:
  - R29 driver-substrate round (first real callers; nothing in-tree binds through this surface yet)
  - D15 (Intel HDA), D6 (LPSS I2C), D1 (NVMe), D2 (xHCI), D3 (e1000e / rtl8139)
  - every driver `.pdx` module that goes live under capability authority
related:
  - design/drivers/registry-v2.md                — the ON-DISK persisted registry (R29.M3); this doc is the IN-KERNEL bound-driver registry; the two names collide; §0.4 names the split
  - design/drivers/blob-policy.md                — covers firmware BLOBS (opaque vendor binaries); this doc covers DRIVERS (paideia `.pdx` modules)
  - design/drivers/firmware-blob-policy.md       — Wave 59 D7 (just-landed) companion; blob-side of the same signed-artifact family
  - design/drivers/driver-signing.md             — the signing policy skeleton this registry's §5 realizes
  - design/drivers/version-rollback.md           — the rollback-contract skeleton this registry's §6 realizes
  - design/drivers/driver-cap.md                 — the KIND_DRIVER cap definition this registry mints
---

# Driver registry v2 — in-kernel signed-manifest + rollback substrate

**Status:** Draft v0.1 (frozen for Wave 59 D4 skeleton landing)
**Date:** 2026-10-10
**Wave / issue:** Wave 59 D4 (paideia-os#2521)
**Repository:** paideia-os (kernel-side primitive)
**Scope:** The IN-KERNEL registry of every bound driver `.pdx` module, keyed by capability. Pins the manifest schema (name, version, kind requirements, ML-DSA-65 signature, BLAKE3 binary hash), the registry entry shape, the five entrypoints (`driver_registry_bind` / `_unbind` / `_lookup` / `_begin_rollback` / `_commit_rollback`), the signature-verification contract against `paideia_root_pk`, and the rollback-token discipline. Companion to `design/drivers/firmware-blob-policy.md` (just-landed) — that doc owns blobs, this doc owns drivers.

---

## Hard inputs (do not relitigate)

- `design/00-feature-inventory.md` §F7 — every peripheral behind a signed, versioned driver.
- `design/01-foundational-decisions.md` §Q11 — capability-based driver authority.
- `design/drivers/driver-cap.md` — `KIND_DRIVER` (derived tag `0x15`) and its rights ladder.
- `design/drivers/driver-signing.md` — the signing-posture outline (R28..R31 scaffold-epoch, R32 real).
- `design/drivers/version-rollback.md` — the rollback-contract outline.
- `src/kernel/core/driver/sig_verify.pdx` (R29.M4-001) — the eight-gate structural signature verifier whose surface §5 reuses.
- `src/kernel/core/driver/keyring.pdx` (R29.M4-004) — holds `paideia_root_pk` once it exists (R32); until then, the scaffold-epoch rules of §5 apply.
- `src/kernel/core/cap/kind.pdx` — `KIND_DRIVER = 0x15` already pins the derived tag.

---

## 0. Decisions summary

### 0.1 Inherited (binding)

| Source | Constraint |
|---|---|
| Pillar 3 (microkernel) | A driver is a userspace process holding a `KIND_DRIVER` cap. The registry is the kernel-side table that NAMES which drivers hold such caps and under what manifest. The driver does NOT read the registry; the supervisor does. |
| Pillar 6 (security by construction) | A `KIND_DRIVER` cap minted without a signature-verified manifest is a compile-time impossibility at the mint gate (§5). The registry entry's `status` field is write-once per lifecycle transition; demotion to `revoked` is irreversible until the row is reaped. |
| Pillar 8 (novelty over POSIX) | No kernel-side driver blob — the driver module is a `.pdx` ELF loaded as a user process. The registry is the capability-ledger of such processes, not a module-load API. |
| Pillar 9 (hierarchically defined) | A driver is minted by the supervisor (holder of `R_DRIVER_ADMIN` on the parent `KIND_PROCESS`). Rollback requires an orthogonal cap (`KIND_ROLLBACK_TOKEN`, new in this PR §2.2) that the supervisor obtains via `driver_registry_begin_rollback`. |

### 0.2 New decisions in this document

| # | Choice | Rationale |
|---|---|---|
| **DR-D1** | **The in-kernel registry is a SEPARATE artifact from the on-disk `registry-v2.md` artifact.** This doc owns the live, in-RAM, cap-attributed table of BOUND drivers. The on-disk registry (`registry-v2.md`, R29.M3) owns the persisted ENTITLEMENT table — "what driver 7 is allowed to do". They cross-reference by name (`manifest.name` is byte-identical to the on-disk record's `name` field). | Two concerns, two tables. Entitlement (durable, signed-at-rest) and binding (volatile, cap-attributed) have different lifetimes, different writers, different failure modes. One table trying to answer both would conflate "has signed authority" with "is currently executing". |
| **DR-D2** | **The manifest is a 128-byte row** with 8 u64 fields (name_lo, name_hi, version_major_minor_patch, kinds_required, kinds_provided, min_api, deprecated_before, flags) plus a 32-byte BLAKE3 digest + 96 reserved bytes = 256 bytes. Followed by a 3309-byte ML-DSA-65 signature block. Total manifest-on-wire = 3565 bytes. | The 256-byte manifest row is single-cache-line in the common case; the signature trails it so a reader that only needs the manifest skips the signature's 3309 bytes with one load of the length field. Same layout discipline as `registry-v2.md` §2 (header-then-signature-at-tail). |
| **DR-D3** | **`driver_registry_bind(manifest_ptr) → Cap<KIND_DRIVER>` is the only mint path.** No "unsigned override", no "debug mode", no bypass. During the scaffold epoch (R28..R31) the signature body is required to be all-zero and the verdict is `SIG_UNSIGNED_SCAFFOLD`; the mint SUCCEEDS and the registry row records the scaffold verdict in `status`. R32 flips the verdict dispatch at the mint gate to require `SIG_OK`; no edit to this file is needed. | Mirrors the EFI image, pdxfs-lite superblock, and persisted registry v2 scaffold-epoch posture (`sig_verify.pdx` §Scaffold-epoch). A "debug bypass" would become the permanent hole the day real signing lands. |
| **DR-D4** | **Rollback is a two-cap protocol: `_begin_rollback(name) → Cap<KIND_ROLLBACK_TOKEN>` then `_commit_rollback(token)` or `_abort_rollback(token)`.** The token names a specific driver + the pre-rollback version it would restore. The commit and abort are the only two legal terminators; a token that is never committed or aborted times out at the next registry generation bump and is reaped by the supervisor. | A single `rollback(name, version)` call cannot distinguish "do it now" from "I am considering it"; the two-phase shape makes the dangerous moment (the actual swap) a separate authority. Matches the `registry_snapshot → registry_rollback` discipline of `registry-v2.md §9` but keeps the token at the cap layer rather than as an opaque id. |
| **DR-D5** | **`KIND_ROLLBACK_TOKEN` is a new derived kind, tag `0x160`.** Runtime base kind: `KIND_RESERVED` (15) — a rollback token is not device-adjacent, not notification-adjacent, not memory-adjacent; it is a signed one-shot capability over a specific registry mutation. Derivation parent at mint time: `KIND_DRIVER` (the driver being rolled back). | Follows the same "derived-tag out of the 4-bit base range, under KIND_RESERVED when nothing else fits" convention `KIND_DMESG = 0x16` set (`kind.pdx §KIND_DMESG`). Keeps the token outside KIND_HW, outside KIND_IPC, outside the memory family — it is sui generis. |
| **DR-D6** | **Table cap: `DRV_REGISTRY_MAX = 32` rows × 64 bytes/row = 2 KiB .bss.** 32 drivers covers the R29 ambition (uart, nvme, xhci, pcie, i2c, gpio, hda, iris_xe + a few spares); 64 bytes/row holds the hot fields the dispatcher needs on every op without reading the full manifest. The full manifest is kept in a parallel `.bss` region (32 × 256 = 8 KiB) that only the signature-verification and lookup paths load. | Matches `_driver_table`'s 32-row ceiling (`driver_table.pdx`) so the live-driver census remains a single number; matches `_hw_timeline_table`'s 2 KiB .bss footprint (`kind_hw_timeline.pdx`). |
| **DR-D7** | **Return-code block = `0xFFFFFC50..0xFFFFFC5F` (DRV_REG_*).** Disjoint from DMA (`0xFFFFFFC4..CF`), timeline (`0xFFFFFFC4..CF` per source), MSIX (`0xFFFFFFE7..EF`), HW_INT (`0xFFFFFFF7..FF`), and from the on-disk registry cluster at `0xFFFFFD00..FDEF`. Previously comment-reserved by `hda/reset.pdx §4` (R33.M1 scaffold) but no codes were defined there; the follow-up PR to `hda/reset.pdx` relocates its reservation. | The driver-registry concern is thematically close to the on-disk registry but numerically disjoint, so a boot-log triage can attribute a code to the right table at a glance. |
| **DR-D8** | **Fingerprint tags = `DRV REG OK name=<..> ver=<..>`, `DRV SIG OK`, `DRV ROLLBACK BEGIN`, `DRV ROLLBACK COMMIT`, `DRV ROLLBACK ABORT`.** Emitted via `klog_s1` with `SUBSYS_DRV_` (R29.M4-004). The skeleton emits only the dispatch-chatter tag (`drv_registry_msg`); per-event tags land in the follow-up slice. | Matches `TL MINT OK` / `TL SIGNAL OK` / `TL WAIT UNBLOCK` from `kind-hw-timeline.md §5.1`; the per-event-tag catalog is deferred along with the real bodies. |

### 0.3 Three meta-positions

1. **A driver is a process, not a module.** PaideiaOS has no in-kernel driver blob slot. Every driver is a userspace process whose authority to touch hardware is a `KIND_DRIVER` cap minted from this registry. The registry is therefore the capability ledger of such processes, keyed by name — not a module-load table, not a dlopen symbol space, not an "insmod" API. Any attempt to re-shape this surface into a module loader is a Pillar-3 regression.

2. **The signature is on the MANIFEST, not on the binary.** The manifest row's BLAKE3 digest field is the binary's hash; the ML-DSA-65 signature covers the manifest row INCLUDING that digest. A reader therefore verifies in two steps: (a) ML-DSA-65-verify the manifest signature against `paideia_root_pk`; (b) BLAKE3-hash the on-disk binary and compare against the manifest's digest field. Verifying the binary directly against ML-DSA-65 would require streaming 3309 bytes of signature over multi-megabyte binaries at every bind; the digest-in-manifest shape is one small signature, one fast hash.

3. **Rollback is not a time-machine.** The rollback discipline here answers "revert this driver's version to the previous bound version" — it does NOT restore kernel state (device registers, DMA mappings, user clients). The supervisor is responsible for the quiesce → rollback → relaunch cycle; the registry is responsible for the atomic swap of the row and the manifest region, and for witnessing it. Confusing "roll back the registry" with "roll back the system" would make this an infinite-regress problem.

### 0.4 Name collision: this doc vs. `registry-v2.md`

The on-disk, persisted-at-rest driver registry (R29.M3-001..004, `registry_v2.pdx` + friends) is also titled "driver registry v2". The names collide because the artifact belongs to the same family at different lifetimes. The split:

| Concern | `registry-v2.md` (on-disk, R29.M3) | `registry.md` (this doc, Wave 59 D4) |
|---|---|---|
| **Backing** | tmpfs inode `/system/registry/drivers.pdxreg` | kernel `.bss` tables |
| **Lifetime** | durable across boot | volatile, rebuilt from manifests at boot |
| **Keyed by** | `driver_table_slot` (u8) | capability-attributed row (minted at `_bind`) |
| **Field focus** | ENTITLEMENT (manifest bitmaps, effect row) | BINDING (cap holder, status, teardown fn, rollback hook) |
| **Writer** | supervisor at boot + reconfig | kernel at `_bind` / `_unbind` / `_commit_rollback` |
| **Reader** | fsck + cap-vs-effect walker (C1301) | cap dispatch + rollback flow |
| **Signature** | on the whole image at tail (sig over all records) | on EACH manifest row (sig over one 256-byte row) |

They cross-reference by `manifest.name`. A `name` present in the on-disk entitlement image but absent from this registry is "entitled but not yet bound" (expected — early boot). A `name` present here but absent from the on-disk image is "bound without entitlement" and is a bind-gate violation (§5.3). Both tables are indexed into by the same 16-byte NUL-padded name; the lookup discipline in `registry_lookup.pdx` is reused verbatim.

---

## 1. Capability shape

### 1.1 Tag layout

The `KIND_DRIVER` derived tag is already allocated at `0x15` (`kind.pdx` line 151); runtime base kind is `KIND_DEVICE = 10`. This document does not re-base it. The new derived kind for the rollback token is:

```
Base-kind enum (16 slots, frozen)        Derived tags (u64 kind field)
  …                                       0x15 : KIND_DRIVER             (pre-existing, R29.M0)
 14: KIND_HW                              0x140..0x143 : HW family       (R29.M1)
 15: KIND_RESERVED                        0x16 : KIND_DMESG              (R51 logging-m9)
                                          0x160: KIND_ROLLBACK_TOKEN     (THIS PR, Wave 59 D4)
```

A rollback token's parent at mint time is a `KIND_DRIVER` cap on the driver being rolled back. The derivation chain is `KIND_PROCESS → KIND_DRIVER → KIND_ROLLBACK_TOKEN`: the supervisor cannot forge a token for a driver it does not already have `KIND_DRIVER` authority over.

### 1.2 Rights ladder

```
KIND_DRIVER (0x15) rights (pre-existing, driver-cap.md):
  R_DRIVER_INVOKE    (0x01)  invoke the driver's declared ops
  R_DRIVER_MANIFEST  (0x02)  read-only: fetch the manifest row
  R_DRIVER_UNBIND    (0x04)  tear down the binding (returns cap null)
  R_DRIVER_ADMIN     (0x08)  the supervisor's rollback / rebind authority
  R_DRIVER_ALL       (0x0F)

KIND_ROLLBACK_TOKEN (0x160) rights (NEW, this PR):
  R_ROLLBACK_COMMIT  (0x01)  consume the token to perform the swap
  R_ROLLBACK_ABORT   (0x02)  consume the token to cancel without swap
  R_ROLLBACK_INSPECT (0x10)  read-only: see which driver + which version
  R_ROLLBACK_ALL     (0x13)
```

A rollback token is a strict one-shot: COMMIT or ABORT consumes it (revokes the cap). INSPECT does not consume. Minting a second token for the same driver while a prior token is live returns `DRV_REG_ROLLBACK_IN_PROGRESS`; the supervisor must terminate the first before starting a second.

### 1.3 Descriptor tail

A `KIND_DRIVER` descriptor's `target_ptr` holds the row index into `_drv_registry_table` in bits [15:0]; upper bits are zero. A `KIND_ROLLBACK_TOKEN` descriptor's `target_ptr` encodes `{row_index[15:0], staged_version[47:16]}` — a single qword decode gives both the registry row the token targets and the version it would restore, with no extra table lookup.

### 1.4 Row layouts

#### 1.4.1 `_drv_registry_table` — the hot row (64 bytes)

```
   64-byte row (one per bound driver slot, 32 slots)
   +--------------------------------------------------+ 0
   | +0   u64  header:                                 |
   |     [7:0]   status (0=free, 1=bound, 2=rollback,  |
   |             3=revoked)                            |
   |     [15:8]  reserved                              |
   |     [31:16] generation (bumps on bind/unbind/     |
   |             commit — stale caps fail at dispatch) |
   |     [63:32] version_packed (16-bit each major,    |
   |             minor, patch; high 16 unused)         |
   | +8   u64  name[0..7]        NUL-padded, byte-id   |
   | +16  u64  name[8..15]       with manifest.name    |
   | +24  u64  cap_holder_slot   KIND_PROCESS slot of  |
   |                             the driver process    |
   | +32  u64  manifest_offset   byte offset into      |
   |                             _drv_manifest_region  |
   | +40  u64  teardown_fn       function ptr; called  |
   |                             on unbind / rollback  |
   | +48  u64  rollback_token_id non-zero iff a token  |
   |                             is live               |
   | +56  u64  row_checksum      xorshift over [0..56) |
   +--------------------------------------------------+ 64
```

`row_checksum` guards against a kernel-side memory corruption silently rewriting entitlement; it is NOT a cryptographic defense (the signature on the manifest region is). The checksum is verified on every lookup and every mutation; a mismatch returns `DRV_REG_ROW_CORRUPT` and the row is quarantined (status → `revoked`, generation bumped) rather than used.

#### 1.4.2 `_drv_manifest_region` — the cold slab (32 × 256 bytes = 8 KiB)

```
   256-byte manifest (one per bound driver slot)
   +--------------------------------------------------+ 0
   | +0   u64  name[0..7]                              |
   | +8   u64  name[8..15]                             |
   | +16  u64  version_packed  (major16/minor16/patch16/_16) |
   | +24  u64  kinds_required  (bitmap, bit k = needs KIND_k) |
   | +32  u64  kinds_provided  (bitmap, bit k = provides…)   |
   | +40  u64  min_api        (API-version tuple major/minor) |
   | +48  u64  deprecated_before  (API version below which     |
   |                             consumers reject this driver) |
   | +56  u64  flags          (bit0 FIRMWARE_REQUIRED,         |
   |                           bit1 ROLLBACK_ALLOWED,          |
   |                           bit2 DMA_CAPABLE,               |
   |                           bit3 ISR_CAPABLE, …)            |
   | +64  u8[32]  signed_blake3 — BLAKE3-256 of the binary    |
   | +96  u64[12] reserved (zero, future-use)                  |
   | +192 u8[64]  reserved for the follow-up slice's expansion |
   +--------------------------------------------------+ 256
```

The signature block for this manifest row follows IMMEDIATELY in a parallel region (`_drv_signature_region`, 32 × 3309 = ~106 KiB — one ML-DSA-65 signature per slot). The signature covers bytes `[0, 256)` of the manifest row and nothing of itself.

### 1.5 Lifecycle

```
         _bind()                     _begin_rollback()
   FREE  ─────────→  BOUND  ────────────────────────→  ROLLBACK_PENDING
                      │  ▲                                   │
                      │  │                                   │
                      │  │  _commit_rollback()               │
                      │  └───────────────────────────────────┘
                      │                                      │
                      │  _unbind()                           │  _abort_rollback()
                      ▼                                      │
                   REVOKED  ◀───────────────────────────────-┘
```

- **FREE → BOUND**: `_bind(manifest_ptr)` performs the eight signature gates (§5), finds a free slot, copies the manifest into `_drv_manifest_region[slot]`, copies the signature into `_drv_signature_region[slot]`, fills the hot row, mints the `KIND_DRIVER` cap. Emits `DRV REG OK name=<..> ver=<..> hash=<16hex>` + `DRV SIG OK`.
- **BOUND → REVOKED**: `_unbind(cap)` calls `teardown_fn`, zeros the manifest + signature, marks the row free, bumps the generation. Emits `DRV UNBIND OK name=<..>`.
- **BOUND → ROLLBACK_PENDING**: `_begin_rollback(name)` mints a `KIND_ROLLBACK_TOKEN` cap over the row; the row's `rollback_token_id` becomes non-zero. The row is still BOUND for cap-invoke purposes; new op-dispatches continue to run against the current version. Emits `DRV ROLLBACK BEGIN name=<..> staged_ver=<..>`.
- **ROLLBACK_PENDING → BOUND (new version)**: `_commit_rollback(token)` calls `teardown_fn`, swaps the manifest + signature region to the staged version, re-runs the signature gates against the staged manifest, re-fills the hot row with the restored version, bumps generation. Emits `DRV ROLLBACK COMMIT`.
- **ROLLBACK_PENDING → BOUND (current version)**: `_abort_rollback(token)` discards the staged version, clears `rollback_token_id`, bumps generation. Emits `DRV ROLLBACK ABORT`.
- **REVOKED → FREE**: supervisor-driven reap, not a cap operation; the row's state byte is cleared and the slot becomes available for a future `_bind`.

**Status is write-once-per-transition.** No code outside this file writes the status byte; the status walker is the only path from BOUND to any other state. Generation bumping is MANDATORY on every state transition so cached caps carrying a stale generation fail at dispatch rather than silently reaching into an unrelated driver.

---

## 2. The five entrypoints

The skeleton PR lands all five as stubs that emit dispatch chatter via `klog_s1(SUBSYS_DRV_, drv_registry_msg)` and return `INVOKE_UNSUPPORTED` (`0xFFFFFFFFFFFFFFFC`). The real bodies land in the follow-up slice. Every entry is leaf (one `call klog_s1`, one `mov rax, imm`, `ret`) — no stack spill, no register preservation beyond the klog args, no reserved labels anywhere.

### 2.1 `driver_registry_bind(manifest_ptr) → Cap<KIND_DRIVER> | DRV_REG_*`

The ONLY mint path. SysV ABI: `rdi = manifest_ptr`. Returns the minted cap slot in `rax`, or a code in the `0xFFFFFC5x` block.

Real body (follow-up slice) will:
1. `manifest_ptr != 0` and 8-byte-aligned → `DRV_REG_BAD_ARG`.
2. `driver_sig_verify_algo(SIG_ALGO_ML_DSA_65, manifest_ptr, 256, sig_ptr, 3309, paideia_root_pk, 1952)` — returns `SIG_OK` (R32+) or `SIG_UNSIGNED_SCAFFOLD` (R28..R31) → bind proceeds; any other verdict → `DRV_REG_SIG_FAIL`.
3. BLAKE3-hash the on-disk binary (located by name lookup in the loader table) via `paideia_crypto_blake3_hash`; compare against `manifest.signed_blake3` → mismatch → `DRV_REG_HASH_MISMATCH`.
4. Name uniqueness: scan `_drv_registry_table` for an existing BOUND or ROLLBACK_PENDING row with matching name → found → `DRV_REG_NAME_IN_USE`.
5. Find a FREE slot → none → `DRV_REG_ENOSPC`.
6. Fill the hot row + manifest region + signature region; compute `row_checksum`; bump generation.
7. Mint `KIND_DRIVER` cap over the row; cap descriptor's `target_ptr = row_index`; rights default `R_DRIVER_ALL`.
8. Emit `DRV REG OK name=<..> ver=<..> hash=<16hex>` + `DRV SIG OK`.

### 2.2 `driver_registry_unbind(cap_slot) → DRV_REG_OK | DRV_REG_*`

Tear down a bound driver. SysV ABI: `rdi = cap_slot`. Returns `0` on success.

Real body will:
1. Validate the cap descriptor: `kind == KIND_DRIVER` → else `DRV_REG_WRONG_KIND`.
2. Fetch row via `target_ptr`; validate `row_checksum` → mismatch → `DRV_REG_ROW_CORRUPT` + quarantine.
3. Reject if `rollback_token_id != 0` → `DRV_REG_ROLLBACK_IN_PROGRESS` (supervisor must abort first).
4. Call the row's `teardown_fn(cap_slot)`; propagate its return.
5. Zero manifest + signature regions for this slot.
6. Clear row (`status = REVOKED`, generation++).
7. Emit `DRV UNBIND OK name=<..>`.

### 2.3 `driver_registry_lookup(name_ptr, name_len) → cap_slot | DRV_REG_NOT_FOUND | DRV_REG_BAD_NAME`

Supervisor-side name → cap resolution. SysV ABI: `rdi = name_ptr`, `rsi = name_len`.

Reuses the exact-name-match discipline of `registry_lookup_by_name` (`registry_lookup.pdx §8.1`): a `name_len` of 0 or above 16 → `DRV_REG_BAD_NAME`; prefix-matches do NOT hit; records whose `status != BOUND` are skipped. Returns the `KIND_DRIVER` cap slot (NOT the row index — the caller invokes through the cap). Not-found returns `DRV_REG_NOT_FOUND` (`0xFFFFFC58`); index 0 is a legitimate hit, so not-found cannot be zero (same discipline as `REGISTRY_LOOKUP_ERR_NOT_FOUND = 0xFFFFFD40`).

### 2.4 `driver_registry_begin_rollback(name_ptr, name_len, target_version) → Cap<KIND_ROLLBACK_TOKEN> | DRV_REG_*`

Stage a rollback. SysV ABI: `rdi = name_ptr`, `rsi = name_len`, `rdx = target_version` (packed major/minor/patch u48).

Real body will:
1. `_lookup(name)` to find the driver → `DRV_REG_NOT_FOUND` if absent.
2. Fetch row; validate checksum.
3. Reject if `status != BOUND` → `DRV_REG_BAD_STATE`.
4. Reject if `rollback_token_id != 0` → `DRV_REG_ROLLBACK_IN_PROGRESS`.
5. Reject if `manifest.flags.ROLLBACK_ALLOWED == 0` → `DRV_REG_ROLLBACK_FORBIDDEN`.
6. Locate the staged version's manifest + signature in a persisted "driver attic" region (deferred to Wave 60+; the skeleton returns `DRV_REG_NO_STAGED` for every input). The attic shape is captured in `design/drivers/driver-attic.md` (not yet written; Wave 60 D-TBD).
7. Verify the staged manifest's signature → bind-gate equivalent.
8. Mint `KIND_ROLLBACK_TOKEN` cap over the row with `target_ptr` encoding `{row_index, target_version}`; set `rollback_token_id` to the token's cap_table generation.
9. Row `status` transitions to `ROLLBACK_PENDING`; new op-dispatches still see the current manifest.
10. Emit `DRV ROLLBACK BEGIN name=<..> staged_ver=<..>`.

### 2.5 `driver_registry_commit_rollback(token_cap_slot) → DRV_REG_OK | DRV_REG_*`

Perform the swap. SysV ABI: `rdi = token_cap_slot`. Returns `0` on success.

Real body will:
1. Validate cap: `kind == KIND_ROLLBACK_TOKEN` → else `DRV_REG_WRONG_KIND`.
2. Rights gate `R_ROLLBACK_COMMIT` → else `INVOKE_DENIED`.
3. Fetch row from `target_ptr`; validate checksum; verify `rollback_token_id` matches the cap's generation.
4. Call current driver's `teardown_fn`.
5. Swap manifest + signature regions to the staged version.
6. Re-run the full §5 signature gate against the staged manifest (defense in depth — the staged version was verified at `_begin_rollback`, but the attic may have been mutated under us; the second verify closes that window).
7. Refill the hot row with the staged version; clear `rollback_token_id`; bump generation; mark `status = BOUND`.
8. Revoke the rollback token cap (it is consumed).
9. Emit `DRV ROLLBACK COMMIT name=<..> old_ver=<..> new_ver=<..>`.

A sixth entrypoint, `driver_registry_abort_rollback(token_cap_slot)`, is NOT part of the five-entrypoint skeleton this PR lands; it is called out in §1.5 and in the follow-up slice because the state machine requires both terminators. The skeleton's five entrypoints are the mint/unbind/lookup/begin/commit set; abort is a trivial variant of commit (same cap validation, no swap, same generation bump) that lands with commit's real body.

---

## 3. Backing table

```
   src/kernel/core/drv/registry.pdx :

   pub let mut _drv_registry_table      : [u64; 256] = uninit @align(64)  // 32 × 64B
   pub let mut _drv_manifest_region     : [u64; 1024] = uninit @align(64) // 32 × 256B
   pub let mut _drv_signature_region    : [u64; 13232] = uninit @align(64) // 32 × 3309B rounded to 13236/8 ≈ 13232 u64
   pub let mut _drv_registry_generation : u64 = 0                         // monotonic
```

`.bss` zero-init puts every slot at `status = FREE = 0`, every manifest at all-zero name (never matches a real driver), every signature at all-zero body (which the scaffold-epoch gate accepts; see §5). The skeleton PR declares only the hot `_drv_registry_table` region (2 KiB); the manifest and signature regions land with the real bodies in the follow-up slice.

Total .bss footprint at full population: 2 KiB + 8 KiB + ~106 KiB = ~116 KiB. The signature region dominates; a future PR may move the signature region to a tmpfs-backed persisted store (same shape as `registry_v2.pdx`'s on-disk block) if the kernel-image size budget demands it.

---

## 4. Signature verification contract

Reuses `driver_sig_verify_algo` from `sig_verify.pdx` verbatim. The eight structural gates (algorithm, artifact ptr, artifact len, sig ptr, sig len = 3309, pk ptr, pk alignment, scaffold-epoch branch) run against:

- `artifact_ptr` = manifest row (256 bytes).
- `artifact_len` = 256.
- `sig_ptr` = parallel signature row (3309 bytes).
- `pk_ptr` = `paideia_root_pk` (fetched via `driver_keyring_root_pk()`; returns a 64-byte-aligned pointer or `KEYRING_ERR_NO_SUCH_KEY` at R28..R31 — the scaffold-epoch keyring is pre-provisioning).

Verdict dispatch at the bind gate:

| `driver_sig_verify_algo` returned | Bind-gate action |
|---|---|
| `SIG_OK` (0, R32+) | Proceed. Row's status flags record `signed_ok`. |
| `SIG_UNSIGNED_SCAFFOLD` (1, R28..R31) | Proceed. Row's status flags record `scaffold`. Fingerprint tag `DRV SIG OK` emits `DRV SIG SCAFFOLD` instead. |
| any `SIG_BAD_*` | Reject with `DRV_REG_SIG_FAIL`. No row mutation. |
| `SIG_UNVERIFIABLE` (R28..R31 only; non-zero signature body present) | Reject with `DRV_REG_SIG_FAIL`. During the scaffold epoch every signature MUST be all-zero; a non-zero body is attempted forgery. |

R32 provisions `paideia_root_pk` and replaces `SIG_UNSIGNED_SCAFFOLD` with hard reject — ONE edit to this file at the gate dispatch, zero edits to the manifest layout, the sig layout, or the row layout. That is the whole scaffold-to-production flip; the two properties `sig_verify.pdx` §Scaffold-epoch enforces (SIG_OK unreachable at R29, `driver_sig_verdict_is_ok` returns 1 iff v == SIG_OK) make it safe.

### 4.1 Why the manifest, not the binary

A 3309-byte ML-DSA-65 verify over a multi-megabyte driver binary is 2-3 orders of magnitude more work than a 256-byte verify + a BLAKE3 hash of the binary. The verify dominates; the hash parallelizes against the signature pipeline and streams. Also: a signature over the manifest row makes attribution forensically clean — a line in a boot log says exactly which 256 bytes a key signed. A signature over the binary ties the signer to a particular linker output, which is unstable across build-system updates.

The split is only safe if the manifest's digest field is covered by the signature. §1.4.2 fixes `signed_blake3` at offset 64, inside the 256-byte signed region, so no attacker can produce a manifest with a different `signed_blake3` and the same signature.

### 4.2 Scaffold-epoch posture

Every signature produced by the build pipeline between R28 and R31 is 3309 all-zero bytes. The bind gate accepts this and records `scaffold` in the row's status flags; the boot witness is honest about the posture (`DRV SIG SCAFFOLD`, not `DRV SIG OK`). An unsigned driver loads, and the supervisor records that it loaded unsigned. R32 flips the dispatch at the gate; no file in this subtree changes.

---

## 5. Rollback discipline

### 5.1 Why two phases

`_begin_rollback` names the target version and arms the swap by minting the token. `_commit_rollback` performs it. A one-call `rollback(name, version)` cannot distinguish "I want to roll this back" from "do it now"; the two-phase shape makes the dangerous moment a separate authority. In practice the supervisor will:

```
   token = driver_registry_begin_rollback("hda", v0_0_9)
   # quiesce the driver, drain its clients, revoke any outstanding caps…
   driver_registry_commit_rollback(token)   # OR _abort_rollback(token) on error
```

The commit is irreversible per cap-consumption; the abort is a clean no-op. A token held forever is reaped at the next registry generation bump by the supervisor's housekeeping (deferred to the follow-up slice; the skeleton has no reaper).

### 5.2 The staged manifest

The staged version must come from somewhere. The current proposal:

- **Attic region** (deferred): a per-driver append-only log of past manifests the supervisor commits durable copies into whenever `_bind` succeeds. The attic is a tmpfs file per driver, with the same signed-at-rest discipline as the on-disk registry v2 image. Rollback staging reads from the attic.
- **Loader-side binary cache** (deferred): the binaries themselves must still exist on disk to be re-loaded. The loader cache keeps the previous version's binary at `driver.pdx.v0.0.9` under the same name discipline.

The skeleton PR implements NEITHER. `_begin_rollback` returns `DRV_REG_NO_STAGED` for every input until the attic lands. The witness fingerprint will show `DRV ROLLBACK BEGIN` only when the staged artifact exists.

### 5.3 Cap-cascade on rollback

A `KIND_DRIVER` cap minted at version v1 is NOT valid after a rollback to v0. The row's generation counter bumps on commit; the stale cap carries the old generation and fails at dispatch (`cap_invoke_dispatch` compares cap.generation vs row.generation). The supervisor is responsible for re-handing out fresh caps to legitimate clients post-rollback; this is a client-visible event the supervisor must orchestrate.

**Design non-goal**: automatic client migration. The registry does not know who holds a `KIND_DRIVER` cap for a given driver; cap holders are the cap-table's concern. A supervisor that rolls back without draining clients will see those clients receive `INVOKE_DENIED` or `INVOKE_UNSUPPORTED` on their next op — which is the explicit, debuggable failure mode we want.

### 5.4 Abort as the no-op terminator

`_abort_rollback(token)` is the clean cancel. The token is revoked; the row's `rollback_token_id` is cleared; the generation bumps anyway (so any caller that observed the ROLLBACK_PENDING state via INSPECT and cached a derived decision gets re-synced); the row returns to BOUND. No teardown fires; no swap happens. The staged artifact in the attic is NOT deleted — the supervisor may begin a fresh rollback immediately.

---

## 6. Fingerprint tags

| Tag | Where emitted | Payload |
|---|---|---|
| `DRV REG OK name=<..> ver=<..> hash=<16hex>` | `_bind` success | first 8 hex of BLAKE3 |
| `DRV SIG OK` | `_bind` after `SIG_OK` | — |
| `DRV SIG SCAFFOLD` | `_bind` after `SIG_UNSIGNED_SCAFFOLD` | — |
| `DRV UNBIND OK name=<..>` | `_unbind` success | — |
| `DRV ROLLBACK BEGIN name=<..> staged_ver=<..>` | `_begin_rollback` success | — |
| `DRV ROLLBACK COMMIT name=<..> old_ver=<..> new_ver=<..>` | `_commit_rollback` success | — |
| `DRV ROLLBACK ABORT name=<..>` | `_abort_rollback` success | — |
| `DRV QUARANTINE name=<..> rc=<hex>` | row-checksum mismatch quarantine | the failing rc |

All go through `klog_s1(KLOG_INFO, SUBSYS_DRV_, …)`. The skeleton PR emits ONLY `drv_registry_msg` (the dispatch-chatter tag) from each stub; per-event tags land in the follow-up slice. The fingerprint golden at `tests/fingerprints/drv_registry.golden` is the shape the follow-up slice will meet; it is deliberately NOT wired into `tools/run-smoke.sh` this slice (there is nothing to produce the output yet).

---

## 7. Return-code taxonomy

Block `0xFFFFFC50..0xFFFFFC5F` — DRV_REG family. 16 codes, aligned on a nibble boundary, previously comment-reserved by `hda/reset.pdx §4` (R33.M1 scaffold) with zero codes defined; the follow-up PR to `hda/reset.pdx` relocates its reservation.

| Code | Name | Meaning |
|---|---|---|
| `0xFFFFFC50` | `DRV_REG_BAD_ARG` | manifest_ptr == 0, misaligned, or name_len out of range |
| `0xFFFFFC51` | `DRV_REG_SIG_FAIL` | `driver_sig_verify_algo` returned any `SIG_BAD_*` or `SIG_UNVERIFIABLE` |
| `0xFFFFFC52` | `DRV_REG_HASH_MISMATCH` | BLAKE3(binary) != manifest.signed_blake3 |
| `0xFFFFFC53` | `DRV_REG_NAME_IN_USE` | a BOUND or ROLLBACK_PENDING row already carries this name |
| `0xFFFFFC54` | `DRV_REG_ENOSPC` | all 32 slots occupied |
| `0xFFFFFC55` | `DRV_REG_WRONG_KIND` | cap's `kind` is not `KIND_DRIVER` (or `KIND_ROLLBACK_TOKEN` on rollback paths) |
| `0xFFFFFC56` | `DRV_REG_ROW_CORRUPT` | `row_checksum` mismatch; row quarantined |
| `0xFFFFFC57` | `DRV_REG_ROLLBACK_IN_PROGRESS` | `rollback_token_id != 0` and operation requires it to be zero |
| `0xFFFFFC58` | `DRV_REG_NOT_FOUND` | lookup miss (lookup paths only — index 0 is a legitimate hit) |
| `0xFFFFFC59` | `DRV_REG_BAD_NAME` | name_len == 0 or > 16 |
| `0xFFFFFC5A` | `DRV_REG_BAD_STATE` | row's status does not permit the requested transition |
| `0xFFFFFC5B` | `DRV_REG_ROLLBACK_FORBIDDEN` | `manifest.flags.ROLLBACK_ALLOWED == 0` |
| `0xFFFFFC5C` | `DRV_REG_NO_STAGED` | no staged manifest in the attic for the requested version |
| `0xFFFFFC5D` | `DRV_REG_TOKEN_EXPIRED` | token's generation does not match row's generation |
| `0xFFFFFC5E` | `DRV_REG_TEARDOWN_FAIL` | `teardown_fn` returned non-zero |
| `0xFFFFFC5F` | `DRV_REG_ENOCRYPTO` | scaffold-epoch guard: real signing requested but `paideia_root_pk` not provisioned |

Success is universally `0`. The 16-code block covers every failure mode above with one code to spare; the standard `INVOKE_UNSUPPORTED` (`0xFFFFFFFFFFFFFFFC`) and `INVOKE_DENIED` (`0xFFFFFFFFFFFFFFFD`) are the dispatch-layer sentinels that take precedence over any DRV_REG code when the cap itself is wrong-kinded or short on rights.

---

## 8. Coupling to the rest of the kernel

- **`driver_table.pdx`** — the registry row's `cap_holder_slot` names a `KIND_PROCESS` slot. The driver process is the live writer side of `_driver_table`'s `lifecycle_state`; the registry is upstream of that. A driver that is BOUND here but has no running process is `_driver_table.state == INIT` + a bind that completed its structural work but has not yet reached `Running`.
- **`sig_verify.pdx`** (R29.M4-001) — `driver_sig_verify_algo` is called verbatim from `_bind` and `_commit_rollback`. The verdict codes are the only inter-module contract; no byte of this module reaches into `sig_verify.pdx`'s internals.
- **`keyring.pdx`** (R29.M4-004) — `paideia_root_pk` is fetched via a (future, R32) `driver_keyring_root_pk()` entry. Until then the scaffold-epoch gate accepts the all-zero signature without consulting the keyring.
- **`registry-v2.md`** (R29.M3, on-disk) — this registry's `name` field is byte-identical to the on-disk registry's `name` field; a supervisor cross-references them at every bind to enforce `name` ∈ entitled set. The enforcement path lives in the supervisor, NOT in this kernel module.
- **`driver-cap.md`** — `KIND_DRIVER` + `R_DRIVER_*` are reused as-is; this module adds `KIND_ROLLBACK_TOKEN` + `R_ROLLBACK_*` and the design doc delta is captured here, not in `driver-cap.md`.
- **`blob-policy.md` + `firmware-blob-policy.md`** — covers vendor firmware BLOBS. Orthogonal: a driver that requires firmware pulls a signed blob via that path; the DRIVER manifest here records `flags.FIRMWARE_REQUIRED`, nothing more.

---

## 9. Open issues / deferred

- **Attic region shape** — Wave 60 D-TBD. Needs a per-driver append-only durable log of past manifests + their signatures, with the same signed-at-rest discipline as `registry-v2.md`. Blocks `_begin_rollback` real body.
- **Teardown-fn signature** — `fn (cap_slot: u64) -> u64`? Takes which args? Deferred until a real driver (D15 HDA) exercises it; the skeleton stores a function pointer but never calls it.
- **Supervisor-side cap migration** — out of scope for the kernel registry; needs a design doc of its own in `design/drivers/supervisor-cap-migration.md` (not yet written).
- **Row-checksum algorithm** — xorshift mirrors `registry-v2.md §4 fsck`. Not cryptographic; a stronger choice (BLAKE3-truncated-64) is possible but costs cycles on every lookup. Deferred.
- **Live-manifest patching** — a driver that wants to narrow its own `kinds_provided` without a full rollback would need a `_narrow_manifest(cap, new_kinds_provided)` entry. Nice-to-have; not blocking.
- **SMP safety** — this skeleton is single-flow pre-scheduler-bringup. The registry row's generation counter will double as the seqlock sequence when SMP lands (same pattern as `registry_v2.pdx §8.2`). Deferred to R29.M7.
- **Chaos integration** — `driver/chaos.pdx` (R29.M6) will add cases for mid-rollback crash recovery. Deferred.

---

## 10. Witness (deferred — follow-up slice)

The follow-up slice lands a boot witness `drv_registry_witness` in `kernel_main.pdx` that:

1. Submits three test manifests through `_bind` (uart-16550, hda, nvme-pcie placeholder).
2. Verifies each row's checksum, generation, and status.
3. Looks up each by name via `_lookup`; asserts round-trip.
4. Begins a rollback on `hda`; verifies the staged version in `target_ptr`; aborts.
5. Begins a rollback on `hda`; commits with staged artifact; verifies generation bump + status cycle.
6. Unbinds all three; verifies manifest + signature regions are zeroed.
7. Emits the five fingerprint tags in order; the golden at `tests/fingerprints/drv_registry.golden` is the match.

The golden shipped with this skeleton is the three-tag prefix (`DRV REG OK` + `DRV SIG OK` + `DRV ROLLBACK BEGIN`) — enough to anchor the follow-up slice's regex generation while leaving the full seven-tag sequence to that slice.
