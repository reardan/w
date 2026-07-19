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
- **`w check --bool-ops`'s position/chain bugs — two fixed, one
  deferred (2026-07-17, wave 2f).** Consolidates four overlapping
  reports from wave-2 sweep chunks 2a/2b/2d/2e, all downstream of the
  same three bugs: (1) a warning inside an *imported* (non-root) file
  reports its line number +1 high (`debugger/memory.w:52` vs. actual
  line 51) — root cause found (`compiler/compiler.w`'s `compile_save`
  saves `line_number + 1` instead of `line_number` before compiling the
  import, then restores the inflated value) but **left open**: the fix
  touches every diagnostic's line number for every imported file, not
  just this hint, so it belongs in its own gated PR, not this one
  (scheduled: wave plan C task 1b). (2) the reported line/column was
  wherever the tokenizer's one-token
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
  the footgun entirely rather than documenting around it. (scheduled:
  wave plan C task 1h)

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
  (scheduled: wave plan C task 1f)

## Definition hashing (`w defhash`)

- **`wtest --defhash` consumer**: wire an opt-in `--defhash` refinement
  into `tools/test_map.w`'s rule (b) (see its header comment) — for a
  changed `.w` file, shell out to `bin/wv2 defhash` on both
  `git show HEAD:<path>` and the worktree copy, and skip adding
  import-closure targets when every recorded name's hash (and the name
  set itself) is unchanged. Patterns to follow:
  `tests/wtest/map_expectations.expect`, `wtest_map_test`/`wtest_run_test`
  (`build.base.json`), the `-f <manifest.json>` synthetic-manifest trick,
  the `cd bin && ./wtest ...` trick for exercising behavior outside a git
  repo, and a self-contained `git init`-in-a-scratch-dir `sh -c` step for
  the HEAD-vs-worktree comparison. Opt-in flag; default selection stays
  byte-identical. (scheduled: wave plan C task 2g)
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

## Cleanup observed while dogfooding

- **`bin/wfixture` cannot pass a target selector to the compiler**
  (scheduled: wave plan C task 1d). The
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
- **`lib/generator.w`'s `__w_gen_create`: unchecked `mmap()`** for a
  `generator` function's 64KB coroutine stack — same failure shape as the
  (fixed) `memory_debug` bookkeeping-table gap: a failed `mmap()` returns
  a small negative int used as a pointer, segfaulting with no diagnostic.
  Stdlib runtime linked into user programs, not the compiler's own
  process. (scheduled: wave plan C task 1c)
- **No recursion-depth guard in the recursive-descent parser.** Deeply
  nested expressions/generic instantiations overflow the stack and die as
  a raw `SIGSEGV` with nothing printed — the same outcome as a silent
  exit-1 (process dies, no message), just signal-terminated rather than a
  clean `exit(1)`. (scheduled: wave plan C task 2h)
- **Unrecognized CLI flags aren't detected as such.** `bin/wv2
  --bounds=xyz` falls through `link_impl`'s flag loop and is treated as
  an input filename, failing with the ordinary (and confusing)
  `no such file: '--bounds=xyz'` instead of an "unrecognized option"
  diagnostic. (scheduled: wave plan C task 1g)

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
