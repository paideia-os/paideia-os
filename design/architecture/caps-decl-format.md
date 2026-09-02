# `caps.decl` — Exec-Time Capability Declaration Format

Round: R90-XREPO.013.M1-001 (paideia-os #2130). Companion of the M0-001
kernel substrate (#2129, `src/kernel/core/cap/reconcile.pdx`).

## 1. Purpose

Every user-space image that runs under `sys_execve` declares the maximum
set of capabilities it will hold, in a small text file named `caps.decl`.
At exec-time the kernel reconciles the child's inherited cap-set against
this declaration and drops any inherited cap the decl does not enumerate.
The declaration is the tool's own *authored* upper bound on its
authority; the exec-time narrow enforces least-privilege at the process
boundary rather than as a runtime library convention.

Two things follow immediately:

- A cap the parent did not hold cannot be *added* by a decl (narrowing
  is one-way — never widening).
- A cap the decl marks as **mandatory** and the parent did not hold
  causes the exec to fail with `-EACCES`; the tool refuses to run
  under-privileged rather than doing partial work.

## 2. Location & Delivery

Two shipping modes coexist. Every tool picks exactly one at build
time; both reach the kernel through the same `caps_decl_pa` /
`caps_decl_len` argument pair on `cap_reconcile_at_exec`.

- **Embedded.** The `caps.decl` bytes live in a dedicated `.rodata`
  section of the image (`.rodata.caps_decl` by convention). The image's
  header exports its start and length via the two symbols
  `__caps_decl_start` / `__caps_decl_end`, which `sys_execve` reads
  after ELF relocation and passes to the reconciler. This is the
  default for statically-linked satellite tools — one artifact, no
  file-system dependency for the exec check.

- **Side-car.** The tool ships an unembedded decl at
  `/etc/caps/<toolname>.decl`. `sys_execve` reads this via the kernel
  scratch buffer before invoking the reconciler. This mode is reserved
  for tools whose decl a system administrator legitimately overrides
  in production (e.g. a `pdxcurl` bound to only a narrow TLS-trust
  subset per site policy). Absence of the side-car when this mode is
  selected is treated the same as an empty decl (see §5 fail-closed).

Manifest bookkeeping: whichever mode is chosen, the tool's
`manifest.pdxsig` lists `caps.decl` as a signed input, so tampering
with a shipped decl fails signature verification before exec ever
reaches the reconciler.

## 3. File Format

Line-oriented plain text, UTF-8, LF-terminated (`0x0A`). Trailing NUL
optional; the reconciler treats byte-length as authoritative and does
not require NUL-termination.

Grammar (informal):

```
file      := line*
line      := ( comment | blank | decl-line ) LF
comment   := '#' any-byte*
blank     := whitespace*
decl-line := whitespace* [ '!' ] kind-name whitespace+ rights-mask whitespace*
kind-name := ASCII identifier, uppercase + underscore + digit,
             e.g. KIND_TCP_SOCKET, KIND_PDXFS_FILE
rights-mask := '0x' hex-digit{1,16}   ; up to a u64
```

Ordering is not significant; duplicate `kind-name` lines are rejected
(exec fails with `-EACCES`, audit log names the duplicate). A malformed
line rejects the whole file — no partial parse, no best-effort read.

### 3.1 Prefixes

- `!KIND_FOO 0x00F` — **mandatory**. If the parent's cap-set does not
  include `KIND_FOO` with the requested rights (or a superset), the
  exec fails with `-EACCES` and the audit log names both the tool and
  the missing right.
- ` KIND_FOO 0x00F` — **optional**. The kernel narrows the parent's
  cap-set to at most this line's rights but does not fail if the
  parent held less. If the parent held zero of `KIND_FOO`, the child
  simply has zero of `KIND_FOO`.

### 3.2 Comments and Whitespace

`#` comments run to end of line. Blank lines and lines containing only
whitespace are ignored. Whitespace between the (optional `!`) kind-name
and the rights mask must be at least one byte and may be tabs, spaces,
or any mix.

### 3.3 Example

```
# ls: read files + directory entries + resolve schemas
!KIND_PDXFS_FILE          0x001   # READ_BYTES
!KIND_PDXFS_MOUNT_TABLE   0x002   # QUERY
 KIND_SCHEMA_HANDLE       0x004   # LOOKUP (optional; empty root is fine)
```

`ls` here refuses to run without READ_BYTES on files and QUERY on the
mount table; a schema-registry cap is welcome if the parent has one
but not required.

## 4. Narrowing Semantics

Let `P` = parent's inherited cap-set (each entry keyed by kind, value
= rights bitmap) and `D` = the parsed decl (same shape). The child
receives cap-set `C` computed as:

```
For each entry (kind, decl_rights) in D:
    parent_rights = P.get(kind, 0)
    C[kind] = parent_rights AND decl_rights           # never widens
    if entry is mandatory and C[kind] != decl_rights:
        FAIL with -EACCES (mandatory-narrower-than-decl)

For each entry in P not present in D:
    (dropped — child does not receive this cap)
```

Two invariants fall out:

- **Narrow-only.** `C[k] ⊆ P[k]` for every kind, so the reconciler
  never grants a right the parent did not hold.
- **Deterministic dropped-cap accounting.** Every entry in `P` is
  either narrowed into `C` (present in `D`) or dropped (absent from
  `D`). The audit trail names both classes.

## 5. Failure & Audit

Failure modes and the audit line each writes:

| Condition                                            | rax          | Audit tag                          |
|------------------------------------------------------|--------------|------------------------------------|
| decl absent (embedded mode, symbol pair missing)     | see §5 flip  | `caps decl missing`                |
| decl empty (side-car mode, file zero bytes)          | see §5 flip  | `caps decl empty`                  |
| decl malformed (parse error on any line)             | `-EACCES`    | `caps decl parse err line=<n>`     |
| duplicate kind-name across two decl-lines            | `-EACCES`    | `caps decl duplicate kind=<name>`  |
| mandatory kind absent from parent's cap-set          | `-EACCES`    | `caps decl missing kind=<name>`    |
| mandatory kind present but narrower than the decl    | `-EACCES`    | `caps decl narrowed kind=<name>`   |
| success                                              | `0`          | `caps decl ok kinds=<n> dropped=<m>` |

### 5.1 Absent-decl policy: fail-closed after adoption

The M0-001 substrate ships with an absent-decl arm that returns `0`
(permissive-default). This lets the substrate land before every tool
has authored its decl (the M4-* waves). Once every tool listed in the
R90-XREPO.013 M3/M4 tables ships a decl (tracked by the M5-001 closeout
audit at `design/round-retrospectives/r90-xrepo-013-closed.md`), the
substrate flips this arm to `-EACCES` — an image with no decl becomes
un-exec-able.

The flip is a single-line change in `reconcile.pdx`'s Arm A and is
gated on the closeout audit's completion.

## 6. Wire Format Between Kernel and Reconciler

`cap_reconcile_at_exec(task_ptr, caps_decl_pa, caps_decl_len)`
(`src/kernel/core/cap/reconcile.pdx`).

- `task_ptr`: TCB of the exec'ing child, or 0 for boot-context
  callers (a future boot witness constructs a synthetic decl and
  calls the reconciler directly).
- `caps_decl_pa`: kernel VA of the decl byte buffer. `sys_execve`
  either points this at the embedded `.rodata.caps_decl` section
  after relocation (embedded mode) OR fills a per-exec scratch page
  from the side-car file (side-car mode). Either way the reconciler
  sees a flat kernel-VA byte buffer.
- `caps_decl_len`: length in bytes (excluding the optional trailing
  NUL). `sys_execve` computes this from the ELF section header
  (embedded) or the file `stat` (side-car).

Return values match `Reconcile::CAP_RECONCILE_OK` (0) and
`Reconcile::CAP_RECONCILE_EACCES` (0xFFFFFFFFFFFFFFF3 == -13).

## 7. Non-goals of this format

- **No runtime cap requests.** A tool cannot ask for MORE than its
  decl at runtime; on-demand elevation goes through the separate
  R90-XREPO.011 elevate-broker path with its own policy checks.
- **No inheritance overrides.** The decl narrows exec-time; nothing
  in this file lets a parent bypass the narrow for a specific child.
- **No versioning header.** The grammar is intentionally simple so
  that future extensions (e.g. per-endpoint rights on
  `KIND_IPC_ENDPOINT`) fit as new *lines* rather than as a schema
  version bump. If a future extension is not backward-compatible with
  the line-oriented shape, that shape moves to `caps.decl.v2` and
  `caps.decl` is refused for the new consumer.

## 8. Round dependencies

| Round     | Sub-issue     | Depends on this doc                          |
|-----------|---------------|----------------------------------------------|
| .013.M1-002 | libpdx-cap client helper | parses this format on the tool side |
| .013.M2-001 | shell sys_execve wire-in | pulls decl bytes for the reconciler |
| .013.M3-* / .M4-* | per-tool adoption   | each tool authors its own decl to this shape |
| .013.M5-001 | closeout audit           | asserts every tool's decl parses and reconciles |

## 9. See also

- `src/kernel/core/cap/reconcile.pdx` — the kernel substrate.
- `design/round-retrospectives/r90-xrepo-wave3-plan.md` §5 — the round plan.
- `design/user/fs-tools-caps.md` — decl inventory for the fs-tools wave.
- `design/user/net-tools-caps.md` — decl inventory for the net-tools wave.
