# tools/hw-smoke-g8.md — G8 input-routing bring-up recipe

Operator recipe for the G8 input-routing hardware-only test, per D7
`gated:hardware` discipline. This does NOT run in CI or QEMU; it
runs on a real ThinkPad T14 Gen4 (12th-gen + successors) with an
Elan touchpad and — for T3 — a Bluetooth 4 dock/keyboard paired
against the R39 BT stack landed in prior Waves.

This is the terminal doc for the G8 input-routing milestone. It
closes issues #2274, #2275, #2276, #2277, #2278, #2279, #2280,
#2281, #2282, #2283, #2284, #2285, #2286, and this one (#2287). It
exercises the full input stack end-to-end: KIND_INPUT_SERVER,
KIND_SEAT, KIND_INPUT_ROUTE (linear), per-device pointer accel, and
hot-plug seat binding across the BT4 dock.

The smoke is marked `dormant` under CI — the input-server witness
sidecar is present in the tree but is not called from the QEMU boot
path. See §6 (Wiring pending) for what the follow-up wire-body
milestone must land before this recipe runs against real firmware.

---

## 1. Purpose

Prove end-to-end input-routing on real T14 Gen4 hardware. The
single boot exercises:

- `KIND_INPUT_SERVER` dispatch of `KIND_HID_EVENT` streams from the
  R32 HID substrate into per-seat queues;
- `KIND_SEAT` binding across the Elan I2C-HID touchpad and the
  built-in keyboard, with hot-plug rebinding when a BT4 dock
  keyboard appears;
- `KIND_INPUT_ROUTE` mint + delivery under the LINEAR discipline
  (one owner at a time; a new mint revokes the prior route);
- per-device pointer accel curves applied to touchpad motion
  before delivery;
- `seat_lock` / `seat_unlock` mediation refusing route mints while
  a seat is locked (per the emergency-console handover flow
  landed in G8-M5-002).

The R32 HID stream, R39 BT-HID pairing, and R31 hotkey substrates
are already integrated per prior Wave landings and are
pre-conditions, not part of the test matrix here.

## 2. Prerequisites

- Reference hardware: ThinkPad T14 Gen4 (or any laptop the
  fingerprint sheet lists with an Elan I2C-HID touchpad and a
  Bluetooth 4 controller) with the R32 HID stack, R39 BT-HID
  pairing, and R31 hotkey substrates all landed and reporting
  their fingerprints on the boot log before the G8 witness runs.
- One paired BT4 keyboard (any dock or standalone unit already
  registered against R39-M2 pairing) available and powered on for
  T3.
- Boot mode: `-kernel` via `boot_stub.S`, opted into the 14-mode
  matrix's `g8-input-routing` slot; the loader sets
  `PAIDEIA_G8_SMOKE=1` in the `_init_caps` sidecar.
- `KIND_INPUT_SERVER` booted per G8-M1-001 and reporting its
  init fingerprint on the boot log before the G8 witness runs.
- `KIND_SEAT` bound to the built-in keyboard + Elan touchpad per
  G8-M5-001 (single-seat default).
- `KIND_INPUT_ROUTE` mint dispatcher available per G8-M2-001.
- Prior G7 first-window bring-up passes (there is one
  `KIND_SURFACE` to route events into; T1..T5 mint routes against
  it).
- USB serial cable + minicom/screen for the boot log.

## 3. Test matrix

Five sub-tests, run in order, one boot. Each emits an explicit
fingerprint on the serial log on PASS; on FAIL the witness halts
after emitting the offending fingerprint's `FAIL` variant.

### T1: keyboard route delivery

Mint a `KIND_INPUT_ROUTE` from the built-in-keyboard slot of the
default `KIND_SEAT` to the G7 witness `KIND_SURFACE`. The operator
presses Fn+F1..Fn+F4 (four Fn-modified keys — chosen so they cannot
be swallowed by an R31 hotkey handler). Witness counts events
delivered against the route and asserts N==4 within the per-test
deadline.

- PASS: `G8 KBD ROUTE OK count=<N>`
- FAIL: `G8 KBD ROUTE FAIL stage=<mint|deliver|count> observed=<N>`

### T2: Elan touchpad pointer route

Mint a `KIND_INPUT_ROUTE` from the Elan-touchpad pointer slot of
the default `KIND_SEAT` to the same `KIND_SURFACE`. The operator
drags one finger across the touchpad; witness collects 100 motion
deltas and asserts the per-device accel curve (bound at G8-M2 mint
time) has been applied (delivered dx/dy differ from raw HID dx/dy
per the configured curve's identity map at v==0 boundary).

- PASS: `G8 PTR ROUTE OK count=100`
- FAIL: `G8 PTR ROUTE FAIL reason=<mint|deliver|accel_missing|timeout> at=<N>`

### T3: BT4 dock keyboard hot-plug

With the default seat already bound (T1 passed), power on / dock
the paired BT4 keyboard. Witness expects the input-server hot-plug
handler to attach the new `KIND_HID_DEVICE` to the default seat's
keyboard slot list, mint no new seat, and route delivery to
continue working (operator presses one key on the BT keyboard;
witness observes one event on the existing route).

- PASS: `G8 HOTPLUG BIND OK dev=BT_KBD`
- FAIL: `G8 HOTPLUG BIND FAIL reason=<no_detect|new_seat|no_deliver|timeout>`

### T4: seat lock refusal

Invoke `seat_lock` on the default seat (per G8-M5-002 emergency-
console handover flow). Attempt to mint a fresh
`KIND_INPUT_ROUTE`. Assert the dispatcher returns
`E_SEAT_LOCKED` and no route slot is allocated. Unlock via
`seat_unlock`; assert a subsequent mint succeeds.

- PASS: `G8 LOCK REFUSE OK code=SEAT_LOCKED`
- FAIL: `G8 LOCK REFUSE FAIL observed=<code> allocated=<0|1>`

### T5: LINEAR revoke on focus change

Mint route A (keyboard slot → surface X). Mint route B (keyboard
slot → surface Y) — under LINEAR discipline this must revoke
route A. Operator presses one key; witness asserts the delivery
lands on B, and asserts a delivery attempt against A's stale slot
returns `E_ROUTE_STALE`.

- PASS: `G8 LINEAR REVOKE OK`
- FAIL: `G8 LINEAR REVOKE FAIL reason=<no_revoke|dual_deliver|stale_missing>`

## 4. Failure taxonomy

Serial output to grep for each expected error path:

- `SKIP: no R32 HID` — HID substrate not integrated; abort before
  T1 (nothing to route).
- `SKIP: no R39 BT` — BT-HID pairing substrate not integrated;
  abort before T3 (still runs T1, T2, T4, T5 if operator has no
  BT4 keyboard).
- `SKIP: no G7 surface` — G7 first-window witness did not land a
  `KIND_SURFACE` for routes to target; abort before T1.
- `G8 * FAIL ...` — one of the five test fingerprints listed
  above; the witness halts immediately, no further tests run.
- `E_SEAT_LOCKED` — the expected refusal code from T4; presence
  is the PASS signal, absence is the FAIL signal.
- `E_ROUTE_STALE` — the expected error on the revoked route A in
  T5; presence is part of the PASS signal.
- `#PF at <rip>` in the interval — page fault inside an
  input-server or HID delivery path; treat as a hard regression,
  capture full serial and open a bug.
- `WATCHDOG G8 T<n>` — a test failed to emit either its PASS or
  FAIL fingerprint before its per-test 2-second timeout (5-second
  for T3 to allow BT4 discovery); witness halts.

## 5. Success criteria

- All five tests pass in one boot, in order.
- All five fingerprints appear on the serial log in the order
  T1, T2, T3, T4, T5.
- No `G8 * FAIL` line anywhere in the log.
- No `#PF` inside the G8 window (between the G7 CLOSE line and
  the G8 CLOSE line).
- No `WATCHDOG G8 T<n>` line.
- Serial log ends with:

      G8 CLOSE OK issues=2274,2275,2276,2277,2278,2279,2280,2281,2282,2283,2284,2285,2286,2287

## 6. Wiring pending

The KIND_INPUT_SERVER / KIND_SEAT / KIND_INPUT_ROUTE dispatchers
landed in G8-M1..M5 are NOT yet wired into
`src/kernel/boot/kernel_main.pdx`. This doc specifies what the
future input wire-body milestone (post-G8, deferred, not yet
filed) must verify. That milestone must:

- Register the G8 cap kinds (KIND_INPUT_SERVER, KIND_SEAT,
  KIND_INPUT_ROUTE) in the boot cap table (alongside the G7
  compositor caps once G7 wire-body lands).
- Bind the input-server dispatch loop into the init-cap sidecar,
  subscribing to the R32 HID event channel at boot.
- Add the `PAIDEIA_G8_SMOKE=1` env var to the
  `tools/run-smoke.sh` mode matrix.
- Add the G8 witness call at the tail of the G8 block in the
  platform init file (mirroring the G4/G5/G7 witness-wiring
  shape).

Until that milestone lands, this recipe is a specification for the
tester, not an executable procedure. The build-time gate in
`tools/build.sh` continues to pin the G8 cap-table writers to
their owner objects; the wire-body milestone must extend that gate,
not remove pins.

## 7. Reproduction command

Once the wire-body milestone lands, the T14 tester runs:

    PAIDEIA_G8_SMOKE=1 bash tools/run-smoke.sh

Note that `PAIDEIA_G8_SMOKE` is not yet wired into
`tools/run-smoke.sh`; the mode matrix add is part of the wire-body
milestone (see §6). Before that lands, the operator can manually
patch `_init_caps` in the loader sidecar to set the sentinel and
boot the T14 by hand — the witness will run against whatever
G8 dispatchers are reachable, but the R32/R39 pre-conditions still
guard T1..T3.

---

## Notes

The HW-smoke exercises the input-server / seat / route primitives
that the G8 milestone lands, so a failure of the QEMU-side dormant
witnesses (`kind_input_server_synth.pdx`, `kind_seat_synth.pdx`,
`kind_input_route_synth.pdx`, `pointer_accel_synth.pdx`,
`seat_lock_synth.pdx`, `g8_integration_synth.pdx`) means this HW
smoke will not run either — the primitive itself has regressed.
Fix the QEMU witnesses first.

Cross-reference `tools/hw-smoke-g7.md` for the compositor
substrate T1..T5 mint routes against (there must be at least one
`KIND_SURFACE` for a route to target), `tools/hw-smoke-r39-bthid.md`
for the BT4 pairing substrate T3 depends on, and
`design/compositor/pwp-spec-vocabulary.md` §2.9..§2.10 for the
KIND_SEAT / KIND_INPUT_ROUTE type signatures the witness asserts
against.
