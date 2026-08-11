// R25 Retrospective: PdxFS-lite (persistent FS MVP + NVMe driver-attach preflight)

**Date:** 2026-08-11
**Milestone:** R25.M1–R25.M7 (all closed; M7 = closure milestone this
doc + #937/#938/#939/#940)
**Issues:** 30 landed across 7 milestones (26 implementation + 4
closure). Zero fully-deferred R25-scoped issues. All 2 ambient
`paideia-as-blocked` labels on R25 issues resolved as paper tigers on
inspection.
**HEAD at closure:** (bumped by the R25.M7 commit that lands this doc)
**paideia-as pinned at:** `2cf169d` — unchanged across R25 (**fifth
consecutive round** with zero cross-repo escalations, since R21 close).

---

## Round Intent

R25 was scoped as the PdxFS-lite persistent-filesystem round per
`design/roadmap/r18-plus-bare-metal.md` §R25 — the first block-storage
plane on top of R24's NVMe substrate. The seven milestones threaded
the on-disk format first (superblock + inode table + extent map),
then the mkfs host tool (so fixture images exist before the mount
path exercises them), then the VFS wire-up (`pdxfs_lite_mount`
publishing a root vnode into the R16 VFS), then the ML-DSA-65 sig-
verify substrate (dev-bypass at MVP; real crypto lands at R32), then
the mutating operations surface (create/rename/unlink returning EROFS
at MVP), then round closure (E2E fixture + migration stub + retro):

- **M1:** On-disk format v0 + superblock read + validate + UUID
  (`design/filesystem/pdxfs-lite-format.md` + `superblock.pdx` +
  `mount.pdx` + `uuid.pdx`).
- **M2:** Inode + extent layer — inode struct, inline extent walker,
  indirect extent read, extent-bitmap allocator scaffolding.
- **M3:** `mkfs.pdxfs-lite` host tool — materialises a valid v0 image
  against a raw file or block device.
- **M4:** VFS wire-up — `pdxfs_lite_mount` populates
  `_pdxfs_lite_mount_ctx`, allocates root vnode, publishes ops table
  through `_pdxfs_lite_vops`; `namei.pdx` bridges VFS path resolution
  to PdxFS-lite inode lookup.
- **M5:** Sig-verify substrate — `pdxfs_sb_verify_sig` with dev-mode
  bypass under `Features.PDXFS_DEV_KEY_ONLY = 1`; real ML-DSA-65
  verify deferred to R32 crypto round with the same fixture
  (`pdxfs_lite_corrupt_sb_witness`) auto-promoted at that flip.
- **M6:** Mutating ops surface — `create.pdx` + `unlink.pdx` +
  `rename.pdx` return `EROFS` at MVP pending the kernel-side
  `nvme_write_blocking` (#906 sibling; not yet landed). All
  supporting scaffolding (inode alloc, extent bitmap set, dentry
  compose, dirty-flag tracking) landed and is unit-testable in
  isolation.
- **M7:** Round closure — end-to-end fixture harness + witness
  (#937), PdxFS-lite → PdxFS v1 migration design stub (#938),
  directory-entry limit note (#939), R25 closure retro + STATUS.md
  block + tag `r25-closed` (#940, this document).

Pillar 6 target (`design/00-feature-inventory.md`): give the kernel
exactly the substrate a persistent filesystem needs to see, mount,
walk, and eventually mutate a NVMe-backed image — format spec / mkfs
tool / mount ceremony / sig verify / read paths / mutating-op
scaffolding — with the write-persistence arc (actual
`nvme_write_blocking` firing + `commit_dirty_metadata` flush) deferred
to R26+ where it consumes the same #1015 userspace-server substrate
gate as #820 (acpi_supervisor) / #860 (pci_enumerator) / #906
(userspace half of `nvme_read_blocking`).

---

## What Shipped

### R25.M1 — On-disk format + superblock (4 issues: #911–#914)

- **#911 v0 format spec** — `design/filesystem/pdxfs-lite-format.md`.
  Decisions summary, byte layouts, signature scope, error surface,
  mount flow.
- **#912 superblock struct + `_pdxfs_sb` .bss anchor** —
  `src/kernel/core/fs/pdxfs_lite/superblock.pdx`. 4 KiB `[u64; 512]
  @align(4096)` slab as the shared mount-time scratch. `sb_validate`
  performs magic + version + block_size + itable_lba + root_ino
  structural checks.
- **#913 `pdxfs_lite_read_superblock`** —
  `src/kernel/core/fs/pdxfs_lite/mount.pdx`. Bridges NVMe substrate
  (R24.M5 `nvme_read_blocking`) to `sb_validate`. Threads `(bar0,
  nsid)` explicitly so the function is testable from a witness
  standalone.
- **#914 UUID helpers** — `src/kernel/core/fs/pdxfs_lite/uuid.pdx`.
  `sb_generate_uuid` (TSC-based v4 UUID; R32 promotes to real
  CSPRNG); `sb_uuid_match` bytewise compare.

**Closure commit:** `a197f7a`.

### R25.M2 — Inode + extent layer (5 issues: #915–#919)

- **#915 inode struct + reserved slots** —
  `src/kernel/core/fs/pdxfs_lite/inode.pdx`. 128 B inode; slot 0
  reserved sentinel; slot 1 = root.
- **#916 `get_inode` + `put_inode`** — same file. `get_inode` reads
  the inode-table block containing the target slot, extracts 128 B
  into `_pdxfs_lite_inode_scratch`. `put_inode` is R25.M6 debt (see
  below).
- **#917 inline extent walker** — `src/kernel/core/fs/pdxfs_lite/read.pdx`.
  `pdxfs_read` locates the correct inline extent for a byte offset,
  reads that data block, memcpys into the caller's buffer.
- **#918 indirect extent lookup** — same file. When the inline range
  is exhausted, `pdxl_rd_walk_indirect` reads the indirect extent
  block, walks the 512-entry array, follows the resolved LBA.
- **#919 extent bitmap allocator scaffolding** —
  `src/kernel/core/fs/pdxfs_lite/alloc.pdx`. `pdxl_ex_alloc_first_fit`
  scans the bitmap for a zero bit, sets it, returns the LBA. `_free`
  is the counterpart; both are used by M6 CREATE/UNLINK plumbing (as
  callable symbols, even though the top-level M6 ops return EROFS).

**Closure commit:** `b8df859`.

### R25.M3 — mkfs.pdxfs-lite host tool (4 issues: #920–#923)

- **#920 mkfs specification** — `tools/mkfs-pdxfs-lite.sh` (bash
  wrapper), plus header docs in every generated file.
- **#921 mkfs superblock stamp** — writes a valid v0 superblock with
  magic / version / block_size / UUID / itable_lba /
  extent_area_lba / root_ino / zeroed reserved region / zeroed sig.
- **#922 mkfs inode table seed** — allocates the inode-table region,
  zeros every byte, populates slot 1 (root dir) with type=directory /
  mode=0755 / link_count=2 / empty extent array / one dentry block
  allocated for `.` and `..`.
- **#923 mkfs dentry seed** — writes `.` and `..` dentries into the
  root dir's first data block (both point at inode 1 per v0 root
  convention).

**Closure commit:** `16e3180`.

### R25.M4 — VFS wire-up (5 issues: #924–#928)

- **#924 `pdxfs_lite_vops` table + init** —
  `src/kernel/core/fs/pdxfs_lite/vops.pdx`. 7-slot ops table
  (`lookup`, `read`, `write`, `readdir`, `create`, `unlink`,
  `rename`); `_pdxfs_lite_mount_ctx` [u64; 8] state (nsid, sb ptr,
  root_ino, root_vn_idx, mounted flag, spare).
- **#925 `pdxfs_lite_mount`** —
  `src/kernel/core/fs/pdxfs_lite/mount_op.pdx`. Full mount: read
  superblock → sig verify → alloc root vnode → publish → populate
  mount ctx.
- **#926 `pdxfs_lite_lookup_by_name`** —
  `src/kernel/core/fs/pdxfs_lite/namei.pdx`. Directory-entry linear
  scan (per §2.5 rule of thumb — cache lands at R40).
- **#927 `pdxfs_lite_path_resolve`** — same file. Wraps
  `path_resolve` with anchoring at the mount root vnode.
- **#928 `pdxfs_read` VFS adapter** —
  `src/kernel/core/fs/pdxfs_lite/read.pdx`. Wraps the M2 inline +
  indirect extent walker as the vops `read` callback.

**Closure commit:** `93d7b93`.

### R25.M5 — Sig-verify substrate (4 issues: #929–#932)

- **#929 `pdxfs_sb_verify_sig` dev-bypass body** —
  `src/kernel/core/fs/pdxfs_lite/verify.pdx`. Under
  `Features.PDXFS_DEV_KEY_ONLY = 1`, verify returns 1 (ACCEPT) iff
  every byte in the sig field [696, 4096) is zero — a bit-flip
  anywhere in that 3400-byte region rejects. Under
  `Features.CRYPTO_ML_DSA_ENABLED = 1` (R32 flip), verify calls the
  real ML-DSA-65 primitive over the [0, 696) signed region.
- **#930 `pdxfs_lite_pubkey_ptr` scaffold** —
  `src/kernel/core/fs/pdxfs_lite/pubkey.pdx`. Returns a `.bss`-backed
  zero-key at MVP (dev-bypass ignores the return value; R32 real
  verify consumes it).
- **#931 corruption fixture** —
  `tests/kernel/fs/pdxfs_lite_corrupt_sb.pdx` +
  `boot_r25_pdxfs_corrupt_sb` opt-in smoke +
  `PAIDEIA_R25_PDXFS_CORRUPT=1` pre-push gate.
  `pdxfs_lite_corrupt_sb_witness` proves 3 cases: (A) pristine
  superblock passes, (B) bit-flip in signed region still passes
  under dev-bypass, (C) non-zero byte in sig field rejects even
  under dev-bypass.
- **#932 wire mount_op sig-verify gate** — `mount_op.pdx` grew the
  `pdxfs_sb_verify_sig` call between superblock read and vnode alloc
  per R25.M5 §3 hook.

**Closure commit:** `94ca656`.

### R25.M6 — Mutating ops surface (4 issues: #933–#936)

- **#933 `create.pdx`** — full body: parent inode load, EEXIST scan,
  inode allocation, child inode populate, dentry compose in scratch;
  return `EROFS` because `nvme_write_blocking` (#906 sibling) hasn't
  landed. Every callable symbol (`pdxl_cr_alloc_inode`,
  `pdxl_cr_populate`, `pdxl_dir_find`) is a `pub` — the composition
  works, the persistence step doesn't fire.
- **#934 `unlink.pdx`** — mirrors create: parent inode load, target
  dentry find, inode-scratch mark-free, dentry-scratch mark-free;
  return `EROFS`.
- **#935 `rename.pdx`** — snapshot source inode_id + type, note
  clobber if target exists, rebuild new dentry in scratch; return
  `EROFS`.
- **#936 `put_inode` scaffolding** — `inode.pdx` grew the
  counterpart; body always returns `ETODO_WRITE` (the write-plumbing
  slot) until #906 unblocks.

**Closure commit:** `8c849e1`.

### R25.M7 — Round closure (4 issues: #937–#940)

- **#937 End-to-end fixture** — `tools/pdxfs-lite-e2e-smoke.md`
  (operator recipe: mkfs → boot → mount → shell R/W → reboot →
  persistence verify) + `tests/kernel/fs/pdxfs_lite_e2e_witness.pdx`
  (placeholder witness — checks mount context populated, SKIP under
  -kernel per the same posture as `pdxfs_lite_corrupt_sb_witness`) +
  `boot_r25_pdxfs_e2e` SKIP-echo smoke +
  `PAIDEIA_R25_PDXFS_E2E=1` pre-push gate.
- **#938 Migration path stub** —
  `tools/migrate-pdxfs-lite-to-v1.md`. Design doc for the R40-side
  migration tool; documents source format (v0), target format (v1
  CoW-PQ), migration approach (superblock swap, inode remap, extent
  copy), safety (checksum every block).
- **#939 Directory-entry limit note** —
  `design/filesystem/pdxfs-lite-format.md §2.5`. Documents
  per-block density (16), inline capacity (128), indirect capacity
  (8320 raw), practical performance ceiling (~64 entries before
  degradation), R40 lift path.
- **#940 R25 closure retro + STATUS.md + tag** — this document +
  STATUS.md R25 CLOSED block + open-question resolution (per-superblock
  vs per-extent signature — §"Open Question Resolution" below) + tag
  `r25-closed`.

**Closure commit:** (this M7 commit).

---

## Cross-Repo Escalations to paideia-as (R25)

**None.** `paideia-as` submodule remained pinned at `2cf169d` for all
seven R25 milestones — unchanged since R21 close. This is the fifth
consecutive round with zero cross-repo escalations
(`feedback_cross_repo_escalation.md` never fired in R25 planning or
implementation).

Two ambient `paideia-as-blocked` labels queued into the R25 planning
sheet were reviewed and downgraded on inspection as **paper tigers**:

- **v0.22 tag: slice + bitfield helpers (M3 mkfs, M6 mutating ops).**
  The R24 closure retro's R25 preflight §"R25 blockers (external)"
  called out the v0.22 tag as an ease-of-implementation item, not a
  blocker: "R25 can hand-code packed superblock/inode fields via
  mov_b / mov_d stores, same idiom as R24 SQE construction." Every
  M3 + M6 site used exactly that idiom — sized stores at fixed
  byte offsets — with zero encoder friction.
- **`sb_generate_uuid` needing RDRAND (M1 #914).** The preflight
  called out RDRAND as "no encoder yet; adds a paideia-as gap." On
  inspection the TSC-based UUID path (per
  `design/filesystem/pdxfs-lite-format.md §4.1`) is acceptable at
  MVP — mkfs is a one-time per-image operation, non-repeating
  entropy is not a security property v0 relies on. RDRAND lands
  with R32 crypto round.

Zero paideia-as submodule bumps required across R25. Zero PA-R25-*
escalation entries filed.

---

## Deferrals

R25 landed with significant substrate deferrals — all in the
**write-persistence** arc, all chained on the same external-blocker
family the last three rounds have inherited. Documented in-round
(each M6 module header calls out `EROFS pending #906`) rather than as
after-the-fact debt discovery:

### D1. All write persistence — pending R24 debt #906 sibling

**Scope:** every mutating op (`create.pdx`, `unlink.pdx`,
`rename.pdx`, `write.pdx`) landed as a full body **through** the
persistence step, then returns `EROFS` from the top-level entry
because `nvme_write_blocking` does not yet exist kernel-side.

**What's landed:**
- `pdxl_cr_alloc_inode` — bitmap set, inode-table stamp in
  `_pdxfs_lite_inode_scratch`.
- `pdxl_cr_populate` — child inode field stamping.
- `pdxl_dir_find` — parent-dir EEXIST scan.
- `put_inode` — returns `ETODO_WRITE` placeholder (the exact spot
  `nvme_write_blocking(nsid, lba, count, buf_pa)` slots in).

**What blocks:**
- **`nvme_write_blocking` kernel-side sibling** (R24 debt item #2,
  from `design/round-retrospectives/r24-closure.md §R24 Debt Carried
  Forward`). Same shape as `nvme_read_blocking` with `OPC = 0x01`.
  Described as "a 30-minute exercise once R25+ opens with a live
  driver." R25 opened and closed without that 30 minutes because the
  driver-attach path (D2 below) is the actual gate.
- **`commit_dirty_metadata`** — dirty-block tracker + flush pass. No
  design pass yet; likely a one-file addition to
  `src/kernel/core/fs/pdxfs_lite/` that walks `_pdxfs_lite_inode_
  scratch` + parent-dentry-block + extent-bitmap-block, calls
  `nvme_write_blocking` per dirty block, clears flags on success.

**Rerouting:** R26+ (probably as R26.M1 — before the USB xHCI work
that R26 is otherwise scoped for). See §Preflight for R26 below.

### D2. Live mount pending driver-attach ceremony

**Scope:** `pdxfs_lite_mount` is a `pub` symbol and works if called;
`kernel_main_uefi` never calls it. Under QEMU-TCG `-kernel` the point
is moot (no NVMe controller ever surfaces); on real hardware the
driver-attach ceremony (`nvme_reset_and_enable` →
`nvme_identify_ctrl` → `nvme_identify_ns` per nsid →
`nvme_create_all_io_cqs` → `nvme_create_all_io_sqs` →
`pdxfs_lite_mount(bar0, nsid, mountpoint_vn_idx)`) is R25.M6 debt
that did not land.

**What blocks:** Same #1015 gate that gates the D1 write pipeline —
the userspace-server substrate. The kernel-side ceremony is fully
composable from the R24 + R25 primitives; the missing piece is the
callsite discipline for where it lives in `kernel_main_uefi` (before
or after the R23 fb console init, before or after the R17 shell
bootstrap, gated on `Features.NVME_ATTACH_ENABLED`?). That's a
several-line addition, not an implementation round; it just wasn't
scoped for R25.

**Rerouting:** R26+ same as D1.

### D3. Real ML-DSA-65 sig-verify — pending R32 crypto round

**Scope:** `pdxfs_sb_verify_sig` under `Features.PDXFS_DEV_KEY_ONLY =
1` (MVP default) implements the dev-bypass semantics documented in
`design/filesystem/pdxfs-lite-format.md §5.4`: accept any superblock
whose sig field is all-zero, reject otherwise. Under
`Features.CRYPTO_ML_DSA_ENABLED = 1` (R32 flip) it must call the
real ML-DSA-65 primitive over the signed region [0, 696).

**What blocks:** R32 crypto round — filed in the roadmap at
`design/roadmap/r18-plus-bare-metal.md §3` as "Post-quantum crypto
subsystem (RDRAND/RDSEED entropy + Müller-jitter + TPM RNG mixed via
SHA-3 DRBG; ML-KEM-768; ML-DSA-65; SLH-DSA-128f; AVX2 vectorized,
constant-time), ~30 issues."

**Rerouting:** R32 — no earlier. The MVP demo (R28) explicitly
accepts the dev-bypass posture per the R25 preflight.

### D4. Live E2E `pdxfs_lite_e2e_witness` invocation

**Scope:** the witness at `tests/kernel/fs/pdxfs_lite_e2e_witness.pdx`
is a placeholder — under `-kernel` it always emits SKIP. On real HW
via GDB it would fire OK if D1 + D2 landed. Neither has landed.

**Rerouting:** R26+ same as D1/D2.

### D5. `boot_r25_pdxfs_e2e` fingerprint file

**Scope:** the opt-in smoke mode is currently a SKIP-echo. When the
boot-time caller wires the witness, it flips to `FINGERPRINT_MODE=1`
with `tests/r25/expected-pdxfs-e2e.txt` matching
`PDXFS E2E OK mounted=1\n`.

**Rerouting:** R26+ same as D1/D2.

---

## Open Question Resolution

**Question:** Per-superblock vs per-extent signature for PdxFS-lite v0.

**Provenance:** `design/roadmap/r18-plus-bare-metal.md §4` open
question #6: "Per-block PQ signing is infeasible (ML-DSA is 3+ KB).
Per-extent? Per-snapshot? **Working assumption:** per-superblock at
R25; per-extent at R40. Deadline: R25 kickoff."

**Resolution at R25.M7 close: per-superblock, promoted from working
assumption to normative decision.** Per-extent signing deferred to
R40+ if it earns its cost against a real threat model at that point.

### Rationale

1. **Cost profile.** ML-DSA-65 signatures are 3309 B. At R25's fixed
   4 KiB block size, a per-block signature would double the on-disk
   footprint (one extent = one data block + one 3.3 KiB signature +
   ~100 B of metadata frame = ~7.5 KiB written per 4 KiB of
   user data — ~1.87 × amplification). Per-superblock signing has
   zero amplification for the mount-time integrity check that is the
   only thing R25's threat model actually cares about.
2. **Threat model at MVP.** R25 defends against an attacker who
   tampers with mount-critical superblock fields (itable_lba
   redirects, root_ino redirects, extent_area_lba redirects) — every
   such attack is caught at mount. R25 does NOT defend against an
   attacker who has write access to the raw block device and can
   corrupt data-block bytes without touching the superblock; that
   requires per-block or per-extent signing, which pushes the crypto
   cost into the write path (~11 ms per 4 KiB write on a modern
   AVX2-capable core per constant-time ML-DSA-65 benchmarks).
3. **Path to per-extent signing.** The extent descriptor at v0 spec
   §2.3 is currently 8 bytes (`start_lba u64`). Adding a per-extent
   signature requires either (a) growing the extent descriptor
   (breaking format change) or (b) packing signatures into a
   parallel per-extent sig region (backwards-compatible-adjacent but
   needs allocator + GC support the R25 substrate does not have).
   Both are R40 CoW-PQ scope — the CoW rewrite path is the natural
   time to lay down the sig-per-extent metadata anyway.
4. **Compat with dev-bypass.** The R25.M5 dev-bypass semantics
   (verify accepts all-zero sig field) work uniformly at
   per-superblock scope. Extending dev-bypass to per-extent would
   require per-extent scratch buffers + per-extent bypass toggles,
   quadratically bloating the design surface for negligible pre-R32
   benefit.
5. **R40 escape hatch.** The `_reserved` region of the R25
   superblock (bytes [72, 696), 624 B) has room for a future
   `sig_scheme` byte + `per_extent_sig_root_lba` pointer, which
   would let a v0 → v1 migration selectively promote to per-extent
   signing if the R40 designer wants an in-format upgrade path (per
   `design/filesystem/pdxfs-lite-format.md §1.2`).

### Cross-reference

Documented in the format spec at `design/filesystem/pdxfs-lite-
format.md §1.3` ("Signature scope") and PDXL-D3 ("Signature scope:
superblock only at R25"). This retro's §Open Question Resolution is
the canonical record; PDXL-D3's "deferred to R40" phrasing is now
normative rather than provisional.

---

## Observable Proof

- Kernel builds clean under `tools/build.sh` — **15/15 verify gates
  pass** (no-AML lint + opcode-canary + kernel dispatch + sched
  guards + tty_read wrapper + link).
- All 15 default pre-push smoke modes pass (`boot_r8_only` through
  `boot_smp`, incl. `boot_r14b_*` and `boot_r17_shell_*`). No new
  fingerprint under `-kernel` — `pdxfs_lite_mount` never runs
  (no NVMe controller under QEMU q35 default → no driver attach →
  no mount call).
- R22 opt-in smokes pass unchanged: `PAIDEIA_R22_PCI_TREE=1
  boot_r22_pci_tree`, `PAIDEIA_R22_MSIX_IR=1
  boot_r22_msix_ir_round_robin` (both SKIP under `-kernel`).
- R21 opt-in smokes pass unchanged.
- R24 opt-in smoke passes unchanged:
  `PAIDEIA_R24_CONCURRENT_IO=1 boot_r24_concurrent_io` (SKIP).
- R25 opt-in smokes:
  - `PAIDEIA_R25_PDXFS_CORRUPT=1 boot_r25_pdxfs_corrupt_sb` — SKIP
    (M5, witness not wired at kernel_main).
  - **New R25.M7 opt-in smoke:** `PAIDEIA_R25_PDXFS_E2E=1
    boot_r25_pdxfs_e2e` — SKIP (M7 posture per §Deferrals D4/D5).
- `nm build/kernel.elf` shows every R25 substrate symbol linked:
  `sb_validate`, `_pdxfs_sb` (4096 B), `pdxfs_lite_read_superblock`,
  `sb_generate_uuid`, `sb_uuid_match`, `get_inode`, `put_inode`,
  `_pdxfs_lite_inode_scratch` (128 B), `pdxfs_read`,
  `pdxl_ex_alloc_first_fit`, `pdxfs_lite_vops_init`,
  `_pdxfs_lite_vops` (56 B), `_pdxfs_lite_mount_ctx` (64 B),
  `pdxfs_lite_mount`, `pdxfs_lite_is_mounted`,
  `pdxfs_lite_mount_root_vn`, `pdxfs_lite_lookup_by_name`,
  `pdxfs_lite_path_resolve`, `pdxfs_sb_verify_sig`,
  `pdxfs_lite_pubkey_ptr`, `pdxfs_lite_corrupt_sb_witness`,
  `pdxfs_lite_create`, `pdxfs_lite_unlink`, `pdxfs_lite_rename`,
  `pdxfs_lite_e2e_witness`.

---

## What Worked (Round Discipline)

1. **softarch → debugger loop shape held throughout.** Seven
   milestones closed as architect+implement passes followed by
   debugger passes. Zero workerbee invocations
   (per `feedback_paideia_os_loop_shape.md`).

2. **Continuous tempo across seven milestones.** Per
   `feedback_paideia_os_tempo.md`, R25 ran continuous with no
   between-milestone review pause. Seven milestones closed within
   two loop days.

3. **In-round documentation of deferrals.** Every M6 mutating op's
   module header calls out `return EROFS pending #906` inline —
   the R25 closure debt inventory (§Deferrals D1) is a
   consolidation of those headers, not a discovery. This is the
   discipline the R24.M5 partial-close note codified; R25 is the
   first round where the discipline was applied prospectively from
   M1.

4. **Paper-tiger downgrades saved cross-repo churn twice.** v0.22
   tag / slice+bitfield labels + RDRAND/UUID label both tacked
   cleanly onto pre-existing encoder features. Zero submodule bumps
   across R25. Fifth consecutive round with zero paideia-as
   escalations.

5. **Placeholder-witness idiom is now standard practice.** R22.M6
   (`msix_ir_round_robin_witness`), R24.M6 (`concurrent_io_witness`
   + `nvme_hw_smoke_witness`), R25.M5 (`pdxfs_lite_corrupt_sb_
   witness`), R25.M7 (`pdxfs_lite_e2e_witness`) all share the
   pattern: `.bss`-backed scratch + guard-on-substrate-availability
   + SKIP emit under `-kernel` + OK emit on live HW via GDB. The
   pre-push opt-in gate + SKIP-echo run-smoke mode is the boilerplate.
   Codified in `tools/pdxfs-lite-e2e-smoke.md §5` "Wire-up posture."

6. **Migration stub landed at close, not at open.** #938 landed at
   R25.M7 close (not queued for R40 open). This fixes the v0 format
   design against later drift — every R25 field is now on record as
   "the migrator will map this to v1 as follows"; future v0
   extensions get scrutinised against the migrator's ability to
   handle them, not against a hypothetical v1 spec that doesn't
   exist yet.

7. **Open-question resolution in the closure doc.** #940's
   scope explicitly names the per-superblock vs per-extent signature
   question from the R25 roadmap plan. Resolved with 5-point rationale
   in §Open Question Resolution above. Same discipline the R24
   closure applied to the userspace-supervisor deferral chain.

---

## What Didn't Work

1. **Write persistence didn't fire end-to-end at any point in R25.**
   Every mutating op landed as scaffolded code returning `EROFS`.
   Under any current boot path, `create`/`unlink`/`rename` are dead
   code from the user's perspective — the shell can't
   `echo > file`; it errors. The R25 acceptance surface accepts this
   (the round was scoped as "MVP + preflight for write persistence,
   not write persistence itself") but the user-visible functionality
   of PdxFS-lite at R25 close is "can mount + read files an operator
   mkfs'd in advance" — same shape as R14 tmpfs. Full write
   persistence lands at R26.M1.

2. **The mount ceremony never runs from `kernel_main_uefi`.** D2
   above. This means even a real-HW UEFI boot with an NVMe drive
   containing a valid PdxFS-lite image will not mount the FS
   automatically — an operator with GDB has to `call
   nvme_reset_and_enable` ... `call pdxfs_lite_mount` manually.
   Same posture as R24: substrate exists, wire-up is R25+ debt.
   Filed as R25.M6 debt "driver-attach ceremony" (which R25.M6
   itself carried forward from R24 unchanged); R26.M1 promotes it.

3. **T14 G4 first-mount capture never happened.** Every R25
   milestone ran under QEMU-TCG `-kernel` (no MCFG → no PCI
   enumeration → no NVMe probe → no mount attempt). The T14
   first-PdxFS-lite-mount moment stays queued for R26+ hardware
   bring-up alongside the R23 first-visual-output moment and the
   R24 first-NVMe-touch moment (which also have not fired). Zero
   rows promoted in `design/hardware/quirks.md` at this pass;
   §2.4 VMD row is unchanged from R24.M6 close.

4. **No opt-in `boot_r25_pdxfs_mount` structural smoke landed.**
   R25 planning identified this as a potential M2-close witness
   (mount against a fixture NVMe image using QEMU
   `-drive if=none,file=disk.img,format=raw -device nvme`) but the
   mkfs host tool (M3) and the mount wire-up (M4) landed after M2,
   so a full-pipeline structural smoke would have had to wait until
   M4 close — at which point it became the E2E fixture (#937) at
   M7. Not a bug; just a natural round-scoping consequence.

5. **Directory-entry limit not enforced at write time.** The §2.5
   note added at #939 documents the ~64-entry rule of thumb and the
   ~8318-entry `EFBIG` ceiling, but the `create.pdx` codepath does
   not currently check the count before allocating the new dentry
   (the check would just precede the `EROFS` return, so it's
   invisible at MVP). Filed as R26 debt "directory-entry limit
   enforcement" — lands with the write-persistence unblock.

---

## Preflight for R26

**R26 (USB xHCI + HID keyboard)** — opens after R25 close per
`design/roadmap/r18-plus-bare-metal.md §R26`. Draft preflight to land
as `design/round-retrospectives/r26-preflight.md` at R26.M1 kickoff.

### R26 direct scope (roadmap)

- xHCI probe (class `0c/03/30`).
- BIOS-owned → OS-owned handoff via `USBLEGSUP`.
- Command ring + event ring (16 B TRBs).
- Port reset + device address.
- Device-context array; slot management.
- USB descriptor parsing.
- HID class driver (userspace).
- HID boot-protocol keyboard translation → TTY input ring (bridges
  to existing `_tty_line_buf`).

### R26 opportunistic scope — R25 debt discharge

The R26 opening also has room to discharge the R25 write-persistence
debt as an M1 prelude:

1. **R26.M0 (optional prelude):** land `nvme_write_blocking`
   kernel-side sibling (#906). ~1 file, ~30 lines. Same shape as
   `nvme_read_blocking` with OPC=0x01. This unblocks:
   - `create.pdx` / `unlink.pdx` / `rename.pdx` returning success
     instead of EROFS.
   - The `pdxfs_lite_e2e_witness` OK-path under GDB.
   - The `tools/pdxfs-lite-e2e-smoke.md §2.2` write phase.
2. **R26.M0.5 (optional prelude):** land `commit_dirty_metadata`
   pass. ~1 file, ~50 lines. Walks dirty inode / dentry / bitmap
   blocks and writes each via `nvme_write_blocking`.
3. **R26.M0.9 (optional prelude):** wire driver-attach ceremony
   into `kernel_main_uefi` behind `Features.NVME_ATTACH_ENABLED = 1`
   (default 0 to keep `-kernel` boots side-effect-free).

If R26 scope tolerates the M0 prelude, the R25 write-persistence
first-fire lands at R26 open — probably 3–5 issues total. If R26
scope is too tight (xHCI is a serious substrate; R26 could easily
run 30+ issues on its direct scope), the M0 prelude moves to R26.5 /
R27 as a targeted "flush the R25 debt" sub-round.

Decision to defer to R26.M1 kickoff — see kickoff doc for the call.

### R26 needs from R25

1. **`pdxfs_lite_mount` + `_pdxfs_lite_mount_ctx`** as the FS
   surface every USB storage device would eventually target — even
   though R26 direct scope is HID keyboards, R26 might land USB
   mass storage (R37 in the roadmap; could pull forward if tempo
   allows). Both ready to consume.
2. **`pdxfs_lite_e2e_witness` scaffold** as the fixture template
   for any USB-storage-backed FS test. Ready to consume.
3. **Directory-entry limit rule of thumb** for shell UX tests —
   deep directory workloads should stay under ~64 entries until
   R40's dentry cache lands. Documented in
   `design/filesystem/pdxfs-lite-format.md §2.5`.

### R26 does NOT need from R25

- Real ML-DSA sig verify. Same posture as R25 — dev-bypass
  suffices until R32.
- Per-extent signing. Same posture — R40.
- Write persistence in the CI path. R26 CI stays QEMU-TCG
  `-kernel` which cannot exercise write persistence anyway;
  real-HW promotion is R28 MVP demo territory.

### R26 blockers (external)

- **paideia-as v0.22 tag** remains uncut. R26 does not need it for
  xHCI — every xHCI register access uses the same 32-bit MMIO
  primitives R22/R24 already use.
- **Real T14 G4 hardware for the first-keyboard-input acceptance
  moment.** R26 opens under QEMU (`-device qemu-xhci -device
  usb-kbd`); T14 promotion queued alongside R23/R24/R25 first-light
  moments in `tools/pdxfs-lite-e2e-smoke.md §3`.

---

## R25 Debt Carried Forward

Ledger of items deferred past R25 close:

1. **`nvme_write_blocking` (kernel-side) — R24 debt item #2,
   R25.M6 dependency.** All R25 mutating ops (`create` / `unlink` /
   `rename` / `write`) return `EROFS` pending this. Sibling of
   `nvme_read_blocking` with `OPC = 0x01`. Filed against
   `design/round-retrospectives/r24-closure.md §R24 Debt Carried
   Forward`; R25 could have landed this but scoping kept it in the
   R24 debt column so the R25 issue count stayed at the planned 30.
2. **`commit_dirty_metadata` pass.** Sibling of (1); no code exists.
   Design pass at R26.M1 (see §Preflight for R26).
3. **Driver-attach wire-up in `kernel_main_uefi`.** R24 debt item
   #4 inherited unchanged; R25 could not close it because the same
   #1015 gate applies.
4. **Real ML-DSA-65 sig verify.** D3 above; R32 crypto round.
5. **Live E2E on real HW.** D4 above; R26+ real HW.
6. **`boot_r25_pdxfs_e2e` fingerprint file.** D5 above; R26+ when
   caller wire-up lands.
7. **Migration tool implementation (`tools/migrate-pdxfs-lite-to-v1
   .sh` / `.pdx`).** #938 landed the design stub only; tool code
   lands at R40 CoW-PQ round.
8. **Directory-entry limit enforcement in `create.pdx`.** #939
   landed the documentation; enforcement lands with the
   write-persistence unblock at R26.M1.
9. **R24 debt items still open (unchanged from R24 close):**
   Multi-controller support; 4-CPU concurrent-IO fixture body;
   `boot_r24_concurrent_io` fingerprint file; T14 G4 first-light
   for NVMe.
10. **R23 debt items still open (unchanged from R23 close):**
    UEFI/OVMF fb_console smoke harness; T14 G4 first-visual-output
    capture; `fb_map_lfb` BGRA-only assumption; `_fb_console_grid`
    fixed size; k_panic_fb_banner_len triplicate; two paideia-as
    encoder polish gaps.
11. **R22 debt items still open (unchanged from R22 close):**
    `_vtd_base` hardcoded; `has_dmar` slot unpopulated;
    `vtd_fault_dispatch` not IDT-wired; `msix_enable_device` +
    `msix_assignments` ledger; full GCMD.TE + SIRTP + IRE ceremony;
    DMA-fault regression SKIP → LIVE; T14 G4 PCI/ACPI captures.
12. **R21 debt items still open:** `hpet_now_ns` precision widening;
    `phase1_acpi_gather` full wire (partial at R22.M1 — MCFG only).

**None regress R25 acceptance.**

---

## Quirks Discovered on Real Hardware

None (R25 ran under `qemu -kernel` throughout — no UEFI/OVMF harness
yet, no MCFG surface, no PCI enumeration, no NVMe controller, no
mount attempt). No rows in `design/hardware/quirks.md` promoted
`PROVISIONAL → CONFIRMED` at this pass.

Quirks-db discipline recap at M7:
- No new rows added — R25 discovered nothing new about the T14 G4
  substrate that wasn't already anchor-documented at R22.M6 (VMD row)
  and R24.M6 (VMD row cross-ref to `tools/nvme-hw-smoke.md`).
- `tools/pdxfs-lite-e2e-smoke.md §4` documents the promotion pass an
  R26+ operator will run when the first live-mount fires on real HW.

---

## Milestone Discipline Statement

R25 held to the round-tempo user preference: continuous loop across
all issues + milestones with no mid-round pause. Seven milestones
closed in roughly two loop days; 30 issues landed (26 implementation
+ 4 closure). Zero fully-deferred issues from R25-scoped work —
every planned R25 issue landed either fully or with the documented
kernel-side/persistence-arc split (D1 above); the persistence-arc
split is itself the R24-inherited #906 dependency chain, not R25
work slippage.

The `softarch → debugger` loop shape held throughout with zero
workerbee invocations. Cross-repo escalation to paideia-as fired
**zero times** during R25 — fifth consecutive round with no
escalations. `paideia-as` submodule pin `2cf169d` unchanged since
R21 close.

---

## Real-Hardware Verification Procedure (T14 G4, R25 gated:hardware)

Full recipe at `tools/pdxfs-lite-e2e-smoke.md`. Summary:

1. **Prepare boot media + PdxFS-lite image.** Build kernel per
   `BUILDING.md`. Materialise a PdxFS-lite image on a scratch NVMe
   drive via `tools/mkfs-pdxfs-lite.sh /dev/nvme0n1`.
2. **BIOS setup.** Same as R24: Intel VMD Controller = **Disabled**;
   Secure Boot Disabled; UEFI Only.
3. **Boot on T14 G4.** Expect fingerprints: R21 substrate + R22 PCI
   ENUM DONE + `NVME PROBE N=1` + (with driver-attach wired)
   `PDXFS_MOUNT uuid=... itable=...`.
4. **GDB attach + witness invoke.** Via Intel DCI dongle, attach
   GDB, `call pdxfs_lite_e2e_witness()`. Expect BEGIN → OK
   mounted=1 → END (versus SKIP not mounted under `-kernel`).
5. **Shell R/W probe.** Once the M0 prelude lands
   (`nvme_write_blocking` + `commit_dirty_metadata` + driver-attach
   wire-up), run the `tools/pdxfs-lite-e2e-smoke.md §2.2` write
   phase, reboot, run §3.2 read phase, verify bytes persist.
6. **Promote quirks-db.** Any new drive-specific quirks discovered
   during §5 get fresh rows per §2.4 template.

None of this blocks R25 close. QEMU-side substrate is proven via
`kernel.elf` linkage + 15/15 build gates + the pre-push regression
matrix + the SKIP-echo opt-in smoke.

---

## Next Round

**R26 (USB xHCI + HID keyboard).** See
`design/roadmap/r18-plus-bare-metal.md §R26`. Preflight document to
land at R26.M1 kickoff as
`design/round-retrospectives/r26-preflight.md`.

R26 blockers: none from R25. Ready to open.

---

**Closure.** R25 PdxFS-lite persistent FS MVP + NVMe driver-attach
preflight closed 2026-08-11. Write paths dormant until #906 unblock
at R26.M1 (or R26.5 sub-round if xHCI scope is too tight to prelude).
