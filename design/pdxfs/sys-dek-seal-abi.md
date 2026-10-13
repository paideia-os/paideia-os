# sys_dek_seal ABI — PFS-13 (paideia-os #2731, Wave PFS-W10)

Status: landed 2026-10-11 (Wave PFS-W10).
Owner: PdxFS / cap substrate.
Depends on: PFS-12 KIND_DEK substrate (Wave 96 / paideia-os #2579).
Blocks: PFS-14 libpdx-volume real `pdxb_block_encrypt` / `pdxb_block_decrypt` bodies.
Closes: `tools/user/mount.pdxfs/src/passphrase_wire.pdx` GAP #P2.

## 1. Purpose

Wave 96 (PFS-12) landed `KIND_DEK` (ordinal `0x1A4`) as a supervisor-only
cap kind that holds the 32-byte plaintext DEK of an encrypted PdxFS
volume for the lifetime of its mount. The mint gate
`kind_dek_mint_body(parent_slot, rights, volume_id, dek_ptr, dek_len,
flags)` is reachable only from kernel code — the `DEK_OP_SEAL`
cap-invoke arm returns `DEK_STUB_SENTINEL` so ring-3 cannot drive it
directly.

The matching ring-3 scenario — `mount.pdxfs` has just finished an
AEAD-authenticated unwrap of the wrapped-DEK blob from a v2
(`PDXB_FLAG_ENCRYPTED`) superblock and holds 32 bytes of plaintext DEK
in a `.bss` scratch — had no supervisor entry point until this wave.
`passphrase_wire_unlock` therefore left the DEK in that `.bss` buffer
indefinitely (`passphrase_wire.pdx` header's documented GAP #P2),
which exposes 32 bytes of key material to any subsequent memory
disclosure in the `mount.pdxfs` address space.

`sys_dek_seal` is that missing entry point. It reads 32 bytes from a
caller-pinned user page, pulls the owning volume's identity from a
KIND_VOLUME cap the caller already holds, and seeds a KIND_DEK row
via `kind_dek_mint_body`. After the syscall returns, the plaintext
DEK lives only in the kernel row; `mount.pdxfs` wipes both its
`.bss` scratch and the pinned page.

## 2. Wire contract

### 2.1 Signature

```
sys_dek_seal(volume_cap_slot: u64,
             pinned_page_addr: u64,
             flags: u64) -> packed u64
```

SC+ ID: **136** (next free slot above PFS-09 `sys_vol_mint` at 135).

### 2.2 Return packing

```
rax = (row_id << 2) | status
```

- `status = rax & 3` — in bits `[1:0]`.
- `row_id = rax >> 2` — valid only when `status == 0`.

| `status` | name                 | meaning                                                                 |
| -------- | -------------------- | ----------------------------------------------------------------------- |
| 0        | `SDS_STATUS_OK`      | `row_id` ∈ `[0, DEK_MAX=16)`; a KIND_DEK row holds the sealed DEK.      |
| 1        | `SDS_STATUS_INVALID_SLOT`  | `volume_cap_slot` ≥ 256; not a live KIND_VOLUME; missing R_VOL_READ. |
| 2        | `SDS_STATUS_INVALID_PAGE`  | `pinned_page_addr` not 4KiB-aligned, kernel-half, or walk failed.    |
| 3        | `SDS_STATUS_MINT_FAILED`   | `kind_dek_mint_body` returned a sentinel (`DEK_TAIL_ENOSPC` etc.).   |

On any error, `row_id` is 0 and only `status` is meaningful. The
2-bit `status` field matches the sibling `sys_vol_mint` ABI
(design/pdxfs/sys-vol-mint-abi.md §3) and leaves enough room for one
future class (currently unused — reserved for a rights-wave gate at
R125+ that would surface a distinct `SDS_STATUS_DENIED`).

### 2.3 Arguments

| arg                 | type | semantics                                                                                       |
| ------------------- | ---- | ----------------------------------------------------------------------------------------------- |
| `volume_cap_slot`   | u64  | Caller's cap-table slot holding a live KIND_VOLUME cap with `R_VOL_READ` in its rights mask.    |
| `pinned_page_addr`  | u64  | User VA, 4KiB-aligned, pointing at a page whose first 32 bytes carry the plaintext DEK.         |
| `flags`             | u64  | Passed through to `kind_dek_mint_body` as its `flags` arg. Only `DEK_FLAG_REVOKED` (bit 0) is defined; mount.pdxfs passes 0. |

## 3. Pinned-page gate semantics

The task brief names a gate of the form _"`pinned_page_addr` is
4KiB-aligned + belongs to caller's KIND_MEMORY range"_. The kernel
composes that gate from three cheaper primitives already in the
tree:

- **G1 — 4KiB alignment.** Inline check `(pinned_page_addr & 0xFFF) ==
  0`, no call. Rejects any pointer that is not a page boundary.
- **G2 — user-half + overflow.** `user_ptr_ok(pinned_page_addr, 32)`
  (`src/kernel/core/syscall/ptr_check.pdx`): rejects `pinned_page_addr
  >= KERNEL_VMA_BASE` and `pinned_page_addr + 32 > KERNEL_VMA_BASE`.
- **G3 — walk the caller's user PT.** `user_read_bytes_via_walk(
  _sys_dek_seal_scratch, pinned_page_addr, 32)`
  (`src/kernel/core/syscall/user_read.pdx`): per-byte walk through
  `_current_tcb.user_pml4_va` → PDPT → PD → PT → frame; reads the
  byte via the kernel higher-half identity map. A byte that cannot
  be walked is rejected.

**G3 _is_ the KIND_MEMORY-ownership proof.** `mm/aspace_map.pdx` pins
the invariant that _"the user PT itself is the ownership proof —
entries map only pages the task has been granted via a KIND_MEMORY
mint"_. Walking a byte successfully from the caller's `user_pml4_va`
is therefore the proof the caller holds a KIND_MEMORY cap over that
page; no separate cap-table lookup for the pinned page's KIND_MEMORY
authority is needed. A caller that forges `pinned_page_addr` to point
at a kernel-mapped page it does not own fails G3 because its own
`user_pml4` does not map that page.

Rejects at any of G1 / G2 / G3 collapse into `SDS_STATUS_INVALID_PAGE`.
A future klog fingerprint emission could tell the three apart; this
landing does not emit one (matching `sys_vol_mint_body`'s posture).

## 4. Volume-id derivation

`kind_dek_mint_body` refuses `volume_id == 0`
(`DEK_MINT_BAD_ARG`). The KIND_VOLUME row (kind_volume.pdx §1)
packs `device_slot` / `mount_slot` into its header, then stores
`uuid_lo` / `uuid_hi` / `root_inode` / `mount_gen` / `inode_count`
/ `free_blocks` / `sig_key_slot` — but **no scalar `volume_id`**.
Three candidates were weighed:

| option                                        | problem                                                                                            |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| (a) use `uuid_lo` directly                    | `sys_vol_mint` synthesizes `uuid_lo = (device_cap << 56) \| superblock_lba` which can be 0; also muddles identity vs liveness. |
| (b) hash `uuid_lo \|\| uuid_hi` to non-zero   | Overkill for a 16-slot address space; introduces a second lookup convention the per-block path must mirror. |
| (c) `volume_id = volume_row_id + 1`           | Always non-zero (row 0 → id 1); deterministic; the per-block crypto side also calls `volume_row_of_slot` on the KIND_VOLUME cap, so the (`row_id + 1`) convention round-trips with zero bookkeeping. |

This landing picks (c). `kind_dek.pdx`'s own §1 header hinted at
_"a kernel-assigned sequential u64 (per kind_volume.pdx
_volume_next_id)"_ but `kind_volume.pdx` has no such symbol; (c) is
the simplest reading of that intent that matches the actual
substrate. The PFS-14 block-crypto path will mirror this derivation:
on a `DEK_OP_LOOKUP_BY_VOLUME` cap-invoke the user hands a
KIND_VOLUME cap, the cap-handler composes `volume_row_of_slot(slot)
+ 1` and calls `dek_lookup_body` with that key.

## 5. Scrub posture

Three transient secrets exist in the syscall's frame; two are the
kernel's responsibility, one is the caller's.

### 5.1 Kernel-side (handled by this syscall)

- **S1 — kernel scratch `_sys_dek_seal_scratch`.** 32 bytes, holds
  the DEK between `user_read_bytes_via_walk` and the end of
  `kind_dek_mint_body` (which copies the four u64 words into the
  KIND_DEK row). The scratch is zeroed via four aligned u64 stores
  of 0 immediately after the mint returns, **on every return path**
  — including `MINT_FAILED`.
- **S2 — transient staging slot (SDS_STAGING_SLOT = 138).**
  `cap_mint_write(138, KIND_MEMORY, RIGHT_MINT, 0)` is staged before
  the mint and `cap_mint_write(138, 0, 0, 0)` is run after,
  regardless of mint success. The transient KIND_MEMORY authority
  therefore never outlives the syscall boundary.

Slot 138 was chosen free-by-construction: 132 (framebuffer stage),
133 (iris vblank), 134 (sys_vol_mint stage) and 136/137 (witnesses)
have documented owners; a repo-wide grep for `138` as a
`cap_mint_write` target returned no hits at this landing.

### 5.2 Caller-side (mount.pdxfs's responsibility)

- **S3 — caller's pinned page.** The kernel does not write back
  through the caller's `user_pml4` to scrub the DEK bytes it just
  read; doing so would require either a `user_write_bytes_via_walk`
  reverse variant with scrub semantics (not currently in the
  kernel) or a separate cap-table authority this body does not
  take. `mount.pdxfs`'s `passphrase_wire_unlock` therefore scrubs
  both the 32-byte `.bss` DEK scratch and the 4KiB staging page it
  owned on every return path. See the user-side section below.

## 6. Interaction with KIND_DEK (Wave 96 / PFS-12)

- The KIND_DEK substrate landed at `src/kernel/core/cap/kind_dek.pdx`
  with ordinal `0x1A4`, derived over KIND_MEMORY, 16-row pool, mint
  gate `kind_dek_mint_body` and three cap-invoke ops
  (`DEK_OP_SEAL` stub / `DEK_OP_LOOKUP_BY_VOLUME` /
  `DEK_OP_SCRUB`). PFS-13 is the §9 FOLLOW-UP #1 that §1 of
  `kind_dek.pdx` reserved for the supervisor mint hop.
- The row layout stores the 32-byte DEK in four u64 words at
  `[+8..+32]`, the `volume_id` at `[+40]`, and `flags` at `[+48]`.
  `sys_dek_seal` writes nothing to the row directly; it hands the
  32 bytes + `volume_id` + `flags` to `kind_dek_mint_body` which
  calls `dek_row_alloc` under the hood.
- `DEK_OP_SEAL` continues to return `DEK_STUB_SENTINEL` from
  cap-invoke. There is no plan to retire the stub — ring-3 cannot
  mint a KIND_DEK row directly, only through this syscall. A caller
  that calls `DEK_OP_SEAL` by mistake is told _"use the supervisor
  mint hop instead"_ via the sentinel code.

## 7. Interaction with the future PFS-14 block-crypto path

Once `sys_dek_seal` returns a `row_id`, mount.pdxfs stores it in
its own `passphrase_wire_dek_row_id` `.bss` slot. The KIND_DEK row
indexed by `volume_id = row_id + 1` holds the plaintext DEK.

PFS-14 will land the real `libpdx-volume` `pdxb_block_encrypt` /
`pdxb_block_decrypt` bodies. Each per-block crypto call reaches the
kernel via a `DEK_OP_LOOKUP_BY_VOLUME` cap-invoke on the user's
**KIND_VOLUME** cap (not on a KIND_DEK cap — the user never holds
one). The cap-handler at `cap_handler_dek` composes:

1. `row_id = volume_row_of_slot(user_cap_slot)` — resolve the
   KIND_VOLUME cap to its row.
2. `volume_id = row_id + 1` — the convention this document pins.
3. `dek_row = dek_lookup_body(volume_id)` — scan the KIND_DEK pool.
4. Four `dek_row_read_qword(dek_row, 0..3)` calls reconstruct the
   32-byte DEK inside the per-block crypto scope; the per-block
   buffer is scrubbed on return. The user never sees the bytes.

The `sys_dek_seal` syscall is therefore the seam between (a) a user
process that briefly holds the plaintext DEK after an AEAD unwrap,
and (b) kernel-only per-block crypto that never surfaces the DEK
again.

## 8. Dispatch wiring

`src/kernel/core/syscall/dispatch.pdx`:

- Bounds check widened `135 → 136` (`cmp rdi, 136; ja dispatch_enosys`).
- New arm `cmp rdi, 136; je dispatch_dek_seal;`.
- New label `dispatch_dek_seal` performs the three-move SysV
  shuffle (`mov rdi, rsi; mov rsi, rdx; mov rdx, rcx`) and
  `call sys_dek_seal_body`. The body owns the user-pointer bounce
  (no dispatch-layer KPTI scratch), mirroring `sys_vol_mint_body`'s
  shim pattern.

## 9. User-side wiring (mount.pdxfs)

`tools/user/mount.pdxfs/src/passphrase_wire.pdx`:

- **Return codes.** `PW_ERR_SEAL_FAILED = 0x0F10`. Band
  `0x0F10..0x0F1F` is reserved for `sys_dek_seal` failure classes;
  only one surface code is defined at the PFS-W10 landing (kernel's
  three distinct status values collapse into one mount.pdxfs
  class). A future refinement that cares about the distinction
  widens the band at `0x0F11+` without touching callers that
  already dispatch on `0x0F10`.
- **New `.bss` scratch.**
  `mount_pw_dek_page_scratch : [u8; 4096] @align(4096)` — the
  4KiB-aligned staging page the DEK is copied into immediately
  before the syscall. Both this page and the 32-byte
  `mount_pw_dek_scratch` are wiped on every return path from
  `passphrase_wire_unlock`.
- **New `.bss` slot.**
  `passphrase_wire_dek_row_id : u64 = 0xFF` — records the
  returned `row_id` on OK; stays at the `PW_DEK_ROW_NONE = 0xFF`
  sentinel across every failure path.
- **`passphrase_wire_unlock` signature.** Gained a fourth argument
  `volume_cap_slot`. The function now runs KDF + DEK unwrap +
  seal-hop in sequence; on seal failure it wipes both scratches
  and returns `PW_ERR_SEAL_FAILED`; on success it stores the
  `row_id` and wipes both scratches before returning `PW_OK`.
- **SC+ constant.** `PW_SC_DEK_SEAL = 136`.

## 10. Encoder discipline recap

- All KIND tags (`KIND_VOLUME = 0x1A0`, `KIND_MEMORY = 4`),
  rights masks (`RIGHT_MINT = 0x200`, `R_VOL_READ = 0x001`,
  `R_DEK_ALL = 0x007`) stage through `r11` before `cmp`.
- No `add reg, [mem]`. No `test`. No `imul`.
- `0xFFF` (page mask), `16` (DEK_MAX), `32` (DEK_LEN), `138`
  (SDS_STAGING_SLOT) are all well-formed imm32 and used directly.
- Labels prefixed `sds_` (kernel) and `mount_pw_ul_` (user).
- Module basename match: `sys_dek_seal_body.pdx` → module
  `SysDekSealBody`.

## 11. Future work

- **R125+ rights-wave gate.** Add a caller-side rights check
  (`R_DEK_SEAL` on a to-be-defined parent cap, or a sysno-level
  pre-authorization). Today any caller can issue the syscall; the
  gate against bad input is purely structural (KIND_VOLUME slot
  validation + pinned-page walk). The 2-bit status field already
  reserves a `SDS_STATUS_DENIED = 3`-adjacent value for this
  landing.
- **libpdx-volume real block-crypto bodies (PFS-14).** The planned
  companion wave that composes `dek_lookup_body` + the paideia-as
  `chacha20_poly1305` intrinsic into real `pdxb_block_encrypt` /
  `pdxb_block_decrypt`.
- **Scrub-on-mount-failure path.** If mount succeeds in sealing a
  DEK but a later mount step fails (bad root inode, journal
  replay refused, etc.), the KIND_DEK row needs a scrub via
  `DEK_OP_SCRUB` on the KIND_VOLUME cap. The umount hook already
  reaches this; the mount-failure fallback is a one-liner in
  `main.pdx` deferred until the whole mount-table composition
  lands.
- **klog fingerprint emission.** Add a `tag_sys_dek_seal_ok` key
  to `klog/keys.pdx` and emit a `klog_s1_d2(volume_id, row_id)`
  on the success funnel. Omitted at PFS-W10 to keep the
  registration churn small (matches `sys_vol_mint_body`).
