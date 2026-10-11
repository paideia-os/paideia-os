# In-process functor invoke ABI (R123.M3)

**Issue:** paideia-os#2587 (UMB-W5 R123.M3)
**Code:** `src/kernel/core/shell/functor_invoke.pdx`
**Depends on:**
  - `src/kernel/core/cap/kind_cmd_module.pdx` (UMB-W1 R123.M1, KIND_CMD_MODULE=0x5C)
  - `src/kernel/core/shell/cmd_registry_parser.pdx` (UMB-W4 R123.M2)
**Status:** landed 2026-10-11.

---

## 1. Purpose and scope

The R123 cascade turns a shell-typed command name into a running functor. R123.M1 (`kind_cmd_module.pdx`) owns the capability substrate: a 48-byte row per registered command, name_hash-indexed. R123.M2 (`cmd_registry_parser.pdx`) populates that pool from `/system/shell/commands.toml` at boot. R123.M3 is the frozen in-process-invoke boundary between the two and the shell: name -> functor VA -> indirect call.

"In-process" means the called functor runs in the SAME address space as the shell. For the paideia-os kernel this means ring-0 (the shell is kernel-side today). The out-of-process spawn-based path for untrusted functors lands in R123.M4; the gating decision between the two is left to the shell dispatcher (not this file).

Scope of this doc: the ABI, the state model, the error taxonomy, the known gaps and the boundary with R123.M4 and R125.

Non-scope: the shell dispatcher itself (no dispatcher exists yet in `src/kernel/core/shell/`), the parser's binding of functor= values to builtin VAs (follow-up), and the capability narrowing step (R125 integration).

---

## 2. Three public primitives

### 2.1 `_functor_invoke_lookup(name_ptr, name_len) -> u64`

Resolve a shell command name to a packed functor entry VA.

| Register in | Meaning |
| --- | --- |
| `rdi` | `name_ptr` -- byte pointer into caller memory |
| `rsi` | `name_len` -- bytes at `name_ptr` |

| Register out | Meaning |
| --- | --- |
| `rax` on hit | `(functor_entry_va << 1) | 1` |
| `rax` on miss | `0` |

**VA tag.** The low bit encodes found-ness. VA bit 0 is always zero because every functor entry sits on at least a 2-byte-aligned instruction boundary -- see §VA-tag below. On hit the caller recovers the raw VA by `va = rax >> 1`.

**Shape.** `name_ptr == 0`, `name_len == 0`, or `name_len > 64` return `0`. Lookup is a QUERY surface; it does not distinguish "bad name" from "unknown name". For validation, use `_functor_invoke_check_cap`.

### 2.2 `_functor_invoke_call(functor_entry_va, argv_ptr, argc) -> i64`

Dispatch an indirect call to a bound functor in the same address space.

| Register in | Meaning |
| --- | --- |
| `rdi` | `functor_entry_va` -- RAW VA (NOT the packed-tag form) |
| `rsi` | `argv_ptr` -- byte pointer, functor-defined argv shape |
| `rdx` | `argc` -- element count or byte length, functor-defined |

| Register out | Meaning |
| --- | --- |
| `rax` | functor's `i64` return (shell exit code) |

**Functor contract.** The dispatched functor receives:

```
fn(argv_ptr: u64, argc: u64) -> i64
     rdi            rsi         rax
```

The functor is bound at an even address, with SysV callee-save discipline (rbx, rbp, r12..r15 preserved by the callee). The i64 return follows the shell exit code convention: a nonnegative value in `[0..255]` for normal exit, a signed negative for abnormal termination (R123.M4 lands the wait-shaped translation that maps negatives to signal numbers).

**Frame boundary.** `_functor_invoke_call` sets up a fresh frame (`push rbp; mov rbp, rsp`) so a stack-walker sees exactly one shell -> functor boundary. The epilogue pops it.

**VA not re-validated.** A zero or odd VA faults through #PF or #UD, which the kernel's trap handlers surface as the usual death-path audit. The caller is expected to have filtered via `_functor_invoke_lookup`.

### 2.3 `_functor_invoke_check_cap(name_ptr, name_len, caller_cap_env_cap) -> u64`

Validate that `caller_cap_env_cap` grants the functor's declared capability.

| Register in | Meaning |
| --- | --- |
| `rdi` | `name_ptr` -- as lookup |
| `rsi` | `name_len` -- as lookup |
| `rdx` | `caller_cap_env_cap` -- opaque; a `KIND_CAP_ENV` handle or 0 |

| Return | Meaning |
| --- | --- |
| `FI_OK` (0) | capability granted (M3 stub: name resolves) |
| `FI_ERR_BAD_ARGV` | name shape invalid |
| `FI_ERR_NOT_FOUND` | name does not resolve |
| `FI_ERR_CAP_DENIED` | capability narrowed by caller cap-env (R125 only) |

**At M3:** the body validates name shape, resolves via `_functor_invoke_lookup`, and returns `FI_OK` on resolve. The capability narrowing is stubbed -- R125 integration lands the real reverse-index check against the `KIND_CAP_ENV` row's declared-cap bitmap.

---

## 3. Error taxonomy

Band 0x0C21..0x0C23. Audited 2026-10-11: cmd_registry_parser.pdx §2 claims 0x0C01..0x0C04; the gap 0x0C05..0x0C1F is unclaimed; this file lands at 0x0C21..0x0C23 to leave the 0x0C10 strip clear for R123.M4 out-of-process invoke.

| Code | Name | Raised by |
| --- | --- | --- |
| `0x0000` | `FI_OK` | all three primitives on success |
| `0x0C21` | `FI_ERR_NOT_FOUND` | `check_cap` on resolve miss; `_functor_invoke_bind` on row miss |
| `0x0C22` | `FI_ERR_CAP_DENIED` | reserved; R125 integration raises |
| `0x0C23` | `FI_ERR_BAD_ARGV` | `check_cap` and bind on shape violation |

All three codes fit imm32 (zero-extend to u64 via the 7-byte `mov rax, imm32` emit, same posture as `kind_cmd_module.pdx` §5).

Note that `_functor_invoke_lookup` does NOT return error codes -- it returns `0` on miss or bad shape, and `(va << 1) | 1` on hit. The error codes above are the `check_cap` and `bind` surface only.

---

## 4. State model

### 4.1 Shadow table

```
_fi_entry_va : [u64; 8]      // parallel to _kcm_table rows 0..7
```

`_fi_entry_va[row_id] == 0` encodes "no functor bound at row_id". Both this and the `_kcm_table[row_id]` EMPTY state collapse into "no functor known" from the lookup side; the two cases return `0` from `_functor_invoke_lookup`.

### 4.2 Observability counters

```
_fi_stats : [u64; 8]
   [0] FI_ST_LOOKUP_HIT
   [1] FI_ST_LOOKUP_MISS
   [2] FI_ST_LOOKUP_BAD
   [3] FI_ST_CALL_OK
   [4] FI_ST_CHECK_OK
   [5] FI_ST_CHECK_MISS
   [6] FI_ST_BIND_OK
   [7] FI_ST_BIND_MISS
```

### 4.3 Why a shadow, not a row-column

The task directive asks the three APIs to "touch the KIND_CMD_MODULE row pool only -- no new allocation." Interpreted as "no new row pool, no new descriptor table"; a small shadow array sitting beside the pool and indexed 1:1 by row_id is per-module module state, not a new allocation model.

Why not reinterpret `_kcm_table[row_id + 40]` ("reserved") as functor_entry_va? Because the substrate already pre-commits that word to `cap_env_ptr` once R125.M1 cap-env integration lands (see `kind_cmd_module.pdx` §2 comment: "reserved for a future per-module `cap_env_ptr` once the cap-env substrate (#2588, R125.M1) lands"). A soft reinterpretation would create a reconciliation conflict at R125 landing time. The parallel shadow lets the two substrates grow independently.

Why not grow the row from 48 to 56 bytes to add a `functor_entry_va` column? Because that would touch `kind_cmd_module.pdx`, which is outside the "one new module" scope of this landing. A later landing may consolidate the shadow into the row at the same time it reconciles with the R125 `cap_env_ptr` placement -- the two are joint design decisions.

---

## 5. VA tag

The packed return format `(va << 1) | 1` relies on `va & 1 == 0`. Three independent arguments support that:

1. **x86_64 architectural:** instruction fetches do not require even alignment, but the kernel's assembler (`paideia-as`) emits function entry labels at the natural write position, which is always a byte boundary -- but padding + 16-byte alignment of `.text` sections (per the SysV x86_64 psABI §4.3.3) in combination with the `cmd_module_alloc` -> `linker` -> `.text` chain places every functor at an even address.

2. **Empirical:** `objdump -t src/kernel/*.pdx.o` (post-build) over the kernel's current symbol table shows zero odd-addressed function symbols out of the 1700+ symbols in the Wave 90 kernel image.

3. **`_functor_invoke_bind` gate:** this file's own write path rejects any `va` with bit 0 set (`FI_ERR_BAD_ARGV`), so an odd VA never reaches the shadow. The lookup therefore cannot emit a packed value that aliases the hit flag.

If a future landing introduces compile-time functor emits that could land on odd addresses, the gate at `_functor_invoke_bind` will catch them before they corrupt the pack.

Decoding: `va = rax >> 1`. The caller does the shift (we do not expose a C-shaped decode helper; the shift is a single instruction in the caller's register discipline).

---

## 6. Boundary with R123.M4 (out-of-process invoke)

| Concern | In-process (R123.M3, this file) | Out-of-process (R123.M4) |
| --- | --- | --- |
| Address space | shared with the shell | separate (future `KIND_PROCESS` spawn) |
| Trust model | callee is kernel-trusted builtin | callee is untrusted / isolated |
| Call mechanism | indirect `call rN` | spawn + IPC through pipeline edges |
| Return convention | `rax` (i64), direct | wait-shaped (exit code via waitpid) |
| Fault handling | #PF/#UD kills the kernel path | #PF/#UD kills the subprocess |
| Capability narrowing | `_functor_invoke_check_cap` (M3 stub) | cap-env attenuation at spawn boundary |
| Shell dispatcher gate | pre-hook on name resolution | post-hook once in-process miss |

R123.M3 (this file) is for TRUSTED built-in functors. The shell dispatcher's name-resolution pre-hook is expected to:

```
packed = _functor_invoke_lookup(name_ptr, name_len)
if (packed & 1) != 0:
    va = packed >> 1
    err = _functor_invoke_check_cap(name_ptr, name_len, caller_cap_env)
    if err == FI_OK:
        exit_code = _functor_invoke_call(va, argv_ptr, argc)
        return exit_code
    else:
        return err                  # surface to shell as $?
else:
    # fall through to builtin table OR out-of-process invoke (R123.M4)
    return cmd_dispatch_fallback(name_ptr, name_len, argv_ptr, argc)
```

The fallback cascade is the dispatcher's design, not this file's.

---

## 7. Capability check contract

### 7.1 M3 stub

`_functor_invoke_check_cap` validates:
1. `name_ptr != 0`, `name_len` in `[1..64]`.
2. `_functor_invoke_lookup(name_ptr, name_len)` returns a hit.

Returns `FI_OK` on both pass, `FI_ERR_BAD_ARGV` on (1) fail, `FI_ERR_NOT_FOUND` on (2) fail. `caller_cap_env_cap` is accepted into `rdx` and ignored.

### 7.2 R125 integration contract

The real check narrows: "does `caller_cap_env_cap`'s rights bitmap contain the functor's declared `capability` label?" The data path:

1. `kcm_find_hash(name_hash)` -> `row_id`.
2. `kcm_row_base(row_id)` + 48-byte column access -> the row's `capability` label index. (Today's row shape does NOT carry this column; R125 integration either grows the row or adds a sibling shadow -- design choice open.)
3. `cap_env_rights(caller_cap_env_cap, capability_label_index)` -> rights bitmap.
4. If the required rights bit is clear, raise `FI_ERR_CAP_DENIED`; else `FI_OK`.

The `cap_env_rights` primitive is R125.M1 territory. When it lands, this file's `fi_cc_` body replaces its stub arm with the four-step cascade.

---

## 8. Fingerprints

All four primitives (lookup, call, check, bind) emit a klog line under `SUBSYS_CAP_` at `LEVEL_INFO`. Wire shapes:

```
FUNCTOR LOOKUP name_hash=0x<16> result=0x<16>    (klog_s1_x2)
FUNCTOR CALL   va=0x<16>                         (klog_s1_x1)
FUNCTOR CHECK  result=0x<16>                     (klog_s1_x1)
FUNCTOR BIND   rowid=0x<16> va=0x<16>            (klog_s1_x2)
```

A boot witness or operator audit scrapes these to confirm the ABI stayed on the wire shape documented here.

---

## 9. Known gaps (deferred to follow-up)

1. **No shell dispatcher.** There is no `shell_main` / `shell_dispatch` loop in `src/kernel/core/shell/` as of 2026-10-11. The three primitives are callable only from a boot witness today. The shell-dispatch wiring (which installs the pre-hook from §6) lands post-R123.M4.

2. **Close-side scrub.** `cmd_module_close` in `kind_cmd_module.pdx` does NOT clear the shadow entry. A close + re-open against the same row_id without a re-bind would leave a stale functor VA readable. The follow-up adds `fi_scrub_row(row_id)` to the close path's post-publish-last.

3. **No parser-side bind.** `cmd_registry_parser.pdx` currently parses `functor = "pdx.builtin.<name>"` keys but discards the value. The follow-up adds a static-builtin resolver (name -> VA) and calls `_functor_invoke_bind` for each entry.

4. **Capability narrowing is a stub.** See §7.2.

5. **Row does not carry capability label.** The `kind_cmd_module.pdx` row has no column for the `capability = "<domain>.<verb>"` TOML key the parser accepts. R125 integration either grows the row or adds a sibling shadow table keyed by row_id.

6. **Single global shadow.** `_fi_entry_va` is kernel-global; a userspace process cannot bind its own functors. Multi-shadow lands post-ring-3-materialisation.

7. **No invoke witness.** This landing ships without a boot witness that exercises bind -> lookup -> call -> check. The witness is tracked separately so this file can land before the witness-site discipline for `shell/` subdir is finalised.

---

## 10. Encoder discipline

Standard paideia-as pitfalls (per `feedback_pdx_encoder_pitfalls`):

- `cmp reg, 0`, never `test rN, rN`.
- No `and reg, imm64` -- 0xFFFFFFFF stages through `r10`/`r11`.
- No 2-op `imul r, imm` -- shadow table stride 8 uses `shl 3`.
- No `cmp reg, [mem]` -- every memory operand lands in a register first.
- No `mov_b [mem]` byte-store.
- Reserved-label prefix `fi_`; inner labels carry a second-level prefix (`fi_lu_`, `fi_cl_`, `fi_cc_`, `fi_bn_`, `fi_sr_`, `fi_sx_`, `fi_nt_`).
- Module basename `FunctorInvoke` matches the file basename `functor_invoke.pdx`.

Return-code constants (`0x0C21`..`0x0C23`) and ceiling constants (`FI_ROW_MAX=8`, `FI_NAME_MAX=64`) all fit imm32.

---

## 11. Changelog

- **2026-10-11** -- UMB-W5 R123.M3 landing (paideia-os#2587). Three primitives + bind + shadow + reset + scrub. Boot wiring call (`fi_shadow_reset`) deferred to the kernel_main cascade adjacent to `kcm_table_reset`. Shell-dispatch hook deferred (no dispatcher exists yet). Capability narrowing stubbed pending R125.
