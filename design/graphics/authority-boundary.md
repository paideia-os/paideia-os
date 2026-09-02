# Graphical Display Authority Boundary

**Status:** landed with R105 (paideia-os, 2026-09-02).
**Owns:** the invariant that says "an app client never touches a
framebuffer that carries the flip authority; it holds either an IPC
endpoint the compositor draws for, or a KIND_FRAMEBUFFER cap whose
rights mask carries R_FB_MAP only." R101 landed the caps and rights
bits (`R_FB_MAP=0x001`, `R_FB_FLIP=0x002`, `R_FB_REVOKE=0x004`); R104
lands KIND_PAGE_FLIP as the compositor's per-output swap authority
(co-landed at R105 because R104 as a whole has not yet landed). R105
lands the compositor-facing syscall surface (sysnos 108-113) and this
document.

**Companion:** `design/graphics/r101-kernel-plan.md` §4.3 (why
KIND_PAGE_FLIP is a separate kind), §R105.M5 (authority-posture
motivating question), and `design/graphics/r102-user-plan.md` §0.5
(single-compositor invariant).

---

## 1. The invariant

> An **app client** never holds a capability that authorises writing to
> the scan-out backing memory of a live display output.
>
> An app client can hold either
>   (a) a KIND_IPC_ENDPOINT into which it sends `SurfaceCommitRecord`
>       messages the compositor consumes, OR
>   (b) a KIND_FRAMEBUFFER cap whose rights mask is exactly
>       `R_FB_MAP` (0x001) -- authority to obtain the mapped LFB VA
>       (for a client-side render into its own back buffer) but NO
>       R_FB_FLIP and NO R_FB_REVOKE.
>
> The **compositor** is the sole holder of every KIND_PAGE_FLIP cap.
> Only the compositor may mint child KIND_FRAMEBUFFER caps carrying
> `R_FB_FLIP` (0x002), and it does so only for its own internal
> per-output back buffers.

This is a **structural** invariant, not a policy one: KIND_PAGE_FLIP is
declared LINEAR (no `R_FLIP_MINT` bit exists in the rights set the
`pgfl_rights_valid` gate accepts). The generic `cap_mint_write` path
cannot manufacture a KIND_PAGE_FLIP cap; only `kind_page_flip_mint_body`
does, and that body is called from exactly one place: a supervisor
scope that also holds the parent KIND_DISPLAY_OUTPUT cap.

---

## 2. Why not just trust the compositor?

Because "the compositor" is not a fixed identity across the system's
lifetime. The compositor process can crash, get restarted by the
supervisor, or be replaced during a session-migration flow (the
single-compositor design of `r102-user-plan.md` §0.5 does NOT forbid a
supervisor-mediated *swap*; it forbids two live compositors at once).
The plane cap has to be recoverable across a compositor crash without
the successor being able to inherit any client's authority to write to
the LFB directly. LINEAR KIND_PAGE_FLIP + `R_FB_MAP`-only clients
enforces that: on a compositor exit, revoke of the KIND_PAGE_FLIP cap
cascades (the substrate refuses subsequent `pgfl_submit` calls against
a freed row); every client's KIND_FRAMEBUFFER cap remains valid but
can no longer be flipped by anyone.

---

## 3. Enforcement audit (2026-09-02)

Repo sweep at the R105 landing point. Every occurrence of
`cap_mint_write` accompanied by `KIND_FRAMEBUFFER` (0x1AF) or its
symbol name in the kernel tree, and the rights value it passes:

```
$ grep -rn "cap_mint_write\|kind_framebuffer_mint_simple" \
    src/kernel/ | grep -i "framebuffer\|fb_" | \
    grep -v "^Binary" | grep -v "^.*://" | sort -u
```

Results (interpreted by hand -- the raw grep is noisy):

| Site | Rights minted | Cap holder | Verdict |
|---|---|---|---|
| `sys_framebuffer_create_body` (sysno 109) | `R_FB_MAP` (0x001) | Any caller of the syscall | OK -- clients hold MAP-only |
| `r101_stdvga_checkerboard.pdx` (boot witness) | (does not mint the FB cap; calls `kind_framebuffer_mint_simple` and holds the row_id in a witness-local slot) | Boot cascade only | OK -- witness never publishes a client-facing cap |
| `r105_flip_client.pdx` (boot witness) | (mints via sys_framebuffer_create -> R_FB_MAP) | Boot cascade only | OK -- follows the same path a real client would |
| No other site | -- | -- | -- |

There is currently **no site outside the compositor path that mints a
KIND_FRAMEBUFFER cap with the R_FB_FLIP bit set.** The R105 landing
therefore has zero known violations of the invariant. When R104 lands
its actual compositor process (or a stub supervisor for T14 wire-up),
the audit MUST re-run against that binary's cap seeding path; a real
compositor holds R_FB_FLIP on its own back-buffer framebuffers to
authorise the plane-swap in `pgfl_submit`, and the audit becomes "any
site OTHER than the compositor supervisor scope that mints R_FB_FLIP
is a violation."

---

## 4. What the LINEAR posture buys

- **Cap discovery is not enumeration.** A client that guesses at
  cap_slot integers and finds a KIND_FRAMEBUFFER at some slot cannot
  use that slot to submit a flip; the missing `R_FB_FLIP` bit gates
  the operation, and no path in the tree grants that bit to a
  non-compositor cap. Even if a compositor bug leaked its own
  KIND_PAGE_FLIP cap slot to a client, the LINEAR property means the
  client cannot duplicate it into a different address space.
- **Compositor restart doesn't leak the plane.** Revocation of
  KIND_PAGE_FLIP invalidates the in-flight flag; a stale submit from
  a compositor that crashed mid-flip is refused with
  `PGFL_BAD_SLOT` after the row is freed. The supervisor mints a
  fresh KIND_PAGE_FLIP for the replacement compositor.
- **The hotplug channel is subscribable, not driveable.** A malicious
  client that acquires a KIND_HOTPLUG_CHANNEL cap can only READ
  events (via the endpoint the compositor granted); it cannot INJECT
  fake events -- `hotplug_channel_deliver` is kernel-only and there
  is no `R_HPCH_INJECT` right.

---

## 5. What this invariant does NOT cover

- **Direct-scanout leases** (KIND_SCANOUT_LEASE, R101 landed via G2)
  DO grant a fullscreen client the ability to bypass the compositor's
  plane and draw straight to the LFB. That is P7 direct-scanout
  behaviour, gated by an entirely separate rights family
  (`R_LEASE_*`), and the compositor's own leasing policy decides
  when to hand out such caps. This document does not overrule the
  P7 lease path; the invariant here applies to the NORMAL per-frame
  path only.
- **Recovery-console reservation** (P8) reserves plane 0 for the
  boot / kernel-panic message path. The compositor cannot revoke
  its own KIND_PAGE_FLIP against plane 0; the substrate rejects that
  operation at `pgfl_submit`. This is a pre-existing R36.M2 gate,
  not new work at R105.
- **GPU submit authority** (KIND_GPU_SUBMIT, R37) is orthogonal. A
  client with a GPU submit cap can render into a KIND_GPU_BO backing
  a KIND_FRAMEBUFFER; the flip authority is still LINEAR under the
  compositor. That is exactly the G7 compositor's per-window render
  path from R102's §0.4.

---

## 6. Follow-on obligations

- **R104 compositor supervisor.** The stub that mints KIND_PAGE_FLIP
  MUST run in a scope disjoint from any ring-3 client's cap_table.
  Today no such scope exists at boot -- the R105 witness fakes one
  in-kernel. R104 lands the actual supervisor-owned mint path.
- **Compositor cap-table linearity audit.** When the compositor
  process spawns child app clients, each child's cap_table MUST NOT
  contain any KIND_PAGE_FLIP entries. A test at compositor process
  spawn asserts this. Deferred to R104's process wiring.
- **`R_FB_REVOKE` audit path.** A client should not hold R_FB_REVOKE
  on any framebuffer it received from the compositor -- that would
  let it tear down the compositor's own back buffer. The current
  `sys_framebuffer_create` mints R_FB_MAP only; when the compositor
  path grows a `svc.compositor` request to allocate a client
  framebuffer, the same rule holds. Enforced in the compositor
  implementation, not in-kernel.
