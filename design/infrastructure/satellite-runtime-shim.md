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

**Owner:** `paideia-as` workspace. The crypto crate itself
(`paideia-as-crypto`) remains a pure `no_std + alloc` **rlib**; the
satellite-linkable archive is produced by a distinct wrapper crate
(`paideia-satellite-runtime`) that consumes the crypto rlib as a
path dep. See the 0.29.1 restructure entry in `CHANGELOG.md`.

**Physical change:** `paideia-as-crypto`'s `[lib] crate-type` stays
`["rlib"]`. A separate crate `paideia-satellite-runtime` sets
`crate-type = ["staticlib"]` and depends on `paideia-as-crypto` via
`path = "../paideia-as-crypto"`. Cargo consequently emits
`target/release/libpaideia_satellite_runtime.a` carrying the crypto
FFI thunks (re-exported at Rust level via `pub use`), the fail-closed
mldsa65 stub, AND the small no_std runtime infrastructure the Rust
compiler demands of every staticlib crate — `#[global_allocator]`,
`#[panic_handler]`, and a `rust_eh_personality` stub. The kernel
build continues to consume `paideia-as-crypto` as an rlib; satellites
consume the wrapper archive.

**Why not emit both rlib and staticlib from `paideia-as-crypto`
directly?** Attempted in 0.29.0/0.29.1; failed at compile time.
Emitting a bare staticlib forces the Rust compiler to require
`#[global_allocator]` + `#[panic_handler]` + `panic = "abort"` inside
the crate producing the staticlib — decisions that belong to the
final ELF, not to a leaf crypto library. The corrected shape puts
those runtime pieces in the wrapper crate where they belong.

**Rationale for a single source of truth:** ChaCha20-Poly1305 (RFC
8439) and Argon2id (RFC 9106) are wire-defined — but only up to a
correct implementation. Any divergence between a "kernel body" and a
"satellite body" would silently break the cross-domain readback
contract (`mkfs --encrypt` on the host, `mount` in the kernel).
Reusing the same rlib crate under both link paths — kernel rlib
consumer directly, satellite via the wrapping staticlib — reduces
that risk to zero at negligible engineering cost. Cargo's dependency
graph enforces the invariant: there is exactly one Rust source of
the AEAD and Argon2id bodies in the workspace, and both link paths
draw from it.

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
  `crates/paideia-satellite-runtime/` with `src/lib.rs` (re-exports
  + fail-closed `mldsa65_sign_runtime_entry` + no_std runtime
  infrastructure: bump allocator, panic handler, eh_personality stub)
  and `Cargo.toml` (crate-type staticlib, minimal deps — just the
  path dep on `paideia-as-crypto`).
- **Artifacts published under `tools/paideia-as/target/release/`:**
  - `libpaideia_satellite_runtime.a` — the single satellite-linkable
    archive. Carries the three crypto FFI thunks (re-exported via
    `pub use` at Rust level, so `ld` sees exactly one definition of
    each — the original `#[unsafe(no_mangle)]` in
    `paideia-as-crypto::ffi`), the fail-closed
    `mldsa65_sign_runtime_entry`, and the small no_std runtime pieces
    (bump allocator + `#[panic_handler]` + `rust_eh_personality`).
    No separate `libpaideia_as_crypto.a` is emitted — the crypto
    crate is rlib-only and its object code reaches satellites only
    through the wrapping staticlib.
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

- **Userspace safety (post-0.29.1 refactor, second pass):** the
  crypto crate depends only on `argon2`, `chacha20poly1305`,
  `thiserror`. All three are pure-Rust and support `no_std + alloc`
  when their default features are turned off — which is the shape
  `paideia-as-crypto` pins in its own `Cargo.toml`. Under
  `#![cfg_attr(not(test), no_std)]` the compiled rlib carries no
  `std` / libc / `_Unwind_*` scaffolding; CPUID feature detection in
  `rng::hardware` is done via hand-rolled
  `core::arch::x86_64::__cpuid` / `__cpuid_count` (RDRAND: leaf 1 ECX
  bit 30; RDSEED: leaf 7 sub-0 EBX bit 18) rather than through
  `std::is_x86_feature_detected!`, matching Intel SDM Vol. 2A §3.2
  table 3-8. The wrapping `paideia-satellite-runtime` staticlib
  adds:
    * A hand-rolled bump allocator over a 4 MiB static byte pool
      (`AtomicUsize`-serialized offset, no free) as
      `#[global_allocator]`. Rationale on the sizing and the
      no-free tradeoff in the module doc comment; short version:
      satellite tools are one-shot processes with a bounded heap
      footprint, and a bump allocator is the smallest thing that
      satisfies the compiler's requirement without adding a Rust
      dep. A `linked-list-allocator` swap behind an off-by-default
      feature is the escape hatch if a future long-running
      satellite needs reclamation.
    * A `#[panic_handler]` that halts the current thread via inline
      `hlt` in an infinite loop. Abort-shape by construction — no
      partial state is committed after a panicked Rust primitive
      returns.
    * An empty `rust_eh_personality` symbol exported via
      `#[unsafe(no_mangle)]` as a defensive stub, in case a
      non-lockstep toolchain revision emits a `.eh_frame` FDE
      referencing it. `panic = "abort"` at the workspace release
      profile ensures the compiler does not itself emit unwind
      tables that would call the personality routine.
  **This was not the starting posture.** The 0.29.0 landing added
  `crate-type = ["rlib", "staticlib"]` to `paideia-as-crypto` on the
  assumption that the crate was already `no_std + alloc`. The
  0.29.1 first pass fixed the `no_std + alloc` claim but kept the
  dual crate-type on the crypto crate, which then failed to
  compile: emitting a bare staticlib forces the compiler to require
  `#[global_allocator]` + `#[panic_handler]` + `panic = "abort"`
  inside the emitting crate, and those decisions do not belong to a
  leaf crypto library. The 0.29.1 second pass (this section)
  moved the staticlib emission (and the three runtime pieces) to
  `paideia-satellite-runtime`, leaving `paideia-as-crypto` as an
  rlib-only build. Load-bearing distinction: the underlying
  requirement is a **link-time correctness** constraint for
  satellite `-nostdlib` builds, not the archive-size concern §9
  previously labelled it. The satellite-runtime crate declares no
  additional Rust dependencies of its own (deliberately NO `ml-dsa`;
  see §3.2 for the rationale — the current fail-closed satellite
  stub returns `PDX_MLDSA_ERR_NO_SIGNER = -6` without touching any
  signer library). No kernel primitive, no OS-specific syscall.
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
   compatibility; keep the crate `crate-type = ["rlib"]` (i.e. do
   NOT emit a staticlib from this crate — see §3.1 rationale). No
   crypto-crate `.a` is emitted; the satellite-linkable archive is
   produced downstream by `paideia-satellite-runtime`. Version bump
   paideia-as → 0.29.0. No paideia-os change yet.
2. **paideia-as** — new crate `paideia-satellite-runtime` per §4.1.
   Same 0.29.0 tag. Reuses (1)'s crypto rlib via a `path` dep, adds
   the fail-closed mldsa65 stub, and provides the no_std runtime
   pieces the Rust compiler requires of every staticlib crate
   (`#[global_allocator]`, `#[panic_handler]`, `rust_eh_personality`).
   Workspace `[profile.release]` gains `panic = "abort"` in the same
   landing (Cargo does not allow `panic` in per-package profile
   overrides).
3. **paideia-os** — bump the paideia-as submodule to 0.29.0 (or
   0.29.1 after the runtime-infrastructure follow-up). Kernel
   build unaffected (rlib path unchanged; release-profile abort
   matches kernel semantics).
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
  Rust rlib (`paideia-as-crypto`) drawn from cargo's dependency
  graph by both the kernel-side consumer (`paideia-as-runtime`) and
  the satellite-side wrapper (`paideia-satellite-runtime`, which
  emits the staticlib satellites actually link against). Divergence
  is physically impossible without editing the shared rlib.
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
- **R5 — Host-toolchain footprint.** After the 0.29.1 refactor
  (second pass) `libpaideia_satellite_runtime.a` is a `no_std +
  alloc` build carrying no libc / std / `_Unwind_*` scaffolding of
  its own; the `#[global_allocator]` (4 MiB bump pool), the
  `#[panic_handler]` (inline `hlt`), and the `rust_eh_personality`
  stub all live inside the wrapper crate itself so satellite ELFs
  need not supply them. Bootstrap-size posture: the archive adds
  ~4 MiB of zero-initialised BSS (the bump pool) plus a few dozen
  bytes of code for the allocator, panic handler, and personality
  stub. `/bin` binaries are already several hundred KB and no
  measured constraint is set; the 4 MiB BSS does not inflate the
  on-disk ELF, only the runtime footprint. Revisit only if
  satellite ELF size or RSS becomes a stated bound.
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
### Retroactively removed from "out of scope" — landed in 0.29.1

- **Removing paideia-as-crypto's `std` dependency.** The 0.28.x
  design pass mislabelled this as an ELF-size-only concern and
  parked it here. That framing was wrong: the crate's `std` linkage
  was a **link-time correctness** blocker for satellite
  `-nostdlib` builds — the archive carried ~80 unresolved libc /
  std / panic / unwind symbols the satellite `ld` line cannot
  satisfy. It is now done — see 0.29.1 `paideia-as-crypto`
  refactor to true `no_std + alloc`.
- **Landing a `#[global_allocator]` inside `paideia-satellite-runtime`.**
  Originally deferred so a satellite that already carries a `malloc`
  (via a C runtime or a custom crt) would not be forced to a
  specific allocator crate by us. That deferral did not survive
  first contact with the Rust compiler: a `no_std` staticlib
  MUST define a global allocator inside the emitting crate; the
  compiler will not defer that decision to the final linked ELF.
  The 0.29.1 second-pass restructure lands a hand-rolled 4 MiB
  bump allocator inside `paideia-satellite-runtime` (see §4.1 for
  the sizing and no-free rationale). A `linked-list-allocator`
  or `dlmalloc` swap behind an off-by-default feature remains a
  future option if long-running satellites need reclamation.
- **Landing `#[panic_handler]` and `rust_eh_personality` inside
  `paideia-satellite-runtime`.** Same underlying constraint as the
  allocator: a `no_std` staticlib MUST define its own panic handler,
  and `panic = "abort"` at the workspace release profile handles
  the eh_personality question (the stub is exported defensively
  regardless). Both landed in the 0.29.1 second-pass restructure.
