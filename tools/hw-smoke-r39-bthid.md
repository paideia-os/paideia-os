# R39.M6 HW-Smoke — BT HID keystroke latency

R39.M6-004 (#1346).  Hardware-smoke procedure for BT HID (keyboard,
mouse, trackpad) over L2CAP.  Per design decision D7
(`gated:hardware`), this smoke stays DORMANT in the CI-less local
smoke matrix until a real T14 Gen 4 machine with the Intel AX211 CNVi
controller and a BT-attached HID peripheral is available.  The
placeholder at `tests/kernel/drivers/bt/hw_smoke_bthid_placeholder.pdx`
returns `0` unconditionally so `tools/run-smoke.sh` reports GREEN
without pretending a bring-up ran.

## Prerequisites

- Real T14 G4 with Intel AX211 CNVi (BT + WiFi shared silicon).
- R39.M2 HCI transport reachable (KIND_BT_HCI, KIND_L2CAP channel).
- LE Secure Connections pairing complete against the peer (R39.M4);
  KIND_BT_PAIRING SEALED cap in hand.
- SDP against the peer confirms class 0x1124 (HID) and the peer
  reports two L2CAP PSMs: 0x11 (Control) and 0x13 (Interrupt).
- R32 HID substrate live: a KIND_HID_DEVICE row minted for the peer,
  the R32.M3 event-stream fan-out (KIND_HID_EVENT) bound to a
  listening subscriber.
- A BT HID peripheral that reports at a bounded rate (a keyboard is
  ideal; most report at 100 Hz).

## Procedure

1. Reset the BT HID module: `bthid_init`.
2. Open the two L2CAP channels against the peer via the R39.M2 HCI
   transport, obtaining `ctrl_cid` (PSM 0x11) and `intr_cid`
   (PSM 0x13).
3. Bind: `bthid_bind(BTHID_KIND_KEYBOARD, ctrl_cid, intr_cid,
   hid_device_slot)` -> `row`.
4. Configure the peer via the control channel:
   - `SET_PROTOCOL(REPORT)` per BT HID §7.4.6.
   - `GET_REPORT` on any feature report the R32.M2 parser flagged as
     mandatory (usually none for a boot-protocol keyboard).
5. Enable interrupt-channel streaming: send an `HID_INTR_DATA` PDU on
   `intr_cid` with a subscribe request.
6. Instrument the R32 event stream: subscribe to
   `KIND_HID_EVENT` and record a monotonic timestamp per delivered
   event.
7. Operator presses a key on the paired keyboard.
8. Assert: the corresponding `KIND_HID_EVENT` arrives within 40 ms of
   the button-down event.  (BT HID typical: 15..25 ms; 40 ms is the
   ceiling above which the R31 event scheduler will still deliver but
   the assertion fires.)
9. Operator holds a key.  Assert: `bthid_stat(BTHID_ST_REPORTS)`
   advances at the peer's advertised report rate ± 10 %.
10. Tear down: `bthid_unbind(row)`.

## Success criteria

- Fingerprint emitted: `R39 BT HID HW OK`
- Measured per-keystroke latency: < 40 ms end-to-end.
- Measured sustained report rate matches the peer's advertised value.
- `bthid_stat(BTHID_ST_REFUSED)` is 0.

Until real hardware is present, the placeholder witness in
`tests/kernel/drivers/bt/hw_smoke_bthid_placeholder.pdx` returns 0 and
the fingerprint above never appears in the shell-shutdown golden.
