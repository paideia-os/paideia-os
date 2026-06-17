# PaideiaOS — Capability System: Linearity and Tags

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Architectural specification of the PaideiaOS capability system mandated by Q7 of `01-foundational-decisions.md`. Covers the handle / descriptor split, kind hierarchy, rights model, LAM tag-bit layout, software-LAM fallback, derivation rules, revocation, sealing, in-memory storage of capability handles, and interactions with the assembler, IPC primitive, scheduler, and audit log.

**Hard inputs (do not relitigate):**
- `design/00-feature-inventory.md` — C4 (capability system) is this document's subject.
- `design/01-foundational-decisions.md` — Q7 mandates both static (E14) and runtime (LAM) enforcement; Q11, Q12, Q15 are directly load-bearing.
- `design/02-development-environment.md` — feature-masked CI lanes test the software-LAM fallback path (§10.5).
- `design/toolchain/custom-assembler.md` — substructural lattice (Q-A2), algebraic effects (Q-A3), elaborator reflection (Q-A4), calling convention with R12/R13 capability band (§8), `unsafe` blocks (Q-A8).
- `design/ipc/wait-free-dataflow.md` — IPC primitive transports capabilities inline in 64-byte slots; LAM tags verified at dequeue.

---

## 0. Decisions summary

### 0.1 Inherited (already binding)

| Source | Constraint |
|---|---|
| Q7 | Both static (build-time linearity check, E14) AND runtime (LAM-backed tag bits) enforcement; the two layers are independent. |
| Q12 | 48-bit (4-level) paging is default → 15 LAM bits available; 57-bit (5-level) opt-in → only 6 LAM bits available. The capability system must work in both regimes. |
| Q-A2 | The substructural lattice has four classes — ordered, linear, affine, unrestricted. Capabilities are at least linear by default. |
| Q-A3 | Algebraic effects with handlers; effect environment in R15. |
| Q-A6 | R12/R13 carry LAM-tagged capability handles linearly. |
| Q-A7 | ML-style modules with functors; capabilities have kind-specific signatures. |
| IPC primitive | Channels are typed by `Channel(Schema)` functor application; capabilities embedded in 64-byte slots; slot LAM tag verified on dequeue. |

### 0.2 New decisions in this document

| # | Question | Decision |
|---|---|---|
| CAP-Q1 | Capability handle model | Hybrid: LAM-tagged pointer to a kernel-managed capability descriptor. The pointer is unforgeable because descriptors live in kernel-only memory; the LAM tag bits carry fast-check data; the descriptor is the source of truth. |
| CAP-Q2 | Descriptor layout | Kind-tagged variant: 16-byte common header (kind tag, derivation parent pointer, revocation epoch, refcount + flags) + kind-specific tail. Slab-allocated per kind. |
| CAP-Q3 | Kind hierarchy | Two-tier: kernel defines a closed enum of base kinds (memory, ipc-endpoint, port, irq, process, sched-ctx, slot-cap, cycle-cap, splitter-cap, merger-cap, handoff-cap, audit, seal-cap, unseal-cap). Userspace defines derived kinds purely in the type system (functor-typed); the kernel sees only the base kind. |
| CAP-Q4 | Rights encoding | Hybrid: a 64-bit rights bitmask in the kernel descriptor (kind-specific layout) + an algebraic effect set in the paideia-as type system; a canonical mapping function (per kind) translates between them at mint time. |
| CAP-Q5 | LAM tag-bit layout (4-level paging) | 8 bits revocation epoch + 2 bits linearity class + 4 bits base-kind hint + 1 bit sealed/opaque flag = 15 bits. |
| CAP-Q6 | Software-LAM fallback | paideia-as emits inline masking (`and` or `bextr`) before every capability-register dereference on no-LAM hardware; tag-check macros are assembler builtins. Per-target binary build. |
| CAP-Q7 | Derivation rules | Tree-tracked subset derivation: minting creates a child with rights ⊆ parent (parent retained); descriptors record parent pointer forming a tree. *Retype* transforms a memory-region capability into another kind, consuming the memory. |
| CAP-Q8 | Revocation | Hybrid: `revoke(cap)` bumps the descriptor's revocation epoch (O(1)); every outstanding handle with an older epoch fails the LAM check on next dereference. `revoke_subtree(cap)` walks the derivation tree for selective revocation. Epoch exhaustion (after 256 revokes on the same descriptor) triggers a descriptor reallocation with tree-walk migration. |
| CAP-Q9 | Sealing | The CAP-Q5 sealed bit is the runtime marker. Applying the seal (minting a sealed child) requires holding a `seal_cap` granted by the supervisor. Inspecting a sealed cap requires the paired `unseal_cap`. |
| CAP-Q10 | Storage of handles in memory | Handles (LAM-tagged 64-bit pointers) live in normal user memory; copying is *not* runtime-prevented. The substructural type system catches duplication at compile time; LAM tags prevent forgery and detect stale (revoked) handles; the audit of `unsafe` blocks is the last line of defense. |

### 0.3 The two meta-positions to acknowledge

1. **Layered enforcement, not redundant enforcement.** The static type system, the LAM tag check, and the descriptor table are *complementary* — each catches a different class of bug:
   - **Substructural type system (Q-A2 + E14):** catches duplication, double-consumption, and unused-linear errors at compile time.
   - **LAM tags:** catch stale handles (after revocation), wrong-kind dereferences (fast dispatch), and broken sealing.
   - **Descriptor table:** is the source of truth for rights, derivation, and identity.

   No single layer is sufficient; each layer adds a class of caught bugs. Q7 mandated "both static and runtime"; this is the realization.

2. **Forgery is prevented; duplication is not (at runtime).** A capability handle is a LAM-tagged pointer; the kernel sets the tag at mint time and verifies on dereference. A user process *cannot* fabricate a valid tag. But user code can *copy* a valid handle freely — at runtime, two locations holding the same handle look identical. The substructural type system prevents this in well-typed code; `unsafe` blocks whose declarations lie can bypass it. This is the price of the "handles in normal memory" choice (CAP-Q10) and is documented as a known trade-off. Pillars 6 (security) and 10 (FP discipline) together rely on the discipline of `unsafe` audit (§9 of the assembler doc).

---

## 1. Architectural overview

```
   user code (paideia-as)                kernel
   ────────────────────                  ──────

   R12 = ┌─────────────────────────┐
         │ ←  LAM tag (15 bits) →  │  pointer (49 bits)
         │ epoch│lin│kind│seal│ │  │            │
         └──────┴───┴────┴────┴─┴──┘            │
                                                ▼
                                    ┌────────────────────────────────┐
                                    │ kernel-only descriptor memory  │
                                    │   ┌──────────────────────────┐ │
                                    │   │ common header (16 B)     │ │
                                    │   │  kind                    │ │
                                    │   │  parent ptr              │ │
                                    │   │  current revocation epoch│ │
                                    │   │  refcount + flags        │ │
                                    │   ├──────────────────────────┤ │
                                    │   │ kind-specific tail        │ │
                                    │   │ (memory: base/len/attr)  │ │
                                    │   │ (ipc: channel id /…)     │ │
                                    │   │ (port: number / mask)    │ │
                                    │   │ etc.                     │ │
                                    │   └──────────────────────────┘ │
                                    └────────────────────────────────┘

   Dereference: load LAM-tagged pointer from R12 →
                hw-LAM strips tag for memory access (or sw masking on no-LAM)
                kernel-side check: tag.epoch == descriptor.current_epoch?
                                   tag.kind == descriptor.kind?
                                   tag.sealed implies caller has unseal_cap?
                check passes → operation on descriptor
                check fails → trap into kernel; audit; handler invoked
```

The flow: a capability operation in userspace dispatches via the IPC or kernel-call effect (per Q-A3); the kernel sees a `R12 = handle` register; verifies the LAM tag against the descriptor's current state; performs the operation; returns.

---

## 2. The handle and the descriptor (CAP-Q1, CAP-Q2)

### 2.1 The handle

A capability handle is a 64-bit value with the layout:

```
 Bit  63           48 47                                                0
      ┌──────────────┬──────────────────────────────────────────────────┐
      │ canonical    │ pointer into descriptor table (49 bits effective)│
      │ extension /  │  — descriptor-table base is kernel-fixed; the    │
      │ LAM tag      │  pointer\'s low bits index into the table         │
      │ (15 bits)    │                                                    │
      └──────────────┴──────────────────────────────────────────────────┘
```

The 49-bit pointer addresses a descriptor in the kernel-only descriptor table. The 15 tag bits carry hot-path metadata (CAP-Q5; see §6).

### 2.2 The descriptor

Every descriptor begins with a 16-byte common header:

```
 Offset  0                  4                  8                  12        16
         ┌──────────────────┬──────────────────┬──────────────────┬─────────┐
         │ kind (4 B)       │ flags (4 B)      │ parent_ptr (8 B) │         │
         └──────────────────┴──────────────────┴──────────────────┴─────────┘
         │ revoc_epoch (4 B)│ refcount (4 B)   │ derivation_meta (8 B)     │
         ├──────────────────┴──────────────────┴────────────────────────────┤
         │ kind-specific tail (variable)                                    │
         │                                                                   │
         │   memory:     base (8) + length (8) + attrs (4) + numa (4)       │
         │   ipc-endpt:  channel_id (8) + session_state (8) + slot_acct (4) │
         │   port:       port_num (2) + access_mask (4) + reserved (10)     │
         │   irq:        vector (1) + cpu_mask (8) + reserved (7)           │
         │   process:    tcb_ptr (8) + cspace_root (8)                      │
         │   sched-ctx:  budget (8) + period (8) + priority (4)             │
         │   slot-cap:   channel_ptr (8) + slot_idx (2)                     │
         │   …                                                              │
         └────────────────────────────────────────────────────────────────────┘
```

`kind` is a 32-bit enum identifying which tail layout applies (only the low 4 bits are used today; the rest are reserved for the closed enum's growth). `parent_ptr` is the LAM-tagged handle of the parent capability in the derivation tree (null for root capabilities). `revoc_epoch` is the descriptor's *current* epoch; any outstanding handle with a tag epoch ≠ this value is stale (per CAP-Q8). `refcount` tracks how many handles claim this descriptor (Q-A2 prohibits duplication in well-typed code, but the refcount is a kernel-side backstop).

### 2.3 Why this layout

- **Kernel-only descriptor storage** is the foundation of unforgeability: user code cannot write into descriptor memory, so the kernel's tag-set is the only source of authentic tags.
- **49-bit pointer + 15-bit tag** fits exactly the 48-bit canonical address space plus LAM tags. The 49th pointer bit is the canonical-sign bit, set to indicate the kernel half of the address space.
- **Kind-tagged variants** match the FP discipline: each kind is a constructor in an algebraic data type; the kernel's dispatch on `kind` is a switch the elaborator can verify exhaustive.
- **16-byte common header on a 64-byte cache line** leaves 48 bytes for the kind-specific tail — sufficient for every kind currently planned without overflowing a cache line. Slab allocation per kind avoids fragmentation.

### 2.4 Descriptor allocation

The kernel maintains per-kind slab allocators; each kind's slab is sized for its descriptor variant. Allocation is wait-free for the common case (per-CPU free lists) and falls back to a global free list on starvation. Descriptors are never freed eagerly — they are *reclaimed* by revocation + refcount-zero (§7).

---

## 3. Kind hierarchy (CAP-Q3)

### 3.1 Base kinds (closed kernel enum)

| # | Kind | Tail content | Use |
|---|---|---|---|
| 0 | `memory` | base, length, attributes (RWX, cacheability), NUMA hint | Memory regions (the substrate of retype). |
| 1 | `ipc-endpoint` | channel id, session-type FSM state, slot-cap accounting | IPC primitive endpoint (Send or Recv side). |
| 2 | `port` | I/O port number, access mask | Port-mapped I/O (per driver). |
| 3 | `irq` | vector number, CPU affinity mask | Interrupt routing. |
| 4 | `process` | TCB pointer, CSpace root (only used at kernel-internal boundary) | Process identity. |
| 5 | `sched-ctx` | budget, period, priority | Scheduling-context donation (per seL4-MCS). |
| 6 | `slot-cap` | parent channel pointer, slot index | The slot-cap economy (per IPC §8). |
| 7 | `cycle-cap` | (empty tail; presence is the right) | Permission to construct cyclic dataflow edges. |
| 8 | `merger-cap` | (empty tail) | Permission to instantiate a merger node. |
| 9 | `splitter-cap` | (empty tail) | Permission to instantiate a splitter node. |
| 10 | `handoff-cap` | designated supervisor pointer, window-ms | Permission for live channel handoff (Q14). |
| 11 | `audit` | audit-log channel pointer | Permission to write to the audit log. |
| 12 | `seal-cap` | paired unseal-cap reference | Permission to seal capabilities. |
| 13 | `unseal-cap` | paired seal-cap reference | Permission to unseal capabilities. |
| 14 | `reserved-1` | reserved for one of: D14 distributed extension, future expansion | — |
| 15 | `reserved-2` | reserved for one of: confidential-computing, attestation, future expansion | — |

16 base kinds, encoded in 4 LAM tag bits (CAP-Q5). The reservation of two slots is deliberate: the LAM kind-hint must remain 4 bits, so future kinds added to the closed enum will displace one of the reserved slots and may require a major-version event.

### 3.2 Derived kinds in the type system

A derived kind is a refinement of a base kind expressed purely in the paideia-as type system. Example:

```paideia-as
signature NvmeQueueCapSig = derived IpcEndpointCap with
  schema : NvmeQueueSchema
  rights : !{nvme_submit, nvme_complete}

module NvmeQueueCap : NvmeQueueCapSig = derive(IpcEndpointCap, NvmeQueueSchema)
```

At runtime, the descriptor's kind is `ipc-endpoint` (the base kind); the type system distinguishes an NvmeQueueCap from a generic IpcEndpointCap at compile time. A misuse — handing an `NvmeQueueCap` where a `LogChannelCap` is expected — is caught at the function-call type check.

### 3.3 Why two-tier

- The kernel's descriptor variants stay a closed, auditable enum.
- Userspace gets unlimited expressivity in type signatures without kernel growth.
- A misuse that the type system catches (e.g., passing a wrong-derived-kind cap) is a compile-time error; a misuse that the type system *missed* (via an `unsafe` block whose declarations lied) is *still* checked against the base kind at runtime.
- The functor-module system (Q-A7) is the natural home for derived-kind definitions.

### 3.4 Limitation

Derived kinds carry no runtime discriminator. If an `unsafe` block constructs a handle claiming to be of derived kind X but the descriptor is actually a base IPC endpoint with no X-specific guarantee, the kernel cannot tell. This is the static-only side of Q7's "both static and runtime" mandate: derived-kind safety is static; base-kind safety is both.

---

## 4. Rights model (CAP-Q4)

### 4.1 Two-representation rights

- **Kernel representation:** a 64-bit rights bitmask in the descriptor. The layout is kind-specific (each kind's tail documents which bits mean what).
- **Type-system representation:** an algebraic effect set carried on the capability's type signature.
- **Canonical mapping:** each kind has a `rights_to_effects` and `effects_to_rights` pair of functions in the kernel; they are inverses up to legal-effect-set normalization.

### 4.2 Why two representations

- The kernel's runtime check is one AND instruction against the bitmask — fastest possible.
- The type system's representation composes elegantly with the rest of the effect system (Q-A3): a `port_read` effect required at a call site forces the caller to hold a capability whose rights include the `port_read` bit; the type system catches this; the kernel verifies it.
- Effect handlers can interpret rights: a test handler can claim a capability has rights it does not in fact have (for mocking).

### 4.3 Rights bitmask layout per base kind (illustrative)

`memory` kind rights bitmask (low 32 bits shown; high 32 reserved):

| Bit | Effect | Meaning |
|---|---|---|
| 0 | `mem_read` | Load from the region. |
| 1 | `mem_write` | Store to the region. |
| 2 | `mem_exec` | Execute from the region. |
| 3 | `mem_map` | Map into an address space. |
| 4 | `mem_share` | Share into another process's AS. |
| 5 | `mem_retype` | Consume the region into another kind. |
| 6 | `mem_revoke` | Revoke this region's capability. |
| 7 | `mem_audit` | The region's accesses are audited. |
| 8 | `mem_lam_priv` | The region's tag bits are kernel-privileged (cannot be set by user). |
| … | reserved | — |

Each kind's bitmask is enumerated in `design/capabilities/rights-catalog.md` (to write).

### 4.4 Effect-to-bitmask mapping

For the `memory` kind:

```
rights_to_effects(bits) =
  let e = ∅
  if bits & MEM_READ:   e ∪= !{mem_read}
  if bits & MEM_WRITE:  e ∪= !{mem_write}
  if bits & MEM_EXEC:   e ∪= !{mem_exec}
  …
  return e
```

The mapping is total in both directions for each kind. The paideia-as elaborator (Q-A4) uses the static effect set on the capability's type signature to determine which bits are required at each use site; the kernel checks the bits at the operation.

---

## 5. LAM tag-bit layout (CAP-Q5)

### 5.1 4-level paging layout (default per Q12)

| Bit range | Field | Width | Purpose |
|---|---|---|---|
| 47–40 | `revocation_epoch` | 8 | Monotonic counter; revoke bumps the descriptor's epoch; handle stale iff `handle.epoch ≠ descriptor.epoch` (compared modulo 256). |
| 39–38 | `linearity_class` | 2 | One of {ordered=0, linear=1, affine=2, unrestricted=3}. The runtime-side reflection of Q-A2; checked at consumption sites. |
| 37–34 | `kind_hint` | 4 | Mirror of the descriptor's base kind, for fast kernel-side dispatch without a descriptor cache miss. |
| 33 | `sealed` | 1 | If set, the capability is sealed (CAP-Q9); inspection requires `unseal_cap`. |
| 48 | canonical-sign | 1 | Bit 48 is the canonical-sign bit per Intel SDM; set for kernel-side pointers. |

### 5.2 5-level paging layout (opt-in per Q12)

With 5-level paging, only 6 LAM bits are available (bits 62–57). The layout is reduced:

| Bit range | Field | Width | Purpose |
|---|---|---|---|
| 62–59 | `revocation_epoch` | 4 | Reduced to 16 epochs — wraparound is more frequent. |
| 58 | `linearity_consumption` | 1 | Compressed: 1 = linear/ordered (consume-once), 0 = affine/unrestricted (multiple use). |
| 57 | `sealed` | 1 | Sealed flag. |
| — | kind_hint | 0 | *Not encoded in tag*; every kind dispatch is a descriptor cache miss. |

The 5-level layout is acknowledged as *materially worse* for hot-path performance — every kind dispatch is now a descriptor touch instead of a tag-bit branch. This is the cost of 5-level paging and informs the Q12 default-to-48-bit decision retroactively: 5-level is opt-in for processes that genuinely need >128 TiB virtual.

### 5.3 Epoch comparison and wraparound

The descriptor stores the current 32-bit epoch (in the common header); the tag stores the low 8 bits. Comparison is `handle.epoch == descriptor.epoch & 0xFF`. When the descriptor's epoch crosses a power-of-256 boundary (after every 256 revocations), the next revocation triggers a *descriptor reallocation*: a fresh descriptor is allocated at a different address with epoch 0; all *currently valid* outstanding handles are tree-walked and updated to point to the new descriptor. The old descriptor becomes a *poison* descriptor (kind = 0xFF, epoch fixed) so any stale handle that still references it fails LAM check.

Reallocation is bounded by the size of the descendant tree (selective revocation can keep this small) and is a rare event in practice (256 revokes per descriptor before triggering it).

---

## 6. Software-LAM fallback (CAP-Q6)

### 6.1 The fallback path

On hardware without LAM (everything below Sapphire Rapids on server and below Meteor Lake on client per `02-development-environment.md` §1.3), the paideia-as compiler emits inline masking before every capability-register dereference.

#### Hardware-LAM target

```
; R12 carries a LAM-tagged cap handle
; access the descriptor
mov rax, [r12]            ; LAM hardware strips tag transparently
```

#### Software-LAM target

```
; R12 carries a tag-bearing handle
mov rdx, r12              ; copy for tag extraction
and rdx, TAG_MASK          ; rdx now holds tag bits
shr rdx, TAG_SHIFT
and r12, POINTER_MASK     ; r12 now holds clean pointer
mov rax, [r12]            ; access descriptor
; rdx is the tag for subsequent verification
```

The extra cost is 3 instructions per dereference (~1 ns on modern hardware) and one register save. The paideia-as assembler emits these automatically when the build target lacks LAM (CPUID gated at build time, not runtime — Q-A6 calling convention is fixed per binary).

### 6.2 Tag verification

Whether hardware or software LAM:

```
; verify epoch matches
mov ecx, [r12 + OFFSETOF_DESCRIPTOR_EPOCH]
cmp dl, cl                ; compare low 8 bits of tag.epoch to desc.epoch
jne cap_stale
; verify kind matches
mov edi, [r12 + OFFSETOF_DESCRIPTOR_KIND]
mov esi, edx
shr esi, EPOCH_BITS
and esi, KIND_MASK
cmp esi, edi
jne cap_kind_mismatch
; … etc.
```

The verification macros are paideia-as builtins (`%verify_epoch`, `%verify_kind`, `%verify_linear`, `%verify_unsealed_or_unseal_cap_held`); the assembler emits them per operation per the calling-convention contract.

### 6.3 Per-target binary

Because the LAM-aware and LAM-unaware code paths differ at the instruction level, *one PaideiaOS binary cannot run on both*. The build matrix produces:

- `paideia-kernel-lam.elf` for LAM-capable hardware.
- `paideia-kernel-swlam.elf` for older hardware.

The dispatch is at install time, not boot time; CPUID at boot verifies the right binary is loaded and panics on mismatch. The CI matrix per `02-development-environment.md` §10.5 builds both and tests both.

### 6.4 Cost summary

On hardware-LAM: zero overhead per capability dereference (LAM masking is part of address translation, hidden in the load latency).

On software-LAM: ~3 instructions per dereference + ~6 instructions per kind/epoch/linearity verification = ~9 extra instructions per capability operation. At ~1 ns per instruction, ~9 ns added to a (likely sub-100 ns) operation = ~10% overhead on capability hot paths. Acceptable for older silicon.

---

## 7. Derivation, mint, retype (CAP-Q7)

### 7.1 Mint

```
mint(parent : Cap[K, rights=R, lin=L],
     subset_rights : R' ⊆ R,
     child_linearity : L' ⊑ L)
     -> Cap[K, rights=R', lin=L']
```

A holder of a parent capability can mint a child with a subset of the parent's rights and at-most-as-strict linearity. The child gets a new descriptor with `parent_ptr` set to the parent's handle; the parent's refcount is incremented. The child's LAM tag carries a fresh epoch from the new descriptor (initial epoch 0).

### 7.2 Subset rule

`subset_rights ⊆ R` is checked at compile time (the effect set of the child's type signature must be a subset of the parent's). The kernel re-checks the bitmask at mint to back the static check. Subset is the bedrock of capability security: a holder cannot escalate their privileges by minting children.

### 7.3 Linearity weakening

The child's linearity class may be *weaker* than the parent's (e.g., a linear parent can mint an affine child; the affine child may be dropped freely). This matches Walker's lattice and lets a server hand out affine views of linear resources. The reverse (affine → linear) requires a separate `freeze` operation that consumes the affine and produces a linear (effectively asserting the holder now treats it as unique).

### 7.4 Retype

```
retype(memory : Cap[memory, R],
       new_kind : Kind,
       layout : LayoutSpec)
     -> Cap[new_kind, R']
```

A memory-region capability can be transformed into a capability of another kind. The memory is consumed (the parent memory cap is invalidated); the new descriptor is allocated within the now-consumed memory region. This is how PaideiaOS userspace allocates kernel objects (descriptors, TCBs, etc.) without the kernel being an allocator: the supervisor hands out memory caps; processes retype them into the kinds they need.

Retype is a *destructive* operation (the parent is invalidated) and has carefully specified preconditions:
- The memory region must be at least the size of the target kind's descriptor.
- The memory region must be properly aligned for the target.
- The target kind must support retype-from-memory.
- The supervisor's `retype_policy_cap` must approve the kind (some kinds are reserved).

Retype is the only mechanism by which new capability descriptors come into existence after kernel boot. The boot path creates a small set of root capabilities; everything else is derived.

### 7.5 The derivation tree

Each descriptor's `parent_ptr` forms a tree rooted at the boot-created root capabilities. The kernel walks the tree for:
- Selective revocation (CAP-Q8): walk the subtree rooted at the revoked capability.
- Epoch-exhaustion migration: walk to find all descendants needing updated handles.
- Audit: dump the tree to the audit log on demand.

The tree is *not* the runtime authorization mechanism — that's the rights bitmask + LAM tag — but it is the *administrative* mechanism: it answers "who derived this and from whom?"

---

## 8. Revocation (CAP-Q8)

### 8.1 The two operations

```
revoke(cap : Cap) -> unit
revoke_subtree(cap : Cap) -> unit
```

**`revoke(cap)`** bumps the descriptor's current epoch by 1. All outstanding handles whose tag epoch equals the *old* descriptor epoch now fail the verification (handle.epoch ≠ descriptor.epoch). This is the common case: "this capability is no longer valid; everyone using it should fail."

**`revoke_subtree(cap)`** walks the derivation tree from `cap` downward; for each descendant descriptor, bumps its epoch. Used when the holder wants to revoke specific derived authority while keeping siblings valid.

Both operations require the caller to hold the *capability* (or a derived one with the `revoke` right). Revocation is not a separate kernel call; it's an effect (`!{revoke}`) the holder performs on the capability itself.

### 8.2 Cost

- `revoke(cap)`: O(1) — just a 32-bit increment.
- `revoke_subtree(cap)`: O(n) where n is the subtree size.
- Verification cost on dereference: O(1) (one 8-bit compare).

### 8.3 Epoch exhaustion

After 256 revocations on the same descriptor, the descriptor's epoch wraps modulo 256. To preserve the invariant that *no two epochs at the same descriptor address ever overlap*, the kernel migrates: it allocates a new descriptor at a different address with epoch 0; for every *currently valid* outstanding handle, it computes a fresh LAM-tagged handle pointing to the new descriptor; it tree-walks the descendants and updates their stored handles. The old descriptor becomes a poison record (kind = 0xFF) so stale handles still fail.

Migration is the rare case (after 256 revokes); selective revocation can spread the load. The kernel maintains a per-descriptor revoke counter and triggers migration proactively at a high-water mark (e.g., epoch ≥ 240) to avoid hitting the exhaustion at runtime.

### 8.4 Interaction with the IPC primitive

A capability passed through an IPC channel that is then revoked: the consumer's next dereference of the received handle fails. The IPC primitive does *not* eagerly notify the consumer; the failure surface is the next operation on the cap. This is consistent with the dataflow-graph framing (no spontaneous events; consumer drives).

A capability *currently in flight* in a channel slot when its descriptor is revoked: the slot's tag bits remain valid (they encoded the producer's epoch); the consumer's verification against the current descriptor epoch fails. The consumer treats the message as if it were corrupt; the corresponding capability is logged as stale; the channel does not die.

### 8.5 Reclamation

A descriptor whose refcount drops to zero *and* whose subtree is empty becomes reclaimable. The kernel does not eagerly free reclaimed descriptors; they go on a deferred-reclaim list and are returned to their kind's slab on the next quiescent point (e.g., a global epoch transition or an explicit `gc` call by the supervisor). This avoids the use-after-free hazard of an in-flight handle racing with reclamation.

---

## 9. Sealing (CAP-Q9)

### 9.1 The seal-cap / unseal-cap pair

To seal capabilities of a chosen domain (e.g., NvmeQueueCap of a specific driver's queues), the driver requests a fresh seal/unseal capability pair from the supervisor:

```
request_seal_pair(domain : SealDomain) -> (seal_cap : SealCap, unseal_cap : UnsealCap)
```

The pair is bound at construction: `seal_cap` and `unseal_cap` are matched by a kernel-allocated nonce; only `unseal_cap` matching the `seal_cap` used to seal a capability can reveal it.

### 9.2 Sealing

```
seal(target_cap : Cap, seal_cap : SealCap) -> SealedCap
```

The target capability's LAM tag has the sealed bit set; the descriptor records the seal-cap's nonce. The sealed capability can be:
- Sent through IPC.
- Stored in memory.
- Invoked through its operations (the kind's operations are not gated on the seal bit, only introspection is).

### 9.3 Unsealing

```
unseal(sealed_cap : SealedCap, unseal_cap : UnsealCap) -> Cap
```

The kernel verifies that the unseal-cap's nonce matches the descriptor's recorded nonce; on success, returns a fresh handle without the sealed bit. The original sealed handle remains valid; this is *unsealing*, not *destruction*.

### 9.4 Introspection on sealed caps

Operations that would reveal capability metadata (`inspect_rights`, `walk_derivation`, `query_kind`) fail on a sealed capability unless the caller also holds the matching `unseal_cap`. The kind operations (`mem_read`, `port_write`, `ipc_send`, …) do *not* check the seal bit — sealing hides metadata, not action.

### 9.5 Use cases

- **Driver-client pattern.** An NVMe driver hands a sealed NvmeQueueCap to a client. The client can submit work via the IPC operations the capability supports; the client cannot read the queue's internal state, walk to the driver's own caps via `parent_ptr`, or enumerate rights to discover the driver's full capability set.
- **Bearer tokens.** A capability that authorizes a specific action but should be unforgeable and untraceable to its source (e.g., a one-time admission token).
- **Audit hiding.** A capability whose existence is auditable but whose detail is not visible to the audit reader without the unseal-cap.

### 9.6 Supervisor policy

The supervisor's grant of `seal_cap` to a process is a security-relevant act, logged to the audit channel. The supervisor must decide which domains a process may seal capabilities in; misuse is auditable.

---

## 10. Storage of handles in memory (CAP-Q10)

### 10.1 Where handles can live

A capability handle is a 64-bit LAM-tagged value; it can be stored anywhere a 64-bit value can be stored:
- A register (R12, R13 by convention per Q-A6).
- A stack slot.
- A heap-allocated struct field.
- A memory mapped from another process (shared memory).
- An IPC channel slot (per the wait-free IPC doc §5).
- A descriptor's tail field (e.g., the `parent_ptr` in the common header).

The kernel does not maintain a per-handle shadow or registry; the handle is just a value.

### 10.2 What prevents forgery

The LAM tag bits encode a kernel-controlled secret per descriptor:
- The revocation epoch is monotonically increasing and known only to the descriptor.
- The kind hint must match the descriptor's kind.
- A handle whose tag bits do not match the descriptor's current state fails the verification on next dereference.

A user process *cannot* fabricate a valid tag without the kernel having minted it. Setting the tag requires either:
- Calling a kernel-provided mint/retype/derive operation (the legitimate path).
- An `unsafe` block that lies about its declared effects (the audited path).

### 10.3 What does *not* prevent duplication

A user process holding a valid handle in R12 may freely copy it: `mov [my_storage], r12`. There is no runtime check that prevents this. The substructural type system catches it at compile time: a `linear` capability cannot be used twice; copying it into storage and then using it from the register is two uses. The compile-time check is exhaustive over well-typed code.

For `unsafe` blocks: the audit catalog records every unsafe; review is the discipline; mistakes are limited to the unsafe block's scope. Cross-block forgery (one unsafe block produces a fake handle that another block consumes as if real) is prevented because the LAM tag bits would not match — the unsafe block can copy a real handle, but cannot generate one from scratch.

### 10.4 Shared-memory capability passing

When two processes share memory (one process holds a `mem_share` cap and grants it to the other), the shared region can carry capability handles. The handle is the same 64-bit value in both processes' address spaces; the LAM tag verification still works because the descriptor it points to is in kernel memory accessible from both.

This is the underlying mechanism for the IPC primitive's slot-based capability transport: the channel's slot array is shared between producer and consumer; the handle stored there is visible to both, with kernel verification still applying.

### 10.5 The runtime backstop summary

| Bug class | Catch mechanism |
|---|---|
| Forged tag (random bits) | LAM tag verification on dereference (fails). |
| Stale handle (after revocation) | Epoch mismatch in LAM tag (fails). |
| Wrong-kind dereference | Kind hint in LAM tag (fast fail) + descriptor kind (definitive). |
| Sealed cap inspection without unseal-cap | Sealed bit in LAM tag (fails introspection ops). |
| Linear cap used twice in well-typed code | Static check (E14); the compile-time, the dominant catch. |
| Linear cap used twice in `unsafe` code | Audit + manual review. |
| Linear cap split across processes via shared memory | This is *legal*: the IPC primitive's slot transport is precisely a controlled form of this; uncontrolled forms are the supervisor's concern (the shared-memory cap was granted intentionally). |

---

## 11. Effect operations and handlers (Q-A3 integration)

### 11.1 The Capability effect

```paideia-as
effect Capability {
  op mint            : (parent: Cap ↓, subset: Rights, lin: Linearity) -> Cap
  op retype          : (mem: MemCap ↓, kind: Kind, layout: Layout) -> Cap
  op revoke          : (cap: Cap ↓) -> unit
  op revoke_subtree  : (cap: Cap) -> unit                        // does not consume
  op seal            : (cap: Cap ↓, sc: SealCap) -> SealedCap
  op unseal          : (scap: SealedCap, uc: UnsealCap) -> Cap
  op inspect_rights  : (cap: Cap) -> Rights                       // fails on sealed
  op inspect_kind    : (cap: Cap) -> Kind                          // succeeds even on sealed (the kind hint is public)
}
```

The kernel installs the default handler at thread creation; it performs the actual capability operations. Test handlers can mock individual operations for property-based testing (e.g., simulate a revocation without actually revoking).

### 11.2 Composition with IPC

The IPC primitive's capability transport is a `Capability` effect operation in disguise: enqueueing a capability through a channel implicitly performs a `move`-style transfer (the linear handle is consumed at the producer, materialized at the consumer). The IPC primitive's effect handler (per the IPC doc §10) composes with the Capability effect handler — both can observe the transfer.

### 11.3 Composition with audit

The default Capability handler emits an audit-channel entry for every mint, retype, revoke, seal, and unseal — building the audit history (E19) automatically. The audit entry includes the descriptor address, parent address, kind, rights bitmask, and timestamp.

---

## 12. Interactions with other subsystems

### 12.1 With the IPC primitive

- Channel construction takes a `Channel(Schema)` capability, allocated from a freshly-retyped memory region; minted as `ipc-endpoint` kind.
- Slot-caps (kind 6) are minted at channel construction; their descriptors' tails carry the channel and slot index.
- Capability transport through channels is verified on dequeue: the slot's stored handle is verified against its descriptor.

### 12.2 With the scheduler

- `sched-ctx` capabilities (kind 5) are the substrate for SC donation per the IPC doc §7.
- The scheduler treats SC caps as linear; donation transfers the cap without copying.

### 12.3 With memory management

- The kernel's memory management is entirely capability-mediated: memory regions are caps, page tables are retyped caps, address spaces are retyped caps.
- The boot path creates one or two root memory caps covering all physical RAM; everything else is derived.

### 12.4 With the audit log

- Every mint, retype, revoke, seal, unseal emits an audit entry.
- Cycle introduction (per IPC §2.3) emits an audit entry.
- The audit log is itself a capability (kind 11), held by the supervisor and by any process granted `audit` rights.

### 12.5 With confidential computing (D1, future)

- TDX guest memory regions are derived (via retype-like operations within the TDX module) from a `tdx-shared` memory cap.
- The capability system inside a TD is a separate descriptor table managed by the TDX shim; capabilities do not cross the TD boundary except as serialized bundles.

---

## 13. paideia-as implementation strategy

### 13.1 Module layout

`src/kernel/cap/` is the kernel-side implementation:

```
src/kernel/cap/
├── descriptor.s     # descriptor allocation, slab pools
├── mint.s           # mint, retype, derive
├── revoke.s         # revoke, revoke_subtree, epoch migration
├── tag.s            # LAM tag emission, masking macros, verify macros
├── seal.s           # seal / unseal operations
├── rights.s         # rights bitmask ↔ effect mapping
├── effects.s        # Capability effect declarations + default handler
└── audit.s          # audit-entry emission for capability ops
```

### 13.2 Phase-1 vs. phase-2 split

Phase 1 (NASM bootstrap):
- A simplified capability system: fixed-layout descriptor (not kind-tagged variant), single-rights-bitmask layout, no derivation tree, manual revocation by tree walk.
- No sealing.
- No effect-based mapping (the type system isn't ready).
- Hardware LAM only (no software-LAM fallback in phase 1 — phase 1 targets dev hardware that has LAM).

Phase 2 (paideia-as coexistence):
- Kind-tagged variant descriptors.
- Derivation tree and tree-walk revocation.
- Sealing.
- Effect-bitmask mapping.
- Software-LAM fallback enabled for older-hardware CI lanes.

Phase 3 (paideia-as canonical):
- All features active; phase-1 fallback removed.

### 13.3 Calling convention integration

R12 carries the operating-on capability (input to most cap ops). The kernel's cap-ops dispatch (via the Capability effect handler in R15) reads R12, performs the LAM verification per §5, then performs the descriptor-side operation.

For mint:
```
mov r12, parent_cap
mov rdi, subset_rights_bits
mov rsi, child_linearity_class
mov rax, [r15 + ipc_handler_offset]   ; Capability effect handler
call rax                              ; dispatch mint operation
; rax now holds the new child cap handle
```

The handler verifies LAM tags, descends into the descriptor, performs the mint, returns the new handle.

### 13.4 Audit emission

Every capability operation emits an audit entry. The entry format:

```
 32-byte audit record:
   op_code  (1 B)   : MINT | RETYPE | REVOKE | SEAL | UNSEAL | …
   reserved (3 B)
   timestamp (8 B)  : monotonic TSC
   actor_pid (4 B)  : the process performing the op
   cap_addr (8 B)   : the affected descriptor address
   parent_addr (8 B): for mint/retype, the parent descriptor; else zero
```

Two records per cache line; emission is one non-temporal 32-byte write.

---

## 14. Performance budget

| Operation | Budget | Substrate |
|---|---|---|
| Hardware-LAM verify (epoch + kind) | ≤ 5 ns | bare-metal Sapphire Rapids |
| Software-LAM verify (mask + check) | ≤ 12 ns | bare-metal Skylake-Server |
| Mint (subset, no retype) | ≤ 100 ns | bare-metal |
| Retype (memory → IPC endpoint) | ≤ 200 ns | bare-metal |
| Revoke (epoch bump only) | ≤ 30 ns | bare-metal |
| Revoke subtree (10 descendants) | ≤ 1 µs | bare-metal |
| Seal | ≤ 50 ns | bare-metal |
| Unseal | ≤ 50 ns | bare-metal |
| Epoch exhaustion migration (10 descendants) | ≤ 5 µs | bare-metal |
| Audit entry emission | ≤ 10 ns | bare-metal |

Numbers are aspirational; baselines come from `design/capabilities/perf-baselines.md` (future).

---

## 15. Verification strategy

### 15.1 Layer A: TLA+ specification

A spec at `design/capabilities/capability-system.tla` (future) formalizes:
- Descriptor lifecycle (allocate, mint, retype, revoke, reclaim).
- Tag bit semantics (epoch comparison, kind verification, sealed enforcement).
- Derivation tree invariants (no cycles; parent of root is null; tree consistency under revocation).
- Sealing invariants (seal-cap and unseal-cap pair matching).

Properties:
- **No-forgery.** A handle whose tag was not set by a kernel operation fails verification.
- **Subset-derivation.** Any minted child has rights ⊆ parent.
- **Revocation soundness.** After `revoke(cap)`, all handles with old epoch fail.
- **Subtree revocation completeness.** After `revoke_subtree(cap)`, every descendant of cap is revoked.
- **Epoch-migration preservation.** After exhaustion migration, valid pre-migration handles map to valid post-migration handles.
- **Sealing soundness.** Inspection of a sealed capability without matching unseal-cap fails.

### 15.2 Layer B: linearity regression

`tests/linearity-regression/cap/` contains accept/reject corpus for every substructural rule applied to capabilities. Per `02-development-environment.md` §9.6, run on every PR.

### 15.3 Layer C: property-based testing

The PBT harness drives random capability-flow scenarios:
- Random mint trees, then random revocations, verifying revocation soundness.
- Random sealing/unsealing patterns.
- Random unsafe-block-like manipulations (within the harness's authority), verifying LAM detection.

### 15.4 Layer D: feature-masked CI lanes

The `minimum-skylake-x` and `minimum-skylake-s` CI lanes per `02-development-environment.md` §10.5 exercise the software-LAM fallback. Tests must pass on both hardware-LAM and software-LAM lanes for every capability operation.

---

## 16. Open issues

| ID | Issue | Resolution location |
|---|---|---|
| CAP-O1 | The TLA+ specification (§15.1) is not yet written; phase-1 deliverable. | `design/capabilities/capability-system.tla` |
| CAP-O2 | Rights bitmask catalogs per kind (§4.3) — each kind needs its own bit catalog documented. | `design/capabilities/rights-catalog.md` |
| CAP-O3 | The descriptor table's address-space layout — where in the kernel half does it sit? Affects 48-bit vs 57-bit interaction. | `design/kernel/memory-model.md` |
| CAP-O4 | 5-level paging degraded tag layout (§5.2) — the kind-hint-absent path is materially slower. Quantify cost; advise users against 5-level for capability-heavy processes. | `design/kernel/memory-model.md` |
| CAP-O5 | Epoch-exhaustion migration interactions with in-flight IPC (a handle in a channel slot during migration). The migration must update the slot's handle, but the slot may be racing with the consumer. | TLA+ spec |
| CAP-O6 | Derived-kind safety holes via lying `unsafe` blocks (§3.4) — formal acknowledgement and review-process spec. | `design/capabilities/derived-kinds.md` (future) |
| CAP-O7 | Reclamation timing (§8.5) — the kernel's "deferred reclaim at quiescent point" needs a precise definition. | TLA+ spec |
| CAP-O8 | Seal-cap / unseal-cap pair management — should pairs be revocable independently? What happens when only the seal-cap is revoked? | `design/capabilities/sealing.md` (future) |
| CAP-O9 | Cross-domain capability translation for D14 distributed extension. Reserved kind slot #14 — design what it looks like. | `design/capabilities/distributed.md` (future) |
| CAP-O10 | Audit-record format growth — the 32-byte format will need extension fields eventually. | `design/audit/format.md` (future) |
| CAP-O11 | Performance baselines (§14) are aspirational; first bare-metal measurements drive `perf-baselines.md`. | `design/capabilities/perf-baselines.md` (future) |
| CAP-O12 | Phase-1 fallback API design — what subset of the phase-2 API is available, ensuring forward-compatibility. | `design/capabilities/phase1-api.md` (future) |

---

## 17. References

### 17.1 Capability systems

- Klein, G. et al. *seL4: Formal Verification of an OS Kernel*. SOSP 2009. (Subset derivation, retype, CSpace.)
- Klein, G. et al. *Comprehensive Formal Verification of an OS Microkernel*. TOCS 32(1), 2014.
- Hardy, N. *KeyKOS Architecture*. ACM SIGOPS Operating Systems Review 19(4), 1985. (Capability foundations.)
- Levy, H. M. *Capability-Based Computer Systems*. Digital Press, 1984. (Reference text.)
- Shapiro, J. S., Smith, J. M., Farber, D. J. *EROS: A Fast Capability System*. SOSP 1999.
- Watson, R. N. M. et al. *CHERI: A Hybrid Capability-System Architecture for Scalable Software Compartmentalization*. IEEE S&P 2015.
- Woodruff, J. et al. *The CHERI Capability Model*. ISCA 2014.

### 17.2 Substructural type systems and effects (cross-references)

- Walker, D. *Substructural Type Systems*. In *Advanced Topics in Types and Programming Languages*, MIT Press, 2005.
- Plotkin, G., Pretnar, M. *Handlers of Algebraic Effects*. ESOP 2009.
- Leijen, D. *Koka: Programming with Row Polymorphic Effect Types*. MSFP 2014.

### 17.3 Sealing and opaque references

- Morris, J. H. *Protection in Programming Languages*. CACM 16(1), 1973. (Original sealing idea.)
- Rashid, R. et al. *Mach: A Foundation for Open Systems*. WS Workstation Operating Systems, 1989. (Sealed ports.)
- Miller, M. S. *Robust Composition: Towards a Unified Approach to Access Control and Concurrency Control*. PhD thesis, Johns Hopkins University, 2006. (Object-capability sealing patterns.)

### 17.4 Intel documentation

- Intel® 64 and IA-32 Architectures Software Developer's Manual, current revision (LAM in Vol. 1; paging in Vol. 3A).
- Intel® LAM (Linear Address Masking) Technical Documentation, current revision.
- Intel® 5-Level Paging and 5-Level EPT White Paper, rev. 1.1, 2017.

---

*End of document.*
