# R83 Retrospective (PARTIAL): Wi-Fi + Bluetooth live

**Date:** 2026-08-25
**Milestone:** R83.M1 (single-milestone round)
**Issues:** 9 landed-as-scaffold/PROVISIONAL (#1858, #1859, #1860,
#1862, #1863, #1864, #1866, #1867, #1870); 0 partial; 0 deferred
(all substantive issues have real code); this doc closes #1871.
**HEAD at audit:** paideia-os bbb3d35 (fresh worktree, no code changes
made by this audit).
**Release tag:** `r83-closed` recommended as a partial-close, per the
R58/R59/R74/R78/R84 precedent — code-complete, real-radio-blocked.

## Round intent

Per `design/roadmap/post-r60-daily-use-roadmap.md:521-522`: "Extensive
AX211/WPA3-SAE/net80211/hci_cnvi/gatt/a2dp/hfp driver corpus exists;
live-exercise against real radios/firmware." This is the most complete
scaffold of the seven audited rounds by line count: `src/kernel/core/
drivers/wifi/` (18 files) + `src/kernel/core/drivers/bt/` (12 files),
20,725 lines total. Confirmed: QEMU has no 802.11 radio model and no
Bluetooth radio model (`virtio-net` is not 802.11; no AX211/CNVi
emulation exists) — this entire round is real-hardware-only, requiring
actual RF association with a real AP and pairing with real BT
peripherals.

## Per-issue disposition

### #1858 — AX211 firmware load real-hw path — LANDED (PROVISIONAL)
`ax211_probe.pdx`, `fw_load.pdx`, `fw_verify.pdx`, `fw_compat.pdx`:
firmware-file location, version-compat gating, and load-sequence
scaffold. Real-hardware-only (`iwlwifi-ty-*.ucode` load against actual
AX211 silicon).

### #1859 — Wi-Fi scan: active + passive scan, AP list — LANDED (PROVISIONAL)
`net80211_mgmt.pdx`, `net80211_mlme.pdx`: management-frame handling and
MLME scan-state logic.

### #1860 — WPA3-SAE association: 4-way handshake, PTK/GTK install — LANDED (PROVISIONAL)
`wpa3_sae.pdx`, `wpa_4way.pdx`, `net80211_assoc.pdx`: SAE FSM policy
and 4-way handshake state machine. **Named cross-round dependency:**
`wpa3_sae.pdx`'s own header states "IT DOES NOT COMPUTE THE ECC
POINT... hash-to-element and the hunting-and-pecking password-to-curve
mapping are the crypto server's (R32) business" — i.e. this issue's
SAE *policy* is real and complete, but the underlying elliptic-curve
math it depends on is delegated to the crypto subsystem this audit's
companion R82 retrospective found to be almost entirely unstarted
(no ECC/lattice math anywhere in `src/kernel/core/crypto`-equivalent
paths). This is a genuine forward dependency worth surfacing: WPA3-SAE
cannot actually complete a handshake until R82's crypto math lands, not
only until real hardware is available.

### #1862 — 802.11ax data path live: send/receive real frames, ping — LANDED (PROVISIONAL)
`tx_dma.pdx`, `dma_domain.pdx`, `he_mcs.pdx`, `rate_control.pdx`: DMA
ring + HE-MCS rate-selection scaffold.

### #1863 — CNVi Bluetooth firmware handoff (shared radio) — LANDED (PROVISIONAL)
`hci_cnvi.pdx`: HCI transport staging ring for the shared iwlwifi/iwlbt
firmware pair, explicit in its header about the shared-ring
race it guards against (single stager discipline).

### #1864 — HCI + L2CAP + GATT live: discover paired device, read
characteristic — LANDED (PROVISIONAL)
`l2cap_fixed.pdx`, `l2cap_dyn.pdx`, `att.pdx`, `gatt.pdx`: channel
multiplexing (fixed + dynamic CIDs), ATT PDU framing, GATT
service/characteristic model.

### #1866 — A2DP audio sink (paired-speaker) live playback — LANDED (PROVISIONAL)
`a2dp.pdx`, `a2dp_bridge.pdx`, `a2dp_rtx.pdx`: SBC/AAC stream setup and
RTP-style retransmission scaffold. Real code exists for this profile —
notable since Bluetooth audio profiles are enough protocol surface
that "nothing exists yet" was a real possibility checked for; it is
not the case here.

### #1867 — HFP handsfree profile live (paired-headset) — LANDED (PROVISIONAL)
`hfp.pdx`: handsfree AT-command/SCO scaffold.

### #1870 — LE Audio live (paired-earbuds) — LANDED (PROVISIONAL)
`le_audio.pdx`, `le_sc.pdx`: LE Audio (LC3/ISO channels) + LE Secure
Connections pairing scaffold.

### #1871 — Round closure — this document
STATUS + retrospective + `r83-closed` tag, partial-close discipline.

## Cross-repo escalations

None (paideia-as language/toolchain side). The #1860 crypto dependency
noted above is a **cross-round**, not cross-repo, escalation — flagging
it here for the roadmap sequencer rather than filing it as a paideia-as
issue.

## Observable proof

Driver corpus builds under its original R38/R39 landing witnesses; no
new observable produced by this audit (no code changes made, no real
radio available in this environment).

## Debt inventory (carried forward)

1. **Real AX211/CNVi radio + real AP + real BT peripherals (speaker,
   headset, earbuds)** — every issue in this round needs a live T14 G4
   session; none of it is buildable-without-hardware debt the way
   several R81/R82 items are.
2. **R82 crypto dependency on #1860** — WPA3-SAE's ECC math is not
   this round's job, but its absence (per the R82 retrospective) means
   even a full real-hardware session cannot complete a SAE handshake
   until R82 lands the underlying primitives. Sequence R82 before a
   real R83 hardware pass, not just before R83's audit.

**Next round:** R84 (Thunderbolt 4 / USB4 live) is the natural sibling
— same disposition shape (code-complete, real-hardware-only). Given
finding (2) above, recommend prioritizing R82's non-hardware-gated
debt (entropy pool, ML-KEM, ML-DSA, SLH-DSA) before scheduling the
real-hardware session that would exercise R83.
