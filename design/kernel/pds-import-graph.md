# PDS import graph traversal + cycle detection — R133.M3

Parent: paideia-os#2480. Milestone: paideia-os#2622.

## Scope

Follow `#import` directives transitively across pds containers; build a
dependency-ordered module list; detect cycles per PDS-O2.

## Algorithm

A classical DFS with gray/black marking:

- Each node (module) carries a 2-bit color: WHITE (0, unvisited),
  GRAY (1, in-progress), BLACK (2, finished).
- `_ig_traverse(root)` recurses over `#import` edges.
  - On entry, if color is GRAY → cycle; emit `PdsErr::ImportCycle`
    with the length of the gray-chain prefix.
  - On entry, if color is BLACK → already included, return.
  - Else mark GRAY, recurse over each `#import` edge, mark BLACK on
    return, append to the post-order list.
- The post-order list is the dependency-ordered module list: a module
  appears after all its transitive imports.

Cycle-report encoding: the error packs the path length N into the
high 32 bits of the packed return; the low 32 bits carry the opaque
error tag.

## Fingerprint

On success: `pds import graph ok modules=N cycles=0`.
On cycle:    `pds import graph FAIL cycles=K`.

The verify-fingerprint-coverage gate only matches bare `OK`, so the
success witness ends with `ok modules=N cycles=0 OK` (or the gate
allowlist carries an entry for this marker shape).

## Status band

See `src/kernel/core/pds/import_graph.pdx` for the error-code
reservation.

## Interactions

- Builds on R133.M1 container reader (which decodes the container
  header + `#import` section into a flat list of path strings).
- Builds on R133.M2 caps-decl gate (which asserts a container's
  caps-decl is well-formed before it is pulled into the graph).
- Downstream: R133.M4 will attach a canonical name-resolution pass
  on top of the dependency-ordered list.

## References

- `design/terminal/semantic-shell-materialization-plan.md` §4 R133 row M3
- PDS-O2 import model
- `src/kernel/core/pds/container_reader.pdx` (R133.M1)
- `src/kernel/core/pds/caps_decl_gate.pdx` (R133.M2)
