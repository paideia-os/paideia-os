# PaideiaOS — Drivers: Schema-Extensible Matching (Phase 3+)

**Status:** Draft v0.1 — phase 3+
**Date:** 2026-06-17
**Scope:** Schema-extensible device-driver matching. Addresses DR-O1.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| SCM-D1 | Phase 1–2: classical VID/PID + Class triple matching | Per DR-D4 |
| SCM-D2 | Phase 3+: devices advertise schema metadata; drivers advertise schemas they fulfill | Future extension |
| SCM-D3 | Schemas are first-class FS nodes (per FS doc §7.4) | Type-system integration |

---

## 1. Phase 3+ matching algorithm

When a device arrives:
1. The bus driver reads device descriptors as before.
2. The bus driver queries the device for *schema declarations* (a vendor extension on hot-plug events).
3. The supervisor looks up drivers that fulfill the declared schemas.
4. Most-specific driver wins; ties by registry priority.

---

## 2. Schema declaration

```capnp
struct DeviceSchemaDeclaration {
  schemaName @0 :Text;
  schemaVersion @1 :SemVer;
  vendorId @2 :Text;
  deviceId @3 :Text;
  additional @4 :List(SchemaConstraint);
}
```

Example: a device declares `nvme/2.0`, `pcie/4.0`. A driver claiming `nvme/2.0` matches.

---

## 3. Drivers registering

```capnp
struct DriverRegistrationV2 {
  driverId @0 :DriverId;
  fulfills @1 :List(DeviceSchemaDeclaration);
  ...
}
```

---

## 4. Open issues

| ID | Issue |
|---|---|
| SCM-O1 | The vendor extension protocol for schema discovery — needs standardization. |
| SCM-O2 | Tie-breaking when multiple drivers fulfill the same schemas. |
| SCM-O3 | Migration from phase-2 VID/PID matching to phase-3 schema matching. |

---

*End of document.*
