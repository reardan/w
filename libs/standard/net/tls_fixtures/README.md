# TLS server test fixtures (issue #203, part of #155)

Checked-in credential material for `libs/standard/net/tls_server_test.w`.
Loaded from disk (and injected as bytes) at test time; no test touches the
network.

## Files

Minted 2026-07-10 by `gen_server.sh` (OpenSSL 3.0.13):

- `server_p256_cert.pem` — a self-signed ECDSA P-256 leaf certificate
  (subject/issuer `CN=test.w.example`, SAN `DNS:test.w.example`,
  `keyUsage=digitalSignature`, `extendedKeyUsage=serverAuth`, ~15 year
  validity so the fixture never date-rots).
- `server_p256_key.pem` — the matching private key in PKCS#8 form.

These are **throwaway TEST keys**, never used for anything real; the private
key is committed on purpose so the loopback interop test needs no key
generation at run time. Rerunning `gen_server.sh` mints a fresh key + cert
pair (the test derives the public key from the key and cross-checks it
against the certificate, so no expectations need editing).

## What the tests do with them

`libs/standard/net/tls_server_test.w` uses this cert+key to stand up a
`tls_accept` server and drives our own `tls_connect` client against it —
both in-memory (deterministic 3-pass replay) and over a real `socketpair`
via `fork()`. The client trusts the leaf with `insecure_skip_verify` (chain
+ hostname only) while still verifying the server's ECDSA `CertificateVerify`
signature and `Finished` MAC, so the two halves are proven to interoperate
end to end with no external tools.
