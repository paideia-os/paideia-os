# Audit-log discipline for every command (R139.M3)

Issue: paideia-os#2641
Wave:  UMB-W21
Lands: 2026-10-14

## 1 Why

Three dispatch surfaces now land commands into the kernel:

- the in-process REPL (R127.M5+ shell parent on the local tty),
- the R135 WASI-jail supervisor (sandboxed userspace binaries),
- the R137 remote-shell daemon (post-quantum KEM handshake, then
  commands flow over the authenticated channel).

Each one dispatches an opaque "command" — a tuple of
`(session_id, pid, cmd_hash, argv_hash, cap_env_fingerprint)` —
and each one lives in a different source file with a different
local hook pattern. The question R139.M3 answers is: _can a single
audit substrate underwrite every one of those paths, so that a
later forensic query (did this command run? under what cap-env?
with what exit?) is answered by one data source rather than three_
— and can that substrate be forgery-resistant by construction,
so that a kernel-level attacker who overwrites a record cannot
hide the overwrite?

The answer is yes, and the substrate is the BLAKE3-chained
`cmd_audit` log introduced here. R127.M7's history_facts fact
ring exists already but is explicitly SCRATCH — 64-byte rows,
silently evicted at 128 per session, no hash, no append-only
discipline. `cmd_audit` is the parallel audit-shaped substrate:
128-byte records, 128 slots in-RAM at M3, BLAKE3-chained so any
post-hoc tampering with record N breaks every subsequent record's
`prev_hash` match.

Design posture (`feedback_novel_clean_design`): POSIX syslog's
audit facility (`auditd` + `/var/log/audit/audit.log` + `ausearch`)
is retired. The kernel owns the audit substrate end-to-end, the
chain is first-class (not a bolt-on log forwarder), and the
record carries the cap-env fingerprint — a reach POSIX auditd has
no name for. The log is forgery-resistant by construction, not by
convention (unlike auditd's "trust the admin's chmod" posture).

## 2 Non-goals (deferred to M4+)

M3 is an in-RAM substrate with a direct-call API. The following
are explicitly out of scope:

1. **Cross-boot persistence.** The pool lives in `.bss` and is
   zeroed on every warm boot. **R139.M4** lands the pdxfs spill —
   on begin, record is written to RAM; on end, finalized record
   is appended to `/system/audit/cmd_audit.pdxlog`; on reboot,
   the on-disk tail is replayed into the ring so the chain
   continues unbroken across the boot boundary.

2. **SMP serialization.** `_cmd_audit_seq` is pre-incremented
   without a lock; on single-core (R18) this is race-free. On
   SMP (R14+) two concurrent `_cmd_audit_begin` calls could
   observe the same seq and overwrite the same slot. **R139.M5**
   lands the atomic-xadd on `_cmd_audit_seq` and a per-slot
   write-lock bit (CA_FLAG_WRITING = 0x4) to serialize concurrent
   finalisers.

3. **KIND cap-invoke op surface.** The direct-call API is the
   only reach at M3. **R139.M6** adds a `KIND_SHELL_SESSION
   CMD_AUDIT_VERIFY` op that forwards an audit token to
   `_cmd_audit_verify` from userspace witnesses (e.g. a
   `veraudit` userland tool that walks the log and asserts
   every record's chain integrity).

4. **Compaction / rotation.** The ring is a fixed 128 slots in
   RAM. **R139.M7** lands a background compactor that spills
   finalized records to pdxfs in batches of 32 and reclaims
   slots.

5. **Chain-prefix cross-boot verification.** On M3, if a reboot
   happens between record N's `_end` and the next boot, record
   (N+1) at the next boot cannot verify its prev_hash because
   the predecessor's this_hash was zeroed by `.bss` init.
   **R139.M4**'s pdxfs spill addresses this: on boot, the last
   finalized record's this_hash is reloaded into slot 127 and
   `_cmd_audit_seq` is set to the on-disk seq so the next
   `_begin` picks up the chain where it left off.

## 3 Record geometry

```
  per-record stride = 128 bytes                             (shl 7)
  pool              = 128 records x 128 bytes = 16384 B     (shl 14)
```

Backing: `_cmd_audit_pool : [u8; 16384]` in `.bss`, `@align(128)`.
Record N starts at `_cmd_audit_pool + (N << 7)`.

### 3.1 Field layout (128 bytes)

```
  [+0]    seq               u64        monotonic sequence number
                                       (seq==0 reserved; first
                                       begin returns seq=1)
  [+8]    prev_hash         [u8; 32]   BLAKE3-32 of predecessor's
                                       record[0..96]; zero for
                                       genesis (seq==1)
  [+40]   session_id        u32        caller-supplied
  [+44]   pid               u32        task pid at dispatch
  [+48]   cmd_hash          u32        djb2(cmd_bytes) (same as
                                       history_facts for join)
  [+52]   argv_hash         u32        djb2(argv_blob)
  [+56]   cap_env_fp        u64        64-bit fingerprint of the
                                       caller's cap-env at
                                       dispatch
  [+64]   tsc_start         u64        RDTSC at _begin
  [+72]   tsc_end           u64        RDTSC at _end
  [+80]   exit_code         u32        process-exit code (i32
                                       sign-extended on read)
  [+84]   flags             u32        bit 0 = PENDING
                                       bit 1 = FINALIZED
  [+88]   reserved          [u8; 8]    zero at M3; M4 pdxfs blk ptr
  [+96]   this_hash         [u8; 32]   BLAKE3-32 of record[0..96]
                                       (includes prev_hash in the
                                       hashed window)
```

Total: 8+32+4+4+4+4+8+8+8+4+4+8+32 = 128.

### 3.2 Why 128 B (and not 64 or 256)

- 64 B (history_facts stride) is too tight — the BLAKE3 chain
  needs 32 B of prev_hash + 32 B of this_hash just for the chain,
  which would leave 0 B for metadata.
- 256 B would waste cache on dispatch (each `_cmd_audit_begin`
  touches two cache lines rather than one for metadata writes).
- 128 B fits a cache-line pair, lets the metadata half
  ([+40..+88]) stay in one line and the hash half ([+96..+128])
  stay in the other, and keeps the stride a `shl 7` which fits
  as an imm8.

## 4 BLAKE3 chain

Each record is tamper-detectably linked to its predecessor:

```
  this_hash[N] = BLAKE3(record[N].bytes[0..96])
  record[N].prev_hash = this_hash[N-1]   (zero for N==1)
```

The 96-byte prefix includes `prev_hash` at [+8..+40], so this is
identical to the brief's `BLAKE3(prev_hash || record_bytes_minus_
this_hash)` — the prev_hash is inside the hashed window.

### 4.1 One-way integrity

Altering any field in record N (seq, session_id, pid, cmd_hash,
argv_hash, cap_env_fp, tsc_*, exit_code, flags) changes record
N's BLAKE3. For record (N+1)'s prev_hash to still match N's
this_hash after that alteration, the attacker would have to
recompute record (N+1)'s prev_hash too — which recomputes record
(N+1)'s this_hash — which cascades to every subsequent record.
Rewriting the chain requires rewriting EVERY record from the
tampered one forward.

### 4.2 BLAKE3 reach

Via `paideia_crypto_blake3_hash` (satellite-runtime extern-C,
same hook `pdxfs_lite/inode.pdx` uses for inode checksums and
`schema_registry.pdx` uses for schema hashes).

SysV marshalling: `rdi=&data, rsi=len, rdx=&out32`. Return value
is discarded: with non-null out and non-zero len the FFI cannot
fail per paideia-as Blake3::hash docs.

### 4.3 Ring eviction

After 128+1 begins, record 0 is overwritten by record 128.
record (N+128)'s prev_hash is pulled from the slot at
`((N+128-1) & 0x7F)` which is `(N+127) & 0x7F = N-1 & 0x7F`
— the immediately preceding begin's slot. Correct by
construction.

What is NOT recoverable after eviction is the chain prefix cross-
check: `_cmd_audit_verify` of record (N+128) cannot cross-check
prev_hash against record N — N is gone. The verifier handles this
cleanly: if `prev_slot.seq != seq - 1` OR `prev_slot.flags !=
FINALIZED`, the chain-prefix check is SKIPPED (not treated as a
break) because eviction is a legitimate ring-overflow outcome,
not a forgery signal. The self-hash check still fires on every
verify call.

## 5 Public API

### 5.1 `_cmd_audit_begin(session_id, pid, cmd_hash, argv_hash, cap_env_fp) -> token | 0`

Allocate the next record slot and write the dispatch half of the
record. Returns a nonzero opaque token (= the record's seq)
on success, 0 iff the slot being overwritten still has PENDING
set (begin>128 begins without matching ends — pool is logically
full of in-flight records).

Caller contract:

- Caller must hold `cap` (begin writes kernel RAM).
- Caller MUST call `_cmd_audit_end` with the returned token.
  Failing to end leaves the record PENDING, which blocks the
  slot at the next ring cycle (POOL_FULL).
- The token is opaque: the caller MUST NOT inspect its bits.

### 5.2 `_cmd_audit_end(token, exit_code) -> errno`

Finalize the record identified by `token`. Validates the token
(nonzero AND slot.seq == token AND flags & PENDING), captures
`tsc_end`, writes `exit_code` and `flags = FINALIZED`, computes
`this_hash = BLAKE3(record[0..96])` and writes it to
[+96..+128].

Returns `CA_OK` on success, `CA_ERR_BAD_TOKEN` otherwise.

### 5.3 `_cmd_audit_verify(token) -> errno`

Validate the chain prefix for the record identified by `token`.

Two integrity checks:

- **Self-hash:** recompute `BLAKE3(record[0..96])` into
  `_cmd_audit_verify_scratch`, compare 4 qwords against
  `slot.this_hash`. On mismatch → `CA_ERR_CHAIN_BROKEN`.
- **Chain-prefix:** iff the predecessor slot still holds record
  (seq-1) finalized, compare `slot.prev_hash` against
  `prev_slot.this_hash`. On mismatch → `CA_ERR_CHAIN_BROKEN`.
  If the predecessor was evicted, chain-prefix is SKIPPED (not
  a break).

Returns `CA_OK` on success (self-hash OK; chain-prefix OK or
SKIPPED), `CA_ERR_BAD_TOKEN` on bad token / non-finalized slot,
`CA_ERR_CHAIN_BROKEN` on hash mismatch.

## 6 Return code band — 0x2200..0x2202

```
  CA_OK                 = 0
  CA_ERR_POOL_FULL      = 0x2200    (begin: PENDING collision)
  CA_ERR_BAD_TOKEN      = 0x2201    (end / verify: token zero or
                                     slot.seq mismatch or state wrong)
  CA_ERR_CHAIN_BROKEN   = 0x2202    (verify: hash mismatch)
```

Band audit (2026-10-14): `grep -rnE '0x220[0-2]\b' src/kernel/`
yields zero hits. Clean band.

All three codes fit imm32 with bit 31 clear so `mov rax, imm32`
emits the 7-byte zero-extending form.

## 7 Interaction with R127.M7 history_facts

| Aspect             | history_facts (M7)         | cmd_audit (M3)             |
|--------------------|----------------------------|----------------------------|
| Purpose            | query predicates           | tamper-evident audit       |
| Record size        | 64 B                       | 128 B                      |
| Record count       | 1024 (128 x 8 sessions)    | 128                        |
| Eviction           | silent (per-session ring)  | silent (global ring); OOP  |
| Chain hash         | none                       | BLAKE3-32                  |
| Append-only        | no (silent evict)          | yes (slots never reused    |
|                    |                            | for different seqs without |
|                    |                            | eviction visibility)       |
| Forgery-resistant  | no                         | yes (chain verification)   |
| M4 persistence     | yes (pdxfs spill, R139.M2) | yes (pdxfs spill, R139.M4) |

The two substrates share `cmd_hash` (both compute djb2 of the
command bytes) so a later join query can walk cmd_audit for
tampering and history_facts for exit-code distributions on the
same `cmd_hash` key.

Record overlap avoidance: history_facts is driven from the hook
inside `_shell_history_append`; cmd_audit is driven from the
dispatch surface (shell parent, jail supervisor, remote-shell).
A single command fires BOTH records with the same `cmd_hash`.

## 8 Boot wiring

In `kernel_main.pdx`, the svc.* bringup cascade reads:

```
  call _shell_history_init;    // R127.M4
  call _hf_init;               // R127.M7
  call _hs_init;               // R139.M1
  call _cmd_audit_init;        // R139.M3 (this file)
  call _shell_jobs_init;       // R127.M5
```

`_cmd_audit_init` MUST follow `_hs_init` so an audit grep sees
the four history-shaped fingerprints in subsystem order:

```
  SHELL_HISTORY INIT OK
  HISTORY_FACTS INIT OK
  HISTORY_SEG   INIT OK
  CMD_AUDIT     INIT OK
```

No data dependency on `_shell_jobs_init`; placement is by
convention only.

## 9 Fingerprint catalogue

```
  CMD_AUDIT INIT OK                    (boot witness)
  CMD_AUDIT BEGIN OK  seq=0x<hex> sid=0x<hex>
  CMD_AUDIT BEGIN REJ errno=0x<hex>    (POOL_FULL)
  CMD_AUDIT END OK    seq=0x<hex> exit=<dec>
  CMD_AUDIT END REJ   errno=0x<hex>    (BAD_TOKEN)
  CMD_AUDIT VERIFY OK seq=0x<hex>
  CMD_AUDIT VERIFY REJ errno=0x<hex>   (BAD_TOKEN or CHAIN_BROKEN)
```

Four "OK" fingerprints are allowlisted in
`tools/verify-fingerprint-coverage.sh` with retirement conditions
tied to the production dispatch surface landing (R127.M5+ shell
parent, R135 jail supervisor, R137 remote-shell wiring
begin+end). The verify op's retirement is tied to the R139.M6
KIND_SHELL_SESSION CMD_AUDIT_VERIFY op surface.

## 10 Threat model

### 10.1 In scope

- **Kernel-level attacker who overwrites one record.** Caught by
  self-hash mismatch at next verify. The attacker would have to
  recompute every subsequent record's BLAKE3 to hide the
  overwrite — detectable by the first unrewrite.

- **Attacker who tries to insert a forged record between two
  real ones.** The inserted record would need `prev_hash =
  real[N].this_hash` AND `real[N+1].prev_hash = forged.this_hash`
  — but `real[N+1]` is already written with the original chain
  prefix. The forgery would require simultaneously editing
  `real[N+1]`'s prev_hash and recomputing its this_hash, which
  cascades forward as above.

- **Attacker who tries to forge a token.** Tokens are seq
  numbers; a forged token would land at some slot, and
  `_cmd_audit_end` validates `slot.seq == token` — any mismatch
  rejects.

### 10.2 Out of scope (deferred)

- **Attacker who can control BLAKE3 output** (collision attack).
  BLAKE3-32 (truncated to 32 bytes) has 128-bit collision
  resistance; a kernel attacker who finds a BLAKE3 collision has
  bigger problems than audit log evasion.

- **Attacker with physical DRAM access** (cold-boot attack).
  The audit substrate is RAM-only at M3; a physical attacker can
  overwrite any record byte-for-byte without passing through the
  _begin / _end API, bypassing the chain entirely. M4's pdxfs
  spill moves the authoritative log off-RAM, which lets a
  verifier compare on-RAM vs on-disk.

- **Attacker who disables `_cmd_audit_begin` at the call site.**
  The audit record is written by the dispatch surface; if the
  attacker patched the dispatch loop to skip `_cmd_audit_begin`,
  no record is created and nothing to verify. M4's cap-env
  posture requires `cap` on begin, which closes this gap for
  userspace attackers; it does not close it for a kernel-level
  attacker who rewrote dispatch.

## 11 Retention policy (M3)

M3 is RAM-only: the pool holds the last 128 finalized records.
Records are overwritten silently at ring saturation. The
retention window is proportional to command rate:

- 128 commands at 1 cmd/sec = 2 min history
- 128 commands at 1 cmd/min = 2 hr history

For audit scenarios with sustained load, M3 is explicitly
insufficient; M4's pdxfs spill is the retention-horizon
extension.

## 12 Encoder-pitfall posture

See cmd_audit.pdx §5 for the complete catalogue. Summary:

- `cmp rN, 0` (never `test rN, rN`)
- `shl rN, 7` (record stride — fits imm8)
- `shl rN, 32` / `shr rN, 32` (u32 pack / isolation — fits imm8)
- `and rN, 0x7F` (slot mask — fits imm32)
- `and rN, 1` (flag bit — fits imm8)
- `mov rax, imm32` (error codes 0x2200..0x2202; bit 31 clear so
  no `and r11, imm64` stage needed)
- `mov_d [mem], reg` (32-bit stores for u32 record fields)
- Module basename `CmdAudit` matches `cmd_audit.pdx`
- Fingerprint `[u8; N]` with N = len(string) + 1

Stack discipline (SysV, entry rsp%16==8):

```
  _cmd_audit_init    1 push + 0 sub       (klog_s1 parity)
  _cmd_audit_begin   5 pushes + sub rsp,32  (klog + seq + slot + pad)
  _cmd_audit_end     3 pushes + sub rsp,16  (klog + pad)
  _cmd_audit_verify  3 pushes + sub rsp,16  (klog + pad)
```

## 13 Open questions

- **Should VERIFY emit on every verify, or only on failure?**
  M3 emits on every call for observability. If the production
  verifier walks all 128 records per boot, that's 128 OK lines
  per boot in the dmesg ring. If the volume becomes a problem,
  move to failure-only emission in M4.

- **Should `_cmd_audit_begin` capture `cap_env_fingerprint`
  from the current task's cap-env rather than taking it as an
  argument?** M3 takes it as an argument so the dispatch surface
  can compute it inline. M4 may add a parallel
  `_cmd_audit_begin_implicit` that reads `[gs:_current_cap_env]`
  and computes the fingerprint internally, for cap-env-aware
  dispatch surfaces.

- **Argv capture.** M3 stores `argv_hash` only (opaque djb2).
  The full argv blob is left to history_facts' `argv_blob_offset`
  field (zero at M7; populated when R127.M8 lands). The two
  substrates share `cmd_hash` so a cross-join recovers full
  argv on demand.

## 14 References

- design/shell/history-datalog-substrate.md (R127.M7 fact store)
- design/shell/history-segmentation.md (R139.M1 projection)
- src/kernel/core/klog/audit.pdx (klog-side audit bridge; the
  cmd_audit substrate is independent — it emits CMD_AUDIT * via
  the regular klog, which the klog_audit_forward filter picks
  up as INFO lines)
- src/kernel/core/fs/pdxfs_lite/inode.pdx (BLAKE3 FFI reach
  reference)
