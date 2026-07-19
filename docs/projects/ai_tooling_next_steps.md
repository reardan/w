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
  and nothing warns — the rule is now documented, the warning/intrinsic
  is not.** Found 2026-07-16 writing `libs/extras/compress/
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
  idiom above. Still open: a `w check` warning on
  `<non-char-pointer> + <int-not-a-multiple-of-known-stride>` is
  unrealizable statically in general, but a `ptr_add(p, n)`-style
  intrinsic that scales by `__word_size__`/`sizeof` (or a real `&p[n]`
  desugar recommended in library code instead of `p + n`) would remove
  the footgun entirely rather than documenting around it.

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
  of "won't compile" (2026-07-16).
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
- **Two `./wbuild`/`wexec` invocations racing in the same worktree
  corrupt each other's build with no useful diagnostic.** Hit while
  gating the `stream_peek_byte` fix (#331 follow-up): a backgrounded
  `./wbuild test_changed` rerun (started to grep its output for
  failures rather than re-scrolling a long transcript) was still
  compiling when a foreground `./wbuild verify` started in the same
  worktree; the seed-stage compile failed with a bare "could not open
  output file" and a stack trace pointing at `compiler.w`'s `link`
  (both processes were writing/executing the same `bin/wv2`). Not a
  compiler or `wexec` bug -- `bin/` has no lock file, so nothing stops
  two invocations from racing there. Agents should treat a worktree's
  `bin/` as single-writer: never background a `./wbuild`/`wexec` call
  and start another in the same worktree before confirming (via
  `pgrep -f` scoped to the worktree's `bin/`, or just waiting for the
  first command's own completion) that it has actually finished.

## Definition hashing (`w defhash`)

- **Shipped (2026-07-18, issue #251 D4a): `wv2 defhash [--closure]
  <file.w>...`** emits one NDJSON record per top-level definition
  (function, global, struct/union/enum, type alias) declared directly in
  the root file(s) -- `{"file", "name", "kind", "hash", "refs"}` -- with
  `hash` a sha256 over the definition's own token stream (whitespace and
  comments excluded, so reformatting/comment edits leave it unchanged)
  and `refs` the other recorded definitions' names it references.
  `--closure` widens scope to the whole compiled program (matching
  `deps`'s closure). `bin/wtest`'s `changed`/`for` selection does **not**
  consume this yet -- it still selects on file-level import closures, so
  a comment-only edit to a `lib/` file still selects every importing
  target, not just the file's own residue rules (`metadata_check`, etc).
  Wiring an opt-in `--defhash` refinement into `tools/test_map.w`'s rule
  (b) (see its header comment) is the natural next step: for a changed
  `.w` file, shell out to `bin/wv2 defhash` on both `git show HEAD:<path>`
  and the worktree copy, and skip adding import-closure targets when
  every recorded name's hash (and the name set itself) is unchanged.
  Left undone here deliberately (partial-preferred: a solid, tested mode
  beats a rushed, under-tested change to shared test-selection
  infrastructure) -- `tests/wtest/map_expectations.expect` and
  `wtest_map_test`/`wtest_run_test` (`build.base.json`) are the patterns
  to follow, including the `-f <manifest.json>` synthetic-manifest
  trick and the `cd bin && ./wtest ...` trick for exercising behavior
  outside a git repo; a self-contained `git init`-in-a-scratch-dir `sh
  -c` step is the cleanest way to test the HEAD-vs-worktree comparison
  without touching this repo's own history.
- `--closure`'s ref resolution is a linear scan over every recorded
  definition per identifier token (`defhash_is_known_definition`,
  `compiler/compiler.w`) -- fine at file scope or even this repo's full
  `lib.lib` closure (~360 definitions, well under a second), but would
  need a hash-table lookup if `--closure` is ever run over something an
  order of magnitude bigger (e.g. wired into `wexec` cache keys per
  D4a's stretch goal).
- `refs` is a token-text match against the recorded definition-name set,
  not real scope resolution: a struct/union field name or enum constant
  that happens to share text with another top-level definition reads as
  a false-positive reference, and a local/parameter shadowing another
  definition's name is not special-cased either. Documented in
  `defhash_main`'s doc comment in `compiler/compiler.w`; tightening this
  would need real per-reference scope tracking, which is a much bigger
  change than D4a's scope.
- Generic struct/function definitions and `operator` overloads are
  invisible to `defhash` on purpose: the scan-ahead/re-parse machinery
  those go through (`grammar/generic.w`, `grammar/operator_overload.w`)
  never reaches `defhash_note`'s call sites. Extending coverage to them
  would mean threading defhash bookkeeping through that machinery too --
  left as a follow-up since ordinary functions/globals/aggregates are
  the common case.

## Cleanup observed while dogfooding

- **`bin/wfixture` cannot pass a target selector to the compiler.** The
  CUDA work (2026-07-17) added compile-diagnostic fixtures that only
  reproduce under `bin/wv2 x64 ...` (gpu constructs are x64-gated, so
  the default-target compile stops at the gate error before reaching
  the interesting diagnostic). wfixture's in-file directive model is
  exactly right for these, but it always invokes the compiler bare, so
  every x64-only fixture had to fall back to hand-written
  `expect_fail`/`expect_stderr` steps in `build.base.json`
  (`cuda_diagnostics_test`) — the pre-wfixture layout the directives
  were meant to replace. A `# wfixture: x64` directive (or forwarding
  extra argv between the compiler path and the first fixture) would let
  those fixtures single-source their expectations again.
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
  convention/API for declaring boolean flag names up front.
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
- **`itoa(INT_MIN)` printed `"-"` instead of the number — resolved
  (2026-07-17).** Found 2026-07-16 while testing float→int conversion
  edges for issue #17 (`tests/float_conformance_test.w`,
  `tests/x64_float64_conformance_test.w`): `cvttss2si`/`cvttsd2si`
  substitute the "integer indefinite" sentinel (`INT_MIN`'s bit pattern)
  on out-of-range float→int conversions (Intel SDM behavior, no software
  range check — see `docs/projects/float.md`'s "Known MVP semantic
  differences"), and printing that value via `itoa()` for a debug
  message reproduced the bug: `itoa` (`lib/lib.w`) negated via
  `n = 0 - n`, which overflows back to the same negative value for
  `INT_MIN` in two's complement, so its digit-extraction loop
  (`while (n > 0)`) never ran and the output was just `"-"` with no
  digits — on both the 32-bit target (`-2147483648`) and x64
  (`-9223372036854775808`). Fixed by extracting digits directly from the
  (possibly still negative) `n`: `n % 10` keeps `n`'s sign under
  truncating division, so a negative digit's magnitude (at most 9) can
  always be negated safely, unlike `n` itself. Same-file fallout found
  while fixing this: `intstrlen` had the identical `0 - i` overflow for
  `INT_MIN` (undercounting to length 1 instead of sign-plus-every-digit)
  despite looking like the "already correct" reference implementation the
  original fix sketch (above) pointed at — fixed the same way, dropping
  the pre-negation; a negative dividend walks to 0 in exactly as many
  steps as its positive counterpart, so the digit count is unaffected.
  Also bumped `itoa`'s `malloc(16)` to `malloc(24)`: a 64-bit `INT_MIN`
  string is 21 bytes with the NUL, and 16 bytes was already tight for
  large 64-bit positive values before this fix even made `INT_MIN` the
  longest case. Lesson for future "mirror the working sibling function"
  fix sketches: verify the sibling against the actual overflow case
  rather than trusting that it "already handles negatives correctly" —
  both functions had the same bug, and only one was named as suspect.
  Comparison-based assertions (`assert_equal`'s `!=` check,
  `assert_equal_hex`'s `hex()`-based formatting, which uses bitwise
  shifts rather than negation) were never affected. Covered by
  `test_itoa_int_min` / `test_intstrlen_int_min` in `lib/lib_test.w`
  (word-size-derived `INT_MIN`, run on both the 32-bit and x64 twins via
  the file's `# wbuild: x64` directive).
- **`stream_peek_byte` sign-extends the byte 0xFF into the -1 EOF
  sentinel — pre-existing library bug.** Found 2026-07-16 while building
  `tests/ndjson_utf8_validator.w` for #287 stage 1: `lib/stream.w`'s
  `stream_peek_byte` returns `s.buffer[s.position]` (a sign-extending
  `char` load), so a raw 0xFF byte is indistinguishable from end of
  input, and everything layered on it — `stream_read_byte`,
  `stream_read_line`, `lib/file.w`'s `file_read_text`/`file_read_lines`
  — silently truncates at the first 0xFF byte (observed: a 241-byte
  NDJSON line captured from the pre-fix `check --json` came back as 213
  bytes). Bytes 0x80–0xFE flow through as other negative values and
  happen to survive the append path, so only 0xFF truncates. Likely fix
  is one masking op (`& 255`) in `stream_peek_byte` plus an audit of
  direct `s.buffer[...]` consumers in the same file; not fixed in the
  #287 PR (seed-adjacent blast radius — `lib/stream.w` feeds wexec,
  wmeta, and the web stack; deserves its own gated PR). The validator
  routes around it by reading with `getchar()`, which masks correctly.
- **The compiler can exit 1 with no diagnostic at all — full audit done
  (2026-07-18), one more gap fixed, one documented.** Three concrete
  silent-exit gaps were fixed 2026-07-16 (backend finisher `write()`
  checks, ce18e1e; tokenizer prefixed-string EOF, f7076b9; allocator OOM
  notice, 35ed0f5 — see the appendix below for status). This pass swept
  every `error(...)` call site in `grammar/`, `compiler/`,
  `code_generator/`, `w.w` (312 sites, not the ~95 `ai_tooling.md` had
  estimated — that number was stale), every direct `exit()`/`asserts()`
  call bypassing `error()`, and the driver-path syscalls (`open()`/
  `read()`/`write()`/`getcwd()`/`mmap()` in the compile/link/deps/symbols
  paths, `grammar/generic.w` and `grammar/defer.w`'s re-parse file opens,
  and the `libs/extras/{c_import,c_preprocessor,parser_generator}` seed
  graph). Full table in the appendix below. Net new finding: a genuine
  silent-crash gap in `lib/memory_debug.w`'s bookkeeping-table growth
  (5 unchecked `mmap()` calls) — **fixed this pass**, no fixture (same
  as 35ed0f5, forcing a real mmap failure needs a memory-exhausted
  environment, not a portable fixture). One further gap is documented,
  not fixed: `lib/lib.w`'s `getchar()` treats a genuine `read()` error
  the same as EOF, so a rare mid-file I/O failure looks like a silent,
  possibly-successful truncation rather than a diagnostic (see
  appendix). The original 2026-07-09 darwin-seed report itself still
  cannot be independently reproduced — see "Bounded repro attempt"
  below — but the audit found no comparable *still-open* silent-exit
  path in the seed graph on Linux, and every `error()` call site is
  safe by construction (see appendix "Method").

  **Bounded repro attempt (Linux-side, 2026-07-18).** The report was:
  an old ("pre-refresh") darwin seed compiling current `w.w`
  (post-#128 `libs/extras`) printed only the `compiling 'w.w'` banner
  and exited 1 — nothing on stdout or stderr — while the same
  constructs in a small probe file produced a proper error under a
  matched seed. The most likely explanation is the seed-generation
  skew the single-tag-pin policy (`CLAUDE.md` "Seed promotion",
  #128/#129) was written to eliminate: at the time, `./w` (Linux) and
  `./w_darwin` had each been refreshed independently, so it was
  possible for `./w_darwin` to be a generation *behind* `./w` — built
  from a `w.w`/grammar snapshot that predates some syntax the
  now-current `w.w` (or its `libs/extras` closure) uses, with the
  failure surfacing inside whatever internal function choked on the
  unrecognized construct rather than through the normal `error()` path
  (which the stale binary's own copy of `compiler/tokenizer.w` may not
  have reached, or may have reached with different, since-fixed
  plumbing). This could not be literally reproduced here: (1) only one
  seed generation/tag exists (`SEEDS` pins `v0.1.0` for all three
  platforms; no earlier tag was ever cut, so there is no "stale"
  generation left to install and test against — the single-tag policy
  landed before a second generation could exist), and (2) the specific
  historical `w_darwin` binary that exhibited the bug was never
  committed (seeds are downloaded, sha256-verified, gitignored) and is
  an arm64 Mach-O besides, so it could not run here even if archived.
  As a bounded substitute, the current pinned Linux seed was run
  directly against current `w.w` (`./w w.w -o /tmp/.../probe`,
  bypassing `wbuild`'s cached multi-stage): it compiled cleanly, exit
  0, banner printed, no incident — confirming that a *matched*
  single-tag-pin seed does not reproduce the failure shape, consistent
  with the skew theory. Fully confirming the original report would
  require a Mac with the specific stale `w_darwin` from 2026-07-09 (or
  before), which no longer exists in any accessible form — **Mac-only,
  and irreproducible even there** without that exact archived binary.

  **Appendix: silent-exit-1 audit table (2026-07-18)**

  Method: `error(char* s)` (`compiler/tokenizer.w`) is the sole sink
  every diagnostic funnels through — in `--json` mode it appends to the
  diagnostic buffer and emits one NDJSON record to stdout; otherwise it
  calls `warning(s)`, which prints `<message> in <filename>:<line+1>` to
  stderr — and only then exits 1 (or long-jumps to the REPL prompt under
  `repl_recovery`). Because every one of the 312 call sites necessarily
  routes through this one function, auditing them reduces to: (a)
  confirm `error()`/`warning()` themselves always emit (read, not
  changed), and (b) grep every call site for a non-empty message
  literal or a preceding `diag_part(...)`/`print_error(...)` fragment
  builder. A small script did (b) across all 312 sites; zero were
  `error(c"")` with no builder in the preceding lines. The rest of the
  table covers direct `exit()`/`asserts()` calls that bypass `error()`
  entirely, and driver-path syscalls that could fail before any
  diagnostic machinery runs.

  | Path | Verdict | Action |
  |------|---------|--------|
  | All 312 `error(...)` call sites: `grammar/*.w` (49 files, e.g. `generic.w` 27, `string_literal.w` 22, `for_statement.w` 18), `compiler/{bignum,compiler,symbol_table,tokenizer}.w`, `code_generator/{arm64,dynamic_registry,elf_32,elf_64,elf_arm64,elf_dynamic,ffi,macho_64,macho_dynamic,pe_64,sse,wasm_module}.w` | SAFE | None — `error()` is the sole choke point (see Method); verified programmatically, no fixes needed |
  | `compiler/tokenizer.w`'s `error()`/`warning()` themselves | SAFE | None — still call `warning()`/`diag_emit()` before every `exit(1)`/longjmp |
  | `compiler/compiler.w:424,600,671,741,909` direct `exit(1)` (usage banners for `link`/`check`/`deps`/`symbols`, `--strict` warning-count summary) | SAFE | None — each preceded by `println2(...)`/`print_error(...)` |
  | `lib/assert.w`'s `asserts`/`assert1`/`assert_equal*` (backs `compiler.w`'s output-fd/`-o`-argument checks, `debugger/attach.w`'s `rt_sigaction` check, etc.) | SAFE | None — always prints + a stack trace before `exit(1)` |
  | `code_generator/{elf_32,elf_64,elf_arm64,macho_64,pe_64,wasm_module}.w` backend-finisher `write()` checks | SAFE (fixed 2026-07-16, ce18e1e) | None — confirmed all 6 finishers still checked |
  | `compiler/tokenizer.w` prefixed-string (`c"..."`/`s"..."`) EOF scan | SAFE (fixed 2026-07-16, f7076b9, `prefixed_string_literal_test`) | None — confirmed |
  | `lib/memory_freelist.w`'s `malloc_grow`/OOM notice; `lib/memory_debug.w`'s `debug_malloc`'s own region `mmap()` OOM check | SAFE (fixed 2026-07-16, 35ed0f5) | None — confirmed both call sites still checked |
  | `lib/memory_debug.w`'s `debug_tbl_ensure_capacity()`: 5 bookkeeping-table `mmap()` calls | **GAP** — unchecked; a failed `mmap()` returns a small negative int used as a pointer with no validation, corrupting the debug allocator's own tracking table and segfaulting on first use with no diagnostic. Only reachable with the opt-in debug allocator (`W_DEBUG_MALLOC` env var or `malloc_force_debug_mode()`), not the default freelist backend | **Fixed this pass**: added `debug_tbl_mmap_failed()`, checked across all 5 results before use; prints `memory_debug: out of memory (bookkeeping table mmap failed)` and exits 1. No fixture — forcing a real `mmap()` failure needs a memory-exhausted environment, same as the untested 35ed0f5 precedent |
  | `lib/lib.w`'s `getchar()`/`getchar_unbuffered()`: a genuine `read()` error (negative, non-EOF — e.g. `EIO`, an interrupted read with no retry, reading a special file) is treated identically to EOF | **GAP found, not fixed** — a mid-file read failure silently looks like end-of-input; the tokenizer then either reports a parse error at the truncation point (misleading, but not literally silent) or, worse, the truncated bytes happen to parse as a valid shorter program and the compiler exits 0 with silently-wrong output. Fixing needs a distinct "read error" sentinel plumbed through `get_character()`/`compile_attempt()`/etc., a wider change than this pass's budget, and read() failing on an already-`open()`ed regular local file essentially never happens in practice | Documented only |
  | `libs/extras/c_import/importer.w` (2 sites), `libs/extras/c_preprocessor/{pp_directives,pp_macro}.w` (4 sites): `error(c"")` preceded by raw `print_error(...)` fragments instead of `diag_part(...)` | SAFE but inconsistent — the message does reach stderr (print_error always writes fd 2), but in `--json` mode the human-readable text still lands on raw stderr while `error(c"")` emits an *empty* NDJSON record on stdout, breaking the JSON contract. Pre-existing, already documented in `ai_tooling.md`'s "Composed messages" note (these libs predate the `diag_part` migration) | Not fixed — separate, larger "migrate c_import/pp to diag_part" task, not a silent-exit bug (message is never actually silent, just off-channel in `--json` mode) |
  | `libs/extras/parser_generator/*.w` | SAFE | None — no direct `exit`/`error` calls; parse failures are recorded into `pg_diagnostics` and returned to the caller (`c_import_header`), which always fatals via a non-empty `error()` either way |
  | Driver-path syscalls: `compiler/compiler.w`'s `compile_attempt`/`compile_relative_path`/`compile_joined` (source `open()` + upward directory search), `link_impl`'s output-path and `/dev/null`/`NUL` `open()`s, `grammar/generic.w:generic_reparse_start`, `grammar/defer.w:defer_reparse_start` (both re-open a recorded file to re-parse a generic instantiation/deferred statement) | SAFE | None — every `open()` result is checked, via `error()` (diag_part-built message) or `asserts()` |
  | Unrecognized CLI flags (e.g. `--bounds=xyz`) | Not silent, but confusing — falls through `link_impl`'s flag loop and is treated as an input filename, then fails the ordinary "no such file: '--bounds=xyz'" `error()` path | UX nit, not fixed (out of scope for this pass) |
  | `lib/generator.w`'s `__w_gen_create`: unchecked `mmap()` for a `generator` function's 64KB coroutine stack | Same failure shape as the memory_debug gap above, but this is stdlib runtime linked into *user* programs that declare `generator` functions, not the compiler's own process — outside this task's named scope (`compiler/`, `grammar/`, `code_generator/`, `w.w`) | Logged, not fixed |
  | Stack overflow from unbounded recursive-descent parsing (deeply nested expressions, generic instantiations) | A related but distinct failure class — a raw `SIGSEGV` is signal-terminated (not a clean `exit(1)`), so it doesn't match this audit's exact "exit 1, no message" shape, but is the same *outcome* (process dies, nothing printed). No recursion-depth guard exists anywhere in the parser | Out of scope for this pass; logged as a known, unaddressed gap |
  | Original 2026-07-09 darwin-seed report | Not independently reproduced | See "Bounded repro attempt" above |

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
