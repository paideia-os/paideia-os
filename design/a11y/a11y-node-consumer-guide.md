# KIND_A11Y_NODE consumer guide

Status: landed (Wave ζ ζ-04). Consumer-facing companion to
`design/a11y/kind-a11y-node.md` (kernel substrate, COMP-IMPL-09).

## What KIND_A11Y_NODE is

A kernel-native capability naming one accessibility-tree node —
`(parent_node_id, role, label_ptr, label_len)`. Kernel dispatch ordinal
`0x1E6`; substrate at `src/kernel/core/cap/kind_a11y_node.pdx`.

## Two ordinals — legacy debt to reconcile

The repo has **two** citizens named `KIND_A11Y_NODE`:

| ordinal | file | layer | status |
|---|---|---|---|
| `0x1E6` | `src/kernel/core/cap/kind_a11y_node.pdx` | kernel-native cap | real (row pool, mint, revoke, cap_invoke dispatch) |
| `0x1E2` | `src/user/a11y/kind_a11y_node.pdx` | userspace PWP schema | stub — every op returns `NODE_NOT_INIT` |

The `0x1E2` file is a richer AccessKit-style schema (role / state /
value / edges) with no row-pool substrate; `0x1E6` is a minimal,
callable-today four-field row. `design/a11y/kind-a11y-node.md`
§"Reconciliation" lists the three paths open (merge / derive / stay
parallel) and defers the choice to whoever lands `0x1E2`'s real
substrate. **This guide targets the `0x1E6` ordinal exclusively** —
that is the one a consumer can actually call today.

## How consumers mint

Consumers mint one KIND_A11Y_NODE at surface-creation time — one node
per widget / row / heading whose semantics the accessibility tree
should name. Four fields are supplied:

- `parent_node_id : u64` — another live `0x1E6` row's `node_id`, or `0`
  for a root node.
- `role : u64` — an ordinal in `[0, ANODE_ROLE_MAX(39)]`; see role
  taxonomy below.
- `label_ptr : u64` — opaque caller-space pointer; the kernel never
  dereferences it.
- `label_len : u64` — byte length in `[0, ANODE_LABEL_MAX(256)]`; must
  be `0` when `label_ptr == 0`.

**Scaffold gap — no userspace mint syscall exists yet.**
`a11y_node_cap_mint` is a direct kernel function (see kernel doc
§"Why mint is not reached through cap_invoke"); a future
`sys_a11y_node_mint`, akin to `sys_volume_mint.pdx`'s shape, will
marshal the four u64 args and forward. Until then, consumers stage the
per-widget arrays (`_status_bar_a11y_nodes`, `_launcher_a11y_nodes`)
with cell value `0` as the "not yet minted" sentinel — mint attempts
are silently no-ops.

## Role taxonomy (subset in active use)

Full 40-value taxonomy at `src/user/a11y/kind_a11y_node.pdx`
lines 243..283. Consumers today use:

| ordinal | name | use |
|---|---|---|
| 2 | `ROLE_BUTTON` | launcher slots (interactive, click-invoked) |
| 5 | `ROLE_LABEL` | status-bar widgets (read-only text: clock/battery/wifi) — placeholder for a `ROLE_STATUS` ordinal not yet in the taxonomy |
| 11 | `ROLE_LIST` | future menu / notification list |
| 26 | `ROLE_TABLE` | future data-grid |
| 37 | `ROLE_HEADING` | future window title / section heading |
| 38 | `ROLE_REGION` | future top-level layout landmark |

Status-bar widgets deliberately map to `ROLE_LABEL` (not `ROLE_STATUS`,
which does not exist today); a follow-on landing that extends the
taxonomy with `ROLE_STATUS = 40` (and bumps `ROLE_MAX` in both the
userspace schema file and the kernel `ANODE_ROLE_MAX` in
`kind_a11y_node.pdx`) would repoint `STATUS_BAR_A11Y_ROLE` at that
ordinal in one line.

## a11y_bind_at_mint — a window-scoped wire, not a widget one

`src/user/compositor/a11y_bind_at_mint.pdx`'s
`a11y_bind_at_mint_wrap(window_id, parent_surface, parent_window,
z_order, tab_workspace_pack, a11y_tree_kind_id) -> row_id` is the P4
gate that guarantees every `KIND_WINDOW` (`0x1C1`) row carries a live
`KIND_A11Y_TREE` (`0x1D3`) reference at mint time. Its six-arg
signature mirrors `window_mint` verbatim.

**It is NOT a per-widget bind.** Status-bar widgets and launcher slots
are not `KIND_WINDOW` rows — they are internal-to-postui-desktop state.
This wave's dispatch note assumed a `bind(widget_kind_id, a11y_node_id)
-> u64` signature that does not exist. Consumers that own real
`KIND_WINDOW` rows (a xdg-shell surface, a compositor toplevel) use
`a11y_bind_at_mint_wrap` verbatim; consumers below the window layer
(widgets, rows, cells) mint their `0x1E6` nodes directly and stash the
cap slot in their own storage array.

## The eventual query API — descendant traversal

`src/user/compositor/a11y_tree.pdx` (Wave ζ ζ-05) provides the pure
userspace edge index a screen reader needs:

- `a11y_tree_add_edge(parent, child) -> slot_index | ENOSPC | BAD_ARG`
  — claims one slot in the 128-entry `_a11y_tree_edges` table.
- `a11y_tree_query_descendants(root, out_buf, buf_cap) -> count` — BFS
  walk starting at `root`, writing discovered child `node_id`s (u32)
  into `out_buf`; self-caps at `buf_cap` (also serves as the cycle
  self-terminator).

**Scaffold gap.** The edge index is orthogonal to the KIND_A11Y_NODE
cap system — it names relationships by `node_id`, not by cap slot.
A consumer today adds one edge per parent/child link at mint time
(concurrent with the `a11y_node_cap_mint` call that produces the child
node) and queries descendants without touching the cap layer. When a
future landing adds a `QUERY_CHILDREN` op to `cap_handler_a11y_node`
(currently arity-one, no such op), the edge-index and the cap-side
child-set become two views of the same relation and the design doc's
`0x1E2`/`0x1E6` reconciliation §gains one more constraint (whichever
citizen owns children ends up owning traversal too).

## Example wire-up

Status-bar widget (`src/user/postui-desktop/status_bar.pdx`
§Section 4):

```
// Per-widget storage (0 == not yet minted).
pub let mut _status_bar_a11y_nodes : [u64; 3] = uninit @align(64)
pub let STATUS_BAR_A11Y_ROLE : u64 = 5   // ROLE_LABEL

// One label string per widget; label_len excludes the NUL.
pub let status_bar_a11y_label_clock : [u8; 6] = "CLOCK\0"
pub let STATUS_BAR_A11Y_LABEL_LEN_CLOCK : u64 = 5

// Init (currently a defensive zero-out; grows a mint loop once
// sys_a11y_node_mint lands).
pub let status_bar_a11y_init : () -> () !{mem} @{} = ...
```

Launcher slot (`src/user/postui-desktop/launcher.pdx` §Section 4)
follows the identical shape, reusing the pre-existing
`launcher_label_{term,files,browser}` strings as its label payloads.

## Follow-ons tracked by this doc

1. `sys_a11y_node_mint` userspace wire (unblocks status-bar and
   launcher mint loops).
2. `ROLE_STATUS` taxonomy extension (replaces `ROLE_LABEL` placeholder
   in `STATUS_BAR_A11Y_ROLE`).
3. `QUERY_CHILDREN` op on `cap_handler_a11y_node` (removes the need
   for a separate userspace edge index once `0x1E2`/`0x1E6`
   reconciliation lands).
4. `libpdx-event` `focus` / `blur` events surfacing an `a11y_node_id`
   field (ζ-03 was blocked in this wave because the `libpdx-event`
   satellite does not exist as a submodule at `tools/user/`).
