# UTF-8 source support (issue #287)

Status: audit + staged design proposal (2026-07-16). **Stage 1
implemented (2026-07-16)**; stage 2 (identifiers) remains
decision-gated on §6 and is untouched. Stage 1 choices, as landed:

- **JSON escaper** (§2.1 item 3): `diag_write_json_string`
  (`compiler/diagnostics.w`) now passes bytes >= 0x80 through raw only
  as part of a well-formed UTF-8 sequence (validated with the same
  rules as `lib/utf8.w`'s `utf8_validate_bytes`, reimplemented locally
  to keep the module dependency-free) and escapes any other byte as
  `\u00XX` — its byte value, so the information is preserved while the
  emitted NDJSON is always valid UTF-8/JSON. Valid-UTF-8 output is
  byte-identical to before; human output is untouched.
- **BOM** (§6 Q1): silent-strip, per this doc's recommendation. A
  single leading `EF BB BF` is consumed in `compile_attempt`
  (`compiler/compiler.w`) via `getc()`, before the first `get_token()`,
  keeping `byte_offset` exact and the line/column counters untouched. A
  partial match (stray `EF` not followed by `BB BF`) may consume up to
  two extra bytes, which is unobservable: such a file fails on its
  first token exactly as before. No new diagnostic message, so no
  frozen-text fixtures changed.
- **Columns** (§6 Q2): codepoint-based, in stage 1, per §3 — the
  one-line `get_character` change (UTF-8 continuation bytes don't
  advance `column_number`). JSON-only in effect: human output has no
  column. `byte_offset`/`token_start_offset` stay byte-exact. The
  additive byte+codepoint dual-field idea from §6 Q2 remains open.
- **Tests** (§5 items 1-6): `tests/utf8_source_test.w` (+ generated x64
  twin) covers raw UTF-8 in line/block comments, `"..."`/`s"..."`
  literals, f-string chunks, and codepoint iteration.
  `check_json_utf8_test` and `utf8_bom_test` (hand-written
  `build.base.json` targets) generate their fixtures at test time with
  `printf` into `bin/` — invalid-UTF-8 and BOM bytes are deliberately
  not committed as tracked `.w` files, so `parser_generator_w_test`
  (which parses every tracked `.w` file) and the metadata gates never
  see them. `tests/ndjson_utf8_validator.w` asserts every captured
  NDJSON line is valid UTF-8, parses as JSON (`structures/json.w`), and
  carries the seven documented diagnostic fields. The column fixture
  asserts `"column": 19` for the §3 probe (byte column would be 25).
- `c"..."` stays raw/unvalidated (§6 Q3) — unchanged, as §4 requires.

The audit below reports the pre-stage-1 behavior; rows fixed by stage 1
are the BOM row, the invalid-UTF-8 `check --json` row, and the
line/column row.

Issue #287: "Support utf8 source files - e.g. utf8 identifiers, utf8 in
comments + strings, etc. Can reference the process / problems / caveats
from Python's 2 to 3 migration where they did this."

## 0. Headline finding

**Strings, comments, and char literals already support UTF-8 today** —
this is not a 0-to-1 feature. `compiler/tokenizer.w` and
`grammar/string_literal.w` were built UTF-8-aware from the start (see
`docs/todo.txt`'s "UTF-8 string descriptors with default `"..."`
literals" / "UTF-8 decode/encode helpers and string codepoint iteration"
lines, `lib/utf8.w`, `lib/grapheme.w`). What is genuinely missing is:
**identifiers** (hard tokenizer limitation), a handful of **rough edges**
around comments/strings (BOM handling, diagnostics-JSON well-formedness,
byte-vs-codepoint column counting), and **test coverage** for the raw
(non-escaped) UTF-8-byte forms of the working paths.

All findings below were produced by building `bin/wv2` from this
worktree (`./wbuild build`), writing probe `.w` files, running
`./bin/wv2 check --json`, compiling and executing the ones that build,
and reading the exact code paths responsible. Probe files are not
committed (scratch only, per task instructions); line numbers below are
exact anchors into the current tree for reproducing any probe.

## 1. Audit table

| Construct | Today's behavior | Root cause / anchor |
|---|---|---|
| UTF-8 bytes in `#` line comments | Clean compile, program runs normally. Comment scan is fully byte-transparent — it only looks for byte `10` (newline) or EOF. | `compiler/tokenizer.w:333-341` (`get_token`, `#` branch) |
| UTF-8 bytes in `/* */` block comments | Clean compile. Scan only looks for the ASCII bytes `*` (0x2A) and `/` (0x2F), which never occur as part of a valid multi-byte UTF-8 sequence (continuation bytes are 0x80-0xBF, lead bytes 0xC2-0xF4). | `compiler/tokenizer.w:316-327` |
| UTF-8 in default `"..."` string literal | Clean compile. Bytes are validated as well-formed UTF-8 at compile time and stored as a `string` (UTF-8 descriptor: `{data, length}`). `.length` is the **byte** length, not the codepoint count. Confirmed at runtime: `"héllo wörld 日本語 emoji: 🎉"` → `s.length == 35` (24 codepoints, 35 UTF-8 bytes). | `grammar/string_literal.w:184-224` (`process_string_literal`, `validate_utf8_literal`), `:285-313` (`char_pointer_literal` / `emit_utf8_string_descriptor`) |
| UTF-8 in `s"..."` (explicit UTF-8-string prefix) | Same validation and storage as default `"..."`. | `grammar/string_literal.w:360-366` (`utf8_string_literal`) |
| UTF-8 in `c"..."` (legacy C string) | Clean compile. Bytes pass through **unvalidated** — `c_char_pointer_literal` never calls `validate_utf8_literal`. Deliberately: it's the raw-bytes/FFI escape hatch. Confirmed: `c"bad: \xff\xfe"` compiles and runs with no complaint at compile *or* run time (until something calls a UTF-8-consuming API on it — see next row). | `grammar/string_literal.w:351-357` (`c_char_pointer_literal`) |
| Runtime UTF-8 boundary on `c"..."` bytes | `lib/utf8.w`'s `utf8_write`/`string_from_bytes` validate at the point a `char*` blob is turned into a `string` or written as UTF-8 output, and `die`/trap with `invalid UTF-8 c string` if it isn't. This is already exactly the Python-3-style explicit bytes↔text boundary — already tested (`tests/string_utf8_invalid_cstr_fixture.w`, `tests/string_utf8_invalid_cstr_arg_fixture.w`). | `lib/utf8.w:211-217` (`utf8_write`), `:164-175` (`string_from_bytes`) |
| UTF-8 in `f"..."` template strings | Clean compile. Each literal chunk is validated exactly like a plain string literal. Confirmed: `f"café: {n} 日本語"` compiles and prints correctly. | `grammar/template_string.w:261` (`validate_utf8_literal(length)` per chunk) |
| UTF-8 char literal (`'é'`) | Clean compile. Decodes the raw UTF-8 sequence to its Unicode codepoint as an `int`. Confirmed: `'é'` → `233` (U+00E9). Already tested: `tests/char_literal_test.w:37-38`. | `grammar/string_literal.w:97-130` (`char_literal_value`) |
| Truncated/invalid UTF-8 in a char literal (e.g. lone lead byte `'\xC3'`) | Clean compile-time error: `invalid UTF-8 char literal: '<byte>'`. | `grammar/string_literal.w:110-121` |
| Invalid UTF-8 bytes inside a default `"..."` literal | Clean compile-time error naming the specific defect: `invalid UTF-8 string literal` / `invalid UTF-8 continuation byte` / `overlong UTF-8 string literal` / `invalid UTF-8 surrogate` / `UTF-8 codepoint out of range`. Confirmed with `"bad: \xff\xfe byte"`. | `grammar/string_literal.w:185-224` (`validate_utf8_literal`) |
| Invalid UTF-8 bytes inside a comment | Clean compile — comments never validate, matching existing (permissive) behavior for any garbage bytes in comments today. | same anchors as comment rows above |
| **UTF-8 in identifiers** (variable/function/struct names) | **Breaks tokenization.** The identifier scan only accepts `a-z A-Z 0-9 _`; the first byte ≥0x80 ends the identifier immediately. That byte (and each subsequent one) is then re-lexed one raw byte at a time as its own bogus token via the tokenizer's single-byte catch-all, producing cascading, confusing parser errors. Confirmed for variable (`int café = 5`), function (`int héllo(): ...`), and struct (`struct Café: ...`) names — e.g. `int café = 5` yields `';' expected, found '<invalid-byte-token>'` at the byte position right after `caf`. | `compiler/tokenizer.w:213-216` (identifier char class), `:342-343` (`else if (nextc != -1): takechar()` catch-all) |
| **UTF-8 BOM** (`EF BB BF`) at file start | **Breaks tokenization immediately**, even for an otherwise all-ASCII file. Not whitespace (whitespace skip only recognizes byte `' '`, `9`, `10`), not caught by any lexical rule; the first BOM byte becomes its own bogus token. Confirmed: `Could not find a valid primary expression, token: '<byte>'` at line 1, column 1. | `compiler/tokenizer.w:194` (whitespace skip condition), `:342-343` (catch-all); fix point: `compiler/compiler.w:81` (`nextc = get_character()` in `compile_attempt`, right before the first `get_token()`) |
| `w check --json` on **valid** UTF-8 content | Clean, well-formed JSON/UTF-8 — bytes ≥32 are copied through unescaped in `diag_write_json_string`, which is correct because they're already valid UTF-8 (JSON strings may contain raw UTF-8). | `compiler/diagnostics.w:96-118` |
| `w check --json` on **invalid** UTF-8 bytes reflected into a diagnostic (BOM byte, broken-identifier byte, truncated char literal) | **Bug.** The same unescaped byte-copy path reproduces the raw invalid byte(s) verbatim into the `message` and `token` JSON fields. The surrounding punctuation is syntactically valid JSON, but the byte stream is not valid UTF-8, which breaks strict JSON/UTF-8 consumers. Confirmed three independent ways (invalid-UTF-8 string literal error, invalid-identifier-byte error, truncated-char-literal error): in each case decoding the emitted NDJSON line as UTF-8 (`python3` `bytes.decode('utf-8')`/`json.loads` on the raw bytes) raises `UnicodeDecodeError`. | `compiler/diagnostics.w:96-118` (`diag_write_json_string` has no UTF-8 validation/escaping branch) |
| Diagnostic **line/column** counting | **Byte-based, not codepoint-based**, with no UTF-8 awareness at all — `column_number` increments by exactly 1 per byte read in `get_character()`, tabs included. For ASCII-only files (100% of the current corpus) this is indistinguishable from codepoint counting, so it has never surfaced before. Confirmed divergence: for `string s = "日本語" x` (a syntax error right after a 3-codepoint/9-byte CJK string), the reported error column is **25** (byte offset of `x`) vs. **19** if columns counted codepoints instead of bytes. | `compiler/tokenizer.w:82-106` (`get_character`); documented consumer contract: `docs/projects/ai_tooling.md:301` ("`line`, `column`: 1-based, from the current token's start position" — silent on byte-vs-codepoint because it's never mattered until now) |
| `tests/parser_generator/w.pg` lexer on UTF-8 **comments/strings** (`parser_generator_w_test`) | Already byte-transparent, zero diagnostics — matches the main tokenizer's permissive comment/string handling exactly. Confirmed with a direct `wlang_lex()` probe (standalone program importing `libs.extras.parser_generator.runtime` + `bin.generated_w_parser`): 0 diagnostics for both a UTF-8 comment source and a UTF-8 string-literal source. `./wbuild parser_generator_w_test` passes clean on the current tree (baseline, no probe files added). | `libs/extras/parser_generator/lexer.w:121-141` (comment matchers), `:311-329` (`pg_lexer_matcher_string`) |
| `tests/parser_generator/w.pg` lexer on UTF-8 **identifiers** | Same ASCII-only restriction as the main tokenizer, and it breaks the same way: probing `wlang_lex()` on `int café = 1` produces an `IDENT` token whose text is truncated to `"caf"` plus 2 lexer diagnostics for the trailing UTF-8 bytes of `é`. This mirrors the main compiler's failure mode almost exactly (ASCII prefix survives as a truncated identifier, then per-byte lex errors). | `libs/extras/parser_generator/lexer.w:15-32` (`pg_lexer_is_alpha` / `is_ident_start` / `is_ident_part`) |

## 2. Staged proposal

### Stage 1 — strings/comments hardening (cheap, do first, no policy decisions)

Everything here is either already correct (needs only test coverage) or
a small, self-contained, low-risk fix:

1. **Tests for the already-working raw-UTF-8-byte paths.** Existing
   coverage (`tests/string_utf8_test.w`, `char_literal_test.w:37`,
   `template_string_test.w:89`) exercises `\u`/`\U` escapes and one
   inline `café` in an f-string, but there is no fixture that puts raw
   multi-byte UTF-8 source bytes directly in a `#`/`/* */` comment, or a
   plain `"..."` literal, as its own dedicated regression. Cheap,
   zero-risk, closes the audit's "working but untested" gap.
2. **BOM handling.** Recommend silently skipping a single leading UTF-8
   BOM (`EF BB BF`) at the very start of a file — matches Python 3,
   Go, Rust, and most modern toolchains, and is the common case Windows
   editors (Notepad, some VS Code configurations) produce unprompted.
   Fix point is exactly `compiler/compiler.w:81`, right after the first
   `get_character()` call in `compile_attempt`: peek 3 bytes, and if
   they match `EF BB BF`, consume them before the first `get_token()`.
   Must not regress a file whose first *content* byte legitimately
   starts with those three bytes as data — irrelevant here since this
   only runs before the very first token of a `.w` source file, not
   inside a string/comment.
3. **Fix `diag_write_json_string` to never emit invalid UTF-8/invalid
   JSON.** Independent of every other decision in this doc — garbage
   bytes can already reach a diagnostic today (a BOM byte, a
   broken-identifier byte, a truncated char literal) and corrupt
   `w check --json` output right now. Minimal fix: track UTF-8
   continuation state while copying `message`/`token`/`file` bytes
   through, and `\u00XX`-escape any byte that is not part of a
   well-formed sequence (a lone continuation byte, an incomplete lead
   byte at end of string, a raw 0x80-0xFF byte with no valid follow-up).
   This is a pure diagnostics-emission fix; it does not change what the
   tokenizer accepts.
4. **Column semantics.** See §3 — recommend switching to codepoint-based
   columns as part of this stage, since it is a one-line, backward-compatible
   change (see below) and is orthogonal to the identifiers decision.

None of Stage 1 touches what bytes are *legal* in an identifier, so it
carries no PEP-3131-style policy risk and needs no maintainer decision
beyond the BOM strip-vs-error question (§6).

### Stage 2 — identifiers (separate, opt-in-by-decision, real policy cost)

This is where issue #287's explicit ask to learn from Python 2→3 matters
most. Two things Python got right and one thing that caused years of
follow-on pain are all directly relevant:

- **Got right: an explicit bytes/text boundary.** Python 3's `str`
  (always text) vs. `bytes` (always raw) split is exactly the
  distinction W already has between `string` (UTF-8-validated,
  `"..."`/`s"..."`) and `char*` from `c"..."` (raw, unvalidated,
  boundary-checked by consumers like `utf8_write`). W does not need to
  invent this — it should protect it. Any identifier-stage change must
  not blur this line (e.g. must not make `c"..."` start silently
  validating, must not let identifiers leak raw invalid bytes into the
  symbol table).
- **Got right (mostly), but expensive: PEP 3131 "Supporting Non-ASCII
  Identifiers"** (Python 3.0, 2007). It allowed identifiers to contain
  Unicode letters per Unicode category (`Lu`, `Ll`, `Lt`, `Lm`, `Lo`,
  `Nl`, underscore, and a few continuation categories for the
  non-initial position), and mandated **NFKC normalization** of every
  identifier at parse time so visually-identical-but-differently-encoded
  spellings compare equal. Costs/lessons directly relevant to a
  from-scratch, no-libc, statically-linked, self-hosting compiler:
  - It requires bundling real Unicode category + normalization tables
    into the tokenizer. That is nontrivial data (megabytes of table, in
    CPython's case) to carry into `compiler/tokenizer.w`, which is
    inside the seed-compiled closure (see §4) — a real, non-trivial
    scoping question of its own, independent of the parsing-logic
    change.
  - In practice the feature is rarely used. Most large Python codebases
    and PEP 8 itself still recommend ASCII identifiers; non-ASCII
    identifiers show up mostly in educational/math-heavy code (e.g.
    `λ`, `π`, `Δ`) or code written for non-English-speaking teams. Low
    real-world usage relative to implementation cost is a real signal,
    not a reason to skip the feature, but a reason to keep the surface
    small (§6 Q4).
  - **What it hit later: homoglyphs / confusables and bidi tricks.**
    PEP 3131 shipped without confusables detection. Years later, the
    2021 "Trojan Source" disclosure (Boucher & Anderson, CVE-2021-42574
    and siblings) showed that Unicode bidirectional-override control
    characters and homoglyphs could make source code *display*
    differently than it *executes* across essentially every language
    that allowed non-ASCII in comments/strings/identifiers — Python,
    C, C++, Rust, Go, JavaScript, etc. all issued advisories and most
    added detection for dangerous bidi control characters, invisible
    characters, and (for some) mixed-script identifiers after the
    fact. The actionable lesson for W: **do not ship the identifiers
    stage without at least the bidi/invisible-character floor from day
    one** — retrofitting it after adoption is exactly what the wider
    ecosystem had to do in 2021.

Recommended v1 scope for Stage 2 (subject to maintainer sign-off, see
§6):

- Identifier bytes: any well-formed UTF-8 sequence decoding to a
  codepoint that is (a) not ASCII (that path is unchanged), (b) not a
  C0/C1 control character, (c) not one of the Unicode bidirectional
  control characters (`U+202A`-`U+202E`, `U+2066`-`U+2069`, `U+061C`),
  and (d) not a zero-width/invisible character (`U+200B`-`U+200F`,
  `U+FEFF` mid-identifier, etc.) — a security floor, not a linguistic
  one. This is deliberately narrower than "any Unicode letter category"
  to start: it is expressible without bundling full Unicode category
  tables (just a short blocklist of dangerous ranges), and can be
  widened to true `XID_Start`/`XID_Continue` semantics later once the
  table-size/seed-cost question (§6 Q4) is settled.
- Normalize identifiers to **NFC** (not NFKC — NFKC also folds
  compatibility variants like ligatures and width forms, which is more
  surprising for identifier equality than plain canonical composition)
  before symbol-table insertion/lookup, so that visually-identical
  spellings using different combining-mark decompositions are the same
  symbol. Confirmed today's symbol table uses plain byte `strcmp` for
  name equality throughout (`compiler/type_table.w:336,778,882,916` and
  equivalents in `compiler/symbol_table.w`) — without normalization,
  two byte-different-but-visually-identical identifiers would silently
  become two distinct symbols, reintroducing exactly the kind of
  confusing, hard-to-spot bug this issue wants to avoid.
- Confusables detection (cross-script homoglyphs, e.g. Cyrillic `а`
  vs. Latin `a`) explicitly **out of v1 scope**, same posture as Go
  (never added it) and Rust (a `mixed_script_confusables` *warn*, not
  error, lint). Flagged as a documented known gap, not silently
  dropped.

## 3. Column-semantics decision

**Recommendation: switch `column_number` to codepoint-based counting in
Stage 1**, ahead of and independent of the identifiers decision.

Why now, and why it's safe:
- The fix is a one-line, purely-local change to
  `compiler/tokenizer.w:82-106` (`get_character`): only increment
  `column_number` when the byte just read is *not* a UTF-8 continuation
  byte (`0x80`-`0xBF`), instead of incrementing per byte unconditionally.
  No decoding, no table, no interaction with the identifiers decision.
- It is **backward compatible with every existing fixture**: for
  all-ASCII input (100% of the current tree), "per codepoint" and "per
  byte" produce identical column numbers, since ASCII bytes are always
  1-byte codepoints. Only lines containing multi-byte UTF-8 content
  before a diagnostic change value — and no current fixture has any.
  `warning_test`/`type_system_*_test`/fixture `column` assertions are
  therefore unaffected.
- It matches human/editor expectation far better than raw bytes: a
  developer (or an AI agent consuming `w check --json`, per
  `docs/projects/ai_tooling.md`) reading "column 19" expects to count 19
  visible characters, not 19 bytes through a CJK string.
- It leaves `byte_offset`/`token_start_offset` (the *other* counter,
  used by `grammar/generic.w` to re-seek and re-lex a recorded source
  span with type parameters bound) untouched and still byte-exact —
  these are already two separate counters in the tokenizer today
  (`byte_offset` vs. `column_number`), so there is no risk of conflating
  a re-seek offset with a display column.

Caveat to document, not fix: codepoints are not what most Language
Server Protocol implementations expect either (LSP positions are UTF-16
code units by default) — but since there is no in-tree LSP today (per
CLAUDE.md, "moved out of this repo in July 2026") and neither raw bytes
nor codepoints match UTF-16 code units for astral characters (emoji,
etc.) anyway, codepoints is the choice that needs no extra table and is
correct for terminal/plain-text tooling, which is what exists today. A
future LSP layer will need its own UTF-16 remapping regardless of which
of {bytes, codepoints} the compiler reports — that translation has to
exist somewhere, and living in the (external, per CLAUDE.md) LSP layer
rather than the compiler core is consistent with how this repo already
factors that boundary.

## 4. What must NOT change

- **Seed closure files stay ASCII in their own source text.**
  `compiler/tokenizer.w`, `grammar/*.w`, `code_generator/*.w`,
  `compiler/*.w`, `debugger/*.w`,
  `libs/extras/{c_import,c_preprocessor,parser_generator}`,
  `structures/hash_table.w`, `structures/w_list.w`, and anything they
  import are compiled by the *currently pinned* seed (`SEEDS`), which
  will not understand UTF-8 identifiers even after this feature lands in
  `bin/wv2` — not until a release is cut and `SEEDS` is bumped per the
  documented "Seed promotion" flow. This is a process trap, not a
  technical blocker: nobody should give a variable in `tokenizer.w`
  itself a non-ASCII name the moment identifiers ship in `wv2`: the old
  pinned seed used to bootstrap every other checkout still can't read
  it.
- **Frozen diagnostic message text.** `warning_test`,
  `type_system_*_test`, and fixture `expect_stderr`/`reject_stderr`
  assertions freeze the exact current strings (`"';' expected, found
  '%s'"`, `"Could not find a valid primary expression, token: %s"`,
  `"invalid UTF-8 string literal"`, etc.). Any wording change (e.g. a
  clearer BOM-specific message) must update every fixture it touches in
  the same commit — CLAUDE.md's standing rule, reconfirmed here because
  a BOM fix is exactly the kind of change likely to want a new/clearer
  message.
- **`byte_offset`/`token_start_offset` stay byte-exact** even if
  `column_number` becomes codepoint-based (§3) — `grammar/generic.w`
  depends on byte-precise re-seeking.
- **`c"..."` stays raw/unvalidated at compile time.** It is the
  deliberate FFI/raw-bytes escape hatch (`raw_asm`, syscall buffers,
  arbitrary binary blobs); making it UTF-8-validate would be a breaking
  behavior change for legitimate non-UTF-8 uses. The existing
  runtime-boundary validation (`utf8_write`, `string_from_bytes`) is the
  correct place for that check, and it already exists — the contract
  lives at the `string`/`char*` boundary, not the compile-time literal.
- **Human (non-JSON) diagnostic output format stays `file:line`, no
  column** — already explicitly "frozen by tests" per
  `docs/projects/ai_tooling.md`; column stays a JSON-only field unless a
  separate decision adds it to human output.
- **`parser_generator_w_test` keeps parsing every tracked `.w` file.**
  Confirmed today's `tests/parser_generator/w.pg` lexer already tolerates
  UTF-8 in comments/strings/char literals with zero changes needed
  (§1) — any Stage-1 fixture is safe to add immediately. Any Stage-2
  identifier fixture is **not** safe to add until
  `libs/extras/parser_generator/lexer.w`'s `pg_lexer_is_alpha` /
  `is_ident_start` / `is_ident_part` are updated in the *same* PR as the
  tokenizer change — otherwise `parser_generator_w_test` regresses
  immediately on the new fixture, per CLAUDE.md's "new language syntax
  must also be added to the parser-generator grammar" rule (a
  lexer-character-class widening is the same kind of coupling even
  though it is not new grammar syntax per se).

## 5. Test plan

**Already covered (verified present, no action):**
`tests/string_utf8_test.w` (decode/encode/boundaries, `\u`/`\U` escapes,
codepoint iteration), `tests/char_literal_test.w:37`
(`test_utf8_char_literals`, raw `'é'`), `tests/template_string_test.w:89`
(raw `café` in an f-string vs. its `é` escape equivalent),
`tests/string_utf8_invalid_cstr_fixture.w` /
`_arg_fixture.w` (runtime rejection of invalid UTF-8 at the
`c"..."`→`string` boundary).

**Stage 1 additions:**
1. A fixture with raw (non-escaped) multi-byte UTF-8 bytes directly in a
   `#` line comment and a `/* */` block comment, asserting clean
   compile + normal run — closes the "byte-transparent but untested"
   comment gap.
2. A fixture with a raw UTF-8 default `"..."` literal (not only escape
   sequences) asserting `.length` is the byte length and content
   round-trips correctly through `println`/`utf8_write`.
3. A BOM fixture (`EF BB BF` + otherwise-plain source) asserting clean
   compile and normal execution after the Stage-1 fix — document the
   *current* failing behavior (`Could not find a valid primary
   expression`) as the "before" state in the PR, not as a committed
   test (it changes).
4. A `w check --json` fixture that deliberately triggers a diagnostic
   from invalid UTF-8 input (reusing the audit's invalid-string/invalid-identifier-byte
   probes) and asserts the emitted NDJSON line is valid UTF-8 (and thus
   valid JSON) — regression guard for the `diag_write_json_string` fix.
5. A column-semantics fixture: a diagnostic triggered after
   multi-byte UTF-8 content on the same line, asserting `column` equals
   the codepoint offset (not the byte offset) — regression guard for §3,
   modeled directly on this audit's `string s = "日本語" x` probe
   (byte column 25 vs. codepoint column 19).
6. No new `parser_generator_w_test` target needed — it already re-parses
   every tracked file, so fixtures 1-3 above are automatically exercised
   by it once committed; confirm it stays green in the same PR (already
   confirmed green on the current tree as a baseline in this audit).

**Stage 2 additions (once identifier policy in §2/§6 is decided):**
7. `tests/utf8_identifier_test.w`: a UTF-8 variable, function, and
   struct name each compiling and running correctly end-to-end,
   mirroring `char_literal_test.w`'s style.
8. Negative fixtures for the security floor: a bidi-control character
   and a zero-width character inside an otherwise-plausible identifier,
   each expected to be a clear compile error (`# expect_stderr:`).
9. An NFC-equivalence fixture: two spellings of "the same" identifier
   using different Unicode normalization forms, asserting they resolve
   to one symbol (if normalization ships) — or, if the maintainer
   instead chooses byte-identical-only matching, asserting the
   *documented* behavior (two distinct symbols) so it's a locked-in
   decision, not an accident.
10. The `libs/extras/parser_generator/lexer.w` identifier-matcher update
    lands in the same PR/commit as the tokenizer change (hard
    requirement, not a nice-to-have — see §4's last bullet).

## 6. Open questions for the maintainer

1. **BOM policy**: silently strip a leading UTF-8 BOM (Python 3 /
   most modern toolchains), or hard-error with a clear, purpose-built
   message ("W source files must not start with a UTF-8 byte-order
   mark")? Silent-strip is friendlier to Windows/Notepad users; a hard
   error is more explicit but will surprise them the first time.
2. **Column semantics**: adopt the codepoint-based fix in Stage 1 (this
   doc's recommendation, §3), or hold it until the identifiers decision
   lands so external tooling absorbs one contract change instead of two?
   Relatedly: should `w check --json` eventually carry *both* a byte and
   a codepoint column as separate fields (additive, non-breaking) so
   downstream consumers pick what they need, rather than the compiler
   picking one?
3. **`c"..."` validation**: stays permanently raw/unvalidated at compile
   time (this doc's recommendation), or should there be an opt-in
   stricter mode (e.g. a `--strict`-gated warning) for the common case
   where a `c"..."` literal is plain text and accidentally contains
   mojibake?
4. **Identifier character set scope**: ship the narrow security-floor
   allowlist proposed in §2 first (cheap, no Unicode category tables),
   or go straight for full `XID_Start`/`XID_Continue` Unicode-letter
   semantics (PEP 3131's actual scope) despite the seed-graph
   table-size/maintenance cost? Given a statically-linked, no-libc,
   multi-target (x86/x64/arm64/wasm) compiler, is bundling real Unicode
   category tables into `compiler/tokenizer.w` acceptable, or should
   that data live in a generated/vendored table file with its own size
   and update-cadence tradeoffs?
5. **Normalization form**: NFC (this doc's recommendation) vs. NFKC
   (Python's actual PEP 3131 choice, which also folds compatibility
   variants) vs. no normalization at all (byte-identical matching only,
   simplest to implement, but reintroduces the "visually identical,
   silently different symbol" trap this issue explicitly wants to avoid
   by referencing Python's migration)?
6. **Confusables/bidi defense posture for v1**: is "reject bidi-control
   and zero-width characters outright, defer full mixed-script
   confusables detection" (this doc's recommendation, matching
   Rust/Go's post-Trojan-Source posture) an acceptable v1 floor, or does
   the maintainer want confusables detection (at least a warning) from
   the very first release, given this is a from-scratch compiler
   without years of installed-base trust to lean on the way C/Python/Go
   had when Trojan Source landed?
7. **Opt-in mechanism**: once Stage 2 ships, is UTF-8 identifier support
   simply always-on (the same posture strings/comments already have —
   no flag), or gated behind an explicit compiler flag / `# wbuild:`-style
   directive? The issue title says "opt-in" is worth considering; this
   doc leans toward always-on (simpler, matches how strings/comments
   already work, and a security floor makes always-on safer) but flags
   it as a real decision rather than assuming it.
8. **Seed bump intent**: is there any actual desire to eventually write
   non-ASCII identifiers inside the compiler's own seed-graph source
   once `SEEDS` catches up, or does "seed closure stays ASCII" become a
   permanent house style regardless of language capability (i.e. this
   is purely a feature for user programs, and the compiler is not
   expected to dogfood it)? Affects nothing about the implementation,
   but is worth stating explicitly so it doesn't get relitigated per-PR.
