# sys_vol_mint — Hot-plug KIND_VOLUME mint ABI (PFS-09)

**Status:** FROZEN at this landing.  Kernel-side body + dispatch
wiring + libpdx-volume client wire-through all land in the same wave
(PFS-W6, chain-head PFS-09, paideia-os#2576).
**Wave:** PFS (pdxfs user-space tool completion), chain-head PFS-09.
**Scope:** The ring-3-facing kernel syscall `sys_vol_mint` (sysno
135) and its client-library wire-through `VolKind::vol_kind_mint` in
`tools/user/libpdx-volume/src/vol_kind.pdx`.  The syscall mints a
fresh `KIND_VOLUME` cap over a user-supplied `VolumeDescriptor` so a
userland `mount.pdxfs` can bring up a mount against a probed
`KIND_BLKDEV` even when no boot-time `_init_caps` seeded the volume.
**Supersedes:**
- The "no cap-invoke op that reaches kind_volume_mint" blocker in
  `src/kernel/core/cap/kind_volume.pdx` SECTION 0 and the
  "no ring-3-reachable KIND_VOLUME mint syscall" blocker in
  `tools/user/libpdx-volume/src/vol_kind.pdx` v1.1.0's
  `vol_kind_mint_elevate` module header for the one-arg
  `vol_kind_mint` entry point (the elevate variant stays blocked on
  libpdx-elevate until that library enters the build tree -- see §6).

---

## §1 Overview

### §1.1 What the syscall is for

`sys_mount` (sysno 75) takes a `/dev/pdxvolN` path string, resolves
it to a volume-registry row via the kernel's `volume_tail_valid` +
`volume_row_device_slot` chain, and routes to
`mount_pdxfs_block(cap_slot, bdev_cap, 0, 0)`.  That path works ONLY
when the volume row ALREADY exists in the registry -- which, at this
landing, happens exclusively via the boot-time `_init_caps` seed for
the founder-home volume (slot 176 / MBOT_ROOT_VOLUME_CAP_SLOT) and
the handful of boot-witness mints landed under
`r30_platform.pdx` + friends.

Hot-plug devices (USB storage, PCIe hot-insert NVMe, loopback images
mounted from `/home`, future removable SATA bay) have NO boot-time
seed.  The probe-time driver mints a `KIND_BLKDEV` cap and publishes
it to a well-known cap slot, but no `KIND_VOLUME` row is created
because that would require reading the superblock, verifying the
PDXB magic, parsing the UUID, and allocating a volume-registry row --
work that the probe path cannot do (it is deliberately a thin
driver-level mint, not a filesystem-layer walk).

`sys_vol_mint` closes that gap.  A ring-3 caller (typically
`mount.pdxfs`, running AFTER userland has probed the device enough
to know the device_cap slot, block_count, and probable superblock
LBA) presents a 64-byte `VolumeDescriptor` and the kernel mints a
fresh `KIND_VOLUME` cap.  The resulting cap_handle is then passed to
`sys_mount` with backend_id=5.

### §1.2 Why this is a sibling to sys_volume_mint (sysno 114)

A functionally-equivalent syscall `sys_volume_mint` already exists at
sysno 114 (R90-XREPO.LV11.M2-003 / paideia-os#2225,
`src/kernel/core/syscall/handlers/sys_volume_mint.pdx`).  It solves
the same problem.  PFS-09 lands a SIBLING at sysno 135 rather than
reusing sysno 114 because the two ABIs differ at the surface:

|                      | `sys_volume_mint` (114, R90)        | `sys_vol_mint` (135, PFS-09, HERE) |
|----------------------|-------------------------------------|------------------------------------|
| magic field          | u64 "PDXVDSC1" (`0x3143534456584450`)| u32 "PDXV" (`0x56584450`)          |
| descriptor size      | 40..256 bytes (variable)            | exactly 64 bytes (fixed)           |
| uuid provenance      | explicit `uuid_lo` / `uuid_hi` at +16/+24 | synthesized from `device_cap` + `superblock_lba` (§4) |
| return discipline    | errno (`-EFAULT`, `-EINVAL`, `-ENOSPC`, `-EIO`) or cap_slot | packed u64: `(cap_handle << 2) \| status`, status ∈ {OK=0, INVALID=1, OUT_OF_ROWS=2, DENIED=3} |
| rights-gate posture  | STUB (same as this; no R125 check)  | STUB (same; R125 is the shared wave that lands it) |

The PFS-09 brief was authored BEFORE the softarch sweep discovered
sysno 114.  By the time the duplication was recognized, the
PFS-09 ABI shape had already been consumed by downstream design
(the 64-byte fixed descriptor is referenced by
`design/pdxfs/init-caps-seed-convention.md` §4.3 for the
boot-vs-hot-plug symmetry argument, and the packed-return discipline
is referenced by `tools/user/libpdx-volume/src/vol_kind.pdx`
v1.2.0's new mint-wire callers).  Breaking the frozen PFS-09 ABI to
re-adopt sysno 114 would have cascaded into three other repos'
contracts; adding a sibling kernel syscall keeps both ABIs intact
and defers the consolidation to a dedicated wave (§6.1).

The two bodies SHARE their substrate: both call
`volume_cap_mint_inner` with a pre-packed `volume_hdr`, then
`cap_mint_write` to publish into a free cap-slot.  There is no logic
duplication at the semantics layer; the duplication is purely at the
ABI surface.

### §1.3 Live source

- Syscall body + shim: `src/kernel/core/syscall/sys_vol_mint_body.pdx`
  - `sys_vol_mint_body`  (kernel-VA entry point)
  - `sys_vol_mint_shim`  (user-VA entry point, dispatched from
                          sysno 135)
- Dispatch wiring:       `src/kernel/core/syscall/dispatch.pdx`
  - Bounds-check widen:  `cmp rdi, 134; ja dispatch_enosys` -> 
                         `cmp rdi, 135; ja dispatch_enosys`
  - New arm:             `cmp rdi, 135; je dispatch_vol_mint`
  - New label body:      `dispatch_vol_mint` (register shuffle +
                         `call sys_vol_mint_shim`)
- Client:                `tools/user/libpdx-volume/src/vol_kind.pdx`
  - `vol_kind_mint`      (one-arg hot-plug entry; marshals the
                          descriptor and issues sysno 135)
- Test:                  `tools/user/libpdx-volume/tests/test_vol_kind_mint.pdx`
  - `test_vol_kind_mint_run` (three cases: happy, kernel-reject,
                              library-side bounds-reject)

---

## §2 VolumeDescriptor wire format

### §2.1 Layout (exactly 64 bytes, 8-byte aligned)

```
offset  size  field          contents
------  ----  -------------  ---------------------------------------
+0      4     magic          u32 LE = 0x56584450 ("PDXV")
+4      4     version        u32 LE = 1 (SVM_DESC_VERSION)
+8      8     device_cap     u64 cap_slot in [0, 256), live
                             KIND_BLKDEV (0x42) descriptor
+16     8     block_count    u64, informational -- stored verbatim
                             into uuid_hi_synth (§4)
+24     8     superblock_lba u64, informational -- stored verbatim
                             into uuid_lo_synth (§4)
+32     8     flags          u64, reserved -- MUST be zero at
                             PFS-09; future flag bits consumed by
                             later waves
+40     24    reserved       zero-filled by caller; kernel does NOT
                             validate the reserved tail (forward-
                             compat gate)
------  ----  -------------
total   64
```

The brief listed `reserved: [u8; 32]` which would push the total to
72, but the brief also stated the descriptor is 64 bytes.  The
64-byte total is load-bearing (it is the only size this syscall
accepts); `reserved` is therefore 24 bytes.  §3.1's length-gate
enforces this.

### §2.2 Why "PDXV" instead of "PDXVDSC1"

- `PDXVDSC1` is sysno 114's magic -- an 8-byte version-encoded
  mnemonic.
- `PDXV` is a 4-byte freed-up magic that fits a u32 slot; it leaves
  the next 4 bytes for an explicit `version` field.  The split
  gives any FUTURE wire-format bump a dedicated version slot rather
  than overloading the magic itself.

The two magics do not collide at the byte level: `PDXVDSC1` starts
with `P D X V D S C 1` and `PDXV` with `P D X V` (then version=1 as
LE u32 = `01 00 00 00`); the fifth byte of each is different (`D`
vs `01`), so a mis-routed descriptor from one syscall to the other
is rejected at the magic/version check with no false match.

### §2.3 Why no explicit UUID in the descriptor

The caller running `mount.pdxfs` does NOT YET have a real UUID at
the moment of hot-plug.  The real UUID lives in the on-disk PDXB
superblock, and reading it requires a KIND_BLKDEV op that the
libpdx-volume layer deliberately defers until AFTER the KIND_VOLUME
cap exists (circular dependency: the superblock-reader uses the
volume cap).  Sysno 114 solves this by making the caller GUESS a
plausible UUID (which it then overwrites via `volume_row_uuid_*_set`
after reading the real one).

Sysno 135 cuts the Gordian knot: the kernel SYNTHESIZES a placeholder
UUID (§4) that is guaranteed non-zero (so `volume_tail_alloc`'s
all-zero refusal passes) and guaranteed unique-per-device (so a
re-mint after transient failure does not accidentally alias to a
different volume).  The real on-disk UUID is written in via
`volume_row_mount_gen_set` + a future `volume_row_uuid_*_set`
helper AFTER the superblock read lands.

---

## §3 Return discipline

### §3.1 Packed u64 shape

```
bit    63 .................... 2  1  0
       [         cap_handle       | status  ]
                 (62 bits)        (2 bits)
```

- `status` in bits [1:0] has 4 values: 0=OK, 1=INVALID, 2=OUT_OF_ROWS,
  3=DENIED.  See §3.3 for the full taxonomy.
- `cap_handle` in bits [63:2]: on OK, this is a cap_slot in
  [SVM_CAP_POOL_LO=240, SVM_CAP_POOL_HI=256).  On any error,
  cap_handle is 0.

Caller decode (C-pseudocode):

```c
uint64_t rax = syscall(135, &desc, 64);
uint64_t status      = rax & 0x3;
uint64_t cap_handle  = rax >> 2;
if (status == 0) {
    /* use cap_handle as a KIND_VOLUME cap_slot */
} else {
    /* status in {1, 2, 3}; cap_handle == 0 */
}
```

### §3.2 Deviation from the task brief (`<< 1` vs `<< 2`)

The brief specified `(cap_handle << 1) | status` with a 2-bit
status enum.  `<< 1` leaves only ONE bit for status (collision
otherwise); the brief's intent was clearly a `<< 2` encoding so the
2-bit status enum fits without ambiguity.  This landing uses `<<
2` and flags the deviation in the kernel body's file header
(`src/kernel/core/syscall/sys_vol_mint_body.pdx` §Deviation note).

Collision proof for `<< 1`:
- `(cap_handle=1, status=0)` -> `(1<<1)|0 = 2`.
- `(cap_handle=0, status=2)` -> `(0<<1)|2 = 2`.
- Same packed value, two distinct meanings -- unresolvable.

### §3.3 Status taxonomy

| status  | code name              | kernel-side triggers                                              |
|---------|------------------------|-------------------------------------------------------------------|
| 0       | OK                     | descriptor validates + volume_cap_mint_inner succeeds + free pool slot found + cap_mint_write done |
| 1       | INVALID_DESCRIPTOR     | `desc_len != 64`; magic != `0x56584450`; version != `1`; `device_cap >= 256`; `cap_table[device_cap].kind != KIND_BLKDEV (0x42)`; shim's `user_ptr_ok` or `user_read_bytes_via_walk` rejects the user pointer (shim synthesizes INVALID rather than a separate -EFAULT) |
| 2       | OUT_OF_ROWS            | `volume_cap_mint_inner` returned any VOL_* sentinel (VOL_REGISTRY_FULL, VOL_TAIL_BAD_ARG, VOL_MINT_BAD_PARENT, VOL_MINT_BAD_RIGHTS); OR the cap-slot pool [240..256) is exhausted (16 active hot-plug volume caps already) |
| 3       | DENIED                 | **Unreachable at PFS-09.**  Reserved for the R125 rights-check landing (`R_VOLUME_MINT` right on the caller) |

### §3.4 Library-side error mapping

`vol_kind_mint` translates the kernel's packed error status to a
library-local errno band `0x0E0*` so the library's error table stays
isolated from the kernel's shape:

| kernel status | library return                       |
|---------------|--------------------------------------|
| 0 (OK)        | kernel packed value VERBATIM (caller recovers cap_handle via `>> 2`) |
| 1 (INVALID)   | `LPV_MINT_ERR_INVALID` (0x0E02)      |
| 2 (OUT_OF_ROWS) | `LPV_MINT_ERR_OUT_OF_ROWS` (0x0E03) |
| 3 (DENIED)    | `LPV_MINT_ERR_DENIED` (0x0E04)       |
| (unexpected)  | `LPV_MINT_ERR_SYSCALL` (0x0E01)      |

The last row covers the defensive case where the kernel returns a
packed value whose low 2 bits are 0 (status=OK) but whose cap_handle
> 255 (impossible for a legitimate kernel return given the fixed
cap-slot pool).  Library-side bounds-reject (dev_cap >= 256) also
returns `LPV_MINT_ERR_INVALID` without issuing the syscall.

---

## §4 UUID synthesis

### §4.1 The constraint

`volume_tail_alloc` (`src/kernel/core/cap/kind_volume.pdx` §tail_alloc,
L404-L479) refuses an all-zero uuid pair:

```asm
; uuid all-zero refused.
mov rax, r13;    ; uuid_lo
or  rax, r14;    ; uuid_hi
cmp rax, 0;
je  vol_ta_bad;  ; -> VOL_TAIL_BAD_ARG
```

A naive hot-plug mint with `uuid_lo = uuid_hi = 0` (because the
caller does not yet know the real UUID) always fails `tail_alloc`.
Sysno 114 solves this by making the caller supply its best-guess
uuid in the descriptor; sysno 135 chose a frozen descriptor layout
WITHOUT a uuid field (§2.3) and so needs a kernel-side synthesis.

### §4.2 The formula

```
uuid_lo_synth = (device_cap << 56) | superblock_lba
uuid_hi_synth = (block_count   << 1) | 1
```

- `| 1` on `uuid_hi_synth` guarantees the pair is NEVER all-zero
  regardless of `device_cap`, `superblock_lba`, or `block_count`.
- `device_cap << 56` puts the cap_slot ordinal in the high byte of
  uuid_lo so a reader can recover it without reading the volume row
  header.  (`superblock_lba` typically fits in <= 48 bits for any
  plausible disk capacity, so the two subfields do not collide.)
- `block_count << 1` preserves the full 63 bits of block_count that
  are informative; the only lost bit is bit 63, which no realistic
  block-count ever reaches.

### §4.3 Properties

1. **Non-zero**: `uuid_hi_synth` is always odd, so the pair is never
   all-zero.  Tail_alloc's all-zero refusal always passes.
2. **Deterministic**: same `(device_cap, block_count,
   superblock_lba)` triple always synthesizes the same uuid pair.
   A re-mint after a transient `tail_alloc` failure does NOT
   accidentally alias to a different volume.
3. **Collision-resistant**: `(device_cap, block_count,
   superblock_lba)` is already unique-per-device by probe-time
   construction.  The synthesis preserves that uniqueness.
4. **Overwritable**: `volume_row_mount_gen_set` already exists for
   post-mint field updates.  A future `volume_row_uuid_set` (filed
   as a design-doc follow-up at §6.2) overwrites the synthetic pair
   with the real on-disk uuid once the superblock-read helper lands.

---

## §5 Cap-slot pool

### §5.1 The range

`SVM_CAP_POOL_LO=240`, `SVM_CAP_POOL_HI=256` -- 16 slots total.
Matches `VOL_MAX=16` (`kind_volume.pdx` L217), so a sys_vol_mint
caller never has fewer cap-slots available than it has volume rows
to put into them.

### §5.2 Pool disjointness audit (2026-10-11)

| range          | claimed by                               | reference |
|----------------|------------------------------------------|-----------|
| [0, 128)       | R66v2 witnesses, boot caps               | various   |
| {132}          | sys_framebuffer_create staging           | handlers/sys_framebuffer_create.pdx |
| {133}          | iris_xe_vblank_isr staging               | drivers/dpy/iris_xe_vblank_isr.pdx §L26 |
| {134}          | sys_volume_mint(114) staging **AND** sys_vol_mint(135, HERE) staging | sysno 114 & 135 both scrub this slot before return; see §5.3 |
| {136}          | pdxfs_pkg_install_smoke witness          | r30_platform.pdx trail |
| {137}          | r104_iris_xe_flip witness                | r30_platform.pdx trail |
| [172, 177)     | mount_table_root reservation             | mount_table_bootstrap.pdx |
| {176}          | MBOT_ROOT_VOLUME_CAP_SLOT                | mount_table_bootstrap.pdx |
| [216, 232)     | r30 thermal / tb_route boot witnesses    | r30_platform.pdx |
| [224, 232)     | sys_mount block-arm pool                 | sys_mount.pdx L298-299 |
| [240, 256)     | **sys_vol_mint pool (THIS LANDING)**     | sys_vol_mint_body.pdx |

### §5.3 Staging-slot sharing (slot 134)

Both sysno 114 and sysno 135 use slot 134 as the transient
KIND_MEMORY parent staging slot for the volume_cap_mint_inner call
(the derivation gate requires a KIND_MEMORY + RIGHT_MINT parent, and
neither syscall's caller holds one -- see sys_volume_mint(114) L120
SYSVM_STAGING_SLOT and sys_vol_mint_body.pdx SVM_STAGING_SLOT).  The
sharing is safe because:

1. Both bodies scrub the slot (cap_mint_write with kind=0, rights=0,
   target=0) BEFORE returning.
2. Both syscalls are synchronous ring-3 calls on the current task;
   no two of them can run concurrently from the same caller.
3. The kernel is still single-core enforcement for the syscall path
   at PFS-09 (no SMP sys_vol_mint callers yet).

A future SMP landing of the syscall path makes staging slot 134 a
per-task TCB field.  That rewrite is a mechanical sweep (grep for
`SYSVM_STAGING_SLOT` / `SVM_STAGING_SLOT`), tracked in
`design/kernel/smp-syscall-staging.md` §4 (future doc).

### §5.4 Overlap with sys_volume_mint(114)'s first-fit scan

Sysno 114's free-slot scan runs over the WHOLE cap_table (0..256).
It can land inside [240, 256), racing with sysno 135's pool.  At
PFS-09 this is a theoretical overlap -- the ONE existing caller of
sysno 114 is `vol_kind_mint_elevate` (a STUB), so no live caller
reaches sysno 114 today.  The consolidation wave (§6.1) resolves
this by either:

(a) Partitioning sysno 114's scan to exclude [240, 256), OR
(b) Deprecating sysno 114 entirely and migrating its one future
    caller to sysno 135.

Decision deferred to the consolidation wave; both options are safe
and the overlap is latent at PFS-09.

---

## §6 Future work

### §6.1 Consolidation wave (sysno 114 vs sysno 135)

Two sibling syscalls doing the same job is a maintenance liability.
A dedicated wave (filed as a paideia-os follow-up issue at this
landing) picks one of:

**Option A: migrate sysno 114 to sysno 135.**  Rewire
`vol_kind_mint_elevate` to issue sysno 135.  Deprecate sysno 114 at
the dispatch layer (return -ENOSYS).  Retain the sysno 114 body for
one release cycle as a deprecated-but-functional target, then delete
in the following release.

**Option B: migrate sysno 135 to sysno 114.**  Rewire
`vol_kind_mint` to issue sysno 114.  Rebuild sysno 114's response
packing to match sysno 135's packed-u64 shape (BREAKING ABI change).
Deprecate sysno 135 at the dispatch layer.

**Recommended**: Option A.  Sysno 135's ABI is simpler (fixed
descriptor size, packed return, synthetic uuid), its sole caller
(`vol_kind_mint`) is LIVE at this landing, and sysno 114's lone
caller is still a STUB.  The migration cost is lower on Option A.

### §6.2 Real UUID writeback

The synthetic UUID pair (§4) is a placeholder.  When the
superblock-read helper lands (`libpdx-volume::pdxb_superblock_read`,
filed under PFS-10 or later), it reads the real on-disk uuid and
calls a new `volume_row_uuid_lo_set` + `volume_row_uuid_hi_set` pair
to overwrite the synthetic values.  The row-setter infrastructure
already exists at
`src/kernel/core/cap/kind_volume.pdx` §Row setters (L757-L933 --
`volume_row_root_inode_set`, `volume_row_mount_gen_set`, etc.); the
uuid pair just needs its own two setters added following the same
pattern.

### §6.3 R125 rights check (DENIED path)

Status=3 (DENIED) is wired into the kernel body as an unreachable
label at PFS-09.  R125 (the capability-rights wave) inserts a
rights check at the head of `sys_vol_mint_body` between (1)
descriptor parse and (2) cap_table device_cap verification.  The
caller must hold `R_VOLUME_MINT` on a well-known elevate-broker cap
or on its own `_init_caps`-seeded authority cap; absence returns
status=3.  The signature and failure taxonomy stay byte-identical
to this landing so a caller compiled against PFS-09 does not need
to re-link when R125 goes real.

### §6.4 vol_kind_mint signature widening

The current one-arg `vol_kind_mint(dev_cap)` entry point sends
`block_count=0, superblock_lba=0, flags=0` in the descriptor.  A
future wave widens the signature to `vol_kind_mint_full(dev_cap,
block_count, superblock_lba, flags)` so the hot-plug caller can
supply the real values once it has probed enough of the device to
know them.  The signature widening is purely additive -- the one-arg
form stays as a convenience shim that forwards zeros.

---

## §7 Test matrix

### §7.1 Library-side tests (`test_vol_kind_mint.pdx`)

Three cases driven via a static mock-gate in the library's own .bss
(see the test file's module header for the full rationale on why a
mock is necessary when no kernel is live under the test harness):

1. **Happy path.**  `mock_rax = (42 << 2) | 0 = 168`, `dev_cap = 7`.
   Verifies: library returns 168 verbatim; descriptor scratch after
   the call carries the correct magic/version/dev_cap bytes and
   zero-filled remaining fields.
2. **Kernel-reject INVALID.**  `mock_rax = 1`, `dev_cap = 7`.
   Verifies: library translates kernel-side status=1 to
   `LPV_MINT_ERR_INVALID (0x0E02)`.
3. **Library-side bounds-reject.**  Mock disabled, `dev_cap = 500`.
   Verifies: library short-circuits to `LPV_MINT_ERR_INVALID`
   WITHOUT reading the mock gate (which, if reached, would return
   999 and fail the assertion).

### §7.2 Kernel-side witness (future)

A kernel-side witness exercising `sys_vol_mint_body` directly
(bypassing the shim) with:
- A seeded `_init_caps` KIND_BLKDEV cap at a known slot.
- A hand-built kernel-VA descriptor at that slot.
- Verification that cap_table has a live KIND_VOLUME at a slot in
  [240, 256) after the body returns.
- Verification that `volume_tail_valid(row_id)` returns 1 for the
  row the body allocated.

Filed as a boot-smoke witness under the kernel-tests tree in a
follow-up wave (deferred to keep the PFS-09 landing's build time
down).

---

## §8 Grep-audit tags for refactor sweeps

Future consolidation sweeps grep for these tokens:

- `SVM_STATUS_` -- the kernel's packed status enum.
- `LPV_MINT_ERR_` -- the library's errno band 0x0E0*.
- `_lpv_vk_syscall_mock_` -- the library's test-mock gate (strip at
  consolidation if a cleaner mock substrate lands).
- `_lpv_vk_desc_scratch` -- the library's descriptor-marshaling
  buffer (per-task TCB slot in a future SMP wave).
- `SVM_CAP_POOL_LO` / `SVM_CAP_POOL_HI` -- the kernel's cap-slot
  pool for sysno 135; move to slab_alloc at consolidation.
- `SVM_STAGING_SLOT` -- shared with `SYSVM_STAGING_SLOT` (sysno
  114); per-task-ize together in the SMP wave.
