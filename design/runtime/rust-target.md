# PaideiaOS — Runtime: Rust Target Registration

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Rust target spec for compiling Rust code to PaideiaOS-native. Addresses JAIL-O2.

---

## 0. Target name

`x86_64-unknown-paideia-native`

---

## 1. Target specification

```json
{
  "arch": "x86_64",
  "data-layout": "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128",
  "llvm-target": "x86_64-unknown-paideia-elf",
  "target-pointer-width": "64",
  "target-c-int-width": "32",
  "target-endian": "little",
  "os": "paideia",
  "vendor": "paideia-os",
  "env": "native",
  "panic-strategy": "abort",
  "executables": true,
  "features": "+sse,+sse2",
  "linker": "paideia-link",
  "linker-flavor": "paideia",
  "no-default-libraries": true,
  "calling-conventions": "paideia-native"
}
```

---

## 2. Standard library

Rust std must be ported. For phase 2: `no_std` only; phase 3+: alloc + std stubs over PaideiaOS APIs.

---

## 3. Use case

The primary use case is the wasmtime port (per `wasm-vm-jail.md` §10.3). The Rust target lets wasmtime build to PaideiaOS PAX directly.

---

## 4. Open issues

| ID | Issue |
|---|---|
| RT-O1 | Std port — extensive work; phase 3+. |
| RT-O2 | Cargo integration with Nix. |

---

*End of document.*
