# PaideiaOS — Terminal: Multi-Session Interaction

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Multi-session conflict semantics — when two sessions modify the same FS file. Addresses SH-O9.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| MS-D1 | FS-level concurrency: per-FS doc, snapshot isolation | Per FS doc §11 |
| MS-D2 | Multiple shell sessions for same user are independent processes | Pillar 3 |
| MS-D3 | Last-writer-wins for concurrent modifications | FS doc default |
| MS-D4 | Sessions don't share state beyond user's capability env | Privacy / isolation |

---

## 1. Concurrent file modification

Session A and Session B both edit the same file:
- A starts a transaction at time T1.
- B starts a transaction at time T2.
- A commits at T3.
- B commits at T4 (T4 > T3).
- B's commit supersedes A's per FS doc's last-writer-wins.

Sessions can detect this via the FS's snapshot-isolation read-version.

---

## 2. Shared environment

Sessions share:
- The user's capability environment.
- The shell-script library imports.

Sessions don't share:
- Local environment variables.
- Current working directory.
- History (each session writes to its own history segment).

---

## 3. Open issues

| ID | Issue |
|---|---|
| MS-O1 | "Open file in another session" warning — UX guidance. |
| MS-O2 | Session-to-session messaging — out of scope. |

---

*End of document.*
