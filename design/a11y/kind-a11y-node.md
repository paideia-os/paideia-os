# KIND_A11Y_NODE — kernel-native accessibility node capability

Status: landed (substrate + cap_invoke dispatch arm). COMP-IMPL-09, Wave UUU.

## Summary

`KIND_A11Y_NODE` (ordinal `0x1E6`) is a kernel-native capability naming
one accessibility-tree node: `(parent_node_id, role, label_ptr,
label_len)`. It is minted via `a11y_node_cap_mint` in
`src/kernel/core/cap/kind_a11y_node.pdx` and queried through the
standard `sys_cap_invoke` path via a new dispatch arm in
`src/kernel/core/cap/invoke.pdx`'s `cap_invoke_dispatch`.

## Two KIND_A11Y_NODE ordinals — this is intentional, not a collision

This repo now has **two** things named "KIND_A11Y_NODE", and they are
deliberately different citizens:

| | `0x1E2` | `0x1E6` (this doc) |
|---|---|---|
| File | `src/user/a11y/kind_a11y_node.pdx` | `src/kernel/core/cap/kind_a11y_node.pdx` |
| Layer | Userspace, compositor-internal PWP schema | Kernel-native `cap_table` citizen |
| Landing | Wave0-B14 G10-M1-002 (#2303) | COMP-IMPL-09 (Wave UUU) |
| Status at landing | Schema + stubs only — every op returns `NODE_NOT_INIT`; no row pool exists | Real: row pool, mint, revoke, query dispatch all live |
| Shape | Rich AccessKit-style node: role/state/value(name/desc/value_text/num/min/max/step)/edges | Minimal: `(parent_node_id, role, label_ptr, label_len)` |
| Parent reference | `tree_ref` names a `KIND_A11Y_TREE` (`0x1D3`) row | `parent_node_id` names another live `KIND_A11Y_NODE` (`0x1E6`) row, or `0` for a root |
| Reachable via `sys_cap_invoke`? | No — lives entirely in the compositor's own process memory, never a `cap_table` row | Yes — this landing's whole point |

The `0x1E2` file's own header states plainly that its row-pool substrate
"DOES NOT EXIST YET" and its op functions are STUB BODIES that always
return `NODE_NOT_INIT` — closing that gap (role/state/value packing,
attach/detach linearity, tree-mutation ops, cross-reference into
`KIND_A11Y_TREE`) is a substantially larger lift than this landing's row
prompt asked for ("Add a dispatch arm to sys_cap_invoke: mint an a11y
node cap tied to `(parent_node_id, role, label_ptr, label_len)`. Return
cap id."). Rather than half-retrofit that stub file with a narrower
shape than its own design intends, this landing mints a **second,
minimal kernel ordinal** (`0x1E6`, the first free `0x1XX` slot at
landing time — see `kind_a11y_node.pdx` §0 for the full grep trail) that
satisfies the row prompt's exact signature as a real, working substrate
today.

### Reconciliation — a decision for a future round, not this one

Three paths are open for a future landing to pick between; none is
foreclosed by this one:

1. **Merge**: retire `0x1E2`'s stub bodies and have the PWP-layer
   schema's rich node data (role/state/value/edges) live as extra
   fields on `0x1E6`'s row, with the compositor's tree-walk code
   consuming `0x1E6` directly. Highest cost (touches every `0x1E2`
   consumer that assumed the richer shape), highest payoff (one
   source of truth).
2. **Derive**: keep `0x1E2` for the rich in-process schema but have its
   real substrate (once built) mint a companion `0x1E6` cap per node,
   so a cross-process consumer (a screen reader running as its own
   task) gets a real capability to hand off, while the compositor's own
   fast-path tree walk still uses `0x1E2`'s in-process arena. Lower
   cost, keeps both shapes alive.
3. **Stay parallel**: `0x1E6` serves narrow cross-process "name one
   node, minimally" use cases (e.g. an input-route dispatch focusing a
   node, or a compositor-external audit trail) while `0x1E2` is built
   out separately as the compositor's own internal accessibility-tree
   representation, and the two never formally unify. Lowest cost,
   accepts two vocabularies for "an accessibility node" long-term.

This document does not pick one — that call belongs to whoever lands
`0x1E2`'s real substrate and can see which shape its actual consumers
(screen reader, elaboration gate, mutation log — all already scaffolded
under `src/user/a11y/`) actually need.

## Why no parent-cap derivation

Every other derived kind in `cap/invoke.pdx`'s dispatch chain gates its
mint on a parent `cap_table` slot of some other kind (`KIND_MEMORY`,
`KIND_IPC_ENDPOINT`, `KIND_DEVICE`, ...). `KIND_A11Y_NODE` (`0x1E6`)
does not: `parent_node_id` names another live `KIND_A11Y_NODE` row by
its kernel-assigned `node_id` — a same-kind self-reference, exactly the
tree-by-node-id shape `0x1E2`'s own (deferred) substrate was already
planning to use for `KIND_A11Y_TREE` linkage. `parent_node_id == 0`
mints a root node.

## Row layout (48 bytes)

```
[+0]  header:  in_use[63:56] | role[15:0]
[+8]  node_id:         u64  -- kernel-assigned monotonic identity; 0 = none
[+16] parent_node_id:  u64  -- 0 at a root node
[+24] label_ptr:       u64  -- opaque caller-space pointer (never dereferenced)
[+32] label_len:       u64  -- byte length named by label_ptr
[+40] reserved0:       u64
```

64 rows, `[u64; 384]` backing (`ANODE_MAX = 64`, `ANODE_ROW_BYTES = 48`).

## `label_ptr` / `label_len` are opaque

The mint gate validates `label_len <= 256` and requires `label_ptr != 0`
whenever `label_len > 0`, but never walks, copies, or dereferences the
pointer — doing so would need a `user_ptr_ok` + walker copy-in this
substrate-only landing does not add (no new SC+ syscall is part of this
row prompt). The kernel stores the value it was given and trusts the
caller to keep the bytes valid for the cap's lifetime, the same posture
`kind_gpio_line.pdx` takes toward pin/community indices and
`kind_bt_pairing.pdx` takes toward its sealed key material. A future
landing wanting the kernel to own a copy of the label text adds a
dedicated copy-in op; the row layout is unaffected.

## Why mint is not reached through `cap_invoke(slot, op_arg)`

`a11y_node_cap_mint` takes four independent `u64`-shaped arguments —
`label_ptr` alone can be a full 64-bit value, so unlike
`call_kind_surface`'s `MINT` arm (which packs `w`/`h`/`format` into the
spare bits of one `op_arg` word) there is no bit-packing scheme that
fits all four fields into `cap_invoke`'s single `op_arg` register. Mint
is therefore a direct kernel function — the same posture
`display_mode_cap_mint` / `sensor_channel_cap_mint` / `kind_gpio_line`'s
own audited mint entries already take: real substrate, callable today,
awaiting a future syscall (a `sys_a11y_node_mint` akin to
`sys_volume_mint.pdx`'s shape) that marshals ring-3 arguments into this
exact signature. This landing's actual "dispatch arm to sys_cap_invoke"
deliverable is the **query-only** `cap_handler_a11y_node`, wired into
`cap_invoke_dispatch` via a `cmp rcx, 0x1E6` arm — the surface a caller
uses *after* minting, mirroring how `KIND_SURFACE`'s and `KIND_SEAT`'s
own dispatch arms (COMP-IMPL-02/03/04, the immediately-preceding
landings in this same "compositor-impl-backtrack wave" series) each
pair a pre-existing mint substrate with a freshly-wired `cap_invoke`
dispatcher.

## Ops (query-only, arity one)

| op | name | returns |
|----|------|---------|
| 0 | `QUERY_PARENT` | `parent_node_id` |
| 1 | `QUERY_ROLE` | `role` (header bits `[15:0]`) |
| 2 | `QUERY_LABEL_PTR` | `label_ptr` (opaque) |
| 3 | `QUERY_LABEL_LEN` | `label_len` |
| 4 | `DEBUG_PRINT` | `0` (requires `R_A11Y_NODE_OBSERVE`) |

Ops 0-3 require `R_A11Y_NODE_INVOKE` (`0x008`). `op_arg[63:8]` must be
zero (`ANODE_TAIL_BAD_ARG` otherwise).

## Rights

```
R_A11Y_NODE_READ    = 0x001
R_A11Y_NODE_INVOKE  = 0x008
R_A11Y_NODE_REVOKE  = 0x010
R_A11Y_NODE_OBSERVE = 0x400
R_A11Y_NODE_ALL     = 0x419
R_A11Y_NODE_CLIENT  = 0x019   -- READ | INVOKE | REVOKE (mint-time grant)
```

No `R_A11Y_NODE_MINT` bit — mint is a direct kernel call (see above),
not an op reachable through `cap_invoke` on an existing cap.

## Failure taxonomy — `0xFFFFEA00..0xFFFFEA0F`

Grep-verified free at landing time (three independent prior landings —
`src/user/compositor/clipboard.pdx`, `subsurface_sync.pdx`,
`dnd_offer.pdx`, and `src/user/libpaideia_ui/view_tree.pdx` — each
already noted this exact page as open and reserved for a future
sibling).

| value | name | meaning |
|---|---|---|
| `0xFFFFEA00` | `ANODE_BAD_SLOT` | revoke: slot out of range, empty, or wrong kind |
| `0xFFFFEA01` | `ANODE_MINT_ENOSPC_SLOT` | mint: no free `cap_table` slot (row is freed before returning) |
| `0xFFFFEA02` | `ANODE_MINT_ENOSPC_ROW` | mint: row pool full (64/64 in use) |
| `0xFFFFEA03` | `ANODE_MINT_BAD_PARENT` | mint: `parent_node_id` neither 0 nor a live row |
| `0xFFFFEA04` | `ANODE_MINT_BAD_LABEL` | mint: `label_len > 256`, or `label_len > 0` with `label_ptr == 0` |
| `0xFFFFEA05` | `ANODE_MINT_BAD_ROLE` | mint: `role > 39` |
| `0xFFFFEA06` | `ANODE_TAIL_BAD_ARG` | internal shape gate / cap_invoke reserved-bits refusal |
| `0xFFFFEA07` | `ANODE_TAIL_ENOSPC` | row-pool allocator: no free row |

`0xFFFFEA08..0xFFFFEA0F` (8 slots) stay free for a future sibling code
(e.g. a real double-revoke guard, should one become necessary).

## Files touched

- `src/kernel/core/cap/kind_a11y_node.pdx` — new: ordinal, rights, ops,
  row pool, validators, `anode_find_by_id`, `a11y_node_cap_mint`,
  `a11y_node_cap_revoke`, `cap_handler_a11y_node`.
- `src/kernel/core/cap/invoke.pdx` — `cap_invoke_dispatch`: one new
  `cmp rcx, 0x1E6 / je call_kind_a11y_node` arm plus the
  `call_kind_a11y_node:` body (bare shim into `cap_handler_a11y_node`,
  no op_arg unpacking needed since every op is arity-one).
- This document.

## Build status

Not yet built or booted by this landing — `bash tools/build.sh` is
main-only per this repo's standing convention; verification happens in
the follow-on build/smoke pass.
