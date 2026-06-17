# PaideiaOS — Terminal: Mouse Interaction

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Mouse interaction in the REPL. Addresses SH-O10.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| MS-D1 | Mouse mode optional; default off | Most users keyboard-only |
| MS-D2 | When on: click-to-position cursor, scroll wheel for history | Standard |
| MS-D3 | Right-click: context menu (paste, copy, etc.) | Familiar |

---

## 1. Activation

```
shell> mouse on
```

Or per-user config in `~/.paideia/shell-config.toml`.

---

## 2. Behaviors with mouse on

- Left-click: position cursor.
- Scroll wheel: scroll history (or pagination of long output).
- Right-click: context menu.
- Selection: select text for copy.

---

## 3. Terminal compatibility

Requires terminal supporting xterm mouse mode (most modern terminals do).

---

## 4. Open issues

| ID | Issue |
|---|---|
| MS-O1 | Terminal-specific quirks. |

---

*End of document.*
