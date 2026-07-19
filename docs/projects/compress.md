# `libs/extras/compress`: CRC-32, DEFLATE, zlib, and gzip

Status: stage 1 implemented (2026-07-16 — checksums, conformant
inflater, zlib/gzip wrappers, stored-blocks deflate; see the test
targets `compress_*_test`). Stage 2 (2026-07-18 — LZ77 hash-chain
matcher with lazy matching, fixed-Huffman `DEFLATE_LEVEL_FAST`,
dynamic-Huffman + block-splitting `DEFLATE_LEVEL_BEST`) is implemented
in `libs/extras/compress/deflate.w`, folding §3's originally-separate
stage 2b (fixed Huffman + LZ77) and stage 3 (lazy matching + dynamic
Huffman) into one PR rather than staging lazy matching behind dynamic
Huffman as §3/§9 originally sketched; the optional zlib-interop
cross-validation target from §8 remains unimplemented. Originally
written as the design doc to satisfy issue
#252's own
requirement before this package is picked up: "`libs/extras/compress/`
— CRC32 + DEFLATE (inflate first): the largest single chunk (~1–2k
lines), should get its own project doc when picked up." Companion to
`docs/projects/version_control.md` (wave 3 lists `compress/` as a
sibling of `vcs/delta.w`, "deliberately outside `vcs/`") and
`docs/projects/build_system_next.md` (Direction 3, the shared build
cache). Scope: a pure-W, seed-independent package implementing raw
DEFLATE (RFC 1951), the zlib wrapper (RFC 1950), the gzip wrapper (RFC
1952), and the two checksums they need (CRC-32, Adler-32). No C/zlib
FFI — consistent with this repo's "native" posture elsewhere (the TLS
stack in `libs/standard/net` implements its own crypto rather than
binding OpenSSL; see `libs/standard/plans/11_native_http_tls.md`).

## 0. Why this doc, and a naming/location note

Nothing under `libs/`, `lib/`, or `structures/` does compression today
(confirmed by grep: no `crc32`/`deflate`/`inflate`/`zlib`/`gzip` hits
anywhere in source). Three independent parts of the tree are already
waiting on it:

- `libs/extras/vcs/cas.w`'s header comment says objects are stored
  "**Uncompressed initially** — compression is an encoding slot to
  fill later, not a semantic requirement," and
  `docs/projects/version_control.md` names `compress/` as the "gateway
  to optional git-format interop" (git's loose-object format is
  `zlib_compress(header + payload)` — literally this package's
  `zlib.w`, once it exists).
- `libs/standard/plans/11_native_http_tls.md` (plan 11, the native TLS
  stack) already forward-references this work by name: "No
  gzip/deflate response decoding — send `Accept-Encoding: identity`
  until plan 07 lands inflate" (line 384–385). "Plan 07" is
  `libs/standard/plans/07_compression_crypto.md`, an older CPython-
  mapped brainstorm doc that scoped a much broader
  `libs/standard/compression/` + `libs/standard/archive/` +
  `libs/standard/crypto/` package (gzip, bz2, lzma, zip, tar, hashlib,
  hmac, secrets — see its "Implementation phases" section). Issue #252
  supersedes the gzip/deflate slice of that plan with a narrower,
  concretely-scoped `libs/extras/compress/` package. **Open question
  for the maintainer** (repeated in §10): reconcile the two — either
  retarget `11_native_http_tls.md`'s "plan 07" pointer at this doc, or
  have a future `libs/standard/compression/gzip.w` re-export
  `libs/extras/compress/gzip.w` if the broader archive/crypto plan is
  ever picked up. This doc does not resolve that; it just flags the
  overlap so nobody implements gzip twice.
- `docs/projects/build_system_next.md` Direction 3 sketches a dumb
  content-addressed HTTP cache for `wexec` ("`GET /cas/<key>` →
  tarball of the target's declared outputs"); gzip-wrapping that
  transfer is a natural, low-risk win once this package exists.

`libs/extras/` is the right home, not `libs/standard/`: like
`libs/extras/vcs/`, nothing here enters `w.w`'s seed import closure
(`w.w`, `grammar/`, `code_generator/`, `compiler/`, the auto-imported
container runtime, and the `c_import`/`c_preprocessor`/
`parser_generator` extras it pulls in — see CLAUDE.md's "Seed
constraint"). Compression is a leaf library nothing in the compiler
depends on, so current language syntax is fine throughout and no
`SEEDS` bump is implicated by this work.

## 1. Format survey

Three RFCs, one algorithm at the core:

| RFC | Name | What it adds over raw DEFLATE | Checksum | Typical producer |
|---|---|---|---|---|
| 1951 | DEFLATE | (nothing — this is the payload format itself) | none | the compressed byte stream inside both wrappers below |
| 1950 | zlib | 2-byte header (`CMF`/`FLG`, compression method + window size + a 5-bit `FCHECK` making the 16-bit header a multiple of 31) + optional 4-byte preset-dictionary id + 4-byte trailer | **Adler-32** (big-endian) | git loose objects, PNG chunks, TLS `DEFLATE` (obsolete), zlib library default |
| 1952 | gzip | 10-byte fixed header (magic `1f 8b`, method, flag byte, mtime, extra flags, OS id) + optional filename/comment/extra/header-CRC fields gated by flag bits + 8-byte trailer | **CRC-32** (little-endian) + uncompressed size mod 2³² | `.gz` files, HTTP `Content-Encoding: gzip`, `git` pack/bundle transport in places |

Both wrappers are "envelope + one DEFLATE stream + a checksum of the
*uncompressed* data" — the interesting algorithmic work is entirely in
DEFLATE; zlib.w and gzip.w are thin framing layers over inflate.w/
deflate.w plus a checksum call.

**Why the two checksums differ, and which consumer needs which
wrapper**: Adler-32 (two 16-bit sums mod 65521, combined as
`(s2 << 16) | s1`) is cheaper to compute in software than a table-
driven CRC-32 but weaker at catching certain error patterns — zlib
picked it for exactly that speed tradeoff in the 1990s; gzip predates
zlib and inherited CRC-32 from the earlier `compress`/Unix tooling
lineage. Neither speed difference matters at this repo's scale (no
target here is gigabytes/second), so the choice of wrapper is about
*consumer expectations*, not performance:

- **VCS object store** (`cas.w`) → **zlib**, because that is what git
  object files actually are on disk; matching it is the entire point
  of the "gateway to git-format interop" framing.
- **HTTP `Content-Encoding`** (`http_client.w`, the web server) →
  **gzip**, the only content-coding besides `identity` any real HTTP
  peer sends (`deflate` Content-Encoding exists in the spec but is
  notoriously ambiguous in the wild — some servers send raw DEFLATE,
  some send a zlib-wrapped stream, both under the same header value —
  and is rare enough that this doc recommends *not* implementing it;
  gzip is unambiguous and universal).
- **`wexec` shared build cache** (`build_system_next.md` Direction 3)
  → either works; **gzip** is the natural pick since the transport is
  already HTTP and the payload (a tarball of build outputs) has no
  reason to want zlib's slightly more compact 2-byte header over
  gzip's self-describing one.

## 2. The fundamentals, distilled

### 2.1 DEFLATE block structure (RFC 1951 §3.2)

A DEFLATE stream is a sequence of blocks. Each starts with a 3-bit
header (read LSB-first, as all DEFLATE bit fields are): `BFINAL` (1
bit, set on the last block) then `BTYPE` (2 bits): `00` stored, `01`
fixed Huffman, `10` dynamic Huffman, `11` reserved (a stream error).

- **Stored** (`00`): the header is padded out to the next byte
  boundary, then `LEN` (u16 LE), `NLEN` (u16 LE, one's complement of
  `LEN`, a self-check), then `LEN` literal bytes. No compression, no
  Huffman tables — this is the trivial, always-correct encoding and
  exactly stage 2a below.
- **Fixed Huffman** (`01`): literal/length symbols (256 for byte
  values 0–255, 256 for end-of-block, 257–285 for length codes 3–258)
  and distance symbols (0–29, offsets 1–32768) use code lengths fixed
  by the spec itself (literal/length: 8 bits for symbols 0–143, 9 bits
  for 144–255, 7 bits for 256–279, 8 bits for 280–287; distance: 5
  bits flat). No table transmission needed — the decoder derives the
  canonical codes from these fixed lengths. This is stage 2b's target.
- **Dynamic Huffman** (`10`): the block transmits its own code-length
  arrays, themselves Huffman-coded: `HLIT` (5 bits, literal/length
  code count − 257), `HDIST` (5 bits, distance code count − 1),
  `HCLEN` (4 bits, code-length-alphabet code count − 4), then `HCLEN`
  3-bit code lengths for a 19-symbol "code length alphabet" in a fixed
  permuted order (16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13,
  2, 14, 1, 15 — RFC 1951 §3.2.7), which builds a small Huffman table
  used to decode the *real* literal/length and distance code-length
  arrays (symbols 0–15 are literal lengths, 16 repeats the previous
  length 3–6 times, 17 repeats zero-length 3–10 times, 18 repeats
  zero-length 11–138 times — the run-length trick that keeps the
  header compact). Everything downstream (literal/length and distance
  Huffman tables) is built from those two length arrays exactly as in
  the fixed case, just with block-specific lengths instead of the
  spec's fixed ones.
- **Back-references**: length/distance pairs after a length symbol
  (257–285, each with 0–5 extra bits specifying the exact length
  3–258) and a distance symbol (0–29, each with 0–13 extra bits
  specifying the exact distance 1–32768) mean "copy `length` bytes
  from `distance` bytes back in the already-decoded output." Distance
  can be less than length (the copy overlaps itself — e.g. distance 1,
  length 100 means "repeat the last byte 100 times"), so the copy must
  be done byte-by-byte forward, never via a bulk `memcpy`-style routine
  that assumes non-overlapping ranges.

### 2.2 Canonical Huffman (RFC 1951 §3.2.2)

DEFLATE's Huffman codes are always canonical: given only the code
*length* of each symbol (never explicit bit patterns), there is exactly
one valid assignment — shorter codes get smaller numeric values, and
codes of the same length are consecutive integers, assigned in symbol
order. This means both encoder and decoder derive identical tables from
nothing but an array of code lengths (`code_length[symbol]`), which is
also all the "dynamic" block header needs to transmit. Mark Adler's
`puff.c` (public domain, distributed as a zlib contrib — not something
to vendor or FFI, just useful prior art to check block-level semantics
against while writing tests) is a good from-scratch reference for the
exact construction algorithm; it is small enough to read end to end in
one sitting and is the reference this doc recommends cross-checking
`inflate.w`'s block decode logic against during implementation, not for
copying code.

## 3. Inflate-first staging

Per the issue's own instruction ("inflate first"), and because every
consumer's minimum bar is "read what other tools already wrote" before
"write something other tools can read":

**Stage 1 — checksums + a fully conformant inflater.**
`crc32.w` and `adler32.w` first (each is small, self-contained, and
needed by both directions anyway to validate round-trips). Then
`inflate.w` covering all three block types (stored, fixed Huffman,
dynamic Huffman) — "fully conformant" here means it must correctly
decode any spec-legal DEFLATE stream, including ones this package's
own (initially primitive) deflater never produces, because real-world
producers (git, gzip(1), zlib, browsers) use dynamic Huffman blocks
routinely. Skipping dynamic-block support would make inflate.w able to
read only its sibling deflate.w's output, defeating the entire "gateway
to interop" purpose. Stage 1 alone already unblocks: reading existing
git objects (once compress/ lands, before this repo's own deflater is
any good), decoding gzip HTTP responses from real servers, and
decoding cache blobs a full-zlib CI producer might write.

**Stage 2 — a deflater, staged for "good enough" before "optimal."**
- *2a — stored blocks only.* One `BFINAL=1, BTYPE=00` block (or a
  chain of them if input exceeds 65535 bytes, `LEN`'s field width).
  Zero compression ratio, but a fully spec-conformant stream — this
  alone is enough to make `zlib_compress`/`gzip_compress` exist and
  round-trip through `inflate.w`, satisfying every consumer's
  *correctness* bar (a VCS object store or an HTTP client doesn't care
  if the bytes are smaller, only that the format is right) before
  ratio work begins.
- *2b — fixed Huffman + greedy LZ77 matching.* A hash-chain match
  finder (details in §6) over 3-byte prefixes, greedy longest-match
  selection (take the best match found at the current position, do not
  look ahead), literals and length/distance pairs encoded with RFC
  1951's fixed Huffman table (no header to transmit — cheap to decode
  *and* cheap to encode against, since the code lengths are compile-
  time constants). This is "good enough for VCS": W source files and
  build artifacts are small and repetitive enough that even greedy
  fixed-Huffman DEFLATE gets most of the practical size win.

**Stage 3 (optional, explicitly out of scope for the PR that closes
the mandatory half of issue #252) — lazy matching + dynamic Huffman
emission.** Lazy matching (before committing to a match at position
`i`, check whether position `i+1` yields a strictly longer one, and
emit a literal at `i` instead if so — zlib's default strategy) and
computing actual per-block symbol frequencies to emit a dynamic Huffman
header typically closes most of the remaining gap to zlib's own ratio
at default settings. Neither is needed for correctness or for any
consumer's minimum bar; both are pure ratio/size improvements. Staged
separately so the mandatory PR stays a bounded size (see §9).

## 4. Buffer-to-buffer vs. streaming for v1

**Recommendation: buffer-to-buffer only for v1.** Every function takes
a whole input buffer and returns a whole output buffer; no incremental
"feed some bytes, pull some bytes" object exists yet.

Justification, consumer by consumer:

- **VCS objects** are already fully materialized in memory before
  compression would apply: `cas.w`'s `cas_get`/`cas_put` read/write
  whole `string_builder` buffers (`cas_read_file` calls
  `stream_read_all` into one buffer; `cas_put`/`cas_put_raw` take a
  `char* data, int length` pair), and objects are individually small
  (source files, trees, commits). There is no partial-object use case
  to design around.
- **HTTP** already has *two* layers in `http_client.w`: the buffered
  convenience API (`http_request`, which internally loops
  `http_stream_read` into one `string_builder` — see
  `libs/standard/web/http_client.w:1630-1655`) and the streaming API
  (`http_stream_read`, consumed today by SSE). A gzip `Content-
  Encoding` decoder can slot into *either* layer later without
  redesigning this package: v1's `gzip_decompress(char*, int)` is
  exactly what `http_request`'s buffered path needs immediately: the
  streaming path (`http_stream_read`) can gain an incremental gunzip
  wrapper as a separate, later piece of work once there is an actual
  caller who cannot afford to buffer a whole response (large cache
  blobs streamed through `http_stream_read`, say) — nothing in this
  design blocks that.
- **The build cache** transfers bounded artifacts (build outputs,
  tarballs); `build_system_next.md`'s own sketch treats them as whole
  blobs (`GET /cas/<key>` returning a complete tarball), matching
  buffer-to-buffer exactly.

This also matches every existing precedent in the tree — `base64.w`
(`char* data, int len` in, malloc'd buffer + `*out_len` out),
`lib/sha256.w`/`whash_oneshot` (whole-buffer digest), `cas.w` (whole-
object put/get) — so buffer-to-buffer is the path of least surprise for
whoever calls this package next, not just the least amount of new
design. A future streaming context, if one becomes genuinely necessary,
should mirror `whash`'s `_new`/`_update`/`_final` shape (`inflate_ctx*
inflate_ctx_new()`, `inflate_ctx_feed(ctx, data, len)`,
`inflate_ctx_read(ctx, out, cap)`) rather than being designed now
speculatively — inflate is naturally resumable block-by-block; a truly
incremental *deflate* is the harder half (the LZ77 window and any
lazy-matching lookahead both want to see input the caller hasn't
provided yet), so it should stay buffer-to-buffer even after inflate
grows a streaming mode, unless a concrete need appears.

## 5. API sketch

Five files, all leaf modules (only `lib.memory` and each other as
dependencies — no `structures.hash_table`, deliberately; see §6 on
allocator behavior for why):

```
libs/extras/compress/crc32.w
libs/extras/compress/adler32.w
libs/extras/compress/inflate.w
libs/extras/compress/deflate.w
libs/extras/compress/zlib.w      # RFC 1950, imports inflate + deflate + adler32
libs/extras/compress/gzip.w      # RFC 1952, imports inflate + deflate + crc32
```

No `libs/extras/compress/__arch__/` is needed — unlike `vcs/cas.w`,
nothing here touches a syscall (no file I/O, no rename-for-atomicity);
it is pure computation over caller-supplied buffers, so it is
architecture-independent by construction on every target this repo
already supports (x86, x64, arm64, arm64_darwin, win64, wasm32 — the
"seed constraint" note in §0 also means none of it needs seed-era-only
syntax, but there is likewise no reason to *use* newer syntax
gratuitously; keep it boring).

### 5.1 Checksums — plain functions, no result wrapper

Checksums over trusted, caller-owned bytes cannot fail (aside from a
negative `length`, treated as zero — matching `base64_encode`'s
`if (len < 0): len = 0` convention), so no `wresult[T]` is warranted
(`docs/error_results.txt`: "Do not retrofit existing fatal APIs
broadly. Add result-returning siblings only where callers have a real
recovery path" — there is no recovery path for "compute a checksum,"
only a value to return).

```
# crc32.w — RFC 1952 §8's reflected polynomial (0xEDB88320), matching
# every real-world producer (zlib, gzip(1), PNG, git).
int crc32_of(char* data, int length)                    # one-shot
int crc32_update(int crc, char* data, int length)        # crc=0 starts a fresh checksum (mirrors zlib's crc32() convention exactly, so vectors are directly cross-checkable)

# adler32.w — zlib wrapper's checksum.
int adler32_of(char* data, int length)
int adler32_update(int adler, char* data, int length)     # adler=1 starts fresh (the algorithm's true neutral element, not 0)
```

### 5.2 `inflate.w` — the risky direction, rich errors

Untrusted input (HTTP bodies, VCS objects that might be corrupt, any
future git-interop source) needs a real recovery path, so this follows
`cas.w`'s own precedent exactly: a small buffer-holding struct as the
payload type, wrapped in `wresult[T]*` with domain-specific error codes
in the `http_error_*`/`CAS_ERR_CORRUPT` style (a describer function,
not a reused Linux errno — there is no syscall underneath to borrow
errno semantics from):

```
struct inflate_result:
    char* data
    int length

int INFLATE_OK()                    # 0
int INFLATE_ERR_BAD_BTYPE()         # BTYPE == 11 (reserved)
int INFLATE_ERR_BAD_STORED_LEN()    # NLEN != ~LEN
int INFLATE_ERR_BAD_HUFFMAN()       # over-subscribed or incomplete code table
int INFLATE_ERR_BAD_DISTANCE()      # back-reference points before the start of output
int INFLATE_ERR_TRUNCATED()         # input ended mid-block
int INFLATE_ERR_TOO_LARGE()         # output exceeded the caller's cap (see below)
char* inflate_error_string(int code)

# max_output <= 0 means unbounded (trusted input, e.g. a VCS object
# whose declared length cas.w's framing already bounds). Untrusted
# input (an HTTP response body) should always pass a real cap --
# mirrors http_client.w's http_max_body_bytes() decompression-bomb
# guard, extended to cover the *compressed* side too.
wresult[inflate_result*]* inflate(char* data, int length, int max_output)
void inflate_result_free(inflate_result* r)
```

Call-site shape (matching `cas.w`'s `result_new_error[wcas_object*]`
idiom exactly, generics always explicitly instantiated in this
codebase):

```
wresult[inflate_result*]* r = inflate(body, body_len, http_max_body_bytes())
if (result_is_error[inflate_result*](r)):
    int code = result_code[inflate_result*](r)
    ... inflate_error_string(code) ...
    result_free[inflate_result*](r)
    return ...
inflate_result* out = result_value[inflate_result*](r)
... out.data, out.length ...
result_free[inflate_result*](r)
inflate_result_free(out)
```

### 5.3 `deflate.w` — cannot fail on valid input, plain return

```
int DEFLATE_LEVEL_STORED()   # 0 -- stage 2a, always available
int DEFLATE_LEVEL_FAST()     # 1 -- stage 2b, fixed Huffman + greedy LZ77 (v1 default)
int DEFLATE_LEVEL_BEST()     # 2 -- stage 3, lazy matching + dynamic Huffman (not yet implemented; deflate() clamps to FAST until it lands, same "ship the symbol, grow the behavior" pattern the level constants exist to support)

struct deflate_result:
    char* data
    int length

deflate_result* deflate(char* data, int length, int level)
void deflate_result_free(deflate_result* r)
```

### 5.4 `zlib.w` / `gzip.w` — thin wrappers, same shape as `inflate`/`deflate`

```
# zlib.w
struct zlib_result:
    char* data
    int length

zlib_result* zlib_compress(char* data, int length, int level)   # never fails
void zlib_result_free(zlib_result* r)

int ZLIB_ERR_BAD_HEADER()          # CMF/FLG fails the mod-31 check
int ZLIB_ERR_UNSUPPORTED_METHOD()  # CM != 8, or FDICT set (preset dictionaries: not in v1)
int ZLIB_ERR_BAD_CHECKSUM()        # Adler-32 mismatch
char* zlib_error_string(int code)
wresult[zlib_result*]* zlib_decompress(char* data, int length, int max_output)

# gzip.w -- same shape, GZIP_ERR_BAD_MAGIC / GZIP_ERR_UNSUPPORTED_METHOD /
# GZIP_ERR_BAD_CRC / GZIP_ERR_BAD_SIZE / GZIP_ERR_TRUNCATED.
# gzip_compress emits a minimal single-member header: MTIME=0, XFL=0,
# OS=255 ("unknown"), no FNAME/FCOMMENT/FEXTRA -- deterministic output
# byte-for-byte for the same input and level, which matters for the
# build cache (Direction 3 keys blobs by content hash; a compressor
# whose output varies run to run would break that) and matches `gzip
# -n`'s reproducible-build convention.
# gzip_decompress parses and skips FEXTRA/FNAME/FCOMMENT/FHCRC per the
# flag byte (real gzip files -- from gzip(1), git, browsers -- routinely
# set FNAME) but only reads a single member; multi-member concatenated
# streams (`cat a.gz b.gz > c.gz`, which gzip(1) explicitly supports)
# are out of scope for v1 -- flagged as an open question in §10.
```

`zlib_result`/`gzip_result` reuse one `_free` for both the success
struct and the value unwrapped from a `wresult` error path (both are
just `{char* data; int length;}`), so `zlib_result_free`/
`gzip_result_free` are the only two release functions needed per
module — no separate error-path variant.

### 5.5 Error handling convention, summarized

Straight application of `docs/error_results.txt`, already the pattern
`cas.w` and `http_client.w` both use for exactly this shape of problem
(validate an untrusted wire/storage format, give the caller a
recoverable error): **wresult[T]\* for anything that parses bytes it
did not produce itself** (inflate, zlib_decompress, gzip_decompress),
**plain return for anything that only encodes** (the three checksum
functions, deflate, zlib_compress, gzip_compress — encoding trusted,
caller-owned bytes cannot semantically fail short of OOM, and OOM is
already handled uniformly by `lib/memory`'s allocator-level notice +
null return, not this package's problem to duplicate).

## 6. W-specific hazards to design around

### 6.1 `int` is native-word-width, not a fixed 32-bit C `int`

The load-bearing fact (README.md: "`int` is a word-sized scalar
... hex literals with bit 31 set sign-extend into the word-sized `int`
on every target ... `__word_size__` is a compile-time constant (4 or
8)"): on the default x86 target `int` is 32 bits, but on the x64 target
it is 64 bits. Every algorithm in this package (CRC-32, Adler-32,
DEFLATE's bit accumulator, Huffman code values, LZ77 distances/lengths)
is defined over **32-bit words** regardless of what target compiles it,
so the same "masked 32-bit word" discipline `lib/sha256.w` and
`libs/standard/crypto/sha2.w` already establish applies throughout:

- Every intermediate that must behave as exactly 32 bits gets masked
  after operations that could carry above bit 31 (left shifts,
  additions) — `lib/sha256.w`'s `sha256_mask32()` builds the all-ones
  mask via `int h = 1 << 16; return h * h - 1`, which produces the
  right *low 32 bits* on both word widths even though the actual
  returned value differs (−1 on a 32-bit host where the multiply
  overflows and wraps; +4294967295 on a 64-bit host where it does not)
  — bitwise AND only cares about the bit pattern, so this is safe;
  `itoa()`-style decimal formatting of that same value is **not** safe
  (it would print differently on the two hosts), so nothing in this
  package should ever decimal-format a checksum or bit-accumulator
  value — format via byte extraction (`(v >> 24) & 255`, ...,
  matching `sha256_put_be32`) or hex (reuse `hex_encode` from
  `libs/standard/crypto/base64.w` over a packed 4-byte buffer) instead.
- **Right shifts must be logical, never W's native (arithmetic) `>>`.**
  Since #249 landed *after* `lib/sha256.w` was written, this package
  should use the `shr`/`rotl`/`rotr`/`popcount`/`clz`/`ctz` built-in
  intrinsics directly (`grammar/bit_builtin.w`) rather than
  reimplementing `sha256_shr`-style helpers — they are specified to
  operate "on the operands' LOW 32 BITS AS UNSIGNED ... zero-extended
  on the 64-bit targets," which is exactly this package's requirement,
  and they lower to 1–2 instructions per backend instead of a masked
  shift-and-or. (They are not reserved words — don't accidentally
  shadow `shr`/`rotl`/`rotr` with a same-named local helper.)
- **No hex/binary literal with bit 31 set may appear as a token.** The
  CRC-32 polynomial this package needs, RFC 1952's reflected form
  `0xEDB88320`, **does** have bit 31 set — as a sanity check,
  `0xEDB88320` = 3,988,292,384 > 2³¹ (2,147,483,648), i.e. its top hex
  digit `E` = `1110` in binary, so the leading bit is 1. (The all-ones
  init/final-XOR value `0xFFFFFFFF` obviously has it set too — every
  bit is 1.) Both must be built at runtime, mirroring
  `sha2.w`'s `sha2_hex32()` (accumulate 4 bits at a time via `(v << 4)
  | nibble`, then `& sha256_mask32()`) or `sha256_mask32()`'s
  shift-multiply trick — never spelled as a literal token. Unlike
  SHA-256's round-constant table (arbitrary, non-derivable primes),
  the CRC-32 table itself does **not** need to be a literal table at
  all: it is standardly *generated* at init time from the single
  polynomial value via the well-known doubling algorithm (8 rounds of
  "if the low bit is set, `poly ^ (word >> 1)`, else `word >> 1`," for
  each of the 256 byte values) — so the only bit-31-hazard constant in
  the whole package is that one polynomial word plus the all-ones
  mask, both handled once, in `crc32.w`.
- **No `int64`/hi-lo-pair machinery needed anywhere.** This is a
  genuine simplification versus `lib/sha256.w`/`sha2.w`: every quantity
  here — the CRC/Adler accumulator, a Huffman code (≤ 15 bits), a
  back-reference distance (≤ 32768) or length (≤ 258), the DEFLATE bit
  buffer, gzip's CRC and `ISIZE` trailer fields — fits in one 32-bit
  masked word. SHA-2 needed hi/lo pairs only because of its 64-bit
  message-length field; nothing here has an equivalent. (`ISIZE` is
  itself defined as "size mod 2³²," so even a multi-gigabyte input
  wraps by spec, not by bug — moot anyway since every consumer already
  caps input size well under 2³² bytes, e.g.
  `http_client.w`'s `http_max_body_bytes()` = 1 GiB.)

### 6.2 Allocator behavior: avoid many-small-allocations patterns

`docs/projects/ai_tooling_next_steps.md` records a real, fixed-but-
worth-remembering incident: `parser_generator_w_test` degraded to a
90-CPU-minute crawl under "millions of small blocks" before #322
rewrote `lib/memory_freelist.w` around 41 segregated size-class bins
with O(1) free. That fix means pathological allocation patterns are no
longer *catastrophically* slow, but they are still wasteful (per-
allocation bookkeeping overhead, worse cache locality, more allocator
pressure than necessary) — and this package's two hottest interior data
structures are exactly the shape that invites the anti-pattern if
implemented carelessly:

- **The LZ77 match finder (deflate stage 2b+).** Do not model it as
  `map[int, list[int]]` (a hash bucket per distinct 3-byte prefix, a
  list node per occurrence) — for an input the size of a build-cache
  blob or a large source file, that is one allocation per input byte,
  i.e. potentially hundreds of thousands of tiny allocations for a
  single `deflate()` call. Use the standard zlib-style flat-array hash
  chain instead: one `int* head` array (bucket → most recent input
  position at that hash, sized to the hash table's bucket count, a few
  thousand entries) plus one `int* prev` array (input position → the
  previous input position sharing the same hash, sized exactly to the
  input length). This is **exactly two allocations regardless of input
  size or match count** — not a compromise versus the "obvious"
  hash-table design, it is the standard, simpler, faster design.
- **Canonical Huffman tables (inflate, and dynamic-block emission once
  stage 3 lands).** DEFLATE's own format caps this tightly: at most
  288 literal/length symbols, 32 distance symbols, 19 code-length
  symbols, max code length 15 bits. Represent a table as a handful of
  fixed-size `int[]` arrays (code lengths, per-length first-code
  offsets, symbols sorted by code — the standard canonical-Huffman
  construction, RFC 1951 §3.2.2's own pseudocode) allocated once per
  `inflate()`/`deflate()` call, never one allocation per symbol or per
  tree node. There is no reason to build an explicit linked Huffman
  tree at all — canonical codes decode by comparing an accumulated bit
  value against per-length boundaries, which is table lookups over flat
  arrays, not tree traversal.
- **Output growth.** Reuse `structures.string.string_builder` as the
  growable output buffer rather than inventing a new one: it already
  provides amortized-doubling growth (`string_reserve`), copies through
  embedded NUL bytes (`string_append_bytes`), and treats `.length` as
  authoritative over the NUL terminator — precisely the "owned, raw,
  binary-safe buffer" contract `cas.w` already leans on
  (`cas_read_file`'s doc comment: "data is NUL-terminated for
  convenience, but length is authoritative"). Detach the finished
  buffer with the same idiom `cas.w`'s `cas_fanout_dir` already uses —
  `char* data = sb.data; int length = sb.length; free(sb)` (freeing
  only the wrapper struct, not `string_free`, which would free the
  data too) — to hand back a plain `char*`/`int` pair without an extra
  copy.

### 6.3 Decompression-bomb guard

Untrusted input (an HTTP response, eventually a fetched git object) can
claim an enormous decompressed size while shipping only a few bytes of
compressed data — the classic "zip bomb." `inflate`/`zlib_decompress`/
`gzip_decompress` all take a `max_output` parameter for exactly this
(§5.2); callers processing untrusted bytes must always pass a real cap.
`http_client.w`'s integration (§7.2) should thread through
`http_max_body_bytes()`; `cas.w`'s integration should use the object's
own declared length from its `"<type> <len>\0"` framing (already
parsed and bounds-checked before any bytes are trusted — see
`cas_get`'s existing framing-validation loop) as the cap, so a
corrupted or hostile object can never over-allocate past what its own
header claims.

## 7. Consumer integration (each is separate follow-up work, not part of this package)

### 7.1 `libs/extras/vcs/cas.w` — zlib-wrapped loose objects

Git's on-disk loose-object format is `zlib_compress(header + payload)`
— bit-for-bit `zlib.w`'s job once it exists. `cas_store_bytes` would
compress `header.data + data` before writing, and `cas_get`/
`cas_verify` would `zlib_decompress` before the existing "<type> <len>
\0" framing check. **No store-format migration concern**: per
`docs/projects/version_control.md`'s own sequencing, `tools/wvc.w`
(wave 2) has not shipped yet, so there is no existing on-disk store to
migrate — this can switch straight to always-compressed once `compress/`
lands, before any real repository exists. **Caveat on "interop"**: this
gets the *compression envelope* bit-identical to git, but full
git-object-id compatibility additionally needs SHA-1 (issue #209,
"implementation in progress," tracked as independent of the native
`wvc` path) since git identifies objects by `sha1("<type> <len>\0" +
payload)`, not the SHA-256 this repo's `cas.w` already uses by design
(`version_control.md`'s own "Design decisions" section: "SHA-256, not
SHA-1 ... Git interop is a non-goal for now"). `compress/` alone does
not deliver git interop; it removes one of the two remaining blockers.

### 7.2 `libs/standard/web/http_client.w` and the server framework (#235)

**Client**: `http_send_request` (`libs/standard/web/http_client.w:859`)
currently hardcodes `Accept-Encoding: identity` unless the caller
supplied their own header — the natural extension is
`Accept-Encoding: gzip, identity` by default, plus a
`Content-Encoding` check right after body assembly in `http_request`
(`:1630`) that runs the (already-buffered) body through
`gzip_decompress(body, body_len, http_max_body_bytes())` before
returning to the caller — transparent to every existing call site,
mirroring how chunked-transfer decoding and redirect-following are
already invisible to callers. A corrupt or oversized gzip body should
fail with a new `http_error_*` code (e.g. `http_error_bad_content_
encoding()`), following the exact precedent of `http_error_bad_chunk()`
/`http_error_body_too_large()`. `http_stream`'s incremental path can
gain the equivalent later if a caller ever needs bounded memory for a
streamed gzip body (§4) — not required for v1.

**Server** (once `RequestContext`/`ServerContext` exist per #235 tasks
2d/3c): gzip the response body when the request's `Accept-Encoding`
header contains `gzip` and the body is over some minimum size (recommend
~256–1024 bytes, matching common server defaults like nginx's
`gzip_min_length` — compressing tiny bodies costs more CPU than it saves
in transfer). Set `Content-Encoding: gzip` and recompute `Content-
Length` from the compressed size. Note for whoever implements this: it
requires the body be fully buffered before headers are sent (or transfer
chunked instead) — a design coupling worth flagging now for the framework
work, not resolved by this doc.

### 7.3 `wexec` shared build cache (`build_system_next.md` Direction 3, wave 3 task 3e)

Direction 3's own sketch already frames the cache server as "a dumb HTTP
server" shipping "tarball of the target's declared outputs" over `GET`/
`PUT /cas/<key>`. Once `gzip.w` exists, `PUT` payloads can be
gzip-compressed before upload and `GET` responses gunzipped on receipt —
a pure transport-size win with no protocol redesign, gated the same way
Direction 3 already commits to: "read-through only, failures fall back
to local build" (`sonnet_wave_plan_2026_07.md`'s wave-3 task 3e
guardrail) — a corrupt or incompatible gzip blob from the cache must
never block a build, only force a local rebuild, exactly like any other
cache-miss path.

## 8. Test plan

Following this repo's existing conventions throughout (no new fixture
mechanism needed):

- **Hand-crafted block fixtures.** A handful of minimal DEFLATE streams
  — an empty stored block, a one-byte stored block, a short fixed-
  Huffman block ("hello world"-scale), a hand-encoded dynamic-Huffman
  block with a deliberately small alphabet — embedded directly as
  `c"\x.."` byte-string literals in `tests/`, the same way
  `lib/sha256.w`'s `sha256_k_table()`/`sha256_h0_table()` embed their
  constant tables. These pin exact block-level semantics (stored-block
  NLEN checking, fixed-code boundaries, the code-length run-length
  tricks) independent of whether this package's own `deflate.w` can
  produce them yet — stage 1 (`inflate.w`) can be fully tested before
  stage 2 (`deflate.w`) exists at all, which is the whole point of
  "inflate first."
- **Corpus round-trip fixtures**, text-committed, not binary. This repo
  has no committed binary fixtures anywhere (`git ls-files tests/ |
  file` turns up only ASCII/JSON/text — the closest analog,
  `tests/asm/corpus_{x86,x64,arm64}.txt`, stores instruction bytes as
  lowercase hex text, one entry per line, `#`-commented). Follow the
  same shape for compress: a `tests/compress/deflate_corpus.txt` (or
  split per block type) with lines of `<hex compressed bytes>|<hex
  expected decompressed bytes>`, generated once (by any reference tool,
  including a real `zlib`/`gzip` at fixture-authoring time — the
  fixture is just the resulting bytes, so authoring it does not create
  a build-time dependency) and committed as text, read and decoded by
  the test at run time. This sidesteps ever needing an actual binary
  `.gz` file in the tree.
- **Fuzz-ish random round-trip, once `deflate.w` exists.** `lib/rand.w`
  already provides a seedable `rand_state` (`rand_init(seed)`) — a
  `test_deflate_inflate_roundtrip` generating some hundreds of random
  buffers (varying size, and varying redundancy: all-zero, fully
  random, repeated short patterns, and English-text-like data, which
  exercise very different match-length distributions) with a fixed seed
  for reproducibility, `deflate()` then `inflate()` each and assert
  byte-equality. Keep total iteration count/size modest (a few hundred
  buffers of a few KB each) — this repo's test suite cares about wall
  time (`build_system_next.md`: "leaf compiles are already effectively
  instant ... any improvement should target [build/verify time], not
  leaf compile speed" — the same logic applies to leaf *test* time).
- **Cross-validation without a build-time system-zlib dependency.** The
  precedent is `tests/openssl_tls_interop.w` +
  `build.base.json`'s `openssl_interop_test` target: gate on
  `command -v <tool>`, print a "...OK
  (skipped: no <tool> on PATH)" success (not a failure) when absent, so
  the manifest entry is always safe on a minimal machine, and every
  subprocess runs under a timeout. For compress, recommend gating on
  `python3` rather than a `zlib`-linked C tool or the `openssl`/`gzip`
  binaries directly: `python3`'s standard library `zlib` module is
  present on effectively every install (it's stdlib, not an optional
  package) and gives direct access to both directions (`zlib.compress`/
  `decompress`, `gzip.compress`/`decompress`) from one small script —
  encode with this package's `deflate`/`gzip_compress`, decode with
  Python's `zlib`/`gzip`, and the reverse, both ways, plus feeding this
  package's `gzip_compress` output to a `gunzip -t`-equivalent check.
  This is a **new, optional** target (e.g. `compress_zlib_interop_
  test`), never a dependency of `./wbuild build`/`verify`/`tests`'
  required path — matching the openssl target's own placement exactly.

## 9. Sizing and staged PRs

Issue #252 estimates "~1–2k lines" for the whole package and flags it
as the wave's biggest single chunk — "budget accordingly." Recommend
splitting the implementation (wave 3 task 3a and beyond) into three
PRs along the stage boundaries already established in §3, so the
mandatory slice stays reviewable and every intermediate state is a
working, tested package:

1. **PR A (required — closes the "inflate first, deflate optional"
   half of #252's wave-3 checkbox).** `crc32.w`, `adler32.w`,
   `inflate.w` (stage 1, all three block types), `deflate.w` stage 2a
   (stored blocks only), `zlib.w`, `gzip.w` — every wrapper exists and
   round-trips correctly, just without real compression yet. Roughly
   900–1100 lines including tests (comparable to `cas.w`'s ~470 lines
   for a package with three RFCs and four block-decode paths instead of
   one storage format). This alone unblocks every consumer in §7 at
   the *correctness* level: cas.w can wrap objects in zlib immediately
   (bytes are correct, just not smaller than before), http_client.w can
   decode any real server's gzip response, wexec's cache can round-trip
   gzip blobs.
2. **PR B (follow-up, same wave or wave 4).** `deflate.w` stage 2b
   (fixed Huffman + greedy LZ77, §6's hash-chain match finder). No API
   change — `DEFLATE_LEVEL_FAST` starts actually compressing, so every
   existing caller (`zlib_compress`/`gzip_compress`) gets smaller output
   for free. Roughly 400–600 lines including the fuzz round-trip test
   from §8 (which only makes sense once compression is real).
3. **PR C (optional, future wave — not required by any consumer's
   correctness bar).** Stage 3 (lazy matching + dynamic Huffman
   emission) plus the optional interop cross-validation target from
   §8. Purely a ratio/size improvement; genuinely optional per the
   issue's own "deflate optional v1" phrasing extended one stage
   further.

## 10. Open questions for the maintainer

1. **`libs/standard/plans/07_compression_crypto.md` overlap** (§0):
   should its gzip/deflate phase be struck in favor of this doc, with a
   pointer added, or is the broader
   `libs/standard/compression/`+`archive/`+`crypto/` package still
   wanted as a separate, later effort that happens to re-export this
   one for the gzip/deflate slice?
2. **`Content-Encoding: deflate` for HTTP** — recommended against in
   §1 (real-world ambiguity between raw-DEFLATE and zlib-wrapped
   producers). Confirm gzip-only is acceptable, or scope `deflate`
   support (with both interpretations) as explicit future work.
3. **gzip multi-member streams** (§5.4) — real `gzip(1)` concatenation
   output exists in the wild (rare, but not nonexistent, and notably
   how some log-rotation and streaming-compression tools produce
   output incrementally). Confirm single-member-only is acceptable for
   v1, or should `gzip_decompress` at least detect and reject
   (rather than silently truncate at) a trailing second member instead
   of erroring only on genuine corruption?
4. **`cas.w`'s zlib adoption** (§7.1) — should it land as a fast-follow
   PR immediately after PR A (§9), given there is no existing store to
   migrate, or wait until `wvc` (wave 2) has real users first so the
   two changes don't compete for review attention in the same window?
5. **HTTP client default** (§7.2) — should `Accept-Encoding: gzip` be
   sent by default (matching curl/browsers) or stay opt-in behind a
   request flag until the decompression-bomb guard (§6.3) has seen more
   real-world exercise? This doc's default recommendation is "on by
   default with the cap enforced," but it's a real behavior change for
   every existing `http_client.w` caller and worth an explicit sign-off.
