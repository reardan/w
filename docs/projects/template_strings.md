# Template strings (f-strings)

`f"..."` literals are expressions producing a `string` value (the two-word
`{data_ptr, length}` descriptor, see `docs/projects/arrays_slices_strings.md`):

```
int count = 42
string s = f"total: {count} items"        # "total: 42 items"
string t = f"sum={count + 1} {{literal}}" # "sum=43 {literal}"
```

## Lexing: chunk mode

The compiler is single-pass with no AST, so the embedded expressions must be
compiled by the ordinary `expression()` rule while the literal is being read.
The tokenizer therefore delivers an f-string in *chunks* instead of one token:

- When the identifier scan has consumed a lone `f` and the next character is
  `"`, the tokenizer fuses the quote and calls `take_template_chunk()`
  (`compiler/tokenizer.w`). The resulting token is the raw literal text up to
  and **including** its terminator: the closing `"` (final chunk) or a single
  `{` (an embedded expression follows).
- `grammar/template_string.w` decodes and appends the chunk, then — if the
  chunk ended at `{` — calls `get_token()` and `expression()`, which consume
  tokens normally from the stream inside the braces. After the expression the
  current token must be `}`; the grammar then calls
  `get_token_template_chunk()`, which replaces the current token with the next
  chunk, scanning from the character right after the `}`.

No persistent tokenizer mode flag is needed: chunk scanning happens only when
the tokenizer sees `f"` or when the grammar explicitly asks for the next
chunk. Nested f-strings inside embedded expressions therefore work by plain
recursion (`f"outer {f"inner {x}"}"` is covered by a test).

### Escapes

- `{{` and `}}` are literal braces. The tokenizer keeps them doubled in the
  chunk token (so a chunk-terminating single `{` stays unambiguous) and the
  grammar collapses them while decoding. A single `}` in literal text is a
  compile error (`single '}' in template string; use '}}'`), like Python.
- All `s"..."` escapes work in chunks: `\n`, `\t`, `\r`, `\0`, `\xHH`,
  `\uHHHH`, `\UHHHHHHHH`; a backslash escapes any other character (so `\"`
  and `\{` also work). Decoding is shared with `grammar/string_literal.w`
  (`string_hex_value`, `string_append_utf8`).
- Chunks are UTF-8 validated like `"..."`/`s"..."` literals.
- Reaching end of file inside an f-string reports
  `unterminated template string literal` (unlike the legacy string forms,
  which have no EOF check).

## Lowering

Each literal lowers to calls into `structures/string.w`:

```
b = __w_template_new()                 # string_builder
__w_template_bytes(b, chunk, length)   # literal chunk (length-explicit, so \0 survives)
__w_template_int(b, value)             # int-like expression
__w_template_cstr(b, value)            # char* expression
__w_template_str(b, value)             # string expression
result = __w_template_finish(b)        # -> string descriptor, frees the builder struct
```

Chunk bytes are emitted into the code stream behind a `call` (the same trick
as `c"..."` literals). The `__w_template_*` wrappers keep the compiler out of
the user namespace; they sit on new public helpers `string_append_bytes`,
`string_append_string` and `string_builder_to_string` (the descriptor shares
the builder's data buffer; `__w_template_finish` frees only the builder
struct, the bytes belong to the resulting string).

Everything is plain word-sized function calls, so x86 and x64 work from the
same lowering (`./wbuild template_string_test` / `template_string_64_test`).

## Supported expression types (v1)

- **int-like**: `int`, fixed-width ints, `char`, `bool`, enums — appended via
  `itoa`, so `char` and `bool` print numerically (`'A'` → `65`, `true` → `1`).
- **`char*`** — appended as a NUL-terminated C string.
- **`string`** — appended by descriptor length (embedded NUL bytes survive).

Anything else — floats, structs, non-char pointers, `map`/`set`/`list`,
arrays/slices, `void`, bare function names — is a compile error:
`unsupported template string expression type: 'T'`.

**Floats are not supported** in v1: `ftoa` lives in `lib/format.w`, not in
`structures/string.w`, and float values travel in xmm/eax with per-target ABI
differences; wiring that into the on-demand runtime was not worth it for the
first cut. `f"{x}"` with a float `x` errors; use `ftoa` explicitly.

## On-demand runtime import

`structures/string.w` is not auto-imported. The lowering follows the json
codec precedent (`grammar/json_builtin.w`): call sites emitted before the
module exists go through per-helper backpatch chains (same encoding as the
`'U'` symbol chains — the chains live outside the symbol table because
`function_definition`'s scope truncation would drop a forward declaration),
and the drivers call `template_string_finish_import()` at a top-level
boundary: `link_impl` (`compiler/compiler.w`), the REPL (`repl.w`) and wdbg
(`debugger/wdbg.w`). When the program imports `structures.string` itself, the
helpers resolve directly through the symbol table and no chain is created.

## Parser generator

`parser_generator_w_test` parses every tracked `.w` file with a parser
generated from `tests/parser_generator/w.pg`. The shared `string` matcher
(`pg_lexer_matcher_string` in `libs/extras/parser_generator/lexer.w`) now
recognizes `f"` and hands off to `pg_lexer_match_template_string`, which
consumes the **entire** literal (embedded braces, nested strings and char
literals inside expressions, `{{`/`}}` pairs) as one STRING token, keeping
the lex round-trip lossless. Token matching is longest-match, so the STRING
span always beats the `f` identifier. No `w.pg` grammar rule changes were
needed; a comment there records the arrangement.

Limitation: the PG lexer skips quoted runs inside embedded expressions
without brace tracking, so a *nested* f-string that itself embeds `{...}`
(e.g. `f"{f"{x}"}"`) is not lexed as one token. The compiler itself handles
such nesting fine; just don't use it in tracked files, or extend the matcher.

## Seed constraint

All implementation files (`compiler/tokenizer.w`, `grammar/template_string.w`,
`structures/string.w`, ...) are compiled by the committed seed, so they use
only pre-existing syntax. F-string syntax itself appears only under `tests/`.

## Tests

- `tests/template_string_test.w` (`template_string_test`,
  `template_string_64_test`; also in `build.json` and `tools/test_map.w`):
  plain/empty literals, int/char*/string interpolation, operators, calls,
  adjacent expressions, escaped braces, `\x`/`\u`/raw UTF-8 chunks, char,
  bool and enum values, f-string as call argument, nesting, map indexing.
- Error fixtures (x86 target only, arch-independent):
  `template_string_error_fixture.w` (unsupported type),
  `template_string_unterminated_fixture.w` (no closing quote),
  `template_string_unterminated_expr_fixture.w` (unclosed `{`),
  `template_string_stray_brace_fixture.w` (single `}`).
