# Explicit scripting mode and in-head noscript

The public `html_parse_with_scripting(data, length, scripting)` and
`html_parse_with_scripting_limits(data, length, scripting, limits)` APIs select
scripting disabled with zero and enabled with a nonzero flag. The existing
`html_parse`/`html_parse_with_limits` retain their legacy noscript interpretation
for compatibility. Browser document hosts should explicitly select enabled mode;
this parser change does not itself execute scripts. Fragment parsing retains its
existing explicit mode and now applies enabled rawtext to nested noscript too.

Enabled noscript consumes rawtext, preserving markup and references literally.
Disabled in-head noscript uses the frozen WHATWG allow/ignore/pop-and-reprocess
rules, with whitespace, comment and PI children and bounded void/raw metadata.
Mixed decoded character tokens keep their leading whitespace under noscript and
reprocess the remainder outside head. Split text nodes retain the enclosing
lexical token span; their decoded lengths and document ownership are independent.
All existing input/token/node/depth/attribute caps remain in effect. Native tests
cover source release, links, every truncated prefix, node/depth refusal, rawtext
isolation, enabled/disabled fragments, and the generic API's legacy behavior.

The exact HTML snapshot, algorithms, WPT revision and unchanged source hashes are
in `manifest.json`. A literal noscript source scan of all 62 tree fixture files
finds 38 related cases in seven files. All seven complete files are admitted:
553 cases and 1,070 requested scripting variants. The inventory keeps all 1,968
cases, marking 1,415 NOT_RUN. The scan is a discovery aid, never an exclusion rule.
Original data and license bytes are shared with the after-body profile where
already present; noscript01.dat and tests5.dat are copied unchanged.

Development execution: **441 PASS / 112 FAIL / 0 ERROR** cases, **846 PASS /
224 FAIL** variants. The complete `noscript01.dat` family passes all 18 cases.
Among the 38 directly related cases, only tests1.dat:111 fails; it depends on
foster parenting and implicit tbody insertion. Other retained failures include
tables, template content/placement, foreign content and formatting recovery.
The complete PI file is now **121 PASS / 3 FAIL**, with 241 passing and six failing
variants. PI cases 111, 120 and 124 still require table/template algorithms.
Original parse-error lists remain unverified; tree comparisons are not browser
WPT execution. No benchmark or complete HTML conformance claim is made.

```
./wbuild html_noscript_test html_noscript_upstream_test
python3 libs/extras/html/fragment_upstream.py bin/html_noscript_fixture --profile modern-noscript --report bin/html-noscript-strict.json
python3 libs/extras/html/fragment_upstream.py bin/html_noscript_fixture --profile modern-pi --report bin/html-pi-upstream.json
```

The registered noscript upstream target uses `--gate noscript-file`, which gates
all 18 unchanged noscript01 cases while retaining every result from the full
553-case affected inventory in its report. Both strict commands above return 1
for remaining failures; `--gate full-corpus` also rejects NOT_RUN. Eight registered
adapter negative contracts include complete missing-driver accounting and
manifest/inventory pin/hash validation. Reports freeze source, driver, adapter,
HEAD and UTC provenance before execution and reject mutation during execution.
