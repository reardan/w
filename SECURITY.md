# Security policy

## Reporting a vulnerability

Please report security problems privately, not in a public issue or pull
request.

Use GitHub's private vulnerability reporting: open the repository's
**Security** tab, choose **Advisories**, then **Report a vulnerability**
(direct link: <https://github.com/reardan/w/security/advisories/new>).
The report is visible only to you and the maintainers.

Include what you can of:

- the affected component (compiler, a backend, a `lib/` module, the
  release seeds or the build tooling) and the commit or release tag;
- a minimal reproducer (a `.w` source file and the command you ran);
- the impact you expect, for example a miscompile, a memory-safety bug in
  generated code or the runtime, or a tampered or mis-verified seed.

You should get an acknowledgement within a week. Fixes are developed in a
private advisory fork where possible and the advisory is published once a
fixed release is available.

## Supported versions

Only the latest release and `main` receive security fixes.

## Release integrity

The bootstrap seeds are pinned by sha256 in `SEEDS`, and `./wbuild`
refuses to run a downloaded seed whose hash does not match its pin. Each GitHub release also
carries a `SHA256SUMS` file covering its binaries (not yet signed).
