# R39.M4 HW-Smoke — BT LE Secure Connections Pairing

R39.M4-004 (#1338).  Hardware-smoke procedure for BT LE Secure
Connections pairing.  Per design decision D7 (`gated:hardware`), this
smoke stays DORMANT in the CI-less local smoke matrix until a real T14
Gen 4 machine with the Intel AX211 CNVi controller is available.  The
placeholder at `tests/kernel/drivers/bt/hw_smoke_pairing_placeholder.pdx`
returns `0` unconditionally so `tools/run-smoke.sh` reports GREEN
without pretending a bring-up ran.

## Prerequisites

- Real T14 G4 with Intel AX211 CNVi (BT + WiFi shared silicon).
- R39.M2 HCI transport reachable (KIND_BT_HCI, KIND_L2CAP channel).
- Working KIND_BT_GATT_CONNECTION path (R39.M3).
- A test peer device (BT LE peripheral) in pairable state, MAC known.
- The R32 crypto server available to unseal the LTK for link setup.

## Procedure

1. Reset the pairing broker: `bpc_reset` and `lesc_init`.
2. Initiate pairing against the test peer:
   `bpc_begin_pairing(peer_lo, peer_hi)` → `pair_slot`.
   Verify the consent dialog fires; accept it manually.
3. Drive P-256 ECDH: `lesc_ecdh_keygen` → `keygen_key`,
   `lesc_ecdh_apply_peer(peer_pub_lo, peer_pub_hi)` → `dhkey`.
4. Confirm passkey (or numeric-compare) via
   `bpc_confirm_passkey(pair_slot, passkey)`.
5. Derive LTK: `lesc_ltk_derive(dhkey)` → `ltk_handle`.
6. Complete pairing: `bpc_complete(pair_slot)` → `sealed_key_slot`.
7. Confirm the SEALED cap: invoke `cap_handler_bt_pairing` op
   BTP_OP_QUERY_SEALED_FLAG on the returned slot; expect `1`.
8. Bond persistence: reboot, then re-derive via
   `bpc_begin_pairing` against the same peer without re-entering the
   passkey; the returned `sealed_key_slot` must resolve to the same
   bonded row.
9. Revoke the pairing: `bt_pairing_cap_revoke(sealed_key_slot)` →
   expect `0`.  Verify subsequent traffic to the peer is refused.

## Success criteria

- Fingerprint emitted: `R39 BT PAIRING HW OK`
- One `drv_audit_emit` record for the mint (event=1), one for the
  revoke (event=2).
- No LTK bytes appear in any user-visible trace.

Until real hardware is present, the placeholder witness in
`tests/kernel/drivers/bt/hw_smoke_pairing_placeholder.pdx` returns 0
and the fingerprint above never appears in the shell-shutdown golden.
