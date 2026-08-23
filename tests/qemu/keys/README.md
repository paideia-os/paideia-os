# PaideiaOS Dev Signing Keys

This directory holds the development ML-DSA-65 signing keys used by the
PaideiaOS bootable-image (pdxb) signing pipeline in the QEMU test flow.

## Files

- `pdxb-dev.mldsa65.pub`  — 1952-byte ML-DSA-65 public key (dev).
- `pdxb-dev.mldsa65.priv` — 4032-byte ML-DSA-65 private key (dev).

## Status: placeholder

Both key files are **placeholders**, not real ML-DSA-65 keys. The in-tree
ML-DSA-65 toolchain (keygen, sign, verify) is not yet available at the point
these files were created, so the placeholders exist to let downstream tools
mmap a byte blob of exactly the right length while the real keygen path is
still being built.

Layout of each placeholder:

- 19 or 20 ASCII header bytes identifying the file as a dev placeholder
  (`PDXB_DEV_PUB_KEY_v0` / `PDXB_DEV_PRIV_KEY_v0`).
- Remaining bytes are zero-filled out to the ML-DSA-65 spec size.

Any tool that treats these bytes as an actual ML-DSA-65 key will produce
invalid signatures and invalid verifications — that is intentional. Once
the real keygen tool lands, both files must be regenerated with genuine
key material and the header magic will disappear.

## In-tree by design

Both the public and the private placeholder are checked into the tree on
purpose. This is a **development-only** key pair used by local QEMU smoke
tests and reproducible-build checks; it is not, and must not become, a
production signing key. Do not copy these files into any release, staging,
or distribution flow.

Once the real ML-DSA-65 toolchain is available:

1. Regenerate `pdxb-dev.mldsa65.{pub,priv}` with the in-tree keygen tool.
2. Keep the pub in-tree; keep the dev priv in-tree only if the whole team
   agrees a shared dev private key is acceptable for local smoke tests.
   Otherwise, gitignore the priv and document how each developer generates
   their own dev pair.
3. Every non-dev signing key (staging, release, per-developer) must live
   outside this repository entirely.

## Rotation policy

- **Dev key**: rotate whenever the ML-DSA-65 wire format or key encoding
  changes, or whenever the placeholder is replaced by real key material.
  On rotation, bump the header magic suffix so consumers can detect an
  outdated dev key mmap.
- **Non-dev keys**: rotation policy for staging/release keys lives with
  the release process, not here. Nothing in this directory is authoritative
  for anything beyond local development.

## Trust boundary

A signature verifiable by `pdxb-dev.mldsa65.pub` proves only that an image
was built on a machine that had access to the in-tree dev private key. It
carries **no** authenticity or integrity guarantee for any user-facing
artifact.
