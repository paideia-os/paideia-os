# R105 Closure Retrospective: Compositor Syscall Surface + Hotplug + Boot Witness

**Date:** 2026-09-02
**Milestone:** R105 (17-issue single-landing wave; the R101 GUI wave's
final round per `design/graphics/r101-kernel-plan.md` §2.1 sub-scope
enumeration).
**Plan pointer:** `design/graphics/r101-kernel-plan.md` §R105.M1..M7.
**HEAD at closure:** paideia-os `<HEAD>` (this doc + the syscall-
table refresh + the ordinal reservations in `cap/kind.pdx` are the
non-code changes).
**Release tag recommendation:** `r105-closed` once the boot smoke
returns green under `PAIDEIA_VGA=std` (main runs the build after
this landing).

---

## §1. What shipped

**Sysnos consumed:** 108, 109, 110, 111, 112, 113 -- the compositor's
public GUI ABI block. Every handler owns its own cap-slot resolution +
rights gate; every dispatch shim is a minimal register shuffle with
the SysV alignment pad. Details in `design/user/syscall-table.md`.

**Kinds landed:**

- **KIND_HOTPLUG_CHANNEL (0x1B1)** -- `cap/kind_hotplug_channel.pdx`.
  Derived over KIND_IPC_ENDPOINT. Row tail {port_slot, delivered,
  owner_pid} + a mask in the header. Rights R_HPCH_SUBSCRIBE /
  R_HPCH_REVOKE. Deliver primitive `hotplug_channel_deliver(event_
  class)` scans every live row and bumps the counter of any row whose
  mask covers the event.
- **KIND_PAGE_FLIP (0x1B0)** -- `cap/kind_page_flip.pdx`. Derived
  over KIND_DISPLAY_OUTPUT. LINEAR: no R_FLIP_MINT bit; the substrate
  refuses generic `cap_mint_write`-driven duplication. Row tail
  {output_slot, active_fb_slot, pending_fb_slot, seq_pending, seq_
  completed} + in_flight bit in header. Submit primitive `pgfl_submit`
  atomically stages the pending flip; deliver primitive
  `pgfl_deliver_vblank` latches and wakes the waiter via
  `sched_wake_kind(SCHED_WAIT_PAGE_FLIP=2, row_id)`.

  **Co-landing note:** the R101 GUI plan §2 originally paired
  KIND_PAGE_FLIP with R104 (T14 Iris Xe wire-up + page-flip cap). At
  the time R105 landed, R104 had not landed, and R105's syscall
  surface + witness had a hard dependency on the kind. Rather than
  block R105 on the whole T14 modeset cascade, KIND_PAGE_FLIP was
  co-landed here. When R104's modeset + vblank ISR path lands, its
  own witnesses consume the existing kind unchanged; the vblank ISR
  becomes an additional call site for `pgfl_deliver_vblank` alongside
  the R101 simulated-tick path.

**Syscalls landed:** all six as separate `sys_*_body` functions under
`src/kernel/core/syscall/handlers/`, wired via dispatch shims in
`src/kernel/core/syscall/dispatch.pdx`. Bounds check widened from 107
to 113 in the same edit.

**Boot witness:** `src/kernel/boot/witness/r105_flip_client.pdx` --
skips cleanly when PAIDEIA_VGA=none (no Bochs stdvga device probed);
under PAIDEIA_VGA=std it mints a fresh KIND_DISPLAY_BACKEND row
(the R101 witness that ran before us revoked its own on teardown),
walks `sys_display_enumerate` -> `sys_framebuffer_create` ->
`sys_framebuffer_map` -> 3x `sys_page_flip` + simulated vblank +
`sys_page_flip_wait` -> `sys_display_hotplug_subscribe` +
`hotplug_channel_deliver`. Fingerprint on success:
`boot r105 flip client ok -- flips=3`.

**Design docs:**

- `design/graphics/authority-boundary.md` -- new. Documents the
  compositor-holds-flip-authority / app-client-holds-map-only-fb
  invariant, with a landing-time audit showing zero violations.
- `design/user/syscall-table.md` -- refreshed to include sysnos
  108-113 rows.
- `design/round-retrospectives/r105-closure.md` -- this document.

---

## §2. What deferred

- **Real ring-3 wiring of `sys_framebuffer_map`.** The syscall accepts
  `user_va` and `len` but does not actually re-map the LFB into the
  caller's user PML4 -- the compositor consumes the returned kernel
  VA directly from ring-0 for this landing. The ABI is stable; the
  mmap wire-in arrives with R106 once a per-task PML4 walker is
  available.
- **Deadline-scheduled `sys_page_flip_wait` timeout.** The current
  implementation caps sched_wait iterations at min(timeout_ms, 256)
  rather than fold the timeout into a deadline-scheduled wake. A
  real timer-wheel-driven wake arrives when the R94 timer subsystem
  grows a per-cap deadline table.
- **KIND_PAGE_FLIP LINEAR-mint gate at the supervisor.** No user path
  at R105 can construct a KIND_PAGE_FLIP cap -- the boot witness
  fakes it in-kernel. R104's compositor supervisor is the first
  legitimate call site.
- **Real KIND_HOTPLUG_CHANNEL delivery over the endpoint.** At R105
  the ISR bumps a per-row counter (the visible-effect the witness
  asserts against); an actual event-record enqueue against the
  row's port_slot needs a fixed payload shape (event class +
  output_id + timestamp) that this landing does not define.
- **schedwait alias in `SchedWait` module.** `SCHED_WAIT_PAGE_FLIP =
  2` lives as a local constant inside `cap/kind_page_flip.pdx`
  rather than a public alias in `sched/sched_wait.pdx`; a follow-on
  cross-repo refresh will hoist it.

---

## §3. Encoder-conservative posture (no paideia-as gaps hit)

Every op used lives in the R100 encoder floor already exercised across
the network + PdxFS + R101 GUI landings: `mov` / `mov [reg+imm]` /
`shl` / `shr` / `xor` / `and` / `or` / `cmp` / `je` / `jne` / `jae` /
`jb` / `ja` / `jbe` / `jmp` / `push` / `pop` / `call` / `ret` /
`sub` / `add` / `lea`. No new immediate encodings, no new memop widths,
no jump-table lowering.

The R101 landing already documented `@jump_table` as unavailable at
v0.24.x and used explicit compare chains; R105 follows the same
posture in the dispatch shim block.

**paideia-as encoder gap hit:** none.

---

## §4. Authority-boundary audit findings

Landing-time repo sweep (`grep -rn "cap_mint_write" src/kernel/ |
grep -i "framebuffer\|R_FB_FLIP"`):

| Site | Rights minted | Verdict |
|---|---|---|
| `sys_framebuffer_create_body` (this landing) | `R_FB_MAP` (0x001) | OK |
| `r101_stdvga_checkerboard.pdx` (R101 witness) | never mints the cap; only calls `kind_framebuffer_mint_simple` and holds row_id | OK |
| `r105_flip_client.pdx` (this landing) | delegates to `sys_framebuffer_create_body` -> R_FB_MAP only | OK |

**No site in the tree mints KIND_FRAMEBUFFER with R_FB_FLIP set.** The
invariant in `design/graphics/authority-boundary.md` §1 holds at HEAD.

---

## §5. Fingerprint tags emitted (this landing)

Landing added five new tags (all lowercase, all NUL-terminated per the
tree convention). None trigger the OK_TOK verifier since none embed a
standalone uppercase `OK` outside a bracketed legacy alias.

- `r105 hotplug channel mint ok` -- KindHotplugChannel mint success.
- `r105 page flip mint ok` -- KindPageFlip mint success.
- `boot r105 flip client ok` -- witness success fingerprint (paired
  with `k_flips`).
- `boot r105 flip client skip` -- witness clean skip when Bochs
  device absent.
- `boot r105 flip client fail` -- witness fail funnel (paired with
  `k_line` = stage number).

---

## §6. Files landed

Full list (paths absolute from repo root):

**New:**
- `src/kernel/core/cap/kind_hotplug_channel.pdx`
- `src/kernel/core/cap/kind_page_flip.pdx`
- `src/kernel/core/syscall/handlers/sys_display_enumerate.pdx`
- `src/kernel/core/syscall/handlers/sys_framebuffer_create.pdx`
- `src/kernel/core/syscall/handlers/sys_framebuffer_map.pdx`
- `src/kernel/core/syscall/handlers/sys_page_flip.pdx`
- `src/kernel/core/syscall/handlers/sys_page_flip_wait.pdx`
- `src/kernel/core/syscall/handlers/sys_display_hotplug_subscribe.pdx`
- `src/kernel/boot/witness/r105_flip_client.pdx`
- `design/graphics/authority-boundary.md`
- `design/round-retrospectives/r105-closure.md` (this file)

**Modified:**
- `src/kernel/core/cap/kind.pdx` (KIND_PAGE_FLIP + KIND_HOTPLUG_CHANNEL ordinals)
- `src/kernel/core/syscall/dispatch.pdx` (bounds widen + 6 dispatch shims)
- `src/kernel/boot/kernel_main.pdx` (init call chain + witness call)
- `design/user/syscall-table.md` (rows for 108-113)
- `STATUS.md` (R105 line)

---

## §7. Follow-on obligations tracked

- **R104 real modeset + vblank ISR.** Consumer of KIND_PAGE_FLIP
  needs to wire its actual vblank IRQ handler to call
  `pgfl_deliver_vblank(row_id, PGFL_SRC_VBLANK)`.
- **R106 mmap for `sys_framebuffer_map` user-VA arm.** ABI stable;
  waiting on per-task PML4 walker.
- **R106 deadline-scheduled `sys_page_flip_wait` timeout.** Fold the
  timeout_ms into a timer-wheel-driven deferred wake.
- **`SCHED_WAIT_PAGE_FLIP` hoist.** Move the enum value from
  `kind_page_flip.pdx`-local into `sched/sched_wait.pdx` on next
  cross-repo refresh.
- **R102 userland satellite reification.** The compositor's
  `svc.compositor` service is the first legitimate holder of these
  caps outside the boot witness; R102 lands that satellite.
