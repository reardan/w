# Standard library: Python parity plan

Prioritized plan for closing the gaps between W's standard library and
Python's, broken into chunks that parallel agents can implement, test and
merge independently.

Status: **planned**. Source analysis: the 2026-10-16 survey of `lib/`,
`structures/`, `libs/standard/`, `libs/extras/` at `792fefb`, which rated
each Python stdlib module Have / Partial / Missing. This doc covers the
Partial and Missing rows; the areas W already covers (TLS, HTTP/2, gRPC,
crypto primitives, SQL, compression codecs, threads/tasks, testing) are
out of scope.

### Relationship to `libs/standard/plans/`

`libs/standard/plans/01..11_*.md` are the per-area API designs (module
layout, Python 3.14 reference sources, edge cases). This doc does not
replace them: it is the execution layer on top, choosing the order,
cutting each area into PR-sized chunks, and saying which chunks can run in
parallel. Module paths follow those plans (`libs/standard/text/`,
`time/`, `fs/`, `formats/`, `numeric/`, `collections/`, `archive/`,
`compression/`, `cli/`, `email/`); small additions to existing `lib/`
files stay in `lib/`. Each chunk's agent reads the matching area plan
before starting, and where the two disagree on API detail the area plan
wins. One correction to the area plans: tests no longer need `build.json`
wiring (issue #323); a `*_test.w` beside the module is enough.

## Goals and non-goals

Goals:

- The everyday text, data-format, filesystem, date/time and numeric
  facilities a Python programmer reaches for first, as plain W libraries.
- Each facility usable on every target the stdlib already supports
  (x86, x64, arm64 Linux, arm64_darwin; wasm and win64 where the
  underlying syscalls exist), with tests that run under `tests`.
- APIs that follow existing W conventions (C strings or `string`,
  `list[T]`, malloc'd results owned by the caller, `*_free` helpers,
  `result.w` for fallible calls), not ports of Python's object model.

Non-goals:

- Reflection (`inspect`), `weakref`/`gc`, `pickle` of arbitrary objects,
  `ast`/`dis` for W itself, `curses`, audio (`wave`), legacy mail
  protocols (IMAP/POP3), `xmlrpc`. Revisit only on demand.
- Language changes. Everything here is library code; if a chunk finds it
  needs syntax, it stops and files an issue instead.

## Constraints every agent must follow

- **Seed graph.** `lib/lib.w`, `lib/path.w`, `lib/args.w`,
  `lib/process.w`, `lib/hex.w` and anything else in `w.w`'s import closure
  are compiled by the pinned seed and must use only seed-era syntax (see
  CLAUDE.md). Check with `./bin/wv2 deps w.w | grep <file>` before
  editing. New modules under `libs/standard/` are leaf libraries and may
  use current syntax. Prefer adding new files over
  growing seed-graph files; when a seed-graph file must change (chunk
  P2.3), keep the change in plain syntax.
- **Tests.** Each chunk ships `<module>_test.w` beside its module (the
  manifest generator discovers `*_test.w` anywhere under `lib/` and
  `libs/`) using `lib/testing.w`, with a `# wbuild: x64` directive so the 64-bit
  twin runs too. No `build.base.json` edits are needed for ordinary tests.
- **Validation before push.** `./wbuild <name>_test <name>_64_test`,
  `./bin/wv2 check --json` clean on every touched file (warnings fail
  `--strict` builds), `git diff --name-only origin/main | ./bin/wtest
  changed` targets green, and `./wbuild verify` when any seed-graph file
  changed.
- **Expression gotchas** (CLAUDE.md): `&&`/`||` for guards, 32-bit masks
  built at runtime, never name a variable `byte`, `T* + n` is an unscaled
  byte offset (use `&p[n]`).
- **One chunk = one PR**, small enough to review in one sitting. A chunk
  owns the files it lists; it does not edit another chunk's files. Shared
  touch points (docs/todo.txt, this doc's status column) are updated by
  the coordinator when merging, not by agents.

## Priority tiers

Ranked by how often a typical program hits the gap, then by how much other
work it unblocks.

| Tier | Area | Why first |
|---|---|---|
| P1 | Regex, string helpers, CSV, datetime | Text and dates are in nearly every script; regex also unblocks shell-mode grep/sed and several later chunks. |
| P2 | Filesystem helpers, config formats, random/algorithms, logging, argparse | Common in tools and services; mostly independent small libraries. |
| P3 | Archives, XML, numerics, hashing extras, networking extras | Valuable but less frequent; some depend on P1/P2 pieces. |
| P4 | Unicode normalization, email parsing, misc | Large data tables or niche use. |

## Chunks

Each chunk lists its files, API sketch, dependencies and the acceptance
test. "Wave" says which parallel batch it can run in: every chunk in a
wave depends only on earlier waves, and chunks in the same wave touch
disjoint files.

### P1: core text and time

**P1.1 Regex engine (`libs/standard/text/re.w`)** — wave 1, large.
Compile patterns to a small program (Pike VM / Thompson NFA with capture
slots) so matching stays linear-time; keep `lib/regex.w`'s API as a thin
wrapper so `lib/shell_*.w` and `repl/shell_translate.w` keep working.
Syntax: groups `( )`, non-capturing `(?: )`, alternation `|`, counted
repetition `{m,n}`, lazy quantifiers, `\d \w \s \D \W \S \b`, anchors
anywhere, case-insensitive flag, multiline flag. API: `re_compile`,
`re_free`, `re_match`, `re_search` (returns a `re_match` with group
spans), `re_findall`, `re_sub` (with `\1` references), `re_split`.
Backreferences are out (they force backtracking). Split into:
- P1.1a parser + NFA compiler + `re_search`/`re_match` with spans (wave 1).
- P1.1b `findall`/`sub`/`split` on top of P1.1a (wave 2).
- P1.1c port `lib/regex.w` callers, keep its test green, add a
  `tests/bench/` case showing the pathological pattern is linear (wave 2).
Acceptance: `libs/standard/text/re_test.w` with a table of (pattern, input, expected
spans) drawn from Python's `re` semantics; the existing `regex_test` and
shell tests unchanged.

**P1.2 String helpers (`lib/str.w`)** — wave 1, small.
Add `strip`/`lstrip`/`rstrip` (whitespace or a char set), `partition`/
`rpartition`, `rindex_of`, `starts_with_at`, `count`, `ljust`/`rjust`/
`center`/`zfill`, `capitalize`/`title`, `splitlines`, `is_ascii`,
`expandtabs`. Non-mutating, malloc'd results, `char*` and `string`
overloads where `split` already has both. Acceptance: `lib/str_test.w`
(new) covering each helper's edge cases (empty input, all-whitespace,
multi-byte UTF-8 left intact).

**P1.3 Text wrapping (`libs/standard/text/textwrap.w`)** — wave 2 (uses P1.2), small.
`wrap(text, width) -> list[char*]`, `fill`, `dedent`, `indent`,
`shorten`. Width counts code points via `lib/utf8.w`. Acceptance:
`libs/standard/text/textwrap_test.w`.

**P1.4 CSV (`libs/standard/formats/csv.w`)** — wave 1, medium.
RFC 4180 reader and writer: quoted fields, embedded newlines, doubled
quotes, configurable delimiter/quote char, `\r\n` and `\n` line endings.
Reader works over a byte buffer and over a `lib/stream.w` stream
(row-at-a-time, so large files don't load whole). API: `csv_reader_new`,
`csv_next_row -> list[char*]`, `csv_parse_all`, `csv_writer_new`,
`csv_write_row`, `csv_quote_field`; a header-aware `csv_dict_reader`
returning `map[char*, char*]`. Acceptance: `csv_test.w` beside it with
round-trip and malformed-input cases (unterminated quote reports the
line).

**P1.5 Datetime core (`libs/standard/time/datetime.w`)** — wave 1, medium.
Types `date`, `time_of_day`, `datetime` (with optional UTC offset in
seconds), `duration` (seconds + nanoseconds). Arithmetic (add/subtract
durations, difference of datetimes), comparison, weekday, ISO week,
day-of-year, ordinal conversion. Builds on `lib/time.w`'s civil-date
functions rather than duplicating them. Acceptance:
`datetime_test.w` beside it, including leap years, year 1 and 9999 bounds,
negative durations.

**P1.6 Datetime formatting and parsing (`libs/standard/time/format.w`)** —
wave 2 (uses P1.5), medium.
`strftime`-style formatter (`%Y %m %d %H %M %S %f %z %Z %a %A %b %B %j
%U %W %%`), matching `strptime` parser, ISO 8601 / RFC 3339 parse and
format, RFC 2822 (HTTP/email dates; `libs/standard/web` can then drop
any ad-hoc date code). Acceptance: format/parse round-trip table.

**P1.7 Time zones (`libs/standard/time/zoneinfo.w`)** — wave 3 (uses P1.5), medium.
Read TZif v2/v3 files from `/usr/share/zoneinfo` (and `$TZ`,
`/etc/localtime`), convert UTC <-> local with DST transitions, POSIX TZ
string footer for dates past the table. `datetime_now_local`. No bundled
database: on targets without zoneinfo (wasm, win64) local time falls back
to UTC with a documented limitation. Acceptance: tests against TZif
fixture files committed under `tests/data/tz/` (no dependency on the host
having zoneinfo).

**P1.8 x86-32 2038 fix (`lib/time.w`, `lib/__arch__/x86/`)** — wave 1,
small. Use `clock_gettime64` (syscall 403) on x86 with a fallback to
`time(2)` on old kernels; return a 64-bit value via the
`lib/bytes.w`-style parts convention or an existing int64 helper.
Acceptance: unit test that the call succeeds and agrees with `time(2)`
to within a second; comment in `lib/time.w` updated.

### P2: tools and services

**P2.1 Glob (`libs/standard/fs/glob.w`)** — wave 1, small.
`fnmatch(pattern, name)` with `* ? [abc] [!a-z]` and escapes;
`glob(pattern) -> list[char*]` including `**` recursion, sorted output,
hidden-file rule matching Python. Reuses `lib/dir.w` walking. Leaves
`lib/shell_patterns.w` alone (its "fall back to external find" behavior
can switch to `fnmatch` later). Acceptance: `glob_test.w` over a
temp tree built by the test (uses P2.2 once it lands, `lib/fs.w` before).

**P2.2 Temp files and shutil (`libs/standard/fs/tempfile.w`, `shutil.w`)** —
wave 1, medium.
`mkstemp`, `mkdtemp`, `temp_dir()` honoring `$TMPDIR`, random names from
`libs/standard/crypto/random.w`, `O_EXCL` creation. `copy_file` (with
`copy_file_range`/`sendfile` fast paths where available, read/write
fallback), `copy_mode`, `copytree`, `move` (rename, else copy+remove),
`disk_usage` (`statfs`). Acceptance: tests in a `mkdtemp` sandbox,
cleaned up with `dir_remove_all`.

**P2.3 Path helpers (`lib/path.w`)** — wave 1, small, **seed graph**.
Add `path_splitext`, `path_stem`, `path_suffix`, `path_relative_to`,
`path_is_absolute`, `path_expand_user`, `path_split_parts`. Plain
seed-era syntax only; run `./wbuild verify`. Acceptance: extend
`lib/path_test.w`.

**P2.4 Argparse v2 (`libs/standard/cli/argparse.w`)** — wave 1, medium.
New leaf library on top of `lib/args.w` (which stays seed-safe):
declared options with types (int/float/string/bool/list), defaults,
required flags, short+long names, positionals with arity, subcommands,
generated `--help` and usage errors. Acceptance: `argparse_test.w`
feeding argv vectors and asserting parsed values and help text.

**P2.5 Leveled logging (`libs/standard/cli/logging.w`)** — wave 1, small.
Levels (debug..critical), named loggers, a handler interface (stderr,
file, in-memory for tests), format with timestamp (`lib/time.w` now,
`datetime_format` once P1.6 lands), thread safety via `lib/task_sync.w`
locks. `lib/logging.w` keeps working; document the new module as its
replacement. Acceptance: `logging_test.w` using the in-memory handler.

**P2.6 Config formats: INI and TOML (`libs/standard/formats/ini.w`, `toml.w`)** —
wave 1, medium (two independent sub-chunks P2.6a INI, P2.6b TOML).
INI: sections, `key = value` / `key: value`, comments, interpolation off
by default. TOML 1.0 reader into a tree compatible in shape with
`structures/json.w`'s `json_value` (so callers walk one tree type);
datetimes as strings until P1.5 lands, then upgraded. Writer for INI;
TOML writer optional. Acceptance: TOML compliance subset from
toml-test's valid/invalid cases committed as fixtures.

**P2.7 Random extras (`lib/rand.w` + `libs/standard/numeric/random.w`)** — wave 1, small.
`shuffle`, `choice`, `sample`, `choices` with weights, `uniform`,
`randrange` with step, `expovariate`, plus a `secrets`-style
`token_bytes`/`token_hex`/`token_urlsafe` and constant-time
`compare_digest` over `libs/standard/crypto/random.w`. Acceptance:
determinism under a fixed seed, distribution sanity checks with loose
bounds.

**P2.8 Algorithms (`libs/standard/collections/bisect.w`, `itertools.w`)** — wave 1, small.
`bisect_left`/`bisect_right`/`insort` over `list[int]`/`list[char*]`/
comparator; `permutations`, `combinations`, `product` as generators via
`lib/generator.w`; `group_by` on sorted lists; `chain`. Acceptance:
outputs compared against hand-written expected lists.

**P2.9 Containers (`libs/standard/collections/counter.w`, `lru.w`)** —
wave 1, small.
`Counter` over `map[char*, int]` (`most_common`, add/subtract);
`lru_cache` as an explicit struct with capacity and hit/miss counters
(a decorator is a language feature, out of scope). Acceptance: unit tests
including eviction order.

### P3: formats, numbers, hashing, networking

**P3.1 Zip (`libs/standard/archive/zip.w`)** — wave 2, medium.
Reader (central directory, stored + deflate entries, CRC check, zip64
for >4 GB) and writer (stored + deflate) using the existing
`deflate.w`/`inflate.w`/`crc32.w`. Acceptance: read a fixture zip made by
Python's `zipfile`, write one and read it back; malformed archives fail
cleanly.

**P3.2 Tar (`libs/standard/archive/tar.w`)** — wave 2, medium.
ustar + pax headers (long names, sizes), read and write, `.tar.gz` via
`gzip.w`. Safe extraction (refuse `..` and absolute paths, using
`path_is_within`). Acceptance: fixture archives from GNU tar and
Python's `tarfile`.

**P3.3 bzip2 and xz decoders (`libs/standard/compression/bzip2.w`,
`xz.w`)** — wave 2, large, two independent sub-chunks. Decode only at
first; encoders are follow-ups. Acceptance: decode fixtures and compare
with stored plaintext hashes.

**P3.4 XML (`libs/standard/formats/xml/`)** — wave 2, large.
P3.4a pull tokenizer (elements, attributes, text, CDATA, comments, PIs,
entity and character references, namespaces), P3.4b DOM-ish tree with
`find`/`findall` on simple paths (ElementTree subset) and a serializer
with escaping. No DTD validation, no external entities (XXE-safe by
construction). Can reuse `libs/extras/html/entities.w` for named
entities. Acceptance: conformance subset fixtures plus round-trip.

**P3.5 Decimal and fractions (`libs/standard/numeric/decimal.w`, `fraction.w`)** —
wave 2, large / medium.
Promote `libs/standard/crypto/bignum.w` (or extract a general
`libs/standard/numeric/bigint.w` from it, P3.5a, wave 1) to a general arbitrary-precision
integer with add/sub/mul/divmod/pow/parse/format. Then `fraction` on
bigints and a `decimal` with context precision and rounding modes
(ROUND_HALF_EVEN default). Acceptance: tables checked against Python
output stored in the test.

**P3.6 Math extras (`lib/fmath64.w` + `libs/standard/numeric/complex.w`)** — wave 1,
medium. `hypot`, `isclose`, `gamma`/`lgamma`, `erf`/`erfc`, `expm1`,
`log1p`, `sinh/cosh/tanh`, integer `factorial`/`comb`/`perm`/`isqrt`;
complex type with arithmetic, `abs`, `phase`, `exp`, `log`, `sqrt`.
Acceptance: values within 1-2 ulp of reference constants.

**P3.7 Hashing extras (`libs/standard/crypto/sha3.w`, `blake2.w`,
`pbkdf2.w`, `base32.w`, `base85.w`)** — wave 1, medium, four independent
sub-chunks. SHA3-256/512 + SHAKE, BLAKE2b/2s, PBKDF2-HMAC (scrypt as a
follow-up), base32 / base32hex / base85 / ascii85. Acceptance: NIST/RFC
test vectors.

**P3.8 UUID (`libs/standard/formats/uuid.w`)** — wave 2 (uses P2.7), small.
Parse/format, v4 random, v7 time-ordered, v5 (needs SHA-1 from
`libs/x/unsafe`, documented as such). Acceptance: format/parse
round-trip, version/variant bits.

**P3.9 IP addresses (`libs/standard/net/ipaddress.w`)** — wave 1, small.
IPv4/IPv6 parse/format (RFC 5952 compression), networks with prefix
length, containment, iteration, private/loopback/link-local checks.
Reuse the IPv6 logic from `libs/standard/web/urlparse.w` by moving it
here and having urlparse import it. Acceptance: table tests.

**P3.10 IPv6 sockets and AAAA (`lib/net.w`, `libs/standard/net/dns.w`)**
— wave 2 (uses P3.9), medium. `AF_INET6` connect/listen/accept per arch
socket ABI, AAAA queries, Happy-Eyeballs-lite ordering in the HTTP
client. Acceptance: loopback `::1` echo test; DNS parse tests from
captured responses.

**P3.11 Struct pack (`libs/standard/formats/struct.w`)** — wave 1, small.
`pack(fmt, ...)`/`unpack(fmt, buf)` with Python's `<>!=` byte-order
prefixes and `bBhHiIqQfd s x` codes, built on `lib/bytes.w`. Acceptance:
byte-exact tables.

### P4: larger tables and niche

**P4.1 Unicode data (`libs/standard/text/unicodedata.w`)** — wave 2, large.
Generated tables (like `lib/grapheme_data.w`, via a `generated`-tagged
target) for general category, case mapping/folding, NFC/NFD/NFKC/NFKD
normalization. Acceptance: Unicode's `NormalizationTest.txt` subset.

**P4.2 Email message parsing (`libs/standard/email/message.w`)** — wave 3,
medium. RFC 5322 headers, MIME multipart, quoted-printable and base64
transfer encodings, RFC 2047 encoded words. Uses P1.6 for dates.

**P4.3 HTTP cookies (`libs/standard/web/cookies.w`)** — wave 2, small.
`Set-Cookie` parse/serialize, a cookie jar with domain/path/expiry rules
(P1.6 for `Expires`).

**P4.4 mimetypes (`libs/standard/web/mimetypes.w`)** — wave 1, small. Extension <->
type table; `http_server` can use it for static files.

## Waves at a glance

| Wave | Chunks (parallel) | Notes |
|---|---|---|
| 1 | P1.1a, P1.2, P1.4, P1.5, P1.8, P2.1, P2.2, P2.3, P2.4, P2.5, P2.6a, P2.6b, P2.7, P2.8, P2.9, P3.5a, P3.6, P3.7 (x4), P3.9, P3.11, P4.4 | All new files except P1.2 (`lib/str.w`), P1.8 (`lib/time.w`), P2.3 (`lib/path.w`, seed), P2.7 (`lib/rand.w`), P3.6 (`lib/fmath64.w`), each owned by exactly one chunk. |
| 2 | P1.1b, P1.1c, P1.3, P1.6, P3.1, P3.2, P3.3 (x2), P3.4a/b, P3.5 decimal/fraction, P3.8, P3.10, P4.1, P4.3 | P3.4b waits on P3.4a inside the wave. |
| 3 | P1.7, P4.2, follow-ups (TOML datetimes on P1.5, logging timestamps on P1.6, `shell_patterns` on P2.1) | |

Suggested batch size is 6-8 agents at a time, picking from the current
wave in tier order (P1 before P2 before P3), so review keeps up.

## Running the agents

- Each agent gets its own git worktree on a branch named for the chunk
  (`stdlib/p1.4-csv`), the chunk text above as its brief, and the
  constraints section verbatim.
- Agents commit locally and report the validation commands they ran and
  their output. The coordinator merges each chunk branch, reruns the
  chunk's tests plus `./wbuild tests` on a batch boundary, and opens one
  PR per chunk (or per tightly coupled pair, such as P1.1a+P1.1b).
- After each merged chunk the coordinator flips that chunk's row in
  `docs/todo.txt` and the status line at the top of this doc.
- If an agent hits friction in `w check`, `wtest` or other agent-facing
  tooling, it notes it in `docs/projects/ai_tooling_next_steps.md` in its
  own PR (CLAUDE.md rule).

## Open questions

- Should `libs/standard/text/re.w` replace `lib/regex.w` outright once shell-mode is
  ported (P1.1c), or keep both? Default: keep `lib/regex.w` as a wrapper
  for one release, then remove.
- int64 representation for datetime/duration on 32-bit targets: reuse
  the `(hi, lo)` parts convention from `lib/bytes.w` / `distributed/u64.w`,
  or wait for a first-class 64-bit integer on x86? Default: parts
  convention internally, word-sized seconds in the public API with a
  documented 2038 limit on x86 until a 64-bit type exists.
- Where do bigints live? Default: extract `libs/standard/numeric/bigint.w` (P3.5a) and make
  `libs/standard/crypto/bignum.w` a constant-time specialization of it.
