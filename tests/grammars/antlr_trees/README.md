# ANTLR parse-tree differential

`./wbuild antlr_tree_differential_test` (`python3 tests/antlr_tree_differential.py`)
checks that W's prediction parsers build the **same parse tree as ANTLR 4.13.2**,
not only the same accept/reject verdict. Each case translates its grammar with
`--exact-lexer --prediction`, generates and compiles a W parser, parses every
pinned input and compares the result with a committed ANTLR observation.

## What is compared

ANTLR's side is `tests/grammars/antlr_left_recursion/TreeOracle.java`: for each
input it records whether parsing produced no syntax error and consumed the
input to EOF, and for accepted inputs the complete tree as
`{"rule", "context", "children"}` nodes and `{"token": text}` leaves. The context
is ANTLR's generated context class (`<Label>Context`, or `<Rule>Context` for an
unlabeled alternative), so the selected alternative of every node is compared.

W's side is [`canonical_tree.w`](../../../libs/extras/grammars/antlr_to_pg/canonical_tree.w).
It projects the normalized W AST onto that shape using `antlr_tree:*` alternative
metadata that the translator now emits in prediction mode:

- `antlr_tree:context` opens an original rule context (source alternatives and
  copied primaries),
- `antlr_tree:fold` marks a lowered left-recursive tail; it re-parents the
  preceding value as its first child, reproducing ANTLR's left-nested tree,
- `antlr_tree:list` marks a list rule whose single base was inlined,
- untagged nodes (lifted groups, precedence tiers, the lowered rule's entry)
  are spliced into their parent.

Only default-channel tokens appear, and a named EOF token is spelled `<EOF>`,
as in ANTLR. Because grouping, associativity, precedence, the chosen
alternative at every ambiguity and every token position are part of the tree,
this is a semantic-equivalence check for the pinned inputs, not a verdict check.

## Cases

- The nine runnable Wave 0 left-recursion fixtures and their 33 inputs, reusing
  the grammars in `../antlr_left_recursion/` (snapshots agree with that
  directory's reference trees).
- `Shapes.g4`: suffix and binary operators interleaved (ANTLR tries binary
  decisions first), adjacent operands (`expr expr`), a right-associative
  operator, a ternary whose middle operand is an ordinary call, prefixes at two
  binding levels, and an undelimited optional owner call (`'return' expr?`).
- `NullableList.g4`: an empty primary with consuming suffix tails and an
  optional separator.
- Unmodified pinned upstream grammars from `../antlr_left_recursion/upstream/`
  whose left recursion is now lowered: `tl` (Unicode operators, empty
  proposition), `semver` (optional separators, labeled operands), `cayenne`
  (application by adjacency), `sapf` (postfix RPN with an ordinary middle
  operand), `peoplecode` (nested `<assoc=right>` options that ANTLR ignores) and
  `z`, whose `expression` precedence alternatives carry the host predicate
  `{ZSupport.isLeftAssociative(_input)}?`. W lowers that predicate as true; the
  oracle compiles `ZSupport.java` (a case's `host_support`, hashed like the
  grammars), which answers true as grammars-v4's support class does without its
  operator pre-pass. Inputs stay on one line because the lexer's `shouldNL`
  predicate decides which newlines are tokens.
  Their inputs were written for this suite.

Every grammar and input byte is pinned in `manifest.json`; `snapshots.json`
holds the ANTLR observations. A case may list `known_differences` (input id and
explanation); an unexpected match then fails until the entry is removed.
There are none.

## Regenerating the reference

Snapshots were produced once with the checksum-pinned jar
(`eae2dfa1…df4d76`, Maven Central `org.antlr:antlr4:4.13.2:complete`) and
OpenJDK 17.0.20.1. Ordinary runs never contact Java. To verify or refresh:

```sh
env -u JAVA_TOOL_OPTIONS PATH=/usr/lib/jvm/java-17-openjdk-amd64/bin:$PATH \
  python3 tests/antlr_tree_differential.py --jar /path/antlr4-4.13.2-complete.jar
# after a reviewed manifest change:
  ... --jar /path/antlr4-4.13.2-complete.jar --refresh-snapshots
```

`--jar` reruns ANTLR for every input and fails when it differs from the
snapshot. `--refresh-snapshots` rewrites only the observations of the selected
cases and drops snapshots for inputs no longer in the manifest.

## Corpus examples (live only)

`--corpus GV4 --sweep-case NAME ... --jar JAR` compares the trees for the pinned
grammars-v4 example files that the coverage sweep selects for those cases
(`sweep_baseline.json`). Nothing is committed from these runs; the corpus is not
vendored. The oracle also compiles the grammar directory's `Java/` host support
(base classes and predicate helpers), generating the directory's other grammars
when that code needs them (Z's operator parser), and a case pinned with no
entry rule starts at the first parser rule, as the sweep does. A rejected input
logs W's diagnostics in its `.w.log`, which distinguishes a syntax error from
an exhausted prediction budget. Measured on the 15 newly lowered grammars whose generated Java
compiles without host support (alef, alloy, cayenne, clu, elixir, gql,
hypertalk, peoplecode, plucid, refal, sapf, semver, spl, tl, vb6): **73 of 75
example files produce identical trees or identical rejections**. The other two
(elixir `block.ex`, hypertalk `Script.txt`) exceed W's one-million-step
prediction budget, an explicit resource failure rather than a different tree.
