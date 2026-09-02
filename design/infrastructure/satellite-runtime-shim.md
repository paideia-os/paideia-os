# Satellite Runtime Shim Architecture

**Wave:** R91 cross-repo (paideia-as + libpdx-audit + paideia-os)
**Status:** design pass (2026-09-02) — mechanical implementation to follow
**Closes:** libpdx-audit#19, paideia-as#1348
**Related:** libpdx-volume#35 (test-dup 'run'), paideia-os satellite-tool /bin seeding pipeline (#1976 / #1977)

## 1. Problem statement

Two independent link-time gaps prevent satellite tools (`mkfs.pdxfs`,
`mount.pdxfs`, `umount.pdxfs`, and future `fsck.pdxfs`/`pkg.paideia-os`)
from producing a runnable ELF on the host toolchain:

- **libpdx-audit#19** — every satellite ships an `audit_wire.o` that
  calls `audit_begin` and `audit_commit` as bare cross-module labels;
  no object on the satellite link line supplies these symbols. The
  kernel resolves them from libpdx-audit's own `audit_client.pdx`,
  which in turn calls `AuditBroker::audit_send_record` →
  `sys_ipc_send` (a kernel syscall). Nothing satisfies the satellite
  link.
- **paideia-as#1348** — `paideia-as` declares four FFI intrinsics as
  external symbols: `paideia_crypto_argon2id_derive`,
  `paideia_crypto_chacha20_poly1305_seal`,
  `paideia_crypto_chacha20_poly1305_open`,
  `mldsa65_sign_runtime_entry`. Implementations exist in the Rust
  crates `paideia-as-crypto` and `paideia-pq-sign`, but only the
  paideia-os kernel build ever links them; the satellite host build
  has no archive to draw from.

Both build to `.o` cleanly. Both fail at the final `ld` step.

## 2. Reference-discipline preflight

Two on-tree facts contradict the issue titles and must be honoured over
the prose (per the project's spec-vs-codebase-conflicts discipline):

- `audit_begin`'s real signature is `(op_name_ptr, op_args_ptr) → u64`
  (source: `libpdx-audit/src/audit_client.pdx` line 83, verified
  against `mkfs.pdxfs/src/audit_wire.pdx` call sites). The issue-19
  title says `(kind, actor, subj) → handle`; that shape does not
  exist and no consumer emits calls in that form.
- `audit_commit`'s real signature is `(audit_id, exit_code) → u64`.
  The issue's "handle, body0, body1, body2" prose likewise
  contradicts every landed consumer.

The shim MUST expose the signatures the ELFs already emit CALL
relocations against. A shim matching the issue prose would leave the
underlying links unsatisfied.

The four crypto/sign FFI symbols are already implemented and verified
as `#[no_mangle] pub unsafe extern "C" fn` in
`paideia-as-crypto/src/ffi/mod.rs` and `paideia-pq-sign/src/ffi.rs`.
The gap is packaging, not correctness — both crates are pure-Rust,
userspace-safe wrappers around the `argon2`, `chacha20poly1305`, and
`ml-dsa` upstream crates. No kernel primitive is required.

## 3. Owner and shape decisions

### 3.1 Crypto shim (Argon2id + ChaCha20-Poly1305)

**Owner:** `paideia-as` workspace, in-place extension of the existing
`paideia-as-crypto` crate.

**Physical change:** add `crate-type = ["rlib", "staticlib"]` to the
`[lib]` stanza (currently implicit rlib). Cargo's second build target
emits `target/release/libpaideia_as_crypto.a`. The kernel build
continues to consume the rlib exactly as today; satellites consume the
staticlib.

**Rationale for a single source of truth:** ChaCha20-Poly1305 (RFC
8439) and Argon2id (RFC 9106) are wire-defined — but only up to a
correct implementation. Any divergence between a "kernel body" and a
"satellite body" would silently break the cross-domain readback
contract (`mkfs --encrypt` on the host, `mount` in the kernel).
Reusing the same crate as both `.rlib` and `.a` reduces that risk to
zero at negligible engineering cost.

**Alternative rejected:** a bespoke satellite `paideia-satellite-crypto`
crate. Rejected because two crates encoding the same RFCs will
eventually diverge on defaults (Argon2id parameter constants, AEAD
tag placement).

### 3.2 Sign shim (mldsa65_sign_runtime_entry)

**Owner:** new `paideia-satellite-runtime` crate under
`paideia-as/crates/`, deliberately kept separate from `paideia-pq-sign`.

**Rationale for separation:** `paideia-pq-sign`'s `Cargo.toml` pulls
in `yubihsm = "0.42"`, `cryptoki = "0.7"`, and `reqwest = "0.12"`.
Producing a satellite staticlib from that crate would drag
OpenSSL, libssh2, and native PKCS#11 libraries onto every satellite
ELF's dependency closure — unacceptable for tools that ship into
`/bin` on a bootstrap system.

**Sign posture (per issue #1348 §Fix and the on-tree consumer scan):**
- `mkfs.pdxfs`, `mount.pdxfs`, `umount.pdxfs` do NOT sign at runtime.
  `pdxb_sign_superblock` is defined in libpdx-volume but reached only
  from tools that pass a `--sig-key` pointing at a PRIVATE seed;
  `mkfs.pdxfs`'s own default is the PUBLIC key (used only to
  compute `sig_key_hash` via BLAKE3). The mldsa65 symbol must
  RESOLVE at link time (`ld` has no dead-code elimination at .o
  granularity) but is never CALLED at runtime.
- Therefore: a fail-closed stub returning
  `PDX_MLDSA_ERR_NO_SIGNER = -6` (new code, band-consistent with the
  existing `-1..-5` in `ffi/mod.rs`) satisfies the current satellite
  cascade. If a future signing satellite lands (e.g. `fsck.pdxfs`,
  `pkg.paideia-os`), it links against the full `paideia-pq-sign`
  staticlib instead, produced from the same crate with
  `crate-type = ["rlib", "staticlib"]` and a `no-hsm` feature flag
  that gates the reqwest/yubihsm/cryptoki dependencies out.

**Consequence for libpdx-volume:** `pdxb_sign_superblock` MUST surface
`PDX_MLDSA_ERR_NO_SIGNER` upward as a user-visible error rather than
silently skipping. This is a one-line propagation check inside
`pdxb_sign.pdx`, tracked as a follow-up under libpdx-volume rather
than gating this shim.

### 3.3 Audit shim (audit_begin / audit_commit)

**Owner:** `libpdx-audit` repo, in-place addition of a satellite
broker variant.

**Physical change:** add two new `.pdx` modules alongside the existing
audit_broker.pdx / syscall_shim.pdx:

- `src/audit_broker_satellite.pdx` — provides `audit_send_record` with
  the same signature the kernel broker exposes, but routes to a
  host-callable path instead of `sys_ipc_send`.
- `src/syscall_shim_satellite.pdx` — provides `sys_getpid` (needed by
  `audit_begin`'s pid composition) as a thin trampoline over the
  Linux `getpid(2)` SYSCALL number 39; the other kernel syscalls
  (`sys_svc_lookup`, `sys_ipc_send`) are unreferenced by the
  satellite broker and MUST NOT be resolved.

The reused-verbatim modules are `audit_client.pdx`, `audit_record.pdx`,
and `audit_hash.pdx`. The three-call state machine, the wire format,
and the pid-composed audit id all remain identical to the kernel
build. This is the point: a satellite audit record is bit-compatible
with a kernel one, so a future kernel-side satellite-audit syscall
(follow-up filed against paideia-os) can absorb these records without
reformatting.

**Audit posture (per the D3 audit-first pillar):**

The pillar requires every operation to journal before emitting
user-visible output. A no-op stub violates D3, so two build modes
are provided:

- **Default (`AUDIT_MODE=stderr`)**: `audit_send_record` writes each
  256-byte wire record to fd 2 as one line of hex-framed JSONL,
  prefixed by `PDXAUDIT ` for grep-ability. This lets satellite runs
  produce a real audit trail on the host during development.
- **Smoke-test (`AUDIT_MODE=off`)**: `audit_send_record` returns
  `AUDIT_OK` immediately without side effect. Reserved for automated
  smoke tests that want to elide audit noise.

The mode is chosen once at process start via one env-var read in
`syscall_shim_satellite.pdx` and cached in `.bss`. No per-call cost.

A follow-up (**libpdx-audit#20**, to file after this shim lands) will
add `AUDIT_MODE=file` writing to `$XDG_STATE_HOME/paideia/tool-audit.jsonl`.

## 4. Physical shape

### 4.1 Crypto/sign shim

- **Repo:** `paideia-as` (github.com/paideia-os/paideia-as)
- **New files:** none in `paideia-as-crypto/`; one new crate
  `crates/paideia-satellite-runtime/` with `src/lib.rs` (re-export
  + fail-closed `mldsa65_sign_runtime_entry`) and `Cargo.toml`
  (crate-type staticlib, minimal deps).
- **Artifacts published under `tools/paideia-as/target/release/`:**
  - `libpaideia_as_crypto.a` — the three crypto symbols.
  - `libpaideia_satellite_runtime.a` — re-exports the crypto three
    (via `pub use` at Rust-level so `ld` finds one definition) plus
    the fail-closed `mldsa65_sign_runtime_entry`.
- **Symbol signatures (SysV x86_64):**

  ```
  paideia_crypto_argon2id_derive(
      rdi = *const Argon2idParamsC,   // 80-byte C struct
      rsi = *mut u8,                  // out_ptr
      rdx = usize                     // out_len
  ) -> i64                            // rax: 0 OK, -1..-5 error
  paideia_crypto_chacha20_poly1305_seal(
      rdi = *const AeadParamsC,       // 32-byte C struct
      rsi = *const u8, rdx = usize,   // plaintext
      rcx = *mut u8,  r8  = usize,    // out buffer + cap
      r9  = *mut usize                // bytes written
  ) -> i64
  paideia_crypto_chacha20_poly1305_open(same shape)
  mldsa65_sign_runtime_entry(
      rdi = *const u8,                // 32-byte seed
      rsi = *const u8, rdx = usize,   // message
      rcx = *mut u8                   // sig_out, >= 3309 bytes
  ) -> i64                            // -6 always in satellite build
  ```

  These are verified against the on-tree `#[no_mangle] extern "C"`
  definitions; the shim MUST NOT re-derive them.

- **Userspace safety:** confirmed. The crypto crate depends only on
  `argon2`, `chacha20poly1305`, `thiserror`; all pure-Rust, `no_std +
  alloc`. The satellite-runtime crate depends only on `ml-dsa` (for
  when the full-signer variant is toggled on) plus the crypto
  re-export. No kernel primitive, no OS-specific syscall.
- **Satellite consumption:** `tools/build.sh` gains `--extra-archive
  PATH` (repeatable). Invocation: `bash tools/build.sh --extra-obj-dir
  ../libpdx-volume/build-out --extra-archive $PAS_TARGET/libpaideia_satellite_runtime.a`.
  `PAS_TARGET` resolves the same way `paideia-as` itself is resolved
  (env var → sibling checkout → `$HOME/Development/PaideiaOS/...`).

### 4.2 Audit shim

- **Repo:** `libpdx-audit`.
- **New files:** `src/audit_broker_satellite.pdx`,
  `src/syscall_shim_satellite.pdx`.
- **Build change:** `tools/build.sh` gains `--profile={kernel,satellite}`
  (default `kernel` to preserve today's behaviour). The satellite
  profile compiles the satellite variants of `audit_broker` /
  `syscall_shim` instead of the kernel ones; both profiles share the
  other three modules unchanged. Satellite output:
  `build-out/libpdx-audit-satellite.a` (archive, not loose `.o`,
  so `ld --gc-sections`-style symbol pruning can drop unused entry
  points).
- **Symbol signatures:** unchanged — `audit_begin`, `audit_record_output`,
  `audit_commit`, `audit_set_parent`, `audit_last_error`,
  `audit_broker_failure_cause`. All are bare labels emitted by
  `.pdx` compilation of `audit_client.pdx`, exactly matching what
  every satellite's `audit_wire.pdx` currently `call`s.
- **Userspace safety:** the satellite broker's only host syscalls are
  `write(2)` (fd 2) and `getpid(2)`; both are unprivileged and always
  available.
- **Satellite consumption:** `bash tools/build.sh --extra-archive
  ../libpdx-audit/build-out/libpdx-audit-satellite.a ...` alongside
  the runtime shim.

## 5. Order of landings

Dependency-aware sequence. Each step is a distinct PR / issue closure.

1. **paideia-as** — audit `paideia-as-crypto` for `no_std` + `alloc`
   compatibility if not already, then add `crate-type = ["rlib",
   "staticlib"]`. Runs alongside a new smoke test that links a tiny
   C program against the staticlib. Version bump paideia-as →
   0.29.0. No paideia-os change yet.
2. **paideia-as** — new crate `paideia-satellite-runtime` per §4.1.
   Same 0.29.0 tag. Reuses (1)'s crypto crate; drops in the
   fail-closed mldsa65 stub.
3. **paideia-os** — bump the paideia-as submodule to 0.29.0. Kernel
   build unaffected (rlib path unchanged).
4. **libpdx-audit** — land the two new `.pdx` modules and the
   `--profile=satellite` build path per §4.2. Version 1.1.0.
   Zero kernel-side change; existing kernel build's default profile
   preserves current behaviour.
5. **Satellite build.sh cascade** — add `--extra-archive PATH` to
   `mkfs.pdxfs`, `mount.pdxfs`, `umount.pdxfs`, and `libpdx-volume`
   (for its own smoke run). Version each to +0.0.1. Wire the two
   archives in as the final link inputs. These are trivially
   parallelizable and can land as one batched PR per satellite.
6. **libpdx-volume** — one-line propagation in `pdxb_sign.pdx` to
   surface `PDX_MLDSA_ERR_NO_SIGNER` upward as a user-visible error
   (§3.2 consequence). Version 1.1.3.

Steps 1–3 are strictly ordered (each depends on the previous).
Step 4 is independent of 1–3 and could run in parallel. Step 5
depends on both. Step 6 depends only on 2 and is a small
adversarial-safety fix rather than a link fix.

## 6. libpdx-volume cross-check

**No source-level change required.** `pdxb_crypto.pdx` and
`pdxb_sign.pdx` emit CALL relocations against the four FFI intrinsics
via the elaborator's `stdlib_lowering::cryptoops` /
`stdlib_lowering::mldsaops` recipes. Whether those relocations
resolve to the kernel bodies (via `paideia-as-runtime` rlib) or to
the satellite bodies (via `libpaideia_satellite_runtime.a`) is a
pure link-time decision. The `.o` files are identical.

The one small follow-up per §3.2 (surface `NO_SIGNER` upward) is a
correctness cleanup, not a build gate.

## 7. Milestone recommendation

Recommend a new cross-repo milestone shared across paideia-as,
libpdx-audit, and paideia-os: **R91-XREPO.M1 Satellite Runtime Shim**,
grouping issues paideia-as#1348, libpdx-audit#19, and the four
satellite-repo companion tickets (build.sh extensions, libpdx-volume
NO_SIGNER surfacing).

This does not fit inside R89.M1 (KIND_TUI_CANVAS, actively landing)
or R90-XREPO (syscall-table refresh cascade, already closed). It is
naturally distinct from either — a link-line fix wave, not a kernel
capability wave — and closing it unblocks smoke-runs for the entire
`/bin` seeding pipeline.

## 8. Architectural risks

- **R1 — Byte-match on cross-domain volumes.** If satellite crypto
  and kernel crypto ever diverge, a volume `mkfs`'d on the host is
  unreadable by the kernel-side `mount`. **Mitigation:** single
  Rust crate emitting both `.rlib` and `.a` (§3.1). Divergence is
  physically impossible without editing the shared crate.
- **R2 — Symbol version drift.** Satellite `.a` shipped by an older
  paideia-as could disagree with a newer paideia-as-emitted `.o`
  on struct layout (e.g. `Argon2idParamsC` field order). **Mitigation:**
  tag the staticlib output with the paideia-as workspace version;
  satellite `build.sh` refuses to link if the archive's embedded
  version disagrees with the `paideia-as --version` producing the
  `.o` files. Enforce via a small `.paideia_version` note-section
  in the archive; softarch pass to specify the exact mechanism.
- **R3 — D3 audit-first pillar erosion.** Default satellite audit
  mode MUST journal, not no-op (§3.3). Flag any future
  `AUDIT_MODE=off` slippage in reviews.
- **R4 — Fail-closed signer masquerading as success.** If
  `pdxb_sign_superblock` swallows `NO_SIGNER` and returns
  `LPV_OK`, the produced volume claims to be signed while being
  unverifiable. **Mitigation:** the §3.2 one-line propagation must
  land in the same wave as the shim; softarch to verify with a
  targeted test.
- **R5 — Host-toolchain footprint.** `libpaideia_as_crypto.a` will
  carry compiler-rt / core::panic scaffolding into every satellite
  ELF. Acceptable for bootstrap (`/bin` binaries are already several
  hundred KB). Revisit only if satellite ELF size becomes a
  measured constraint.
- **R6 — Satellite/kernel wire divergence in audit.** The satellite
  broker writes wire records to stderr; the kernel broker sends them
  to `svc.audit-journal`. Both use the SAME 256-byte payload shape
  from `audit_client.pdx`, so a future kernel-side "absorb satellite
  audit trails" syscall can ingest satellite JSONL verbatim. Flag
  in review if anyone proposes a satellite-specific wire shape.

## 9. Out of scope

- A real kernel-side satellite-audit syscall (would let satellites
  emit into `/system/audit/user-events/` via a proper channel);
  filed as follow-up under paideia-os.
- `AUDIT_MODE=file` (host-journal) — libpdx-audit#20 follow-up.
- Full `paideia-pq-sign` staticlib (for real signing satellites);
  gated behind the arrival of the first signing satellite tool.
- Removing paideia-as-crypto's `std` dependency (if it currently
  has one); tracked separately if a satellite ELF size limit is
  ever set.
