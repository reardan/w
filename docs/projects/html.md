# HTML document foundation

`import libs.extras.html.html` provides a bounded, explicit-length tokenizer and
an owned static document tree for consumers such as Win. It does not depend on a
DOM, renderer, CSS library, or JavaScript runtime. This is an initial HTML subset,
not a claim of WHATWG parser conformance. The maintained lexical contract is
[`html.tokens`](../../libs/extras/html/html.tokens); implementation and fixtures
are hand maintained together. The complete named-reference table is generated
offline from a pinned WHATWG data snapshot and checked in; consumers need no
download or generation step.

```w
import libs.extras.html.html

html_document* document = html_parse(data, byte_length)
# document.failed means invalid input or a resource budget stopped parsing.
# A failed document can still contain a useful partial tree.
html_document_free(document)
```

## Ownership and representation

`html_parse(data, length)` copies exactly `length` bytes, including embedded NUL.
`html_parse_with_limits(data, length, &limits)` accepts caller budgets. Input may
be released or changed immediately after the call. `html_document` owns its
`source`, nodes, attributes, decoded strings, and diagnostics. Release it once
with `html_document_free`; do not free or mutate individual borrowed fields.
Destruction walks an allocation list, so it does not recurse through deep trees.
There is no process-global parser state.

`root` is an `HTML_DOCUMENT` node. Element nodes have kind `HTML_START`, an ASCII
lowercase `name`, linked `attributes`, and `first_child`, `last_child`,
`next_sibling`, and `parent` links. Text/comment/doctype nodes use `text` and
`text_length`. Attribute `value_length` and node `text_length` are byte lengths;
strings additionally have a convenience zero terminator. Text is byte-preserving
apart from CRLF/CR normalization, NUL replacement, and reference decoding; input
encoding detection and invalid UTF-8 repair are the caller's responsibility.

Every node, token, attribute and diagnostic has a half-open `[start, end)` source
byte span. Decoded lengths can differ from span widths. An element's span grows
through its closing tag, implied closure boundary, or last consumed input at EOF.
Synthetic containers have `implied = 1`, a zero start, and document containers
cover the input. Explicit `html`, `head`, and `body` starts populate the existing
containers, replace the synthetic start and attributes, and clear `implied`.
Diagnostics have owned messages and linked `next` fields. Recoverable malformed
markup adds diagnostics without setting `failed`.

## Token API

`html_tokenizer_new(data, length, limits_or_zero)` copies input. Repeated calls to
`html_tokenizer_next` return independently owned tokens; release **every** token
with `html_token_free`, including the terminal `HTML_EOF` token. Release the
context with `html_tokenizer_free`. Tokens remain valid after context disposal.
Kinds are `HTML_START`, `HTML_END`, `HTML_TEXT`, `HTML_COMMENT`, `HTML_DOCTYPE`, and
`HTML_EOF`. EOF is stable on repeated reads and is also returned after a fatal
budget/input error; inspect `tokenizer.failed` to distinguish those outcomes.
The tokenizer chooses text modes from encountered start tags; this API is a
whole-document tokenizer, not a resumable chunk interface.

Tag and attribute names are ASCII case folded. Quoted and unquoted values,
boolean attributes, and slash syntax are recognized. First duplicate attribute
wins; duplicates consume the attribute budget. Comments end at `-->`; other
`<!...>` and `<?...>` forms become diagnosed bogus comments. Case-insensitive
`<!doctype ...>` becomes a doctype token with retained text. EOF in tags,
comments, or declarations produces partial tokens and diagnostics.

Data/RCDATA and attribute values decode all 2,231 case-sensitive WHATWG named
reference spellings, including two-code-point values and 106 legacy spellings
without semicolons. Matching takes the longest valid spelling. In an attribute,
a legacy match followed by an ASCII letter, digit, or `=` stays literal:
`&notit;` becomes `¬it;` in text but remains `&notit;` in an attribute.
Other missing semicolons are diagnosed while still decoding the reference.
Unknown names stay literal; an unknown alphanumeric name followed by `;`
also produces a diagnostic. Decoded bytes are never parsed again as markup or
references (`&amp;lt;` becomes `&lt;`).

Decimal/hex numeric references consume their digit run with or without a
semicolon. Missing digits preserve the literal spelling with a diagnostic;
missing semicolons are diagnosed. Numeric NUL, out-of-range scalars (including
arbitrarily long overflowing digit runs), and surrogate values become U+FFFD.
HTML's Windows-1252 control-reference substitutions apply; unmapped controls
and Unicode noncharacters survive with diagnostics. Referenced CR stays CR,
because source newline normalization precedes reference decoding.
Text and attribute NUL bytes also become U+FFFD with diagnostics. CR and CRLF
become LF. `title`/`textarea` select RCDATA; `style`, `xmp`, `iframe`, `noembed`,
`noframes` select raw text. Their matching, case-insensitive end tag
requires a following space, `/`, or `>`; apparent other markup remains text.
`script` also disables reference decoding, but tracks HTML escaped and double-
escaped script states: `<!--` enters escaped text, a delimited `<script` enters
double escape, and a delimited `</script` leaves double escape as text. In normal
or escaped text it closes the element. `-->` returns either escape mode to normal
script data. EOF in either escape mode is diagnosed. JavaScript quoting and
comments do not affect these transitions. The lexical contract follows the
[HTML script states](https://html.spec.whatwg.org/multipage/parsing.html#script-data-state).

## Initial tree recovery

The tree builder always supplies `html`, `head`, and `body` containers. Initial
metadata (`title`, `meta`, `link`, `base`, `style`, `script`) goes into `head` until
body content starts. Ordinary text/elements start the body. An explicit initial
head is recognized; ending the head switches back to body insertion. Duplicate
document starts are diagnosed and keep the first attributes. Whitespace and
comments use the current insertion parent. Doctypes are attached to the document
root after the preallocated HTML container (source spans retain original order).

The standard HTML void element list never enters the open-element stack.
Self-closing syntax on other HTML elements is diagnosed and ignored. A new `p`
or the documented block set closes any open `p`: `div`, `section`, `article`,
`ul`, `ol`, `dl`, `table`, `blockquote`, `pre`, `hr`, `h1` through `h6`.
New `li`, `dt`/`dd`, `option`, `tr`, and `td`/`th` starts close an earlier matching
item through intervening descendants, without crossing a list/table/select/dl
boundary. End tags close the nearest named ancestor and any intervening nodes;
misnesting is diagnosed. Unmatched and void end tags are ignored with diagnostics.
EOF closes remaining spans without inventing source bytes.

Not implemented: full comment/doctype state machines and quirks modes, `plaintext`, `noscript`
scripting flags, fragment contexts, all HTML insertion modes, table foster
parenting and implicit tbody, adoption-agency formatting reconstruction,
SVG/MathML foreign content, templates, encoding sniffing, streaming/chunk resume,
and browser security/content policy. The tree is a deterministic useful initial
subset; malformed formatting/tables can differ from browser DOMs.

## Limits and validation

Defaults: 8 MiB source, 100,000 tokens, 100,000 nodes, depth 256 (root depth zero,
node depth must be less than the limit), 256 attributes per tag, 256 diagnostics.
Limits include synthetic nodes. A usable configuration requires at least four
nodes, depth three, one token, and nonnegative attribute/diagnostic caps. Input
and tree/token/attribute limit violations set `failed` and stop consumption.
The diagnostic cap suppresses later messages; `failed` remains authoritative
even when the cap is zero. Zero attributes prohibits attributes but allows tags.
Decoded storage is bounded by source size (NUL expansion at most 3x), node/token
caps and attribute cap; there is no unbounded recursive parser stack. Allocation
failure follows the repository allocator's normal behavior.

`tests/html_test.w` has x86/x64 semantic fixtures for implied tags, malformed
nesting, raw CSS/JS, RCDATA, references, attribute ownership, explicit-length NUL
input, spans, every EOF prefix of a mixed document, and independent resource
limits. `tests/html_entities_test.w` independently reads the pinned JSON and
checks every spelling in text and all three attribute quoting contexts, plus
legacy ambiguity, numeric repair, source spans, EOF prefixes and capped
diagnostics. Its selected fixtures also run with allocation leak checks.
The generated table uses immutable packed records and bounded binary lookups;
it requires no per-document table allocation or global initialization.

`bin/html_entities --check` verifies the snapshot's SHA-256 and
byte-identical regeneration as part of the entity tests. Run without `--check`
to regenerate. The [data provenance](../../libs/extras/html/entities-provenance.md)
records the upstream URLs, pin, licensing and update procedure.
`examples/web/html_document.w` demonstrates an external consumer using only
the public parse/free and linked-tree interfaces.
