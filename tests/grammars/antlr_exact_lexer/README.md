# Exact continuation lexer fixtures

`--exact-lexer` opts into a continuation-preserving, prioritized lexer VM and
implies `--stateful`. It does not change native `.pg` choice semantics or make
unmapped predicates/actions exact. The initial supported grammar subset includes
Unicode scalar sets, properties, complements, literals, wildcard,
sequences, alternatives, optional/repeated atoms, nongreedy decisions, and
productive lexer rule/fragment calls. Unicode escape/range/property lowering and grammar/rule case options use pinned
ANTLR/Java 17 data; see `tools/antlr_unicode/README.md`. Rule-level case options
apply only to lexer rules; parser-rule options remain unsupported. Implicit case-insensitive
parser literals still require explicit token rules. Malformed/unknown properties
and unsupported host code remain strict failures.

`Exact.g4` and `tests/antlr_exact_lexer_test.w` cover delimiter continuation,
overlapping repetition, productive nested calls, greedy/nongreedy priority,
source-order choice after nongreedy decisions, scalar input, and resource limits.
The positive endpoint assertions were checked against ANTLR 4.13.2's generated
Java lexer (jar SHA-256
`eae2dfa119a64327444672aff63e9ec35a20180dc5b8090b7a6ab85125df4d76`).

The VM follows ordered epsilon closure and retains greedy configurations after
an acceptance; lower-priority configurations that crossed a nongreedy decision
are pruned. This is stronger than selecting a fragment's longest endpoint.
A recursive call stores an interned return context, so its caller's remaining
input participates in matching. Nullable-prefix recursion remains rejected by
the translator's structural audit. Nonproductive public token rules are refused.
Nonproductive fragments retain their actual recursive transitions: optional calls
can appear inside productive rules, and a failed call must preserve how far ANTLR
inspected input during invalid-token recovery. No accepting base case is invented.
Such calls remain subject to the same explicit resource limits.

The bytecode consists of immutable six-field little-endian records, independent
of target word size. Range transitions consume Unicode scalar values; reported
lengths remain byte lengths. Programs are trusted compiler output. Matchers
return positive lengths, `-2` for resource exhaustion, `-3` for invalid UTF-8,
`-4` for successful zero-width matches, and `-4 - failure_length` for a
failed match that inspected input. `0` is a no-match without inspected input. The generated stateful
provider must propagate these statuses with guarded progress enabled.

`at_lex_execute` additionally reports failure length, steps, peak configurations and interned
stack count. Limits are one million closure visits per match, 32,767 states,
16,384 interned stacks and 512 call depth. Exhaustion is an explicit error, not
a grammar rejection. The long-input fixture proves linear closure growth for a
simple regular repetition; it is not a claim that recursive/ambiguous grammars
have linear complexity. Each execution frees all temporary configurations and
contexts, with no global cache or speculative command execution. Large Unicode
sets use a single consuming configuration with binary-searched intervals.

The input domain is valid UTF-8 without embedded NUL, matching the provider's
NUL-terminated matcher ABI. Embedded NUL and invalid encodings are explicit
input errors. Escaped NUL literals, unpaired surrogate literals and out-of-range
escapes are strict translation failures, never silently truncated strings.
Scalar ranges/properties may contain U+0000 mathematically, but no input in the
provider's supported domain contains it.

The optional exhaustive endpoint gate compares 7,104 bounded strings, including
invalid/truncated inputs, against a generated ANTLR lexer rule in isolation:

```sh
./wbuild antlr_to_pg
python3 tests/grammars/antlr_exact_lexer/differential.py \
  --antlr-jar /path/to/antlr-4.13.2-complete.jar \
  --java-home /usr/lib/jvm/java-17-openjdk-amd64
```

`bin/exact_endpoint_oracle/results.json` records tool provenance, the complete
case denominator, elapsed time, and any counterexamples. This tests individual
match endpoints; whole-lexer priority/recovery and parser compatibility are
separate conformance gates.
