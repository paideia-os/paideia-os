#!/usr/bin/env python3
"""
tools/_shell_test_driver.py — pexpect-driven QEMU shell test harness.

Called by tools/run-shell-test.sh. Launches the kernel under QEMU with
serial on stdio, waits for the shell prompt, sends each scripted command,
resyncs on the prompt after each one, and prints the full transcript. On
--golden, exit-diffs against the expected transcript.

See #635 (r17-m5-001-serial-pty-driver-script).

Exit codes match the wrapper's contract:
   0  — success (+ golden match if requested)
   1  — golden mismatch or mid-run error
 124  — timeout waiting for prompt / EOF
"""

import argparse
import sys

import pexpect


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--script", required=True)
    ap.add_argument("--golden", default=None)
    ap.add_argument("--timeout", type=int, default=30)
    ap.add_argument("--prompt", default="$ ")
    args = ap.parse_args()

    with open(args.script) as f:
        commands = [line.rstrip("\n") for line in f if line.rstrip("\n") != ""]

    qemu_argv = [
        "-kernel", args.kernel,
        "-serial", "stdio",
        "-display", "none",
        "-monitor", "null",
        "-no-reboot",
        "-no-shutdown",
        "-m", "32M",
    ]

    child = pexpect.spawn(
        "qemu-system-x86_64", qemu_argv,
        timeout=args.timeout, encoding="utf-8",
    )

    transcript_parts = []
    exit_code = 0
    saw_first_prompt = False

    try:
        # Boot phase: wait for the first shell prompt.
        child.expect_exact(args.prompt)
        saw_first_prompt = True
        transcript_parts.append(child.before)
        transcript_parts.append(args.prompt)

        # Drive each scripted command and resync on the next prompt.
        for cmd_line in commands:
            child.sendline(cmd_line)
            idx = child.expect_exact([args.prompt, pexpect.EOF])
            transcript_parts.append(child.before)
            if idx == 0:
                transcript_parts.append(args.prompt)
            else:
                # Shell exited (e.g. via `exit`). Stop driving.
                break
    except pexpect.TIMEOUT:
        transcript_parts.append(child.before or "")
        sys.stderr.write(
            f"TIMEOUT after {args.timeout}s waiting for prompt {args.prompt!r}\n"
        )
        exit_code = 124
    except pexpect.EOF:
        transcript_parts.append(child.before or "")
        if not saw_first_prompt:
            sys.stderr.write(
                f"kernel exited before shell prompt {args.prompt!r} appeared\n"
            )
            exit_code = 1
    finally:
        if child.isalive():
            child.terminate(force=True)

    transcript = "".join(transcript_parts)
    sys.stdout.write(transcript)
    if not transcript.endswith("\n"):
        sys.stdout.write("\n")

    if exit_code == 0 and args.golden is not None:
        with open(args.golden) as f:
            expected = f.read()
        if transcript != expected:
            sys.stderr.write("SHELL TEST FAILED: transcript mismatch\n")
            exit_code = 1

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
