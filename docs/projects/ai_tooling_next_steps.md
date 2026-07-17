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
- **Bool-bitwise condition warning: default still lvalue-scoped;
  widened scope shipped opt-in (stage 1, 2026-07-16).** The shipped
  "did you mean `||`/`&&`?" hint (2026-07-10) fires by default only
  when both `|`/`&` operands are bool-typed *lvalues* in an if/while
  condition. Stage 1 of the migration landed: (a) the parser generator
  now emits `&&`/`||` for every boolean join in generated code (kind-set
  guards, first-byte dispatch ranges, literal-trie accept tests, charset
  conditions, recovery skip conjunctions — all pure-comparison operands;
  `libs/extras/c_import/generated_c_parser.w` regenerated, removing all
  of its ~140 sites), and (b) `w check --bool-ops` (opt-in, modeled on
  `--imports`) widens the hint to comparison-result operands —
  `(a == b) | (c == d)` — covered by `check_bool_ops_test`. The
  compiler-injected modules (auto-import closure, prelude/json/
  template/var runtimes) stay suppressed under the flag like `--imports`
  does. Measured stage-2 worklist with the flag on: 471 fires across
  `w check --bool-ops w.w` plus 19 in the suppressed compiler-injected
  runtime (16 auto-import closure + 3 `structures/prelude.w`), ~490
  hand-written sites total. Stage 2 is the mechanical per-site sweep
  (reviewed in ~50-site chunks: top files `debugger/wdbg.w` 47,
  `libs/asm/x86_decode.w` 36, `libs/extras/parser_generator/lexer.w` 27,
  `grammar/string_literal.w` 27, `compiler/tokenizer.w` 24); flipping
  the default comes after that.
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
- **`w check --bool-ops` (and the underlying bool-bitwise condition
  warning generally) misreports the site location for any warning
  inside an *imported* file.** Found 2026-07-17 doing the bool-bitwise
  stage-2 sweep (wave 2, chunk 2d: `grammar/`+`compiler/`+
  `code_generator/`). Two independent bugs stack: (1) every reported
  line number for a warning inside an imported (non-root) file is off
  by exactly +1 — reproduced minimally with a two-file `import`
  (`main.w` importing `sub.w`, the flagged `&` on `sub.w`'s line 2
  reports as line 3); a single-file root program checked directly does
  not show this, so it's specific to crossing an import boundary
  (plausibly an extra line-count tick when the tokenizer switches
  files). (2) independent of file identity, the reported line/column
  for this warning is wherever the tokenizer's one-token lookahead
  happens to be sitting when `warning()` fires (i.e. after the full
  join has been parsed), not the location of the flagged operator
  itself — for a chained condition (`A & B & C`, or nesting across a
  line break) this can point at a wholly different token than the one
  that needs editing. Reproduced with a 3-term chain (`(a==1) & (b==2)
  & (c==3)`) in a root file (no import-boundary bug in play): only the
  first `&` is actually flagged (both operands bool; the fold's result
  promotes to a non-bool type so later folds in the same chain never
  qualify), but the reported column lands on the *second* `&`, one
  token further right than the real one. Combined, agents cannot trust
  either the line or the column for this warning inside any imported,
  multi-line, or chained site — the only reliable approach found was
  computing `actual_line = reported_line - 1` for imported files, then
  reading the surrounding source to identify which specific `&`/`|`
  the message's operator symbol (`&` vs `|`) and site count actually
  refer to. A `check --bool-ops --json` mode that reported the true
  operator token's byte offset (as recorded by the parser at `accept()`
  time, before any further lookahead) would remove this entirely.
  Related, not a bug: converting a flagged join to `&&`/`||` changes
  operator precedence grouping (`&&`/`||` bind looser than `&`/`|`), so
  in a 3+-term chain each conversion can newly expose the *next* fold
  as bool-vs-bool (their result type is no longer erased by `&`/`|`'s
  int-promotion) — sweeping such a chain to a real fixpoint takes one
  `check --bool-ops` re-run per remaining fold, not one.

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

## Cleanup observed while dogfooding

- **Test sources can assert on their own raw bytes.** `defer_test.w`'s
  `test_defer_closes_file_descriptor` asserts the first byte of
  `tests/defer_test.w` is the `'i'` of `import`, so prepending the new
  `# wbuild: x64` manifest directive as line 1 broke it at runtime while
  every compile stayed clean (2026-07-10, manifest-generation
  migration; the directive lives on line 2 there now). When a tool
  rewrites test sources en masse, grep the touched files for their own
  paths first; longer term, self-referential assertions should read a
  dedicated fixture instead of the test's own source.
- **No portable stat()/file-metadata wrapper exists anywhere in the
  tree.** Building `libs/extras/vcs/index.w` (issue #252 wave 3, the
  stat-cached dirstate) needed a file's (size, mtime); no
  `lib/__arch__/*/syscalls.w` wraps `stat`/`fstat`/`statx` -- every
  prior caller that wanted a size used `lib.lib`'s `file_size()`
  (seek-to-end, not a real stat) and no module reads mtime at all.
  Landed a scoped fix rather than a general one:
  `libs/extras/vcs/__arch__/{x86,x64}/fsops.w:vcs_statx` (Linux `statx`,
  syscall numbers 383/i386 and 332/x86-64) -- `struct statx`'s layout is
  identical on 32- and 64-bit Linux by design (verified against glibc's
  `stat(2)` on the dev host), so only the syscall NUMBER is per-arch,
  cheaper than hand-deriving the legacy 32-/64-bit `struct stat`
  layouts. arm64/win64/wasm are unimplemented, matching tree.w's/
  commit.w's own x86/x64-only directory-walk scope. A general
  `lib/stat.w` (mtime/size/mode/is-dir for any caller, not just
  libs/extras/vcs) is future work once a second consumer needs it
  outside vcs/ -- tree.w's own header comment already flags the
  executable bit as unlearned for the same underlying reason.
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
- **The compiler can exit 1 with no diagnostic at all — partially
  addressed.** The pre-refresh darwin seed compiling current `w.w`
  (post-#128 `libs/extras`) printed only the `compiling 'w.w'` banner
  and exited 1 — nothing on stdout or stderr (2026-07-09; the same
  constructs in a small probe file produced a proper `list field
  'append' not found` error, so some deep error path exits without a
  message). Three concrete silent-exit gaps found while auditing this
  are now fixed (2026-07-16): every backend finisher
  (`elf_finish`/`elf_finish_64`/`elf_finish_arm64`/`pe_finish_64`/
  `macho_finish_arm64`/`wasm_finish`) now checks its output-binary
  `write()` and prints `could not write output file` instead of exiting
  0 with a truncated image (ce18e1e); the tokenizer's `c"..."`/`s"..."`
  prefixed-string scanner reports `unterminated string literal` at EOF
  instead of spinning forever with no output (f7076b9, pinned by
  `prefixed_string_literal_test`); and `lib/memory`'s allocator prints a
  one-line notice before returning null on OOM instead of letting every
  caller's assumed-infallible `malloc()` segfault with no diagnostic
  (35ed0f5). What remains: the original 2026-07-09 darwin-seed report
  itself hasn't been independently re-reproduced to confirm one of these
  three covers it, and no one has yet done the full audit of the ~95
  `error()` call sites (`ai_tooling.md`'s current-state notes) for other
  silent-exit paths beyond these three.

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
  Worth a proper root-cause pass on the allocator/JIT interaction — this
  workaround just avoids the pattern, it doesn't explain it.

## Skills / rules upkeep

- Keep skill command examples in sync with CLI changes (they are
  hand-verified snapshots, nothing asserts them). A cheap
  `skills_test` that greps the documented flags against `--help` output
  would catch drift once the compiler grows a help text.
- Candidate new skills as workflows stabilize: ARM64 testing under
  `qemu-aarch64` (see `docs/projects/arm64.md`), seed updates
  (`./wbuild update` discipline), and C interop debugging (`c_import`).
