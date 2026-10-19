# After-body tree-construction audit

This profile inventories every `.dat` file under
`html/syntax/parsing/resources` at WPT
`6d4552a8b1057e42a180119d70273f563e53a264`. The 135 source cases containing a
case-insensitive `</body` or `</html` spelling followed by whitespace, `/` or `>`
identify 22 affected files. Every case in every affected file is admitted:
1,308 cases and 2,600 scripting variants. The remaining 660 cases stay NOT_RUN
in the full 1,968-case denominator. The textual inventory intentionally includes
rawtext, malformed, foreign, table, template and frameset cases. No failure is
removed because its earlier insertion mode is unimplemented.

Files are copied byte for byte from that pinned WPT archive. `manifest.json`
records their original paths and SHA-256 hashes; `inventory.json` records every
file, count, derived source-case index and selection disposition. The original
WPT license accompanies them. This is a native comparison of WPT resource data,
not execution of browser WPT scripts. Upstream error lists are retained but not
compared. The document parser has no scripting flag yet: both requested variants
are retained and their divergences remain failures.

Normative rules come from the frozen HTML snapshot
`1ea5faabf97bb6735dadd7919425cffce0c75dba`, whose content hash and exact algorithm
IDs are in the manifest. The implementation adds after-body and after-after-body
comment placement, whitespace and ordinary-token recovery, scoped body/html
end tags without popping open elements, HTML-fragment end-tag handling, and
bounded merging of missing document-element attributes. It preserves existing
attribute values and list order; the union cap is checked before ownership moves.
The tokenizer's processing-instruction token branch is still missing, so this
is not complete coverage of either current insertion mode. The existing initial,
head, in-body, frameset, formatting, table, template, foreign-content, doctype,
namespace and scripting gaps remain mandatory.

Run the registered native regression and strict upstream audit:

```
./wbuild html_after_body_test html_after_body_fixture
python3 libs/extras/html/fragment_upstream.py bin/html_after_body_fixture --profile modern-after-body --report bin/html-after-body-upstream.json
```

The adapter defaults to the strict selected gate and returns 1 while any selected
case fails or is unsupported. `--gate full-corpus` additionally rejects NOT_RUN.
Neither gate converts this foundation into a passing full standards suite.
The adapter's negative checks run through the registered
`html_fragment_upstream_test` target and preserve all 1,308 cases when the binary
is missing. Each fresh report freezes exact app/W HEADs, parser/driver/adapter
hashes, input hashes and UTC before execution, then rejects changed provenance.
The native fixture accepts reversible `--hex` transport for source containing
NUL; decoded bytes and explicit length enter the same native parser. It does not
rewrite source or expected trees.

Initial development audit after this implementation: 494 PASS, 733 FAIL,
81 UNSUPPORTED, zero ERROR/TIMEOUT, plus 660 NOT_RUN; variants: 987 PASS,
1,451 FAIL, 162 UNSUPPORTED. These are tree-comparison outcomes, not a browser
conformance percentage. Fresh committed evidence is supplied separately to the
coordinator. The historical html5lib profile remains separate (61 selected cases,
122 variants); the modern-select profile remains separate (81 selected cases).
