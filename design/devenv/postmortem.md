# PaideiaOS — Dev Env: CI Postmortem Substrate

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Canonical record/replay substrate for failure investigation. Addresses dev-env J2.

---

## 0. Decision

**QEMU `-icount rr` is canonical** for kernel-level postmortems. **Mozilla `rr`** is available for userspace and host-side tools.

---

## 1. QEMU `-icount rr`

When a CI integration/system test fails:
1. The QEMU run was already capturing `replay.bin` via `-icount rr=record`.
2. The replay.bin is uploaded as a CI artifact.
3. Developer downloads, runs `qemu-system-x86_64 -icount rr=replay -rrfile replay.bin`, attaches GDB, debugs.

## 2. Mozilla `rr`

For OCaml-side fuzzers, host-side tool failures:
- Capture via `rr record <tool>`.
- Replay via `rr replay`.

## 3. Bundle contents

CI failure artifact bundle:
- QEMU `replay.bin` (if QEMU run).
- Serial console log.
- GDB stub session log (if any).
- Kernel log ring snapshot.
- Test verdict.
- Profile name and parameters.

## 4. Open issues

| ID | Issue |
|---|---|
| PM-O1 | Cross-mode: when test alternates between QEMU and host. |

---

*End of document.*
