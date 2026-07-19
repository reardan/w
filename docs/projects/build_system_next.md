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

## Stage-1 inventory (issue #323, 2026-07-16): every shell script and hand-written target

Issue #323's end state is "no build.json/Makefiles/shell scripts; deps
captured in .w sources; `wbuild path/to/file.w` just works". The direct-file
UX (`./wbuild [selector] path/to/file.w`, `bin/wtest for path...` —
`tools/wexec.w`'s "Direct-file UX" section and `tools/test_map.w`'s `for`
subcommand) is the first concrete step and lands resolved through the
*existing* manifest/deps machinery: `build.json` and `build.base.json`
still exist after it. This section is the stage-2 roadmap: every
`tools/*.sh` script (plus every other `.sh` `build.base.json` invokes) and
every one of `build.base.json`'s 168 hand-written targets, each with why it
resists becoming a generated (or deleted) target, enumerated directly from
the manifest rather than guessed. Counts below are exact for the tree at
this commit; rerun the classification (structural, not prose) before
trusting it against a later tree.

### Shell scripts (11: 10 `tools/*.sh` + `archive.sh`)

| Script | Invoked by (`build.base.json`) | #323 blocker |
|---|---|---|
| `tools/run_arm64.sh` | `build_arm64`, `arm64_smoke_test`, `pac_full_test_arm64`, `pac_corrupt_test_arm64`, plus every generated `arch=arm64` twin | qemu-user-static / native-exec wrapper — a cross-arch execution shim is likely permanent (Bazel/Buck2 keep an equivalent runner); revisit only if `lib.process` grows emulator-aware exec. |
| `tools/run_wasm.sh` | `build_wasm`, `wasm_smoke_test`, plus every wasm run step | Wraps `wasmtime`/`node`; same "permanent execution shim" reasoning as `run_arm64.sh`. Also blocks bucket G below (wbuildgen's `arch=` vocabulary has no `wasm` value yet). |
| `tools/web/run_node.sh` | `wasm_extern_test`, `wasm_webgl_test` | Wraps `node` to run `tools/web/*.mjs` harnesses; the harnesses themselves are non-W, so this sits outside the ".w sources" model regardless of the shell wrapper. |
| `tools/openssl_interop_test.sh` | `openssl_interop_test` | Shells out to the system `openssl` CLI for a TLS/crypto interop round-trip. Needs a W-side subprocess-diff harness (spawn `openssl` via `lib.process`, compare) before the script can retire — real porting work, not a directive gap. |
| `tools/compress_zlib_interop_test.sh` | `compress_zlib_interop_test` | Same shape as `openssl_interop_test.sh`, against the system `zlib`/`gzip`. Same blocker. |
| `tools/attach_test.sh` | `attach_test` | ptrace-based debugger-attach test. Needs porting onto the in-repo ptrace machinery (`debugger/`) as a W test harness — natural to revisit alongside #123's attach phases. |
| `tools/parser_generator_w_batches.sh` | `parser_generator_w_test` | Batches/diffs parser-generator output across the tracked `.w` corpus. Needs porting to a W batch-diff tool, or folding into `tools/parser_generator.w` itself. |
| `tools/merge_manifest.sh` | *(not referenced — opt-in git merge driver, see its own header)* | Exists specifically to resolve `build.json` merge conflicts by regeneration; irrelevant once `build.json` is retired. Until then it's outside the wexec-driven graph entirely (local git config, not a manifest step). |
| `tools/mac/run_darwin_tests.sh` | *(not referenced — invoked by hand per `AGENTS.md`/`CLAUDE.md`)* | Developer-invoked native Mach-O test runner; Mac-only, never a manifest target. Out of scope for #323's manifest-capture model. |
| `tools/mac/wdev.sh` | *(not referenced — invoked by hand)* | Docker `w-dev` container wrapper for the agent/dev workflow. Same "out of scope" reasoning as `run_darwin_tests.sh`. |
| `archive.sh` (repo root) | `update`, `update_win`, `update_darwin` | Archives the current seed before promotion (`docs/release.md`). Tightly coupled to seed bootstrap (inventory bucket A below); runs before any freshly-built compiler is trustworthy, so it is unlikely to become a W program before the bootstrap chain itself is redesigned. |

`libs/standard/net/{tls,x509}_fixtures/gen_*.sh` are real shell scripts
in the tree but match neither filter (not under `tools/`, not referenced
by `build.base.json`) — one-off fixture regenerators run by hand, out of
scope for this inventory.

### Hand-written `build.base.json` targets (168), by migration blocker

Bucket sizes sum to exactly 168; every target name in the manifest appears
in exactly one bucket.

**A. Bootstrap / self-host chain — 20.**
`wv2`, `wexec`, `build`, `verify`, `update`, `wv2_win`, `wexec_win`,
`build_win`, `verify_win`, `update_win`, `wexec_darwin`, `build_darwin`,
`verify_darwin`, `update_darwin`, `build_x64`, `verify_x64`,
`build_arm64`, `verify_arm64`, `build_wasm`, `verify_wasm`. Blocker:
these targets *are* the build system (chained `wv2`→`wv3`→`wv4`→`wv5`
self-compiles, byte-equality checks, the darwin/win64 cp/mv staging
dance) — structurally not a "compile one `.w` root" shape at all, so no
per-file directive captures them. Likely permanent, or migrates only
alongside a from-scratch bootstrap redesign; out of #323 stage-2 scope.

**B. Umbrella aggregates — 3.** `tests`, `tests_x64`, `tests_win64`.
Blocker: step-less; membership is a hand-maintained `deps` array that
`wbuildgen` appends generated names to. #323's "no build.json" endgame
needs a tag/glob-based selection mechanism (e.g. "every generated leaf
target") instead of a materialized array before these can stop being
manifest entries at all.

**C. Tool binaries, no test convention — 11.** `wtest`, `wbuildgen`,
`wfixture`, `wtest_map_check`, `wmeta`, `wvdiff`, `wvc`, `wdbg`,
`wdbg_x64`, `gen_stubs`, `rewrite_c_strings`. Blocker: single compile
step, no run/assertion — not `*_test.w`-shaped, so `wbuildgen`'s
generation convention doesn't apply regardless of directives. This PR's
direct-file UX already covers the *compile* half ad hoc
(`./wbuild tools/wmeta.w` now works without a manifest entry), but
dependents (`manifest` → `wbuildgen`, `metadata_check` → `wmeta`,
`wvc_e2e_test` → `wvc`, ...) still reference them by target *name* in
`deps`; the entries can't be deleted until #323 gives a target a
path-based way to depend on "compile this file first" (bucket K below is
the same gap from the dependent's side).

**D. Already directive-expressible, simply unmigrated — 21 originally;
11 migrated in wave 2 task 2a (2026-07-19), 10 remain and were
reclassified — the inventory's "no blocker at all" framing was
optimistic for 7 of the 21; see below.**

  Migrated (now generated, hand-written entries deleted from
  `build.base.json`): the 5 plain compile+run targets whose source
  already used the default arch — `float_abi_test`, `varargs_test`,
  `extern_data_test`, `print_builtin_test`, `dynamic_test` — plus the
  two asm targets whose only unconventional field was a directory-level
  `inputs` declaration, migrated via `deps=` — `asm_x86_disasm_test`,
  `asm_x86_asm_test` (note: `deps=` only feeds `bin/wtest`'s "data"
  selection field, not `wexec`'s "inputs" cache-key field, which
  generated targets cannot declare at all — these two lose wexec's
  content-hash caching and become FORCE targets like the ~430 other
  generated targets that already have no "inputs"; a real but minor
  loss, not a test-behavior change). The 4 legacy `X_test_x64` targets
  all migrated and renamed to the `X_64_test` convention: `dynamic_test_x64`
  → `dynamic_64_test`, `c_import_libc_test_x64` → `c_import_libc_64_test`,
  `varargs_test_x64` → `varargs_64_test`, `extern_data_test_x64` →
  `extern_data_64_test` (downstream references to the old names updated
  in the same commit: `docs/todo.txt`, this file).

  Deferred, reclassified with their real blocker (the "21, no blocker"
  framing did not hold under wbuildgen's actual generation rules):
  - `x64_test`, `x64_float_test`, `x64_fmath64_test`,
    `x64_ndarray64_test`, `x64_int64_test`, `x64_map_float64_test` (6):
    each source's basename already equals the desired *x64-only* target
    name, but `wbuildgen` unconditionally also generates a default
    32-bit twin under that same basename-derived name (there is no way
    to suppress or redirect it), and several of these sources use
    `float64` (rejected by the compiler on 32-bit words) — so deleting
    the hand-written entry would silently generate a broken/incorrect
    32-bit target reusing the name, not a clean migration. This is
    really bucket G's "name doesn't match convention" blocker wearing an
    arch disguise: needs a `name=`-style override (or an "arch-only, no
    default twin" directive) before it can move.
  - `asm_stubs_test` (1): its declared `inputs` include three
    `code_generator/{x86,x64,arm64}_asm.w` files consumed as runtime
    *text data* (via `asm_stub_check`), not compiled — but `wbuildgen`'s
    `deps=` directive flatly rejects any value ending in `.w`
    ("imports already track" it, which is false here). No directive
    can express this target's actual input set today.
  - `arm64_smoke_test`, `wasm_smoke_test` (2): genuine aggregate
    umbrellas — 6 and 9 programs respectively, each compiled, run, and
    followed by a shared `echo "... OK"` epilogue step — not the single
    `(source, arch)` shape `wbuildgen` ever generates. `wasm_smoke_test`
    is additionally blocked at the arch level: `wbuildgen` has zero
    `wasm` awareness (`arch=` only accepts `x64`/`arm64`/`win64`/
    `arm64_darwin`), matching the `run_wasm.sh` row above.
  - `pac_full_test_arm64` (1): needs `--pac=full` injected into the
    arm64 compile command and carries the same `echo "... OK"` epilogue
    convention as its sibling `pac_corrupt_test_arm64` (bucket E) — no
    directive can add an arbitrary compiler flag to a generated compile
    step.

**E. Shell-wrapped, bespoke logic — 15.** `missing_file_test`,
`openssl_interop_test`, `compress_zlib_interop_test`,
`parser_generator_w_test`, `wtest_map_test`, `unsafe_import_test`,
`debug_test`, `debug_test_x64`, `attach_test`, `repl_test`,
`repl_test_x64`, `wasm_extern_test`, `wasm_webgl_test`, `pac_flag_test`,
`pac_corrupt_test_arm64`. Blocker: each step is a real `sh -c` one-liner
or external script (subprocess probing, ptrace attach, PTY scripting via
`script`, `grep`-based disassembly/flag checks) with no W-side
equivalent — see the shell-script table above for the specific porting
work each needs. The single largest concentration of genuine (non-
directive-gap) blockers in this inventory.

**F. `generate.exclude`: source is machine-generated — 2.**
`parser_generator_test` (compiles
`tests/parser_generator/generated_sample_test.w`), `parser_generator_c_test`
(compiles `tests/parser_generator/generated_c_parser_test.w`). Blocker:
the source is itself regenerated-and-diffed output of the parser
generator; a `# wbuild:` directive living in that file would be
clobbered on the next regeneration. Needs either the generating tool to
emit the directive into its output, or these stay hand-written
permanently as the generator's own self-test.

**G. `generate.exclude`: target name doesn't match source basename — 18.**
`crypto_base64_test`, `crypto_base64_64_test`, `crypto_random_test`,
`crypto_random_64_test`, `crypto_rsa_verify_test`,
`crypto_ecdsa_p256_test`, `net_asn1_test`, `net_x509_test`,
`net_tls_test`, `net_tls_server_test`, `net_darwin`, `graphics_math_test`,
`graphics_math_64_test`, `graphics_gl_smoke_test`, `graphics_darwin`,
`pac_darwin`, `extern_alias_test_x64`, `float_abi_test_x64`. Blocker:
`wbuildgen` derives a generated target's name from its source's own
basename (`X_test.w` → `X_test`); every target here compiles a source
whose basename doesn't match the desired target name (e.g.
`crypto_base64_test` compiles `libs/standard/crypto/base64_test.w`).
Needs a `name=` override directive in `wbuildgen` before these can
generate.

**Update (2026-07-19, wave 2b):** `wbuildgen` grew `# wbuild: name=<target>`
(overrides the basename-derived name — and the base every arch twin's
suffix rule derives from — for the whole source); 13 of the 18 migrated:
`crypto_base64_test`/`crypto_base64_64_test`, `crypto_random_test`/
`crypto_random_64_test`, `crypto_ecdsa_p256_test`, `graphics_math_test`/
`graphics_math_64_test` (plain `name=` [+ `x64`], unchanged shape), and
`crypto_rsa_verify_test`, `net_asn1_test`, `net_x509_test`,
`net_tls_test`, `net_tls_server_test` (these five bundled *both*
bitnesses' compile+run into one hand-written target under the legacy
`..._test_x64` binary-name style, not a separate target — `name=` + `x64`
now generates them as the two separate targets the rest of this bucket
already used, e.g. `net_asn1_test` + a new `net_asn1_64_test`,
joining `tests_x64` the same way `crypto_base64_64_test` already did;
verified byte-for-byte on the plain ones and behaviorally on the split
ones). Left hand-written, with reasons: **`graphics_gl_smoke_test`**,
**`extern_alias_test_x64`**, **`float_abi_test_x64`** — all three are
x64-*only* targets (no 32-bit variant is wanted, and for
`extern_alias_test_x64`/`float_abi_test_x64` no 32-bit variant has ever
existed or been vetted), but `wbuildgen`'s default-arch generation is
unconditional — it always emits a target under the (possibly
`name=`-overridden) basename at the default 32-bit arch unless
`build.base.json` already claims that exact name, with no directive to
say "this source is x64-only, skip the 32-bit default" (confirmed by
compiling `tests/x64_test.w` — one of bucket D's *own* x64-only-by-
convention targets — at the default arch: it compiles clean but the
binary exits 1 with no output, i.e. a real, silent behavior change, not
just redundant coverage). `float_abi_test_x64` additionally bundles
*three* unrelated source files
(`tests/float_abi_test.w`/`tests/x64_float_abi_test.w`/
`tests/x64_c_import_float_test.w`) into one target — bucket L's
multi-source-per-target gap, not bucket G's. **`net_darwin`**,
**`graphics_darwin`**, **`pac_darwin`** stay hand-written per the wave
plan's own hedge: `graphics_darwin`/`pac_darwin` each bundle 2-3 unrelated
source files into one target (same bucket L gap), and `net_darwin`,
though single-source, would collide with the same unconditional-default
problem above (`name=` would still generate an unwanted 32-bit
`tests/net_darwin_smoke_test.w` compile under the override name). Logged
as friction in `docs/projects/ai_tooling_next_steps.md`.

**H. Argv variant of an already-generated target — 1.**
`x25519_iterated_test` compiles the same source as the *also-generated*
`x25519_test` (`libs/standard/crypto/x25519_test.w`), just invoking the
binary with an extra `--iterated-1000` argument. Blocker: `wbuildgen`'s
generated run step never takes CLI arguments for the binary itself (only
`stdin=`/`expect_*=`); needs an `argv=` directive, or support for more
than one run step per generated target.

**Update (2026-07-19, wave 2b):** migrated. `wbuildgen` grew
`# wbuild: argv=<args>`: alone, it appends CLI arguments to every
run-capable twin's run step; paired with an equal, nonzero count of
`name=` directives, each pair instead defines one more default-arch-only
target from the same source (leaving that source's other generated
targets untouched) — `x25519_test.w` carries `# wbuild: name=
x25519_iterated_test argv=--iterated-1000` alongside its existing
`# wbuild: x64`, generating a byte-identical `x25519_iterated_test`
target next to the plain `x25519_test`/`x25519_64_test`.

**I. Compile-error fixture (the compile step itself must fail) — 1
(RESOLVED, wave 2c).** `int64_x86_error_test` (`expect_fail`/
`expect_stderr` on the *compile* step, not a run step). Was blocked on
`wbuildgen`'s directive-decorated run step only ever decorating the
compiled binary's run, never the compile step itself. Fixed with a new
`compile_fail` directive (`tools/wbuildgen.w`): the source declares
`# wbuild: compile_fail` plus `# wbuild: expect_stderr="..."`, and
wbuildgen decorates the compile step itself with `expect_fail`/
`expect_stderr` and skips run-step generation entirely.
`int64_x86_error_test` now generates from `tests/int64_x86_error_test.w`
instead of living hand-written in `build.base.json`.

**J. Outside `wbuildgen`'s scanned trees, or source doesn't end in
`_test.w` — 16.** `hello`, `test`, `grammar_test`, `type_table_test`,
`bignum_test`, `net_basic`, `win64_header_test`, `win64_hello_test`,
`win64_smoke_test`, `dynamic_test_win64`, `cuda_smoke`, `elf`,
`grapheme_data`, `net`, `simple`, `testing_ground`. Blocker: `wbuildgen`
only scans `tests/`, `lib/`, `structures/`, `graphics/`, `libs/`,
`tools/` for files literally named `*_test.w` (`grammar_test` and
`type_table_test`/`bignum_test` compile `grammar/` and `compiler/`
sources — outside the scan list entirely, deliberately, since
compiler-tree changes route through the `verify` residue rule instead);
the rest compile a real source that just isn't suffixed `_test.w`
(`tests/hello.w`, `tests/elf.w`, `tools/generate_grapheme_data.w`, ...).
No directive fixes this — it needs either a rename (churns any existing
references to the current name) or widening `wbuildgen`'s scan
convention past the `_test.w` suffix / six fixed trees.

**K. Needs an extra (non-`wv2`) target dependency — 18.**
`buffer_field_assign_test`, `array_error_test`, `syscall_arity_test`,
`int_literal_width_test`, `prefixed_string_literal_test`,
`warning_test`, `type_system_error_test`, `type_system_warning_test`,
`operator_overload_error_test` (all depend on `wfixture`), `manifest`,
`manifest_check` (depend on `wbuildgen`), `metadata_check` (depends on
`wmeta`), `wvdiff_test` (depends on `wvdiff`), `wvc_e2e_test` (depends
on `wvc`), `wexec_keep_going_test`, `wexec_ordered_output_test` (depend
on `wexec`), `wexec_remote_cache_test` (depends on `wexec`),
`asm_seed_gate` (`deps: []`, but compiles via the raw seed `./w`, never
`bin/wv2` — a second, distinct mismatch). Blocker: `wbuildgen`'s `deps=`
directive declares a non-W *data* file input (bucket recorded in the
generated target's `"data"` array), not an additional *target*
dependency; there is no directive today that can add `wfixture`/`wvc`/
`wexec`/... to a generated target's `deps` list alongside `wv2`. This is
the same "path-based deps" gap bucket C flagged from the tool-binary
side — solving it there (letting a target depend on a *file* instead of
a *name*) would likely retire this bucket too.

**Update (2026-07-19, wave plan C task 2d):** the path-based gap is
closed for the shape that already had a single-source compile-and-run
target — `# wbuild: tool=<path>` (resolved via a new
`wbg_find_target_by_source` scan over `build.base.json`, not a
hardcoded name table) and `# wbuild: fixture_group=<name>` (groups
several `tests/*_fixture.w` files into one generated `bin/wfixture`
invocation) together migrated 11 of this bucket's 18:
`buffer_field_assign_test`, `array_error_test`, `syscall_arity_test`,
`int_literal_width_test`, `prefixed_string_literal_test`,
`warning_test`, `type_system_error_test`, `type_system_warning_test`,
`operator_overload_error_test` (via `fixture_group=`) and
`wvc_e2e_test`, `wexec_remote_cache_test` (via a bare `tool=` — these
two turned out to already be conventional `_test.w` compile+run
targets with no shape gap at all beyond the missing "deps" entry).
Still hand-written, and *not* closed by this mechanism: `manifest`,
`manifest_check`, `metadata_check`, `wvdiff_test`,
`wexec_keep_going_test`, `wexec_ordered_output_test` compile nothing of
their own (they invoke a tool binary directly against fixture
data/manifests, so there is no `*_test.w` source for a directive to
live on — closing these needs a distinct "the whole target is one tool
invocation, no compile step" generation mode, an open design question,
not a directive gap); `asm_seed_gate`'s raw-seed mismatch is unrelated
to tool dependencies and needs its own compiler-selector fix. Bucket C
itself is unaffected by design — `wbg_find_target_by_source` resolves
*against* those 11 hand-written tool targets, it does not generate them
(none of them are `*_test.w`-shaped, so wbuildgen's scan never reaches
them either way).

**L. Multi-step pipelines — 42.** `float_reference_test`,
`string_utf8_test`, `container_trap_test`, `memory_debug_fault_test`,
`strict_mode_test`, `check_json_test`, `check_roots_test`,
`check_imports_test`, `symbols_test`, `deps_test`,
`self_host_warning_test`, `repl_warning_test`, `default_args_test`,
`varargs_w_test`, `dynamic_var_test`, `dynamic_var_64_test`,
`generics_test`, `generics_inference_test`, `compound_assign_test`,
`char_literal_test`, `script_mode_test`, `crypto_bignum_test`,
`https_e2e_test`, `switch_test`, `template_string_test`,
`for_container_test`, `generator_test`, `defer_test`, `import_test`,
`map_set_builtin_test`, `list_builtin_test`, `wtest_run_test`,
`metadata_test`, `wexec_test`, `result_propagate_test`, `task_io_test`,
`json_rpc_test`, `json_rpc_64_test`, `task_io_64_test`,
`asm_foundations_test`, `asm_arm64_test`, `asm_x64_test`. Blocker: each
chains more than a single compile+run — a second reference binary
(`float_reference_test`'s `cc`-compiled C oracle), several independent
diagnostic invocations with separate `expect_*` assertions
(`check_json_test`, `symbols_test`, ...), or several `.w` fixtures
compiled and run in sequence (`generator_test`, `switch_test`, ...).
`wbuildgen`'s directive vocabulary covers exactly one extra step today
(`extra_compile=`, default-arch only, always after the single run step);
these need a genuine N-step / multiple-run-step directive vocabulary
before they can generate — the highest-effort bucket to close after E.

### Reading this inventory

Buckets D (21, zero blocker — pure migration) and the arm64/wasm slice of
A/E (already using the shared runner scripts) are free wins independent
of any new tooling. Buckets C and K are two faces of the same "deps by
path, not by name" gap and are worth solving together. Bucket E (15) and
the Mac-only rows of the shell-script table are the genuinely hard
remainder — real logic with no W-side equivalent yet, not a manifest
expressiveness gap. Bucket L (42) is the single biggest lever: a
multi-step/multi-run directive vocabulary would clear roughly a quarter
of all hand-written targets in one design.
