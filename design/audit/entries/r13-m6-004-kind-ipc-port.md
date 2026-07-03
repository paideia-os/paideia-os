---
audit_id: r13-m6-004-kind-ipc-port
issue: 452
file: src/kernel/core/cap/kind_ipc_port.pdx
function: cap_handler_ipc_port
effects: [mem, sysreg]
capabilities: [cap]
reviewed_by:
date: 2026-07-03
---

# AUDIT R13-m6-004 — KIND_IPC_PORT Handler: Point-to-Point Message Slot (#452)

## Justification

The KIND_IPC_PORT capability handler implements a point-to-point message slot (port)
for inter-process communication. The port pool is a static 64-slot array in .bss, each
slot 16 bytes: a full flag (u64) and a 56-bit payload. The handler supports two
operations: OP_SEND and OP_RECV with rights-based access control and WOULD_BLOCK
semantics when the slot is full (SEND) or empty (RECV).

**Handler Signature:**
```
pub let cap_handler_ipc_port : (u64, u64, u64) -> u64 !{mem, sysreg} @{cap} =
  fn (rights: u64) (target_ptr: u64) (op_arg: u64) -> unsafe { ... }
```

Handler ABI (via cap_invoke_dispatch, R12-m2-001 §M):
- **RDI** = rights (capability rights bitmask)
- **RSI** = target_ptr (encodes port_id, 0..63)
- **RDX** = op_arg (bits [7:0] = op_code, bits [63:8] = payload on SEND)
- **RAX** = result (return code or payload on success)

## Data Model

### Port Pool Structure (src/kernel/core/ipc/port.pdx)
64-slot pool, 16 bytes per slot, 1024 bytes total, .bss-resident, zero-initialized.
Each slot is indexed as `_port_pool + port_id * 16`:
- **+0 (u64)** : `slot_full` — 0 = empty, 1 = message present
- **+8 (u64)** : `payload` — 56-bit message content (op_arg >> 8 on SEND)

### Encoding: port_id from target_ptr
The capability descriptor's target_ptr field directly encodes the port_id (0..63).
Out-of-range port_id (>= 64) returns INVOKE_UNSUPPORTED (0xFFFFFFFFFFFFFFFC).

## Operation Semantics

### OP_SEND (op_arg[7:0] = 0)
- **Rights check**: RIGHT_INVOKE (0x08) required; else INVOKE_DENIED (0xFFFFFFFFFFFFFFFD).
- **Port bounds**: port_id >= 64 returns INVOKE_UNSUPPORTED.
- **Precondition**: slot_full == 0 (empty).
- **Action**: Extract payload from op_arg[63:8]; store at _port_pool[port_id].payload;
  set _port_pool[port_id].slot_full = 1.
- **Success return**: RAX = 0.
- **Full error**: slot_full == 1 returns INVOKE_WOULD_BLOCK (0xFFFFFFFFFFFFFFFB).

### OP_RECV (op_arg[7:0] = 1)
- **Rights check**: RIGHT_READ (0x01) required; else INVOKE_DENIED.
- **Port bounds**: port_id >= 64 returns INVOKE_UNSUPPORTED.
- **Precondition**: slot_full == 1 (message present).
- **Action**: Read payload from _port_pool[port_id].payload; set slot_full = 0;
  return payload in RAX.
- **Empty error**: slot_full == 0 returns INVOKE_WOULD_BLOCK.

### Unknown Operation (op_arg[7:0] ≠ 0, 1)
Returns INVOKE_UNSUPPORTED (0xFFFFFFFFFFFFFFFC).

## Return Codes

| Code | Hex | Meaning |
|------|-----|---------|
| 0 | 0x0000000000000000 | OP_SEND success |
| payload | 0x00...... | OP_RECV success (payload in RAX) |
| INVOKE_WOULD_BLOCK | 0xFFFFFFFFFFFFFFFB | Slot full on SEND or empty on RECV |
| INVOKE_UNSUPPORTED | 0xFFFFFFFFFFFFFFFC | Unknown op_code or port_id >= 64 |
| INVOKE_DENIED | 0xFFFFFFFFFFFFFFFD | Rights check failed |

**New sentinel**: INVOKE_WOULD_BLOCK (0xFFFFFFFFFFFFFFFB) is introduced in this audit
entry for IPC blocking semantics, distinguishing from INVOKE_UNSUPPORTED and INVOKE_DENIED.

## Handler Implementation

### Entry Prologue
1. Save RDI, RSI, RDX (caller-saved, preserved for rights/port_id/op_arg)
2. Emit tag string cap_port_msg ("CAP INVOKE PORT\n\0") via uart_puts
3. Restore RDI, RSI, RDX

### Dispatch on op_code
- Extract op_code = RDX & 0xFF
- Branch: op_code == 0 → OP_SEND; op_code == 1 → OP_RECV; else → INVOKE_UNSUPPORTED

### Common Checks (both OP_SEND and OP_RECV)
1. **Rights check**: Extract bit from RDI (RIGHT_INVOKE for SEND, RIGHT_READ for RECV);
   if missing, emit cap_denied_msg and return INVOKE_DENIED (0xFFFFFFFFFFFFFFFD).
2. **Port bounds**: Compare RSI < 64; if RSI >= 64, return INVOKE_UNSUPPORTED (0xFFFFFFFFFFFFFFFC).

### OP_SEND Path
1. Compute slot address: R9 = RSI << 4 (port_id * 16); R10 = [RIP + _port_pool] + R9
2. Check slot_full: load [R10 + 0]; if != 0, return INVOKE_WOULD_BLOCK (0xFFFFFFFFFFFFFFFB)
3. Store payload: RAX = RDX >> 8; store at [R10 + 8]
4. Mark slot full: store 1 at [R10 + 0]
5. Return: RAX = 0

### OP_RECV Path
1. Compute slot address: R9 = RSI << 4; R10 = [RIP + _port_pool] + R9
2. Check slot_full: load [R10 + 0]; if != 1, return INVOKE_WOULD_BLOCK
3. Read payload: RAX = [R10 + 8]; R11 = RAX (save for return)
4. Clear slot_full: store 0 at [R10 + 0]
5. Return: RAX = R11 (payload)

### Instruction Count
Approximately 55 instructions: 6 (prologue/epilogue) + 6 (dispatch) + 8 (common checks)
+ 18 (OP_SEND) + 17 (OP_RECV).

## Cross-References

- **Issue**: #452 (R13-m6-004 IPC port handler)
- **Related**: #431 (real-handler precedent, kind_ipc)
- **Design**: `design/capabilities/linearity-and-tags.md` §3.1 (closed-enum kinds)
- **Rights**: `src/kernel/core/cap/rights.pdx` (RIGHT_INVOKE, RIGHT_READ)
- **Kind enum**: `src/kernel/core/cap/kind.pdx` (KIND_IPC_PORT = 6)
- **Dispatch wiring**: `src/kernel/core/cap/invoke.pdx` (cap_invoke_dispatch)
- **Port pool**: `src/kernel/core/ipc/port.pdx` (_port_pool definition)
- **Audit**: This entry

## Scope and Constraints

### Landing Scope
- Real handler body (55 instructions, no stubs)
- Static port pool (64 slots, 1024 bytes, .bss-resident)
- Dispatch wiring in cap_invoke_dispatch (cmp rcx, 6; je call_kind_ipc_port)
- No initialization call: .bss zero-init (slot_full = 0) is correct empty state

### Smoke Test Collisions
- Kind 6 dispatch does not collide with any existing smoke-test paths
- Existing smoke tests (boot_r8_only, boot_r10, boot_r11, boot_r12, boot_r12_denial)
  do not invoke KIND_IPC_PORT capabilities, so no green regression expected

### Encoder Dependencies
- All instructions are standard x86-64 (mov, cmp, jne, jae, call, ret, shl, and, shr, lea)
- No encoder gaps (compare to aspace-map-001, aspace-unmap-001)

## Verification

### Build Verification
```bash
cd /home/snunez/Development/PaideiaOS
./tools/build.sh 2>&1 | tail -3
```
Expected: Successful kernel build; no assembly errors.

### Smoke Test Verification (5-mode green)
```bash
for mode in boot_r8_only boot_r10 boot_r11 boot_r12 boot_r12_denial; do
  ./tools/run-smoke.sh $mode 2>&1 | tail -1
done
```
Expected: All modes exit with status 0 (green).

### Objdump Verification
```bash
objdump -d build/kernel.elf | grep -A 70 '<cap_handler_ipc_port>:' | head -80
```
Expected: ~55 instructions; prologue (push/lea/call/pop); dispatch logic; error paths.

### Dispatch Wiring Verification
```bash
objdump -d build/kernel.elf | grep -B 1 -A 3 '<call_kind_ipc_port>:'
```
Expected: `cmp rcx, 6` followed by `je call_kind_ipc_port`.

### No Emoji Artifacts
```bash
grep -P '[\x{1F300}-\x{1FAFF}]|[\x{2600}-\x{27BF}]' \
  src/kernel/core/ipc/port.pdx \
  src/kernel/core/cap/kind_ipc_port.pdx \
  src/kernel/core/cap/tags.pdx \
  src/kernel/core/cap/invoke.pdx \
  design/audit/entries/r13-m6-004-kind-ipc-port.md \
  && echo "SYMBOLS" || echo "CLEAN"
```
Expected: Output "CLEAN".

## Known Limitations

- **Synchronization scope**: Port operations do not coordinate with other CPUs (single-CPU
  mailbox semantics). Multi-CPU consistency is deferred to R13-m6+ (port multi-producer
  discipline).
- **Buffering**: Ports hold exactly one message; multi-message queues are deferred to R13-m7+.
- **Timeouts**: No timeout on WOULD_BLOCK; userspace must poll. Timeout semantics deferred
  to R13-m8+ (port timed-wait).
- **Fairness**: No priority inversion avoidance; port reads are FIFO-ordered per slot but
  multiple ports are unordered (depends on invocation order). Priority inheritance deferred
  to R13-m9+ (real-time disciplines).

## Validation Checklist

- [x] Handler function signature matches ABI (rdi=rights, rsi=port_id, rdx=op_arg)
- [x] Port pool structure correct (16 bytes per slot, 64 slots, .bss resident)
- [x] OP_SEND and OP_RECV branches implemented
- [x] Rights checks (RIGHT_INVOKE for SEND, RIGHT_READ for RECV)
- [x] Port bounds check (port_id < 64)
- [x] WOULD_BLOCK sentinel defined and returned correctly
- [x] Return codes match specification (0, payload, WOULD_BLOCK, UNSUPPORTED, DENIED)
- [x] Tag string emitted (cap_port_msg)
- [x] Dispatch wiring in invoke.pdx (cmp rcx, 6; je call_kind_ipc_port)
- [x] No emoji artifacts
- [x] ~55 instruction count (real body, not stub)
- [x] 5-mode smoke tests pass (green)
