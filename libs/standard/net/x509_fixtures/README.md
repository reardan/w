# X.509 test fixtures (issue #199, part of #155)

Checked-in certificate and key material for `libs/standard/net/x509_test.w`
and `asn1_test.w`. Everything here is loaded from disk at test time; no test
touches the network.

## Real certificates

Fetched 2026-07-10. Live TLS chains could not be captured in the build
environment (the egress proxy re-mints server certificates), so the real
certificates come from files published in public GitHub repositories:

- `isrg_root_x1.pem`, `le_r11.pem` — ISRG Root X1 (RSA-4096) and the
  Let's Encrypt R11 intermediate (RSA-2048, signed by ISRG Root X1 with
  sha256WithRSAEncryption). Source: `letsencrypt/website` repository,
  `static/certs/isrgrootx1.pem` and `static/certs/2024/r11.pem` (the same
  files letsencrypt.org/certs serves).
- `google_leaf.pem`, `gts_ca_1c3.pem`, `gts_root_r1.pem` — a real
  www.google.com chain: RSA-2048 leaf (SAN `www.google.com`, expired
  2023-03-27, tests pin `now` = 2023-02-15) signed by GTS CA 1C3
  (RSA-2048), signed by GTS Root R1 (RSA-4096); both links
  sha256WithRSAEncryption. Source: `golang/go` tag `go1.24.0`,
  `src/crypto/x509/verify_test.go` (`googleLeaf`, `gtsIntermediate`,
  `gtsRoot` constants).
- `trustasia_leaf.pem`, `trustasia_ca.pem`, `digicert_global_root_ca.pem` —
  a real DigiCert-rooted chain: `*.tm.cn` leaf (EC P-256, signed
  ecdsa-with-SHA384 by a P-384 CA — parse-only in the tests), TrustAsia ECC
  OV TLS Pro CA (EC P-384, signed by DigiCert Global Root CA with
  sha384WithRSAEncryption — exercises the RSA PKCS#1 v1.5 SHA-384 verify
  path on real certificates), DigiCert Global Root CA (RSA-2048). Source:
  `golang/go` tag `go1.24.0`, `src/crypto/x509/verify_test.go`
  (`trustAsiaLeaf`, `trustAsiaSHA384Intermediate`, `digicertRoot`).

Field expectations asserted in the tests (serial, SAN, validity, key sizes)
were cross-checked against `openssl x509 -text` (OpenSSL 3.0.13) at check-in
time.

## Synthetic certificates and keys

Minted 2026-07-10 by `gen_synthetic.sh` (OpenSSL 3.0.13); see that script
for the exact shapes. Chains: an RSA root/intermediate signing EC and RSA
leaves (PKCS#1 v1.5 SHA-256/384 and RSA-PSS SHA-256/384 with salt length =
hash length), and an all-ECDSA P-256 chain. Negatives: expired leaf,
self-signed leaf, unknown-critical-extension leaf, and a pathLen violation
(`int_rsa` has `pathlen:0` but signs `int_rsa2`, which signs `leaf_deep`).
`key_p256_sec1.pem`/`key_p256_pkcs8.pem` are the same throwaway P-256 test
key in both PEM encodings; `key_p384_pkcs8.pem` is the wrong-curve negative.
The CA private keys are not committed; rerunning the script mints a fresh
universe and requires updating the serial/date expectations in
`../x509_test.w`.

The tests pass a fixed `now` (2026-08-01 = 1785542400 for the synthetic
certs) so date checks never rot: the expired-leaf fixture has a one-day
validity ending 2026-07-11 and the not-yet-valid case re-checks a good 2026
cert against `now` = 2020-01-01.
