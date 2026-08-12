# PaideiaOS — InitCap sidecar format (R20b.M4-001)

**Status:** Design v0.1
**Date:** 2026-08-11
**Round:** R20b.M4 (loader capability-seed hook)
**Issue:** #1561 (this document accompanies the format + validator).
**Parent:** `design/ipc/userspace-server-substrate.md` §6.
**Follow-up:** #1562 R20b.M4-002 (loader wire-in + `loader_seed_caps`).

---

## 0. Purpose

Every userspace image that expects seeded caps declares an `_init_caps` array
in its `.rodata` (or, more precisely, an `.init_caps` section). At image load
time, `loader_seed_caps` (M4-002) walks the array and mints each entry into
the task's cap_table. This document fixes the **record format**, the
**image-side placement rule**, and the **validator contract** the loader will
call before minting.

M4-001 delivers the format + validator only. Live minting is M4-002.

---

## 1. Record layout — 16 bytes each

```
InitCap (16 bytes, natural 8-byte alignment)
  +0    u16 slot            (target slot in the task's cap_table; 0..255)
  +2    u16 kind            (KIND_* value — matches src/kernel/core/cap/kind.pdx)
  +4    u32 rights          (RIGHTS_* mask — matches src/kernel/core/cap/rights.pdx)
  +8    u64 target_ptr      (kind-specific; e.g. for KIND_IPC_ENDPOINT: endpoint tail per kind_endpoint.pdx)
```

The 16-byte record is intentionally sized to a power of two so a
count × 16 stride computation is a single left-shift. All fields are
little-endian.

## 2. Image-side declaration convention

The userspace image publishes two symbols, both in `.rodata`:

```
_init_caps_count : u16                        ; count of entries (0..N)
_init_caps       : InitCap[_init_caps_count]  ; the array itself
```

Example in `.pdx` source (userspace):

```
module MyServer = structure {

  // Two init-caps: slot 0 = endpoint (read+invoke), slot 1 = dmesg (read).
  pub let _init_caps_count : u16 = 2

  pub let _init_caps : [u64; 4] = [
    // Entry 0: slot=0, kind=KIND_IPC_ENDPOINT(5), rights=R_IPC_READ|R_IPC_INVOKE(0x09), tail=(id=1,dir=RECV)
    0x0000_0009_0005_0000,   // rights<<32 | kind<<16 | slot
    0x0000_0000_0001_0001,   // target_ptr: endpoint_id=1 (bits 0..15), dir=RECV(1) (bits 16..17)

    // Entry 1: slot=1, kind=KIND_DMESG(0x16), rights=RIGHT_READ(0x01), target_ptr=0
    0x0000_0001_0016_0001,
    0x0000_0000_0000_0000
  ]
}
```

Byte-pack rationale: paideia-as does not yet expose struct-typed `.rodata`
initialisers; a `[u64; 2*N]` with hand-packed words is the phase-1 form.
When paideia-as grows struct-in-rodata support the packing helper moves
into a source-level `InitCap` type and the array becomes idiomatic.

**Placement**: both symbols live in the image's default `.rodata`
section. The loader's phase-1 walk uses the two symbol names directly
(via elf_lite's symbol-table walk, added in M4-002). A future
`.init_caps` section is reserved as an optimisation but not required at
phase 1.

## 3. Sidecar phase-1 wire layout (validator input)

For the M4-001 validator + its boot witness the sidecar is treated as a
single contiguous blob (this is also the shape M4-002 will hand to the
validator once it has resolved both symbols and colocated them in a
kernel-side scratch buffer, avoiding two separate ELF walks per record):

```
sidecar (16 + N*16 bytes)
  +0    u16 count             (== _init_caps_count)
  +2    u8[14] reserved       (padding; MUST be zero at phase-1)
  +16   InitCap[count]        (the array, 16 bytes per entry)
```

The 14-byte pad after `count` aligns the first entry to a 16-byte
boundary. This matches what a hand-authored `[u64; 2 + 2*N]` looks like
in `.rodata` when N > 0.

## 4. Validator contract

```
init_caps_validate(image_base: u64, image_len: u64) -> u64
```

- **RDI (input)**  `image_base` — sidecar blob start (VA).
- **RSI (input)**  `image_len`  — sidecar blob length in bytes.
- **RAX (output)** `INIT_CAPS_OK` (0) on success, or a distinct error code:

| Code | Constant | Cause |
|------|----------|-------|
| `0xFFFFFFFF` | `INIT_CAPS_BAD_COUNT` | `image_len < 16` **or** `16 + count*16 > image_len` (array won't fit). |
| `0xFFFFFFFE` | `INIT_CAPS_BAD_SLOT`  | Any entry's `slot >= 256` (out of cap_table range). |
| `0xFFFFFFFD` | `INIT_CAPS_BAD_KIND`  | Any entry's `kind` is not in the closed base enum {0..15} nor a registered derived kind (`0x15` KIND_DRIVER, `0x16` KIND_DMESG). |

The validator does **not** validate `rights` (rights masks are
kind-specific; delegate to the mint gate that fires per-kind in M4-002)
nor `target_ptr` (kind-specific interpretation).

Failure is **fail-fast**: on the first bad entry the validator returns
its error code without inspecting later entries. M4-002 aborts the
entire image load on any validator failure, so a partial-seed race
cannot leave a task with mixed valid/invalid caps.

## 5. Loader-side walk contract (M4-002 preview)

`loader_seed_caps(task_ptr, image_base, image_len)`:

1. Locate `_init_caps_count` + `_init_caps` in the image's symbol table
   (existing `elf_lite_load` symbol-table walk grows a second pass).
2. Colocate the two into a kernel-side sidecar scratch buffer of the
   shape §3 documents. (This lets the validator work on one contiguous
   blob, matching what M4-001's boot witness synthesizes.)
3. Call `init_caps_validate(scratch_base, 16 + count*16)`. Abort load on
   any non-zero rc (`ELF_CAP_SEED_FAILED = 0xFFFFFFF9`).
4. Iterate 0..count: `cap_mint_write(task.cap_table + slot*24, kind, rights, target_ptr)`.

## 6. What this milestone does NOT do

- No live minting (M4-002).
- No symbol-table walk (M4-002 adds a second `elf_lite_load` pass).
- No rights validation (kind-specific; deferred to per-kind mint gates).
- No `target_ptr` validation (kind-specific).
- No echo-server binary (M5-001).

*End of document.*
