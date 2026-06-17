# PaideiaOS — Drivers: Per-Driver Test Pattern

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Test patterns each driver must ship. Addresses DR-O11.

---

## 0. Required tests per driver

- Lifecycle FSM tests (every transition).
- Capability-coverage tests.
- Crash-and-restart tests.
- Handoff tests (if applicable).
- Performance regression tests.

---

## 1. Lifecycle FSM tests

For each transition in the driver's lifecycle FSM:
- Trigger the transition.
- Verify state changes.
- Verify side effects (logged events, IPC sent, etc.).

---

## 2. Capability-coverage tests

Each capability the driver declares:
- Use it; verify operation succeeds.
- Don't have it; verify operation fails with documented error.
- Audit log records denial.

---

## 3. Crash-and-restart tests

- Trigger crash (deliberate panic).
- Verify supervisor restarts.
- Verify clients reconnect via service registry.

---

## 4. Handoff tests (if applicable)

- Start two driver versions simultaneously.
- Trigger handoff.
- Verify state preserved across handoff.

---

## 5. Performance regression tests

- Per-driver micro-benchmarks.
- Baselines tracked over time.
- Regression > 10% triggers alert.

---

## 6. Open issues

| ID | Issue |
|---|---|
| PDT-O1 | Common test harness for all drivers. |

---

*End of document.*
