#!/bin/sh
# Regenerates the synthetic X.509 fixtures in this directory with openssl.
# Run from this directory. Minted 2026-07-10 with OpenSSL 3.0.13; the
# committed files are the source of truth for the tests (which assert
# minted serials/dates), so rerunning this script means updating the
# expectations in ../x509_test.w. CA private keys are throwaway and are
# not committed; only the P-256 test keys used by the key-loading tests
# are kept.
set -e

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- keys -------------------------------------------------------------------
openssl genrsa -out "$tmp/ca_rsa.key" 2048 2>/dev/null
openssl genrsa -out "$tmp/int_rsa.key" 2048 2>/dev/null
openssl genrsa -out "$tmp/int_rsa2.key" 2048 2>/dev/null
openssl genrsa -out "$tmp/leaf_rsa.key" 2048 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/ca_ec.key"
openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/int_ec.key"
openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/leaf_ec.key"

# Committed P-256 key pair for the private-key loading tests: the same key
# in SEC1 and PKCS#8 form, plus a P-384 PKCS#8 key as the wrong-curve
# negative. These are TEST keys, never used for anything real.
openssl ecparam -name prime256v1 -genkey -noout -out key_p256_sec1.pem
openssl pkcs8 -topk8 -nocrypt -in key_p256_sec1.pem -out key_p256_pkcs8.pem
openssl ecparam -name secp384r1 -genkey -noout -out "$tmp/p384.key"
openssl pkcs8 -topk8 -nocrypt -in "$tmp/p384.key" -out key_p384_pkcs8.pem

# --- RSA root + intermediate -------------------------------------------------
openssl req -x509 -new -key "$tmp/ca_rsa.key" -sha256 -days 7300 \
	-subj "/O=W Test/CN=W Test RSA Root" \
	-addext "basicConstraints=critical,CA:TRUE" \
	-addext "keyUsage=critical,keyCertSign,cRLSign" \
	-out ca_rsa.pem

cat > "$tmp/int.ext" <<EOF
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,digitalSignature,keyCertSign,cRLSign
EOF
openssl req -new -key "$tmp/int_rsa.key" \
	-subj "/O=W Test/CN=W Test RSA Intermediate" -out "$tmp/int_rsa.csr"
openssl x509 -req -in "$tmp/int_rsa.csr" -CA ca_rsa.pem -CAkey "$tmp/ca_rsa.key" \
	-sha256 -days 7300 -extfile "$tmp/int.ext" -out int_rsa.pem 2>/dev/null

# --- good EC leaf (SAN with wildcard and non-DNS entries, EKU) ---------------
cat > "$tmp/leaf.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:test.w.example,DNS:*.wild.w.example,IP:192.0.2.7,email:cert@w.example
EOF
openssl req -new -key "$tmp/leaf_ec.key" \
	-subj "/O=W Test/CN=test.w.example" -out "$tmp/leaf_ec.csr"
openssl x509 -req -in "$tmp/leaf_ec.csr" -CA int_rsa.pem -CAkey "$tmp/int_rsa.key" \
	-sha256 -days 3650 -extfile "$tmp/leaf.ext" -out leaf_ec.pem 2>/dev/null

# --- RSA leaf signed sha384WithRSAEncryption ---------------------------------
openssl req -new -key "$tmp/leaf_rsa.key" \
	-subj "/O=W Test/CN=test.w.example" -out "$tmp/leaf_rsa.csr"
openssl x509 -req -in "$tmp/leaf_rsa.csr" -CA int_rsa.pem -CAkey "$tmp/int_rsa.key" \
	-sha384 -days 3650 -extfile "$tmp/leaf.ext" -out leaf_rsa384.pem 2>/dev/null

# --- RSA-PSS signed leaves (saltlen = hash length) ---------------------------
openssl x509 -req -in "$tmp/leaf_ec.csr" -CA int_rsa.pem -CAkey "$tmp/int_rsa.key" \
	-sha256 -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 \
	-days 3650 -extfile "$tmp/leaf.ext" -out leaf_pss256.pem 2>/dev/null
openssl x509 -req -in "$tmp/leaf_ec.csr" -CA int_rsa.pem -CAkey "$tmp/int_rsa.key" \
	-sha384 -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:48 \
	-days 3650 -extfile "$tmp/leaf.ext" -out leaf_pss384.pem 2>/dev/null

# --- all-ECDSA chain ----------------------------------------------------------
openssl req -x509 -new -key "$tmp/ca_ec.key" -sha256 -days 7300 \
	-subj "/O=W Test/CN=W Test EC Root" \
	-addext "basicConstraints=critical,CA:TRUE" \
	-addext "keyUsage=critical,keyCertSign,cRLSign" \
	-out ca_ec.pem
openssl req -new -key "$tmp/int_ec.key" \
	-subj "/O=W Test/CN=W Test EC Intermediate" -out "$tmp/int_ec.csr"
openssl x509 -req -in "$tmp/int_ec.csr" -CA ca_ec.pem -CAkey "$tmp/ca_ec.key" \
	-sha256 -days 7300 -extfile "$tmp/int.ext" -out int_ec.pem 2>/dev/null
openssl x509 -req -in "$tmp/leaf_ec.csr" -CA int_ec.pem -CAkey "$tmp/int_ec.key" \
	-sha256 -days 3650 -extfile "$tmp/leaf.ext" -out leaf_ec_chain.pem 2>/dev/null

# --- negatives -----------------------------------------------------------------
# Expired: one-day validity; the tests use a fixed `now` weeks after minting.
openssl x509 -req -in "$tmp/leaf_ec.csr" -CA int_rsa.pem -CAkey "$tmp/int_rsa.key" \
	-sha256 -days 1 -extfile "$tmp/leaf.ext" -out leaf_expired.pem 2>/dev/null

# Self-signed leaf: chains to nothing in the store.
openssl req -x509 -new -key "$tmp/leaf_ec.key" -sha256 -days 3650 \
	-subj "/O=W Test/CN=test.w.example" \
	-addext "basicConstraints=critical,CA:FALSE" \
	-addext "keyUsage=critical,digitalSignature" \
	-addext "extendedKeyUsage=serverAuth" \
	-addext "subjectAltName=DNS:test.w.example" \
	-out selfsigned_leaf.pem

# Unknown critical extension: parser must reject the whole certificate.
cat > "$tmp/crit.ext" <<EOF
basicConstraints=critical,CA:FALSE
subjectAltName=DNS:test.w.example
1.2.3.4=critical,ASN1:UTF8String:unsupported critical payload
EOF
openssl x509 -req -in "$tmp/leaf_ec.csr" -CA int_rsa.pem -CAkey "$tmp/int_rsa.key" \
	-sha256 -days 3650 -extfile "$tmp/crit.ext" -out leaf_critext.pem 2>/dev/null

# pathLen violation: int_rsa carries pathlen:0 yet signs a second CA, so a
# leaf under that second CA needs more intermediates than int_rsa allows.
openssl req -new -key "$tmp/int_rsa2.key" \
	-subj "/O=W Test/CN=W Test RSA Intermediate 2" -out "$tmp/int_rsa2.csr"
openssl x509 -req -in "$tmp/int_rsa2.csr" -CA int_rsa.pem -CAkey "$tmp/int_rsa.key" \
	-sha256 -days 7300 -extfile "$tmp/int.ext" -out int_rsa2.pem 2>/dev/null
openssl x509 -req -in "$tmp/leaf_ec.csr" -CA int_rsa2.pem -CAkey "$tmp/int_rsa2.key" \
	-sha256 -days 3650 -extfile "$tmp/leaf.ext" -out leaf_deep.pem 2>/dev/null

# --- record what was minted -----------------------------------------------------
for f in ca_rsa int_rsa leaf_ec leaf_rsa384 leaf_pss256 leaf_pss384 \
         ca_ec int_ec leaf_ec_chain leaf_expired selfsigned_leaf \
         leaf_critext int_rsa2 leaf_deep; do
	echo "== $f"
	openssl x509 -in "$f.pem" -noout -serial -dates -subject -issuer
done
