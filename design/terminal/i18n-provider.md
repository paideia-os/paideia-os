# PaideiaOS — Terminal: Locale and i18n Provider

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Locale data shipped with PaideiaOS and downloadable extensions. Addresses SH-O11.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| I18N-D1 | Default locale: `und` (no language-specific tailoring) | Compatibility |
| I18N-D2 | CLDR-based locale data shipped for: en-US, en-GB, es, pt-BR, fr, de, ja, zh-CN, zh-TW, ko, ru, ar | Major languages |
| I18N-D3 | Additional locales downloadable from upstream CLDR | Extensibility |
| I18N-D4 | UCA collation table per locale | Standard |

---

## 1. Default shipped locales

Roughly the top-10 in the language-by-population list, with additional based on project demographics:
- en-US, en-GB (English)
- es (Spanish — global)
- pt-BR (Portuguese — Brazilian)
- fr (French)
- de (German)
- ja (Japanese)
- zh-CN, zh-TW (Chinese)
- ko (Korean)
- ru (Russian)
- ar (Arabic — bidi)

---

## 2. Locale storage

Per-locale data in `/system/locale/<id>/`:
- `cldr.json` — CLDR data subset.
- `collation.dat` — UCA collation table.
- `keymap.toml` — keyboard layout (if applicable).

---

## 3. User-set locale

```toml
[user.locale]
language = "es"
region = "MX"
```

Affects date/time formatting, number formatting, currency display, command-help translations (when installed).

---

## 4. Open issues

| ID | Issue |
|---|---|
| I18N-O1 | Translation workflow for command help. |
| I18N-O2 | Right-to-left layouts in the renderer. |

---

*End of document.*
