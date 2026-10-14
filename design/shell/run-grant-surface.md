# `run --grant` shell cap-grant surface — R125.M5 (paideia-os#2595)

**Status.** Accepted. User-space CLI landed at Wave UMB-W13 (M5); kernel-side
override syscall + `caps_decl_apply` splice deferred to M5-cont (follow-up
ticket cited at the end of this doc).

**Scope.** `/bin/run` lets a shell user attach a one-shot capability grant
override to a child process at execve-time, overlaying (M5-cont) the
child's declared `.caps.decl` manifest for one invocation.

**Non-scope at M5.** Rights `delegate`/`passthrough` semantics; grant
provenance tracking; multi-tier (grandparent-grants-child) grants. These are
R125.M6+ work.

---

## 1. Why `/bin/run` and not a shell builtin

The user-visible call shape mirrors `sudo` and `env`, which are both external
tools rather than shell builtins. Three concrete reasons to keep this out of
the shell:

1. **Decoupling.** The grant surface should not vary across shells
   (interactive `/bin/sh`, future `/bin/osh`, service invokers, kernel-side
   spawners). An external `/bin/run` keeps the ABI shell-agnostic.
2. **Audit surface.** A separate binary gives an obvious grep target for
   security review: every grant funnels through one argv parser.
3. **Fork-child posture.** The shell's `exec_child` already forks, and the
   child's first execve is on the external tool. `/bin/run` reads the spec,
   calls the grant-override syscall, then issues its *own* `execve` to the
   target. The kernel sees two execves: the first (shell→run) consumes no
   override; the second (run→target) consumes the pending override. This
   matches the exact single-slot-auto-clear discipline the kernel scratch
   below enforces.

The alternative — a shell builtin that passes the grant blob through a
reserved envp slot or an argv-blob prefix — would:
- widen the shell's argv parser (which has twice absorbed hard-to-reverse
  changes from `-c "..."` and redirect scans),
- require every shell on the system to re-implement the parser, and
- entangle grant provenance with shell state (which shell forked which cmd?
  the shell record would need to carry a grant history field).

External tool wins on all three dimensions.

---

## 2. CLI grammar

```
run [--grant <cap-spec>] <command> [args...]

<cap-spec>  := entry ("," entry)*                          (max 6 entries)
entry       := <name> ":" <rights>
<name>      := [a-zA-Z0-9._-]+                             (max 64 bytes)
<rights>    := "0x" [0-9a-fA-F]{1,16}
```

Max 6 entries matches `CAP_ENV_ROW_WIDTH` in
`src/kernel/core/cap/kind_cap_env.pdx` — the per-env slot count is the real
ceiling, and letting the user exceed it would be a parse error either way.

**Examples.**

```
run /bin/true                                    # no grant; equivalent to plain execve
run --grant fs.read:0x1 /bin/cat /etc/motd
run --grant fs.read:0x1,fs.write:0x2 /bin/sh -c '...'
run --grant ipc.endpoint.1:0x8 /bin/elevate_broker_daemon
```

**argv passthrough.** `argv[0]` seen by the target is the target path
(matches POSIX "argv[0] is the invoked name" convention and avoids
basename extraction logic). `envp` is passed through verbatim from the
shell's envp.

---

## 3. Cap-spec blob format

Byte layout — identical to the ELF `.caps.decl` section the kernel
already consumes (`src/kernel/core/elf/caps_decl_loader.pdx` §SECTION 18):

```
offset  type   name                                        meaning
------  -----  ------------------------------------------  ------------------
0x00    u32    version                                     must be 1
0x04    u32    n_requests                                  1..6
0x08    u64    reserved0                                   MBZ
0x10    CapRequest[n_requests]

CapRequest (24 B):
  0x00  u64  parent_cap_name_hash                          FNV-1a 64 of <name>
  0x08  u64  requested_rights                              AND-mask over parent
  0x10  u32  slot_binding                                  dest slot in child env
  0x14  u32  reserved                                      MBZ
```

Max blob size = `16 + 6*24 = 160` bytes. Stored in `.bss` scratch
(`run_blob`, align 8) inside the `/bin/run` image.

**`parent_cap_name_hash`.** FNV-1a 64 of the name bytes. The kernel's
M3 bridge posture (`caps_decl_loader.pdx` §SECTION 1) masks the low 8
bits to a parent slot index into the invoking task's active env; the
M4 upgrade (R125.M4) swaps this for a real hash lookup against a
per-task name→slot table without changing the on-disk/on-wire format.
`/bin/run` emits the full 64-bit hash and lets the kernel decide
which bits to use.

**`requested_rights`.** Parsed as the 0x-prefixed hex literal verbatim.
The kernel's `_cap_minter_derive` enforces the narrow-only invariant
(§SECTION 1 of `src/kernel/core/svc/cap_minter.pdx`) so a request that
widens a parent right returns `CDL_ERR_RIGHTS_WIDEN = 0x0F32`.

**`slot_binding`.** Assigned by `/bin/run` as the 0-indexed position of
the entry in the spec. First entry → slot 0, second → slot 1, …, sixth
→ slot 5. This matches the auto-append discipline the shell uses when
there is no explicit slot binding in the spec.

---

## 4. User-space flow (M5 posture)

```
/bin/run _start
├─ Phase 0  capture (argc=rdi, argv=rsi, envp=rdx) into callee-save regs
├─ Phase 1  argv guard; argv[1] == "--grant" ? else target = argv[1]
├─ Phase 2  if --grant:
│     ├─ argc < 4 → emit usage, exit RUN_ERR_PARSE (0x1200)
│     ├─ run_parse_spec(argv[2], &run_blob)
│     │     └─ walk entries, FNV-1a each name, parse 0xHEX rights,
│     │        write CapRequest[i] with slot_binding = i,
│     │        write header (version=1, n_requests, reserved0=0).
│     ├─ parse err → emit "run: bad --grant cap-spec", exit RUN_ERR_PARSE
│     ├─ sys_caps_grant_override(blob_ptr, 16 + n*24)   [SC+ 138]
│     │     ├─ rax == 0            → applied; fingerprint and continue
│     │     ├─ rax == -ENOSYS      → kernel pre-M5-cont; emit warning,
│     │     │                        proceed with plain execve
│     │     └─ rax == other        → treat as widen; exit RUN_ERR_WIDEN
│     └─ target = argv[3]
└─ Phase 3  sys_execve(target, &argv[k], envp) where k=1 or 3
             └─ if returns at all (error): emit error, exit RUN_ERR_EXEC
```

### Return taxonomy

| Code              | Numeric | Trigger                                           |
|-------------------|---------|---------------------------------------------------|
| `RUN_OK`          | 0       | Nominally unreachable (execve replaces image)    |
| `RUN_ERR_PARSE`   | 0x1200  | Bad argv count, bad spec, bad hex                 |
| `RUN_ERR_WIDEN`   | 0x1201  | Kernel rejected the grant (widened parent right)  |
| `RUN_ERR_EXEC`    | 0x1202  | `sys_execve` returned (target missing / bad ELF)  |

A warning line to stderr on `-ENOSYS` from SC+ 138 is **not** an error;
the exit status in that case is whatever the target returns via its
own `sys_exit` (or `RUN_ERR_EXEC` if the plain execve itself fails).

---

## 5. Kernel-side contract (M5-cont, deferred)

The follow-up ticket wires three pieces. This section specifies them for
the ticket's own implementor so the on-wire format and sysno are fixed
now.

### 5.1 Syscall surface

- **SC+ ID 138** `sys_caps_grant_override(blob_user_ptr, blob_len) -> u64`
- **Capability bound.** `cap_check` row: no required rights at M5-cont (the
  caller already holds the parent caps the grant narrows; the kernel's
  `_cap_minter_derive` enforces narrow-only. R125.M6 adds a "pass-on"
  right that the parent must hold to be allowed to delegate — until then,
  any task holding a parent cap can grant a narrower view of it to any
  child).
- **Dispatch bounds widen.** `src/kernel/core/syscall/dispatch.pdx:673`
  `cmp rdi, 137; ja dispatch_enosys;` → `cmp rdi, 138`. New arm
  `dispatch_caps_grant_override:` tails into
  `sys_caps_grant_override_body`.
- **Return codes.** `0` = applied; `0x0F30` = bad version; `0x0F31` = unknown
  parent slot; `0x0F32` = widen; `0xFFFFFFFFFFFFFFF3` = -EACCES (if a future
  cap_check row denies). The user-space tool treats any non-zero / non-ENOSYS
  as `RUN_ERR_WIDEN` conservatively; M5-cont can refine.

### 5.2 Kernel-side state

New file `src/kernel/core/svc/caps_grant_override.pdx` owns:

```
pub let mut _caps_grant_override_scratch : [u8; 65536] = uninit @align(16)
pub let mut _caps_grant_override_len     : [u64; 1]    = uninit @align(8)
pub let mut _caps_grant_override_valid   : [u64; 1]    = uninit @align(8)
```

Match `CDL_MAX_SECTION_BYTES = 65536` from `caps_decl_loader.pdx` so a
grant can be as large as a declared manifest.

**Single-slot discipline.** At M5-cont the scratch is one global slot
across all tasks. Writing it with a pending-but-not-yet-consumed grant
is NOT an error; the previous grant is replaced (overwrite is the
intended semantics for a shell flow where the grant's lifetime is one
execve). The scratch MUST auto-clear on execve consumption:

```
caps_decl_apply:
  (1) if _caps_grant_override_valid: pass override blob to caps_decl_parse
      with the CHILD cap-env; THEN clear the slot (one-shot).
  (2) locate .caps.decl in the ELF; if present, pass to caps_decl_parse
      with the same child env.
```

Order matters: the override is applied BEFORE the ELF section so the
ELF section's writes to the same slot_binding land on top of the
override — i.e., the ELF manifest is the floor, the override is the
*override*. (R125.M6 inverts this ordering if needed; at M5-cont we
pick the simpler "manifest-last-wins" shape and let M6 reargue.)

Actually, re-reading the issue — the spec says "temporarily grants the
specified caps to the child process at execve-time, overriding the child's
declared `.caps.decl`". That reads override-last-wins. So the order is:

```
caps_decl_apply:
  (1) locate .caps.decl in the ELF; if present, parse into child env.
  (2) if _caps_grant_override_valid: parse override into child env
      (overwrites slot_binding collisions from step 1); clear the slot.
```

M5-cont picks this (override-last-wins) ordering.

### 5.3 User-pointer validation

`sys_caps_grant_override_body` must gate `blob_user_ptr` through the
same `user_ptr_ok + user_read_bytes_via_walk` pair that
`sys_vol_mint_body` / `sys_dek_seal_body` use (per
`src/kernel/core/syscall/sys_vol_mint_body.pdx` §Walk):

- `blob_len` ≤ 65536
- `blob_len` ≥ 16 (header floor)
- `blob_user_ptr` + `blob_len` is user-mapped read-only across its full
  extent (walk returns 0 on hole / overrun)

On any gate fail: return `-EINVAL` (= `0xFFFFFFFFFFFFFFEA` sign-ext of
-22) and do NOT touch `_caps_grant_override_valid` (leave previous
state).

On success: copy the blob into `_caps_grant_override_scratch`, set
`_caps_grant_override_len` and `_caps_grant_override_valid = 1`,
return 0.

### 5.4 Splice location

`src/kernel/core/elf/caps_decl_loader.pdx:caps_decl_apply` already
chains `locate -> parse` for the ELF section. The splice adds a second
`parse` call BEFORE returning:

```
caps_decl_apply(elf_hdr, child_env):
  rc1 = <existing locate + parse of ELF .caps.decl>
  if _caps_grant_override_valid:
    rc2 = caps_decl_parse(&_caps_grant_override_scratch,
                          _caps_grant_override_len, child_env)
    _caps_grant_override_valid = 0  # auto-clear
    return (rc2 ?: rc1)             # override error overrides manifest ok
  return rc1
```

The error priority is "override reports first" because an override error
is more actionable to the shell user than a manifest error (which is a
developer's own `.caps.decl` section).

---

## 6. Soft-fail progression

Each stage lands with a documented soft-fail posture that the next stage
converts to hard-fail without an ABI change:

| Milestone | Soft-fail at                        | Hard-fail at                         |
|-----------|-------------------------------------|--------------------------------------|
| M3 (landed) | ELF `.caps.decl` error → klog only | M4 after per-task env bind lands     |
| M5 (THIS) | SC+ 138 ENOSYS at user-space         | M5-cont after sysno 138 wires        |
| M5-cont   | Any grant error → `RUN_ERR_WIDEN`    | M6 adds granular codes to taxonomy   |

This mirrors the progression discipline laid out in the Phase-7+ cascade
across R125 (M1→M2→M3→M4 each landed with its own soft-fail arm).

---

## 7. Why single-slot kernel scratch (not per-task)

Three alternatives considered:

1. **Per-task slot.** Store the override in the task's own TCB. Avoids
   racing with concurrent `sys_caps_grant_override` calls across tasks.
   **Rejected at M5-cont** because the TCB field add is a wider change
   than the single-slot scratch, and the race is a non-issue in practice:
   `/bin/run`'s own execve consumes its own override immediately, so the
   only window where another task could overwrite is between
   `sys_caps_grant_override` and `sys_execve` in `/bin/run` — a window
   that is zero instructions outside the kernel. Future SMP-live
   execution adds a per-task TCB slot in R128+ when the task-struct
   layout churn is already scheduled.

2. **Argv-passed blob.** Pass the blob as an extra fixed argv slot. The
   kernel reads `argv[argc]` which it already walks for the NULL
   terminator. **Rejected** because every ring-3 ABI consumer would need
   to know about and preserve this slot; a thin shell wrapper that
   builds its own argv array would silently drop it.

3. **Envp-passed blob.** Mint a reserved envp key like
   `_PDX_CAP_GRANT_OVERRIDE=0x<blob_bytes_hex>`. **Rejected** for the
   same reason as (2) plus the "every env dump leaks the grant" leak.

Single-slot scratch wins because the "post-fork, same task, pending
execve" shape is the exact single-threaded window the design needs.

---

## 8. Encoder-pitfall adherence

`/bin/run` was authored against the paideia-as encoder gotcha list
(see `feedback_pdx_encoder_pitfalls`):

- byte loads: `xor rax, rax; mov_b rax, [ptr]; cmp rax, imm`
  (paideia-as #1248 mitigation)
- no `test rN, rN` → `cmp rN, 0`
- no 2-op `imul r, imm` → `shl` + `add` folding
- no `and r11, imm64` → stage imm into `r10` first
- stride multiplies by 24: `(x<<3) + (x<<4)`
- hex folds: `shl r15, 4; add r15, nibble`
- labels prefixed `run_` (no `loop`, `if`, `fn`, `let`)
- fingerprint tags: `N = len(string) + 1` (NUL counted)
- module basename matches file: `Run` ↔ `run.pdx`

The kernel-side M5-cont scaffolding (`caps_grant_override.pdx`) follows
the same list.

---

## 9. Follow-up: M5-cont ticket (sibling to #2595)

**Title:** `R125.M5-cont — wire sys_caps_grant_override (SC+ 138) + caps_decl_apply splice`

**Scope.**
1. Add `src/kernel/core/svc/caps_grant_override.pdx` with the scratch
   state and `sys_caps_grant_override_body` syscall body (per §5.2 /
   §5.3 of this doc).
2. Widen the dispatch bounds in
   `src/kernel/core/syscall/dispatch.pdx:673` from 137 to 138 and add
   the sysno-138 arm.
3. Edit `src/kernel/core/elf/caps_decl_loader.pdx:caps_decl_apply` to
   add the override-apply + auto-clear step after the ELF section's
   own apply (per §5.4).
4. Add `/bin/run` to the tmpfs seed table at
   `src/kernel/boot/witness/bin_seeds.pdx` so the shell can resolve
   `run /bin/true` through the path walker.
5. Fingerprint: `boot_r125_m5cont_run_grant_applied` after a boot-time
   witness that spawns `/bin/run --grant fs.read:0x1 /bin/true`
   through the shell and checks the kernel's `caps.decl: section
   absent` *does not* fire for the target (because the override
   populated the child env).

**Depends on.** This issue (#2595) landed.

**Deliverable.** Boot smoke exercises the end-to-end flow; wire the
fingerprint into `tools/hw-smoke-fingerprints.md`.

---

## 10. Non-goals for R125.M5 (this landing)

- No `/bin/run` tmpfs seed (M5-cont adds it alongside the kernel work).
- No shell builtin fallback for `--grant` (external `/bin/run` is the
  single surface).
- No `--revoke` sibling (R125.M7+).
- No syscall counter / audit trail of grants (R130 scope).
