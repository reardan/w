# HTML document foundation

`import libs.extras.html.html` provides a bounded, explicit-length tokenizer and
an owned static document tree for consumers such as Win. It does not depend on a
DOM, renderer, CSS library, or JavaScript runtime. This is an initial HTML subset,
not a claim of WHATWG parser conformance. The maintained lexical contract is
[`html.tokens`](../../libs/extras/html/html.tokens); implementation and fixtures
are hand maintained together, with no downloaded grammar or generation step.

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

Data/RCDATA and attribute values decode `amp`, `lt`, `gt`, `quot`, `apos`, `nbsp`,
and decimal/hex numeric references **with semicolons**. Unknown references remain
literal. Numeric NUL, out-of-range scalars, and surrogate values become U+FFFD.
Text and attribute NUL bytes also become U+FFFD with diagnostics. CR and CRLF
become LF. `title`/`textarea` select RCDATA; `style`, `xmp`, `iframe`, `noembed`,
`noframes`, and `script` select raw text. Their matching, case-insensitive end tag
requires a following space, `/`, or `>`; apparent other markup remains text.

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

Not implemented: full named entity tables and legacy missing-semicolon rules,
numeric-reference Windows-1252 remapping, script escaped/double-escaped states,
full comment/doctype state machines and quirks modes, `plaintext`, `noscript`
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
limits. `examples/web/html_document.w` demonstrates an external consumer using
only the public parse/free and linked-tree interfaces.
