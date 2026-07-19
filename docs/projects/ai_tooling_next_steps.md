# AI Tooling — next steps

A living backlog for the agent-facing toolchain surfaces in this repo
(`w check`, `w symbols`, `bin/wtest`, skills/rules). The implemented
baseline is documented in `docs/projects/ai_tooling.md`. The integrations
built on these surfaces (`wlsp`, the MCP servers, `windex`, the
edit-check hook) moved out of this repo in July 2026; their backlog
moved with them.

**How this file is maintained** (enforced by
`.cursor/rules/ai-tooling-feedback.mdc`): when an agent or contributor
using the tooling hits friction, a bug, or a missing capability, they add
a short entry here (symptom, where observed, suggested direction) in the
same PR. When an item ships, its summary moves to the status section of
`ai_tooling.md` and the entry is deleted here. Keep entries terse; this
is a queue, not an archive.

## Diagnostics (`w check`)

- **Shipped (2026-07-17): cross-line call-tail absorption now warns.**
  `postfix_expr`'s call tail warns `call arguments continue from the
  previous line` when its `(` opens on a different line than the
  expression it attaches to (`int b = 2` / `(a + b)++` no longer
  silently merges into `2(a + b)` with no diagnostic; still
  non-breaking — a same-line-only hard rule stays a future decision);
  fixtures `tests/cross_line_call_warning_fixture.w` and
  `tests/cross_line_call_increment_fixture.w`.
- **Multi-error reporting.** The compiler stops at the first error
  (single-pass, no recovery). Documented limitation; real fix is parser
  recovery, which stays a research project. Cheap partial win: after an
  error in file A, agents re-check to find errors behind it — nothing to
  build, just keep the limitation documented in skills.
- **Shipped (2026-07-17, wave 2f): the bool-bitwise condition hint is
  now on by default for every call-free join.** See `ai_tooling.md`'s
  status section for the shipped description; `--bool-ops` survives as
  the narrower "also report call-containing joins" superset (it used to
  gate the comparison-result widening itself, before the wave-2
  mechanical sweep converted every side-effect-free site tree-wide).
- **`w check --bool-ops`'s position/chain bugs — all three fixed**
  (2026-07-17, wave 2f; (1) fixed 2026-07-19, wave 1b). Consolidates
  four overlapping reports from wave-2 sweep chunks 2a/2b/2d/2e, all
  downstream of the same three bugs: (1) a warning inside an *imported*
  (non-root) file reported its line number +1 high (`debugger/
  memory.w:52` vs. actual line 51) — **fixed**: `compiler/compiler.w`'s
  `compile_save` saved `line_number + 1` instead of `line_number` before
  compiling the import and restored the inflated value on return, but
  that was only half of it — a paired defect meant the naive "just drop
  the `+ 1`" fix undercounted instead: `compile_attempt`'s priming
  `nextc = get_character()` call for the *new* file read the importer's
  still-pending lookahead (the unconsumed newline at the end of the
  `import ...` line) and spuriously bumped the freshly-reset
  `line_number` from 0 to 1 before the imported file's first byte was
  even read, while `compile_save` never saved/restored `nextc` itself,
  so the importer's own resumption silently lost the newline crossing
  it needed on the way back out. Fixed by resetting `nextc = 0` right
  before `compile_attempt`'s priming read (mirroring the existing
  `grammar/generic.w:generic_reparse_start` idiom for re-parsing a
  generic definition) and saving/restoring `nextc` in `compile_save`
  alongside `line_number` (now saved verbatim, no `+ 1`). Every
  diagnostic in every imported file across a full `check --bool-ops` of
  `w.w` shifted by exactly one line (135/135 sites, spot-checked against
  real source); regression pinned by `tests/imported_diagnostic_line_
  fixture.w` + `tests/imported_diagnostic_line_leaf.w` (`warning_test`),
  asserting both the imported file's own line and the importing file's
  post-import line stay exact. (2) the reported line/column was wherever
  the tokenizer's one-token
  lookahead sat once the *whole* condition finished parsing, not the
  `&`/`|` itself — **fixed**: `grammar/binary_op.w`'s
  `warn_bool_bitwise_at` snapshots `line_number`/`diag_token_line`/
  `diag_token_column`/`token` when `accept()`'s peek recognizes the
  operator, before consuming it moves the lookahead, and restores them
  around the `warning()` call. (3) a same-precedence chain of 3+ terms
  only ever flagged the first pairing, because
  `binary2_finish_pop`/`binary2_finish` return the untyped placeholder
  type `3`, erasing the fold's bool-ness before the next pairing's check
  ran — **fixed**: `bitwise_and_expr`/`bitwise_or_expr` now track
  `chain_is_bool`/`chain_is_pure` alongside the running fold instead of
  re-deriving them from the (erased) type, so every qualifying pairing
  gets its own diagnostic (`tests/bool_bitwise_chain_fixture.w` pins two
  distinct positions for a 3-term chain). The precedence-grouping
  observation from the original reports still holds — converting a
  join can newly expose the next fold in a chain as bool-vs-bool — but
  no longer needs a re-enumeration pass to catch: the default hint now
  walks the whole chain in one `check` pass.
- **`T* + int` is a raw, unscaled byte offset for every pointee width,
  and nothing warns — the rule is now documented, and the ergonomic
  intrinsic half has shipped; the warning half has not.** Found
  2026-07-16 writing `libs/extras/compress/
  inflate.w`'s dynamic-Huffman block decoder: `wh_build(c, dist_huff,
  lengths + hlit, hdist)` (where `lengths` is `int*`) added `hlit`
  *bytes* to the pointer, not `hlit` ints — landing 4 (or 8, on x64)
  times too close to the start of the array on every word size, so the
  distance-code Huffman table silently built from the wrong slice.
  `./bin/wv2 check` reports nothing (it is well-typed: `int* + int ->
  int*`); the bug only surfaced as a runtime
  over-subscribed/incomplete-Huffman-table failure, and only for inputs
  exercising that exact code path (fixed-Huffman and simple dynamic
  blocks with `hlit`/small offsets near zero happened to still work).
  `lib/sha256.w` and every other manual-pointer-arithmetic call site in
  the tree already route around this by treating every pointer as
  `char*` and multiplying the index by the element size by hand
  (`p + i * 4`), which works but has no compiler backing — a typed
  `int*`/struct-pointer `+` is silently just as wrong as a `char*` one
  with a forgotten `* width`. `a[i]`/`&a[i]` *do* scale correctly (this
  is what made the bug non-obvious: indexing and "pointer plus offset"
  look interchangeable but are not). README.md/CLAUDE.md now document
  the rule explicitly (2026-07-17), citing `lib/sha256.w`'s `p + i * 4`
  idiom above. **Shipped (2026-07-19):** `lib/ptr.w`'s
  `ptr_add[T](p, n)` — a generic function, `return &p[n]`, so it
  inherits the compiler's already-correct indexing scale for any `T`
  with no `sizeof`/`__word_size__` bookkeeping needed in the caller —
  plus `ptr_diff[T]`, covered by `tests/ptr_add_test.w`
  (int/char/struct pointees, negative offsets, an explicit assertion
  that `ptr_add` and raw `p + n` disagree). The exemplar `inflate.w`
  bug site and two similar `char*` call sites in
  `libs/extras/compress/{inflate,deflate}.w` now use `&p[n]` directly.
  Still open: `./bin/wv2 check` still reports nothing on the raw `T* +
  int` form itself — a `w check` warning on
  `<non-char-pointer> + <int-not-a-multiple-of-known-stride>` is
  unrealizable statically in general, and nothing stops new code from
  writing `p + n` instead of reaching for `ptr_add`/`&p[n]`. The footgun
  is now avoidable, not eliminated.

- **No warning when an import breaks a different compile target.**
  `tools/wexec.w` is compiled three ways (default `x86`, `win64`,
  `arm64_darwin`); adding `import libs.standard.web.http_client` (for
  the shared build-cache client, issue #251 D3-2) compiled clean under
  the default `w check` but failed only `win64`'s build ("Cannot find
  symbol: 'sys_socket'" — `lib.net` has no
  `lib/__arch__/win64/syscalls.w` socket implementation) — caught only
  by `wtest changed`'s import-closure selection flagging `wexec_win`
  as impacted, then building it explicitly. `w check` has no
  "check every arch this file's closures actually get compiled under"
  mode, so an arch-incompatible import in a multi-target tool stays
  invisible until that target's next full build. Worked around here
  with a `tools/__arch__/<arch>/wexec_remote_http.w` shim (the same
  pattern `libs/extras/vcs/__arch__/` already uses for its own
  win64/wasm networking gap) isolating the actual HTTP calls behind
  per-arch resolution, with a win64 stub that always reports a
  transport failure so the feature degrades to "unavailable" instead
  of "won't compile" (2026-07-16). (scheduled: wave plan C task 3e)
## Test selection (`bin/wtest`)

- **First `wtest changed` after a build can take well over the
  documented ~35s.** Building `libs/extras/vcs/merge3.w` (issue #252
  wave 4), `git diff --name-only HEAD | ./bin/wtest changed` timed out
  at the default 2-minute tool timeout on its first run (cold
  `bin/.wtest_deps_cache`) against this tree's current size; a retry
  with a longer timeout completed and printed the expected selection.
  README/AGENTS.md's "~35s" figure is stale for a repo this size (or
  this was host-specific slowness) -- agents should budget several
  minutes (not the 2-minute tool default) for the FIRST post-build
  `wtest changed` invocation, same as any other cold-cache step.
## Build manifest (`tools/wbuildgen.w`)

Friction found migrating bucket D of `build_system_next.md`'s hand-written
`build.base.json` inventory (wave plan C task 2a) — 11 of 21 targets
migrated cleanly, 10 turned out to need directive vocabulary that doesn't
exist yet:

- **No way to say "this basename is arch-only"**: a source like
  `tests/x64_test.w` whose desired target name already equals its
  basename-derived name (`x64_test`) but which must compile with the
  `x64` selector (some use `float64`, rejected on 32-bit words) can't
  migrate — `wbg_scan` unconditionally also generates a *default* 32-bit
  twin under that same name (no directive suppresses or redirects it),
  and `generate.exclude` skips the whole file, twins included, so it
  can't be combined with a directive either. Blocks `x64_test`,
  `x64_float_test`, `x64_fmath64_test`, `x64_ndarray64_test`,
  `x64_int64_test`, `x64_map_float64_test`. Needs a `name=` override (or
  an explicit "no default twin" flag) — natural to fold into task 2b's
  `name=` directive work.
- **`deps=` rejects any `.w`-suffixed value even when the file is
  consumed as runtime text, not imported.** `asm_stubs_test.w` reads
  `code_generator/{x86,x64,arm64}_asm.w` as data via
  `asm_stub_check(path, path)`, not `import` — but `wbg_apply_directive`
  hard-rejects any `deps=` value ending in `.w` on the assumption
  "imports already track it". No directive can express this target's
  real input set today; it stays hand-written.
- **`deps=`'s "data" field is wtest-selection-only, not a cache-key
  field** — easy to miss. Hand-written targets get real caching via a
  separate `"inputs"` array (`tools/wexec.w`'s `wexec_cache_key`); the
  generated-target path (`wbg_make_target`) never emits `"inputs"` at
  all, `deps=` only populates `"data"` (consumed solely by
  `tools/test_map.w`'s rule (a) for `wtest changed` selection). Migrating
  a hand-written target that declared `"inputs"` for caching (e.g.
  `asm_x86_disasm_test`/`asm_x86_asm_test`, which read `tests/asm/` at
  runtime) silently turns it into a FORCE target (always reruns) with no
  diagnostic — matches the existing behavior of ~430 other generated
  targets that also lack `"inputs"`, so it's a minor loss, but worth a
  generated-target `"inputs"`-equivalent (or at least a note in
  `--explain-cache`) if build-time caching for generated targets is ever
  wanted.
- **No directive for a multi-program aggregate target, extra compiler
  flags on a generated compile step, or a `wasm` arch value.** Blocks
  `arm64_smoke_test`/`wasm_smoke_test` (each is 5-9 programs compiled,
  run, and summarized by one shared `echo "... OK"` epilogue — not the
  single `(source, arch)` shape `wbg_make_target` ever produces) and
  `pac_full_test_arm64` (needs `--pac=full` injected into the arm64
  compile command, which no directive can add). `wasm_smoke_test` is
  additionally blocked because `wbg_apply_directive`'s `arch=` only
  recognizes `x64`/`arm64`/`win64`/`arm64_darwin` — no `wasm` value
  exists at all.

## Definition hashing (`w defhash`)

- **Shipped (2026-07-19, wave plan C task 2g): `wtest --defhash` opt-in
  refinement.** `tools/test_map.w`'s rule (b) now accepts `--defhash`
  (`changed` and `for` both take it): per changed `.w` path it shells out
  to `bin/wv2 defhash` on the worktree copy and on `git show
  HEAD:<path>` (staged to `bin/.wtest_defhash_head.w`), and skips that
  path's import-closure additions when the recorded definition name set
  and every name's hash come back identical — rule (a) literals and the
  rule (c) residue mappings (`parser_generator_w_test`, `metadata_check`,
  ...) still apply, so a comment/formatting-only edit just stops
  recommending every importer. Fails open in every other case (a path
  new to HEAD, a git/defhash error, a real definition change) — see
  `wtest_defhash_unchanged`. The documented generic/operator blind spot
  (below) is handled by a dedicated pre-check, `wtest_defhash_risky_text`:
  a whole-word scan for `operator` plus a scan for an identifier
  immediately followed by a bracket whose comma-separated contents are
  all-uppercase-led names (this codebase's own type-parameter convention,
  `T` / `K, V` — every real type name here is lowercase snake_case, so it
  never matches an ordinary container instantiation or array index); a
  hit on either version of the file falls back to the ordinary scan for
  that path instead of risking a false "unchanged". It is a textual
  stand-in, not a parse, so it may over-fire (safe) but must never
  under-fire; task 4f's defhash coverage extension would let this drop
  entirely. Selection without `--defhash` is unchanged byte-for-byte
  (checked directly: the original `tools/test_map.w` and the new one
  produce identical `wtest changed` output on the same inputs when the
  flag is not passed). Tested by `tools/wtest_defhash_scratch_test.sh`
  (`wtest_defhash_test`, `build.base.json`) — a throwaway `git init` repo
  (symlinking in
  `bin/wv2`/`bin/wtest` and the `lib`/`structures`/`code_generator` trees
  every compile needs) exercising real HEAD-vs-worktree comparisons: a
  comment-only edit is skipped, a real edit and a generic-shaped file are
  not. Not extended: `tests/wtest/map_expectations.expect`'s cases run
  against this repo's own ambient git state, which is not deterministic
  for a feature whose answer depends on HEAD-vs-worktree diffs, so it
  stays scratch-repo-only rather than risking a flaky case there.
- `--closure`'s ref resolution is a linear scan over every recorded
  definition per identifier token (`defhash_is_known_definition`,
  `compiler/compiler.w`) -- fine at file scope or even this repo's full
  `lib.lib` closure (~360 definitions, well under a second), but would
  need a hash-table lookup if `--closure` is ever run over something an
  order of magnitude bigger (e.g. wired into `wexec` cache keys per
  D4a's stretch goal).
- Generic struct/function definitions and `operator` overloads are
  invisible to `defhash` on purpose: the scan-ahead/re-parse machinery
  those go through (`grammar/generic.w`, `grammar/operator_overload.w`)
  never reaches `defhash_note`'s call sites. Extending coverage to them
  would mean threading defhash bookkeeping through that machinery too --
  left as a follow-up since ordinary functions/globals/aggregates are
  the common case.

## Build manifest (`wbuildgen`)

- **Shipped (2026-07-19, wave plan C task 2d): path-based target deps.**
  `# wbuild: tool=<path>` resolves a tool's own `.w` source (e.g.
  "tools/wvc.w") to the name of the existing `build.base.json` target
  that compiles it and adds it to a generated target's "deps" alongside
  "wv2" (`wbg_find_target_by_source`/`wbg_resolve_tool_name`,
  `tools/wbuildgen.w`); `# wbuild: fixture_group=<name>` groups several
  `tests/*_fixture.w` files sharing a group name into one generated
  `bin/wfixture` invocation. Migrated 11 of `build_system_next.md`'s
  bucket K (18): the 9 wfixture-driven targets (`buffer_field_assign_test`,
  `array_error_test`, `syscall_arity_test`, `int_literal_width_test`,
  `prefixed_string_literal_test`, `warning_test`, `type_system_error_test`,
  `type_system_warning_test`, `operator_overload_error_test`) via
  `fixture_group=`, plus `wvc_e2e_test`/`wexec_remote_cache_test` via a
  bare `tool=` directive on their existing conventional `_test.w`
  sources (these two needed no new generation mode at all — they were
  already single-source compile+run shaped; the missing "deps" entry
  was the *only* blocker, which is exactly bucket K's own framing of
  the gap). Fixture-group member order is alphabetical by path, not the
  hand-picked order some base targets had; verified behavior-preserving
  (each fixture's pass/fail is independent, wfixture's exit status is
  an aggregate) by diffing generated vs. committed JSON before merging.
- **Open: the rest of bucket C/K has no compile-and-run shape at all.**
  `manifest`/`manifest_check` (invoke `bin/wbuildgen` directly),
  `metadata_check` (`bin/wmeta check package.wmeta`), `wvdiff_test`
  (`bin/wvdiff` over fixture text files), `wexec_keep_going_test`/
  `wexec_ordered_output_test` (`bin/wexec` over fixture JSON manifests)
  compile nothing themselves — there is no `*_test.w` source for a
  directive to live on, so `tool=`/`fixture_group=` can't reach them.
  Bucket C itself (the 11 tool binaries: `wtest`, `wbuildgen`,
  `wfixture`, `wtest_map_check`, `wmeta`, `wvdiff`, `wvc`, `wdbg`,
  `wdbg_x64`, `gen_stubs`, `rewrite_c_strings`) stays hand-written by
  design — `wbg_find_target_by_source` resolves *against* these, it
  doesn't generate them (they aren't `*_test.w`-shaped). `asm_seed_gate`
  is a distinct mismatch (`deps: []`, compiles via the raw seed `./w`,
  never `bin/wv2`) that a compiler-selector directive would fix, not a
  tool-dependency one. Closing these would need a new "invoke a tool
  as the whole target, no compile step" generation mode — a real design
  decision (what source/marker would such a target even scan for?),
  left open per the task's "enumerate, don't migrate" scope.

## Cleanup observed while dogfooding

- **`wbuildgen` can't express "this source's default-arch target is
  x64-only, don't also generate an unwanted 32-bit twin"** (wave 2b,
  bucket G migration). `wbg_scan`'s default-arch generation is
  unconditional: it always emits a target under the source's
  (`name=`-overridden or not) basename at the 32-bit default arch unless
  `build.base.json` already claims that exact name — there is no
  directive to opt a source *out* of the 32-bit default while still
  generating an x64 twin under the plain (non-`_64_test`-suffixed) name.
  Confirmed as a real behavior gap, not just redundant coverage: compiling
  `tests/x64_test.w` (bucket D, hand-written today as x64-only under its
  own basename) at the default arch builds clean but the binary silently
  exits 1 with no output. Blocks migrating `graphics_gl_smoke_test`,
  `extern_alias_test_x64`, `float_abi_test_x64` (bucket G) and bucket D's
  whole `x64_test`/`x64_float_test`/... family the same way — left
  hand-written, see `build_system_next.md`'s bucket G update. Fix would be
  a directive like `arch_only=x64` (or reusing `arch=x64` to mean "this
  IS the default" when no other arch is requested) that suppresses the
  unconditional 32-bit generation for that source.
- **`wexec_resolve_program` (tools/wexec.w) resolves a bare command name
  to the first *readable* file on `PATH`, not the first *executable*
  one — a manifest step naming `"env"` failed with a bare "command
  failed with exit status 127" while writing wave 1f's `wexec_lock_test`
  (2026-07-19), even though `/usr/bin/env` was on `PATH`: this sandbox
  also has a non-executable `~/.local/bin/env` (a `pyvenv`-style config
  file, `-rw-r--r--`) earlier in `PATH`, and `wexec_resolve_program`'s
  loop treats `open(candidate, O_RDONLY, 0) >= 0` as "found" without
  ever checking the executable bit, so it silently resolves to that file
  and `execve()` on it fails — with no diagnostic pointing at *why*
  (exit 127 alone looks identical to "not found anywhere"). Worked
  around in that test by using `sh -c "unset VAR; exec cmd..."` instead
  of `env -u VAR cmd`. Not fixed here (out of scope for wave 1f, and
  every other `PATH`-resolved command name already used across
  `build.base.json` — `diff`, `cmp`, `grep`, `timeout`, `wine`, ... —
  happens not to collide with a same-named non-executable file on any
  tested host, so this is latent rather than currently breaking a real
  target). Real fix: check the executable bit (or `access(path, X_OK)`)
  in the `PATH` search loop, and ideally have the exit-127 path name the
  resolved-but-unusable candidate instead of just "exit status 127".
- **Test sources can assert on their own raw bytes.** `defer_test.w`'s
  `test_defer_closes_file_descriptor` asserts the first byte of
  `tests/defer_test.w` is the `'i'` of `import`, so prepending the new
  `# wbuild: x64` manifest directive as line 1 broke it at runtime while
  every compile stayed clean (2026-07-10, manifest-generation
  migration; the directive lives on line 2 there now). When a tool
  rewrites test sources en masse, grep the touched files for their own
  paths first; longer term, self-referential assertions should read a
  dedicated fixture instead of the test's own source.
- **`lib/args.w` boolean flags swallow the next positional.** A bare
  `-f` / `--nofollow` before a path is treated as a valued flag, so
  `stat -f path` never sees `path` as positional (documented in
  `lib/args.w`'s header). `tools/{stat,readlink}.w` work around this
  with a hand-rolled argv walk; a real fix is either a
  `args_has_bool_flag` that does not consume the next token, or a
  convention/API for declaring boolean flag names up front. (scheduled:
  wave plan C task 1e)
- **wexec directory hashing is Linux-layout only.** Found while porting
  the darwin triad: `wexec_collect_dir` (tools/wexec.w) parses the Linux
  getdents record layout, so on macOS — where the `getdents` shim
  returns raw Darwin `getdirentries64` records (see the NOTE in
  `lib/__arch__/arm64_darwin/syscalls.w`) — a directory input silently
  hashes as an empty file list. The darwin build targets therefore
  declare no directory `"inputs"` (FORCE-style, always run). To unlock
  content-hash caching on macOS, add per-arch dirent accessors
  (`reclen`/`name`/`kind`) next to each `getdents` shim in
  `lib/__arch__/*/syscalls.w` and use them from `wexec_collect_dir`.
- **`getchar()`/`getchar_unbuffered()` conflate a genuine `read()` error
  with EOF** (`lib/lib.w`). A mid-file I/O failure looks like silent
  truncation (or a misleadingly-positioned parse error) instead of a
  diagnostic; fixing needs a distinct "read error" sentinel plumbed
  through `get_character()`/`compile_attempt()`/etc. Rare in practice (a
  `read()` on an already-`open()`ed regular local file essentially never
  fails) — documented, not scheduled.
- **Shipped (2026-07-19, wave plan C task 1c): `lib/generator.w`'s
  `__w_gen_create` coroutine-stack `mmap()` is now checked** —
  `__w_gen_mmap_failed()` mirrors `debug_tbl_mmap_failed()`'s convention;
  on failure prints `generator: out of memory (coroutine stack mmap
  failed)` and exits 1. No fixture (needs real memory exhaustion, same
  precedent as 35ed0f5).
- **Shipped (2026-07-19, wave plan C task 2h): recursion-depth guards
  close the last silent-`SIGSEGV` gap.** Two independent counters
  (`compiler/tokenizer.w`) catch runaway recursive-descent nesting before
  the parser's own call stack overflows: `expr_nesting_depth`, checked in
  `grammar/primary_expr.w`'s `'('` branch (the only place paren-grouping
  re-enters `expression()`, the top of the expression grammar), errors
  `expression nesting too deep` past 1000 levels; `stmt_nesting_depth`,
  wrapping the whole body of `grammar/statement.w`'s `statement()` (the
  single function every nested `{...}`/`:`-block/if/while/for/switch body
  recurses back through, so one guard there covers every statement-level
  recursion path), errors `statement nesting too deep` past 200. Both
  route through the normal `error()` path (works under `--json`, and
  unwinds a REPL recovery longjmp correctly) and reset to 0 at the start
  of every compile (`compiler/compiler.w`'s `compile_attempt`) and every
  REPL entry (`repl/core.w`'s `repl_compile_entry`), so a longjmp — which
  skips every pending decrement — can never poison the next compile/entry
  with a stale count. Manually confirmed: a 100000-deep nested-paren file
  that previously `SIGSEGV`'d now exits 1 with the diagnostic, both in
  plain and `--json` mode; a native paren-chain crash was measured
  between 40000 and 60000 levels deep before this change, so 1000 leaves
  large headroom. Fixtures: `tests/expression_nesting_{error,clean}_
  fixture.w` (1500 vs. 900 nested parens) and `tests/statement_nesting_
  {error,clean}_fixture.w` (220 vs. 150 branches of an `if`/`else if`
  chain — see the next entry for why the exact numbers matter), wired
  into the new `recursion_depth_test` target via `bin/wfixture`.
  `parser_generator_w_test` was checked against both new fixtures
  (`tests/parser_generator/w.pg` untouched — no new syntax) and stayed
  green with no depth-related PG issues found.
- **Found while shipping the above: `code_generator/x86.w`'s
  `ctrl_kind_stack`/`ctrl_val_stack` are fixed `int[256]` arrays, and
  nested control-flow statements can already exhaust them well short of
  any real call-stack limit.** Every open `if`/`while`/`for`/`switch`
  region holds one array slot (two, for an `if`, until its `else` arm
  starts) until it closes, so *true* nested bodies (an `if` whose body is
  another `if`, etc.) hit the array's bound at 129 nested `if`s (2 slots
  each) or 86 nested `for`s (3 slots each); an `if`/`else if` dispatch
  chain — which recurses `grammar/statement.w`'s `statement()` through
  the `else` arm exactly like true nesting, but only holds ~1 slot per
  branch since each branch's own second slot frees before the next
  `else` is parsed — survives to 255 branches, failing at 256 (all
  measured exactly). This is *why* task 2h's `stmt_nesting_depth` limit
  is 200 rather than a rounder, larger number: it has to clear the tree's
  longest legitimate chain (`lib/lib.w`'s errno-to-string dispatch, 132
  branches) while staying under 256, so it cannot also preempt the
  narrower 129/86 bounds for genuinely nested (non-chain) control flow —
  those two shapes still hit the pre-existing array bound first, which
  prints a real (if compiler-internal-looking) diagnostic via
  `__w_bounds_trap`/`__w_list_index_trap` — `index out of range: index
  256, length 256` plus a stack trace — rather than segfaulting silently,
  so it is not the same class of bug 2h closes, just a related, narrower
  gap. Real fix: make `ctrl_kind_stack`/`ctrl_val_stack` grow dynamically
  (or move them off a fixed-size array entirely) instead of picking a
  bigger constant.
- **Found while shipping 2h: piping a very long single line (10000+
  characters) containing deeply nested parens into the interactive REPL
  (`bin/repl < file`, no PTY) does not reliably reach the second REPL
  entry.** A 5000-deep nested-paren one-liner followed by further entries
  on their own lines: the nesting-too-deep diagnostic printed correctly,
  but the entries after it were never evaluated and the process exited
  0 instead of running them. Narrowed to the combination of extreme line
  length and deep nesting specifically — a plain long line (3000 `+`-
  joined terms, no nesting) recovers and evaluates the next entry
  normally, and a shorter deep-paren line (1100 levels, ~2200 characters,
  still past the 1000-level guard) also recovers correctly. Likely the
  REPL's own interactive line reader (distinct from the compiler's
  grammar-level recursion `compiler/tokenizer.w`'s counters guard)
  buffers or re-scans raw input in a way that behaves differently at
  that combined size; not investigated further since it falls outside a
  piped, non-PTY invocation `repl_test`'s `script -qc` fixtures don't
  exercise this exact shape either. Worth a closer look before relying on
  giant single-line REPL input in agent tooling.
- **Shipped (2026-07-19, wave plan C task 1g): unrecognized CLI flags
  now get a real diagnostic.** `link_impl`'s flag loop (the common tail
  for link/check/deps/symbols/defhash) errors `unrecognized option:
  '<arg>'` and exits 1 for any unknown `-`-prefixed argument instead of
  treating it as an input filename; pinned by
  `unrecognized_option_test` (which also guards that `--bounds=off`
  still parses as a flag).
- **`lib/process.w`'s `process_run`/`process_run_windows` take `stdin_text`
  as a `char*` and compute its length with `strlen`, so a subprocess
  input containing an embedded `0x00` byte silently truncates at that
  byte instead of being written in full — stdout/stderr capture is fine
  (`process_capture_read` tracks byte counts, not a C string), only the
  *write* side has this gap. Not hit by wave plan C task 2e's zlib/gzip
  interop port (`tests/compress_zlib_interop.w`): that harness passes
  binary compressed bytes through scratch files instead of subprocess
  stdin/argv specifically to sidestep this (and to avoid interpolating
  bytes into a spawned script's source text at all). Worth fixing before
  any future harness needs to *pipe* binary data into a child process
  (a length-taking `process_run_bytes(path, argv, opts, char* stdin,
  int stdin_length, timeout_ms)` twin, or an overload, would cover it).

## ParserGenerator streaming codegen (`libs/extras/parser_generator/`)

- **A pre-existing (milestone 2/3, not milestone-4-specific) crash in the
  streaming-mode emitter**: a rule with two alternatives sharing a
  factorable leading term, where the *longer* alternative's suffix (after
  the shared prefix) is nullable but non-empty and the *shorter*
  alternative's suffix is the true empty/epsilon case, segfaults
  `pg_generate_parser` instead of either generating correctly or being
  rejected by `pg_streaming_check`. Root cause: `analysis.w`'s
  `pg_report_choice` exempts a unit from the pairwise overlap check when
  it is the *empty*-suffix unit (`pg_report_unit_is_empty_suffix`) — sound
  on its own — but the *other* (nullable, non-empty) unit in the pair
  never gets its own guard (`pg_plan_unit_guard` bails on any nullable
  suffix, per `pg_analysis_terms_guardable`), so `pg_streaming_check`
  reports 0 conflicts for the rule (the empty-suffix exemption hides the
  only pairing that would have flagged it) while `pg_emit_streaming_choice`
  still needs *some* guard condition for that now-"committed" nullable
  unit and finds `guard_set == 0`, indexing through it in
  `pg_emit_kind_set_test`. Minimal repro (no actions/predicates involved
  at all — confirmed independent of this milestone's changes):
  `parser edge_probe\nmode streaming\ntoken IDENT letters\ntoken WS
  spaces\nstart value\nrule value = IDENT WS? | IDENT\n` segfaults
  `pg_generate_parser`. Not hit by any grammar in the tree today (`w.pg`
  stays AST mode; `streaming_sample.pg` and this milestone's
  `actions_sample.pg` were deliberately checked against this shape and
  avoid it), so it did not block milestone 4, but any future streaming
  grammar with a shared prefix followed by a nullable (not flatly empty)
  continuation on one side will hit it. Fix likely belongs in
  `pg_plan_unit_guard`/`pg_report_choice`: either also require the
  *nullable* side of such a pairing to be the trailing/last unit before
  granting the empty-suffix exemption, or treat "nullable, non-empty,
  unguardable" units as a `pg_streaming_check` violation in their own
  right rather than silently falling through to codegen.

## REPL surface (`repl.w`, consumed by wtools' `repl_eval` and skills)

- **A `:save`d session transcript is not always a valid standalone `.w`
  file.** Found while adding `:save`/`:load`/`:type`/`:time`/`:reset`/
  `:symbols` colon-commands (issue #276 P2, 2026-07-16). `int x = 5` is
  valid at the REPL (`repl_entry_item` in `repl/core.w` special-cases a
  top-level "name = expression" into a declaration plus an assignment
  compiled into the entry function) but the same line rejected standalone
  — `./bin/wv2 check --json` on a file containing a bare `int x = 5;` at
  file scope fails with `Could not find a valid primary expression, token:
  =`, because ordinary top-level globals may only be declared, not
  initialized inline (initialization has to happen inside a function).
  Since almost every REPL session declares variables this way, `:save`ing
  a typical session and then `:load`ing it back (or compiling it with
  `bin/wv2`) does not round-trip. Either teach top-level declarations to
  accept `= expr` as sugar for "declare, then assign in an implicit init
  function" (mirroring what the REPL already does), or document the
  asymmetry in `:help`/the REPL skill so agents don't rely on `:save`
  output being directly compilable.

- **`string_free(b)` immediately followed by `free(b)` on the same
  `string_builder*` corrupted the heap, but only inside `repl.w`'s full
  startup context.** Found while adding the `--json` NDJSON mode (issue
  #276 P3, 2026-07-16): `repl_eval_json`'s helper built a `string_builder`,
  read a captured-output file into it, then did the textbook-looking
  `char* result = strclone(b.data); string_free(b); free(b); return
  result;` — the very next `json_object()`/`json_object_set()` call in the
  caller would then see a `json_value*` with a garbage `.type` field, or
  segfault outright on a later `malloc`/`free`. Confirmed via bisection
  across ~40 throwaway repro programs: (1) not reproducible standalone —
  a tight loop of `string_new()` + `string_append` + `string_free` +
  `free` in isolation (`structures.string` + `lib.lib` only) never
  corrupts; (2) reproducible once the program links `repl.w`'s full import
  set (`repl.core`, `debugger.wdbg`, `lib.shell`, etc.), calls
  `repl_init()` + the wdbg trap-handler install, and runs at least one
  `repl_eval()` before the `string_free`+`free` pair — the surrounding fd
  save/restore dance (`dup2`) and echo-hook wiring were *not* required
  once that much was present, so the trigger is somewhere in the
  interaction between `repl_eval`'s in-process JIT machinery (or the
  debugger/fault-handler setup) and the general-purpose allocator, not in
  `string_free`/`repl.w`'s own logic. Workaround applied in `repl.w`
  (`repl_format_echo`'s string-typed echo case and
  `repl_json_read_capture`): skip `string_free` and just take `b.data`
  directly before `free(b)` — the same ownership-transfer idiom
  `string_builder_to_string`/`__w_template_finish` already use, which
  sidesteps the bug entirely and needed no extra allocation. Every other
  `string_free(x); free(y)` pair in the tree already frees two *different*
  pointers (builder vs. some unrelated buffer); grepping confirms `repl.w`
  was the only place calling `string_free(b); free(b)` on the same `b`.
  Root-caused 2026-07-18 (`docs/projects/repl_allocator_interaction.md`):
  no REPL/JIT dependency at all — `string_free(b)` already frees `b`
  itself, so the pair is a plain double free, and `lib/memory_freelist.w`
  has no double-free detection, so the second `free()` corrupts that size
  class's free list into a permanent self-loop that aliases every later
  allocation of a matching size onto the same address (reproduced
  standalone with raw `malloc`/`free`, no `repl.w` imports). The doc
  covers why the earlier bisection looked REPL-specific, rules out the
  signal-handler and checkpoint/rollback hypotheses with citations, and
  recommends `W_DEBUG_ALLOC=1` for catching this class of bug in the
  future rather than hardening the production allocator under a timebox.

## Skills / rules upkeep

- Keep skill command examples in sync with CLI changes (they are
  hand-verified snapshots, nothing asserts them). A cheap
  `skills_test` that greps the documented flags against `--help` output
  would catch drift once the compiler grows a help text.
- Candidate new skills as workflows stabilize: ARM64 testing under
  `qemu-aarch64` (see `docs/projects/arm64.md`), seed updates
  (`./wbuild update` discipline), and C interop debugging (`c_import`).
