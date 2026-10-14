# ELF `.caps.decl` section — declared capabilities loader (R125.M3)

**Status:** accepted (Wave UMB-W10, 2026-10-11)
**Depends on:** R125.M1 KIND_CAP_ENV (Wave 87), R125.M2 `svc.cap-minter` (Wave 96)
**Blocks:** R125.M4 (manifest linter), R125.M5 (`run --grant` CLI), R125.M6 (toolchain emitter)
**Closes:** paideia-os#2593

---

## 1. Problem statement

A PaideiaOS child process inherits nothing from its parent by default: no
file descriptors, no namespace handles, no device access — nothing. Every
authority is a *capability*, held in a per-task `KIND_CAP_ENV` slot
(R125.M1). An execve therefore starts the child with an empty cap-env;
without further plumbing, the child cannot name any resource.

R125.M2 added `svc.cap-minter`, a privileged daemon that *derives* a
capability from one the caller already holds, narrowed to a subset of
rights. That gives us the mechanism — but not the policy that decides
*which* caps a new process should receive.

**R125.M3 (this document) is that policy carrier.** It lets a program
embed a *manifest* in its own ELF image declaring the capabilities it
needs. At execve time, the kernel reads the manifest, calls the minter
once per request, and populates the child's cap-env before transferring
control.

The design is deliberately **novel** (per
[novel + clean design bias](project_novel_clean_design.md)) — not
POSIX `setuid`/`setgid`, not Linux file capabilities (`xattr`), not
Capsicum. See §9 for the comparative analysis.

---

## 2. Design goals

1. **Static declaration.** A program's capability needs are visible at
   link time, auditable with `objdump`-equivalents, and signed as part of
   the image.
2. **No ambient authority.** The kernel never grants a capability the
   parent did not already hold; the manifest *filters down* parental
   authority, it does not conjure new.
3. **Fail-closed.** Any manifest error — bad version, unknown parent cap,
   rights widening — fails the execve with `EACCES`. Partial populations
   are never visible to user code.
4. **Zero-cost absent.** Programs without a `.caps.decl` section pay a
   single section-header scan on execve and nothing else.
5. **One place to look.** The manifest lives in the ELF image itself,
   not in a sidecar config, so a program's cap profile cannot drift from
   its binary.

---

## 3. Section format

**Section name:** `.caps.decl`
**Section type:** `SHT_PROGBITS`
**Section flags:** `SHF_ALLOC = 0` (metadata; not loaded into child VA)
**Alignment:** 8 bytes.

**Byte layout** (little-endian; 16 B header + 24 B per request):

| Offset | Type              | Field                 | Notes                                 |
| -----: | ----------------- | --------------------- | ------------------------------------- |
| `0x00` | `u32`             | `version`             | Must equal `CDL_SECTION_VERSION = 1`. |
| `0x04` | `u32`             | `n_requests`          | ≤ `CDL_MAX_REQUESTS = 256`.           |
| `0x08` | `u64`             | `reserved0`           | MBZ; reserved for future flag bits.   |
| `0x10` | `CapRequest[n]`   | packed request array  | each 24 B, see below.                 |

**`CapRequest` (24 B)**

| Offset | Type  | Field                   | Semantics                                 |
| -----: | ----- | ----------------------- | ----------------------------------------- |
| `0x00` | `u64` | `parent_cap_name_hash`  | FNV-1a 64-bit of parent cap's name string.|
| `0x08` | `u64` | `requested_rights`      | AND-mask applied to parent's rights.      |
| `0x10` | `u32` | `slot_binding`          | Destination slot index in child cap-env.  |
| `0x14` | `u32` | `reserved`              | MBZ.                                      |

The ceiling `CDL_MAX_SECTION_BYTES = 65536` caps the full section at
64 KiB — enough for 2730 requests, well beyond `CDL_MAX_REQUESTS`.

### 3.1 Name hashing

Cap names are hashed on the way in with FNV-1a-64 using the constants:

```
FNV1A64_OFFSET = 0xCBF29CE484222325
FNV1A64_PRIME  = 0x00000100000001B3
```

The toolchain emitter (R125.M6) emits only the hash; the kernel never
reads the raw name string, which keeps the parse hot path free of a
string-table dereference and leaves no cap-name text in the loaded image
for a reverse engineer to grep. The downside — hash collisions silently
alias caps — is bounded: in a 2^64 space with a few hundred cap names
per task, collision probability is negligible, and `svc.cap-minter`
rejects a derive that produces a handle with a mismatched *type* kind,
closing the one remaining weakness.

### 3.2 Slot binding

`slot_binding` is the index into the child's cap-env where the derived
handle is deposited. Programs typically know their own slot layout at
compile time (e.g. slot 0 = stdin, slot 1 = stdout, slot 2 = terminal
service). The sentinel `CDL_SLOT_APPEND = 0xFFFFFFFF` requests "append
to first free slot" and is used by boot-time inits that don't want to
pin a layout.

---

## 4. Execve integration

### 4.1 Where it fires

The hook runs inside `sys_execve_body` **after** the ELF image is fully
mapped into the child's VA space and **before** control transfers to the
child entry point. Specifically, it sits between:

- *(upstream)* `_elf_load_image` returns the mapped-header pointer, and
- *(downstream)* `_execve_enter_user` performs the final iretq.

The call is one line (see §4.3). Precise placement matters:

* Running the hook *before* `_elf_load_image` would be pointless — the
  section bytes are not yet readable.
* Running it *after* `_execve_enter_user` is unreachable — control has
  already left kernel mode.
* The child's `KIND_CAP_ENV` slot already exists at this point (allocated
  during task-struct construction earlier in `sys_execve_body`).

### 4.2 Hook semantics

```
status = _caps_decl_apply(elf_header_ptr, child_cap_env_slot)
if (status != CDL_OK) {
    /* _caps_decl_apply has already klog-warned. */
    _execve_rollback(child)
    return -EACCES
}
```

`_caps_decl_apply` is the single-call convenience wrapper exported by
`caps_decl_loader.pdx`; it internally performs `_caps_decl_locate` and,
if the section exists, `_caps_decl_parse`. Section absent is **not** an
error — the child simply starts with an empty cap-env, which is the
right policy for everything from init to privileged daemons that will
receive their caps from a supervisor over the cap-minter RPC later.

### 4.3 Exact splice (`sys_execve_body.pdx`)

The hook adds **three lines** to `sys_execve_body` immediately after the
ELF load completes and before user transfer. Caller must have

* `r12` = `elf_header_ptr` (set by `_elf_load_image`),
* `r13` = `child_cap_env_slot` (set by `_task_struct_new`).

Splice:

```asm
    ; --- R125.M3: apply ELF .caps.decl manifest to child's cap-env ---
    mov  rdi, r12
    mov  rsi, r13
    call _caps_decl_apply
    cmp  rax, 0
    jne  sys_execve_body_caps_fail
    ; -----------------------------------------------------------------
```

and the `sys_execve_body_caps_fail` landing pad:

```asm
sys_execve_body_caps_fail:
    ; _caps_decl_apply has already emitted a klog warning.
    mov  rdi, r14             ; r14 := child task handle
    call _execve_rollback
    mov  rax, 0x0D            ; -EACCES
    neg  rax
    jmp  sys_execve_body_exit
```

Register conventions follow the existing `sys_execve_body` scheme (see
header comment of that file). If `r12`/`r13` in that file hold different
values at the splice point, the splice should materialise the correct
operands from wherever they live; the *contract* is `rdi = elf_hdr_ptr,
rsi = child_cap_env_slot`.

---

## 5. Public API

Defined in `src/kernel/core/elf/caps_decl_loader.pdx`.

### 5.1 `_caps_decl_locate(elf_header_ptr) -> packed u64`

Scans section headers for a section whose name hashes to
`CDL_SECTION_NAME_HASH` (FNV-1a of `".caps.decl"`).

Returns `(section_file_offset << 32) | (section_size & 0xFFFFFFFF)`.
Both halves zero ⇒ section absent (not an error).

### 5.2 `_caps_decl_parse(section_bytes_ptr, section_len, child_cap_env_slot) -> errno`

Validates the header, walks `n_requests` records, and for each one:

1. Resolves `parent_cap_name_hash` against the *invoking* task's cap-env
   via `_cap_env_lookup_by_hash`.
2. Calls `_cap_minter_derive(parent, requested_rights, caller_env)`.
3. Inserts the derived handle into `child_cap_env_slot` at
   `slot_binding`.

Any validation failure emits a klog warning and returns a nonzero
errno; see §6 for codes.

### 5.3 `_caps_decl_apply(elf_header_ptr, child_cap_env_slot) -> errno`

Convenience wrapper used by `sys_execve_body`. Equivalent to
`locate` followed by `parse`; treats section-absent as success with
empty env.

---

## 6. Return codes

| Code  | Symbolic name           | Meaning                                                                |
| ----- | ----------------------- | ---------------------------------------------------------------------- |
| `0`   | `CDL_OK`                | Manifest applied (or absent).                                          |
| `0x0F30` | `CDL_ERR_BAD_VERSION` | Version mismatch, header truncated, or `section_len` does not match `header + n_requests * 24`. Also returned for `n_requests > CDL_MAX_REQUESTS` and section > ceiling. |
| `0x0F31` | `CDL_ERR_BAD_HASH`    | A `parent_cap_name_hash` does not resolve against the invoking task's cap-env. |
| `0x0F32` | `CDL_ERR_RIGHTS_WIDEN` | `_cap_minter_derive` rejected the request because `requested_rights` is not a subset of the parent's rights, OR `_cap_env_insert` refused the derived handle. |

Non-zero codes become `-EACCES` at the `sys_execve_body` boundary. The
specific numeric code is preserved in klog for forensics but not visible
to user code (information-leak defence).

---

## 7. Interaction with other R125 milestones

### 7.1 R125.M1 — KIND_CAP_ENV (Wave 87)

`_cap_env_lookup_by_hash` and `_cap_env_insert` are the two surfaces of
the KIND_CAP_ENV substrate the loader consumes. The child's cap-env is
already allocated by the time the loader runs; this module only
*populates* it.

### 7.2 R125.M2 — svc.cap-minter (Wave 96)

Every request flows through `_cap_minter_derive`. The loader never
constructs a handle on its own; it is a pure *orchestrator* over the
minter. In particular:

* **Rights narrowing** happens entirely in the minter. The loader does
  not inspect rights bits.
* **Audit trail**: the minter already logs each derive; the loader
  therefore inherits a clean audit chain without duplicating it.
* **Future rate-limiting**: when the minter grows a budget (R125.M8),
  it applies here automatically.

### 7.3 R125.M5 — `run --grant` (future)

`run --grant <cap>:<rights>` will *augment* the embedded manifest at
launch time without rewriting the binary. The implementation path:

1. The shell constructs a synthetic `.caps.decl` payload in an anonymous
   kernel buffer.
2. `sys_execve` learns a new "manifest overlay" argument that, when
   present, calls `_caps_decl_parse(overlay_ptr, overlay_len, child)`
   *after* the ELF-embedded one.
3. The overlay follows exactly the same validation and derive rules —
   `run --grant` cannot bypass the minter, cannot widen rights, cannot
   add caps the invoking shell does not already hold.

Design implication: the parse function is intentionally reentrant on
a single child env. Multiple `_caps_decl_parse` calls can accumulate
caps into the same env, matching the overlay model.

### 7.4 R125.M4 — manifest linter (future)

A static linter will verify at link time that a `.caps.decl` section
is well-formed, that slot bindings don't collide, and that cap-name
hashes correspond to a known schema (`caps/registry.pdxd`). The
kernel is deliberately *more permissive* than the linter: it accepts
unknown hashes (returning `CDL_ERR_BAD_HASH` at runtime) rather than
hardcoding a schema, because the schema evolves faster than the
kernel does.

### 7.5 R125.M6 — toolchain emitter (future)

`paideia-as` will grow a `#[caps]` directive that compiles down to a
`.caps.decl` section. The emitter and this loader share the layout
constants in §3; a round-trip test (R125.M9) will enforce the
contract.

---

## 8. Threat model

| Threat                                            | Defence                                                                            |
| ------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Hostile ELF declares a cap the parent lacks       | `_cap_env_lookup_by_hash` fails → `CDL_ERR_BAD_HASH` → `EACCES`.                   |
| Hostile ELF asks for wider rights than parent     | `_cap_minter_derive` rejects → `CDL_ERR_RIGHTS_WIDEN` → `EACCES`.                   |
| Hostile ELF declares 2^31 requests                | `CDL_MAX_REQUESTS = 256` and `CDL_MAX_SECTION_BYTES = 65536` → `CDL_ERR_BAD_VERSION`.|
| Hostile ELF truncates the section                 | `section_len != header + n*24` check → `CDL_ERR_BAD_VERSION`.                      |
| Hostile ELF stuffs non-NUL section name          | Name hashing bounded to `CDL_SECTION_NAME_LEN = 10` + NUL stop → no overread.      |
| Section name collides with another section        | FNV-1a 64 collision space; mitigated by minter type-check on derive.               |
| Hostile ELF forges `.caps.decl` of a trusted bin  | ELF image is content-addressed and signed upstream of this loader; out of scope.   |
| Overflow in `n_requests * 24` size computation    | `n_requests` is `u32` ≤ 256; `24 * 256 = 6144` fits in `u32`. No overflow.         |
| TOCTOU between locate and parse                   | Both read the same mapped ELF image; the image is immutable at this point.        |

---

## 9. Why not just …?

* **POSIX `setuid`.** Grants *ambient* authority (whole-user), not
  per-resource caps. Doesn't compose. Rejected.
* **Linux file capabilities (xattr).** Caps live in filesystem metadata,
  not the binary — they can drift (copy loses them, rsync loses them).
  Rejected.
* **Capsicum / FreeBSD cap mode.** Dynamic entry into a sandbox at
  runtime. Doesn't let the kernel *populate* initial caps declaratively.
  We complement rather than replace: a program entered with a declared
  manifest *could* then enter a Capsicum-style sandbox. Future work.
* **seccomp-bpf profiles.** A deny-list over syscalls, not an authority
  model. Orthogonal.
* **A sidecar `.caps` file next to the binary.** Separates policy from
  code; policy drifts, gets lost, gets stripped. Rejected.

The chosen design matches the pattern from the Barrelfish and Multics
literatures where program-declared capabilities are a first-class
property of the image; see `design/foundations/capabilities-survey.md`.

---

## 10. Testing

* **Unit (post R125.M6 emitter):**
  - section-absent → `CDL_OK`, empty env, no klog warning except the
    informational "absent" message.
  - zero requests, well-formed header → `CDL_OK`, empty env.
  - bad version (`0`, `2`, `0xFF…`) → `CDL_ERR_BAD_VERSION`.
  - `n_requests * 24 + 16 != section_len` → `CDL_ERR_BAD_VERSION`.
  - `n_requests = 257` → `CDL_ERR_BAD_VERSION`.
  - unknown cap-name hash → `CDL_ERR_BAD_HASH`.
  - widened rights → `CDL_ERR_RIGHTS_WIDEN`.
  - slot collision in child env → `CDL_ERR_RIGHTS_WIDEN` (via insert).
  - `CDL_SLOT_APPEND` → placed at first free slot.

* **Integration:**
  - Shell `run foo` where `foo` has a `.caps.decl` declaring stdin/stdout
    → child receives both derived caps, nothing else.
  - Shell `run foo` where `foo` declares a cap the shell doesn't hold
    → execve returns `EACCES`, child never exists.

* **Fuzz:**
  - 1 MiB of random bytes at the `.caps.decl` section offset — the
    parser must never panic or over-read; always one of the four return
    codes.

---

## 11. Table of contents

1. Problem statement
2. Design goals
3. Section format
   3.1 Name hashing
   3.2 Slot binding
4. Execve integration
   4.1 Where it fires
   4.2 Hook semantics
   4.3 Exact splice (`sys_execve_body.pdx`)
5. Public API
   5.1 `_caps_decl_locate`
   5.2 `_caps_decl_parse`
   5.3 `_caps_decl_apply`
6. Return codes
7. Interaction with other R125 milestones
   7.1 KIND_CAP_ENV
   7.2 svc.cap-minter
   7.3 `run --grant`
   7.4 Manifest linter
   7.5 Toolchain emitter
8. Threat model
9. Why not just …?
10. Testing
11. Table of contents

---

*Closes paideia-os#2593.*
