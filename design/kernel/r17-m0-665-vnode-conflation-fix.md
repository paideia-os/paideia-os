# R17-M0 #665: vnode/inode conflation fix

## §1. Problem statement

path_resolve.regular_lookup treats backend-native inode indices (returned by vops_lookup / tmpfs_lookup) as vnode-pool indices when feeding them back into vnode_slot on the next iteration. Two disjoint index spaces silently aliased. Also: mount() leaves the root vnode's ops_ptr/backend_ptr at zero.

Detailed writeup: see paideia-os#665 (github issue).

Root cause bug: index-space confusion in path_resolve regular_lookup + mount's incomplete root-vnode initialization.

## §2. Phase index

This fix lands across seven phases. Each phase is one commit and one push; each preserves every existing boot fingerprint.

- **Phase 0** (this commit) — design doc scaffold + word-store landmine microbench witness. NO change to any VFS path.
- Phase 1 — add `vnode_cache_or_alloc` symbol to vnode_pool.pdx, exercised only by its own witness.
- Phase 2 — add `backend_registry.pdx` with `backend_ops_table` + `backend_root_inode`, exercised only by its own witness.
- **Phase 3** (LANDED) — wire root vnode ops_ptr/backend_ptr in mount() via backend_registry calls; keep witness pre-wires as belt+suspenders. Added sub-test E to verify ops_ptr and backend_ptr lands.
- Phase 4 — rewire path.pdx regular_lookup to call vnode_cache_or_alloc; rewrite #573 sub-tests D/F to check backend_ptr not vnode_idx.
- Phase 5a-e — remove witness pre-wires one witness at a time (sys_read, sys_write, sys_dup2, fd_inherit, fd_cloexec).
- Phase 6 — finalize design doc (growth plan, alternatives, cross-refs).

## §3. Landmine microbench (Phase 0)

paideia-as #1251 is OPEN: the elaborator's `Mnemonic::Mov` retarget branch does not have a store-direction case, so `mov [mem], eX/wX` (bare mov with narrow-suffix register) silently retargets to a REX.W 64-bit store, clobbering adjacent bytes.

Write patterns used across #665:

- **P1 (safe for fresh alloc):** full u64 store `mov [rax + offset], rN` where rN is 64-bit and the destination's adjacent bytes are provably zero (e.g., immediately after vnode_alloc's zero-fill).
- **P2 (safe for re-populating):** `mov_w [mem], rN` sized-mnemonic form with rN full-width, pre-zeroed. Goes through the typed-mnemonic elaborator path, not the bare-mov retarget. Corpus-proven — used in fd_inherit.pdx:67, vfs_close.pdx:91, tmpfs/init.pdx:64+, etc.
- **P3 (BROKEN — do not use):** `mov [mem], r12w`, `mov [mem], cx`, `mov [mem], r12d`. Bare narrow-suffix. Triggers paideia-as #1251.

Phase-0 microbench proves P2 works (pre-zeros a 64-bit .bss slot to 0xDEADBEEFCAFEBABE, does a `mov_w` of 0x1234 at offset +0, asserts the top 6 bytes remain 0xDEADBEEFCAFE unchanged). If paideia-as #1251 is ever fixed such that P2 breaks or P3 becomes safe, this witness catches it immediately.

Marker: `R17 WORD STORE OK`.

## §4-§10 — reserved

Filled in by subsequent phases.
