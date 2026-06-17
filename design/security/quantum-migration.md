# PaideiaOS — Security: Quantum-Readiness Migration Plan

**Status:** Living document
**Date:** 2026-06-17
**Scope:** Plan for migrating away from classical components when a cryptographically-relevant quantum computer (CRQC) emerges. Addresses PQ-O13.

---

## 0. Trigger event

A credible CRQC capable of breaking 256-bit ECDLP (Curve25519, P-384) within reasonable wall-clock.

## 1. Pre-trigger state

PaideiaOS uses hybrid (classical + PQ) signatures and KEMs. The classical component is a hedge against PQ-cryptanalysis.

## 2. Post-trigger response

1. Issue an emergency catalog update marking classical primitives `deprecated`.
2. New artifacts use pure-PQ schemes.
3. Existing artifacts remain verifiable via PQ component alone (the hybrid construction is designed for this).
4. Rotation cadence + event-driven rotation phases out classical.

## 3. Algorithm successor selection

Move to pure-PQ schemes:
- Release artifacts: ML-DSA-65 (was hybrid Ed25519 + ML-DSA-65).
- Boot chain: SLH-DSA-128s (already pure-PQ).
- Root: SLH-DSA-256s (already pure-PQ).
- KEM: ML-KEM-1024 (already pure-PQ post-migration).

## 4. Periodic re-evaluation

Annual: review of cryptanalysis state.

---

*End of document.*
