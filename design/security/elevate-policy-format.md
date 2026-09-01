# /system/policy file format (v1)

Tracking: paideia-os #2119 (R90-XREPO.011.M1-004).

Consumers: the elevate broker daemon (`svc.elevate-broker`, R48b
substrate, #2122 dispatch body) — the sole consumer today. Any
future in-kernel policy consultation MUST go through the broker,
never re-parse this file directly.

## 1. Purpose

`/system/policy` is the on-disk table the elevate broker consults to
decide whether a given `elevate_client_request` should be granted or
refused. The v1 file is a **line-based ASCII text** table — no PdxRecord
framing, no length prefixes, no bignums. A simple state machine on the
broker side reads it into an in-memory rule list; the k parsing arms
(comment, blank, rule) are the entire grammar.

The scope of v1 is **path-prefix + role-class → decision**. That is
enough to encode the initial "init can touch `/system/`, everyone else
can touch their own turf" posture the elevate flow needs, and no more.
A richer schema (per-uid quotas, time-of-day gates, per-op verbs) is a
v2 concern.

## 2. Grammar

```
file       := line ( '\n' line )* [ '\n' ]
line       := blank | comment | rule
blank      := WS*
comment    := WS* '#' <any char except '\n'>*
rule       := WS* path-prefix WS+ role-class WS+ action WS*
WS         := ' ' | '\t'
path-prefix := '/' <printable char>*                    -- absolute path
role-class  := 'INIT' | 'ADMIN' | 'OWNER' | '*'
action      := 'ALLOW' | 'DENY' | 'DENY_UNLESS_ROLE'
```

- Whitespace: one or more space or tab characters between fields;
  leading/trailing whitespace on a line is stripped before parsing.
- Line terminator: `\n` (0x0A). `\r` is treated as trailing whitespace
  and stripped.
- Encoding: 7-bit ASCII only. A byte >= 0x80 anywhere in the file is a
  parse error and the whole file is rejected (the broker refuses to
  fall back to a partial rule set).
- Comment character `#` may appear only as the first non-whitespace
  character of a line. There is no in-line trailing-comment syntax in
  v1.
- Blank lines and comment lines contribute no rules.
- No line-continuation. Each rule fits on one physical line.

### 2.1 Path-prefix semantics

- Must start with `/`.
- Compared against the caller-supplied absolute path via **byte-level
  longest-common-prefix**: rule `/system/` matches every request whose
  target path starts with the 8-byte string `/system/`.
- A rule whose prefix is exactly `/` matches everything and is the
  legitimate way to express a catch-all default.
- No glob syntax in v1. `/` and printable non-`WS` bytes only.

### 2.2 Role-class semantics

The role-class is the caller's own attribute, resolved by the broker
from the calling task's identity BEFORE this table is consulted:

| role-class | meaning |
|------------|---------|
| `INIT`     | caller pid == 1 (the init process) |
| `ADMIN`    | caller belongs to the admin group (post-users milestone; today no task matches) |
| `OWNER`    | caller uid matches the file's own uid attribute (post-uid milestone; today no task matches except INIT) |
| `*`        | matches any caller (wildcard) |

Rules whose role-class no task can match yet (ADMIN, OWNER) are
harmless — they simply never fire. This lets the seeded default
document the intended posture ahead of the milestones that populate
those role classes.

### 2.3 Action semantics

| action              | broker return |
|---------------------|---------------|
| `ALLOW`             | `ELVC_OK` (elevation granted) |
| `DENY`              | `ELVC_ERR_DENY` (elevation refused) |
| `DENY_UNLESS_ROLE`  | reserved for v2 — a marker that says "the wildcard rule below is the DENY fallback; this line is a comment on WHO the ALLOW arm expects". v1 broker treats `DENY_UNLESS_ROLE` as a no-op rule (parses successfully, contributes no decision) so the seeded default remains forward-compatible with a v2 broker that consults it. |

## 3. Evaluation order

Top-to-bottom, first match wins. A request that reaches the end of the
rule list without a match falls back to **DENY** (fail-closed).

The v1 default posture (§5) exhaustively covers the four seeded
top-level prefixes (`/system/`, `/home/`, `/tmp/`, `/var/`), so the
fallback fires only for paths outside those trees (e.g. `/etc/…` or
`/mnt/…` under a future mount). Those correctly default-deny.

## 4. File placement

Absolute path: `/system/policy`.

- Owner: kernel (seeded at boot; see §6).
- Mode at v1: rw for the kernel writer, r for anyone with `/system`
  read access — because there is no per-file ACL yet, this is a
  posture-only statement today.
- Backed by tmpfs at v1. When PDXFS-block lands as the root FS (R51/R52),
  the seeder still runs the same `tmpfs_write`-equivalent write on the
  live mount point; migration is transparent to the file's shape.

## 5. Seeded default (v1)

Written verbatim by the boot-time seeder (§6). Byte-for-byte:

```
# PaideiaOS elevate policy v1
# path-prefix  role-class  action
/system/  INIT  ALLOW
/system/  *     DENY
/home/    *     ALLOW
/tmp/     *     ALLOW
/var/     *     ALLOW
```

Wire size: **173 bytes** (7 lines, each terminated by a single `\n`).
No trailing NUL, no CR. Fits in one 4 KiB tmpfs page — the seeder issues
one `tmpfs_write` call.

Encoded intent:

- `/system/` is the kernel's own turf. Only pid==1 (init) may write
  there today. Every other requester is refused.
- `/home/`, `/tmp/`, `/var/` are the user-writable trees. Any caller
  is granted.
- Everything else default-denies via the fall-through rule at §3.

## 6. Boot-time seeding

Seeded by `src/kernel/boot/witness/rootfs_seed_policy.pdx` (module
`RootfsSeedPolicy`), called from `boot_continue_after_ring3` in
`kernel_main.pdx` immediately AFTER `witness_rootfs_dir_seeds` (which
already creates `/system` as a directory in the tmpfs tree via
`vnode_cache_or_alloc`, so this seeder can look `/system` up rather than
re-create it — same discipline `witness_rootfs_dir_seeds` itself follows
for the pre-existing `/system` inode from the audit-bridge witness, see
`rootfs_dir_seeds.pdx` Stage 5).

Four stages, each stamping its own number into `_policy_seed_stage`
before its own call so the FAIL fingerprint's `line=<N>` KV names the
tripping stage (idiom borrowed from `pdxb_ahci_probe.pdx`'s
`_pdxbap_stage` / `rootfs_dir_seeds.pdx`'s `_rfs_stage`):

1. `mount_root_vnode` → `r15 = root_vn_idx`; `tmpfs_lookup(1, "system")`
   → `r13 = system_inode_idx`; `vnode_cache_or_alloc(root_vn_idx,
   system_inode_idx, &_tmpfs_vops)` → `r14 = system_vn_idx` (idempotent
   with `witness_rootfs_dir_seeds` Stage 5's own bind — dedup returns
   the same slot).
2. `tmpfs_create(system_inode_idx, "policy", 6, VNODE_TYPE_REG=1)` →
   `r13 = policy_inode_idx` (system_inode_idx dead after this call —
   the reused-register discipline matches `bin_seeds.pdx`'s tmpfs seeds).
3. `vnode_cache_or_alloc(system_vn_idx, policy_inode_idx, &_tmpfs_vops)`
   → new vnode-pool slot (return value discarded — matches
   `bin_child_hello_seed`'s Step 5 comment).
4. `tmpfs_write(policy_inode_idx, &_policy_default_bytes, 173, 0)` —
   single-page write (the payload's 173 bytes are well under the
   `tmpfs_write` per-call cap of 4096 per `write.pdx` §4.5).

## 7. Fingerprint

Success (single line, emitted via `klog_s1_d1` with `k_bytes`):

```
policy seed ok [legacy: POLICY SEED OK] bytes=173
```

`bytes=<N>` is the actual `tmpfs_write` return (well-formed writes
short-circuit to the whole buffer, so `N` == 173 under normal boot).
The `[legacy: POLICY SEED OK]` bracketed segment is the coverage-gate
tag: `tools/verify-fingerprint-coverage.sh`'s `OK_TOK` extractor sees
the uppercase `OK` there and treats the whole line as an asserted
marker — same dual-form discipline `rs_fp_ok`, `tag_sys_taskinfo_ok`
and the R100-PREP tags follow.

Failure (single line, emitted via `klog_s1_d1` with `k_line`):

```
policy seed fail [legacy: POLICY SEED FAIL] line=<N>
```

where `<N>` ∈ {1, 2, 3, 4} names the stage that tripped per §6.

## 8. Idempotence and re-boot behaviour

- Under the current tmpfs root, every boot is a cold start; the seeder
  runs its four stages and writes the file freshly each time. Stage 2's
  `tmpfs_create` sees no pre-existing `/system/policy` and succeeds.
- Under a persistent root FS (post-R51/R52), Stage 2's `tmpfs_create`
  would collide on the pre-existing inode and return 0 — the same
  posture `rootfs_dir_seeds.pdx` fixed for `/system` at #1999. The v2
  seeder for a persistent root MUST first `tmpfs_lookup(system_inode,
  "policy")` and only fall through to create-then-write when the lookup
  misses, matching that precedent. v1 does NOT include that guard
  because it would be dead code under the tmpfs root and untestable
  until the persistent-root milestone lands.

## 9. Non-goals for v1

- **No parser here.** `/system/policy`'s parser is the broker's business
  (see #2122). This spec defines what the file looks like on disk; the
  broker consults it. No other code path in the kernel touches this
  file.
- **No versioning header.** The spec is v1; a v2 file would introduce a
  first-line magic (e.g. `#!pdx-policy v2`) that the broker recognises
  and dispatches into a v2 parser. v1 files carry no magic — the broker
  MUST treat a header-less file as v1 by construction.
- **No hot-reload.** The broker reads `/system/policy` once at start-up.
  Editing the file at runtime has no effect until the broker restarts.
  A future hot-reload (SIGHUP-style, or a watch-based inotify equivalent
  when that exists) is a broker-side milestone, orthogonal to the file
  format.
- **No signature.** The file is trusted by placement — anyone who can
  write `/system/policy` is trusted by construction under the seeded
  default (only INIT can). A signed / attested policy is a v2 concern
  aligned with the pkg attestation flow.

## 10. Cross-references

- `src/kernel/boot/witness/rootfs_seed_policy.pdx` — the seeder.
- `src/kernel/boot/witness/rootfs_dir_seeds.pdx` — creates the
  `/system` directory this seeder writes into.
- `src/kernel/boot/witness/bin_seeds.pdx` — the tmpfs-seed pattern
  this module mirrors (mount_root_vnode → tmpfs_lookup →
  vnode_cache_or_alloc → tmpfs_create → vnode_cache_or_alloc →
  tmpfs_write).
- `design/services/svc-elevate-broker-registration.md` — the broker
  daemon that consumes this file.
- `design/round-retrospectives/r90-xrepo-wave3-plan.md` §3 —
  R90-XREPO.011 wave, the elevate-broker-completion track this issue
  belongs to.
