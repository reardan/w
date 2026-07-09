# AI Tooling — next steps

A living backlog for the agent-facing toolchain (`w check`, `w symbols`,
`bin/wtest`, the edit-check hook, `bin/wmcp`, `bin/wlsp`, skills/rules).
The implemented baseline is documented in `docs/projects/ai_tooling.md`.

**How this file is maintained** (enforced by
`.cursor/rules/ai-tooling-feedback.mdc`): when an agent or contributor
using the tooling hits friction, a bug, or a missing capability, they add
a short entry here (symptom, where observed, suggested direction) in the
same PR. When an item ships, its summary moves to the status section of
`ai_tooling.md` and the entry is deleted here. Keep entries terse; this
is a queue, not an archive.

## Diagnostics (`w check`)

- **Garbled `file` field on unresolvable paths.** Reproduce:
  `./bin/wv2 check --json lib/does_not_exist_anywhere.w` emits
  `{"file": "l\\\u0010\u0008\u0017", "line": 0, ...,
  "message": "filesystem root reached, abandoning search"}` — the
  file-not-found path serializes a corrupt/uninitialized filename buffer
  into the JSON record. Fix the buffer handling in the upward-search
  error path (`compiler/compiler.w` / `compiler/diagnostics.w`).
- **Array-to-pointer decay is a warning but generates corrupting code.**
  Found during the buffered-getchar work (issue #113, 2026-07-09):
  passing a fixed array (`char[8192] buf`) where a `char*` parameter is
  expected only warns (`argument 2 type mismatch: expected 'char*', got
  'char[] value'`) but emits the array's *descriptor address* as the
  pointer, so the callee (here `read(2)`) overwrites the descriptor's
  {data-pointer, length} header with payload bytes — the data pointer
  becomes file content and the next index through the array jumps to a
  garbage address far from the corruption site. Cost hours to trace
  back. Either implement real decay (pass the descriptor's data
  pointer) or promote the warning to a hard error; a warning that
  compiles to memory corruption is the worst of both.
- **Multi-error reporting.** The compiler stops at the first error
  (single-pass, no recovery). Documented limitation; real fix is parser
  recovery, which stays a research project. Cheap partial win: after an
  error in file A, agents re-check to find errors behind it — nothing to
  build, just keep the limitation documented in skills.
- **stderr chatter.** `check --json` prints `compiling '...'` and
  `using filename as path directly: ...` progress text to stderr. Stdout
  is clean, so parsers are unaffected, but a `--quiet` flag would make
  hook/LSP/MCP logs less noisy.
- **Arch-aware checking.** The hook and skills default to the x86 check;
  `lib/__arch__/x64/` files (and x64-only constructs like `int64`)
  deserve an automatic `check --json x64` pass when touched. Got worse
  with the graphics macOS backend (2026-07-09): `graphics/cocoa.w`
  declares `float64` extern parameters, so the default check reports
  "float64 requires the x64 target" on a perfectly healthy file — and
  there is no way to redirect it, because the target selector does not
  compose with the command (`wv2 x64 check --json f.w` parses "check"
  as a filename). Fix both: accept `wv2 <target> check` (or a
  `--arch=` flag), and infer the target from `__arch__` path segments
  and per-file markers so the hook picks the right one automatically.

## Edit-check hook (`bin/whook`)

- **Cache compiler-tree checks.** Every edit under `compiler/`,
  `grammar/`, `code_generator/` re-checks `w.w` (~3s). A content-hash
  stamp (same idea as `bin/.wexec_cache/`) could skip re-checks when the
  tree is unchanged since the last clean result.
- **Suggest tests alongside diagnostics.** The hook already knows the
  edited path; appending `bin/wtest changed <file>` output to the
  injected context would put the focused targets in front of the agent
  at exactly the right moment.
- **Tool-name matcher.** Cursor does not exhaustively document
  `postToolUse` tool names, so the hook filters inside the script
  (substring match on write/edit/replace). Once the names are
  documented, add a `matcher` to `.cursor/hooks.json` and drop the
  in-script heuristic. Revisit `afterFileEdit` if it ever gains a
  documented context-injection output.
- **Considered and deliberately skipped:** a `beforeShellExecution`
  nudge that intercepts bare `./wbuild tests` and suggests `test_changed`
  (fights the agent on a legitimate command), and a `stop`-hook
  "loop until verify is green" flow (the `stop` hook is not wired for
  Cloud Agents). Revisit with evidence of need.

## Test selection (`bin/wtest`)

- **Unmapped paths fall back to the full suite.** `tools/test_map.w`
  itself, `tools/wexec.w` test fixtures aside, `examples/`, and
  `tools/unicode/` all map to `tests`. Audit with
  `git ls-files | ./bin/wtest changed --verbose` and add rules where a
  focused target exists (e.g. `tools/test_map.w` -> `wtest_map_test`).
- **Registry drift.** The target registry is hand-maintained in
  `wtest_init_targets()`; a target added only to `build.json` silently
  falls back to `tests`. Either parse the manifest at runtime (the
  original design-doc idea) or add a test that diffs the registry
  against `./wbuild --list`.
- **`wtest changed --run`.** Now that `lib/process.w` exists, `wtest`
  could execute the selected targets itself instead of relying on the
  `./wbuild test_changed` xargs pipeline.

## MCP / LSP / cloud

- **`wdbg` rejects valid imported bare returns.** While debugging
  `tools/parser_generator.w`, `./bin/wdbg tools/parser_generator.w ...`
  failed before starting the debuggee with `Cannot find symbol: 'return'
  in libs/extras/parser_generator/diagnostics.w:24`. Add a debugger
  compile/run regression for imported functions containing bare `return`
  statements and fix the debugger's symbol-resolution path.
- **Cloud Agents cannot see `bin/wmcp`.** Repo `mcp.json` is IDE-only;
  the server must be registered in the Cloud Agents dashboard (stdio
  command: `sh -c "./wbuild wmcp >&2 && exec ./bin/wmcp"`).
  Owner action; until then cloud agents use the shell commands.
- **Conditional breakpoints/hit counts/logpoints land soon** (design:
  `docs/projects/debugger_conditional_breakpoints.md`). They add new
  stable, grep-able output lines (`logpoint N hit H: expr = value`,
  extended `info breakpoints` fields) to the same text protocol — worth
  keying a future structured wrapper off, and worth a
  `w-debug-wdbg` skill example once merged.
- **`callers`/`callees` performance.** `windex_enclosing_function` scans
  every declaration per reference (O(references × declarations)); fine
  for a one-shot CLI/MCP call, but would want an index instead of a
  linear scan if a workflow ever calls it in a loop over many symbols.
- **`windex` covers x86 only**, matching `bin/wlsp` (shells to plain
  `wv2 symbols --json`, no `x64` arg support yet).

## Cleanup observed while dogfooding

- **`indexd_test` is flaky under a parallel `wbuild tests` run.** Seen
  twice on 2026-07-09: `asserts(c"daemon responded", ...)` fires
  (jsonrpc_read_message returned 0) while the full suite runs in
  parallel, but the target passes 8/8 standalone. The windexd port
  discovery file (`bin/.windexd.port`) and the shutdown RPC are shared
  state between `index_test`/`indexd_test`/`index_mcp_test`, so a
  sibling test can shut down or replace the daemon this test spawned.
  Isolate the port file per test (env var or argv override) or
  serialize the index tests.
- **`repl.w` is not warning-free.** `./bin/wv2 repl.w -o /dev/null`
  reports two type warnings at `repl.w:518` (`load_word` argument 1 and
  `write` argument 2, both `char*` vs `int`). Fix them, then consider
  extending the warning-free gate (`self_host_warning_test`) to
  `repl.w`, `debugger/`, and `tools/`.
- **One-off targets assuming `bin/` exists — resolved.** The
  Makefile-to-`wbuild` migration handles it uniformly: `wbuild` and the
  manifest's `dirs` create `bin/` for every target.
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
- **Nonexistent input files produce a garbled directory-walk error.**
  `wv2 <typo>.w` prints `file ... not found error '-2'`, walks up
  directories, and at the filesystem root prints "abandoning search
  in" followed by garbage bytes (observed on arm64_darwin while
  bringing up the PAC tests, 2026-07-09; the misspelled path was
  `tests/hash_table_test.w` for `structures/hash_table_test.w`). A
  plain "no such file: <path>" before the import-search walk would
  have saved the confusion.
- **`syscall()` accepts any arity but lowers exactly nr + 3 args, with
  no diagnostic.** `syscall(172, 0x59616d61, -1)` compiles clean
  (`w check` too) but leaves garbage in `eax`, so the kernel returns
  ENOSYS at runtime. This silently broke `attach_target_fixture.w`'s
  `PR_SET_PTRACER_ANY` prctl, which made `attach_test` fail on any
  host with `ptrace_scope=1` (found 2026-07-09 on the `w` ssh box).
  The builtin knows its own arity — a wrong-argument-count warning
  (like ordinary functions get) would have caught this at edit time.
- **wexec is fail-fast; one broken target silently cancels the rest of
  an umbrella run.** During the 2026-07-09 full-suite run, the
  `c_import_test` failure stopped scheduling with 58 of 116 `tests`
  targets attempted, and the `attach_test` failure later cut another 10
  — with no "N targets skipped" summary, so lost coverage is easy to
  miss. Add a `--keep-going` mode (run everything, summarize failures
  at the end) for test-suite runs, and print how many targets were
  skipped when stopping early.
- **The compiler can exit 1 with no diagnostic at all.** The pre-refresh
  darwin seed compiling current `w.w` (post-#128 `libs/extras`) printed
  only the `compiling 'w.w'` banner and exited 1 — nothing on stdout or
  stderr (2026-07-09; the same constructs in a small probe file produced
  a proper `list field 'append' not found` error, so some deep error
  path exits without a message). Audit compiler exit paths so every
  failure prints at least a one-line diagnostic; a silent exit cost a
  full bisect to find the offending construct.
- **`lib/testing.w` test discovery is ELF-only.** It walks ELF section
  headers to find `test_*` symbols, so any testing.w-based test aborts
  with "No symbol table addr" when compiled `arm64_darwin` and run
  natively on macOS (observed with `map_set_builtin_test`,
  `list_builtin_test` 2026-07-09). That caps native darwin testing at
  the assert-style set in `tools/mac/run_darwin_tests.sh`. Either parse
  Mach-O `LC_SYMTAB` alongside ELF, or have the compiler emit a static
  test registry (which would also survive stripped binaries).

## Skills / rules upkeep

- Keep skill command examples in sync with CLI changes (they are
  hand-verified snapshots, nothing asserts them). A cheap
  `skills_test` that greps the documented flags against `--help` output
  would catch drift once the compiler grows a help text.
- Candidate new skills as workflows stabilize: ARM64 testing under
  `qemu-aarch64` (see `docs/projects/arm64.md`), seed updates
  (`./wbuild update` discipline), and C interop debugging (`c_import`).
