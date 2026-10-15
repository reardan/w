# CSS lexical and tree specification

This is the maintained specification for the handwritten scanner and recovering
parser in `css.w`. It is an original implementation informed by CSS Syntax Level
3 (<https://www.w3.org/TR/css-syntax-3/>); no grammar or generated source was
imported. There is no code generation step or generated artifact to synchronize.
The test suite asserts deterministic tokens, matching delimiters and semantic
nodes from identical explicit-length inputs.

The scanner visits input bytes left to right with this priority:

1. ASCII whitespace (`space`, tab, LF, CR, FF) → `space` (decoded value one space).
2. `/*` through the next `*/` or EOF → `comment` (empty decoded value).
3. Single/double quoted sequences → `string`, or `bad-string` at an unescaped
   newline. Escaped newlines are removed; EOF implies string closure and emits
   a diagnostic. Newlines terminate a bad string without consuming the newline.
4. Optional sign, digits and/or decimal fraction, optional exponent → `number`.
   An immediately following identifier makes `dimension`; `%` makes `percentage`.
   Decoded values retain numeric spelling and decoded unit or percent suffix.
   `number_length` records the numeric prefix boundary before escape decoding.
5. Name-start, `--`, `-` followed by name-start, or valid escape → `ident`,
   except an ASCII-case-insensitive decoded `url` immediately followed by `(`.
   When the next non-whitespace byte is not a quote, consume a `url` token
   through `)` or EOF; its decoded value excludes the wrapper and edge whitespace.
   Escapes and NUL replacement apply inside URLs. Whitespace followed by more
   content, quotes, `(`, non-printable bytes, or a backslash-newline produce an
   empty `bad-url` token. Recovery consumes through the next unescaped `)` or
   EOF; internal punctuation never becomes component delimiters. A quoted URL
   retains the existing `ident` plus balanced-parenthesis/string representation.
6. `@` followed by an identifier → `at-keyword`; `#` followed by name character
   or valid escape → `hash`. Their decoded values omit the prefix. Hash tokens
   record `hash_id` when the raw spelling after `#` would start an identifier;
   unrestricted hashes such as `#123` remain distinct from escaped ID hashes.
7. Any other byte → `delim`.

Names allow ASCII letters, underscore, non-ASCII bytes, digits after the first
character, hyphens and escapes. A valid escape is backslash followed by a byte
other than newline, or EOF. An escaped EOF in names/URLs produces U+FFFD and
a diagnostic; a trailing backslash in a string is ignored before its EOF
diagnostic. Hex escapes consume 1–6 hex digits and one optional
whitespace codepoint (CRLF counts as one). Zero, surrogate and out-of-range
escapes decode to U+FFFD. Input NUL in names/strings also becomes U+FFFD. Escapes
are UTF-8 encoded; other non-ASCII source bytes are retained without validating
UTF-8. Raw source spans always refer to the original bytes.

Delimiter tokens `(`, `[`, `{` and their matching closers retain partner token
indices. Comments and strings never contribute delimiters. Unexpected closers
are diagnosed without altering the opening stack. EOF implicitly closes
remaining blocks/functions with synthetic closing delimiter tokens whose source
spans are `[length,length)`. Partner indices remain valid for consumers and
diagnostics record the closure. Synthetic tokens count toward the token limit.

A stylesheet is a list of qualified rules and at-rules. Each rule retains its
prelude token range. A qualified rule requires a brace block. Semicolons remain
inside qualified preludes for downstream grammar validation. At-rules end at a
semicolon, brace block or EOF. `media`, `supports`, `layer`, `container` and
`keyframes` blocks recursively contain rules; `font-face` and `page` blocks
contain declarations. Unknown at-rule blocks are retained as opaque token
ranges. At-rule classification is ASCII case insensitive.

Selectors are top-level comma-separated component sequences. Commas inside
balanced blocks do not split a selector. Empty selectors are diagnosed and
omitted. Selector nodes preserve descendant whitespace, combinator tokens,
attribute blocks and functional pseudo arguments. Full selector validity,
matching and specificity are outside this syntax API.

Declarations split only at top-level semicolons. A declaration starts with an
identifier, optional trivia, and colon; otherwise the segment is diagnosed and
omitted. Its value is a component-token range trimmed of edge trivia. A trailing
ASCII-case-insensitive `!important` is extracted into `important`. Bad strings
and bad URLs and unmatched closing delimiters invalidate the declaration. Balanced nested
blocks, including custom-property braces, retain internal semicolons. Invalid
properties or values under a particular CSS module are left to its consumer.
EOF can close the last declaration without a semicolon.

Known deviations: function tokens (including quoted URLs) remain ident plus
opening parenthesis. CDO/CDC are ordinary delimiters. CSS nesting declarations
and full selector grammar validation are not implemented. A missing closing
parenthesis/bracket consumes components until EOF according to block recovery;
no heuristic guesses where a later rule was intended to start.
