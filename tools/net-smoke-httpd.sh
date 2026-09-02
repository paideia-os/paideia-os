#!/usr/bin/env bash
# R98.M2-001 (paideia-os #2102): minimal single-shot TCP responder for the
# networking smoke lane.
#
# Started by the `boot_net_smoke` composite in `tools/run-smoke.sh` BEFORE
# the R94 off-box witness boots, killed AFTER it exits. Serves ONE
# connection on ${PORT} with a fixed ${PAYLOAD} reply, then closes.
#
# Usage:
#   PORT=<n>       (default: 5555 — matches PAIDEIA_HOSTFWD='tcp::5555-:5555')
#   PAYLOAD=<str>  (default: "PONG" — 4 bytes, pinned by
#                   tests/expected-r94-tcp-offbox.golden's `bytes=4`)
#   MODE=<echo|http>
#                  echo (default): send PAYLOAD then close (R94 witness path).
#                  http:            wrap PAYLOAD in an HTTP/1.0 200 OK envelope
#                                   with Content-Length -- for future R100+
#                                   pdxcurl-style smokes that talk HTTP.
#   HANG=<seconds> (default: 3) — how long to hold the listen socket open
#                                  before giving up if nothing connects. The
#                                  composite kills the responder anyway on
#                                  exit; this is a defence against forever-
#                                  hangs when a witness boot fails silently.
#
# Exit codes:
#   0    — one client connected + PAYLOAD sent + closed cleanly
#   1    — python3 / nc absent, or bind refused (port in use, etc.)
#   124  — HANG budget elapsed with no client connection
#
# Preference: python3 (universally available, deterministic byte-exact
# writes, `MODE=http` supported). `nc -l -q 1 -N` fallback if python3 is
# missing (echo-mode only; http-mode requires python3).
#
# Referenced by: design/networking/qemu-net-invocation.md §4 (host
# prerequisites), design/round-retrospectives/r98-closed.md M2 disposition.

set -u

PORT="${PORT:-5555}"
PAYLOAD="${PAYLOAD:-PONG}"
MODE="${MODE:-echo}"
HANG="${HANG:-3}"

# Prefer python3: byte-exact write + accept-timeout + http envelope in one
# expression. Falls back to nc when python3 is missing (echo mode only).
if command -v python3 >/dev/null 2>&1; then
    exec python3 - <<PYEOF
import socket, sys, os

port    = int(os.environ.get("PORT", "${PORT}"))
payload = os.environ.get("PAYLOAD", "${PAYLOAD}")
mode    = os.environ.get("MODE",    "${MODE}")
hang    = float(os.environ.get("HANG", "${HANG}"))

if mode == "http":
    body = payload.encode("utf-8")
    reply = (
        b"HTTP/1.0 200 OK\r\n"
        b"Content-Length: " + str(len(body)).encode("ascii") + b"\r\n"
        b"Connection: close\r\n"
        b"\r\n"
    ) + body
else:
    reply = payload.encode("utf-8")

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    srv.bind(("127.0.0.1", port))
except OSError as e:
    print(f"net-smoke-httpd: bind port {port} refused: {e}", file=sys.stderr)
    sys.exit(1)
srv.listen(1)
srv.settimeout(hang)
try:
    conn, _peer = srv.accept()
except socket.timeout:
    print(f"net-smoke-httpd: no client within {hang}s", file=sys.stderr)
    sys.exit(124)
try:
    # Drain whatever the guest sends (bounded — the R94 witness sends 4 B "PING"
    # then reads; we do NOT block waiting for more).
    conn.settimeout(0.5)
    try:
        conn.recv(4096)
    except socket.timeout:
        pass
    conn.sendall(reply)
finally:
    try:
        conn.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    conn.close()
    srv.close()
sys.exit(0)
PYEOF
fi

if command -v nc >/dev/null 2>&1; then
    if [[ "${MODE}" == "http" ]]; then
        echo "net-smoke-httpd: MODE=http requires python3 (nc fallback covers echo only)" >&2
        exit 1
    fi
    # nc -l <port> -q 1: after EOF on stdin, wait 1s then close.
    # Openbsd nc uses -N to shut down on EOF; ncat uses -q. Try both.
    if nc -h 2>&1 | grep -q -- '-N'; then
        printf '%s' "${PAYLOAD}" | nc -l -N "${PORT}"
    else
        printf '%s' "${PAYLOAD}" | nc -l -q 1 "${PORT}"
    fi
    exit $?
fi

echo "net-smoke-httpd: neither python3 nor nc found" >&2
exit 1
