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
  deserve an automatic `check --json x64` pass when touched.

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
  nudge that intercepts bare `make tests` and suggests `test_changed`
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
  `wtest_init_targets()`; a target added only to the Makefile and
  `build.json` silently falls back to `tests`. Either parse the
  Makefile/manifest at runtime (the original design-doc idea) or add a
  test that diffs the registry against `./wbuild --list`.
- **`wtest changed --run`.** Now that `lib/process.w` exists, `wtest`
  could execute the selected targets itself instead of relying on the
  `make test_changed` xargs pipeline.

## MCP / LSP / cloud

- **Cloud Agents cannot see `bin/wmcp`.** Repo `mcp.json` is IDE-only;
  the server must be registered in the Cloud Agents dashboard (stdio
  command: `sh -c "mkdir -p bin && make -s wmcp >&2 && exec ./bin/wmcp"`).
  Owner action; until then cloud agents use the shell commands.
- **`w-debug-mcp` / DAP.** `wdbg`'s command loop is already scriptable
  over stdin (see the `w-debug-wdbg` skill); a structured wrapper
  remains deferred until an agent workflow actually needs programmatic
  stepping.
- **Semantic index.** `symbols --json` dumps declarations per file; a
  cross-file reference index (and `w-index-mcp`) is still unbuilt.
- **LSP coverage.** `bin/wlsp` publishes diagnostics and
  go-to-definition only; references, hover, and rename all want the
  semantic index above.

## Cleanup observed while dogfooding

- **`repl.w` is not warning-free.** `./bin/wv2 repl.w -o /dev/null`
  reports two type warnings at `repl.w:518` (`load_word` argument 1 and
  `write` argument 2, both `char*` vs `int`). Fix them, then consider
  extending the warning-free gate (`self_host_warning_test`) to
  `repl.w`, `debugger/`, and `tools/`.
- **One-off Make targets still assume `bin/` exists.** `make build` and
  the tool targets (`wtest`, `wmcp`, `wlsp`, `whook`) now create it and
  self-bootstrap `wv2`; the long tail of test targets does not. Extend
  the pattern if fresh-clone friction shows up again, or finish the
  Makefile-to-`wbuild` migration which handles it uniformly.

## Skills / rules upkeep

- Keep skill command examples in sync with CLI changes (they are
  hand-verified snapshots, nothing asserts them). A cheap
  `skills_test` that greps the documented flags against `--help` output
  would catch drift once the compiler grows a help text.
- Candidate new skills as workflows stabilize: ARM64 testing under
  `qemu-aarch64` (see `docs/projects/arm64.md`), seed updates
  (`make update` discipline), and C interop debugging (`c_import`).
