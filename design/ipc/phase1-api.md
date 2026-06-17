# PaideiaOS — IPC Phase-1 Fallback API

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** The phase-1 IPC API that ships before the wait-free dataflow primitive (Q1), the session-typed channels, the slot-cap economy, and the algebraic-effect dispatch all come online. Addresses IPC-O12 from `wait-free-dataflow.md`. The phase-1 API is a strict subset of the phase-2 API; code written against phase-1 carries forward without modification.

**Hard inputs:**
- `wait-free-dataflow.md` — phase-2 design.
- `milestones.md` §2.5 — phase-1 omits the novel IPC primitive.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| P1IPC-D1 | Phase-1 IPC is a simple bounded-buffer SPSC channel in NASM | Minimum-viable; no novel algorithm |
| P1IPC-D2 | No session types in phase 1 | Type system not ready in phase 1 |
| P1IPC-D3 | No capability passing through phase-1 IPC; messages are raw byte buffers | No capability system in phase 1 |
| P1IPC-D4 | No slot-cap economy in phase 1; bounded buffer with `Full` error return | Pragmatic for phase 1 |
| P1IPC-D5 | No effect-handler dispatch; phase-1 IPC is a direct function call | No algebraic effects in phase 1 |
| P1IPC-D6 | No cross-AS IPC in phase 1; everything in kernel address space | Simpler |
| P1IPC-D7 | The phase-1 API is byte-compatible with phase-2's `Channel(BytesSchema)` instance | Migration insurance |

---

## 1. The phase-1 API

```nasm
; Allocate a channel with the given capacity.
; Inputs:  RDI = capacity (number of slots)
;          RSI = slot size in bytes
; Outputs: RAX = channel handle (or 0 on failure)
extern ipc_create_channel

; Enqueue a message.
; Inputs:  RDI = channel handle
;          RSI = pointer to message bytes
;          RDX = message length
; Outputs: RAX = 0 (Ok), 1 (Full), 2 (BadChannel)
extern ipc_enqueue

; Dequeue a message.
; Inputs:  RDI = channel handle
;          RSI = pointer to output buffer
;          RDX = output buffer length
; Outputs: RAX = bytes written, or -1 (Empty), -2 (BadChannel)
extern ipc_dequeue

; Destroy a channel.
; Inputs:  RDI = channel handle
; Outputs: RAX = 0 (Ok), 1 (BadChannel)
extern ipc_destroy_channel
```

That is the complete API: 4 entry points, no extensions.

---

## 2. Phase-1 implementation

### 2.1 Storage

Each channel:
- Bounded buffer: a ring of `capacity` slots, each of `slot_size` bytes.
- Two `u32` indices: `head` (producer-owned), `tail` (consumer-owned).
- Stored in kernel memory (no userspace mapping in phase 1).

### 2.2 Enqueue

```nasm
ipc_enqueue:
    mov ecx, [rdi + chan_head]      ; load head
    mov edx, [rdi + chan_tail]      ; load tail
    mov r8d, [rdi + chan_capacity]
    mov r9d, ecx
    sub r9d, edx                     ; ecx - edx
    cmp r9d, r8d                     ; full if (head - tail) >= capacity
    jge .full
    
    mov r9d, ecx
    cdq                              ; clear high bits
    div r8d                          ; r9 = ecx mod capacity
    
    ; copy message bytes into slot[r9]
    mov r10, rdi                     ; channel base
    add r10, chan_slots_offset
    mov r11, r9
    mov rax, [rdi + chan_slot_size]
    mul r11                          ; rax = slot_offset
    add r10, rax                     ; r10 = &slot
    
    ; memcpy
    mov rcx, rdx                     ; message length
    mov rsi, rsi                     ; source
    mov rdi, r10                     ; dest
    rep movsb
    
    ; head++
    mov eax, [rdi + chan_head]
    inc eax
    mov [rdi + chan_head], eax
    
    mov rax, 0                       ; Ok
    ret

.full:
    mov rax, 1                       ; Full
    ret
```

### 2.3 Dequeue

Analogous: load head and tail, check empty, compute position, copy bytes out, increment tail.

### 2.4 Locking

Phase 1: no concurrency. Each channel has one producer (a specific kernel routine) and one consumer (a specific kernel routine). The kernel guarantees no two threads simultaneously enqueue or dequeue.

When a phase-1 channel needs concurrent enqueues (e.g., from multiple devices), a global lock is acquired around the channel's operations. This is acceptable for phase 1 because the channels are rare and contention is low.

---

## 3. Migration to phase 2

### 3.1 What changes

Phase 2:
- Capability handles replace raw channel handles.
- Session types describe what the channel carries.
- The slot-cap economy replaces the `Full` error.
- Effect-handler dispatch replaces direct calls.

### 3.2 What stays the same

For the phase-1 byte-stream patterns:
- `ipc_create_channel(capacity, slot_size)` → phase-2 `Channel(BytesSchema, capacity)`.
- `ipc_enqueue(handle, bytes, len)` → phase-2 `Channel.send(bytes)` with no slot-cap check (since the phase-1 channel had `Full` semantics).
- `ipc_dequeue(handle, buf, buf_len)` → phase-2 `Channel.recv()` returning bytes.

### 3.3 Migration path

The phase-1 implementation is replaced by phase-2 instantiations of `Channel(BytesSchema)`. The phase-1 API entry points become wrappers around the phase-2 calls. Eventually the wrappers are removed (when no phase-1 code remains).

This is the migration insurance promised by P1IPC-D7.

---

## 4. Phase-1 use cases

The phase-1 IPC is used by:
- The kernel's serial console (producer: kernel logging; consumer: serial driver).
- The kernel's audit log (producer: audit-event emission; consumer: log writer).
- The NVMe driver's request queue (producer: kernel; consumer: NVMe driver thread).
- Basic kernel-to-root-task signaling.

Not used by:
- Userspace-to-userspace IPC (no userspace in phase 1).
- Cross-AS communication (no AS isolation in phase 1).
- Hot-plug events (no hot-plug in phase 1).

---

## 5. Phase-1 limitations

| Limitation | Phase-2 resolution |
|---|---|
| No capability transport | Q1 capability handles in slots |
| No session typing | Functor-typed channels (IPC-Q5) |
| No effect tracking | Algebraic effects (Q-A3) |
| No cross-AS | KPTI + cross-AS context switch |
| Global lock for concurrent producers | Wait-free SPSC; merger nodes for MPSC |
| No async notification | Notification + IPI (SCH-Q9) |
| No backpressure beyond `Full` | Slot-cap economy (IPC-Q8) |
| No handoff | Q14 live handoff |
| No replay markers | D13 record/replay |

---

## 6. Phase-1 tests

The phase-1 tests cover:
- Basic create/destroy.
- Enqueue/dequeue roundtrip.
- Buffer-full behavior (returns `Full`).
- Empty-buffer behavior (returns `Empty`).
- Capacity limits.
- Concurrency under global lock.

When phase 2 lands, these tests should continue to pass against the wrapper API.

---

## 7. Open issues

| ID | Issue |
|---|---|
| P1IPC-O1 | Capacity selection for the phase-1 audit log channel — depends on log rate. |
| P1IPC-O2 | The exact moment to migrate each user from phase-1 wrappers to phase-2 API — coordinate with the subsystem migrations in `milestones.md` §3.3. |
| P1IPC-O3 | A phase-1 stress test that simulates phase-2 patterns (high-throughput producer, slow consumer) — establishes baseline performance pre-phase-2. |

---

*End of document.*
