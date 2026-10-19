# Modern select parser foundation

This inventory is separate from the historical html5lib inventory one directory
above. It pins WPT `6d4552a8b1057e42a180119d70273f563e53a264` and every `.dat` file
under `html/syntax/parsing/resources`: 62 files and 1,968 cases. The unchanged
`tests_innerHTML_1.dat` file is admitted in full (81 cases). The other 1,887 cases
remain `NOT_RUN`; this inventory does not establish full WPT applicability.
The original WPT license accompanies the fixture. The manifest records hashes.

The normative target is the [frozen HTML specification](https://html.spec.whatwg.org/commit-snapshots/1ea5faabf97bb6735dadd7919425cffce0c75dba/),
whose original retrieved content hash is recorded in the manifest. Relevant
algorithm sections are `parsing-main-inbody`, `parsing-html-fragments`,
`reset-the-insertion-mode-appropriately`, `generate-implied-end-tags` and
`has-an-element-in-scope`. That snapshot has no `in select` insertion mode.

The native foundation implements the explicit select fragment checks for
`select` and `input` start tags; ordinary in-body select/option/optgroup rules;
select closure through elements in scope; implied option/optgroup closure;
`hr` implied end tags within a select; nested select recovery; and input-induced
select closure. A fragment context is not placed on the stack of open elements.
Consequently, option/optgroup and hr behavior can differ between a select fragment
and a select element within a document. `keygen` retains its parser void-element
behavior, and textarea uses the existing RCDATA tokenizer.

Every input and expected tree in the four select-context cases (75–78) is
byte-identical to the historical pinned html5lib file. No historical exclusion,
obsolete-failure waiver, or expected-output rewrite is used. The modern resource
inventory also records a derived select/option/optgroup breakdown: 100 cases in
17 complete files containing 955 cases. Those other files remain unrun.

The WPT script file
`html/semantics/forms/the-select-element/customizable-select/select-parsing.html`
contains 17 declared subtests, and `select-input-parsing.tentative.html` contains
four. They remain **NOT_RUN as browser WPT tests**: native tree fixture results
are not a substitute for their scripts, Web IDL, DOM methods or harness.
The tentative file's first two cases allow input within select, while the frozen
normative algorithm closes a select in scope on input. That disagreement remains
visible; it is not permission to change normative behavior or hide tentative
failures. Native regression tests assert the frozen algorithm.

Run the bounded native profile with:

```
./wbuild html_select_test html_select_upstream_test
```

The upstream target explicitly uses `--profile modern-select --gate select-context`.
It requires all four select-context cases to pass in both scripting modes while
reporting all 81 cases and 162 mode variants. The initial measured full-file
result is 12 passing cases, two failures (HTML-context frameset and after-body
comment placement), and 67 unsupported contexts. All other corpus cases remain
unrun. The separate `--gate selected` command requires the complete admitted file
to pass and currently fails. `--gate full-corpus` additionally fails on any
`NOT_RUN` corpus cases. Neither profile is a complete standards gate.

Parse-error equivalence, active formatting reconstruction/adoption agency,
foreign namespaces/integration points, table/template/frameset modes, parser
suspension and document.write remain mandatory work. Fragment creation remains
native and owned; no Win innerHTML or script execution path is exposed here.
