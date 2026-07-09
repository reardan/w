# `w-debug-mcp`

Status: **implemented** — `tools/mcp/w_debug_mcp.w` (built as `bin/wdmcp`,
`make wdmcp`), the last of the four MCP servers named in
[reardan/w#25](https://github.com/reardan/w/issues/25). `w-toolchain-mcp`
and `w-index-mcp` (`docs/projects/semantic_index.md`) shell out to a
subprocess per tool call; `wdbg`'s command loop doesn't fit that shape —
each command's output determines what to send next — so this server keeps
a live `wdbg` session across multiple tool calls instead.

## Why this was deferred, and what changed

`ai_tooling.md` deferred `w-debug-mcp` with "wdbg's command loop is already
scriptable over stdin; a structured wrapper remains deferred until an
agent workflow actually needs programmatic stepping." That need showed up
directly during this project's own validation pass: diagnosing a real
crash with `wdbg` benefits from a logpoint to find the failing condition,
then a conditional breakpoint to catch it before the crash, then
inspecting locals and the backtrace — a sequence where each step's
command depends on the previous step's output. A fixed batch script can't
do that; a live session can.

## Tools

- `debug_start({file, args?, break_start?})` — spawns
  `./bin/wdbg <file> [args...] [--break_start]` with piped stdio and
  returns `{session_id, output, prompt_seen}`. `break_start` defaults to
  `true`: see "The `--break_start` default" below.
- `debug_send({session_id, command})` — writes one command line to the
  session and returns `{output, prompt_seen, exit_code?}`. Any `wdbg`
  command works: `break`, `condition`, `log`, `ignore`, `print`, `step`,
  `next`, `continue`, `backtrace`, `info locals`, etc. (see
  `docs/debugging.txt` for the full set). `exit_code` is present once the
  debuggee has actually exited (the session is then gone — start a new
  one).
- `debug_stop({session_id})` — kills and reaps the session.

## The `--break_start` default

`wdbg` only starts reading commands once something traps it: a source
`debugger` statement, a patched breakpoint, `--break_start`/`--break_end`,
or a fatal signal. Nothing else synchronizes it with the command loop —
it's a single in-process call to the debuggee's compiled `main`, not a
forked/ptraced child (`debugger/wdbg.w`'s `wdbg_main`). A program with no
`debugger` statement, given `break`/`condition`/`log` commands before any
of those fire, just runs to completion or a crash first — the commands
were never read, not delayed. `debug_start` defaults `break_start` to
`true` for exactly this reason: an MCP caller that doesn't know the
target's source in advance would otherwise hit this silently. `wdbg`
itself now also warns about it (see `docs/projects/ai_tooling_next_steps.md`
and `.cursor/skills/w-debug-wdbg/SKILL.md`) for the CLI/skill path.

## Reading a session's output

`wdbg`'s output isn't framed — it's plain text ending in the `wdbg> `
prompt once a command's effects are done. `dmcp_read_until_prompt`
(`tools/mcp/w_debug_mcp.w`) polls stdout and stderr together (via
`lib/poll.w`) and accumulates until the buffer ends with that prompt, both
streams hit EOF (the debuggee exited — `debug_send` detects this and
reaps the process), or a timeout elapses. `prompt_seen: false` with no
`exit_code` means the command is still running past the timeout (e.g. an
infinite loop) — the session is still alive; sending another command (or
waiting) is safe.

## Known limitations

- **One command per `debug_send` call.** No batching; this is the point
  (see "Why this was deferred" above) but means a long, purely mechanical
  sequence costs one round trip per line.
- **x86 only**, matching `wdbg`'s own build (`make wdbg`) and every other
  tool in this project's AI-tooling surface.
- **No session limit or idle reaper.** A caller that forgets `debug_stop`
  leaves the child process (and its table entry) around until the server
  exits. Fine for interactive/agent use; would want a cap for anything
  longer-running.

## Testing

`tools/mcp/debug_mcp_test.w` (`make debug_mcp_test`) drives the real
`bin/wdmcp` over stdio: initialize, `tools/list`, then one live session
against `tests/debug_no_pause_fixture.w` (deliberately has no `debugger`
statement) — `debug_start` reaching the pre-main pause,
`break helper` + `continue` reaching the breakpoint, `print a` matching
the known fixture value, and `debug_stop` returning an exit code.
