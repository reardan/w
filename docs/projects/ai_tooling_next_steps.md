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

- **Array-to-pointer decay corruption is fixed.** Issue #220 (found
  during the buffered-getchar work, #113, 2026-07-09) is closed: PR #225
  implemented real decay (`coerce()` in `grammar/promote.w` loads the
  descriptor's data pointer instead of passing the descriptor address)
  across call arguments, initialization, assignment, return, container
  literals/push/insert, membership keys and switch cases. Three narrower
  edge cases were consciously left out of that fix — C-variadic tails,
  `cast(int, arr)` vs `cast(char*, arr)`, and one arm of a conditional
  expression — none of which corrupt memory (wrong-but-visible descriptor
  address, or a lingering warning); they're tracked in issue #229.
- **Multi-error reporting.** The compiler stops at the first error
  (single-pass, no recovery). Documented limitation; real fix is parser
  recovery, which stays a research project. Cheap partial win: after an
  error in file A, agents re-check to find errors behind it — nothing to
  build, just keep the limitation documented in skills.
- **Bool-bitwise condition warning is lvalue-scoped for now.** The
  shipped "did you mean `||`/`&&`?" hint (2026-07-10) only fires when
  both `|`/`&` operands are bool-typed *lvalues* in an if/while
  condition. Comparison-result operands — `(a == b) | (c == d)` — stay
  exempt because that spelling is the established style of the
  pre-`&&`/`||` compiler sources: enabling it fires 469 times in the
  seed graph alone, 80 of them in the *generated*
  `libs/extras/c_import/generated_c_parser.w`, so widening the scope
  needs a dedicated style-migration PR (a per-site short-circuit safety
  review plus a parser-generator emission change) first.
- **`T* + int` is a raw, unscaled byte offset for every pointee width,
  and nothing warns.** Found 2026-07-16 writing `libs/extras/compress/
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
  look interchangeable but are not). Suggested direction: a `w check`
  warning on `<non-char-pointer> + <int-not-a-multiple-of-known-
  stride>` is unrealizable statically in general, but at minimum
  README.md/CLAUDE.md should document the rule explicitly (searched for
  "pointer arithmetic" and "byte offset" — nothing exists today), and a
  `ptr_add(p, n)`-style intrinsic that scales by `__word_size__`/
  `sizeof` (or a real `&p[n]` desugar recommended in library code
  instead of `p + n`) would remove the footgun entirely rather than
  documenting around it.

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

- **`wtest changed --run` — landed.** `wtest` now takes a `--run` flag:
  after printing the selection (unchanged), it spawns `bin/wexec` itself
  with that target list, inheriting stdio so build output streams live,
  and exits with its status — instead of a caller piping `wtest`'s
  output through `./wbuild test_changed`'s `xargs -r ./wbuild`. An empty
  selection is a no-op, matching `xargs -r`'s behavior on empty input.
  A companion `-f manifest.json` flag (mirroring `bin/wexec`'s own)
  overrides the manifest for both selection and, under `--run`,
  execution; it exists so `--run` can be tested in isolation
  (`wtest_run_test` in `build.base.json`, fixture at
  `tests/wtest/run_fixture.json`) without ever selecting a real target
  whose own steps shell out to `bin/wtest`, which would recurse through
  the live manifest.
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
- **`.txt` doc-only filter swallowed `tests/asm/` corpus fixtures — fixed
  (issue #171).** `wtest_doc_only` in `tools/test_map.w` treated every
  `*.txt` path as documentation (meant for `docs/todo.txt`), so
  `tests/asm/corpus_{x86,x64,arm64}.txt` — runtime fixture data for the
  whole asm test suite, not docs — never reached the `tests/asm/` residue
  rule; `wtest changed` silently selected nothing for a corpus-only
  change. Found while wiring the new `asm_fuzz_*` property/fuzz targets,
  which read those same fixtures. Fixed by excluding `tests/asm/` from
  the doc-only check before the extension test; pinned by a new
  `wtest_map_test` case (`build.base.json`).

## Debugger surface (consumed by the external integration tools)

- **Conditional breakpoints/hit counts/logpoints have landed** (design:
  `docs/projects/debugger_conditional_breakpoints.md`, status:
  implemented). They add new stable, grep-able output lines (`logpoint N
  hit H: expr = value`, extended `info breakpoints` fields) to the same
  text protocol — still worth keying a future structured wrapper off, and
  still worth a `w-debug-wdbg` skill example.

## Cleanup observed while dogfooding

- **Hex/binary literals wider than 32 bits were silently corrupted —
  resolved (2026-07-13).** The literal decoder kept only a rolling
  32-bit window of a literal's digits, so on the x64 target
  `0x7ff0000000000000` parsed to `0` and `0x000fffffffffffff` parsed
  to `0xffffffffffffffff` — no warning, no error. Distinct from the
  documented bit-31 sign-extension gotcha, and a straight bug for
  64-bit-word targets: until the tokenizer carries 64-bit (or bignum)
  literal values, wide constants must be assembled at runtime from
  sub-32-bit pieces (see `lib/sha256.w`'s runtime-built masks).
  Resolved by `int_literal_width_check()` (grammar/int_literal.w,
  shared by the expression, enum-value and parameter-default decode
  paths): any hex or binary literal with more than 32 significant bits
  is now a compile error instead of wrapping. Leading zeros carry no
  bits, so `0x00000000ffffffff` still compiles; the
  `int_literal_width_test` fixtures freeze the error message and
  `tests/warning_clean_fixture.w` pins the still-legal wide spellings.
  Extended 2026-07-16: decimal literals get the same guard
  (`int_literal_decimal_check()` — more than 10 significant digits, or
  exactly 10 comparing above 4294967295, is the same compile error;
  boundary spellings pinned by `tests/int_literal_bounds_test.w`), and
  the sweep for newly-rejected literals caught a real casualty: the
  win64 FILETIME epoch offset `11644473600` in
  `lib/__arch__/win64/syscalls.w` had been silently wrapping — win64
  `linux_time()` returned garbage — and is now computed at runtime.
- **`parser_generator_w_test` retained every parsed AST — fixed by
  batching (2026-07-12).** `test_parse_all_tracked_w_files` parsed all
  tracked `.w` files in one process, retaining every AST, so the
  32-bit gate segfaulted (exit 139) once tracked source crossed
  ~3.7MB — six new library files tipped it, and removing ANY one of
  them "fixed" it, a misleading bisect signature worth remembering.
  First attempt — freeing per-file ASTs/sources/diagnostics — was
  correct but catastrophically slow: recursive frees through the
  first-fit allocator turned the 2-minute gate into a 90-CPU-minute
  crawl (CI's 30-minute budget times out), and fragmentation kept RSS
  growing anyway. The landed fix is
  `tools/parser_generator_w_batches.sh`: rerun the test binary once
  per 150-file slice of the manifest, bounding memory at batch size
  forever (~21s total). The residual named here — the allocator's
  quadratic free/malloc behavior under millions of small blocks — was
  fixed by #322 (2026-07-16): `lib/memory_freelist.w` now uses 41
  segregated size-class bins with O(1) free, so the batching is a
  memory bound, no longer a speed workaround.
- **Test sources can assert on their own raw bytes.** `defer_test.w`'s
  `test_defer_closes_file_descriptor` asserts the first byte of
  `tests/defer_test.w` is the `'i'` of `import`, so prepending the new
  `# wbuild: x64` manifest directive as line 1 broke it at runtime while
  every compile stayed clean (2026-07-10, manifest-generation
  migration; the directive lives on line 2 there now). When a tool
  rewrites test sources en masse, grep the touched files for their own
  paths first; longer term, self-referential assertions should read a
  dedicated fixture instead of the test's own source.
- **One-off targets assuming `bin/` exists — resolved.** The
  Makefile-to-`wbuild` migration handles it uniformly: `wbuild` and the
  manifest's `dirs` create `bin/` for every target.
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
- **`itoa(INT_MIN)` prints `"-"` instead of the number — pre-existing
  library bug, unrelated to float codegen.** Found 2026-07-16 while
  testing float→int conversion edges for issue #17
  (`tests/float_conformance_test.w`, `tests/x64_float64_conformance_test.w`):
  `cvttss2si`/`cvttsd2si` substitute the "integer indefinite" sentinel
  (`INT_MIN`'s bit pattern) on out-of-range float→int conversions (Intel
  SDM behavior, no software range check — see `docs/projects/float.md`'s
  "Known MVP semantic differences"), and printing that value via
  `itoa()` for a debug message reproduces the bug: `itoa` (`lib/lib.w`)
  negates via `n = 0 - n`, which overflows back to the same negative
  value for `INT_MIN` in two's complement, so its digit-extraction loop
  (`while (n > 0)`) never runs and the output is just `"-"` with no
  digits — on both the 32-bit target (`-2147483648`) and x64
  (`-9223372036854775808`). Comparison-based assertions (`assert_equal`'s
  `!=` check, `assert_equal_hex`'s `hex()`-based formatting, which uses
  bitwise shifts rather than negation) are unaffected; only code that
  formats an `INT_MIN`-valued int via `itoa()` hits this — the new
  conformance tests route around it by asserting bit patterns via
  `assert_equal_hex` instead. Not fixed here (out of scope for a
  float-conformance PR, and `lib/lib.w` is broadly imported); the fix is
  a one-line special case (or restructure the loop to extract digits via
  `-(n % 10)` without pre-negating `n`, matching `intstrlen`'s existing
  correct handling of negative `n`).
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
