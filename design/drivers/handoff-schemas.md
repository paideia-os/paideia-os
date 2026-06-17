# PaideiaOS — Drivers: Handoff Schema Versioning

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Schema versioning and migration framework for driver live-handoff. Addresses DR-O3. Builds on `ipc/typed-handoff.md`.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| DHS-D1 | Each driver declares its handoff schema and version | Standard |
| DHS-D2 | Cap'n Proto-based; semver | Per Q13 |
| DHS-D3 | Replacement driver supports a *range* of compatible schema versions | Flexibility |
| DHS-D4 | A `migrate(v_old, v_new)` function transforms across versions | Standard |
| DHS-D5 | Major version differences may require hard restart instead of handoff | Pragmatic |

---

## 1. Driver schema declaration

A handoff-capable driver registers:

```capnp
struct DriverHandoffMetadata {
  driverId @0 :DriverId;
  handoffSchemaName @1 :Text;
  supportedVersionMin @2 :SemVer;
  supportedVersionMax @3 :SemVer;
  schemaDefinition @4 :SchemaDefinition;
}
```

---

## 2. Migration function

For each (old, new) compatible pair, a migration function exists:

```paideia-as
fn migrate_handoff_state(certificate : OldHandoffCertificate, target_version : SemVer)
                       -> Result<NewHandoffCertificate, MigrationError>
```

The supervisor invokes this when V_old < V_new.

---

## 3. Migration cases

- **Patch version**: identity (no migration needed).
- **Minor version**: field additions; defaults applied.
- **Major version**: explicit migration function or fail.

---

## 4. Open issues

| ID | Issue |
|---|---|
| DHS-O1 | Schema registry for driver handoff schemas. |
| DHS-O2 | Migration testing framework. |

---

*End of document.*
