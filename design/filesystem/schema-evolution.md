# PaideiaOS — Filesystem: Schema Versioning and Migration

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** How file/record schemas evolve while preserving historical data validity. Addresses FS-O4.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| SCH-D1 | Schemas are versioned; each version has a stable identifier | Standard |
| SCH-D2 | Forward compatibility: a newer reader can read older records | Migration policy |
| SCH-D3 | Backward compatibility: an older reader rejects newer-versioned records | Safety |
| SCH-D4 | Migration via in-place rewrite during snapshot diff | Pragmatic |
| SCH-D5 | Schema registry is a CoW FS directory (schemas are first-class nodes per FS doc §7.4) | Self-describing |

---

## 1. Schema identifier

Each schema has:
- Name (e.g., `audit.entry`).
- Version (e.g., `1.2.0`).
- Composite id: `audit.entry@1.2.0`.

---

## 2. Compatibility rules

- **Major version**: incompatible change; readers reject.
- **Minor version**: backward-compatible additions; readers ignore unknown fields.
- **Patch version**: clarifications only; no field changes.

A schema-id without explicit version defaults to "latest".

---

## 3. Migration

When the schema changes:
1. New schema version is registered.
2. Existing records remain valid in their original version.
3. New records use the new version.
4. Optionally: a `migrate(v_old, v_new)` function rewrites records during snapshot creation or background compaction.

---

## 4. Forward / backward compat

For minor-version evolution:
- Old reader on new record: ignore unknown fields, succeed.
- New reader on old record: missing-field defaults applied.

For major-version evolution:
- Migration is mandatory; bypassing it requires explicit user policy.

---

## 5. Schema registry

The registry is a directory in the typed name-resolution graph:

```
/system/schemas/
  audit.entry/
    1.0.0/
      schema_definition
    1.1.0/
      schema_definition
    1.2.0/
      schema_definition
  ...
```

Applications query the registry via the `enumerate_schema` operation per FS doc §7.2.

---

## 6. Open issues

| ID | Issue |
|---|---|
| SCH-O1 | Concrete migration API for record-by-record transformation. |
| SCH-O2 | Long-tail schemas (rarely-used old versions) — when to garbage-collect. |
| SCH-O3 | Cross-application schema sharing — namespace allocation. |

---

*End of document.*
