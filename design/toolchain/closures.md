# Issue #994: Closure Types and Runtime Representation

**Phase**: v0.18 | **Depends on**: pa-r17-004 | **Blocks**: #995, #996  
**Status**: Phase 1 (non-calling implementation; #995 handles invocation)

## 1. Overview

Paideia-as v0.18 introduces **closure types** (`|T1, T2| -> R`), a distinct form from fn-ptr types (`(T1, T2) -> R`). Closures capture free variables from their enclosing scope and are represented as 16-byte fat pointers at runtime.

This document describes:
- The closure runtime layout (memory representation)
- How the elaborator lowers closure literals from AST to IR
- The calling convention for closure bodies (R14 discipline)
- How issue #995 (closure call) will consume these structures

## 2. Runtime Layout

A closure value occupies **16 bytes (align 8)** on the caller's stack:

```
struct Closure {
  env_ptr:  *env,   // 8 bytes — pointer to captured values (0 if no captures)
  code_ptr: *code,  // 8 bytes — pointer to the closure body function
}
```

The **environment record** (`env`) is a variable-size struct holding captured bindings, allocated on the *caller's stack frame*:

```
struct env_record {
  capture[0],       // 8 bytes (u64) or per-type width
  capture[1],       // ...
  ...
}
```

Capture slots are **symbol-sorted** for determinism and packed via `record_layout.rs` tight-packing rules.

### Zero-Capture Case

When a closure captures no free variables, `env_ptr` is **null (0)**, but the fat pair is still materialized. This allows #995 to use a uniform `mov r14, [f+0]; call [f+8]` regardless of capture count.

## 3. Lowering and Layout

### Type Lowering

The parser produces `TypeClosure { params, ret, effects, capabilities }` for syntax `|T1, T2| -> R !{...} @{...}`.

The elaborator's `lower_type.rs` lowers `TypeClosure` to `Type::Fn` (same as fn-ptr), but the IR layer tracks the discriminant: `IrKind::Lambda` (fn-ptr) vs. `IrKind::ClosureCons` (closure).

### Expression Lowering

An `ExprLambda` (`|x| body`) in source is **context-dependent**:

- **Expected type = `Type::Fn` (fn-ptr discipline)**  
  Lowered to `IrKind::Lambda`. No captures allowed; T0538 fires if captures exist.

- **Expected type = `Type::Fn` (closure discriminant)**  
  Lowered to `IrKind::ClosureCons`. Captures are analyzed, env layout computed, code symbol mangled as `closure_<parent>_<node_id>`.

- **Unannotated (inferred)**  
  Defaults to closure if captures exist, else fn-ptr.

### Capture Analysis

Capture analysis (existing in `elaborate/src/capture.rs`) classifies each free variable:

- **Reference**: borrowed (no consumption). Legal for any binding class.
- **Value**: copied (copy semantics for Unrestricted/Affine). Binding remains usable in outer scope.
- **Consume**: ownership transferred. Legal only if closure itself is Linear/Affine (called ≤1 time).

The elaborator populates `ast.captures_mut()[lambda_id]` at `check_linearity.rs:457`, and the IR arena's `closure_meta_table` records env layout + code symbol.

## 4. Emission Strategy

### Closure Body Emission

The closure body is emitted as a normal function but with **captured symbols resolved to `[r14 + offset]`** (env-relative addressing):

```asm
  mov rax, [r14 + 0]    # load capture[0]
  add rax, [r14 + 8]    # add capture[1]
  ret
```

**R14 is reserved for the environment pointer** (per `abi.rs::PAIDEIA_BRIDGE_SAVE = [R15, R14]`).

On entry to the closure body, the caller (via #995) will load R14 from `[f+0]` before executing `call [f+8]`.

### Closure Pair Materialization

When a closure literal is evaluated:

1. **Allocate 16 bytes** on the caller's stack for the fat pair.
2. **Allocate env record** (sizeof(env) bytes) on caller's stack.
3. **For each capture (symbol-sorted)**:
   - If **Consume**: `mov [env+off], <src_reg>` (takes ownership).
   - If **Reference** or **Value**: `mov [env+off], <src_reg>` (copy semantics; src binding remains live).
4. **Set code_ptr**: `lea rax, [rip + closure_<parent>_<node_id>]; mov [f+8], rax`.
5. **Set env_ptr**: `lea rax, [rbp + env_off]; mov [f+0], rax` (or 0 if no captures).
6. **Return the pair address in RAX** (standard SysV return).

## 5. Example

Source:
```paideia
let y: u64 = 42;
let f: |u64| -> u64 = |x| x + y;
```

Generated IR:
```
ClosureCons(id=99)
  captures: [CapturedBinding { symbol: y, kind: Value }]
  env_layout: RecordType { fields: [(y, u64)] }
  code_symbol: closure_entry_99
```

Generated ASM (pseudo):
```asm
  # Allocate pair + env on caller's stack
  mov [rbp-16], 0           # env_ptr = null (will set below)
  lea rax, [rbp-24]         # env record address
  mov [rbp-16], rax         # env_ptr = address of env record
  
  # Populate env: capture y (value)
  mov rax, [rbp+y_offset]   # load y from binding
  mov [rbp-24], rax         # store in env[0]
  
  # Set code_ptr
  lea rax, [rip + closure_entry_99]
  mov [rbp-8], rax          # code_ptr at [f+8]
  
  # Return pair in rax
  lea rax, [rbp-16]
  ret
```

## 6. Calling Closures (Issue #995)

#995 implements the call side:

```asm
  mov r14, [f+0]      # load env_ptr into R14
  call [f+8]          # call closure body (R14 is now live inside it)
  # Result in RAX per SysV convention
```

The closure body accesses captures via `[r14 + off]` and returns normally.

## 7. Zero-Capture Optimization (Future)

A zero-capture closure can be optimized to a bare function pointer (folded to fn-ptr type) in a future release. For now, both are materialized as 16-byte fat pairs for consistency.

## 8. References

- `design/paideia-as/v0.18-issue-994-closures.md` — full architectural spec
- `design/toolchain/custom-assembler.md` §3.2 — capture discipline
- `design/toolchain/calling-convention.md` §1 — R14 reservation
- Issue #995 (pa-r18-002) — closure invocation
- Issue #996 (pa-r18-003) — hashmap (uses closures for hash functions)
