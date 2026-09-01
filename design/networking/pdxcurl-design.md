# `pdxcurl` — Flagship Design

**Status:** proposal (2026-09-01, companion to `design/networking/r93-user-tools-plan.md`)
**Wave:** R93. Full tool-inventory, kernel-coordination, and milestone
context lives in the parent plan — this document is the deep dive on
`pdxcurl` alone, mirroring the level of per-tool detail
`design/tooling/volume-tooling-ux.md` §3–§5 gives `mkfs.pdxfs`/
`mount.pdxfs`/`umount.pdxfs`.
**Depends on:** `libpdx-net` (TCP/TLS/HTTP), `libpdx-url` (parse/validate),
`libpdx-audit` (@0.2 wire), `libpdx-semantic-pipe` (line-based fallback
until paideia-os#2000), `pdxtrust` (mints the `KIND_TLS_TRUST` caps
`pdxcurl` consumes).

---

## 0. Reading order

- §1 mental model — what `pdxcurl` is, in one paragraph.
- §2 argv surface.
- §3 the trust model, restated precisely (this is the load-bearing design decision).
- §4 request pipeline, stage by stage.
- §5 `--dry-run` vs `--audit-only` — the exact wire contract for each.
- §6 output modes: semantic-pipe, `--output FILE`, plain stdout fallback.
- §7 error taxonomy — exit codes and result codes, one table.
- §8 `caps.decl`.
- §9 what `pdxcurl` deliberately does not do (curl-parity gaps, permanent and temporary).

---

## 1. Mental model

`pdxcurl <url>` resolves the URL's host (DNS, if not a literal IP),
opens a TCP connection, optionally negotiates TLS 1.3 against a
capability-pinned raw public key (no CA, no X.509, §3), sends one
HTTP/1.1 request, and prints or writes the response. Every invocation
writes an audit record *before* any byte reaches the wire and a second
one *after* the response (or failure) is known — the same INTENT/RESULT
pairing `mount.pdxfs` established. Output is a typed semantic-pipe
record (status/headers/body-chunks) that degrades gracefully to
line-based text when the schema registry isn't reachable, exactly like
every other tool released in this repo generation. There is no ambient
trust store, no `-k`/`--insecure`, and no environment-variable proxy
magic — everything `pdxcurl` trusts, it was explicitly told to trust, by
cap URI, on that invocation's command line.

---

## 2. Argv surface

```
pdxcurl [OPTIONS] <url>

  -X, --request=<METHOD>       GET (default) | POST | HEAD | PUT | DELETE
  -d, --data=<STRING|@FILE>    request body; @FILE reads from a file; implies -X POST if -X unset
  -H, --header=<K:V>           repeatable; additional request header
  -o, --output=<FILE>          write response body to FILE instead of stdout
  --trust=<cap-uri|name>       KIND_TLS_TRUST cap for HTTPS; a bare name resolves
                                via pdxtrust's user-scope store (§8 of the parent plan);
                                required for https:// URLs, ignored for http://
  --resolve=<ip>                skip DNS, connect directly to this literal IP
                                (host header + SNI still use the URL's hostname)
  --timeout-ms=<N>              default 10000; applies to connect + each read
  --max-redirects=<N>           default 10
  --allow-downgrade             permit an https-> http redirect (refused by default)
  --dry-run                     print the HttpRequestRecord that would be emitted; no network I/O
  --audit-only                  journal INTENT only; no DNS, no connect, no send
  --verbose                     stderr chatter per stage (resolve, connect, handshake, send, recv)
  <url>                         http:// or https:// (any other scheme is a parse error, exit 2)
```

Deliberately absent versus classic `curl`: `-k`/`--insecure` (§3),
`-L`/`--location` as an opt-in flag (redirects are always followed up to
`--max-redirects`, since a capability-scoped, audit-first tool has no
"blindly trust every redirect target the same way" ambiguity to gate
behind a flag — the audit trail records every hop regardless), proxy
support (`-x`/`--proxy`, no proxy concept exists in this plan's scope),
cookie jars (`-b`/`-c`, no persistent cookie store exists or is planned —
a stateless request tool has no home for session state), and multi-URL
globbing (`curl` can take `{a,b}.example.com`-style brace expansion;
`pdxcurl` takes exactly one URL per invocation, full stop — scripting
loops belong at the shell layer).

---

## 3. The trust model (restated precisely)

This is the parent plan's §0.5, restated here with the exact mechanics
`pdxcurl` implements.

### 3.1 What "trust" means at v1

A `KIND_TLS_TRUST` cap (minted by `pdxtrust import`, §8 of the parent
plan) names exactly one `(algorithm, public_key_bytes, label)` triple.
`pdxcurl --trust=fixture-server https://1.2.3.4/` means: "I expect the
TLS server at 1.2.3.4 to authenticate the handshake with a signature
that verifies under the public key I've labeled `fixture-server`." If
the server presents any other key — including a perfectly valid,
CA-signed, browser-trusted X.509 certificate for a real domain — the
handshake is refused (`TLS_KEY_MISMATCH`). There is no fallback, no
partial match on hostname, no "warn and continue."

### 3.2 What this buys

- **No ASN.1/X.509 parser in the TCB.** X.509 certificate parsing is
  one of the most CVE-dense parser surfaces in networked software
  (malformed-length, integer-overflow, and recursive-structure bugs
  recur across every major TLS library's history). `pdxcurl` has none
  of that attack surface because it never parses a certificate.
- **No CA root store to curate, ship, and keep current.** A CA store is
  itself a long-lived trust artifact with its own supply-chain and
  revocation problems (a compromised or coerced CA, a root that should
  have been distrusted years ago). Pinning removes the question
  entirely: trust is exactly as fresh as the last `pdxtrust import`.
- **Fits the capability model natively.** "Who may this process talk
  to, authenticated how" is exactly the shape of question a capability
  system is built to answer explicitly, rather than the ambient,
  process-global trust-store model POSIX systems inherited from an era
  before capabilities were a mainstream OS primitive.

### 3.3 What this costs

- **No public-internet HTTPS.** A real-world server's certificate is
  signed by a CA `pdxcurl` has no concept of; `pdxcurl` cannot verify it
  and does not try. `pdxcurl` v1 is a tool for talking to endpoints an
  operator controls or has been given an out-of-band public key for —
  intranet services, PaideiaOS-native peers, a package mirror whose
  maintainer publishes a pinned key. It is explicitly not (yet) a
  general-purpose "browse HTTPS" tool.
- **Key rotation is a manual, explicit act.** If a server operator
  rotates their TLS key, every `pdxcurl` client's trust anchor must be
  re-imported (`pdxtrust import <name> <new-pubkey-file>`) before that
  client can talk to the server again. There is no automated
  "trust-on-first-use with change detection" at v1 — that would be a
  reasonable future addition to `pdxtrust`, not `pdxcurl`.

### 3.4 The escape hatch that does not exist, on purpose

Classic `curl -k` disables certificate verification entirely — a
notorious footgun that trains operators to reach for it under deadline
pressure and then forget to remove it. `pdxcurl` has no equivalent flag.
An HTTPS request with no `--trust=` given is a parse-time argument error
(exit 2), not a runtime "verification skipped" warning. The only way to
talk to a server `pdxcurl` doesn't already trust is to go get its key
and `pdxtrust import` it first — a deliberately higher-friction path than
`-k`, and one that leaves an audit trail (`TrustAnchorRecord@0.1`'s
`IMPORT` action) of exactly when and by whom that trust decision was
made.

---

## 4. Request pipeline

1. **Parse** — `libpdx-url.url_parse(<url>)`. Failure: exit 2, no audit
   record written (nothing to audit yet — the argument itself was
   malformed, not a network intent).
2. **INTENT audit** — `libpdx-audit.audit_begin` with an
   `HttpRequestRecord@0.1` carrying every resolved argv field
   (`method`, `url`, `scheme`, header count, whether `--trust` was
   given) but `status: 0`, `result_code: INTENT`. Written *before* DNS.
3. **Resolve** — `--resolve=<ip>` bypasses this; otherwise
   `libpdx-net.net_resolve(host, A)`. Failure: `DNS_FAILED`, jump to
   step 7 (RESULT audit) with that code.
4. **Connect** — `libpdx-net.net_connect`. Failure: `CONN_REFUSED` or
   `TIMEOUT`, jump to step 7.
5. **TLS handshake** (https only) — `libpdx-net.net_tls_wrap` against
   the resolved `KIND_TLS_TRUST` cap. Emits `TlsHandshakeRecord@0.1`
   regardless of outcome. Failure: `TLS_KEY_MISMATCH` or
   `TLS_HANDSHAKE_FAILED`, jump to step 7.
6. **Send + receive** — request line/headers/body out; status-line/
   headers/body in, following redirects up to `--max-redirects` (each
   hop re-runs steps 3–6 against the new URL; `redirect_count`
   increments; a same-connection-reusable redirect, i.e. same host/port/
   scheme, reuses the socket per `libpdx-net`'s connection-reuse note).
   Failure: `HTTP_4XX`/`HTTP_5XX` is **not** a pipeline failure — a 404
   is a fully successful request/response cycle from `pdxcurl`'s
   perspective; the result_code still reports it (§7) but exit code 0
   with `--fail`-equivalent behavior is *not* the default (mirrors
   curl's own default of "print the error body, exit 0" — `pdxcurl`
   does not silently add a `--fail`-by-default behavior curl users
   wouldn't expect).
7. **RESULT audit** — second `HttpRequestRecord@0.1`, same `audit_id`,
   real `status`/`body_bytes`/`result_code`.
8. **Output** — §6.

---

## 5. `--dry-run` vs `--audit-only`

|  | DNS resolved? | TCP connect? | TLS handshake? | Bytes sent? | Audit record | Exit code family |
|---|---|---|---|---|---|---|
| (normal) | yes | yes | yes (https) | yes | INTENT + RESULT | per §7 |
| `--dry-run` | yes | no | no | no | one record, `result_code: DRY_RUN` | always 0 |
| `--audit-only` | no | no | no | no | one record, `result_code: AUDIT_ONLY` | always 0 |

`--dry-run` exists to answer "what exactly would be sent" — it fully
resolves DNS (so the printed record shows the real destination IP) and
computes the exact wire bytes (request line, headers in send order,
body if any) but stops before `net_connect`. `--audit-only` exists to
answer a narrower, cheaper question — "record that this was requested"
— and does not even resolve DNS, since the intent itself, not the
destination's current IP, is what's being logged. The two are not
layered (passing both is a parse-time argument conflict, exit 2) because
they answer genuinely different questions and combining them would
produce an ambiguous record.

---

## 6. Output modes

1. **Semantic-pipe** (the schema-registry-available future): typed
   records for status, headers (one record per header or a bounded
   batch — exact framing left to `libpdx-semantic-pipe`'s own
   conventions), and body chunks, distinct from the audit trail's
   `HttpRequestRecord@0.1` (the audit record is a summary; the
   semantic-pipe stream is the actual response content, typed).
2. **Line-based fallback** (today's reality, per the parent plan §0.2):
   a deferral header line, then `HTTP/1.1 200 OK` and headers as
   plain text to stdout, followed by the body — visually
   indistinguishable from classic curl's default output, which is
   deliberate: a human running `pdxcurl` interactively today should not
   have to care that the typed layer isn't wired up yet.
3. **`--output FILE`**: body only (never headers/status) written to
   `FILE`, regardless of which of the above two modes is active for the
   status/header reporting (which still goes to stdout/semantic-pipe).

---

## 7. Error taxonomy

| `result_code` | Meaning | Exit code |
|---|---|---|
| `OK` | Request completed; `status` holds the real HTTP status (including 4xx/5xx — see §4 step 6) | 0 |
| `DNS_FAILED` | Resolution failed (NXDOMAIN, timeout, malformed response) | 6 |
| `CONN_REFUSED` | TCP connect refused or reset | 7 |
| `TLS_KEY_MISMATCH` | Server's handshake signature did not verify under the pinned trust-anchor key | 8 |
| `TLS_HANDSHAKE_FAILED` | Any other TLS failure (protocol error, timeout mid-handshake) | 8 |
| `HTTP_4XX` / `HTTP_5XX` | Informational tag alongside `OK`-family exit 0 — see §4 step 6; not a distinct exit code | 0 |
| `TIMEOUT` | Connect or read exceeded `--timeout-ms` | 28 |
| `TOO_MANY_REDIRECTS` | Exceeded `--max-redirects` | 47 |
| `NO_PERMISSION` | `--trust=` cap not held / not found | 4 |
| `DRY_RUN` | `--dry-run` set | 0 |
| `AUDIT_ONLY` | `--audit-only` set | 0 |
| `INTENT` | (never a terminal state a human sees; internal INTENT-record marker) | n/a |

Exit-code numbering deliberately echoes classic curl's own exit-code
table (6=DNS, 7=connect, 8=TLS-ish "weird server reply" family,
28=timeout, 47=too-many-redirects) so a script written against curl's
exit-code conventions has a fighting chance of working unmodified
against `pdxcurl` — one small, free interoperability win that costs
nothing given this plan's error taxonomy needed a numbering scheme
either way.

---

## 8. `caps.decl` (design intent; final numbers per the parent plan §12.3)

```
KIND_USER               — invoker identity, audit attribution
KIND_TLS_TRUST           — placeholder 0x1A7 (parent plan §12.3); read-only
                           consumption of a pdxtrust-minted trust anchor;
                           absent from any http:// (non-TLS) code path
KIND_IPC_ENDPOINT        — semantic-pipe stdout + libpdx-audit journal
KIND_ELEVATE_CHANNEL     — NOT required by pdxcurl itself at v1 (no elevate
                           gate on an HTTP/HTTPS client request); listed here
                           only to document its absence explicitly, mirroring
                           the "declared for shape, not touched" convention
                           mkfs.pdxfs's own caps.decl uses for kinds a future
                           milestone might need and none does yet.
```

No `KIND_BLOCK_DEVICE`, no `KIND_PDXFS_*` — `pdxcurl` touches no
filesystem state of its own beyond `--output FILE` (a plain
`sys_open`/`sys_write`/`sys_close` against a bare path, same
self-contained-syscall posture `cat.pdx`/`mkfs.pdxfs` M2 use, not a
cap-mediated file handle).

---

## 9. Deliberate curl-parity gaps

**Permanent** (architectural, not "not yet"):
- No `-k`/`--insecure` (§3.4).
- No cookie jar, no proxy support, no multi-URL globbing (§2).
- No FTP/SFTP/SCP/other-protocol support — HTTP(S) only, ever; curl's
  do-everything protocol list is explicitly not a goal.

**Temporary** (this wave's honest scope cuts, tracked in the parent
plan's §11 debt inventory, revisited in a follow-up round):
- No public-CA-signed HTTPS (§3.3) — needs an X.509 mode this plan does
  not build.
- No HTTP/2, no HTTP/3 (parent plan §0.4) — HTTP/1.1 only.
- No IPv6 literal or AAAA support (parent plan §2.2/§6).
- ML-DSA-65 verification not yet available — TLS handshakes verify
  against Ed25519 only at v1 (parent plan §2.4); `pdxcurl --verbose`
  reports the negotiated `sig_algo` so this is visible per-invocation,
  not just in this document.

---

*End of document.*
