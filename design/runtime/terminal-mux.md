# PaideiaOS — Runtime: Interactive Jail Terminal Multiplexing

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Terminal I/O for interactive WASM/VM jails (vim, etc.). Addresses JAIL-O12.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| TM-D1 | Terminal I/O via virtio-console for VM jails | Standard |
| TM-D2 | Terminal I/O via WASI stdio for WASM jails | Standard WASI |
| TM-D3 | Shell session pipes virtio-console / WASI stdio to actual terminal | Bridging |
| TM-D4 | TTY escape sequences pass through | Compatibility |
| TM-D5 | Window-size events forwarded via virtio extension or WASI | Standard |

---

## 1. Architecture

```
   User's terminal
        │ (ANSI escapes)
        ▼
   Shell session
        │ pipes via typed channel
        ▼
   Jail process (WASM or VM)
   - WASM: WASI stdio
   - VM: virtio-console
        │
        ▼
   Application (vim, etc.)
```

---

## 2. Window size

When the user's terminal resizes:
- Shell receives SIGWINCH-equivalent.
- Shell sends window-size update to jail.
- Jail propagates to application.

---

## 3. Open issues

| ID | Issue |
|---|---|
| TM-O1 | TTY raw-mode vs cooked-mode handling. |
| TM-O2 | Mouse events through the jail. |

---

*End of document.*
