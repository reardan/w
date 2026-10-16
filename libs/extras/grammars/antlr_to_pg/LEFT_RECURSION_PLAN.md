# ANTLR left recursion implementation plan

Extend imported-parser prediction to handle the remaining supported ANTLR
left-recursion shapes, using three parallel worker agents and one integrator.
Implement an explicit precedence plan and validate its progress before publishing
normalized rules. Measure grammar compilation and runtime compatibility separately.

Status: planned, not implemented. This follows [PR #708](https://github.com/reardan/w/pull/708)
and the [compatibility capability ledger](COMPATIBILITY_PLAN.md). The planning PR
is stacked on #708 while that implementation remains open. Implementation branches
must start from the accepted combined base, not an older parallel checkout.

## Baseline and outcome

The clean implementation measurement is `b1887a858969ba341fb1449793dfd69ed4113677`,
published by `61dbc338`, against corpus
`89fd36482e8cb68a4e55df021a8adbc7541b52f2` and the same 291 pinned roots.
Exact mode means `--exact-lexer --prediction`.

| Configuration | Translate | Generate | W compile | W compiler strict |
| --- | ---: | ---: | ---: | ---: |
| Default permissive | 218 | 214 | 214 | 214 |
| Default translator strict | 10 | 10 | 10 | 10 |
| Stateful permissive | 218 | 214 | 214 | 214 |
| Stateful translator strict | 28 | 28 | 28 | 28 |
| Exact permissive | 267 | 267 | 267 | 267 |
| Exact translator strict | 218 | 218 | 218 | 218 |

Twenty-one grammars have 25 rules reporting `AT_LEFT_RECURSION`. These are
candidates for this work, not 21 proven instances of indirect recursion. Source
inspection finds direct adjacency, optional separators, grouped calls, and
nullable bases that the existing normalizer declines. A generic audit code does
not establish which condition caused the decline. An initial nullable-prefix graph
probe found no multi-rule strongly connected components in these 21 grammars.
Wave 0 must reproduce that observation with maintained diagnostic evidence;
genuine mutual recursion remains a negative fixture, not an assumed missing feature.

Planning triage generated all 21 original grammar roots successfully with pinned
ANTLR 4.13.2 and Java 17, without changing their input hashes. This establishes a
tool-generation gap, not Java compilation or parser runtime equivalence. Thirteen
currently report only left-recursion findings; eight also report other semantic
findings. Preserve both facts in the maintained Wave 0 inventory.

The target is to account for all 25 rules and implement every shape that passes
the reference and safety gates below. Resolving all 21 grammar failures would
raise exact compilation to 288/291 if no additional blockers emerge. That is a
conditional ceiling, not an acceptance threshold. AspectJ/TrapC dependencies and
SHARC empty visible lexer tokens are outside this increment. Strict acceptance
may remain blocked by host actions, predicates, declarations, or other findings.

Preserve the original roots, bytes, hashes, and historical observations in
[sweep_baseline.json](sweep_baseline.json). The current measured findings are in
[sweep_remaining.json](sweep_remaining.json); the denominator must not shrink when
a newly supported rule exposes another failure.

## Pinned rule inventory

| Grammar | Refused rules |
| --- | --- |
| alef | `setlist`, `zelist` |
| alloy | `expr` |
| awk | `non_unary_expr`, `non_unary_print_expr` |
| cayenne | `expr` |
| clu | `primary` |
| eiffel | `expression` |
| elixir | `expression` |
| gql | `valueType` |
| gvpr | `expr` |
| hypertalk | `chunk` |
| kirikiri-tjs | `expression` |
| peoplecode | `expr` |
| plucid | `expression` |
| refal | `program` |
| rust | `expression` |
| sapf | `expression` |
| semver | `build`, `preRelease` |
| spl | `expression` |
| tl | `proposition` |
| vb6 | `valueStmt` |
| z | `expression`, `predicate` |

## Semantics and implementation contracts

Use ANTLR 4.13.2 and Java 17 as the reference. Verify and record that both `java`
and `javac` resolve to major 17; setting `JAVA_HOME` without checking `PATH` is
insufficient. ANTLR classifies direct-recursive
alternatives as binary, prefix, suffix, or other, and rewrites them with precedence
constraints. Preserve the distinction between a constrained operand and an
ordinary recursive call. The placement of a reference inside an optional/grouped
term is significant; assigning the same precedence to every owner reference is
not a valid shortcut. Verify option placement and warnings against the reference,
especially PeopleCode's nested associativity options.

Primary references:

- [Documented left recursion transformation](https://github.com/antlr/antlr4/blob/4.13.2/doc/left-recursion.md).
- [Alternative classification walker](https://github.com/antlr/antlr4/blob/4.13.2/tool/src/org/antlr/v4/parse/LeftRecursiveRuleWalker.g).
- [Precedence and reference rewriting](https://github.com/antlr/antlr4/blob/4.13.2/tool/src/org/antlr/v4/analysis/LeftRecursiveRuleAnalyzer.java).
- [Rule transformation and ordinary entry references](https://github.com/antlr/antlr4/blob/4.13.2/tool/src/org/antlr/v4/analysis/LeftRecursiveRuleTransformer.java).

In prediction mode, classify all recursive rules through the explicit plan,
including previously accepted rules. Reuse an existing lowering only where its
equivalence to the plan is established; preserve existing AST layouts where that
is compatible with the verified semantics. Any discovered mismatch needs a
separate executable witness and reviewed correction. Native ordered-choice parsers,
default/stateful lowering, public complete-input prediction entries, source
reconstruction, and sticky resource errors retain their contracts.

### Precedence plan

Build an immutable analysis result before allocating public helper names or
changing `rule.alts`. A plan contains the owning rule; source alternatives and
order; classification; associativity; binding levels; occurrence paths through
nested groups/modifiers; the selected constrained recursive occurrence; ordinary
full-precedence occurrences; and source/label metadata. Represent a primary's
binding explicitly rather than guessing from delimiter spellings.

Track both source identity and transformed decision priority. Verify the pinned
walker's binary, prefix, suffix, then other classification; precedence is derived
from the total original alternative count and index: `p = N - alt + 1`, using
one-based alternatives. Binary right operands use `p + 1` for left association
and `p` for right association; prefix operands use `p`; ordinary recursive calls
use `0`. A trailing mandatory direct self-reference differs from one inside a
group or optional term. Check generated
reference output when binary and suffix alternatives compete, rather than assuming
all transformed decisions preserve outer source order. Record which recursive
occurrence the analyzer actually rewrites, including nested rule-reference order.

Stage the lowered rules in a private candidate grammar. Validate progress,
productivity, helper-name collisions, metadata, and nullable-prefix cycles across
the combined candidate graph before committing it. Interdependent rule plans need
a common validation boundary. Refusal leaves the original rule graph and all
requested outputs intact. Helper-count and analysis-work exhaustion produce an
explicit refusal, not a partially published grammar.

Retain alternative labels, element/list labels, left-operand metadata, source
coordinates, and original alternative identity. Generated helpers must not pretend
to be ANTLR context classes. Preserve delayed AST replay and the documented W AST
folding contract.

### Progress and nullability

Compute fixed-point parser nullability and productivity, and nullable-prefix call
edges, independently of declaration order. Report a concrete cycle path for any
remaining strongly connected recursive component. Parser progress is measured in
consumed tokens, not source bytes: named EOF tokens may have zero-byte spans.
Distinguish a consumable named token from terminal EOF assertions; an EOF-only
tail is not automatically a progress proof. Test actual token-cursor advancement.

Check the lowered grammar, not only the original prefix. A binary operator does
not have to consume before its right operand if that operand is independently
proven to consume. An operand that can be empty cannot supply that proof. Permit
a nullable primary only when the resulting calls and loop tails still satisfy
progress and productivity checks. Reject nullable repetitions and stationary
cycles; do not use the runtime work limit as permission to admit them.

Do not globally weaken `at_expression_base_direct`, `at_precedence_prefix_safe`,
or the final left-path audit. Replace a rejected condition only with a specific
proof over the proposed lowering. The existing final audit and downstream
`pg_grammar_safety_check` remain independent backstops. Bound generated graph size before allocation; measure the
downstream dense graph analysis as helpers grow. Use sparse cycle analysis if
measurements show that existing graph costs prevent safe expansion.

### Host semantics and residual recursion

Track structural lowering and host-site findings independently. Preserve source
sites through every clone so a permissive compilation cannot erase a strict
refusal. No new predicate execution, superclass adapter, or speculative action
support is introduced here.

If a true indirect/hidden cycle remains, first minimize it and record reference
behavior. A separate design gate is required before introducing runtime fixed-point
recognition, memoization, or generalized parsing: it must specify precedence,
ambiguity selection, nullable derivations, AST construction, and resource limits.
This plan does not authorize bypassing a cycle diagnostic or silently selecting
a different parse. A residual unsupported case remains in the measured ledger.

## Parallel agent ownership

There are four simultaneous slots: one integrator and three workers. Use isolated
worktrees. Shared files have one owner; workers submit narrow requested changes
to the integrator rather than editing them concurrently.

| Owner | Work and exclusive file ownership | Handoff |
| --- | --- | --- |
| Integrator | CLI/dispatch, `types.w`, `normalize.w`, `audit.w`, existing shared metadata and generator/runtime files, documentation, aggregate baselines | Freeze interfaces, apply shared changes, integrate commits, run combined validation |
| Agent A lowering | `normalize_prediction.w`; new precedence-plan/lowering modules; dedicated lowering unit fixtures | Plan descriptors, deterministic candidate generation, supported-shape evidence, atomic refusal checks |
| Agent B safety | New parser progress/cycle-analysis modules; dedicated nullability/progress unit fixtures | Read-only candidate validator, nullable/productive sets, cycle witnesses, work-limit behavior |
| Agent C oracle | New pinned left-recursion fixture directory and manifest, oracle drivers, runtime witnesses, measurement reports | Independent ANTLR observations, per-rule classification, performance and six-configuration comparisons |

Existing shared differential runner/manifest edits belong to C after an explicit
handoff; A/B request fixtures there. Existing shared W test files remain integrator
owned. Each agent can edit its own new unit test sources, but the integrator owns
any shared target wiring. The integrator transfers ownership explicitly if an
interface change requires it; no simultaneous edits to a shared module.

Each worker reports its commit, files changed, checks run, supported/refused
shapes, unresolved questions, and exact integration dependencies. Do not promote
coverage using a worker's partial checkout. Freeze the combined source during
bootstrap and measurement.

## Execution waves and gates

### Wave 0 Freeze evidence and interfaces

Run A's alternative-classification inventory, B's call-graph/nullability inventory,
and C's reference extraction in parallel. C creates a manifest covering all 21
grammars and 25 rules, reusing upstream hashes and preserving licenses.

Every entry records source location/alternative, normalization refusal reason,
reference generation outcome and warnings, generated transformation details,
remaining host findings, witness
entry rule, expected lowering class, and runtime evidence status. Distinguish an
observed behavior from an inferred cause. Add stable reason details under the
existing `AT_LEFT_RECURSION` finding rather than forcing consumers to parse text.

The integrator freezes the plan/candidate/validation interfaces after reconciling
these inventories. Gate: all 25 rules accounted for, unchanged six-configuration
baseline, no acceptance relaxations, and a minimized fixture for each identified
shape. Reference generation is not counted as reference runtime evidence.

### Wave 1 Nonnullable direct recursion

A implements explicit classification and lowering. B validates lowered candidates
and consuming operands. C supplies reference observations and upstream probes
independently of the W implementation.

Initial work groups overlap; the inventory determines final order:

| Shape | Candidate witnesses | Required checks |
| --- | --- | --- |
| Adjacent operands and optional separators | Cayenne, HyperTalk, AWK, SemVer, Alloy | Association and mixed precedence; omitted separator; operand progress |
| Grouped, optional, repeated owner references | Rust, GVPR, GQL, VB6, Elixir | Correct constrained occurrence; full-precedence calls; labels and modifiers |
| Guarded recursion inside primaries | Eiffel, Plucid, SPL, Refal, Kirikiri-TJS | Consuming guards beyond paired delimiters; prefix versus other classification |
| Complex suffixes and option placement | CLU, SAPF, PeopleCode, Z | Remaining recursive operands; source ordering; reference warnings; preserved host findings |

Integrate the simplest proven nonnullable shapes first. Gate each shape on
reference recognition and normalized grouping/label evidence, positive and negative
inputs, progress checks, atomic refusal, and bounded resource tests. A grouping
transformation must not change the original outer alternative's precedence merely
because it expands into several helper alternatives.

### Wave 2 Nullable primaries

A extends primary lowering; B owns proofs for empty bases and consuming recursive
tails; C tests Alef and TL plus minimized adversarial grammars. Cover empty input,
empty operands where the reference allows them, separators alone, nested empty
forms, competing nullable alternatives, and invalid truncated continuations.

Gate: preserve the reference language and selected derivation while rejecting
stationary call cycles, nullable loops, and nonproductive rules. Resource failures
remain explicit and sticky across backtracking. If the general nullable case
cannot pass this gate, retain a narrower diagnosed subset rather than weakening
checks for the entire category.

### Wave 3 Residual review and corpus promotion

C reruns every original case, including cases whose first blocker changed. A/B
minimize residual failures and distinguish unsupported structure, genuine cycles,
host-semantic requirements, and source defects. The integrator decides whether a
residual cycle needs the separate architecture gate described above.

Publish exact compile, translator-strict, and W compiler-strict outcomes
independently. Record every original rule as supported with evidence or explicitly
refused with its current cause. Update baselines only after the unchanged combined
revision passes all gates. No predicted count becomes an expected-pass entry.

## Validation and performance gates

For each new shape, compare the pinned ANTLR oracle with W on acceptance,
complete consumption, precedence/association, selected source alternatives,
labels/list-label order, spans, and lossless source reconstruction where applicable.
Add a canonical source-expression/operand-tree projection against Java contexts;
token streams, selected spans, or arithmetic values alone cannot establish correct
association. Compare supported normalized grouping, not raw helper-tree identity. Keep valid
ANTLR inputs valid in the ledger when W differs; never turn a mismatch into a
negative-language fixture.

Use both minimal grammars and unmodified upstreams. A host-dependent upstream
runtime test must pin the necessary reference support files, or record runtime
coverage as blocked and keep minimal-fixture evidence separately attributed.
Actions or predicates must not be deleted from a purported upstream runtime test.

Include malformed/truncated inputs, helper-name collisions, nested modifiers,
labels inside groups, source-rule reorderings, already-supported shapes, and
atomic output preservation on failure. Explicit negative tests cover direct and
mutual stationary cycles, zero-progress nullable recursion/repetition, nonproductive bases,
analysis budget exhaustion, and runtime exhaustion after a viable earlier branch.

Record analysis time, helper count, generated size, prediction steps, peak pending
branches, frames/events, and peak memory on geometrically increasing inputs.
Freeze numeric per-fixture bounds after the initial reference/prototype measurements
and before promoting the shape. Keep the existing one-million-step prediction
default and 90-second corpus-stage timeout; increasing either is not a fix for a
regression. Any needed new limit has an independent review and exhaustion test.

Implementation check sequence:

1. After W edits, run `bin/wv2 check --json` on the appropriate root; fix warnings.
   Preserve pinned-seed syntax compatibility in compiler-imported modules.
2. Select focused targets with `bin/wtest changed`; use `bin/wtest archs FILE --check`
   for applicable multi-architecture roots. Exercise generated parsers on x86/x64
   and run required bootstrap/fixpoint checks.
3. Run the offline and live Java 17 / ANTLR 4.13.2 differential suites, new recursion
   witnesses, and existing lexer endpoint tests. Oracle snapshots require reviewed
   reference evidence; ordinary test runs cannot rewrite them.
4. Run `env -u NO_COLOR ./wbuild tests` on the frozen combined source. Apply changed
   compiler-line coverage requirements if compiler-tree files are touched.
5. Run the complete pinned six-configuration sweep. Preserve every reviewed
   per-case baseline, all 267 exact compile successes, and all 218 exact-strict
   successes. All original 212 compile cases must remain warning-free in default
   mode, and all 58 historical stateful-strict cases must remain exact-strict
   successes (the current stateful-strict count is 28). Preserve the five reviewed
   strict-reclassification witnesses. Keep the existing 24-family /
   170-input differential suite passing. Infrastructure failures are failures,
   not compatibility refusals.
6. Validate hashes, compare original and new outcomes, and publish provenance and
   remaining findings. Historical passes stay visible; any necessary correction
   requires a separately reviewed executable witness.

## Delivery and completion

Deliver three implementation PRs in order:

1. Diagnostics, the 25-rule inventory, independent reference fixtures, and the
   precedence/progress interfaces. No semantic acceptance changes.
2. Nonnullable direct-recursion support, source metadata preservation, safety
   checks, measured performance bounds, and independently verified promotions.
3. Nullable-base support, residual classification, final corpus/runtime evidence,
   and strengthened baselines. Split a generalized-recursion proposal out if the
   separate architecture gate is actually needed.

Completion means every inventoried rule has an evidenced implementation or a
specific remaining refusal, all eligible new shapes pass their reference and
resource gates, historical per-case expectations remain protected, and the combined
suite is green. It does not mean full ANTLR conformance or 21 automatic strict
promotions. The final report must distinguish implementation gaps from unexecuted
upstream runtime cases and from unrelated host-semantic gaps.
