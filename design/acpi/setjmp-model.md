# PaideiaOS — ACPI: setjmp / longjmp Linear-Capability Model

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Linear-capability model for ACPICA's limited setjmp/longjmp use. Addresses AC-O2.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| SJ-D1 | Jump-buffers are linear capabilities | Substructural discipline |
| SJ-D2 | longjmp consumes the buffer | Single-use |
| SJ-D3 | Double-longjmp detected and panics | Safety |
| SJ-D4 | setjmp creates a buffer; longjmp invokes it | Standard |

---

## 1. Type signature

```paideia-as
fn paideia_setjmp() -> JumpBufCap !{setjmp}
fn paideia_longjmp(buf : JumpBufCap ↓, value : i32) -> !  // diverges
```

`JumpBufCap` is linear; `longjmp` consumes it.

---

## 2. ACPICA shim

ACPICA's C code calls `setjmp(buf)` and `longjmp(buf, val)`. The shim wraps:

```paideia-as
extern fn setjmp(buf : *mut JumpBuffer) -> i32 = {
  let cap = paideia_setjmp()
  store buf, cap         // store the cap into ACPICA's buffer
  return 0
}

extern fn longjmp(buf : *mut JumpBuffer, val : i32) -> ! = {
  let cap = load buf      // load the cap from ACPICA's buffer
  paideia_longjmp(cap, val)
}
```

---

## 3. Double-longjmp detection

If ACPICA calls longjmp twice on the same buffer, the second call sees a consumed cap. The shim detects (the load returns nothing valid) and panics.

---

## 4. Open issues

| ID | Issue |
|---|---|
| SJ-O1 | Interaction with the C-runtime exception model. |

---

*End of document.*
