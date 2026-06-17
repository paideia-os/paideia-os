# PaideiaOS — Terminal: Pipeline Record Wire Format

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Cap'n Proto schema for pipeline records at process/host boundaries. Addresses SH-O2.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| WF-D1 | Cap'n Proto-based per Q13 | Standard |
| WF-D2 | Each record has schema id + payload | Self-describing |
| WF-D3 | Schemas registered in FS schema registry | Lookup |

---

## 1. Wire format

```capnp
struct PipelineRecord {
  schemaId @0 :SchemaId;
  schemaVersion @1 :SemVer;
  payload @2 :Data;       # Cap'n Proto-encoded per schema
  capabilities @3 :List(CapabilityAttestation);  # for cap-bearing records
  metadata @4 :Metadata;
}
```

---

## 2. Schema lookup

The receiver looks up `schemaId` in the FS schema registry to decode `payload`.

---

## 3. Versioning

Receiver supports a range of compatible schema versions (per FS schema-evolution doc).

---

## 4. Open issues

| ID | Issue |
|---|---|
| WF-O1 | Capability attestation format detail. |

---

*End of document.*
