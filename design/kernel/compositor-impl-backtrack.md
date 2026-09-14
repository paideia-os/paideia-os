# Compositor kernel implementation backtrack (Wave TTT)

Five implementation-backtrack items targeting WEAK stubs / missing
`cap_invoke_dispatch` arms the compositor substrate needs wired before
its tests can pass. Each item was investigated against the CURRENT
tree before writing any code -- the codebase turned out to be
considerably further along than the wave brief assumed (three of the
five named targets either don't exist under the names given, or were
already fully implemented), so each entry below records what was
actually found and why the landed fix takes the shape it does.

See also: `design/kernel/syscall-table-cap-invoke.md` (COMP-IMPL-01
detail) and `design/kernel/kind-surface-mint.md` (COMP-IMPL-02 detail).

## COMP-IMPL-01 -- sys_cap_invoke sysno reconciliation

**No code change.** Audited every real caller; all agree on sysno 4
against `src/kernel/core/syscall/dispatch.pdx`'s authoritative
cmp-chain. No caller anywhere in the tree references sysno 120 for
`cap_invoke`. Full detail + audit table in
`design/kernel/syscall-table-cap-invoke.md`.

## COMP-IMPL-02 -- KIND_SURFACE mint operation

`surface_mint` (kind_surface.pdx) and its `cap_handler_surface`
dispatcher were already fully implemented (16-row pool, not a stub).
The actual gap was one level up: `cap_invoke_dispatch`'s
`call_kind_surface` shim always zeroed MINT's w/h/format arguments,
making MINT unreachable from the only real userspace entry point
(`sys_cap_invoke`). Fixed by packing w/h/format into `op_arg`'s upper
56 bits for the MINT ordinal only (ordinals 0..4 unchanged). Full
detail in `design/kernel/kind-surface-mint.md`.

- `src/kernel/core/cap/invoke.pdx`

## COMP-IMPL-03 -- KIND_FB_SCANOUT dispatch arm (-> KIND_FRAMEBUFFER)

**Naming reconciliation.** No `KIND_FB_SCANOUT` kind exists anywhere
in the tree. The kind that actually owns the boot-populated LFB
descriptor is `KIND_FRAMEBUFFER = 0x1AF`
(`src/kernel/core/cap/kind_framebuffer.pdx`, R101.M3-001), whose row
already carries real `width / height / stride / pixel_format / lfb_pa
/ lfb_va` populated at mint time from the platform's actual MMIO-mapped
LFB (not a fixed 1920x1080 placeholder -- that file's mint gate
(`fb_dim_valid`) refuses `0`/`> FB_DIM_MAX(8192)` and takes real
dimensions from its caller, `sys_framebuffer_create_body`, sysno 109).

The real gap: `kind_framebuffer.pdx`'s own header names the plan --
"one QUERY op ... at this landing; the cap_invoke dispatch for FLIP +
REVOKE arrives at R105." FLIP and REVOKE did land at R105, but as
DEDICATED syscalls (108..113, `design/user/syscall-table.md`) rather
than through `cap_invoke` -- and QUERY's `cap_invoke_dispatch` wiring
was never added at all (confirmed: no `call_kind_framebuffer` arm
existed anywhere in `invoke.pdx`). Additionally, `FB_OP_QUERY_FORMAT`
had named an op ordinal since R101.M3-001 with no backing accessor --
every other QUERY field (width/height/stride/lfb_pa/lfb_va/
backend_kind) had one; format did not.

Fix: added the missing accessor and wired the whole QUERY family into
`cap_invoke_dispatch`. A caller wanting `{lfb_ptr, pitch, width,
height}` issues four `cap_invoke` calls against the same `fb_slot`
(`FB_OP_QUERY_VA`, `_STRIDE`, `_WIDTH`, `_HEIGHT`) -- a single packed
4-field return is not possible through the frozen 2-arg
`sys_cap_invoke(slot, op_arg) -> u64` ABI (one `u64` result register),
the same per-field shape `KIND_SURFACE`'s own `OP_SURFACE_QUERY`
already uses.

- `src/kernel/core/cap/kind_framebuffer.pdx` -- new `fb_row_pixel_format`
  accessor (backs the previously-unbacked `FB_OP_QUERY_FORMAT`).
- `src/kernel/core/cap/handlers/cap_handler_framebuffer.pdx` -- new,
  the QUERY-only dispatcher, gated on `R_FB_MAP`.
- `src/kernel/core/cap/invoke.pdx` -- new `0x1AF` arm + `call_kind_framebuffer`
  shim.

## COMP-IMPL-04 -- KIND_INPUT_FOCUS mint dispatch (-> KIND_SEAT)

**Naming reconciliation.** No `KIND_INPUT_FOCUS` kind exists. The
kind that actually models "mint a focus association tied to a
(seat_id, surface_id) pair" is the KERNEL-side `KIND_SEAT = 0x1BF`
(`src/kernel/core/cap/kind_seat.pdx`, R113.M5-025, #2405) -- note this
is deliberately DISTINCT from the USER-side Wayland-vocabulary
`KIND_SEAT = 0x1D6` (`src/user/input_server/seat_kind.pdx`), a split
the kernel file's own "KERNEL vs. USER KIND_SEAT NAMING" section
already documents and resolves as non-colliding.

The kernel substrate (`seat_create` / `seat_destroy` / `seat_bind_kbd`
/ `seat_bind_ptr`) was already fully implemented, including the real
per-seat `kbd_focus_slot` / `ptr_focus_slot` / `touch_focus_slot`
fields this wave item is asking for. The real gap: `kind_seat.pdx`'s
own header names it verbatim -- "the follow-on seat-manager /
display-manager landings that call seat_create + seat_bind_kbd +
seat_bind_ptr through the cap dispatcher's KIND_SEAT arm (not yet
landed)." Confirmed: no `call_kind_seat` arm existed anywhere in
`invoke.pdx`.

Fix: added `cap_handler_seat.pdx`, a 4-op dispatcher (`BIND_KBD=0`,
`BIND_PTR=1`, `DESTROY=2`, `MINT=3`), and wired `KIND_SEAT (0x1BF)`
into `cap_invoke_dispatch`. `MINT` (`seat_create`) returns the new
`seat_id` as the durable focus-association handle; `BIND_KBD` /
`BIND_PTR` tie that seat_id to a `surface_id` payload packed into
`op_arg`'s upper 56 bits, including a marker value that expands back
to the real 64-bit `SEAT_FOCUS_NONE` sentinel so the substrate's
clear-binding arm stays reachable through the packed encoding.

- `src/kernel/core/cap/handlers/cap_handler_seat.pdx` -- new.
- `src/kernel/core/cap/invoke.pdx` -- new `0x1BF` arm + `call_kind_seat`
  shim.

## COMP-IMPL-05 -- compositor_register_client kernel-side

`src/user/compositor/client_registry.pdx` already had a real,
non-stub `compositor_register_client` body (8-slot table, dup +
full-scan gates, R113.M6-027 #2407). Widened to the wave's target
shape:

- `CLIENT_REGISTRY_MAX`: 8 -> 32.
- Added a fourth parallel `.bss` array, `_client_endpoint_ids`, so a
  row is the full `{app_id, caps, endpoint_id}` triple. New rows
  stamp `CLIENT_NO_ENDPOINT (0)` at claim time; `compositor_client_
  endpoint` / `compositor_client_set_endpoint` are the new accessor
  pair for the follow-on landing that mints a real `KIND_IPC_ENDPOINT`
  once postui-desktop and svc-compositor split into separate
  processes (per the file's own pre-existing lifecycle-skeleton note).
- `compositor_register_client`'s two-argument signature is UNCHANGED
  -- its sole caller (`src/user/postui-desktop/entry.pdx`
  `pdx_desktop_init`) is preserved verbatim.
- `CLIENT_REGISTRY_FULL` still returns the existing high-sentinel
  (`0xFFFFE150`), not a POSIX `-EBUSY`: every other refusal in this
  same file (`DUP`, `BAD_ARG`) already uses that taxonomy for a
  same-address-space bookkeeping structure, and the sole caller
  discards the distinction (stores the raw result verbatim), so
  splitting one function's return convention in two buys nothing.

- `src/user/compositor/client_registry.pdx`

## Risk summary

- COMP-IMPL-01: none (documentation only).
- COMP-IMPL-02: additive `op_arg` decode gated on the MINT ordinal;
  no existing caller reachable, so no behaviour change for ordinals
  0..4.
- COMP-IMPL-03/04: new kind-ID dispatch arms reuse EXISTING,
  already-frozen kind identities (`0x1AF`, `0x1BF`) -- no new kind-ID
  allocation, so no collision risk against `kind.pdx`'s registry.
  Register-alignment discipline (odd push count -> `rsp%16==0` at
  every nested `call`) was rederived per handler, not copy-pasted.
- COMP-IMPL-05: table widen + new column are purely additive; the one
  existing caller's call shape is untouched.

Build not run -- main should invoke `bash tools/build.sh` and
re-invoke softarch with the error tail if it fails.
