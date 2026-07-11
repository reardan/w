#!/bin/sh
# Runner for the optional openssl TLS interop target (issue #236).
#
# Usage: sh tools/openssl_interop_test.sh <arch-suffix>
#   <arch-suffix> selects bin/openssl_tls_interop<suffix> (32 or 64).
#
# Gated on openssl being installed: without it the target reports a skip
# and succeeds, so the manifest entry is safe on minimal machines. Every
# subcommand runs under timeout(1) so a wedged peer can never hang the
# build (the #236 failure mode); the harness itself also bounds every
# socket/pipe/reap wait internally.
set -e

arch="$1"
if [ -z "$arch" ]; then
	echo "usage: $0 <arch-suffix>" >&2
	exit 2
fi
bin="bin/openssl_tls_interop$arch"

openssl_bin=$(command -v openssl || true)
if [ -z "$openssl_bin" ]; then
	echo "openssl interop OK (skipped: no openssl on PATH)"
	exit 0
fi

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

# Throwaway self-signed ECDSA P-256 cert, the only server key shape both
# sides of our TLS stack support.
timeout 30 openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
	-keyout "$dir/key.pem" -out "$dir/cert.pem" -days 2 -nodes \
	-subj "/CN=localhost" >/dev/null 2>&1

timeout 60 "$bin" "$openssl_bin" "$dir/cert.pem" "$dir/key.pem"
