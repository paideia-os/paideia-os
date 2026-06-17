# PaideiaOS — Terminal: `.pds` Script Format

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Detailed specification of the `.pds` script file format. Addresses SH-O7.

---

## 0. Format

```
#! /bin/paideia-sh           # shebang (optional)
#capability fs.read.home
#capability fs.write.home/backup
#requires-paideia >= 0.5
#import "lib/util.pds" as util

# Shell script content follows:
find ~ 
  | where modified > now - 1.day
  | each { |f|
      copy $f.path to ~/backup/$(basename $f.path)
    }
```

---

## 1. Header pragmas

| Pragma | Purpose |
|---|---|
| `#capability <cap>` | Declares a required capability; checked at load |
| `#requires-paideia <semver>` | Minimum PaideiaOS version |
| `#import "<path>" as <name>` | Import another `.pds` as a module |
| `#schema "<path>"` | Pre-register schemas |
| `#ascii` | ASCII-only mode (no Unicode glyphs) |

---

## 2. Body

The body is shell pipeline syntax per `semantic-shell.md` §2.

---

## 3. Modules

Imported `.pds` files are first-class modules. Their declarations are accessible via the import name.

---

## 4. Open issues

| ID | Issue |
|---|---|
| PDS-O1 | The exact import semantics — top-level let-bindings exported? Or only `pub`-marked? |
| PDS-O2 | Module circularity — detect at load. |

---

*End of document.*
