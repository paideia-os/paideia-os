# R97 Retrospective: TLS placement decision + KIND_TLS_CONN reservation

**Date:** 2026-09-01
**Milestones:** R97.M1 (TLS placement decision doc), R97.M2
(KIND_TLS_CONN reservation), R97.M3 (socket-surface sufficiency audit),
R97.M4 (paideia-as cross-repo escalation), R97.M5 (round closure).
**Issues closed at landing:** #2094, #2095, #2096, #2097, #2098, #2099.
**HEAD at closure:** paideia-os (this landing).
**Release tag:** `r97-closed` recommended, though R97 is a design-only
round — no fingerprint attests it on every boot, no `.pdx` code lands.

## Round intent

R97 exists to make the "TLS lives entirely in user-space" commitment
formal at the round-boundary level. That commitment was made 2026-06-17
at `design/network/stack.md` §8 NET-D6 and re-cited in
`design/networking/r91-plan.md` §11, but between "cited in a plan" and
"pinned by a round-closure retrospective" is exactly the gap this round
closes.

R97 lands alongside R96 in a single wave because R97 is design-only
work that shares no build artefacts with R96 — the two rounds are
mutually independent and closing them together keeps the R91-R99
planning cadence tight.

## Per-milestone disposition

### R97.M1 — TLS placement decision doc — LANDED

* **#2094 (M1-001) — Decision doc.**
  `design/networking/tls-placement-decision.md` (new, ~160 lines).
  Formalises the ratification (this is not a fresh design — the
  decision is 2026-06-17's NET-D6) and records the two independent
  lines of reasoning that reconfirm it:
  * **Architecture:** `stack.md` §8 explicitly rejects a kTLS-style
    in-stack integration on key-isolation / independent-update /
    multi-implementation-coexistence grounds.
  * **Crypto substrate:** paideia-as as of 2026-09-01 has SHA-256
    (v0.25.0), HKDF-SHA256 (v0.26.0), X25519 (v0.27.0), and ChaCha20-
    Poly1305 (v0.22.0) landed, but has **no ECDSA-P256 or RSA-2048
    verify intrinsic** — the classical bridge a real Internet TLS 1.3
    handshake needs. Building in-kernel TLS today would compound
    "first real-NIC verification" and "adopt classical crypto" in the
    same wave; user-space termination sidesteps the tension.

### R97.M2 — KIND_TLS_CONN reservation — LANDED

* **#2095 (M2-001) — Reservation.**
  Spec ambiguity resolved: the R97 planning brief suggested reserving
  `KIND_TLS_CONN` at ordinal `0x1B5`, but `0x1AA` was reserved during
  the R91 wave and is already recorded in
  `design/architecture/next-wave-derived-kinds.md` L2382. Reused
  `0x1AA`; no new ordinal minted. See
  `design/networking/tls-placement-decision.md` §3 for the ratchet-
  forward language ("Base ordinal reflects fix#2005's TCP renumber")
  the reservation carries.

### R97.M3 — Socket-surface sufficiency audit — LANDED

* **#2096 (M3-001) — Audit.**
  Recorded in `design/networking/tls-placement-decision.md` §4. Two
  areas checked:
  * **`MSG_PEEK`** — not needed. TLS 1.3 records are self-framing
    (RFC 8446 §5.1 two-byte length prefix); the client always knows
    the exact byte count of the current record from its header, so
    the peek use case that motivates `MSG_PEEK` for line-based
    protocols never arises for TLS.
  * **Partial-write handling on `sys_send`** — no kernel gap. R72's
    per-call 1024-byte cap on `sys_send` is a normal partial-write
    scenario that user-space TLS libraries handle by looping (the
    standard pattern OpenSSL / BoringSSL / Rustls already use). The
    R100 `pdxcurl` and `libpdx-net` designs assume send-loop
    discipline.
* **#2097 (M3-002) — Gap-close if audit finds gap.**
  Disposition: **no-op.** The audit found no gap in either dimension.
  Recorded as such in `design/networking/tls-placement-decision.md`
  §4.3. No separate close-out issue filed.

### R97.M4 — paideia-as cross-repo escalation — LANDED

* **#2098 (M4-001) — File paideia-as issues for TLS classical bridge.**
  Verification against `design/library-status.md` L22 (paideia-as
  crypto state, 2026-09-01 sweep):
  * **SHA-256** — already landed at paideia-as v0.25.0. No filing.
  * **HKDF-SHA256** — already landed at paideia-as v0.26.0. No filing.
  * **ECDSA-P256 sign + verify** — NOT landed. One new paideia-as
    issue filed as non-blocking cross-repo escalation. See
    `design/networking/tls-placement-decision.md` §5 for the framing
    (classical bridge compat concession, not retreat from Pillar 6).

  The R97.M4-001 filing exposes a subordinate spec ambiguity: paideia-
  os's submodule pointer for paideia-as is still at v0.24.0 per the
  2026-09-01 library-status sweep note, so even the *landed* SHA-256 /
  HKDF-SHA256 / X25519 primitives are not yet callable from `.pdx` in
  this tree until the submodule bump. That bump is main's decision
  (3 minor + 1 patch version jump is substantial); this retrospective
  notes it as a live gate against any future TLS-adjacent kernel work
  but not against R97 itself.

### R97.M5 — round closure — LANDED

* **#2099 (M5-001) — This retrospective.**

## What did NOT land in R97

* **No `KIND_TLS_CONN` implementation.** Reservation only — the
  landing is deferred to a future round when paideia-as has the
  classical bridge primitives (ECDSA-P256 minimum) AND the substrate
  is a natural fit for in-kernel termination (which requires either
  a Phase-2 `net-stack` server split or a different assessment of
  the key-isolation trade-off that produced NET-D6 in the first
  place).
* **No paideia-as submodule bump.** Main-scope decision; R97 flags
  the live version gap and leaves the bump to a dedicated pass.
* **No `net/tls_*.pdx`, no `sys_tls_*` syscalls, no
  `net/tcp*.pdx` extensions.** R97 is design-only.

## Spec ambiguities resolved during landing

* **KIND_TLS_CONN ordinal.** Planning brief said `0x1B5`; already
  reserved at `0x1AA` from R91.
* **SHA-256 escalation.** Planning brief listed it; library-status
  shows it landed at v0.25.0. Escalation dropped from the filing.
* **HKDF-SHA256 escalation.** Planning brief listed it; library-status
  shows it landed at v0.26.0. Escalation dropped from the filing.
* **R97.M3-002 disposition.** Planning brief said "if audit finds a
  gap, close it"; the audit found no gap; recorded as no-op in the
  audit doc.

## Files touched

| File | Kind | Notes |
|---|---|---|
| `design/networking/tls-placement-decision.md` | new doc (~185 lines) | R97.M1-001 + M3-001/002 audit |
| `design/round-retrospectives/r97-closed.md` | new doc (this file) | R97.M5-001 |
| paideia-as new issue (ECDSA-P256) | cross-repo | R97.M4-001 |

**No `.pdx` code, no fingerprint, no witness lands in R97.**

## Cross-references

* `design/network/stack.md` §8 NET-D6 — the primary decision this
  round ratifies.
* `design/networking/r91-plan.md` §11 — the plan this round closes.
* `design/round-retrospectives/r96-closed.md` — sibling wave-closing
  round.
* `design/library-status.md` — paideia-as crypto state that grounds
  the M4 escalation filing.
