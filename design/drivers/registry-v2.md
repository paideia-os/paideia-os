# Driver registry v2 — versioned schema + on-disk layout

Status: landed R29.M3-001 (#1028) + R29.M3-002 (#1029) + R29.M3-003
(#1030) + R29.M3-004 (#1031).
Supersedes: the implicit "v1" registry (the volatile `_driver_table` rows
of `src/kernel/core/driver/driver_table.pdx`, which carry no version tag
and never leave RAM).

## 1. Why a versioned, persisted registry

`_driver_table` is runtime state: 32 rows of `{state, in_use, pid,
name[16], caps_manifest_offset}`, rebuilt from scratch on every boot. It
answers "what is driver 7 doing right now"; it cannot answer "what was
driver 7 *allowed* to do, and who said so". The supervisor needs the
second question answered *before* it launches a driver process, and the
answer must survive reboot and be attributable.

Registry v2 is that durable artifact: for each installed driver, its
name, its semantic version, the capability manifest it is entitled to
(the KIND_HW family bitmap), and the effect row the elaborator proved
for it (the same row the cap-vs-effect walker C1301 enforces at compile
time — see `tests/kernel/drivers/elaborator/`). The file is versioned at
the head so a future schema change is a migration, not a corruption, and
signed at the tail so a tampered registry is detectable before any
capability is minted from it.

The issue title says "cap'n proto persisted". Paideia has no Cap'n Proto
elaborator support and will not grow one for a kernel-resident format;
what is borrowed is the *property* Cap'n Proto is wanted for — a
field-order-stable, offset-addressable record encoding with no parse
step. Every field below sits at a frozen byte offset; decoding is a load,
not a walk.

## 2. On-disk layout

```
   /system/registry/drivers.pdxreg
   +---------------------------------------------------------------+ 0
   |                          HEADER  (32 B)                        |
   |  +0   u32  magic          'P''D''X''R'  = 0x52584450 (LE)      |
   |  +4   u16  schema_version = 2                                  |
   |  +6   u16  header_bytes   = 32                                 |
   |  +8   u32  record_bytes   = 96                                 |
   |  +12  u32  record_count   = N   (0 <= N <= 32)                 |
   |  +16  u64  flags          = 0   (reserved)                     |
   |  +24  u64  content_checksum  (xorshift over records[0..N))     |
   +---------------------------------------------------------------+ 32
   |                        RECORD 0  (96 B)                        |
   |  +0   u64  header:  [7:0] driver_table_slot                    |
   |                     [15:8] lifecycle_state                     |
   |                     [23:16] record_flags (bit0 = valid)        |
   |                     [31:24] reserved                           |
   |                     [63:32] pid (u32)                          |
   |  +8   u64  name[0..7]     NUL-padded, byte-identical to the    |
   |  +16  u64  name[8..15]    driver_table row's name field        |
   |  +24  u64  driver_version [15:0] patch [31:16] minor           |
   |                           [47:32] major [63:48] reserved       |
   |  +32  u64  cap_manifest_lo   KIND_HW-family entitlement bitmap |
   |  +40  u64  cap_manifest_hi   reserved for kinds >= 64          |
   |  +48  u64  effect_row        elaborator-proved effect bitmap   |
   |  +56  u64  caps_manifest_offset  (mirrors driver_table [+8])   |
   |  +64  u64  reserved                                            |
   |  +72  u64  reserved                                            |
   |  +80  u64  reserved                                            |
   |  +88  u64  record_checksum   xorshift over record[0..88)       |
   +---------------------------------------------------------------+ 128
   |                        RECORD 1 .. RECORD N-1                  |
   +---------------------------------------------------------------+ 32+96N
   |                    SIGNATURE BLOCK  (3325 B)                   |
   |  +0   u32  sig_magic  'P''D''S''G' = 0x47534450 (LE)           |
   |  +4   u16  sig_alg    = 1 (ML-DSA-65)                          |
   |  +6   u16  reserved   = 0                                      |
   |  +8   u64  sig_bytes  = 3309 (ML-DSA-65 signature length)      |
   |  +16  u8[3309]  signature — ALL ZERO at R28..R31 (scaffold)    |
   +---------------------------------------------------------------+ 3357+96N
```

Total file size is exactly `32 + 96*N + 3325` bytes. At the R29.M3 cap of
`N = 32` that is 6429 bytes — inside tmpfs's 64 KiB per-inode ceiling but
well past its 4 KiB single-page write primitive, hence the chunked
persistence loop of §4.

## 3. Versioning strategy

`schema_version` is the *first* field after the magic, so a reader that
knows nothing else about the file can still branch on it after an 8-byte
load. `header_bytes` and `record_bytes` follow it, so a v3 reader can
skip a v2 header of a different size and stride v2 records without a
compiled-in constant. That triple — version, header stride, record
stride — is the whole forward-compatibility contract; everything else is
version-specific.

Migration rules:

- **Additive change** (new field into a `reserved` slot): `schema_version`
  is *not* bumped. Old readers see the field as reserved and ignore it;
  the reserved bytes are specified as zero, so an old writer producing a
  file an new reader consumes yields the field's zero value, which every
  new field must define as its "unset" semantics.
- **Any change to an existing field's offset, width, or meaning, or any
  growth of `record_bytes`**: `schema_version` bumps, and the writer for
  the new version must be able to read the previous one. Registry v2 reads
  v1 by construction — v1 was never persisted, so "migration from v1" is
  a cold build of the v2 file from the live `_driver_table` rows, which is
  what `registry_v2_record_encode` does.
- A reader MUST reject a file whose `schema_version` exceeds the one it
  was built for. Silently ignoring unknown-version records would let a
  downgrade attack strip entitlements.

## 4. Persistence discipline

`/system/registry/drivers.pdxreg` lives on tmpfs in the QEMU smoke path,
seeded by the boot witness exactly as the audit-log bridge seeds
`/system/audit/log.pdaudit` (see `src/kernel/core/klog/audit.pdx`). The
registry code never names a path or a backend: it holds an **inode
index** in `_registry_persist_inode` and issues raw `tmpfs_read` /
`tmpfs_write` against it. When a later round mounts pdxfs-lite at boot,
the seeding witness points the same slot at the persistent inode and
every call site above it is unchanged. That indirection is the entire
FS-agnosticism story, and it is deliberately the same one the audit
bridge uses.

**Chunked I/O.** `tmpfs_write` and `tmpfs_read` are single-page
primitives — they reject any request whose byte range crosses a 4 KiB
boundary. `registry_persist_write` / `registry_persist_read` therefore
loop, issuing `min(remaining, 4096 - (offset & 4095))` bytes per call.
This is not a workaround: a page-at-a-time loop is what a real backend
wants anyway, and it makes the registry size limit a property of the
inode ceiling (64 KiB) rather than of the write primitive.

**Shadow write.** A registry that is half-written when the machine dies
is worse than one that is absent: it parses, and it under-states
entitlements. `registry_persist_publish` therefore writes the full image
to a shadow inode (`drivers.pdxreg.new`), reads it back, runs the fsck
validator against the read-back bytes, and only then writes the live
inode and re-validates. The crash window shrinks to the live write
itself. A true atomic swap needs a directory `rename`, which tmpfs does
not implement (R16.M2 shipped create/lookup/read/write/unlink only) and
which is meaningless on a volatile backend regardless; the swap lands
with pdxfs-lite's `rename` (`src/kernel/core/fs/pdxfs_lite/rename.pdx`)
when the registry moves to that backend, and `publish` is the single
function that changes.

**fsck.** `registry_v2_validate` is the checker, run against an in-memory
image (live buffer or read-back scratch). It walks, in order: magic;
`schema_version`; `header_bytes` / `record_bytes` geometry; `record_count`
bound; every record's `record_checksum`; the header's
`content_checksum`; the signature block's magic, algorithm, and declared
length; and — at R28..R31 only — that the signature body is all zero.
Each failure has its own return code in the `0xFFFFFD0x` space so a
boot-log triage names the failing stage without a debugger.

## 5. Signature discipline

The signature covers the header and all records — bytes `[0, 32+96N)` —
and nothing of itself. It is emitted as ML-DSA-65 (`sig_alg = 1`,
3309-byte signature) by the same signing substrate the EFI image uses,
and follows the same staging: R28 through R31 write an **all-zero
signature body** and readers verify only that the block is present,
well-formed, and zero. This is the identical scaffold posture as
`tools/sign-efi.sh` — the layout, the length, and the algorithm tag are
frozen *now* so that turning on real signing later changes one function
and zero offsets, and so that a file produced today is byte-layout
compatible with a verifying reader shipped later.

An all-zero signature is never treated as "valid" — it is treated as
"unsigned, scaffold epoch". When real signing lands, the reader flips
from "assert zero" to "assert verify", and any file still carrying zeros
fails. There is no configuration knob between those two states.

## 6. Boot witness

`src/kernel/boot/kernel_main.pdx` §`registry_v2_witness` is the in-tree
proof, emitting `R29 REGISTRY V2 OK` into the boot fingerprint. It runs
after the audit-bridge witness (which is what creates `/system` on
tmpfs), seeds `/system/registry/{drivers.pdxreg,drivers.pdxreg.new}`,
binds both inode indices, registers two drivers into the driver table
(`uart-16550` pid 7 driven to `Running`; `nvme-pcie` pid 9 left at
`Init`), encodes and seals a two-record image, publishes it shadow-first,
loads it back, and asserts:

- the read-back image is **byte-exact** against the live image across all
  3549 bytes (`registry_persist_compare == 0`);
- every decoded field round-tripped — slot, lifecycle state, valid flag,
  pid, packed version, capability manifest, effect row, manifest offset,
  for both records;
- record 0's `name_lo` equals the first qword of the *original* 16-byte
  name literal, so the assertion is about the input, not merely about
  self-consistency;
- the signature block is present and well-formed: `PDSG` magic, `sig_alg`
  1, declared length 3309, body zero.

Five failure edges follow, run against the read-back copy (a throwaway
verification target, restored afterwards, with a final clean re-validate
proving the restoration): corrupted magic → `ERR_BAD_MAGIC`; corrupted
record byte → `ERR_REC_CHECKSUM`; non-zero signature body →
`ERR_SIG_NOT_ZERO`; `record_encode` at index 32 → `ERR_BAD_INDEX`;
`publish` with count 33 → `ERR_TOO_MANY`. A stage counter
(`_registry_v2_witness_stage`, 0..26) is written before every gate so a
failure prints which sub-test tripped without a debugger.

## 8. Lookup + hot-reload

`src/kernel/core/driver/registry_lookup.pdx`.

### 8.1 The two lookups

```
registry_lookup_by_name(image_ptr, name_ptr, name_len) -> record_index
registry_lookup_by_slot(image_ptr, slot)               -> record_index
```

Both return a **record index** (0..31) on a hit and `ERR_NOT_FOUND`
(`0xFFFFFD40`) on a miss. Index 0 is a legitimate answer, so "not found"
cannot be zero; the `0xFFFFFD4x` codes sit far outside the index range
and every caller separates them with one `cmp rax, 32; jae`.

Both take the image base as their first argument rather than implicitly
addressing the live buffer. That is not gratuitous generality: the
reload conflict scan of §8.3 must look a slot up in the *candidate*
image while reading the live one, and a buffer-implicit lookup could not
express that. It is also the convention `registry_v2_record_addr` and
`registry_v2_field` already follow.

The record index and the `driver_table_slot` are deliberately different
numbers. An image may hold a subset of the table's rows in any order —
`registry_v2_record_encode` takes both as independent arguments — so
`lookup_by_slot` is the function that turns the runtime key into the
record key. Callers that hold a slot and want a field do
`registry_v2_field(image, registry_lookup_by_slot(image, slot), off)`.

**Name matching is exact, not prefix.** After the caller's `name_len`
bytes compare equal, the record's byte at `[name_len]` must be NUL
(unless `name_len` is the full 16). Without that terminator check
`"uart"` would match `"uart-16550"` and a supervisor asking for a short
name would be handed a different driver's entitlements — the single most
dangerous way this function could be wrong. A `name_len` of 0 or above 16
is `ERR_BAD_NAME` (`0xFFFFFD41`) rather than a miss: zero would match the
NUL padding of every record, and a key wider than the field is a
malformed request.

Records without the valid flag (record header bit 16) are skipped by both
lookups; an invalid record's fields are not meaningful.

Both scans are linear over `record_count`. At the 32-record cap that is
at most 32 × 16 byte compares. An index would have to be rebuilt on every
generation bump and kept coherent across reload and rollback — more
machinery to keep correct than the scan could ever save at this scale.

### 8.2 The generation id

`registry_gen_id()` returns a monotonic counter, starting at 0, bumped
once per **adoption of new content**: a reload that changed something, or
a rollback. It is never reset, so two observations are always orderable.

A consumer that cached a record index or a manifest bitmap compares the
generation it captured against the current one and learns in a single
load that its cache is stale. Nothing else in the registry answers that
cheaply — the content checksum changes for benign reasons and is not
ordered, so it can say "different" but never "newer". When SMP arrives,
this counter is also the seqlock sequence the module will need.

### 8.3 Hot-reload and the RUNNING-conflict rule

```
registry_reload(count) -> OK | ERR_RELOAD_CONFLICT | <fsck/IO code>
```

Sequence:

1. `registry_persist_load(count)` — read the live file into scratch and
   fsck it. An image that fails fsck is never diffed, never compared
   against, and never adopted.
2. **Diff scan**, candidate vs live, record by record. A `record_count`
   mismatch counts as "every record changed" — the geometry itself moved.
   The differing-record count is published in `registry_reload_changed()`.
3. **No-op early-out.** If nothing differs: return OK, touching no
   memory and bumping no generation. A supervisor may poll the file as
   often as it likes and pay only the read plus one 96-byte-per-record
   compare. This is what makes the reload *incremental* rather than a
   periodic wholesale overwrite, and it is also why the conflict scan can
   never false-positive: a record that did not change cannot conflict.
4. **Conflict scan** (§below).
5. **Adopt**: bulk-copy the candidate over the live buffer, re-fsck the
   result, bump the generation.

Step 5 re-fscks bytes that step 1 already fscked. The copy is the only
operation between them, and the second validate is the difference between
"the copy is correct" and "the copy was believed correct", for one pass
over at most 6432 bytes on a path that just did file I/O.

**The rule.** A reload rewrites the entitlement record of drivers that
may be executing. The registry answers "what is this driver allowed to
do"; changing that answer under a driver already exercising the old
answer is a capability-safety violation, not a configuration update.
So:

> For every record in the **live** image whose `driver_table_slot` is
> currently in `DRIVER_STATE_RUNNING` (per the R29.M2 FSM, read through
> `driver_lifecycle_get_state`), the candidate image must contain a
> record for that slot whose `cap_manifest_lo`, `cap_manifest_hi` and
> `effect_row` are byte-identical. Any violation rejects the **whole**
> reload with `ERR_RELOAD_CONFLICT` (`0xFFFFFD42`) and leaves the live
> image byte-untouched.

Disappearance counts as a violation: dropping a RUNNING driver's record
is a silent revocation of everything it holds, which is strictly worse
than changing one bit of it.

Records whose slot is `INIT`, `SUSPENDED`, `HANDOFF`, `STOPPING`,
`STOPPED`, or absent from the table entirely apply freely. Nothing is
executing against them, so the new content simply becomes the truth the
supervisor will use at the next launch — which is what a hot-reload is
for.

Only those three fields are conflict-relevant. `driver_version` and
`name` are descriptive; `pid` and `lifecycle_state` are snapshots of the
table, which is authoritative for them (§7). None of them is a field a
capability is minted from, so all four may change under a RUNNING driver.

The rejection is all-or-nothing rather than per-record. A partially
applied reload would leave the image in a state no writer ever produced
and no signature ever covered; "some of your change landed" is not a
result a supervisor can act on.

**Deferred.** Nothing here quiesces a driver in order to *make* a
conflicting reload legal. That is a supervisor-level protocol —
`STOPPING` → `STOPPED` → reload → relaunch, driven through the R29.M2
FSM — and it is exactly what the caller should do when it sees
`ERR_RELOAD_CONFLICT`. The registry's job is to refuse, not to
orchestrate.

## 9. Snapshot + rollback

`src/kernel/core/driver/registry_snapshot.pdx`.

```
registry_snapshot()            -> snapshot_id (>= 1) | <fsck code>
registry_rollback(snapshot_id) -> OK | ERR_BAD_SNAPSHOT | <fsck/IO code>
```

Every mutation of the registry changes what drivers are entitled to, and
some mutations are wrong in ways only discovered afterwards — a driver
that will not start, a manifest that fails the cap-vs-effect check at
launch, a signature that will not verify once real signing lands.
Rollback is the escape hatch: capture a known-good sealed image before
the risky step, restore it after.

`registry_snapshot` takes no count argument. The image is
self-describing — `record_count` is in its header — and asking the caller
to restate a number the artifact already carries is an opportunity for
the two to disagree. It fscks the live image **before** capturing it: a
snapshot of a malformed image is an undo button that restores
corruption, which would make rollback the thing that broke the machine.

### 9.1 Where the ring lives, and why

The ring is **.bss** — 4 × 6432 = 25728 bytes of kernel image — not
tmpfs files and not a second registry directory.

A snapshot stored on the same filesystem as the artifact it protects
shares that artifact's failure domain. The scenarios rollback exists for
include "the registry file is corrupt", "the write path is misbehaving",
and "the FS is not mounted yet"; in all three a tmpfs-resident snapshot
is either unreachable or itself suspect at exactly the moment it is
needed. .bss is reachable before any mount, cannot be truncated by a
failing write path, and costs one fixed allocation known at link time
rather than an inode budget competing with the rest of `/system`.

The price is that snapshots do not survive reboot. That is the right
trade: a snapshot is a short-lived undo buffer for an in-progress
reconfiguration, while cross-boot durability is what the persisted file
itself provides. Nothing here substitutes for the file; everything here
substitutes for rebuilding the file by hand after a bad step.

### 9.2 Why four slots, and why a ring

Depth 4 covers the supervisor's realistic nesting — one snapshot before
a hotplug batch, one before the reload that batch triggers, one before a
manual repair, one spare — at 25 KiB. Depth 2 would make the third
concurrent operation lose its baseline; depth 8 doubles a fixed .bss cost
for a nesting level no caller in R29 can produce.

It is a **ring**, not a stack, because eviction must be deterministic and
silent. With a ring, taking a fifth snapshot always succeeds and always
evicts the oldest, and a caller holding an evicted id learns so from
`ERR_BAD_SNAPSHOT` at rollback time. With a stack, the fifth snapshot
would have to fail — turning a bookkeeping limit into a failed operation
at the worst possible moment.

Snapshot ids are monotonic from 1 and never reused. `slot = (id - 1) & 3`
locates the candidate slot and the id stored there must match **exactly**,
so a stale id fails closed rather than aliasing onto a newer snapshot.
Id 0 is the empty-slot marker, so it is never a valid id and needs no
separate occupancy bitmap. `registry_snapshot_init` clears the id and
count arrays explicitly rather than relying on .bss zeroing, because the
empty encoding is a correctness invariant: a slot whose id happened to
hold garbage matching a caller's id would hand back an arbitrary
6432-byte buffer as a registry image. The image bytes themselves are not
cleared — they are unreachable while their id is zero.

### 9.3 Rollback goes through the existing publish path

`registry_rollback`:

1. `id != 0` and `_registry_snapshot_ids[(id-1) & 3] == id`, else
   `ERR_BAD_SNAPSHOT` (`0xFFFFFD50`). One equality covers "never
   existed", "already evicted" and "id 0".
2. fsck the snapshot **in the ring**, before it is copied anywhere. The
   live buffer is therefore only ever overwritten with an image that has
   just passed validation, so a failed rollback leaves the current image
   intact — the same preserve-on-failure posture as every other mutator
   in this family.
3. copy ring → live buffer;
4. `registry_persist_publish(count)` — the §4 path, unmodified: shadow
   write, read back, fsck, live write, re-fsck;
5. bump the generation (§8.2), because content a consumer may have
   cached has just been replaced.

There is deliberately **no second write path**. A rollback-specific
writer would be the only writer in the system never exercised by the boot
witness, and it would be reached only when something had already gone
wrong.

### 9.4 Witness

`src/kernel/boot/kernel_main.pdx` §`registry_lookup_witness`, emitting
`R29 REGISTRY LOOKUP OK`, 36 sub-tests. It runs immediately after
`registry_v2_witness` and reuses only the files that witness created; it
re-registers both drivers and rebuilds, seals and publishes the two-record
image itself, so it stands alone.

Coverage: lookup by name (two hits, prefix miss, absent miss, over-long
key), lookup by slot (two hits, in-range miss, out-of-range miss); a
no-op reload proving `registry_reload_changed() == 0` and no generation
bump; snapshot → mutate record 1 → publish → rollback, with the mutation
proven gone **both** in the live image and in the re-read file (which is
what proves rollback went through `publish` rather than only touching
memory) and a clean post-rollback fsck; two `ERR_BAD_SNAPSHOT` edges
(never-issued id, id 0); a conflicting reload against RUNNING slot 0
returning `ERR_RELOAD_CONFLICT` with the live image proven untouched; a
non-conflicting reload against INIT slot 1 adopted with exactly one
changed record; and a final `registry_gen_id() == 2` asserting that
precisely two adoptions occurred — the rollback and the adopted reload,
and neither the no-op reload nor the refused one.

Stages 29 and 33 are the load-bearing trick: `record_encode` and `seal`
are memory-only, so they produce a live image that deliberately disagrees
with the file *without* going through `publish`. That is the only way to
hand `registry_reload` a candidate that differs from the live view, and
it is what a real out-of-band registry edit would look like.

## 10. Coupling to the rest of R29

- **`driver_table.pdx`** — a record's `driver_table_slot`,
  `lifecycle_state`, `pid`, `name`, and `caps_manifest_offset` are read
  *from* the live row at encode time. The registry is a projection of the
  table plus the two fields the table does not carry (version, manifest
  bitmaps).
- **`lifecycle.pdx`** — `lifecycle_state` is snapshotted, not authoritative;
  on load, the supervisor re-registers the driver into `DRIVER_STATE_INIT`
  and drives the FSM forward. Persisting the state byte is for forensics
  ("this machine died with the NVMe driver in Handoff"), not for resume.
- **cap-vs-effect walker (C1301)** — `effect_row` is the elaborator's
  answer, recorded. A supervisor that mints a capability outside
  `cap_manifest_lo` for a driver whose `effect_row` does not claim the
  matching effect is committing the error C1301 catches at compile time;
  R29.M4 wires the runtime half against this field.
