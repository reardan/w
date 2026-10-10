# CSS parsing library

Import `libs.extras.css.css`. This library owns a syntax tree independent of a
browser DOM, selector matcher, cascade or layout engine. The maintained lexical,
tree and recovery specification is [syntax.md](../../libs/extras/css/syntax.md).
It also records provenance and precise limitations.

All entry points take `(char* source, int length, css_limits* limits)`:

- `css_tokenize_n` returns decoded tokens, byte spans and balanced-delimiter links.
- `css_parse_stylesheet_n` additionally returns qualified rules and at-rules.
- `css_parse_declarations_n` parses an inline declaration list.
- `css_parse_selectors_n` splits a selector list into component-token groups.

Pass `0` for default limits. `css_default_limits()` allocates a caller-owned
configuration: 1 MiB input, 131072 tokens, 65536 nodes, nesting depth 128 and 256
diagnostics. The library copies the configuration. Input has an absolute 16 MiB
ceiling and configured depth must be 1–256. Invalid input and exhausted
input/token/node/depth budgets set `document.failed`; partial storage is still
owned and safe to free. Diagnostic storage stops at its configured cap. Syntax
errors recover locally and do not set `failed`. Callers should inspect both
`failed` and `diagnostics` before accepting the tree.

Every result copies the exact source bytes, so the caller may free the input
immediately. Each token has `kind`, decoded `value` and `value_length`, half-open
byte offsets `start/end`, and `match` (-1 for no matching delimiter). Source is
explicit-length, including embedded NUL. Invalid UTF-8 is retained as bytes;
this is a UTF-8-oriented syntax parser, not an encoding detector.

Unquoted `url(...)` produces one `url` token with the decoded URL and the full
wrapper's byte span. Malformed forms produce `bad-url` and a diagnostic, consume
through the next unescaped closing parenthesis or EOF, and invalidate only the
containing declaration. URL punctuation does not alter block balancing. Quoted
URLs retain `ident`, parenthesis, and string component tokens. Unterminated valid
URLs retain their decoded value with an EOF diagnostic.

Nodes have `kind`, decoded `name`, byte span, token range `first/last`, children
and an `important` flag. Qualified-rule children begin with selector nodes,
followed by declaration nodes. At-rules contain nested rules, declarations or an
opaque `block` node, according to the specification. Rule token ranges represent
the prelude; declaration token ranges represent the value excluding `!important`;
selector/block token ranges represent their components. Declaration byte spans
include the property and priority. All ranges are half-open.

All pointers obtained through a document are borrowed. Call
`css_document_free(document)` once to free source, tokens, nodes, diagnostics
and copied limits, including failed results. Do not separately free attached
nodes or mutate ownership lists. Returned documents share no mutable parser
state and can be used by independent consumers concurrently.

Build the small external-consumer example:

```sh
bin/wv2 examples/web/css_inspect.w -o bin/css_inspect
bin/css_inspect
./wbuild css_test css_64_test
```

The conventional tests cover semantic tokens and rules, escaped identifiers and
strings, dimensions/percentages, nested blocks and selectors, invalid-declaration
recovery without losing later rules, embedded NUL, EOF, ownership and limits.
There are no imported/generated grammar artifacts: deterministic fixtures test
the handwritten specification directly.
