# Build system: where wbuild stands, and four directions to take it

Brainstorm / design survey, 2026-07-10. Companion to
`docs/projects/wexec.md` (which records the Makefile→wexec migration and
the executor's design). This doc assesses the remaining duplication in
the wbuild stack, compares how other ecosystems solved each problem, and
lays out four improvement directions, roughly ordered from pragmatic to
research-grade — including a staged version of the grammar+VCS
integrated build idea.

**Scope constraint (2026-07-10): W does not support versioning yet.**
`package.wmeta` carries version fields and constraints (stages 1–4 of
`docs/package_metadata.txt`), but lock files (stage 5), dependency
fetching, and any cross-version resolution are unimplemented. Every
part of this doc that depends on version identity or commit history —
direction 4b and the cross-commit queries built on it — is therefore
**deferred until versioning is in place**. The in-scope near-term work
is directions 1, 4a, and 3, all of which key purely off the current
working tree's content and need no versioning story at all.

## Where the system stands today

The shape is already good — a Ninja-like two-layer split that most
ecosystems converge on eventually:

- `wbuild` (52-line shell bootstrap) → `bin/wexec` (~1000-line W-native
  executor) → `build.json` (generated manifest, 258 targets).
- Content-hash caching (not mtime), parallel scheduling with ordered
  output, no shell in the execution path.
- `tools/wbuildgen.w` derives the 157 conventional compile+run test
  targets from the tree; `build.base.json` (1652 lines) holds the 98
  irregular ones plus 3 aggregates.
- `bin/wtest changed` does impact-based test selection from the manifest
  plus `wv2 deps` import closures plus `tools/test_map.w` residue rules.

Measured on this tree: a full compiler self-compile is ~4.6s; a leaf
test compiles in ~0.1s. So leaf compiles are already effectively
instant — the expensive things are (a) the bootstrap/verify chain
(4 full self-compiles ≈ 20s), (b) running the whole `tests` umbrella,
and (c) knowing *precisely* what a change invalidates. Any improvement
should target those three, not leaf compile speed.

### The duplication that remains

The dependency graph is currently stated in **four places**:

1. **Source `import` lines** — ground truth, already queryable via
   `wv2 deps`.
2. **Manifest `"inputs"`** — coarse directory prefixes (`wv2` declares
   `compiler/`, `grammar/`, ... whole trees), a conservative
   over-approximation of (1). A comment edit anywhere under `lib/`
   invalidates the compiler.
3. **`tools/test_map.w` residue rules** — ~150 lines of hardcoded
   path→target `strcmp` chains, most of which restate coupling the
   import graph already knows but `deps` can't see (arch-specific
   modules, data files).
4. **`wtest_map_test` golden lists in `build.base.json`** — exact
   expected-output fixtures for (3), re-maintained by hand whenever the
   graph shifts.

This is exactly Bazel's classic sin (Python `import` vs BUILD `deps`,
maintained twice) — except W already has the tool Bazel had to grow
separately (Gazelle, their BUILD-file generator): the compiler itself.
Beyond the graph, `build.base.json` still hand-carries per-target
details (`stdin`, `timeout_ms`, `expect_stdout`, extra steps) that the
fixture-directive precedent (`# expect_stderr:` headers read by
`bin/wfixture`) shows can live in the test source instead. And the
darwin/arm64 target families are structural near-clones of their Linux
counterparts (the cp/mv staging dance is repeated verbatim in
`wbuild`, `wexec_darwin`, and `build_darwin`).

## How others do it (mapped to W)

- **Go**: no build files at all. The import graph *is* the build graph;
  package = directory; irregularities are in-source directives
  (`//go:build`, `//go:embed`). Content-addressed build *and test
  result* cache — `go test` prints `(cached)` for packages whose inputs
  didn't change. This is the mature version of what `wv2 file.w`
  "just works" already feels like, and `# wbuild: x64` is already a
  Go-style directive.
- **Bazel / Buck2**: explicit hermetic target graph, remote cache +
  remote execution. The parts worth stealing are the *cache protocol*
  (dumb content-addressed blob store) and the discipline that a cache
  key must capture every input; the part to avoid is the second,
  hand-maintained dep graph. Buck2/Skyframe internally model the whole
  build as memoized incremental computation — relevant prior art for
  direction 4.
- **Ninja**: dumb executor + generated manifest. wexec is already this;
  no action needed.
- **Tup / Memoize / fabricate**: don't declare inputs — *trace* them
  (FUSE or syscall tracing) and record what the compiler actually
  opened. Exact dependencies with zero declaration.
- **Zig**: the build script is a program in the language (`build.zig`).
  Considered and rightly rejected in wexec.md — static JSON stays
  analyzable; wbuildgen gives the expressiveness where needed.
- **Unison**: the extreme endpoint of grammar-integrated builds:
  definitions are content-addressed by AST hash, names are metadata,
  the codebase is a database. Test results are cached per definition
  hash — a test whose transitive definitions didn't change never
  reruns. It works, at the cost of abandoning text files and git.
- **Salsa / rust-analyzer, Eclipse JDT, Kotlin IC**: query-based or
  definition-granularity incremental compilation inside the toolchain —
  the "read the grammar to determine build structure" half, done as
  compiler infrastructure rather than a build tool.
- **tree-sitter**: realtime incremental re-parsing across edits — the
  "maintained in realtime" half, proven in editors.

Nobody glues definition-level hashing + VCS history + realtime
maintenance together on top of ordinary text files and git. Unison is
closest and got there by replacing the filesystem. That middle point is
genuinely open territory — see direction 4.

## Direction 1 — the compiler as the single source of truth

Goal: delete duplication classes 2–4 above by making wexec/wtest derive
everything derivable from `wv2`, and moving the rest into the source
files it describes.

- **Deps-driven cache keys.** For any target whose step compiles a `.w`
  root, wexec computes the input set by running `wv2 deps <root>`
  (cached the way `bin/.wtest_deps_cache` already does) instead of
  reading `"inputs"`. Manifest `"inputs"` remain only for non-W inputs
  (fixture data, `.pg` grammars, shell helpers, the seeds). Immediate
  precision win: a `lib/` comment edit stops invalidating `wv2`'s
  cache; conversely undeclared-but-imported files can no longer be
  missed.
- **Arch-aware `deps`** (already on the `ai_tooling_next_steps.md`
  backlog): once `deps` composes with the target selector and resolves
  `lib/__arch__/` per-arch, most of `test_map.w`'s residue rules retire.
  The rules that remain are only true out-of-band coupling (run-time
  data files), which is what the residue mechanism was designed for.
- **In-source target directives.** Extend the `# wbuild:` directive
  vocabulary so a test carries its own irregularities:
  `# wbuild: timeout=5000`, `# wbuild: stdin=...`,
  `# wbuild: expect_stdout=...`, `# wbuild: arch=x64,arm64`,
  `# wbuild: deps=hello` (for tests like `wexec_test` that need a
  sibling artifact). wbuildgen already parses directives; each field it
  learns moves targets out of `build.base.json`. The `# expect_stderr:`
  fixture-header migration proved the pattern. Realistic end state:
  base shrinks to the toolchain chain, the darwin/arm64 families, and
  the aggregates — a few hundred lines.
- **Platform axis in generation.** Teach wbuildgen a `platforms`
  expansion so the darwin/arm64 twins (and their staging idiom) are
  generated from one description instead of transcribed. The
  cp/mv fresh-inode dance becomes one templated step sequence.
- **Fix the golden-list fixture.** Generate `wtest_map_test`'s expected
  lists (or assert must-contain properties instead of exact sets) so
  graph changes stop requiring hand-edits to `build.base.json`.

Effort: incremental, each bullet lands independently. Risk: low — every
piece is checkable against the current behavior (same trick as the
manifest migration's lossless diff). This is the Gazelle/Go lesson
applied to a repo that, unlike Bazel's users, owns its compiler.

## Direction 2 — traced dependencies (exact inputs, zero declaration)

Instead of declaring or deriving inputs, *observe* them: wexec already
forks each step as a child process, and the repo already ships ptrace
machinery (`debugger/`, wdbg attach). Run steps under a lightweight
ptrace supervisor that records every path successfully `open`ed for
reading; that set (hashed) becomes the target's input key, stored
alongside the cache stamp.

- Catches what no declaration can: the compiler reading
  `structures/hash_table.w` via auto-import, fixtures read at runtime,
  `run_arm64.sh` invoking qemu.
- Gives hermeticity-lite for free: a `--hermetic` flag fails a target
  that reads outside its recorded set — Bazel's sandbox benefit without
  a sandbox.
- First run of a target is uncached (no recorded set yet) — same
  semantics Tup/redo accept; combine with Direction 1 so the *derived*
  set primes the key and the *traced* set audits/extends it.
- Cost: a ptrace supervisor is real work (syscall-stop handling per
  arch), but it dogfoods the debugger infrastructure, and only the
  Linux hosts need it (darwin targets are FORCE-style anyway, per
  wexec.md).

## Direction 3 — shared cache, then remote execution (the Bazel piece)

wexec already computes a cache key per target; today the only consumer
is a local stamp file. Widen the key from the 64-bit rolling hash to
SHA-256 (`lib/sha256.w` is sitting right there) and add a dumb
content-addressed remote store:

- Protocol: `GET /cas/<key>` → tarball of the target's declared
  outputs + the pass stamp; `PUT` on cache miss after a green run.
  A dumb HTTP server suffices — sccache/ccache/Buck2's HTTP cache mode
  prove gRPC isn't needed. The repo's own `libs/standard/net` HTTP(S)
  stack could host it in a ~200-line `wcache.w`, which would be a very
  W move: the build cache server is itself a W program built by the
  manifest it serves.
- What it buys: CI populates the cache; a fresh clone's
  `./wbuild tests` becomes mostly `(cached)` lines — including *test
  results*, Go-style, since a run-target's stamp is keyed by its full
  input closure. The bootstrap chain caches the same way (`build`'s key
  already piggybacks on `wv2`'s source hash), so `verify` on an
  untouched compiler tree is a cache hit rather than 20s of
  self-compiles.
- Prerequisite: keys must be *trustworthy* before they're shared —
  which is Directions 1/2. A shared cache multiplies the blast radius
  of an over-coarse or missing input. Sequence it after them.
- Remote *execution*, the second half of Bazel's story, has a cheap
  W-shaped MVP: the Mac workflow already offloads Linux-only targets to
  ssh host `w` by hand. `wexec --remote=<host> <target>` that rsyncs
  the input closure (known exactly, thanks to 1/2), runs the target
  remotely, and pulls outputs back would formalize the existing habit
  — no execution API, no workers, just ssh. Full farm-style RE is not
  worth it at this repo's scale.

## Direction 4 — the grammar + version-control integrated build

The idea: read (some of) the grammar to determine build structure at
*definition* granularity rather than file granularity, maintain the
structured tree and its diffs continuously across edits and commits,
and make invalidation exact enough that most "builds" are lookups.

Honest framing first: nobody does this end-to-end on text files.
Unison does it by making the AST database *the* codebase; Salsa/JDT do
the granularity without the VCS half; tree-sitter does the realtime
half without the build half. The reasons it stays unglued elsewhere —
non-local semantic effects (inference, overloads, macros) make precise
per-definition effect maps hard — are much weaker in W: single-pass
compilation means declaration-before-use discipline, no inference to
speak of, and the tokenizer + symbol table needed to extract
per-definition facts already exist in `compiler/`. W is unusually well
placed to build the middle point. Staged so each stage pays for itself:

### 4a. Definition-level content hashing (`wv2 defhash`)

A subcommand that emits, per top-level definition (function, struct,
global, protocol), a content hash over its token stream (whitespace
and comments excluded) plus the list of external symbols it references.
Build on the tokenizer + `symbols` machinery. Then:

- A target's semantic cache key = hash of the *reachable definition
  set* from its entry point, instead of file bytes. Formatting and
  comment edits invalidate nothing; editing one `lib/` function
  invalidates only targets that transitively reference it — file-level
  `deps` closure becomes definition-level reachability.
- `wtest changed` gains the same precision: a diff touching three
  functions selects tests reaching *those functions*, not tests
  importing those files.
- This is the highest-leverage 20% of the whole idea, and it is pure
  toolchain-query work — no compiler-output changes, `verify`
  untouched.

### 4b. The VCS half: a persistent semantic index over git history
### (deferred — blocked on W versioning support)

Everything in this stage assumes stable identity across versions of the
tree — commit-ranged queries, result reuse across history, definitions
tracked through renames. W's versioning story is metadata-only today
(no lock files, no cross-version resolution), so this stage should not
start until that lands; 4a and 4c below are deliberately shaped so they
don't wait for it. Recorded here as the eventual destination:

Maintain an index (a `bin/.windex`-style cache, derived and
regenerable) mapping definition-hash → {defining file/commit, direct
references, cached target/test results}. Because keys are content
hashes, the index is naturally append-only and shared-cache-friendly
(merges with Direction 3's store). What falls out:

- `wtest changed A..B` over commit ranges, exact at definition level.
- Semantic history queries for free: "which definitions changed between
  v1 and v2", semantic blame ("when did this function's *behavior*
  last change, ignoring moves/renames/reformatting"), rename detection
  (same hash, new name).
- Tree diffs between commits are set-diffs of definition hashes —
  cheap, incremental, and a strictly better input to `test_changed`
  than `git diff --name-only`.

### 4c. Realtime maintenance

Working-tree only — needs 4a's `defhash` but none of 4b's history
integration, so it is not blocked on versioning. A small watcher (or
the editor-hook path the AI tooling already uses) re-runs `defhash` on
save and folds the result into a working-tree index. W files
are small and the tokenizer is fast — re-hashing a saved file is
sub-millisecond, so tree-sitter-grade incremental parsing is
unnecessary; whole-file re-lex on save *is* realtime at this scale.
Effect: by the time `./wbuild test_changed` is typed, the analysis is
already done — selection and cache lookup are index reads, and the
"nearly instant build" experience is real for the common case (edit →
exact test set → mostly cached → run the few truly affected binaries).

### 4d. Incremental codegen — flagged as research, probably skip

The maximal version — cache per-definition machine code and patch
binaries instead of recompiling — fights this compiler's architecture:
single-pass direct byte emission means every definition's address
depends on everything emitted before it, so "patching" means
relocation infrastructure the compiler deliberately doesn't have. And
the payoff is capped: whole-program compiles are 0.1s for leaves and
~5s for the compiler itself. If sub-second self-compiles ever matter,
this becomes its own project (a relocatable fast-path backend), and
`verify`'s byte-equality gate must stay defined over the full
non-incremental compile so the fixpoint guarantee is never diluted.

## Suggested sequencing

1. **Direction 1** first — it deletes existing duplication, needs no
   new infrastructure, and every later direction depends on
   trustworthy, derived input sets. Start with deps-driven cache keys
   and the directive vocabulary; arch-aware `deps` unlocks the
   test_map cleanup.
2. **4a (`defhash`)** second — small, self-contained, immediately
   sharpens both caching and `wtest changed`, and is the foundation of
   the novel part of the idea.
3. **Direction 3's shared cache** third, once keys are derived (1) and
   fine-grained (4a) — that's when a shared cache pays off most and
   mis-invalidation risk is lowest. The ssh remote-run MVP can ride
   along.
4. **4c** (working-tree watcher) once 4a exists; **Direction 2**
   (tracing) whenever hermeticity or undeclared-input bugs actually
   bite — it's the best *audit* for the derived graph even if it never
   becomes the primary key source.
5. **4b** only after W versioning support lands (see the scope
   constraint at the top) — the history-integrated index is the
   destination, not the near-term work.
6. **4d** only if a concrete need for sub-second self-compiles appears.
