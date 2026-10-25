# Native Mermaid railroad diagrams

The native engine supports all four railroad headers from the pinned
[Mermaid 12.2.0 railroad syntax reference](https://github.com/mermaid-js/mermaid/blob/mermaid%4012.2.0/packages/mermaid/src/docs/syntax/railroad.md):
`railroad-beta`, `railroad-ebnf-beta`, `railroad-abnf-beta`, and
`railroad-peg-beta`. This is a bounded grammar subset, not full syntax parity.

The parser stores an owned grammar syntax tree in `mm_document.railroad`.
Terminals, references, sequences, alternatives, optional paths, repetitions,
ABNF numeric literals and PEG predicates, character classes, and EBNF exceptions retain distinct semantics. The
renderer follows the upstream railroad renderer's geometry: `name =` rule rows
with 5px start/end markers, padded rounded terminals and square references,
10px horizontal and 8px vertical separation, and arcRadius-10 quarter-circle
rails: choices branch from the center line onto each centered alternative's
track, optional and zero-or-more paths add a bypass two radii above the body,
and one-or-more/zero-or-more paths loop back two radii below it. Arcs are
sampled into short segments so SVG and the native preview share one display
list. PEG alternatives are numbered in evaluation order. Predicates and EBNF
exceptions are labeled frames on the same rail. ABNF bounded repetition uses
annotated loops, without expanding the grammar or creating exponential numbers
of boxes.

| Notation | Supported | Remaining syntax |
| --- | --- | --- |
| IR | All eight documented constructors: terminal, nonterminal, special, sequence, choice, optional, zeroOrMore, oneOrMore; nested and multiline constructors; upstream string escapes | Configuration and custom styling |
| EBNF | `=` / `::=`, single/double quoted terminals, references, adjacent/comma sequences, `|`, grouping, `?` / `*` / `+`, `[optional]`, `{repetition}`, `? special ?`, `/* */` and `(* *)` comments, exception operator `A - B`, upstream string escapes | Configuration and custom styling |
| ABNF | `=`, references including hyphens, `/`, grouping, optional groups, prefix `*`, `1*`, `2*4`, exact counts, `%x` / `%d` / `%b` numeric values/ranges/sequences, line comments, incremental `=/` rules, RFC 7405 explicit `%s` / `%i` strings, case-insensitive rule-name folding, RFC 5234 escape-free double-quoted strings | Configuration and custom styling |
| PEG | `<-`, quoted terminals, references, ordered `/`, sequences, `?` / `*` / `+`, `&` and `!` predicates, wildcard `.`, grouping, `#` comments, character classes with ranges and escaped brackets/backslashes/`n`/`r`/`t`, upstream string escapes | Configuration and custom styling |

Rules end with a semicolon, as upstream requires, but the semicolon may be
omitted when the next rule head (`name =`, `name ::=`, `name =/`, `Name <-`)
starts a new line or the grammar ends; this is a strict superset, so every
grammar upstream accepts keeps its meaning, and it matches RFC 5234, where ABNF
rules end at the line. In ABNF a `;` also begins the trailing line comment. The
optional `title` statement accepts a quoted or unquoted title. `%%` source
comments work in every notation.

Quoted literals follow each notation's upstream escape set. IR, EBNF and PEG
strings (`"..."` or `'...'`) decode `\n`, `\r` and `\t` and take any other
escaped character literally (`\"`, `\'`, `\\`, `\x` is `x`); like upstream they
may span lines. Decoded control characters are displayed as their escapes so
the box stays legible. ABNF strings follow RFC 5234 and the upstream ABNF
grammar: double quotes only, no escapes, so a backslash is an ordinary
character (use `%x` values for a quote). Quoted titles decode the same way,
except that an ABNF title is taken verbatim.

Rule references are never inlined, as upstream draws them; recursive grammars
therefore render finitely. Each reference is resolved against the diagram's
rules (`mm_rail_expr.target`): in SVG a reference to a rule of the same diagram
is a link (`#railroad-rule-<name>`) to that rule's row, whose name carries the
matching `id`; references to external/core rules (such as ABNF `ALPHA`) stay
plain boxes. ABNF quoted strings are visibly marked case-insensitive unless prefixed with `%s`.
Incremental rules extend an earlier definition and fold rule/reference names to
lowercase. EBNF exceptions bind more tightly than concatenation and display both
the included and excluded expression in an explicitly labeled frame; they are
not rendered as alternatives. PEG character classes consume a single character;
empty classes, reversed ranges and unterminated escapes are diagnosed.

Limits are 256 rules, 1024 expression nodes, 32 recursive parser levels, and
repeat bounds up to 1,000,000. Numeric ABNF values must fall in 0–0x10FFFF, with
ascending ranges. Empty diagrams, duplicate rule definitions, malformed
constructors, missing delimiters, excessive nesting and unsupported operators
produce source diagnostics and no partial preview. Source read/write/edit is
lossless even when a grammar is invalid.

The same display list drives SVG and the native desktop editor. There is no
Mermaid JavaScript or browser dependency. Text widths come from the native text
metrics rather than browser measurement, so box widths differ slightly from
upstream. Theme parity, the `railroad` configuration block, custom styling and
in-editor navigation of rule references remain future work.

```sh
./wbuild wmermaid wmermaid_editor railroad_test railroad_64_test
bin/wmermaid svg examples/mermaid/railroad-ebnf.mmd bin/grammar.svg
bin/wmermaid_editor examples/mermaid/railroad.mmd
```

The examples are `examples/mermaid/railroad{,-ebnf,-abnf,-peg,-escapes}.mmd`.
Tests cover AST semantics, upstream arc/bypass/loop geometry, predicate and
ordered-choice labels, per-notation literal escapes, optional semicolons,
reference links, bounds, escaping, diagnostics, every byte-prefix truncation, and source
edit ownership on x86 and x64. Guard-allocator leak checks pass on both targets;
all four SVG examples are parsed as XML, and native preview is visually checked.
