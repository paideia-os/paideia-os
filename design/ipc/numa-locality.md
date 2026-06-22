# IPC Channel Allocation: NUMA-Local Optimization (R3.5-006)

**Author:** osarch + workerbee  
**Date:** 2026-06-21  
**Status:** Phase 2.5 (structure; single-node QEMU only)  

## Overview

R3.5-006 implements NUMA-local channel allocation to reduce cross-node cache traffic on the enqueue/dequeue path. Each NUMA node maintains its own channel pool; `ipc_channel_create()` allocates from the local node via GS-relative addressing.

## Motivation

**Pillar 2** (per-CPU allocators, no BKL) extends to NUMA nodes: memory allocated on the node where the producer/consumer runs avoids inter-node coherency traffic, reducing IPC latency.

Per the Intel Performance Analysis Guide §3.3.2:
- **Intra-node access:** ~40 cycles (L3 cache hit).
- **Inter-node access (QPI/Infinity Fabric):** 200-400 cycles (cross-NUMA serialization).

For high-frequency IPC (e.g., microkernel fast-path), allocating channels on the local node is **critical**.

## Implementation

### Channel Pool Organization

```c
// Per-node channel pool (Phase 2.5: 1 node only; Phase 8+: N nodes)
struct ChannelPool {
  channels: [Channel; CHANNEL_POOL_SIZE],  // 32 channels per node (= 16.9 KiB)
  free_list_head: u32,                     // Index of next free channel
}

// Global pools array (indexed by NUMA node ID)
let mut channel_pools: [ChannelPool; MAX_NUMA_NODES];  // 64 nodes max
```

### Allocation Path

1. **Get local NUMA node:** `numa_local_node() -> u8` reads from `gs:[numa_node_offset]`.
   - GS-base is set up at boot (Phase 6 m6 `gs_current.pdx`).
   - Each CPU/thread has a per-CPU GS area with cached NUMA node ID.

2. **Allocate from local pool:** `channel_pools[local_node].free_list_head` → next channel.

3. **Return channel:** Pointer is guaranteed to be on the local NUMA node.

### Example Assembly (Phase 2.5 pseudocode)

```asm
ipc_channel_create():
    mov rax, gs:[numa_node_offset]          ; Local NUMA node in RAX
    lea rcx, [channel_pools + rax * 8]     ; Pool base for this node
    mov rdx, [rcx + free_list_head]        ; Next free channel index
    cmp rdx, CHANNEL_POOL_SIZE             ; Bounds check
    jge pool_full
    ; Allocate at channel_pools[node][index]
    lea rsi, [rcx + rdx * sizeof(Channel)] ; Channel address (local node)
    ; ... initialize channel ...
    ret
```

## Phase 2.5 Status

**Single-node QEMU:** All allocations come from node 0 (no cross-node traffic possible). The GS-base setup is deferred to Phase 6 m6 completion.

**TODO (Phase 8+):**
- Multi-node QEMU / real hardware: verify GS-based NUMA node detection.
- Per-node free-list management: implement per-node allocation tracking.
- Contention-aware rebalancing: move channels between pools if imbalance detected.

## References

- **Intel Performance Analysis Guide**, "NUMA Fundamentals" §3.3.2: cross-NUMA latency analysis.
- **AMD NUMA Whitepaper**: https://www.amd.com/system/files/2017-06/amd-numa-whitepaper-draft.pdf
- `design/runtime/per-cpu-state.md`: GS-base initialization (Phase 6 m6).
- `src/kernel/core/ipc/channel.pdx`: Channel struct definition.
- `src/kernel/core/ipc/channel_create.pdx`: Allocation implementation.

## Verification TODO

1. Single-node test: verify all allocations come from node 0.
2. Multi-node simulation: mock numa_local_node() to return different nodes; confirm allocations respect locality.
3. Cache coherency trace: measure QPI traffic with NUMA-local vs. cross-node channel allocation (Phase 8+ real hardware).
