# PaideiaOS — Dev Env: Assembly-as-Host-Test-Target Harness

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Test harness that links assembled kernel data-structure code into a host process. Addresses dev-env S8.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| HTH-D1 | Kernel data-structure modules are unit-tested on the host | Speed |
| HTH-D2 | Harness wraps assembled modules in a host-runnable shim | Standard |
| HTH-D3 | Tests run as standard Linux processes (not in QEMU) | Speed |

---

## 1. Architecture

```
kernel data-structure module (paideia-as)
        |
        v compiled to ELF object
shim layer (host-side Rust/C)
        |
        v provides test scaffolding
        v links module
        v exposes test entry points
host test runner
```

---

## 2. Why on host

Unit testing kernel data structures (slab allocators, hash maps, trees) doesn't need full kernel boot. Running on Linux as a normal process is dramatically faster.

---

## 3. Limitations

- No kernel-specific features (no real interrupts, no MMIO).
- Tests are for *pure logic* only.

---

## 4. Open issues

| ID | Issue |
|---|---|
| HTH-O1 | Shim layer language — Rust most likely (matches paideia-as Rust impl). |

---

*End of document.*
