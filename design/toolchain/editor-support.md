# PaideiaOS — paideia-as Editor Support

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Editor integration plan for paideia-as: LSP server, syntax highlighting grammars, and per-editor configuration recipes for VS Code, Helix, Emacs, and Vim. Addresses AS6 from `custom-assembler.md`.

**Hard inputs:**
- `custom-assembler.md` §11.3 — LSP server architecture.
- `custom-assembler.md` §13 — tooling layout (`paideia-lsp`, `paideia-fmt`).

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| ED-D1 | LSP server: `paideia-lsp`, a separate binary that links the elaborator as a library | §11.3 binding |
| ED-D2 | First-class editors: VS Code, Helix, Emacs, Vim (Neovim) | Cover the dominant 2026 editor ecosystem |
| ED-D3 | Syntax highlighting: Tree-sitter grammar (consumed by all four editors) | One grammar, many editors |
| ED-D4 | Configuration shipped in `tools/editor/<editor-name>/` directory of the assembler repo | Single source of truth |
| ED-D5 | LSP protocol version: 3.17 or later | Modern features required |
| ED-D6 | Editor integration is required-for-phase-1 contributor support, not phase-3+ luxury | Working in a typed-elaborator + substructural language without LSP is impractical |

---

## 1. LSP server architecture

### 1.1 Capabilities supported

The LSP server (`paideia-lsp`) handles:
- `textDocument/diagnostics` — push errors as user types.
- `textDocument/hover` — show inferred substructural class, effect row, capability set.
- `textDocument/definition` — jump to definition.
- `textDocument/references` — find all uses.
- `textDocument/codeAction` — quick fixes.
- `textDocument/completion` — autocomplete.
- `textDocument/formatting` — invoke `paideia-fmt`.
- `textDocument/rename` — rename symbol across files.
- `textDocument/semanticTokens` — semantic highlighting (richer than syntactic).
- `workspace/symbol` — module/functor search.
- `workspace/configuration` — read user settings.

### 1.2 Incremental compilation

The server maintains an in-memory cache of parsed and elaborated files. On change:
1. The change is diffed against the previous version.
2. Affected files are re-elaborated incrementally.
3. Diagnostics are pushed for changed files only.

Target latency: < 100 ms for a single-character change in a typical file.

### 1.3 Multi-root workspace

The server supports multiple workspace roots (a user's project may span multiple directories). Modules from different roots resolve via the union of root manifests.

### 1.4 Transport

stdio (default; standard LSP). TCP for remote editor scenarios (rare).

---

## 2. Tree-sitter grammar

A single Tree-sitter grammar at `tools/editor/tree-sitter-paideia/` is consumed by VS Code, Helix, Emacs, Neovim, and any other Tree-sitter-aware editor.

### 2.1 Tokens

The grammar tokens mirror `syntax-reference.md` §2.3:
- Keywords
- Identifiers (including Unicode XID_Start)
- Literals (numbers, strings, characters)
- Operators (Unicode and ASCII forms)
- Punctuation
- Effect/capability brackets
- Substructural markers
- Comments (line, block, doc)

### 2.2 Productions

Matches the EBNF in `syntax-reference.md` §8. The grammar is designed for error recovery (partial parses produce useful results when the user is mid-edit).

### 2.3 Queries

Highlighting queries at `tools/editor/tree-sitter-paideia/queries/`:
- `highlights.scm` — syntactic highlighting.
- `injections.scm` — embedded language injection (e.g., `unsafe` block contents as raw assembly).
- `locals.scm` — scope tracking for jump-to-definition.
- `tags.scm` — symbol extraction for navigation.

---

## 3. VS Code

### 3.1 Extension structure

`tools/editor/vscode/` contains a complete VS Code extension:
- `package.json` — extension manifest.
- `client.ts` — LSP client wiring.
- `syntaxes/paideia.tmLanguage.json` — TextMate grammar (fallback when Tree-sitter unavailable).
- `language-configuration.json` — auto-pairs, comment toggling, indentation.

### 3.2 Activation

Activates on `*.pdx`, `*.pdi`, `*.pds` files.

### 3.3 Configuration

User settings (under `paideia.*`):
- `paideia.lsp.path` — path to `paideia-lsp` binary (auto-discovered if in PATH).
- `paideia.fmt.onSave` — format on save (default: true).
- `paideia.lint.enabled` — show lint diagnostics (default: true).
- `paideia.preview.unicode` — render Unicode glyphs (default: true).

### 3.4 Distribution

Phase 2: published to the VS Code Marketplace (requires Marketplace publisher account).

Phase 1 (now): users install from VSIX file built locally.

---

## 4. Helix

### 4.1 Configuration

Helix has built-in Tree-sitter support. Users add to `languages.toml`:

```toml
[[language]]
name = "paideia"
scope = "source.paideia"
file-types = ["pdx", "pdi", "pds"]
roots = ["paideia-os.toml"]
language-servers = ["paideia-lsp"]
auto-format = true
formatter = { command = "paideia-fmt", args = ["--stdin"] }
indent = { tab-width = 2, unit = "  " }

[[grammar]]
name = "paideia"
source = { git = "https://github.com/paideia-os/paideia-as", subpath = "tools/editor/tree-sitter-paideia" }
```

The Tree-sitter grammar is fetched from the assembler repo at the pinned commit.

### 4.2 LSP server config

```toml
[language-server.paideia-lsp]
command = "paideia-lsp"
```

### 4.3 Distribution

A `tools/editor/helix/install.sh` script automates the languages.toml update.

---

## 5. Emacs

### 5.1 Mode

A custom `paideia-mode` derived from `prog-mode`, defined in `tools/editor/emacs/paideia-mode.el`.

Features:
- Tree-sitter-based syntax highlighting (Emacs 29+ has built-in tree-sitter support).
- LSP integration via `lsp-mode` or `eglot`.
- Format on save via `paideia-fmt`.
- Indentation rules.

### 5.2 Activation

```elisp
(use-package paideia-mode
  :mode (("\\.pdx\\'" . paideia-mode)
         ("\\.pdi\\'" . paideia-mode)
         ("\\.pds\\'" . paideia-mode))
  :hook (paideia-mode . eglot-ensure))
```

### 5.3 Distribution

Phase 2: published to MELPA.

---

## 6. Neovim

### 6.1 Setup

Using nvim-lspconfig:

```lua
require'lspconfig'.paideia_lsp.setup{
  cmd = { 'paideia-lsp' },
  filetypes = { 'paideia' },
  root_dir = require'lspconfig.util'.root_pattern('paideia-os.toml', '.git'),
}
```

Tree-sitter parser registered via nvim-treesitter:

```lua
require'nvim-treesitter.configs'.setup {
  ensure_installed = { 'paideia' },
  highlight = { enable = true },
}
```

The parser source location is in `parser-info/paideia.lua`.

### 6.2 Distribution

A `tools/editor/nvim/setup.lua` script automates the configuration.

---

## 7. Formatter integration

`paideia-fmt` runs in all editors. Configuration is identical:
- Read from stdin or filename.
- Output to stdout.
- Exit code 0 on success.
- Editor invokes on save (if configured).

### 7.1 Project-level config

A project's `paideia-fmt.toml` controls:
- ASCII vs Unicode preference (per `syntax-reference.md` §11).
- Line length (default 100).
- Indent style (default 2 spaces).
- Other style preferences.

---

## 8. Diagnostic display

All editors receive LSP diagnostics with:
- The diagnostic code (`Cxxxx`, per `diagnostics.md`).
- The severity (error / warning / hint).
- The structured payload.
- Code-action suggestions.

Inline display:
- VS Code: red/yellow squiggles under the span.
- Helix: gutter icons + status-line message.
- Emacs: `flymake`-style overlays.
- Neovim: `vim.diagnostic` API.

---

## 9. Hover

Hovering over a symbol shows (LSP `textDocument/hover`):
- Symbol kind (variable, function, type, module).
- Inferred type.
- Inferred substructural class (linear, affine, …).
- Inferred effect row.
- Documentation comment (doc-comment from declaration).

For capability variables specifically:
- Capability kind.
- Rights.
- Linearity class.
- LAM tag layout (the bits encoding the runtime tags).

---

## 10. Code actions

LSP code actions provided:
- "Drop this affine binding" (inserts explicit `drop binding`).
- "Add to effect signature" (extends the enclosing function's effect row).
- "Wrap in unsafe block" (with a stub for effects/capabilities/justification fields).
- "Apply opt-pass" (inserts `#[peephole]` or similar annotation).
- "Convert to Unicode glyph" / "Convert to ASCII fallback" (per file).
- "Extract to function" (extract the selected expression).
- "Rename symbol" (rename across files).

---

## 11. Workspace

A PaideiaOS workspace is rooted at a directory containing `paideia-os.toml` (or a directory containing `Cargo.toml` if it's the assembler repo itself, given the Rust-based phase-1 implementation).

The LSP server reads the workspace manifest to discover:
- Source roots.
- Build configuration.
- Module organization.
- Toolchain version pinning.

---

## 12. Open issues

| ID | Issue |
|---|---|
| ED-O1 | Tree-sitter grammar maintenance — when the parser EBNF evolves, the grammar must update; testing infrastructure needed. |
| ED-O2 | Editor-specific snippets (boilerplate for module declarations, etc.) — phase 2+. |
| ED-O3 | Inlay hints (LSP 3.17 feature) — should display inferred types inline. Phase 2+. |
| ED-O4 | The IDE-side rendering of Unicode operator glyphs — fonts must support them. Recommend a project font. |
| ED-O5 | Performance of incremental elaboration — measure on real workloads. |
| ED-O6 | The relationship between the assembler repo and the editor extensions — version pinning when the assembler protocol evolves. |
| ED-O7 | A standalone REPL editor experience — out of scope for phase 1; possibly worth designing. |

---

*End of document.*
