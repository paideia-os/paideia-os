# Driver registry v2 — versioned schema + on-disk layout

Status: landed R29.M3-001 (#1028) + R29.M3-002 (#1029).
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

## 7. Coupling to the rest of R29

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
