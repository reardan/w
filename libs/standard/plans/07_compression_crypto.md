# Plan: compression, archives, hashes, and secrets

## Target area

Base code directory: `libs/standard/compression/`, `libs/standard/archive/`,
and `libs/standard/crypto/`

Suggested modules:

- `libs.standard.compression.zlib`
- `libs.standard.compression.gzip`
- `libs.standard.compression.bz2`
- `libs.standard.compression.lzma`
- `libs.standard.archive.zipfile`
- `libs.standard.archive.tarfile`
- `libs.standard.crypto.hashlib`
- `libs.standard.crypto.hmac`
- `libs.standard.crypto.secrets`
- `libs.standard.crypto.base64`

## Python 3.14 reference implementations

Consult these CPython sources first:

- `Lib/gzip.py` and `Modules/zlibmodule.c` - gzip wrapper and zlib binding.
- `Lib/zipfile/` - ZIP format reader/writer.
- `Lib/tarfile.py` - TAR format reader/writer and extraction filters.
- `Lib/bz2.py`, `Modules/_bz2module.c`.
- `Lib/lzma.py`, `Modules/_lzmamodule.c`.
- `Lib/hashlib.py`, `Modules/_hashopenssl.c`, `Modules/md5module.c`,
  `Modules/sha1module.c`, `Modules/sha2module.c`.
- `Lib/hmac.py` - HMAC construction and compare_digest behavior.
- `Lib/secrets.py` - secure token helpers.
- `Lib/base64.py` and `Modules/binascii.c` - binary-to-text encodings.

## Current W starting point

- No compression, archive, hash, HMAC, base64, or secure random modules exist.
- Low-level Linux syscalls include file I/O and likely access to random devices
  through normal file reads, but there is no `getrandom` wrapper yet.
- W can call C libraries through FFI, which is the pragmatic path for zlib/OpenSSL
  style primitives.

## Goals

1. Add safe binary-to-text encoding first (`base64`, hex helpers).
2. Add cryptographic hashes and HMAC with constant-time comparison.
3. Add secure random token helpers backed by OS randomness.
4. Add zlib/gzip and archive readers/writers in staged form.
5. Make archive extraction safe by default.

## Non-goals for MVP

- No homegrown cryptographic algorithms.
- No TLS here; TLS belongs in networking and should use the same crypto backend.
- No unsafe archive extraction helpers that write outside the destination.
- No full compression matrix if C libraries are missing in the environment.

## API sketch

`crypto/base64.w`

- `char* base64_b64encode(char* data, int length)`
- `bytes_result base64_b64decode(char* text)`
- `char* base64_urlsafe_b64encode(char* data, int length)`
- `bytes_result base64_urlsafe_b64decode(char* text)`
- `char* hex_encode(char* data, int length)`
- `bytes_result hex_decode(char* text)`

`crypto/hashlib.w`

- `hash_ctx* hash_new(char* name)`
- `void hash_update(hash_ctx* ctx, char* data, int length)`
- `bytes_result hash_digest(hash_ctx* ctx)`
- `char* hash_hexdigest(hash_ctx* ctx)`
- Convenience: `sha256`, `sha1`, `md5` if available.

`crypto/hmac.w`

- `bytes_result hmac_digest(char* key, int key_len, char* msg, int msg_len, char* digest_name)`
- `char* hmac_hexdigest(...)`
- `int hmac_compare_digest(char* a, int alen, char* b, int blen)`

`crypto/secrets.w`

- `bytes_result secrets_token_bytes(int nbytes)`
- `char* secrets_token_hex(int nbytes)`
- `char* secrets_token_urlsafe(int nbytes)`
- `int secrets_randbelow(int upper_bound)`

`compression/gzip.w`

- `bytes_result gzip_compress(char* data, int length)`
- `bytes_result gzip_decompress(char* data, int length)`

`archive/tarfile.w`

- `tar_reader* tar_open_read(char* path)`
- `tar_entry* tar_next(tar_reader* reader)`
- `int tar_extract_all_safe(char* archive, char* dest)`

`archive/zipfile.w`

- `zip_reader* zip_open_read(char* path)`
- `list[char*] zip_namelist(zip_reader* reader)`
- `bytes_result zip_read(zip_reader* reader, char* name)`

## Implementation phases

### Phase 1: bytes result type

- Add a shared `bytes_result` struct under `libs.standard.crypto.bytes` or a
  common utility module: data pointer, length, ok, error.
- Tests: ownership, empty bytes, allocation failure behavior if representable.

### Phase 2: base64 and hex

- Implement pure W base64 from `base64.py` behavior.
- Support standard and URL-safe alphabets.
- Validate padding rules.
- Tests: RFC vectors, empty input, invalid characters, missing padding policy.

### Phase 3: OS randomness and secrets

- Add `getrandom` syscall wrapper or read `/dev/urandom` with retry.
- Implement unbiased `randbelow` by rejection sampling.
- Tests: length, bounds, invalid upper_bound, no deterministic assumptions.

### Phase 4: hashes and HMAC

- Prefer OpenSSL EVP through `c_import`/`extern` if available.
- If OpenSSL is not acceptable, implement SHA-256 in pure W first; do not expose
  weak hashes unless required for compatibility.
- Implement constant-time digest comparison.
- Tests: NIST SHA-256 vectors, HMAC RFC vectors, compare timing-independent loop
  shape by code review plus functional tests.

### Phase 5: zlib/gzip

- Bind zlib for deflate/inflate.
- Implement gzip header/trailer handling or use zlib gzip mode if exposed.
- Tests: compress/decompress round trip, Python-generated gzip fixture,
  truncated input, bad checksum.

### Phase 6: tar and zip

- TAR: implement uncompressed ustar read/list/extract first.
- ZIP: implement stored and deflated entries after zlib exists.
- Extraction must normalize paths and reject absolute paths, `..`, symlink
  escapes, and device files by default.
- Tests: list archive, read file, safe extraction rejects traversal fixtures.

## Compatibility notes from Python

- Python's `hashlib` delegates to OpenSSL but also has built-in fallbacks. W can
  start with one backend as long as unsupported algorithms fail clearly.
- Python `tarfile` added extraction filters for safety. W should make safe
  extraction the only public extraction helper in MVP.
- Python compression modules expose streaming APIs. W can start whole-buffer and
  add streaming once `lib.stream` integration is designed.

## Acceptance criteria

- Base64/hex match Python outputs for vectors.
- Secure random functions use OS randomness and validate bounds.
- SHA-256 and HMAC-SHA256 match published vectors.
- Gzip can round-trip data and reject malformed input.
- Archive extraction cannot write outside the destination in traversal tests.
