#!/bin/sh
# Runner for the optional zlib/gzip python3 interop target
# (docs/projects/compress.md §8, issue #252).
#
# Usage: sh tools/compress_zlib_interop_test.sh <arch-suffix>
#   <arch-suffix> selects bin/compress_zlib_interop<suffix> (32 or 64).
#
# Gated on python3 being installed: without it the target reports a skip
# and succeeds, so the manifest entry is safe on minimal machines
# (precedent: tools/openssl_interop_test.sh). Both directions are
# checked: this package compresses known data and python3's zlib/gzip
# modules decode it, then python3 compresses the same data and this
# package decodes that.
set -e

arch="$1"
if [ -z "$arch" ]; then
	echo "usage: $0 <arch-suffix>" >&2
	exit 2
fi
bin="bin/compress_zlib_interop$arch"

python_bin=$(command -v python3 || true)
if [ -z "$python_bin" ]; then
	echo "zlib interop OK (skipped: no python3 on PATH)"
	exit 0
fi

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

payload='zlib/gzip python3 interop payload, issue #252, docs/projects/compress.md'

timeout 30 "$bin" compress "$dir"

timeout 30 "$python_bin" -c "
import zlib, gzip, sys
payload = b'''$payload'''
with open('$dir/w.zlib', 'rb') as f:
	z = f.read()
with open('$dir/w.gz', 'rb') as f:
	g = f.read()
if zlib.decompress(z) != payload:
	sys.exit('python3 could not decode w.zlib produced by this package')
if gzip.decompress(g) != payload:
	sys.exit('python3 could not decode w.gz produced by this package')
with open('$dir/py.zlib', 'wb') as f:
	f.write(zlib.compress(payload, 6))
with open('$dir/py.gz', 'wb') as f:
	f.write(gzip.compress(payload, compresslevel=6))
"

timeout 30 "$bin" decompress "$dir"

echo "zlib interop OK"
