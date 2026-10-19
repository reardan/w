# Processing-instruction tokenizer and tree audit

The complete unchanged `processing-instructions.dat` at WPT
`6d4552a8b1057e42a180119d70273f563e53a264` contains 124 cases and 247 scripting
variants. Its source and original license are shared with the preceding
after-body profile, with exact path/hash admission in this profile's manifest.
The inventory retains all 62 files and 1,968 cases, marking 1,844 NOT_RUN here.
A literal `<?` source scan records 132 related cases across that whole inventory;
this is a discovery aid, not an exclusion rule or a conformance assertion.

The exact HTML snapshot and tokenizer/tree algorithm IDs are pinned in the
manifest. The native tokenizer implements processing-instruction open, target,
after-target, data and questionable states. It preserves ASCII target case,
validates target characters, converts invalid/disallowed targets into genuine
bogus comments including the initial `?`, discards incomplete valid instructions
at EOF, strips only a terminal `?`, and normalizes CRLF without expanding
character references. The PI data state's literal NUL survives with explicit
length. Rawtext, RCDATA and ordinary comment tokenization are unchanged.

`HTML_PROCESSING_INSTRUCTION = 7` is a leaf node. `name` owns the target;
`text` and `text_length` own data, including a non-null allocation for empty data.
Source/token buffers may be released independently. Nodes remain in the owning
document allocation list until teardown. Shared input/token/node/depth caps apply.
PI insertion covers supported document/fragment contexts, including document
prefix, before/in/after head, ordinary body and after-body/final document modes.
Leading PI nodes can precede the doctype and HTML element; consumers must locate
HTML by kind/name. Existing initial/comment/head and other insertion-mode gaps
remain independent mandatory work.

The full development result is **120 PASS / 4 FAIL / 0 ERROR** (240 passing and
7 failing variants). No dependency case is skipped:

| Original case | Remaining dependency |
| --- | --- |
| 111 | Table insertion must create an implicit tbody for tr |
| 120 | Template child nodes need a real template-content DocumentFragment |
| 123 | Scripting-off in-head noscript insertion mode and document scripting flag |
| 124 | Template head placement plus real template-content ownership |

The serializer does not invent a `content` marker for ordinary template children.
The strict selected gate remains nonzero until these tree algorithms land.
Constructor, full CharacterData mutation/coercion, observers, and general
DOM/Web IDL exposure are separate integration work, not established by this audit.

```
./wbuild html_processing_instruction_test html_after_body_fixture
python3 libs/extras/html/fragment_upstream.py bin/html_after_body_fixture --profile modern-pi --report bin/html-pi-upstream.json
```

The second command returns 1 for the current four failures. `--gate full-corpus`
also rejects NOT_RUN. The registered historical upstream target runs all adapter
negative contracts, including full 124-case/247-variant preservation on a missing
binary and cross-pin inventory rejection. Reports freeze exact HEADs, hashes and
UTC before execution and reject changed provenance. These are native tree-output
comparisons of original WPT resource data, not browser WPT execution; original
parse-error lists remain unverified. No performance result is asserted.
