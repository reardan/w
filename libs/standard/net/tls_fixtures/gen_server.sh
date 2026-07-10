#!/bin/sh
# Regenerates the synthetic TLS-server fixtures in this directory (issue #203,
# part of #155): a throwaway self-signed ECDSA P-256 leaf certificate and its
# private key, used by libs/standard/net/tls_server_test.w to stand up a
# tls_accept server for the loopback interop test. Minted with OpenSSL 3.0.13.
# These are TEST keys, never used for anything real; the private key is
# committed on purpose so the tests need no key generation at run time. Run
# from this directory.
set -e

# Self-signed P-256 leaf (SAN test.w.example), ~15 year validity so the
# fixture never date-rots. server_p256_key.pem is the PKCS#8 private key;
# server_p256_cert.pem is the matching self-signed certificate.
openssl ecparam -name prime256v1 -genkey -noout -out sec1.tmp
openssl pkcs8 -topk8 -nocrypt -in sec1.tmp -out server_p256_key.pem

openssl req -x509 -new -key server_p256_key.pem -sha256 -days 5478 \
	-subj "/O=W Test/CN=test.w.example" \
	-addext "basicConstraints=critical,CA:FALSE" \
	-addext "keyUsage=critical,digitalSignature" \
	-addext "extendedKeyUsage=serverAuth" \
	-addext "subjectAltName=DNS:test.w.example" \
	-out server_p256_cert.pem

rm -f sec1.tmp
echo "== server_p256_cert.pem"
openssl x509 -in server_p256_cert.pem -noout -subject -dates -ext subjectAltName
