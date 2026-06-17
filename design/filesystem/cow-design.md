# PaideiaOS — Copy-on-Write Filesystem Design

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Architectural specification of the PaideiaOS clean-slate CoW filesystem mandated by Q4 of `01-foundational-decisions.md`. Covers the B-epsilon tree spine, HAMT directory structures, persistent functional discipline, CoW emergence from substructural sharing, Merkle DAG integrity, per-transaction PQ signature, typed name-resolution graph, capability model, encryption at rest, compression, transaction commit, recovery, and the phase-1 fallback path.

**Hard inputs (do not relitigate):**
- `design/00-feature-inventory.md` — E5 (storage stack), E17 (CoW + integrity-checked FS), E6 (typed name-resolution graph), E19 (audit log); D9 (novel FS semantics).
- `design/01-foundational-decisions.md` — Q4 (new CoW filesystem from scratch), Q11 (PQ-signed integrity), Q13 (typed records for shell pipelines).
- `design/02-development-environment.md` — fuzz targets include the CoW FS (§9.5); reproducible builds; algorithm catalog.
- `design/toolchain/custom-assembler.md` — substructural lattice (Q-A2), algebraic effects (Q-A3), functor modules (Q-A7).
- `design/ipc/wait-free-dataflow.md` — FS server is reached via the dataflow IPC primitive; session-typed channels.
- `design/capabilities/linearity-and-tags.md` — kind-tagged variants; derived kinds via type system; retype.
- `design/kernel/memory-model.md` — CoW emerges from substructural lattice + page-fault handler (MEM-Q6); page-size derived kinds.
- `design/security/pq-trust-root.md` — SLH-DSA-128s (boot), Ed25519+ML-DSA-65 (operational), ML-KEM-1024 (KEK), algorithm catalog.

---

## 0. Decisions summary

### 0.1 Inherited (already binding)

| Source | Constraint |
|---|---|
| Q4 | A new CoW filesystem from scratch, designed under the PaideiaOS capability and FP-style discipline. |
| Q11 / `security/pq-trust-root.md` | The FS's on-disk format carries PQ signatures. SLH-DSA-128s is the boot-chain signature; operational signatures are hybrid Ed25519 + ML-DSA-65. |
| Q13 | Shell pipelines pass typed records by reference within a host; serialization at boundaries. The FS exposes typed records to shell consumers. |
| E6 | The naming model is a *typed name-resolution graph*, not a POSIX path system. |
| MEM-Q6 | CoW emerges from the substructural lattice + page-fault effect handler — not a separate FS feature, an OS-wide property the FS inherits. |
| CAP-Q3 | Closed 16-kind base enum with one remaining reserved slot (#15). |
| Q9 | No POSIX; external software runs in the WASM/VM jail (per `runtime/wasm-vm-jail.md`, future). |

### 0.2 New decisions in this document

| # | Question | Decision |
|---|---|---|
| FS-Q1 | Data-structure family | **Genuinely novel**: B-epsilon trees for the main keyspace (write-buffered internal nodes), HAMT (hash-array-mapped tries) for directory structures, persistent functional discipline throughout. Merkle DAG layered over for integrity. |
| FS-Q2 | CoW granularity (taken: pillar-derived) | **Extent-level**. Extents are ranges of contiguous logical bytes mapped to physical extents on disk; the unit of CoW is the extent. Linked to MEM-Q4 page-size kinds (4K/2M/1G) where extents can be page-aligned for zero-copy direct I/O. |
| FS-Q3 | PQ signing granularity (taken) | **Per-transaction-commit**. Every commit writes a new superblock pointing to the new tree root and carries an SLH-DSA-128s signature over the root. The Merkle DAG ensures the signature transitively authenticates every node. |
| FS-Q4 | Naming model (taken: E6-derived) | **Typed name-resolution graph**: hierarchical paths *plus* tag-attribute cross-references *plus* schema-aware records. POSIX paths are unavailable. The shell (E12) queries the graph via typed effect operations. |
| FS-Q5 | Capability model (taken) | File-level capabilities: each file is a derived kind over base `memory` with file-specific effect rows; directories are derived kinds over the directory-HAMT; extents are *not* separately capability-typed (they're accessed through the file cap). |
| FS-Q6 | Hash algorithm for Merkle (taken: per algorithm catalog) | **BLAKE3** — fast SIMD-friendly hash, well-studied; usable for both integrity and content addressing. |
| FS-Q7 | Encryption (taken: PQ-doc-derived) | TME-MK at-rest encryption per FS; the KEK is wrapped under hybrid X25519 + ML-KEM-1024 (per universal KEM PQ-Q6) sealed in the supervisor's enclave (per PQ-Q5). |
| FS-Q8 | Compression (taken) | **Zstd** opt-in per file via a `compression_cap` attribute; default off. |
| FS-Q9 | Recovery model (taken) | **Online only**: no offline fsck. Verification is continuous via Merkle hash checks on every read; corruption triggers `fs_corruption` effect; recovery is via the most recent verified signed root or a replicated copy. |
| FS-Q10 | Multi-device pool (taken: scope-derived) | **Phase 1–2: single device only**. Phase 3+: multi-device pool with mirror/RAID-Z-equivalent via the same B-epsilon + Merkle structures; the policy is a supervisor decision. |

### 0.3 Three meta-positions

1. **This is an *ambitious* design.** B-epsilon trees are research-active (TokuDB / Tokutek lineage, planned for bcachefs but not yet shipped at scale); HAMT is well-understood for in-memory persistent data structures (Bagwell, Clojure, Scala) but its application to *durable* on-disk directories is novel. Combined with the PaideiaOS substructural + effect-typed discipline, this filesystem is research-grade in two dimensions: the structures themselves *and* the formal discipline they're built under. Realistic timeline: phase-2 ships a minimum-viable CoW FS; phase-3 reaches B-epsilon + HAMT maturity; phase-4+ would be production-grade. The user accepted this scope explicitly.

2. **CoW is a kernel property, not an FS feature.** Per MEM-Q6, copy-on-write emerges OS-wide from the substructural lattice + page-fault handler. The FS *inherits* CoW for free at the page-mapping level. The FS-internal CoW (B-epsilon nodes are CoW; tree spine is CoW) is a separate concern: it's persistence-CoW, not memory-CoW. Both are present.

3. **The "typed name-resolution graph" is genuinely different.** POSIX path syntax (`/usr/bin/foo`) is rejected by pillar 5 (no backwards compatibility) and Q9 (no POSIX). The FS's naming model is a directed labeled graph where nodes are typed records (files, directories, schemas) and edges are typed attributes (parent-of, references, tagged-as). Queries are schema-aware; the shell (E12) issues typed effect operations against the graph. This is closer to a graph database than a file system, but persists with full ACID semantics over the B-epsilon + Merkle structures.

---

## 1. Architectural overview

```
                  ┌──────────────────────────────────────────────────────────────┐
                  │   FS Server (userspace process, fs-cow)                       │
                  │                                                                │
                  │  ┌────────────────────────────────────────────────────────┐  │
                  │  │ Typed name-resolution graph (in-memory cache)          │  │
                  │  │   - hierarchy nodes                                    │  │
                  │  │   - tag-attribute index                                │  │
                  │  │   - schema registry                                    │  │
                  │  └────────────────────────────────────────────────────────┘  │
                  │  ┌────────────────────────────────────────────────────────┐  │
                  │  │ B-epsilon spine — keyspace                             │  │
                  │  │   internal nodes buffer pending updates                │  │
                  │  │   leaves hold extent maps                              │  │
                  │  │   every node CoW; every node Merkle-hashed            │  │
                  │  └────────────────────────────────────────────────────────┘  │
                  │  ┌────────────────────────────────────────────────────────┐  │
                  │  │ HAMT directories                                       │  │
                  │  │   32-way trie keyed on BLAKE3 of name                  │  │
                  │  │   nodes immutable; updates by path copying            │  │
                  │  └────────────────────────────────────────────────────────┘  │
                  │  ┌────────────────────────────────────────────────────────┐  │
                  │  │ Transaction manager                                    │  │
                  │  │   buffer pool; commit barrier; PQ signer interface     │  │
                  │  └────────────────────────────────────────────────────────┘  │
                  │  ┌────────────────────────────────────────────────────────┐  │
                  │  │ Storage capability holder                              │  │
                  │  │   NVMe / virtio-blk via E5                             │  │
                  │  │   TME-MK key-id binding                                │  │
                  │  └────────────────────────────────────────────────────────┘  │
                  └────────────────┬───────────────────────────────────────────┘
                                   │
                                   ▼
                   ┌────────────────────────────────────────┐
                   │  Wait-free dataflow IPC channels       │
                   │  (per IPC primitive)                   │
                   │   - client → fs : Read/Write requests  │
                   │   - fs → client : typed responses      │
                   │   - fs → supervisor : audit events     │
                   └────────────────────────────────────────┘
                                   │
                                   ▼
                   ┌────────────────────────────────────────┐
                   │  Clients: shell, applications, audit   │
                   │  Each holds a typed file/dir capability │
                   └────────────────────────────────────────┘

   On-disk format:
   ┌──────────────┬─────────────────────────────────────────────────────────┐
   │ Superblock   │ B-epsilon node + HAMT node + extent regions              │
   │ chain (N=64) │                                                          │
   │ — newest is   │  Every node:                                            │
   │   the canonical│   - BLAKE3 hash over its children                      │
   │   committed    │   - kind tag (internal / leaf / HAMT / extent_index)    │
   │   tree         │   - data                                               │
   │ — each carries │                                                        │
   │   PQ signature │  Superblock:                                           │
   │   over its     │   - magic, version, FS UUID, TME-MK key-id              │
   │   root         │   - root node hash                                     │
   │ — written      │   - last commit timestamp                              │
   │   round-robin  │   - SLH-DSA-128s signature over the above              │
   └──────────────┴─────────────────────────────────────────────────────────┘
```

---

## 2. B-epsilon tree spine (FS-Q1)

### 2.1 Background

The B-epsilon tree (Brodal & Fagerberg 2003; Bender et al. 2007) is a write-optimized variant of the B-tree. Internal nodes have a *buffer* of pending update messages that aren't flushed to children immediately; flushes happen when buffers fill. This amortizes the cost of small random writes across larger sequential flushes — a fundamental write-throughput win, especially for HDDs but also for SSDs (sequential writes wear levelling).

### 2.2 The PaideiaOS B-epsilon variant

The PaideiaOS B-epsilon tree is parameterized by `ε ∈ (0, 1)`:
- Each internal node has `B^ε` children (typical: B=2048 cache-lines worth of node, ε = 0.5 → ~45 children).
- Each internal node has buffer space for `B - B^ε * pointer_size` messages.
- Messages are tagged with their key range and operation type (`Insert`, `Delete`, `Update`).

A read walks from root to leaf, applying any buffered messages encountered along the way before reading the leaf. A write inserts a message at the root; the root flushes when full.

### 2.3 CoW discipline

Every node is *immutable once written* (CoW). A flush from a parent's buffer to a child:
1. Reads the child.
2. Constructs a new child with the buffered messages applied.
3. Writes the new child (allocates fresh extent).
4. Writes a new parent pointing to the new child.
5. Propagates the new parent upward (recursive CoW).
6. The new root is recorded in the next superblock commit.

Old nodes remain valid for *snapshots* — a snapshot retains the historical root pointer; reads from a snapshot traverse the historical Merkle DAG.

### 2.4 Merkle hashing of nodes

Every node carries a BLAKE3 hash over:
- Its kind tag.
- Its content (buffered messages for internals; extent map for leaves).
- The hashes of its children.

This is recursive: the root's hash transitively summarizes the entire tree. The superblock's signed root hash is the FS's authenticated identity.

### 2.5 Why B-epsilon

- Write-throughput: many small writes amortize through buffer flushes. The wait-free IPC primitive can deliver high write rates to the FS server; the FS must keep up.
- Match with multicore: parallel flushes are possible (different subtrees can flush concurrently).
- Forward-looking: the structure was selected partly because it's research-active and the project's pillar 11 (research-driven) is honored at the algorithm level.

### 2.6 Phase-2 risk

The B-epsilon tree has been studied for decades but production deployments (TokuDB / Percona, planned for bcachefs) are limited. PaideiaOS's implementation must:
- Adopt a published B-epsilon variant (TokuDB's Fractal Tree or the Bender et al. *Bε-tree* paper) as the algorithmic baseline.
- Add Merkle hashing per node.
- Verify the write-buffer recovery semantics (a crash mid-flush must be recoverable to either the pre-flush or post-flush state, with the Merkle hash matching).

The verification stories (TLA+ spec, property-based testing) are scope-realistic. See §15 open issues.

---

## 3. HAMT directories (FS-Q1 continued)

### 3.1 Background

Hash-Array-Mapped Trie (Bagwell 2000) is a persistent functional data structure widely used as an immutable hash map (Clojure, Scala, Haskell). Each node is a 32-way array indexed by 5 hash bits; collisions descend one level deeper.

For directories: hash the entry name with BLAKE3; use the hash bits to descend the HAMT; the leaf carries the actual `(name, child_node_hash)` mapping.

### 3.2 Why HAMT for directories

- **Persistent.** Updates produce new nodes without modifying old ones — CoW-native.
- **Concurrent.** Reads on old versions are safe in parallel with updates on new versions; no locking.
- **Lookup is O(log₃₂ n)** in the directory size — extremely flat trees (a million entries is ~4 levels).
- **Path copying** for updates is bounded: only the nodes on the path from root to the affected leaf are copied.
- **Merkle integration**: each HAMT node carries the BLAKE3 hash of its children, just like B-epsilon nodes.

### 3.3 The directory operations

```paideia-as
effect Directory {
  op lookup    : (dir : DirCap, name : String) -> option NodeCap !{fs_read}
  op insert    : (dir : DirCap, name : String, child : NodeCap) -> DirCap !{fs_write}
  op remove    : (dir : DirCap, name : String) -> DirCap !{fs_write}
  op enumerate : (dir : DirCap) -> list (String, NodeCap) !{fs_read}
}
```

Each operation produces a *new* `DirCap` representing the modified state (insert/remove). The old `DirCap` remains valid pointing to the pre-modification view — a *snapshot for free*.

### 3.4 Snapshots and history

A directory's "history" is the chain of root pointers across transaction commits. The FS retains historical roots until garbage-collected; an explicit snapshot pins a root, preventing GC. Snapshots cost: zero extra space at creation; deltas accumulate as the live tree diverges.

### 3.5 Why HAMT vs. a B-epsilon for directories

- Most directories are small (tens to thousands of entries). The B-epsilon's write-buffer optimization is wasted; the simpler HAMT structure is faster.
- Persistent immutable structures are well-understood (Bagwell, Clojure community); risk is lower.
- The HAMT's branching pattern is hash-based, which is naturally collision-resistant and avoids the B-tree's rebalancing.

The hybrid (B-epsilon for keyspace, HAMT for directories) is intentional: each data-structure choice matches its use.

---

## 4. CoW: persistence + memory (FS-Q1 continued, MEM-Q6 integration)

### 4.1 Two CoW layers

1. **Memory CoW** (per MEM-Q6): when a page-cap is `mem_share`-d (affine), its PTE is marked read-only; a writer triggers a page fault; the pager allocates and copies. *In-memory* CoW.

2. **Persistence CoW** (this document): every B-epsilon and HAMT node is allocated fresh on every update; the old node remains for snapshots and historical reads. *On-disk* CoW.

The two layers compose: an in-memory write to a CoW-marked page (memory CoW triggers in-memory copy) eventually flushes to disk as a new extent (persistence CoW writes the new extent). The "CoW write" of one byte may touch:
- 1 in-memory page (4 KiB memory CoW).
- 1 or more B-epsilon leaves (each leaf is a fresh on-disk extent).
- The B-epsilon path from root to leaf (path-copying CoW).
- The superblock (the new root pointer).

### 4.2 Substructural integration

Every file/dir/extent capability has a substructural class:
- A linear `FileCap` represents exclusive ownership.
- An affine `FileReadOnlyCap` represents shared read access; minting one of these triggers the in-memory CoW for any subsequent writer.
- The FS server tracks shares via the descriptor's `shared_count`.

The substructural lattice does *not* track on-disk structures directly — those are FS-internal state. But the lattice tracks who holds what at the FS-server's API boundary.

### 4.3 Snapshot semantics

A snapshot is a capability:

```paideia-as
effect Snapshot {
  op create  : (root : DirCap, label : String) -> SnapshotCap
  op restore : (snap : SnapshotCap) -> DirCap         // not destructive; new mount
  op delete  : (snap : SnapshotCap) -> unit            // releases pin; allows GC
  op diff    : (a : SnapshotCap, b : SnapshotCap) -> DiffStream
}
```

A snapshot's storage cost is *zero* at creation (it just pins a Merkle root). Diff between snapshots is computed by walking the Merkle DAGs and comparing hashes — sharing subtrees are visible by equal hashes, eliminating O(size) comparison cost.

---

## 5. Merkle DAG integrity (FS-Q1 continued)

### 5.1 The hash chain

Every on-disk node carries `BLAKE3(kind ‖ content ‖ child_hash_1 ‖ child_hash_2 ‖ …)`. The root's hash is the FS identity. A reader fetches a node, recomputes its hash, compares to the parent's recorded hash — corruption is detected.

### 5.2 BLAKE3 (FS-Q6)

BLAKE3 was chosen because:
- SIMD-vectorized (AVX-512 throughput on the supported PaideiaOS hardware tier).
- Tree-structured internally — parallelizable.
- Cryptographically strong (256-bit output).
- Public-domain implementation reference.
- Used by the algorithm catalog (per PQ doc) as the BLAKE3 of artifact descriptors.

### 5.3 Verification on read

Every read verifies the Merkle chain from root to the touched leaf. The verification overhead is one BLAKE3 hash per node touched (~5 ns per cache line at AVX-512 speeds; with parallel SIMD, the cost is negligible relative to the I/O).

### 5.4 Corruption response

A read whose recomputed hash mismatches the parent's recorded hash raises an `fs_corruption` effect. The handler (the FS server's policy):
1. Logs to the audit channel (E19).
2. Attempts to recover from a replicated copy (multi-device pool, phase 3+) or a recent snapshot.
3. If unrecoverable, the read returns `Corruption` to the caller; the affected file/region is flagged.

The fs-server's `fs_corruption` handler is per-FS (capability-typed); the supervisor's policy may install global handlers (e.g., dump state, prepare for snapshot rollback).

---

## 6. PQ signing and verification (FS-Q3)

### 6.1 Per-transaction-commit signature

Every transaction commit:
1. The transaction manager assembles the new root (B-epsilon + HAMT all coalesced).
2. Computes the root's BLAKE3 hash (already done during construction).
3. Constructs the superblock: magic, version, FS UUID, TME-MK key-id, root hash, commit timestamp.
4. Submits the superblock to the supervisor's PQ signing service (per `security/pq-trust-root.md` §6.3).
5. The signer returns an SLH-DSA-128s signature.
6. The superblock + signature is written to the next slot in the superblock ring (N=64 slots, round-robin).
7. A `commit_barrier` (sfence + writeback) ensures durability.

### 6.2 Why SLH-DSA-128s

- Hash-based (no lattice assumption): minimal cryptanalysis risk for the boot-chain-tier signing.
- Signature size ~7.8 KB: fits in a sector; per-transaction overhead acceptable.
- Slow signing (~50 ms per PQ doc §15): bounds commit rate but is not the dominant cost (the I/O for the new root is comparable).
- Verification fast: ~100 µs.

### 6.3 Verification at mount and at boot

At mount:
1. The FS server reads all 64 superblocks; selects the highest-timestamp one with a valid signature.
2. Verifies the signature against the FS's registered SLH-DSA-128s public key (resolved via the algorithm catalog).
3. If the latest signature fails, falls back to the next-most-recent valid superblock.
4. Replays the audit log (E19) for the period between the last valid commit and now (if recovery is needed).

### 6.4 Key rotation interaction

When the boot-chain signing key rotates (every 6 months per PQ-Q9), existing superblocks remain verifiable via the algorithm catalog's key history; new commits use the rotated key.

### 6.5 Audit log integration

Every commit emits an audit entry (kind = `fs_commit`, fields = root hash, timestamp, signer key id). The audit log itself is signed; together with the FS commits, the audit chain is verifiable end-to-end.

---

## 7. Typed name-resolution graph (FS-Q4)

### 7.1 The graph

A directed labeled graph:
- **Nodes**: typed records (files, directories, schemas, tags).
- **Edges**: typed labeled relationships (parent-of, references, tagged-as, schema-of).

Every node has a *schema* identifying its type; the schema itself is a node, recursively-typed.

### 7.2 Operations

```paideia-as
effect TypedGraph {
  op resolve_path     : (root : NodeCap, path : Path) -> option NodeCap
  op lookup_by_tag    : (root : NodeCap, tag : Tag) -> list NodeCap
  op enumerate_schema : (root : NodeCap, schema : SchemaCap) -> list NodeCap
  op query            : (root : NodeCap, query : Query) -> ResultStream
  op create_node      : (parent : NodeCap, schema : SchemaCap, content : Record) -> NodeCap
  op link             : (from : NodeCap, edge : EdgeLabel, to : NodeCap) -> unit
}
```

`Path` is hierarchical: `["home", "santiago", "papers", "paideia.md"]` — a list of named children. `Tag` is a flat label that may appear on many nodes. `Query` is a structured expression (subset of TLA+ / Datalog; details in `design/terminal/semantic-shell.md`, future) producing a stream of matching nodes.

### 7.3 Why this is not POSIX

POSIX paths are unique strings interpreted by the kernel. PaideiaOS paths are *types* in the graph: `Path` is a path-type, not a string. The shell's pipeline (per Q13) passes typed records, not strings; the FS's `resolve_path` consumes a typed path and returns a typed node. The lack of stringly-typed paths eliminates an entire class of bugs (path injection, encoding ambiguity).

### 7.4 Schema registry

Schemas are first-class nodes in the graph. A schema specifies:
- Field names, types, constraints.
- Effect rows for operations on instances.
- Versioning information.

The FS's schema registry is itself a directory of schema nodes; userspace applications register their schemas at install time. The semantic shell uses the registry to type-check pipeline expressions.

### 7.5 Cross-references

A node may have arbitrary outgoing edges to other nodes — not just the canonical parent-child. This makes the graph a *graph*, not a tree. Symlinks, hard links, references in document files (e.g., a paper citing another paper) all become first-class edges.

The Merkle DAG underneath captures the graph structure: a node's hash includes its outgoing edges, ensuring cross-reference integrity.

### 7.6 Persistence under B-epsilon + HAMT

The graph is persisted as:
- **B-epsilon keyspace** maps `(node_id, schema_id)` to the node's content extent.
- **HAMT directories** for each "directory-like" node (where path resolution descends).
- Edge lists are stored inline in nodes (for outgoing edges) or computed via tag indices (for incoming edges, lazily).

---

## 8. Capability model (FS-Q5)

### 8.1 Derived kinds

The FS exposes derived kinds (per CAP-Q3 two-tier) over the base `memory` kind:

| Derived kind | Effect row | Use |
|---|---|---|
| `FileCap` | `!{fs_read, fs_write}` | A linear, mutable file handle. |
| `FileReadOnlyCap` | `!{fs_read}` | An affine, shared-read handle. |
| `DirCap` | `!{dir_lookup, dir_insert, dir_remove, dir_enum}` | Directory operations. |
| `SnapshotCap` | `!{snapshot_read, snapshot_diff}` | A pinned historical root. |
| `SchemaCap` | `!{schema_inspect}` | A schema identity. |
| `TaggedCap` | `!{tag_lookup}` | A tag identity. |

Each derived kind is a functor over the base — the kernel sees one of: `memory`, `ipc-endpoint`, `process` etc.; the type system sees the rich derived hierarchy.

### 8.2 File capabilities are at file granularity

One capability per file; not per-extent. The file's descriptor records the B-epsilon key prefix that identifies its content. Extent access happens *through* the file capability (e.g., `read(file_cap, offset, length)` → bytes); extents are not separately capability-typed.

### 8.3 Directory capabilities are at directory granularity

One capability per directory. Directory operations produce new `DirCap`s representing the new state — the old `DirCap` remains valid for snapshot purposes.

### 8.4 The supervisor's role

The supervisor mints the FS server's initial capabilities at boot: the root `DirCap`, the schema registry's `DirCap`, the tag index's `DirCap`. The FS server derives all other capabilities as clients access them.

### 8.5 Audit integration

Every capability mint/retype/revoke on FS objects emits an audit entry. The audit log records the operation (open file, create directory, delete entry, snapshot pin), the actor, and the affected node hash.

---

## 9. Encryption (FS-Q7)

### 9.1 At-rest encryption via TME-MK

Each FS instance has a TME-MK key-id (encrypted at the DRAM level via Intel TME-MK on Tiger Lake+ client, Sapphire Rapids+ server). All FS-server pages — buffer pool, in-memory B-epsilon nodes, HAMT roots — are mapped with the FS's key-id; physical-memory snooping is defeated.

### 9.2 Per-file encryption via the KEK

Each file has a *file-encryption key (FEK)* generated at file creation. The FEK is wrapped under the *FS key-encryption key (KEK)* using AES-256-GCM. The KEK itself is held in the supervisor's enclave (per PQ-Q5), wrapped at rest by hybrid X25519 + ML-KEM-1024 (per PQ-Q6 universal KEM).

On read: the supervisor unwraps the KEK; the KEK unwraps the FEK; the FS server decrypts the file extent with the FEK; the cleartext is delivered to the client (via the IPC channel, which is then encrypted-in-transit if crossing a host boundary).

### 9.3 Key rotation

The FS's KEK rotates per the supervisor's policy (default: 90 days). Rotation re-encrypts the wrapped FEKs in-place (cheap, ~32 bytes each); the underlying file contents are not re-encrypted (would be cost-prohibitive). Old KEKs remain in the supervisor's enclave for recovery from snapshots.

### 9.4 Forward secrecy

Forward secrecy is not the primary property: KEKs are stored alongside the FS, so a compromise of the supervisor's enclave compromises the past. The defense is at the enclave level (per PQ doc).

### 9.5 Hardware fallback

On hardware without TME-MK, the in-memory pages are unencrypted (the kernel and supervisor are trusted). The signal is logged to the audit channel; the user is informed that the in-DRAM threat model is weaker.

---

## 10. Compression (FS-Q8)

### 10.1 Per-file Zstd opt-in

A file's descriptor records `compression: Option<Algorithm>`. When set, every write is compressed (via Zstd level 3 — fast, decent ratio) before storage; every read decompresses. Extents on disk are post-compression.

### 10.2 Why opt-in

- Compression is a CPU cost; many files (encrypted, already-compressed, random-data) don't benefit.
- Opt-in lets the user choose per file.

### 10.3 Why Zstd

- Best practical compression-vs-speed tradeoff for general data (per the Zstandard project).
- Open algorithm, audit-friendly.
- Implemented in PaideiaOS as an Effect: `!{compress, decompress}`.

### 10.4 Compression and Merkle hashing

The on-disk extent's hash is over the *compressed* bytes (the bytes actually written). Decompression happens after hash verification, so a tampered compressed extent is caught before decompression.

---

## 11. Transactions and commit (FS-Q3 mechanics)

### 11.1 Transaction lifecycle

```
1. begin_txn() — allocate transaction buffer; record start timestamp.
2. Reads — go through the in-memory B-epsilon spine; Merkle-verified.
3. Writes — buffered in the transaction's pending message list.
4. The writes accumulate; no on-disk changes yet.
5. commit_txn() —
   a. The transaction's messages are merged into the B-epsilon root's buffer.
   b. The new root is computed (CoW path-copying as buffers cascade).
   c. The new HAMT directories are computed (for any dir operations).
   d. All new nodes are written to fresh extents (CoW).
   e. The new superblock is constructed with the new root hash.
   f. PQ signing of the superblock (SLH-DSA-128s).
   g. Superblock written to the next ring slot.
   h. Commit barrier (sfence + writeback).
   i. The commit is durable; the audit log records the event.
```

### 11.2 Commit cadence

Commits happen on:
- Explicit `commit_txn()` from the client.
- Periodic timer (default every 30 seconds).
- Memory-pressure-driven (when buffer pool fills, force a commit to free buffers).
- Shutdown (final commit before unmount).

### 11.3 Aborts

A transaction can abort: the pending message list is discarded; no on-disk changes occurred; the in-memory state is unchanged. Aborts are free (no rollback needed; CoW means writes never landed).

### 11.4 Concurrent transactions

Multiple transactions can be in-flight; each has its own buffer. At commit time, the transaction's writes are applied to the current root, and the new root supersedes. Conflicts (two transactions modifying the same key) are resolved by the transaction system's policy (last-writer-wins by default; configurable per FS).

### 11.5 Snapshot isolation

A read in a transaction sees the FS state as of the transaction's start; it does not see commits from concurrent transactions. This is *snapshot isolation* (Berenson et al., 1995); it provides strong consistency while allowing high concurrency.

---

## 12. Recovery (FS-Q9)

### 12.1 The recovery flow

On FS mount:
1. Read all 64 superblock slots.
2. Find the highest-timestamp slot with a verified signature.
3. Verify the Merkle root: recompute root hash from the on-disk root node; compare to the superblock's recorded root hash.
4. If both verifications pass, the FS is mounted at that root.
5. If the latest valid superblock is older than the audit log's last recorded commit, replay any unrecorded commits (none should normally exist; this is the post-crash gap).

### 12.2 Online verification

After mount, every read verifies the Merkle chain to the touched leaf. Background verification (a periodic walker) checks the whole tree at low priority.

### 12.3 No offline fsck

PaideiaOS does not ship an offline fsck. The CoW + Merkle structure means corruption is detected at read time; partial corruption (one bad extent) is contained by Merkle (only descendants of the bad node are affected; the rest is recoverable).

### 12.4 Replication recovery (phase 3+)

Multi-device pool support (FS-Q10) adds replication: each extent is stored on N devices; a Merkle mismatch at one device triggers automatic recovery from a healthy replica. This is the standard ZFS / bcachefs pattern, deferred until phase 3+.

### 12.5 Snapshot rollback

The supervisor's policy may rollback to a snapshot (per `snapshot_restore`); useful for "the system was just compromised; restore to last known good".

---

## 13. paideia-as implementation

### 13.1 Module layout

`src/userspace/fs-cow/` is the FS server:

```
src/userspace/fs-cow/
├── server.s              # main loop, IPC entrypoints
├── b_epsilon.s           # B-epsilon tree implementation
├── hamt.s                # HAMT directory implementation
├── extent.s              # extent allocator (per-NUMA per-device)
├── merkle.s              # BLAKE3 hashing, verification
├── pq_sign.s             # SLH-DSA-128s signing interface
├── txn.s                 # transaction manager
├── superblock.s          # superblock ring management
├── graph.s               # typed name-resolution graph
├── schema.s              # schema registry
├── tag.s                 # tag index
├── tme_mk.s              # TME-MK key-id binding
├── zstd.s                # Zstd compression
└── effects.s             # Fs effect declarations + handler
```

### 13.2 Phase-1 vs. phase-2 split

Phase 1 (NASM bootstrap):
- A simplified FS: write-once log structured (no B-epsilon, no HAMT, no CoW); single-writer.
- BLAKE3 verification.
- Per-superblock signing.
- Supports just enough for kernel boot: read the loader from disk, sign-verify, jump.

Phase 2 (paideia-as coexistence):
- B-epsilon tree spine.
- HAMT directories.
- Typed name-resolution graph (basic, hierarchical only; no tag attributes yet).
- Per-transaction commit + PQ signing.
- TME-MK + ML-KEM-1024 KEK.
- Single-device only.

Phase 3+ (paideia-as canonical):
- Multi-device pool.
- Tag attributes and cross-references in the graph.
- Snapshot diff/rollback.
- B-epsilon buffer-flush optimization tuning.
- Online integrity walker.

### 13.3 Calling convention

FS ops dispatch through R15's effect environment per Q-A3. R12 carries the file/dir cap; R13 carries the operation argument.

---

## 14. Performance budget

| Operation | Budget | Substrate |
|---|---|---|
| Single-file read (4 KiB, cache hit) | ≤ 1 µs | bare-metal Sapphire Rapids + NVMe |
| Single-file read (cold) | ≤ 50 µs | bare-metal + NVMe |
| Single-file write (4 KiB, buffered) | ≤ 2 µs | bare-metal |
| Transaction commit (small) | ≤ 100 ms | bare-metal (dominated by SLH-DSA-128s) |
| Transaction commit (large) | ≤ 200 ms | bare-metal |
| Directory lookup (HAMT, 1M entries) | ≤ 5 µs | bare-metal |
| Snapshot creation | ≤ 10 µs | bare-metal |
| Snapshot diff (modified subset) | proportional to modified hashes | bare-metal |
| Merkle verification per node | ≤ 50 ns | bare-metal AVX-512 BLAKE3 |
| BLAKE3 throughput | ≥ 2 GB/s per core | bare-metal AVX-512 |
| Compression (Zstd lv 3) | ≥ 500 MB/s per core | bare-metal |

Aspirational; baselines come from `design/filesystem/perf-baselines.md` (future).

---

## 15. Open issues

| ID | Issue | Resolution |
|---|---|---|
| FS-O1 | TLA+ spec for the B-epsilon tree under PaideiaOS discipline — phase-2 deliverable; the trickiest is the buffer-flush recovery semantics. | `design/filesystem/b-epsilon.tla` (future) |
| FS-O2 | TLA+ spec for the HAMT directory under crash semantics. | `design/filesystem/hamt.tla` (future) |
| FS-O3 | The typed name-resolution graph's query language — Datalog subset? TLA+ subset? Project-specific? | `design/terminal/semantic-shell.md` (future, links here) |
| FS-O4 | Schema versioning and migration — how do schemas evolve while preserving historical data validity? | `design/filesystem/schema-evolution.md` (future) |
| FS-O5 | The B-epsilon parameter `ε` — concrete value selection based on workload measurement. | `design/filesystem/b-epsilon-tuning.md` (future) |
| FS-O6 | Multi-device pool semantics for phase 3+ — mirror, RAID-Z-equivalent, erasure-coded. | `design/filesystem/multi-device-pool.md` (future) |
| FS-O7 | Compression algorithm catalog beyond Zstd — should LZ4 (faster) and XZ (denser) be offered? | `design/filesystem/compression-catalog.md` (future) |
| FS-O8 | Snapshot retention policy — automatic GC of unpinned snapshots vs. supervisor-driven. | `design/filesystem/snapshot-gc.md` (future) |
| FS-O9 | Cross-FS file movement — when copying between two PaideiaOS FS instances, can Merkle subtrees be transferred whole? | `design/filesystem/cross-fs-copy.md` (future) |
| FS-O10 | The audit log's location — is the audit log itself an FS file (recursive), or a separate underlying log? | `design/audit/log-structure.md` (future) |
| FS-O11 | Persistent-memory (PMem) backing for the buffer pool — can a `PersistentMemCap` (per MEM-Q10) accelerate transactions? | `design/filesystem/pmem-buffer.md` (future) |
| FS-O12 | The FS's interaction with capability revocation — if a `FileCap` is revoked while the file has open writes from another holder, what happens? | TLA+ spec |
| FS-O13 | Phase-1 fallback FS — design the write-once log structure for boot needs only. | `design/filesystem/phase1-bootfs.md` (future) |
| FS-O14 | Performance baselines — first bare-metal measurements drive `perf-baselines.md`. | `design/filesystem/perf-baselines.md` (future) |
| FS-O15 | The scope realism question — is the phase-2 milestone achievable in 24 months given B-epsilon novelty? | `design/filesystem/milestones.md` (future, links to assembler milestones) |
| FS-O16 | Network FS story — D14 distributed capabilities may include a remote FS protocol. | revisit at phase 3+ |

---

## 16. References

### 16.1 B-epsilon and write-optimized data structures

- Brodal, G., Fagerberg, R. *Lower Bounds for External Memory Dictionaries*. SODA 2003.
- Bender, M. A., Farach-Colton, M., Fineman, J. T., Fogel, Y. R., Kuszmaul, B. C., Nelson, J. *Cache-Oblivious Streaming B-trees*. SPAA 2007 (foundational Bε-tree).
- Bender, M. A. et al. *An Introduction to Bε-trees and Write-Optimization*. login: Magazine, Oct 2015.
- *TokuDB / Fractal Tree Index*. Tokutek / Percona technical documentation.

### 16.2 HAMT and persistent functional data structures

- Bagwell, P. *Ideal Hash Trees*. EPFL technical report, 2000.
- Steindorfer, M. J., Vinju, J. J. *Optimizing Hash-Array Mapped Tries for Fast and Lean Immutable JVM Collections*. OOPSLA 2015.
- Hickey, R. (Clojure community) — extensive practical experience with HAMT in immutable collections.

### 16.3 Filesystems

- McKusick, M. K. et al. *A Fast File System for UNIX*. TOCS 2(3), 1984. (Reference for cylinder groups and locality.)
- Rosenblum, M., Ousterhout, J. K. *The Design and Implementation of a Log-Structured File System*. TOCS 10(1), 1992.
- Hitz, D., Lau, J., Malcolm, M. *File System Design for an NFS File Server Appliance*. WTEC 1994 (WAFL).
- Bonwick, J., Ahrens, M., Henson, V., Maybee, M., Shellenbaum, M. *The Zettabyte File System*. FAST 2003 (ZFS).
- Rodeh, O. *B-trees, Shadowing, and Clones*. ACM Transactions on Storage 3(4), 2008 (btrfs theory).
- Overstreet, K. *bcachefs* design documentation (ongoing).

### 16.4 Merkle structures and integrity

- Merkle, R. C. *A Digital Signature Based on a Conventional Encryption Function*. CRYPTO 1987.
- Bonwick, J. *ZFS End-to-End Data Integrity*. Sun blog (informative).

### 16.5 Hashing

- O'Connor, J., Aumasson, J.-P., Neves, S., Wilcox-O'Hearn, Z. *BLAKE3: One Function, Fast Everywhere*. 2020.

### 16.6 Compression

- Collet, Y. *Zstandard*. RFC 8478, 2018.

### 16.7 Persistence and ACID

- Berenson, H. et al. *A Critique of ANSI SQL Isolation Levels*. SIGMOD 1995.
- Lampson, B., Sturgis, H. *Crash Recovery in a Distributed Data Storage System*. (Foundational recovery semantics.)

---

*End of document.*
