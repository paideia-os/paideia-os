# PaideiaOS — Terminal: Line Editor Bindings

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Vi-mode and emacs-mode bindings for the shell line editor. Addresses SH-O5.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| LE-D1 | Vi-mode and emacs-mode both supported | User preference |
| LE-D2 | Emacs-mode is default (most common) | Modern convention |
| LE-D3 | Bindings configurable via `~/.paideia/shell-keys.toml` | Customization |
| LE-D4 | Multi-line editing supported in both modes | Modern |

---

## 1. Emacs-mode core bindings

| Binding | Action |
|---|---|
| C-a | Beginning of line |
| C-e | End of line |
| C-f / C-b | Forward / back character |
| M-f / M-b | Forward / back word |
| C-k | Kill to end of line |
| C-u | Kill to beginning |
| C-y | Yank |
| C-_ / C-x C-u | Undo |
| C-r | Reverse history search |
| C-s | Forward history search |
| TAB | Completion |
| RET | Submit |
| C-x C-e | Open in editor |

---

## 2. Vi-mode core bindings

Normal mode: standard Vim motions (`h`, `j`, `k`, `l`, `w`, `b`, `0`, `$`, `gg`, `G`).
Insert mode entered with `i`, `a`, `I`, `A`, `o`, `O`.
Operators (`d`, `c`, `y`) combined with motions.
Marks, registers, macros (limited).

---

## 3. Configuration

```toml
[shell.line-editor]
mode = "emacs"   # or "vi"

[shell.line-editor.custom-bindings]
"C-x C-x" = "swap-cursor-and-mark"
```

---

## 4. Open issues

| ID | Issue |
|---|---|
| LE-O1 | Mouse-mode integration. |
| LE-O2 | Multi-line editing in vi-mode — complex (especially text-object boundaries). |

---

*End of document.*
