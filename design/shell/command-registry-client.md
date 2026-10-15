# PaideiaOS — Shell: Command Registry Client (R222.M5)

**Status:** Draft v0.1 — landed Wave 122
**Date:** 2026-10-15
**Scope:** Per-session command-registry client for the semantic shell.
Resolves `<name> <args>...` into a `(cs_body_ref, functor_ref)` tuple
at every REPL dispatch, honouring the system / user-shadow override
rule from `design/terminal/command-registry.md` (CRG-D1..D4).

**Upstream:** paideia-os#2486 (R222 cmd-functor umbrella),
paideia-os#2662 (R222.M5 CmdRegistry).
**Module:** `tools/user/libpdx-pds-parser/src/cmd_registry.pdx` module
`CmdRegistry`.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| CMD-D1 | Closed-addressing hash table with linear probe, 128 slots × 48-byte stride | Trivial O(1) lookup for small command counts; predictable address arithmetic; no indirection or allocation |
| CMD-D2 | FNV-1a 64 of the command name as probe key | Byte-for-byte identical to R222.M2 `_cmd_sig_fnv1a64` + R222.M3 `_fi_fnv1a64`; `name_hash` is numerically comparable across the three parser-family modules |
| CMD-D3 | Scope byte on each entry (0=system, 1=user); user-shadow override at lookup | Matches CRG-D4 (per-user commands shadow system commands); the write-once-at-session-start discipline keeps the override deterministic |
| CMD-D4 | No TOML parse at M5; caller hands a pre-flattened byte buffer of entries | TOML parsing lives in R123.M2 kernel-side `cmd_registry_parser.pdx` (landed); separating the TOML layer from the catalogue layer keeps M5 testable in isolation and preserves the pure-leaf discipline of the parser family |
| CMD-D5 | Write-once; no eviction, no hot reload at M5 | Open question CRG-O1 (hot reload) is deferred to a follow-up; M5 locks the catalogue at session boot and reads only until session end |
| CMD-D6 | 48-byte stride decomposed as `shl idx,5` + `shl idx,4` | Non-power-of-two stride; the two sub-strides are power-of-two so each individual shift stays in the pitfall-safe shape (per `feedback_pdx_encoder_pitfalls`, no 2-op `imul r,imm`) |
| CMD-D7 | `cmdreg_` label prefix (NOT `cr_` which is R224.M4 CapRow) | Grep-confirmed free of linker-visible symbol collisions; disjoint from the parser-family's eighteen prior prefixes |

---

## 1. Pool layout

```
_cmdreg_entries : [u8; 6144]      // 128 slots × 48 bytes, @align(8)
_cmdreg_init_state    : u64       // 0 = not initialised, 1 = initialised
_cmdreg_count_system  : u64       // # system entries registered
_cmdreg_count_user    : u64       // # user entries registered
```

Per-entry layout (48 bytes):

| Offset | Size | Field          | Notes |
|--------|------|----------------|-------|
| 0x00   | 8    | `name_hash`    | FNV-1a 64. 0 marks empty slot. |
| 0x08   | 8    | `cs_body_ref`  | Opaque handle to the CommandSig record (R222.M2). |
| 0x10   | 8    | `functor_ref`  | Opaque handle to the paideia-as functor module (R222.M3). |
| 0x18   | 1    | `scope`        | 0 = `CMDREG_SCOPE_SYSTEM`, 1 = `CMDREG_SCOPE_USER`. |
| 0x19   | 1    | `flags`        | Reserved; 0 at M5. |
| 0x1A   | 1    | `name_len`     | 1..`CMDREG_NAME_MAX` = 16. |
| 0x1B   | 1    | reserved       | 0. |
| 0x1C   | 16   | `name_inline`  | ASCII name bytes, zero-padded. |
| 0x2C   | 4    | reserved       | 0. |

The 48-byte stride is **not** a power of two. The stride multiply uses
`shl idx, 5` (* 32) + `shl idx, 4` (* 16) summed into a scratch register:

```
mov rcx, r14         ; slot_idx
mov r9,  r14
shl rcx, 5           ; slot_idx * 32
shl r9,  4           ; slot_idx * 16
add rcx, r9          ; slot_idx * 48
lea r11, [rip + _cmdreg_entries]
add rcx, r11         ; rcx = entry_addr
```

Both individual shifts stay in the pitfall-safe shape; no 2-op `imul r, imm`
appears anywhere in the module.

Hash-to-slot mapping: `slot = hash mod 128`. Because 128 = 2^7, the
mod is implemented via a shift-pair (`shl r, 57; shr r, 57`) that
isolates the low 7 bits. This avoids `and r, imm64` (per the
pitfall list). Precedent: `row_types.pdx` uses `shl r, 40; shr r, 40`
for the parallel case of low-24-bit idx masking.

---

## 2. Public API

```
_cmdreg_init() -> ()
_cmdreg_register(scope, name, name_len, cs_body_ref, functor_ref) -> errno
_cmdreg_lookup(name, name_len, out_entry_ptr) -> errno
_cmdreg_dump(out, out_cap) -> (bytes_written << 32) | status
_cmdreg_fnv1a64(ptr, len) -> hash              // module-private leaf
```

### 2.1 `_cmdreg_init`

Idempotent lazy boot hook. Zero-fills `_cmdreg_entries` (6144 B via a
u64-stepping loop, 768 iterations), resets both scope cursors, sets
`_cmdreg_init_state := 1`. A second call after the first is a one-branch
no-op (`cmp rax, 0; jne cmdreg_ini_done`).

Every public API that reads the table calls `_cmdreg_init` at its first
instruction after the SysV prologue. This replicates the Wave 120 /
Wave 121 lazy-init pattern across EffectRow + CapRow.

### 2.2 `_cmdreg_register`

```
rdi = scope           // u8 widened to u64; must be 0 or 1
rsi = name            // ptr to ASCII bytes
rdx = name_len        // 1..16
rcx = cs_body_ref     // opaque u64
r8  = functor_ref     // opaque u64
rax = CMDREG_OK | CMDREG_ERR_*
```

Validates `scope <= 1` (BAD_SCOPE) and `1 <= name_len <= 16` (BAD_NAME).
Calls `_cmdreg_init` + `_cmdreg_fnv1a64(name, name_len)` → `name_hash`.
Computes `slot = name_hash mod 128` via shift-pair. Linear-probes
forward (mod 128) up to 128 attempts; on the first empty slot, writes
the 48-byte entry and bumps the per-scope cursor. On a full pass without
finding an empty slot, returns `CMDREG_ERR_TABLE_FULL`.

**Register-liveness.** 5 callee-save pushes
(`rbx=name, r12=name_len, r13=cs_body_ref, r14=functor_ref, r15=scope_byte`)
+ `sub rsp, 32` (4 scratch slots: `name_hash`, `slot_idx`, `probe_count`,
pad) → entry `rsp % 16 == 8`, +40 pushes = `% 16 == 0`, +32 scratch =
`% 16 == 0` steady at every nested CALL to `_cmdreg_init` and
`_cmdreg_fnv1a64`.

### 2.3 `_cmdreg_lookup`

```
rdi = name            // ptr to ASCII bytes
rsi = name_len        // 1..16
rdx = out_entry_ptr   // ptr to u64; receives entry base addr on OK, 0 on error
rax = CMDREG_OK | CMDREG_ERR_*
```

Validates `1 <= name_len <= 16` (BAD_NAME). Calls `_cmdreg_init` +
`_cmdreg_fnv1a64` → `target_hash`. Computes `slot = target_hash mod 128`.
Probes forward up to 128 attempts; stops at the first empty slot. During
the walk the function keeps a `best_entry_ptr` accumulator in `r14`
(initially 0). The best-match rule:

1. If any entry on the probe chain has `name_hash == target_hash` AND
   `scope == CMDREG_SCOPE_USER`, that entry wins immediately — the loop
   short-circuits.
2. Else, if any entry has `name_hash == target_hash` AND
   `scope == CMDREG_SCOPE_SYSTEM`, remember it in `best_entry_ptr`
   (only if not already remembered — the first system hit wins among
   system-scope collisions).
3. On loop exit, if `best_entry_ptr != 0`, write it to `*out_entry_ptr`
   and return `CMDREG_OK`; else write 0 and return `CMDREG_ERR_NOT_FOUND`.

**Register-liveness.** 6 callee-save pushes
(`rbx=name, rbp, r12=name_len, r13=out_entry_ptr, r14=best_entry_ptr, r15=target_hash`)
+ `sub rsp, 24` (2 scratch slots: `slot_idx`, `probe_count` + 8 B pad)
→ entry `rsp % 16 == 8`, +48 pushes = `% 16 == 8`, +24 scratch =
`% 16 == 0` steady at every nested CALL.

### 2.4 `_cmdreg_dump`

```
rdi = out             // ptr to caller buffer; filled on OK
rsi = out_cap         // byte capacity of the caller buffer
rax = (bytes_written << 32) | status
```

Calls `_cmdreg_init`. Walks slots 0..127, copying each occupied entry's
48 bytes into the caller buffer in slot order via 6 x u64 moves. Returns
`CMDREG_ERR_OUT_TOO_SMALL` the first time a copy would overflow `out_cap`;
otherwise packs `(n_written << 32) | CMDREG_OK`.

The dump is the enumeration surface R222.M8 (`describe <cmd>` builtin)
will format over. At M5 it is already callable by test fixtures and the
future admin shim.

**Register-liveness.** 4 callee-save pushes
(`rbx=out, r12=out_cap, r13=n_written, r14=slot_idx`) + `sub rsp, 8` pad
= 40 B frame; entry `rsp % 16 == 8`, +32 pushes = `% 16 == 8`, +8 pad =
`% 16 == 0` at the single nested CALL to `_cmdreg_init`.

### 2.5 `_cmdreg_fnv1a64`

Pure-leaf FNV-1a 64 over caller bytes. Byte-for-byte mirror of
`_cmd_sig_fnv1a64` (R222.M2) and `_fi_fnv1a64` (R222.M3): same offset
basis 0xCBF29CE484222325 and prime 0x100000001B3, same loop body. Three
copies in the parser family live in disjoint linker-visible symbol
namespaces so each sub-module can be linked standalone; the three hash
functions are numerically identical on the shared ASCII input, so
downstream consumers that compare `name_hash` values across the three
families are guaranteed numerical equality.

The multiplication uses the one-op `mul rcx` form (encoding `48 F7 E1`),
distinct from the pitfall-listed 2-op `imul r, imm` shape.

---

## 3. Status band 0x4500..0x45FF

| Code | Name | Meaning |
|------|------|---------|
| 0      | `CMDREG_OK`                 | Operation succeeded. |
| 0x4501 | `CMDREG_ERR_NOT_FOUND`      | `_cmdreg_lookup` found no entry with matching `name_hash`. |
| 0x4502 | `CMDREG_ERR_BAD_SCOPE`      | `_cmdreg_register` with scope not in {0, 1}. |
| 0x4503 | `CMDREG_ERR_BAD_NAME`       | `name_len == 0` or `name_len > CMDREG_NAME_MAX (= 16)`. |
| 0x4504 | `CMDREG_ERR_TABLE_FULL`     | `_cmdreg_register` with all 128 slots occupied. |
| 0x4505 | `CMDREG_ERR_OUT_TOO_SMALL`  | `_cmdreg_dump` out_cap < `n_occupied * 48`. |

Slots `0x4506..0x45FF` reserved for R222.M6 (commands.toml bind errors),
R222.M7 (fuzz corpus deviations), R222.M8 (`describe <cmd>` render
errors), M4+ hot-reload failures.

The 0x4400..0x44FF band is reserved for the parallel R221.M5 arm of
Wave 122; the two Wave 122 arms sit on adjacent kilo-step boundaries
disjoint from every prior landed band.

---

## 4. Encoder-pitfall discipline

Per `feedback_pdx_encoder_pitfalls`, the module avoids every known
paideia-as encoder trap:

- No `test rN, rN` — every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64` — hash-slot mod uses `shl r, 57; shr r, 57`;
  name-length checks use imm8 variants only.
- No 2-op `imul r, imm` — 48-byte stride decomposes as
  `shl idx, 5 + shl idx, 4`; the FNV multiply is one-op `mul rcx`.
- No multiline `pub let = "..."` — single-line justifications
  (precedent: command_sig.pdx, cap_row.pdx).
- Module basename `CmdRegistry` matches `cmd_registry.pdx`.
- `cmdreg_` label prefix (NOT `cr_` which is TAKEN by R224.M4 CapRow).
- All `cmp reg, imm` immediates fit in imm32 with bit 31 clear.
- Byte loads via `xor rN, rN; mov_b rN, [base + idx]`.
- Byte stores via `mov_b [dst + disp], reg` or
  `mov r11, base; add r11, idx; mov_b [r11], src`.
- Cross-module `.bss` reads/writes via `lea r11, [rip + sym]; mov [r11], rax`.

---

## 5. Register-liveness discipline

`r11` is clobbered by every nested CALL. The three nested-CALL sites in
this module (`_cmdreg_register`, `_cmdreg_lookup`, `_cmdreg_dump`) all
stash their arguments in callee-save `r12..r15` (or on the stack scratch)
before any nested CALL. `_cmdreg_init` and `_cmdreg_fnv1a64` are pure
leaves with no nested CALL; they do not need stashing.

The lazy-init discipline (every reader calls `_cmdreg_init` at entry)
costs one branch on the hot path (the sentinel short-circuit).

---

## 6. Acceptance (per issue brief)

### 6.1 Seed fixture

```
_cmdreg_init();
_cmdreg_register(SYSTEM, "find",    4, cs_find,    fn_find);
_cmdreg_register(SYSTEM, "curl",    4, cs_curl,    fn_curl);
_cmdreg_register(SYSTEM, "ls",      2, cs_ls,      fn_ls);
_cmdreg_register(SYSTEM, "cat",     3, cs_cat,     fn_cat);
_cmdreg_register(SYSTEM, "grep",    4, cs_grep,    fn_grep);
```

Followed by five `_cmdreg_lookup` calls, each of which must return
`CMDREG_OK` and write the matching `entry_addr` to the out pointer.

**Timing target.** Each lookup is bounded by:
- 1 x `_cmdreg_init` idempotent short-circuit (3 instructions).
- 1 x `_cmdreg_fnv1a64` over ≤16 bytes (16 iterations × ~5 ops per
  iteration = ~80 ops).
- 1 x `shl + shr` for the mod.
- ≤128 probe iterations, but typically 1 (no collision expected on
  a 5-entry table with a well-distributed hash).

On the 400 MHz class QEMU target with a cycle budget of ~2.5 ns/cycle,
≤200 instructions × 1 cycle (optimistic uop) = ≤500 ns. Well under
the 50 µs target. The real QEMU timing (with mispredicts and memory
latency) is expected to land at <5 µs for this fixture.

### 6.2 User-shadow test

```
_cmdreg_init();
_cmdreg_register(SYSTEM, "find", 4, cs_system_find, fn_system_find);
_cmdreg_register(USER,   "find", 4, cs_user_find,   fn_user_find);

// Lookup must return the user entry.
_cmdreg_lookup("find", 4, &out_entry);
// *out_entry is at an address X such that *(u64 *)(X + 24) == 1 (USER)
// and *(u64 *)(X + 16) == fn_user_find.
```

The probe chain for `find` holds TWO entries (system in slot `S`, user
in slot `S+1` — or vice versa depending on probe order). The lookup
walks the chain and short-circuits on the user match.

---

## 7. Interactions

- **R222.M2 (CommandSig).** The `cs_body_ref` payload at offset 8 of
  each entry points at a CommandSig record (R222.M2 output), whose
  128-byte header carries the command's name, caps, version, and
  stability. The REPL dispatch at R222.M6+ dereferences `cs_body_ref`
  to inspect caps and stability.
- **R222.M3 (FunctorInstance).** The `functor_ref` payload at offset
  16 is the paideia-as module ref the shell `exec`s. R222.M3's
  `_fi_instantiate` wire-format matches what the dispatcher consumes.
- **R222.M4 (ArgFlagSpec).** The ArgSpec + FlagSpec records a
  functor needs for `_afs_check_invocation` are reachable through
  `cs_body_ref` + a per-command spec quartet pointer (consolidated
  at R222.M6 commands.toml bind).
- **R123.M2 (kernel-side cmd_registry_parser).** TOML parse of
  `/system/shell/commands.toml` + `/users/<u>/shell/commands.toml`
  lives there (landed). At session boot the shell's start-up path
  calls through to that layer, obtains a pre-flattened byte buffer
  of entries, then iterates `_cmdreg_register` for each entry on
  this M5 side. R222.M6 wires the two layers together.

---

## 8. Open issues

| ID | Issue |
|----|-------|
| CMD-O1 | Hot reload (`CRG-O1` upstream) — a running shell session reloads only at next session boot. Deferred to a dedicated milestone. |
| CMD-O2 | Table full behaviour. M5 returns `CMDREG_ERR_TABLE_FULL` without eviction; the 128-slot cap is 2x the expected system-command count. A later M bumps `CMDREG_SLOTS` to 256 or 512 after corpus profiling. |
| CMD-O3 | `name_hash` collision across distinct names. The FNV-1a 64 collision rate on a 128-entry table is below 2^-50; a defensive future landing may add a secondary name-byte compare at lookup time. |
| CMD-O4 | Scope byte expansion. M5 reserves one byte; a later milestone wants per-tenant or per-container scopes and may bump to a u32 encoding. |

---

## 9. Forward path

- **R222.M6** — commands.toml bind layer; chains R123.M2 kernel-side
  TOML parse into `_cmdreg_register`. Introduces the default-literal
  grammar for `ArgSpec` / `FlagSpec` and the per-command quartet
  pointer that reconciles the four signature records with this
  catalogue.
- **R222.M7** — fuzz corpus. 20-test seed covering: (a) empty table
  lookup, (b) full table (128 entries) lookup, (c) hash collision via
  birthday-paradox stress, (d) user-shadow override, (e) BAD_SCOPE /
  BAD_NAME / TABLE_FULL / OUT_TOO_SMALL error paths, (f) dump round-
  trip under capacity, (g) dump at exact capacity.
- **R222.M8** — `describe <cmd>` builtin. Formats `_cmdreg_dump`
  output as a queryable table over the typed-pipe surface.
- **R123.M3** — in-process invoke. Dereferences `functor_ref` via the
  KIND_CMD_MODULE row pool.
- **R127** — tab completion. Walks `_cmdreg_dump` output for prefix
  matching.

---

*End of document.*
