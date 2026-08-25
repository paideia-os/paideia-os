# /etc configuration substrate

R74.M1-006 (paideia-os #1943). Companion to the R74 milestone landing;
this document is the operator-facing side of the `/etc` layout freeze
(#1940) and the `sysctl`-analog tool (#1941, in the
[paideia-os/libpdx-config](https://github.com/paideia-os/libpdx-config)
satellite repo).

---

## Layout at HEAD (R74 landing state)

`/etc` files that the kernel or init reads at boot, and their
authoritative shape:

| Path | Format | Written by | Read by |
|------|--------|------------|---------|
| `/etc/hostname` | single line, no trailing whitespace | operator | sysctl, prompt |
| `/etc/paideia.conf` | INI-lite `key = value` under `[section]` headers | operator via sysctl | init at boot |
| `/etc/motd` | plain text, printed at shell start | rootfs seed (init) | operator observes |
| `/etc/passwd` | analog — one line per user: `user:uid:gid:home:shell` | operator | future `sudo`/elevate |

`sysctl <key>` reads, `sysctl <key>=<value>` writes and persists to
`/etc/paideia.conf`. The kernel does not itself parse the config —
init consumes it after mounting `/etc` and passes any kernel-tunable
knobs through the existing `sys_kern_tune` interface (see
`design/kernel/sys-kern-tune.md`).

---

## Bootstrap sequence

R65 landed the persistent-home mount at `/home/operator` when
`PAIDEIA_R65_PERSIST=1` is set. `/etc` follows the same pattern but
mounts a small dedicated slice — see the persistent-home design at
`design/user/persistent-home.md`.

R74 as landed:
1. `/etc/hostname` defaults to `paideia` when unset (init hardcodes).
2. `/etc/motd` seeded by `RootfsSeed::rootfs_seed_run` (R57.M4-006,
   paideia-os #1802) — 34 bytes on the wire, banner `"PaideiaOS R57 --
   init rootfs seed"`.
3. `/etc/paideia.conf` is not yet parsed at boot (blocks on
   libpdx-config landing). Init runs with compiled-in defaults.
4. `/etc/passwd` is stubbed to one line: `operator:1000:1000:/home/
   operator:/bin/sh`.

---

## Sample `/etc/paideia.conf`

```
[kernel]
log_level = info
per_cpu_runq_depth = 16

[shell]
prompt = "$ "
history_size = 64

[net]
default_ttl = 64
mtu = 1500

[fs]
mount_timeout_ms = 5000
```

The parser (in libpdx-config satellite repo) treats leading whitespace
and blank lines as ignorable, `;` and `#` as line comments, and
`section.key` as the flat key form once the parse tree lowers to a
lookup table.

---

## Operator workflow

Read a value:
```
$ sysctl kernel.log_level
info
```

Set a value (persists to `/etc/paideia.conf`):
```
$ sysctl shell.prompt="> "
```

List all keys in a section:
```
$ sysctl -a kernel
kernel.log_level = info
kernel.per_cpu_runq_depth = 16
```

Reset a key to the compiled-in default:
```
$ sysctl -d shell.prompt
```

Read-only file check for the layout above:
```
$ ls /etc
hostname  paideia.conf  motd  passwd
$ cat /etc/hostname
paideia
```

---

## What's landed today vs. what's deferred

- **Landed** (R74 at paideia-os HEAD): this document; `/etc` layout
  freeze note in `design/user/etc-layout.md`; retro at
  `design/round-retrospectives/r74-closure.md`.
- **Deferred to libpdx-config repo**: the `key = value` parser
  (#1955 in libpdx-config), the `sysctl` tool binary (#1941), init's
  boot-time parse of `/etc/paideia.conf` (#1942 depends on parser
  linkage).

Once libpdx-config lands its M1 wave, this doc's "Bootstrap sequence"
§3 flips from "compiled-in defaults" to "parsed at boot". No changes
needed here at that point — the layout is frozen.
