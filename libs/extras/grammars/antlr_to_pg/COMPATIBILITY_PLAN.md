# ANTLR compatibility implementation plan

Implement the remaining grammar coverage work through three parallel worker
agents and one integrator. Improve recognition, lexer behavior, and the defined
W AST contract while measuring compilation and semantic compatibility separately.
Use an explicit imported-ANTLR prediction mode so existing native `.pg` grammars
retain their ordered-choice behavior.

This plan follows merged PRs #689, #690, and #692. It replaces the earlier
increment plans as the forward work plan; their implementation histories remain
unchanged. The architecture prototypes below are required gates before broad
parser or lexer acceptance is enabled. Implementation is in progress; final measurements and remaining limitations will
be recorded alongside the implementation before completion.

## Baseline and scope

The audit at W commit `1763b6cf82a6d8d2da63552a2b95641c6c25aeb8` used grammars-v4
commit `89fd36482e8cb68a4e55df021a8adbc7541b52f2` and the existing 291 selected cases.

| Measurement | Passing cases |
| --- | ---: |
| Default permissive translation | 218/291 |
| Default permissive generation and ordinary compilation | 212/291 |
| Default permissive output compiled with W `--strict` | 49/291 |
| Default translator `--strict` acceptance | 15/291 |
| Default strict output generated and compiled normally | 15/291 |
| Default strict output compiled with W `--strict` | 7/291 |
| Translator `--strict --stateful`, generation, and W `--strict` | 58/291 |

The 79 compile misses comprise 68 translation failures reporting unsupported
left recursion, four other zero-consumption/EOF failures, one missing-dependency
failure, and six generation failures. Categories describe observed blockers;
one case can contain several underlying problems. All 212 generated parsers
compile normally. The 163 warning-as-error failures contain generated boolean
bitwise warnings. The stateful strict path adds 45 acceptances and loses two
relative to default strict, so its 58 passes are a separate configuration.

ANTLR 4.13.2 generated source for 77 of the 79 W compile misses. AspectJ and
TrapC also failed on missing imports in that setup. This does not establish
Java compilation or runtime compatibility for those grammars. Informix/JPA
generated with undefined-token warnings; SHARC generated with empty-token
warnings. Runtime compatibility remains unconfigured in the current sweep.

Preserve the 291 roots, corpus revision, input hashes, original historical
`recorded_pass` data, and independently protected per-case expectations. Capture
new measurements before implementation changes. A correctness-driven loss needs
a reproducible counterexample and an explicit reclassification reason; keep the
historical success visible. Aggregate gains cannot compensate for another
case's unexplained regression. Do not change upstream grammar bytes to improve
the original cohort's count.

Completion means the planned capabilities have executable evidence, the
remaining cases have actionable explanations, and the supported subset has a
documented contract. It does not require pretending incomplete upstream grammars
or arbitrary foreign host code are automatically translatable.

## Parallel ownership

Only four agents run concurrently. Reassign the three worker slots between
waves; the table does not imply additional simultaneous agents.

| Role | Primary ownership | Handoff responsibility |
| --- | --- | --- |
| Integrator | Shared contracts, CLI wiring, shared generator/runtime entry points, aggregate baselines and final checks | Resolve interfaces before workers edit; integrate and review in dependency order |
| Worker A | Lexer emitters, new lexer IR/lowering/execution modules, lexer fixtures | Provide capability declarations, runtime requirements, and differential evidence |
| Worker B | Parser prediction, source metadata, precedence/list normalization, parser fixtures | Provide decision-mode contract, AST contract, and refusal explanations |
| Worker C | Sweep/oracle/harness/CI initially; Unicode and dependency/adapters in later waves | Maintain independent oracle fixtures; hand off mature harness before changing roles |

Each worker uses an isolated worktree and its own `bin/` and sweep artifacts.
Do not rebuild shared tool binaries concurrently from different source states.
The integrator freezes the exact combined revision for measurements and records
tool hashes before and after each sweep.

The integrator alone edits shared integration surfaces during an integration
window: `tools/antlr_to_pg.w`, translator `types.w`, `ast.w`, `audit.w`, `emit.w`,
and parser-generator `grammar_model.w`, `grammar_reader.w`, `generator.w`,
`token_stream.w`, `token.w`, and `lexer_state.w`. Workers develop new modules or
submit small integration patches against an agreed interface. Ownership can be
transferred explicitly for a wave, but never shared concurrently. Only the
integrator updates `sweep_baseline.json` and published coverage totals.

## Wave 0 Shared contracts and durable evidence

Land a small foundation change before production feature work:

1. Define configuration names and stage identities for the measurement matrix.
2. Define structured diagnostics and capability identifiers.
3. Define lexer match results, token observations, prediction inputs, and source
   alternative/label metadata needed by both backends.
4. Move the audit's useful reproductions from ignored `bin/` artifacts into
   maintained test inputs. Preserve the original measurements in documentation
   and regenerate machine results through the maintained harness.

An additive JSON audit should retain the human-readable diagnostic surface.
Each finding records a stable code, stage, source file/line/column, rule and
alternative/site, feature, explanation, and whether it is a demonstrated
mismatch, an unproven transformation, a missing dependency, or an unsupported
adapter. Separate undefined token identity from missing lexer implementation.
Report all known blockers per grammar; do not reduce planning to one error.

Initial codes must distinguish parser continuation risks; labels, compound
operators, ternaries, postfix tiers and recursive-tail refusals; nullable and
nonproductive forms; lexer continuation/repetition, nongreedy, Unicode,
case-insensitive, EOF/progress and channel limitations; and host declarations.
Workers add codes through the shared registry rather than inventing prose that
the sweep must classify with regular expressions.

## Wave 1 Measurements and small independent fixes

| Agent | Deliverable | Gate |
| --- | --- | --- |
| A | Generated predicate warning cleanup | Pure boolean matcher expressions use logical operators; all existing 212 permissive outputs compile with W `--strict` unless a separately documented issue is exposed |
| B | Parser witnesses, source metadata design, and decision-risk diagnostics | The known strict-accepted choice mismatch is visible; native `.pg` behavior is unchanged |
| C | Configuration matrix and pinned runtime oracle | Reproduce the baseline table independently and detect failures in the correct configuration/stage |
| Integrator | Diagnostic/metadata wiring and baseline capture | No unexplained historical or per-case loss |

Worker A edits `matchers_emit.w` and its owned tests. Keep genuine bitwise
operations; change the pure generated comparisons currently selected differently
by `g_at_stateful`. Review resulting JSON/CSV matcher golden changes explicitly.
This task improves warning-free compilation, not semantic acceptance.

Worker C extends `sweep_grammars_v4.py`, `tests/antlr_sweep_harness_test.py`, and
`.github/workflows/grammar-coverage.yml`. Introduce a versioned schema with two
independent configuration dimensions: permissive/strict translation and
default/explicit-stateful lexer selection. For each configuration run translation,
generation, ordinary W compilation, and W `--strict` compilation. Build each
configuration's own outputs in separate directories. Keep `not_run`,
`not_configured`, and unavailable-oracle states distinct from passes.

Runtime denominators count configured inputs and grammars separately from the
291 compile cases. Test configuration isolation, independent stage failures,
missing outputs, timeout/process-group cleanup, crashes, complete denominators,
schema migration, dependency integrity for every configuration, and tool changes
during a run. Preserve original historical 179 compile/10 strict records.

The oracle pins ANTLR 4.13.2 and its jar SHA-256
`eae2dfa119a64327444672aff63e9ec35a20180dc5b8090b7a6ab85125df4d76`,
the Java environment and options, source grammar/base-class hashes, start rules,
and test inputs. Normal `./wbuild tests` uses checked-in inputs and oracle
snapshots without Java or network access. A separate CI job verifies the jar,
generates and compiles Java code, executes the reference, and checks snapshots.
Report source generation, Java compilation, and execution separately.

Acceptance requires zero lexer errors, zero parser errors, and full input
consumption. A recovered parse tree is not successful recognition. Compare
symbolic token identities, text, channels and normalized spans separately from
parser outcomes. Compare expression grouping through a normalized semantic tree
or evaluated result. Keep W's retained skipped trivia separate from ANTLR's
public token stream. Normalize byte/code-point/UTF-16 offsets explicitly.

## Wave 2 Lexer and parser architecture prototypes

Worker A builds a continuation-aware lexer prototype. Worker B builds an
imported-ANTLR prediction prototype. Worker C supplies independent adversarial
fixtures and performance measurements. Shared runtime changes remain with the
integrator. Both prototypes must publish supported semantics and limitations
before production integration.

### Lexer prototype

Retain the existing stateful shell for rule priority, modes, ordered commands,
token spans and `more`. Add proposed translator modules `lexer_ir.w`,
`lexer_lower.w`, and `lexer_emit.w`, with a reusable execution module if needed.
Represent character transitions, epsilon branches, ordered alternatives,
greedy/nongreedy decisions, accepting states and source provenance. Reserve a
call/return representation for later recursive-rule support.

Use NFA-style configuration execution first, retaining viable endpoints through
the whole token rule. A helper must not choose one longest endpoint before its
continuation is examined. Deduplicate configurations and execute lexer commands
only after selecting the winning top-level token rule. Implement regular ASCII
semantics before Unicode, nongreedy priority and recursive calls. Delay DFA
caching until correctness and profiling justify it; an unordered NFA alone does
not reproduce ANTLR nongreedy behavior.

Gate: differential token tests cover `[a-z]+ 'x'`, `('aa' | 'aaa')+`, optional
pieces stealing delimiters, overlapping alternatives, fragment continuations,
failed suffixes, equal-length competing rules and malformed/truncated input.
Record execution time, peak memory, configuration counts and generated size on
both representative inputs and increasing adversarial inputs. Resource exhaustion
must be an explicit execution failure, never silently converted into rejection.

### Parser prototype

The preferred hypothesis is an explicit imported-ANTLR prediction mode using
context-aware decision simulation over a grammar/ATN-like representation. Keep
the existing deterministic fast paths where sound. Prediction must consider
the caller's continuation and optional/repeated terms, retain source alternative
priority, and avoid speculative AST construction or host side effects.

Evaluate one small continuation-preserving general-parser alternative against
the same witnesses if needed to test that hypothesis. Select one production
direction, documenting ambiguity policy, AST construction, lookahead/memory
limits and supported grammar subset. Broader CFG recognition alone is not
ANTLR equivalence. Sorting alternatives by length, fixed lookahead, and PEG
left-recursion support are not substitutes for this gate.

The mandatory initial witness is:

```antlr
grammar Choice;
start: item EOF;
item: 'a' | 'a' 'b';
WS: [ \t\r\n]+ -> skip;
```

ANTLR accepts `ab`; the current strict-translated W parser rejects it. Add
caller-follow-sensitive choices, indirect shared prefixes, nullable alternatives,
optional/repeated term continuations, ambiguity, dangling `else`, and TinyC/MicroC
assignments/comparisons/`else`. Test both acceptance and malformed inputs.

Gate: match reference acceptance, full consumption, source-order ambiguity
resolution, precedence and association; preserve the defined AST metadata;
execute no speculative actions; keep native `.pg` output/behavior and existing
streaming restrictions intact. Record time, memory, generated size, and failure
behavior under increasing shared-prefix inputs. Set explicit per-fixture resource
limits from the prototype measurements before enabling production CI gates.

Until a decision shape is supported, strict compatibility auditing must expose
it as unproven or refuse it. Preserve historical strict results, but use a
reproducer-backed reclassification if a previous acceptance is demonstrated
incorrect. Do not retain a false guarantee to protect the headline count.

## Wave 3 Production engines and source contracts

| Agent | Deliverable | Dependency |
| --- | --- | --- |
| A | Exact regular lexer execution, then nongreedy priorities | Lexer prototype gate |
| B | Chosen prediction implementation and source metadata | Parser prototype gate |
| C | Unicode/case-handling module and independent fixtures | Frozen lexer charset/code-point API; completed harness handoff |
| Integrator | Serialized runtime/model/CLI integration and oracle execution | Both worker contracts |

Add an explicit parser-mode representation to the PG model/reader/generator and
translator emission. Update the emitted-DSL validator `antlr_to_pg/pg.pg`,
documentation and syntax fixtures together. Imported grammar selection must be
explicit; do not change all existing native AST/streaming grammars implicitly.

Preserve source rule, source alternative, element label/list-label semantics,
and spans through normalization and helper generation. Define accessors or
metadata for the normalized W AST. Full ANTLR generated context/listener API
identity is outside this increment. Label support must precede relaxing the
current labeled-recursion refusals.

Unicode work covers literal escape decoding in AST construction, UTF-8 traversal,
code-point ranges/complements, properties, wildcard semantics and grammar/rule
`caseInsensitive` precedence. Pin Unicode data and reference behavior. Test raw
and escaped BMP/non-BMP text, invalid encodings, negated classes, property sets,
mixed-case ranges and positions. An ASCII subset is not an exact implementation.
Worker C owns new charset/data modules; the integrator applies narrow changes
to shared `ast.w` and option processing.

Gate: each newly implemented capability removes only its corresponding audit
loss and has executable differential evidence. Default and explicit-stateful
configurations remain independently measured. Keep unsupported host code visible.

## Wave 4 Expressions and lexer state completion

| Agent | Deliverable | Required witnesses |
| --- | --- | --- |
| A | Productive recursive lexer calls and state-transition design | Bison/Langium/PowerQuery token examples; nonproductive Lisp refusal |
| B | General direct-expression plan and recursive lists | Labels, ternaries, compound operators, interleaved postfix tiers, keyword-delimited lists |
| C | Pinned dependency setup and adapter provenance | AspectJ/TrapC imports, host adapter acceptance/refusal, source defects |
| Integrator | EOF/progress/channel runtime implementation and combined review | Token-provider snapshots, source reconstruction, termination |

Worker B replaces ad hoc tier-shape decisions with explicit descriptors carrying
source alternative, precedence, associativity, operator sequence, operand
positions and binding powers. Support ternary intermediate operands, compound
operator clauses and postfix operations at multiple binding levels. Preserve
ANTLR's source-order prefix binding and indirect-call behavior. Overlapping
bases/operators become eligible only when the production predictor supports
their decisions. Suggested corpus witnesses are Teal/CTL for overlap, PromQL
for compound clauses, AQL/Terraform for ternaries, and labeled Go/Rust/MuParser
forms. Removing one blocker does not imply the entire grammar now works.

Extend list proofs to supported keyword-delimited bodies, including MATLAB
statement lists. Distinguish guarded recursion from operands that indirectly
return to the owner. Keep productivity, nullability, final nullable-prefix cycle
checks, helper-name collision handling and atomic refusal. Arbitrary indirect
or hidden left recursion remains separately unsupported.

Worker A adds call/return lexer configurations with explicit cycle and resource
handling after regular matching is stable. Test recursive nesting, overlapping
fallbacks, nongreedy delimiters, unterminated input and fragment continuations.
Do not invent a productive base for Lisp or erase matching alternatives merely
to emit a token.

EOF/state work must change the runtime contract as well as the audit: current
generated lexers check EOF before probing rules, require positive match lengths,
and the token stream rejects non-EOF tokens without offset progress. Represent
EOF completion and mode-only transitions explicitly. Detect repeated zero-input
configurations and unbounded mode-stack growth. Start with internal mode-only
transitions; expose zero-width named tokens only after defining spans, storage,
and parser consumption. Test Pegen/Rex EOF rules, Creole EOF-as-newline, Go's
mode-only fallback, `more` at EOF, and deliberately cyclic transitions.

Custom channels require identity mapping. ANTLR custom channel numbers must not
be copied into PG's reserved error-channel identity. Preserve source order and
lossless trivia while exposing the requested parser-visible channel behavior.
Test channel remaps, invalid commands, snapshots, rewind and roundtrip text.

Worker C first tries explicit pinned dependency inputs for AspectJ/TrapC using
the existing resolver; broad global discovery is not the default solution.
Pin additional grammar/base-class/example paths and any upstream setup recipes.
Keep changed setup as a separately identified configuration or cohort, preserving
the original roots and historical measurement. Informix/JPA missing matchers,
SHARC empty definitions and Lisp nonproductivity remain named source defects.

Adapters record source site/text/hash, native adapter path, supported scope,
runtime evidence and deferred behavior. Use JavaScript's existing adaptation
ledger as a provenance precedent, not as an assumed general adapter runtime.
Port selected host semantics explicitly. Never drop a predicate or superclass
and label the result generic strict compatibility.

## Wave 5 Runtime promotion and rollout

Worker C returns to independent conformance and bounded fuzzing; A and B close
minimized lexer/parser counterexamples. Use deterministic generation/mutation
seeds and persist minimized failures as ordinary tests. A pinned Grammarinator
job is optional; it must not add an unbounded or network-dependent step to the
normal test suite.

Promote a runtime capability only after positive/negative oracle tests pass.
Known valid upstream inputs stay recorded as known compatibility mismatches
until fixed; they are never converted into negative-language fixtures. Compare
labels/source identity only where supported, and compare normalized grouping
rather than raw generated helper trees.

Consider making exact stateful lowering the default only after default goldens,
existing consumers, runtime fixtures and measured performance satisfy the
documented contract. Keep parser-mode rollout independently controlled. Restore
or explain Geekcode/STL's stateful proof failures before claiming a uniform
replacement for the existing strict path.

The integrator publishes a final feature ledger, per-grammar remaining blockers,
independent configuration/stage counts and configured-runtime denominators.
Every one of the original 79 compile misses and 276 strict misses must have
either a measured promotion or an explicit remaining cause. No numerical target
for full ANTLR equivalence is inferred from compilation.

## Merge order and validation

Land contracts and baseline measurement first. Warning cleanup and oracle
fixtures can land independently after that. Land production lexer/prediction
integration only after their prototype gates; then land Unicode, expression,
recursive-lexer, EOF/channel and adapter increments with their own tests. Update
aggregate baselines last, from an unchanged combined revision.

For every code increment:

1. Run structured checks after `.w` edits and fix warnings. Check `w.w` for
   compiler-tree changes. Use `bin/wtest archs <file> --check` where applicable.
2. Use `git diff --name-only HEAD | bin/wtest changed` to select focused targets;
   include new untracked sources explicitly before they enter the diff.
3. Run relevant executable lexer/parser fixtures, atomic-refusal checks and the
   live oracle for changed semantic behavior. Keep offline harness checks green.
4. Run `./wbuild tests` on the integrated revision with `NO_COLOR` unset. Shared
   compiler-imported parser-generator changes must also satisfy bootstrap/fixpoint
   checks and retain syntax accepted by the pinned seed. Apply the repository's
   changed-line coverage gate when compiler-tree code is touched.
5. Run the complete pinned configuration sweep and configured runtime suite;
   verify hashes, no crashes/timeouts/missing artifacts, and per-case expectations.
6. Publish measured gains, regressions/reclassifications, remaining blockers and
   resource measurements. Raise expectations only for observed passes.

Each worker handoff contains its exact revision, owned files, interface changes,
test commands/results, oracle witnesses and unresolved cases. Another worker
cross-reviews semantic acceptance; the integrator owns combined validation.

## Design references

- [Current pinned coverage](SWEEP_RESULTS.md) and [translator contract](README.md).
- [Existing expression increment](EXPRESSION_COVERAGE_PLAN.md) and
  [prior list/expression increment](COVERAGE_NEXT_PLAN.md).
- [Native parser-generator behavior](../../../../docs/projects/parser_generator.md).
- [ANTLR left-recursion transformation](https://github.com/antlr/antlr4/blob/4.13.2/doc/left-recursion.md)
  and [prediction implementation](https://github.com/antlr/antlr4/blob/4.13.2/runtime/Java/src/org/antlr/v4/runtime/atn/ParserATNSimulator.java).
- [ANTLR lexer rules](https://github.com/antlr/antlr4/blob/4.13.2/doc/lexer-rules.md)
  and [nongreedy decisions](https://github.com/antlr/antlr4/blob/4.13.2/doc/wildcard.md).
- [Bison GLR](https://www.gnu.org/software/bison/manual/html_node/GLR-Parsers.html),
  [Lark parsing algorithms](https://lark-parser.readthedocs.io/en/latest/parsers.html),
  and [CPython PEG design](https://peps.python.org/pep-0617/) provide architecture
  comparisons; none is automatically a drop-in ANTLR compatibility layer.
