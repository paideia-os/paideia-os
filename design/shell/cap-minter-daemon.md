# svc.cap-minter — sub-capability derivation daemon

**Status:** M2 skeleton, 2026-10-11.
**Umbrella:** paideia-os #2478 (R125, capability flow at exec).
**Milestone:** R125.M2 (paideia-os #2592, Wave UMB-W9).
**Companion substrate:** [kind_cap_env.pdx](../../src/kernel/core/cap/kind_cap_env.pdx) (R125.M1, Wave UMB-W1).
**Companion module:** [cap_minter.pdx](../../src/kernel/core/svc/cap_minter.pdx) (this landing).

---

## 1. Why a daemon

R125's thesis is "every command runs in a bounded cap-flow". The shell
mints a KIND_CAP_ENV (R125.M1), stuffs it with the caps the command is
authorised to touch, freezes it, and hands it to the cmd-module
launcher. Once that env is frozen the running command cannot ask the
shell for a widened cap — but it CAN ask for a NARROWER one. The
canonical example:

> A command holds a read-write cap on the filesystem root. It wants to
> hand a child subprocess a READ-ONLY view of the same root so the
> child cannot mutate state the parent still trusts.

Derivation is a MUTATION of the caller's cap-env (a child cap written
into a free env slot) and an ALLOCATION of a fresh cap_table
descriptor. Neither action sits on the "every op reads only" surface
of the R125.M1 handler. We route the derive request through a NAMED
IPC endpoint (`svc.cap-minter`) that running processes bind via
`svc_lookup`.

The alternative — exposing derive as a cap_invoke op on KIND_CAP_ENV —
is left for R125.M3 where the caller's env is in scope through the IPC
dispatcher. At M2 the ring-3 reachable op surface stays read-only
(COUNT, LOOKUP, IS_FROZEN); OP_DERIVE (= 3) is reserved but unwired.

## 2. Service identity

| Field          | Value                                              |
|----------------|----------------------------------------------------|
| Service name   | `svc.cap-minter`                                   |
| Name length    | 14 bytes                                           |
| Endpoint id    | 20                                                 |
| Bringup entry  | `_cap_minter_init()` in `cap_minter.pdx`           |
| Boot hook      | `kernel_main.pdx` after `schema_registry_bringup`  |
| Return code 0  | `CM_OK`                                            |
| Return code 1+ | `CM_ERR_*` (0x0F01..0x0F03)                        |
| Bringup codes  | `CM_BRINGUP_EP_FAIL` 0xFFFFEBD0, `_REG_FAIL` D1    |

Endpoint id 20 sits in the kernel-side svc.* reservation band
(16=elevate-broker, 17=audit-journal, 18=schema-registry, 19 reserved
for an audit-adjacent slot, 20=cap-minter). The free band
`0xFFFFEBC8..0xFFFFEBDF` noted in `cmd_invoke.pdx` provides the
bringup error codes.

## 3. Public API

### 3.1 `_cap_minter_init() -> u64`

Boot hook. Shape mirrors `schema_registry_bringup` one-for-one:

1. `endpoint_alloc_at(20)` — on refusal returns `CM_BRINGUP_EP_FAIL`
   WITHOUT calling `svc_register` (the "do not partially install the
   row" discipline from R48-PREP-005.M1 and R90-XREPO.012.M2-002).
2. `svc_register("svc.cap-minter", 14, 20)` — on refusal returns
   `CM_BRINGUP_REG_FAIL`.
3. Normalises `_cap_minter_active_env[0]` to `CM_ENV_NONE` (0xFF). The
   .bss zero-init would leave this at 0, which is a VALID env handle;
   0xFF is the "no caller" sentinel the derive path expects.
4. Emits one fingerprint:
   - `CAP_MINTER INIT OK` on success.
   - `CAP_MINTER INIT FAIL errno=0x..` on either failure path.

### 3.2 `_cap_minter_set_active_env(env_handle) -> ()`

Harness-side setter. Writes `_cap_minter_active_env[0]`. Validates
`env_handle` in `[0, 16)` or `== CM_ENV_NONE`; any other value clamps
to `CM_ENV_NONE` so a stale caller cannot park a nonsense handle.
Emits `CAP_MINTER SET_ENV env=0x..`.

At M2 the ambient active env is set by:

- A boot smoke harness pinning a specific env before invoking
  `_cap_minter_derive` directly.
- The R125.M3 IPC dispatcher writing the active env from the caller's
  process cap-env on message entry.

At M3+ the global becomes thread-local-equivalent (per-CPU through
`gs:`-relative access, matching the existing per-CPU runqueue
discipline). The M2 global is deliberately single-slot to keep the
substrate testable before the IPC lift.

### 3.3 `_cap_minter_derive(parent_cap_slot, requested_rights, out_slot_ptr) -> errno`

The hot path. See [§4](#4-derivation-semantics) for the algorithm.

| Arg (SysV)   | Meaning                                                 |
|--------------|---------------------------------------------------------|
| `rdi`        | `parent_cap_slot` — env slot id (0..5) in caller's env  |
| `rsi`        | `requested_rights` — bit mask (u64)                     |
| `rdx`        | `out_slot_ptr` — writeable `u64*` for the new env slot  |

**Return (rax):**

| Code | Symbol                   | Condition                                   |
|------|--------------------------|---------------------------------------------|
| 0    | `CM_OK`                  | success; `*out_slot_ptr` holds new env slot |
| 0x0F01 | `CM_ERR_PARENT_INVALID`| no active env OR parent slot invalid        |
| 0x0F02 | `CM_ERR_RIGHTS_WIDEN`  | requested rights exceed parent rights       |
| 0x0F03 | `CM_ERR_ENV_FULL`      | env frozen OR no free env slot OR cap pool full |

### 3.4 IPC frame layout (deferred to R125.M3 wiring)

The daemon's named endpoint receives DERIVE frames. The frame body
(16 bytes, per `src/kernel/core/ipc/frame.pdx` payload discipline)
carries:

```
+0   u16  op_code     = 1 (DERIVE)
+2   u16  parent_slot
+4   u32  reserved
+8   u64  requested_rights
```

The REPLY frame carries `errno` + `env_slot_id` (on OK). This layout
is pinned here so the ring-3 client ABI is stable before the frame
dispatcher lands.

## 4. Derivation semantics

A derived child cap:

- **Same resource.** `kind` and `target_ptr` match parent — the child
  names the same underlying resource (same filesystem inode, same
  framebuffer, same socket).
- **Narrower rights.** `requested_rights` ⊆ `parent_rights`. A widened
  right is a privilege escalation and is rejected with
  `CM_ERR_RIGHTS_WIDEN`.
- **Fresh descriptor.** Allocated from the `[CM_SLOT_BASE,
  CM_SLOT_LIMIT) = [192, 256)` reserved range of `cap_table` (see §5).
- **Independent lifetime.** The parent's revoke does not implicitly
  revoke the child at M2; lineage tracking is R128 scope. A child is
  revoked independently (or stays live past parent death).
- **Env-visible.** Written into a free env slot of the caller's
  cap-env so the caller addresses it by env slot (0..5).

### 4.1 The narrow-only invariant

```
(requested_rights & parent_rights) == requested_rights
```

Equivalently, `(requested_rights & ~parent_rights) == 0`. We use the
first form because paideia-as does not emit `not reg`; the AND-and-
compare is one instruction shorter and sidesteps the encoder gap.

### 4.2 The frozen-env case

The shell's R125.M1 flow is:

```
env = cap_env_create()
cap_env_insert(env, 0, fs_cap)
cap_env_insert(env, 1, net_cap)
...
cap_env_freeze(env)      # no more insertions permitted
hand env to cmd-module launcher
```

After FREEZE, `cap_env_insert` refuses with `CAP_ENV_ENV_FROZEN`. The
cap-minter's step-8 frozen-flag check in `_cap_minter_derive` catches
this and returns `CM_ERR_ENV_FULL` without allocating anything.

**Open design question (R125.M3):** should derivation unfreeze the env
to admit the child? Three options:

1. **Keep frozen; return `CM_ERR_ENV_FULL`.** The M2 posture.
   Simplest; forces the shell to pre-derive before FREEZE. Harsh on
   dynamic callers.
2. **Reserve derive-only slots.** The env has 6 slots; mark some
   subset (e.g. slots 4..5) as "FROZEN-does-not-apply" and let the
   cap-minter write into those post-FREEZE. Changes R125.M1
   invariants.
3. **Child env.** The derivation creates a NEW cap-env, mints the
   child cap into it, and returns a handle to that env. Matches
   subprocess spawn semantics (child inherits a derived view). Likely
   the right long-term answer but adds a cap-env to the lifecycle.

M2 picks (1) explicitly because (2) and (3) each require a design
pass. The resolution is pinned by R125.M3 which lifts the per-caller
context in a way that will make (3) nearly free.

## 5. Reserved cap_table slot range

`cap/slab.pdx:slab_alloc` is a Phase-2 stub that returns
`CAP_SLAB_CAPACITY` (256) unconditionally — a "slab full" sentinel
until the free-list is rewritten. Using it in the daemon would make
every M2 derivation return `CM_ERR_ENV_FULL` which is useless for
bringup.

Until the slab is rewritten, the cap-minter owns a reserved range of
`cap_table` slots:

```
CM_SLOT_BASE  = 192
CM_SLOT_LIMIT = 256       (= CAP_SLOT_MAX)
```

Giving the daemon 64 derived cap slots. Low slots (`0..191`) remain
available for early-boot kernel-side mints, witness fixtures, and
ring-3 syscall-minted descriptors. A landing-time audit (`grep
'*24+0]' src/kernel/`) showed zero live producers in `[192, 256)`.

**Allocation:** linear scan `cmnt_find_free_cap_slot` finds the first
slot where `kind` (at offset +0) is zero. The .bss zero-init of
`cap_table` guarantees fresh slots satisfy this. There is no slab-free
at M2 (slot reuse is bounded by chaos-restart or process death, both
of which clear via higher-level revoke paths not yet wired to the
cap-minter's reserved range).

**Migration:** when the Phase-3 slab allocator lands (R128.M*
+ lineage), the daemon switches to `slab_alloc`/`slab_free` and the
reserved range becomes a no-op. The constants stay as upper bounds for
witness audit, then retire once the slab is proven.

## 6. KIND_CAP_ENV op 3 reservation

This landing also edits `kind_cap_env.pdx`:

```
pub let CAP_ENV_OP_COUNT     : u64 = 0
pub let CAP_ENV_OP_LOOKUP    : u64 = 1
pub let CAP_ENV_OP_IS_FROZEN : u64 = 2
pub let CAP_ENV_OP_DERIVE    : u64 = 3    // NEW, R125.M2
pub let CAP_ENV_OP_MAX       : u64 = 3    // was 2
```

The op number is reserved; the dispatch arm in `cap_handler_cap_env`
is NOT wired at M2. The current handler masks `op_arg` to its low 16
bits (`op_code[7:0]` + `slot[15:8]`) which is insufficient for DERIVE
(needs `parent_slot` + `requested_rights` + a return seat). R125.M3
widens the mask and wires the arm to call through to
`_cap_minter_derive_handler`.

**Op-level encoding (deferred to R125.M3):**

```
op_arg layout:
  [7:0]    op_code = 3 (DERIVE)
  [15:8]   parent_slot
  [31:16]  requested_rights (16 bits sufficient for M3; expansion to
                              full 64 bits lifts the encoding to a
                              second u64 arg once cap_invoke grows a
                              4-arg form, R125.M5+)

Return in rax:
  on success: env_slot_id of the new cap (0..5)
  on error:   INVOKE_DENIED (the standard sentinel; the specific
              CM_ERR_* code appears in the klog fingerprint)
```

## 7. Interaction with R125.M3 — ELF caps.decl loader

R125.M3 adds the ELF `.caps.decl` loader that reads a command binary's
declared cap-flow at launch and installs it into the env the shell
hands to `cmd_module_invoke`. The cap-minter interacts with M3 in two
places:

- **Pre-FREEZE derivations.** The loader may call `_cap_minter_derive`
  BEFORE calling `cap_env_freeze` to materialise sub-caps from the
  parent-shell's env into the child-command env. Example: the shell
  holds `fs_cap(RW)`; `.caps.decl` says `fs: ro`; the loader derives
  `fs_cap(R)` from the shell's RW and inserts into the child env at
  slot 0.
- **Caller-context propagation.** M3 wires the IPC dispatcher so an
  incoming DERIVE frame sets `_cap_minter_active_env` to the caller's
  process cap-env. This replaces the M2 harness-set setter. The
  per-CPU variant comes with R125.M4.

## 8. Interaction with R125.M5 — `run --grant`

R125.M5 adds the shell's `run --grant` flag which overlays shell-time
rights grants onto the launched command's env. The cap-minter is the
mechanism:

```
run --grant fs:ro mycmd
```

→ shell derives `fs_cap(R)` from its own `fs_cap(RW)` via
`_cap_minter_derive`, inserts into the staging env for `mycmd`,
freezes, launches.

The grant form is strictly `--grant <role>:<rights-letters>` where
rights-letters is a strict subset of the shell's own rights for that
role. The widen check in `_cap_minter_derive` is the enforcement
point; the shell parser rejects widening before the daemon call so a
widened `--grant` surfaces as a shell error, not a `CM_ERR_RIGHTS_WIDEN`.

## 9. Interaction with R125.M6 — capability-typed arguments

R125.M6 types command-line arguments as capabilities. A command
signature like

```
fn mkdir : (path: cap<fs, R:W:X>) -> ()
```

means the shell must present a `fs` cap with at least `R|W|X` rights.
The cap-minter is invoked when the shell's own cap carries MORE rights
than the command declaration admits:

- Shell holds `fs_cap(R:W:X:D)` (RWX + delete).
- Command declares `(path: cap<fs, R:W:X>)` (no delete).
- Shell derives `fs_cap(R:W:X)` via `_cap_minter_derive`, inserts into
  the staging env.

This is the inverse of `--grant`: `--grant` is user-declared narrowing;
R125.M6 is type-system-enforced narrowing. Both land through the same
daemon.

## 10. Error taxonomy (reprise)

| Code         | Symbol                   | When                                              |
|--------------|--------------------------|---------------------------------------------------|
| 0            | `CM_OK`                  | success                                           |
| 0x0F01       | `CM_ERR_PARENT_INVALID`  | active env unset, parent slot empty/out-of-range, parent cap kind 0 |
| 0x0F02       | `CM_ERR_RIGHTS_WIDEN`    | requested rights NOT a subset of parent rights    |
| 0x0F03       | `CM_ERR_ENV_FULL`        | env frozen, env has no free slot, OR reserved cap pool exhausted |
| 0xFFFFEBD0   | `CM_BRINGUP_EP_FAIL`     | `endpoint_alloc_at(20)` refused at boot           |
| 0xFFFFEBD1   | `CM_BRINGUP_REG_FAIL`    | `svc_register` refused at boot                    |

The three `CM_ERR_*` codes fit imm32 with bit 31 clear so they emit
via the 7-byte zero-extending `mov rax, imm32` form. The band
`0x0F01..0x0F03` is clean (`grep -rnE '0x0F0[1-3]\b' src/kernel/`
returned zero hits at landing).

## 11. Observability

`_cap_minter_stats[8]` tracks:

| Index | Symbol                      | Bumped when                     |
|-------|-----------------------------|---------------------------------|
| 0     | `CM_ST_INIT_OK`             | `_cap_minter_init` succeeds     |
| 1     | `CM_ST_INIT_EP_FAIL`        | `endpoint_alloc_at` refused     |
| 2     | `CM_ST_INIT_REG_FAIL`       | `svc_register` refused          |
| 3     | `CM_ST_DERIVE_OK`           | derivation succeeds             |
| 4     | `CM_ST_DERIVE_PARENT`       | parent-invalid rejection        |
| 5     | `CM_ST_DERIVE_WIDEN`        | rights-widen rejection          |
| 6     | `CM_ST_DERIVE_ENV_FULL`     | env-full rejection              |
| 7     | `CM_ST_SET_ACTIVE_ENV`      | set_active_env called           |

Fingerprints emitted (all `SUBSYS_CAP_`, `LEVEL_INFO`):

- `CAP_MINTER INIT OK`
- `CAP_MINTER INIT FAIL errno=0x..`
- `CAP_MINTER DERIVE OK env=0x..`
- `CAP_MINTER DERIVE REJ errno=0x..`
- `CAP_MINTER SET_ENV env=0x..`

The successful-insert path ALSO emits the inherited `CAP_ENV INSERT
env=0x.. slot=<dec>` fingerprint from `cap_env_insert` — so a derive
+insert pair appears as two adjacent lines in the klog.

## 12. Encoder-pitfall posture

Standard R125 discipline:

- Labels prefixed `cmnt_` (cap-minter; disjoint from `cm_`
  cmd_module, `kcm_` kind_cmd_module, `ce_` kind_cap_env).
- `cmp rN, 0` (never `test rN, rN`).
- `shl rN, 3` / `shl rN, 4` compose stride*24 (never `imul r, imm`).
- `mov rax, imm32` for 32-bit zero-extending constants (never `and
  r11, imm64`).
- Single-line `pub let name = "..."` declarations.
- Module basename `CapMinter` matches file basename `cap_minter.pdx`.
- Fingerprint `[u8; N]` with N = len(string) + 1 (trailing NUL counts).
- Narrow-only check via AND-and-compare (sidesteps the `not reg`
  encoder gap).

Stack discipline (SysV, entry rsp%16==8):

- `_cap_minter_init`                 : 1 push (rsp%16==0 at call site).
- `_cap_minter_set_active_env`       : 1 push.
- `_cap_minter_get_active_env`       : pure leaf, 0 pushes.
- `cmnt_note`                        : pure leaf, 0 pushes.
- `cmnt_find_free_env_slot`          : 2 pushes + `sub rsp, 8` realign.
- `cmnt_find_free_cap_slot`          : pure leaf, 0 pushes.
- `_cap_minter_derive`               : 5 pushes + `sub rsp, 16` spill.

## 13. What lands at M2 and what deferred

**Lands at M2:**

- `cap_minter.pdx` module.
- `_cap_minter_init` + `_cap_minter_set_active_env` +
  `_cap_minter_get_active_env` + `_cap_minter_derive`.
- `CAP_ENV_OP_DERIVE = 3` constant in `kind_cap_env.pdx`.
- Boot hook in `kernel_main.pdx` after `schema_registry_bringup`.
- Reserved cap_table slot range `[192, 256)` for derived caps.

**Deferred to R125.M3:**

- Dispatch arm in `cap_handler_cap_env` for op 3 DERIVE.
- Caller-context propagation (per-CPU `_cap_minter_active_env`).
- ELF `.caps.decl` loader calling `_cap_minter_derive`.

**Deferred to R125.M5:**

- `run --grant` shell flag.

**Deferred to R125.M6:**

- Capability-typed command arguments.

**Deferred to R128:**

- Lineage tracking (parent-revoke propagating to children).
- Phase-3 slab allocator; cap-minter switches to `slab_alloc`/`slab_
  free`; reserved range retired.

## 14. Audit summary

- Endpoint id 20: adjacent to the kernel-side svc.* band (16/17/18/19).
- Error band 0x0F01..0x0F03: clean (zero collisions, 2026-10-11).
- Bringup band 0xFFFFEBD0..D1: inside the free `cmd_invoke.pdx`-noted
  band `0xFFFFEBC8..0xFFFFEBDF`.
- Label prefix `cmnt_`: zero existing hits.
- Reserved cap_table range `[192, 256)`: zero live producers at
  landing.
- `CAP_ENV_OP_DERIVE = 3`: strictly greater than the existing
  `CAP_ENV_OP_MAX = 2`; adjacent to the reserved op band.

Closes paideia-os#2592.
