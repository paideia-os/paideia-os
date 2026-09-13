# postui-desktop

The desktop shell: a ring-3 compositor client that registers itself with
svc-compositor, hosts a terminal widget backed by a `KIND_TTY` sink, a
24px status bar (clock / battery / wifi), and a hardcoded 3-slot
application launcher.

Landed across R113.M6-027..031 (paideia-os #2407-#2411).

## Files

| File | Issue | Purpose |
|---|---|---|
| `config.pdx` | #2407 | Static geometry, identity, and placeholder capability-slot constants. |
| `entry.pdx` | #2407 | Process entry: `pdx_desktop_init`, main-loop skeleton. |
| `terminal_widget.pdx` | #2407 / #2411 | KIND_TTY-backed terminal widget; Frame-to-rect scanline swap. |
| `status_bar.pdx` | #2408 | Clock (`sys_clock_read_ns` poll), battery (real `KIND_BATTERY` cap), wifi (userspace placeholder). |
| `launcher.pdx` | #2409 | 3-slot grid (`term`/`files`/`browser`) + `postui_desktop_launch` exec dispatch. |
| `surface_wire.pdx` | #2410 | `sys_cap_invoke` gate on the `KIND_SURFACE` cap before a draw is accepted. |

## Lifecycle status

This subtree compiles and type-checks but is **not yet linked into any
running binary** (see the `postui-desktop/*` exclusion branch in
`tools/build-user.sh`, alongside `compositor/`, `input_server/`, `a11y/`,
`color/`, `ime/`, `libpaideia_ui/`) -- it is a scaffold awaiting the
process-spawn wire that hands it real capabilities (a `KIND_SURFACE`
sub-cap for its terminal Frame, and optionally a `KIND_BATTERY` read cap
for the status bar). See `config.pdx`'s "SPAWN-TIME CAPABILITY GAP" note
for the exact placeholder-slot convention (`0 == not granted yet`).

## Known gaps (deliberate, documented at each call site)

- **Wifi status has no kernel capability behind it.** No `KIND_WIFI_*`
  kind exposes signal strength or SSID today. `status_bar.pdx`'s wifi
  widget returns a fixed local placeholder (60% / `"WEAK"`) with **no
  syscall at all** -- see its header for why a same-tree "kernel stub"
  would be unreachable from ring 3 without a real syscall + dispatch
  wire, and `src/kernel/core/net/wifi_status_stub.pdx` for the inert
  kernel-side placeholder this mirrors pending that follow-up.
- **Battery reuses the real `KIND_BATTERY` capability** (0x158,
  already dispatched in `invoke.pdx`) rather than a new fake
  `KIND_POWER_SUPPLY` kind, to avoid maintaining two competing
  "the battery" capabilities. See `status_bar.pdx`'s header.
- **`compositor_register_client` lives under `src/user/compositor/`**
  (`client_registry.pdx`), not `src/kernel/compositor/` -- the latter
  path does not exist; the compositor is a userspace server in this
  tree. See `client_registry.pdx`'s header.
- The application launcher's manifest scan (`/system/apps/*.desktop-like`)
  is not implemented; the 3-slot grid is hardcoded per the issue's own
  stub-is-OK scope.
