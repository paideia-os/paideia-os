# /etc layout freeze — R74.M1-002 (paideia-os #1940)

The five files under `/etc` that R74 declares authoritative. Frozen
shape, so a future operator running against a persistent volume from
an older HEAD can still be parsed.

## Shape

```
/etc/
    hostname       # single-line, no CRLF, no trailing whitespace
    paideia.conf   # INI-lite (see libpdx-config parser spec)
    motd           # plain text, printed at shell login
    passwd         # colon-separated: user:uid:gid:home:shell
```

## Format constraints

**`/etc/hostname`**
- One line, terminated by a single `\n`.
- ASCII letters/digits/hyphen only. No leading digit. Max 63 bytes.
- Default when absent: `paideia`.

**`/etc/paideia.conf`**
- INI-lite: `[section]` headers, `key = value` inside.
- One key per line. Trailing `\n` on last line.
- Comments: `#` or `;` from column-1 or after value with a space.
- Keys are ASCII `[a-z0-9_]`, lowercase. Section names same.
- Values are UTF-8, `"quoted"` if they contain spaces or `#`/`;`.
- Sections landed at R74: `kernel`, `shell`, `net`, `fs`. New sections
  land as sub-issues under later rounds.

**`/etc/motd`**
- Plain text, no format contract beyond "printable on tty at
  shell login".
- Rootfs-seed default: `PaideiaOS R57 -- init rootfs seed\n` (34
  bytes on wire — R57.M4-006 / paideia-os #1802 `rs_motd_banner`).

**`/etc/passwd`**
- One line per user: `login:uid:gid:home_path:login_shell`.
- Fields colon-separated, no colons inside values.
- `login` matches `[a-z][a-z0-9_]{0,15}`.
- `uid` and `gid` are decimal u32.
- `home_path` and `login_shell` are absolute paths.
- Rootfs-seed default:
  `operator:1000:1000:/home/operator:/bin/sh\n`.

## Freeze rationale

- File names are POSIX-conventional so an operator with prior
  UNIX/Linux experience finds them without doc-diving.
- Content shapes are parseable by libpdx-config (see that repo's
  parser spec) without further schema work.
- The freeze at R74 means any subsequent round can add `/etc/<newfile>`
  without touching this document; new files just get their own
  freeze section.

## Cross-references

- Operator walkthrough: `doc/user-guide/etc-configuration.md`.
- Kernel-side parser + sysctl tool: paideia-os/libpdx-config (satellite
  repo).
- Persistent mount plumbing: `design/user/persistent-home.md`.
- Boot-time seed: `src/user/rootfs_seed.pdx` (R57.M4-006 / #1802).
