# PaideiaOS — Filesystem: Compression Algorithm Catalog

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Compression algorithms supported per-file. Addresses FS-O7.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| CMP-D1 | Zstd is the default | FS-Q8 binding |
| CMP-D2 | LZ4 supported for very-fast paths | Speed |
| CMP-D3 | XZ (LZMA2) supported for archives | Best ratio |
| CMP-D4 | No proprietary algorithms | Audit-friendly |
| CMP-D5 | Per-file selection via `compression_cap` attribute | Per-file optimization |

---

## 1. Algorithms

| Algorithm | Speed | Ratio | Use case |
|---|---|---|---|
| Zstd (level 3) | Fast | Good | General default |
| Zstd (level 19) | Slow | Best | Archives, cold storage |
| LZ4 | Very fast | Modest | Hot data; low-latency requirement |
| XZ (LZMA2) | Slow | Excellent | Backup, cold archive |
| None | n/a | n/a | Already-compressed, encrypted, random data |

---

## 2. Per-file selection

A file's descriptor records `compression: Option<Algorithm>`. When set, every write compresses; every read decompresses.

The default is `None`; opt-in via the supervisor's policy or per-file annotation.

---

## 3. Schema-driven hints

The schema registry (per FS doc §7.4) may include compression hints:
- Schema `LogEntry` → recommend Zstd-3 (logs compress well).
- Schema `ImagePixels` → recommend None (images already compressed).
- Schema `Database` → recommend LZ4 (fast read access).

The compression-cap attribute respects schema hints but can override.

---

## 4. Open issues

| ID | Issue |
|---|---|
| CMP-O1 | Zstd dictionary support — pre-trained dictionaries can improve ratio for small files. |
| CMP-O2 | Streaming compression for large files. |

---

*End of document.*
