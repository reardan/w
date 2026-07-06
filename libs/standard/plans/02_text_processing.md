# Plan: text processing

## Target area

Base code directory: `libs/standard/text/`

Suggested modules:

- `libs.standard.text.re`
- `libs.standard.text.difflib`
- `libs.standard.text.textwrap`
- `libs.standard.text.unicodedata`
- `libs.standard.text.codecs`
- `libs.standard.text.string`

## Python 3.14 reference implementations

Consult these CPython sources first:

- `Lib/re/` and `Lib/sre_parse.py` history - Python regex API and parser shape.
- `Modules/_sre/` - CPython regex VM and opcodes.
- `Lib/difflib.py` - sequence matcher and unified/context diffs.
- `Lib/textwrap.py` - wrapping/filling/dedent behavior.
- `Modules/unicodedata.c` and generated Unicode database files.
- `Lib/codecs.py` and `Lib/encodings/` - codec registry conventions.
- `Lib/string.py` - constants, template, formatter references.

## Current W starting point

- `lib/utf8.w` validates, decodes, encodes, counts codepoints, and offers simple
  string prefix/suffix helpers.
- `lib/grapheme.w` implements grapheme boundaries.
- `structures/string.w` provides `string_builder`.
- No regex, Unicode properties, case mapping, text wrapping, diff, or codec
  registry exists.

## Goals

1. Provide a minimal Python-compatible regex subset.
2. Add useful diff and wrapping utilities for tools, docs, and test output.
3. Add Unicode metadata lookup for categories and simple case mapping.
4. Add codec-style encode/decode helpers for UTF-8 and ASCII first.
5. Keep APIs W-simple and explicit about ownership.

## Non-goals for MVP

- No full backtracking compatibility for every Python regex feature.
- No locale-sensitive string operations.
- No complete normalization tables in the first pass.
- No error-handler plugin registry until codecs have multiple users.

## API sketch

`re.w`

- `regex* re_compile(char* pattern)`
- `regex* re_compile_flags(char* pattern, int flags)`
- `match* re_match(regex* r, string text)`
- `match* re_search(regex* r, string text)`
- `list[string] re_findall(regex* r, string text)`
- `int re_fullmatch(regex* r, string text)`
- `char* re_error(regex* r)`
- Flags: `RE_IGNORECASE`, `RE_MULTILINE`, `RE_DOTALL`

MVP regex syntax:

- Literals, `.`, `^`, `$`
- Character classes `[abc]`, ranges `[a-z]`, negation `[^x]`
- Quantifiers `*`, `+`, `?`
- Groups `(...)` and alternation `|`
- Escapes `\d`, `\w`, `\s`, plus uppercase negations

`difflib.w`

- `diff_opcodes* diff_sequence(char** a, int alen, char** b, int blen)`
- `list[char*] diff_unified(char** a, int alen, char** b, int blen, char* from, char* to)`
- `int diff_ratio(char** a, int alen, char** b, int blen)`

`textwrap.w`

- `list[char*] textwrap_wrap(char* text, int width)`
- `char* textwrap_fill(char* text, int width)`
- `char* textwrap_dedent(char* text)`
- `char* textwrap_indent(char* text, char* prefix)`

`unicodedata.w`

- `int unicode_category(int codepoint)` returning compact enum.
- `int unicode_combining(int codepoint)`
- `int unicode_is_alpha(int codepoint)`
- `int unicode_to_lower(int codepoint)`
- `int unicode_to_upper(int codepoint)`

`codecs.w`

- `codec_result codec_encode_utf8(string input)`
- `codec_result codec_decode_utf8(char* bytes, int length)`
- `codec_result codec_encode_ascii(string input, char* errors)`
- `codec_result codec_decode_ascii(char* bytes, int length, char* errors)`

## Implementation phases

### Phase 1: text utility foundation

- Add shared `text_span` and `text_error` structs.
- Add helpers for line splitting and joining using `string_builder`.
- Tests: empty text, final newline preservation, UTF-8 boundary behavior.

### Phase 2: regex parser and bytecode

- Build a recursive descent parser into a compact AST.
- Lower AST into a Thompson NFA or small VM. Prefer NFA for predictable runtime.
- Store capture group start/end byte offsets.
- Return errors instead of aborting on invalid patterns.
- Tests copied conceptually from CPython `Lib/test/test_re.py`: literals,
  anchors, classes, repetition, grouping, alternation, invalid syntax.

### Phase 3: regex execution

- Implement `match`, `search`, `fullmatch`, `findall`.
- Decide byte-vs-codepoint semantics: MVP should use byte offsets but never
  split invalid UTF-8. Document this difference from Python.
- Add ignorecase for ASCII first, then Unicode simple case mapping.

### Phase 4: diffs

- Port the `SequenceMatcher` idea from `difflib.py`.
- Use lists of lines as the primary type.
- Implement unified diff output compatible with Python's common format.
- Tests: insert/delete/replace/equal, no trailing newline marker if supported.

### Phase 5: wrapping and dedent

- Match Python `textwrap.wrap`, `fill`, `dedent`, `indent` for simple ASCII.
- Add tabs and whitespace collapsing options after MVP.

### Phase 6: Unicode data and codecs

- Generate compact tables from Unicode data outside the compiler bootstrap path.
- Keep generated W data under `libs/standard/text/generated/`.
- Start with category, combining class, and simple upper/lower maps.
- Tests: ASCII, accents, combining marks, emoji grapheme interactions.

## Compatibility notes from Python

- Python regex has many features: lookaround, named groups, lazy quantifiers,
  backreferences, conditionals. Treat these as deferred and return clear
  unsupported-feature errors.
- Python strings are Unicode codepoint sequences. W `string` is UTF-8 bytes plus
  length, so APIs must document whether offsets are bytes, codepoints, or
  graphemes.
- Python codecs use a registry and named error handlers. W can start with direct
  functions and later add registration.

## Acceptance criteria

- Regex MVP passes a focused compatibility test suite for supported syntax.
- Diff output can compare two text files and produce unified diff lines.
- Text wrapping works for ASCII and preserves UTF-8 boundaries.
- Unicode lookup tables are generated and tested, not hand-edited.
