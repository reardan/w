# Native Mermaid railroad diagrams

The native engine supports all four railroad headers from the pinned
[Mermaid 12.2.0 railroad syntax reference](https://github.com/mermaid-js/mermaid/blob/mermaid%4012.2.0/packages/mermaid/src/docs/syntax/railroad.md):
`railroad-beta`, `railroad-ebnf-beta`, `railroad-abnf-beta`, and
`railroad-peg-beta`. This is a bounded grammar subset, not full syntax parity.

The parser stores an owned grammar syntax tree in `mm_document.railroad`.
Terminals, references, sequences, alternatives, optional paths, repetitions,
ABNF numeric literals and PEG predicates retain distinct semantics. The
renderer draws rule entry/exit markers, rounded terminals, square references,
branch rails, optional bypasses and backwards repetition loops. PEG alternatives
are numbered in evaluation order. Predicates are explicitly labeled as
non-consuming. ABNF bounded repetition uses annotated loops, without expanding
the grammar or creating exponential numbers of boxes.

| Notation | Supported | Remaining syntax |
| --- | --- | --- |
| IR | All eight documented constructors: terminal, nonterminal, special, sequence, choice, optional, zeroOrMore, oneOrMore; nested and multiline constructors | Configuration and custom styling |
| EBNF | `=` / `::=`, single/double quoted terminals, references, adjacent/comma sequences, `|`, grouping, `?` / `*` / `+`, `[optional]`, `{repetition}`, `? special ?`, `/* */` and `(* *)` comments | Exception operator `A - B`, extended literal escape syntax |
| ABNF | `=`, references including hyphens, `/`, grouping, optional groups, prefix `*`, `1*`, `2*4`, exact counts, `%x` / `%d` / `%b` numeric values/ranges/sequences, line comments | Incremental `=/` rules, RFC 7405 explicit `%s` / `%i` strings, case-insensitive rule-name folding |
| PEG | `<-`, quoted terminals, references, ordered `/`, sequences, `?` / `*` / `+`, `&` and `!` predicates, wildcard `.`, grouping, `#` comments | Character classes and extended literal escapes |

All rules require a terminating semicolon. In ABNF it also begins the trailing
line comment; write each rule on its own line. The optional `title` statement
accepts a quoted or unquoted title. `%%` source comments work in every notation.
Quoted literals accept escaped matching quotes and backslashes; other escapes
are rejected. Rule references are not expanded and may refer to external/core
grammar rules. ABNF quoted strings are visibly marked case-insensitive.

Limits are 256 rules, 1024 expression nodes, 32 recursive parser levels, and
repeat bounds up to 1,000,000. Numeric ABNF values must fall in 0–0x10FFFF, with
ascending ranges. Empty diagrams, duplicate rule definitions, malformed
constructors, missing delimiters, excessive nesting and unsupported operators
produce source diagnostics and no partial preview. Source read/write/edit is
lossless even when a grammar is invalid.

The same display list drives SVG and the native desktop editor. There is no
Mermaid JavaScript or browser dependency. Paths are deterministic orthogonal
rails rather than the upstream curved layout. Theme parity, custom configuration,
advanced grammar syntax and interaction with rule references remain future work.

```sh
./wbuild wmermaid wmermaid_editor railroad_test railroad_64_test
bin/wmermaid svg examples/mermaid/railroad-ebnf.mmd bin/grammar.svg
bin/wmermaid_editor examples/mermaid/railroad.mmd
```

The four examples are `examples/mermaid/railroad{,-ebnf,-abnf,-peg}.mmd`.
Tests cover AST semantics, loop/bypass geometry, predicate and ordered-choice
labels, bounds, escaping, diagnostics, every byte-prefix truncation, and source
edit ownership on x86 and x64. Guard-allocator leak checks pass on both targets;
all four SVG examples are parsed as XML, and native preview is visually checked.
