# PaideiaOS — Terminal: Kitty Graphics Protocol Dialect

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Specific Kitty graphics protocol extensions used by PaideiaOS. Addresses SH-O3.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| KGP-D1 | Use Kitty graphics protocol baseline (raster images) | Standard |
| KGP-D2 | Use placement-based positioning | Better than cursor-based |
| KGP-D3 | Support: PNG, JPEG, raw RGBA | Common formats |
| KGP-D4 | Animation frames supported | Multi-frame |
| KGP-D5 | Detect via XTGETTCAP query | Standard |

---

## 1. Protocol features used

- Image transmission via base64-encoded data in escape sequences.
- Placement command for positioning.
- ID-based addressing for later updates.
- Animation frames.

---

## 2. Fallback

When terminal doesn't support Kitty graphics:
- Plain text representation.
- ANSI-256 box-drawing if possible.

---

## 3. Performance

Large images may be slow to transmit; the shell can offer to write to a file and open externally instead.

---

## 4. Open issues

| ID | Issue |
|---|---|
| KGP-O1 | Sixel as alternative for terminals without Kitty support. |

---

*End of document.*
