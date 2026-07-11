# REPL: current state and prioritized improvements

Status: research (July 2026). Covers `w/repl.w` at submodule commit
`334834c`, the tooling around it in this repo (`wtools`, `wharness`), and
issues [reardan/w#33](https://github.com/reardan/w/issues/33) and
[reardan/w#114](https://github.com/reardan/w/issues/114). Defects marked
"verified" were reproduced against a fresh build of `bin/repl` (x86)
during this research.

NOTE (added on import): this research predates the July 2026 wave
program; D4 and parts of D6 have since been fixed. See
`docs/projects/consolidated_plan_2026_07.md` §3 for the reconciliation —
that document is the plan of record; this one is the underlying research.

## 1. Current state

### Architecture

`w/repl.w` (731 lines) is a standalone program with its own `main()`. The
whole compiler is linked in; each entry (possibly multi-line,
Python-style) is staged to `/tmp/w_repl_entry_N.w`, compiled into an RWX
mmap buffer as an anonymous function `__repl_N`, and called immediately.
Highlights of what already works, per `docs/projects/repl.md`,
`docs/todo.txt` and the `repl_test`/`repl_test_x64` targets:

- The stdlib (`lib.lib`, `lib.assert`) compiles into the buffer at
  startup; imports, structs, extern/c_lib all work at the prompt.
- Top-level declarations persist between entries (globals with storage in
  the code buffer, jumped over by the entry function); `x := expr` infers
  the type. Redefinition is Python-style shadowing (fresh symbol;
  `sym_lookup` keeps the last match). Struct/union/enum redefinition
  reuses the type-table record in place.
- Compile errors long-jump back to the prompt (`repl_setjmp`/
  `repl_longjmp` stubs; the `repl_recovery` hook in `error()`,
  `compiler/tokenizer.w:53`) and a ~20-global checkpoint rolls back code,
  symbols, types and import registries.
- The reader is a pure continuation scanner (bracket/comment/string
  state) with tty auto-indent, plus a raw-mode line editor with
  persistent history (`lib/line_edit.w`, `lib/termios.w`).
- File mode `repl file.w [args...]` (the `python -i` workflow), with
  `--no_main`.
- x86 and x64 are supported (x64 via `MAP_32BIT` buffer + real x64
  setjmp/longjmp stubs). arm64 stubs for `repl_setjmp`/`repl_longjmp`
  exist (`code_generator/arm64_asm.w:119`, including pointer-auth
  handling) but `repl.w` only wires x86/x64.

### Consumers today

1. **`bin/repl`** — the CLI, the only user of the full loop.
2. **wdbg** — `debugger/eval.w` reimplements "the repl model" for
   `p <expr>` at breakpoints: stages `return <expr>`, compiles it into
   the live buffer, rolls back through the same setjmp hook, and binds
   locals via low-memory scratch slots. A parallel implementation, not
   shared code (only the recovery hook is shared).
3. **wtools MCP server** — the `repl_eval` tool
   (`wtools/mcp/w_toolchain_mcp.w:185`) shells out to `bin/repl`,
   piping entries + `:quit` and scraping stdout.
4. **Agent skills** — `w/.cursor/skills/w-repl-explore` teaches agents to
   drive the piped interface.
5. **Planned** — `w/docs/ui.txt` sketches a websocket "repl server"
   behind a web UI (editor / debugger / repl / terminal).

### Verified defects and gaps

| # | Behavior | Severity |
|---|----------|----------|
| D1 | A runtime fault in an entry kills the session: `int* p = 0` then `p[0]` dies with SIGSEGV (exit 139); `1 / 0` dies with SIGFPE (exit 136). Compile errors recover; runtime faults do not. | high |
| D2 | Float echo prints raw bits: `1.5 + 2.25` echoes `1081081856`. `repl_echo` has no float case. | medium |
| D3 | Struct-value echo prints a meaningless int (`pt v` … `v` echoes `-143081536`). | medium |
| D4 | `repl.w:576` compiles with two type-mismatch warnings (`load_word` / `write` args). | low |
| D5 | Banner and `w> `/`.. ` prompts go to stdout even when piped, so scripted consumers (MCP `repl_eval`, skills) scrape output interleaved with prompts. | low–med |
| D6 | Staged entries use fixed names (`/tmp/w_repl_entry_N.w`, counter restarts per session): two concurrent sessions overwrite each other's files — generic instantiation re-parses recorded spans from those files, so this can miscompile — and the files leak after exit. | low |
| D7 | The 8MB code buffer is grown by `code_emitter.w`'s realloc on overflow, which would move the mapping out from under every embedded absolute address. Latent breakage for long sessions / a future server. | low (latent) |
| D8 | `:help` does not mention `x := expr`. | trivial |

## 2. The eight questions

### Q1. Make the REPL a library with a thin CLI — yes (P1)

It is not a library today: reader, eval engine, echo policy, arg parsing
and the prompt loop all live in one file with `main()`. Proposed split
(all in-tree in `reardan/w`, so plain imports work):

- **`repl/core.w`** — session + eval engine, no I/O policy:
  `repl_init(...)` (buffer mmap, asm stubs by arch, stdlib import,
  recovery buffer), `repl_eval(char* entry_text) -> {status, value,
  type}`, owning entry staging, skip regions, declare/shadow, the
  checkpoint/rollback, deferred-runtime finishers
  (generics/json/f-string/prelude/var) and echo-type computation.
- **`repl/scan.w`** — the pure continuation scanner as
  `repl_entry_complete(text)`; reusable by any front end (server,
  bracketed paste, editors).
- **`repl.w`** stays as the thin CLI (smallest churn: build targets,
  docs and the `./bin/wv2 repl.w -o bin/repl` invocation keep working):
  args, banner, prompt loop, auto-indent, `:commands`, history, echo
  printing.

Who benefits: wdbg (Q6), the ui.txt repl server, `#114` (which needs a
home for a repl-mode flag — see Q3), fault recovery (belongs in core),
and the MCP tool (can keep shelling out; embedding becomes possible).
Watch-outs: the hand-written `repl_test`/`repl_test_x64` targets live in
`build.base.json` and reference `repl.w`; keep the file name stable or
update them in the same change.

### Q2. Issue #33 — essentially done as a tracker; close and replace

Disposition of its "future improvements" list, verified against head:

| Item | Status |
|------|--------|
| Line editing + history (termios raw mode) | **Done** (PR #71, `lib/line_edit.w`) |
| x64 REPL support | **Done** (PR #71, `repl_test_x64`) |
| Struct redefinition handling | **Done** (`type_reset_for_redefinition`, tested in `repl_test`) |
| Line-editor single-row redraw (added later) | **Done** (commit `04da059`) |
| Late binding for redefined calls | **Split out** → #114 |
| REPL/debugger integration at wdbg breakpoints | **Partial** — `dbg_eval` + locals binding landed (#71); full REPL entries at a breakpoint remain (Q6) |
| `:load` and `:symbols` commands | Not done |
| Bracketed-paste handling | Not done |

Recommendation: **close #33** with a comment mapping the leftovers —
late binding is #114, and the three remaining small items (`:commands`,
bracketed paste, full REPL-at-breakpoint) get fresh narrow issues (or one
"REPL v2" tracking issue pointing at this document). A tracker where 5 of
8 items are done and the biggest one has its own issue has finished its
job.

### Q3. Issue #114 (late binding) — yes, but sequence it after the Q1 split

Worth doing: stale callers are the biggest remaining semantic wart —
redefining `f` at the prompt leaves every previously compiled `g` calling
the old `f`, which undercuts the main point of interactive redefinition.
The issue's design (a REPL-only, name-indexed map of call-site offsets,
rewritten on redefinition, mirroring the existing GOT-slot mechanism for
variadic C imports) is sound and costs normal compiles nothing.

Sequencing argument: the issue itself flags "where the REPL flag lives
and how it's checked" as the open decision — that is exactly the boundary
the Q1 library split defines. Doing #114 first bakes more globals into
`repl.w` that immediately move. Landing core first also gives wdbg's eval
the same fix for free once it shares the engine (Q6).

Scope: x86 + x64 call-emission sites first (arm64 when the REPL is wired
there), `./wbuild verify`/`verify_x64` as gates, plus `repl_test` cases:
redefine-then-call-through-old-caller, several generations of
redefinition, and prototypes ('U' symbols) still resolving through the
existing backpatch path.

### Q4. Imperative "bash-like" mode (calling programs) — thin explicit escape, not a bare-command mode

Foundations exist: `lib/process.w` has spawn/exec with per-stream stdio
control, cwd, env vectors, wait/status decoding and timeouts — nothing
new is needed at the syscall layer.

Recommended shape: a **`!` escape** handled by the reader (like
`:commands`): `!git status` runs the command with inherited stdio;
`!cd dir` and `!export K=V` are intercepted builtins (they must affect
the REPL process itself). This is unambiguous, cheap (reader-level, in
the CLI layer), and matches IPython/IDLE conventions.

Recommended against: making bare `ls -la` fall through to the shell —
either by "if it fails to compile, run it as a command" (every typo
becomes a command execution) or by first-token heuristics (`ls - la` is
valid W when the symbols exist; the ambiguity is unresolvable in
general). A dedicated `:sh` toggle that flips the prompt into
command-first mode is a reasonable later addition if the `!` escape sees
heavy use.

### Q5. Imperative mode with native W functions — the better half of the same feature

Proposal: **`lib/shell.w`** on top of `lib/process.w` and `lib/env.w`:

- `shell_result* sh(char* cmd)` — `/bin/sh -c` with captured
  stdout/stderr and decoded status (`{string out, string err, int
  status}`)
- `run(list[char*] argv)` — no shell, same result shape
- `cd(char* path)`, env get/set wrappers; a pipeline helper later.

The win over Q4 alone is composability: results are W values —
`r := sh("git status")`, `r.out`, loops/filters in W, f-strings for
interpolation — and the module is useful outside the REPL (scripts,
wharness tools, wexec). The two modes then unify: `!cmd` is sugar for
"run with inherited stdio", `sh(...)` is the capturing form. `lib/shell.w`
can land independently of any REPL work; the REPL then advertises it in
`:help` (or auto-imports it).

### Q6. REPL / wdbg integration — yes, three touchpoints

(The request said "wgb"; no such component exists in either repo, so this
reads it as **wdbg**, which is also what #33's future-work list pairs the
REPL with.)

Already shared: the in-process buffer model, the `repl_setjmp` recovery
hook, and `lib/line_edit.w` on both prompts. `debugger/eval.w` is a
hand-rolled subset of the REPL's eval engine.

1. **Fault recovery in the REPL using wdbg's handler machinery** —
   `wdbg.w:1098–1167` already solves i386/x86-64 `rt_sigaction` with
   hand-built restorer thunks for SIGSEGV/SIGILL/SIGBUS/SIGFPE. The REPL
   installs the same handlers; on a fault in an entry it prints the
   signal + fault address (optionally a `lib/stack_trace` backtrace) and
   long-jumps to the prompt. This directly fixes D1 and is the highest
   value integration.
2. **Full REPL at breakpoints** — after Q1, `dbg_eval` grows into (or is
   replaced by) `repl/core.w`'s eval, so a stopped debuggee's prompt
   accepts multi-line entries, persistent helper definitions and imports;
   the existing locals scratch-binding stays as a pre-eval hook.
3. **`debugger` statement at the prompt** — today it emits `int3` and,
   with no handler installed, kills the session. With (1)'s handlers the
   natural behavior is to enter the wdbg command loop at that point,
   making `bin/repl` a superset of `bin/wdbg` for in-buffer code.

End state: one "interactive session" core with two front ends — which is
also what the ui.txt web plans (editor + debugger + repl over one server)
imply.

### Q7. Other improvements

- **Echo fixes** (D2, D3): floats via `lib/float64_format`; struct values
  via the json codec that is already REPL-resident
  (`json_codec_finish_import`) — echoing `pt{x: 3}` as `{"x": 3}` is
  nearly free and extends to lists/maps.
- **Tab completion** from the live symbol table (it's in-process;
  `lib/line_edit.w` has no completion hook yet) + **Ctrl-R** history
  search.
- **Bracketed paste** (#33 leftover): pasted code with blank lines
  currently ends the entry early, and auto-indent double-indents pasted
  tabs; paste mode suspends both.
- **Scripted/agent mode**: prompts + banner to stderr when stdin is not a
  tty (or `--quiet`); `-e "entry"` one-shot eval; optionally `--json`
  NDJSON per entry (`{entry, output, echo, error}`). Directly improves
  wtools `repl_eval` (D5) and the w-repl-explore skill.
- **More `:commands`**: `:symbols` (`print_symbol_table` exists), `:load
  file` (file mode at runtime), `:type expr` (compile, report the type,
  discard), `:time expr`, `:dis name` (the in-house disassembler from
  reardan/w#163 makes this cheap), `:reset`, `:save file` (concatenate
  the staged entry files — they are already kept per entry for generics).
- **Staging hygiene** (D6): a per-session `mkdtemp`-style directory,
  cleaned up on exit.
- **arm64 / darwin REPL**: stubs exist; needs `define_asm_functions_arm64`
  wiring in `repl.w`, an arm64 low-address buffer strategy (no
  `MAP_32BIT`), and mac signal plumbing once fault recovery lands. The
  Mac is a primary dev platform per `w/CLAUDE.md`.
- **Buffer exhaustion** (D7): in REPL mode, replace the realloc path with
  a clear diagnostic (embedded absolute addresses make moving the buffer
  impossible), or reserve a larger mapping up front.

### Q8. REPL items found in project docs

- `w/docs/ui.txt` — the web-UI roadmap wants a websocket **"repl
  server"** plus editor/terminal: the strongest external argument for the
  Q1 split.
- `w/docs/todo.txt` "current limitations" — the only REPL limitation
  listed is the stale-caller late binding, i.e. #114.
- `w/docs/projects/repl.md` — same limitation; also records that struct
  redefinition and the line-editor redraw were already fixed (matches
  Q2's table).
- `wharness/README.md` — its "REPL mode" is a conversation loop
  (unrelated implementation, no code to share), but wharness could grow a
  `w_eval` tool that pipes entries to `bin/repl` the way wtools'
  `repl_eval` does — cheap and useful for its agent.
- No other REPL debts found in `w-private` docs.

## 3. Prioritized plan

Effort: S = hours, M = a focused day or two, L = multi-day.

**P0 — robustness + quick wins** (independent of each other)

1. Runtime-fault recovery via wdbg's handler machinery (D1, Q6a) — M
2. Echo fixes: floats, struct/container values via json codec; document
   `:=` in `:help` (D2, D3, D8) — S
3. Fix `repl.w`'s two compile warnings (D4) — S
4. Staging hygiene: per-session temp dir + cleanup (D6) — S

**P1 — architecture**

5. Library split: `repl/core.w` + `repl/scan.w` + thin CLI (Q1) — M
6. #114 late binding, built on the core's repl-mode flag (Q3) — M–L

**P2 — interactive UX**

7. Bracketed paste — S–M
8. Tab completion from the symbol table; Ctrl-R history search — M
9. `:symbols`, `:load`, `:type`, `:time`, `:dis`, `:reset`, `:save` — S
   each

**P3 — scripting/agents + the shell direction**

10. Non-tty cleanup (prompts → stderr), `-e`, `--json` (D5) — S
11. `lib/shell.w` native helpers (Q5; useful standalone) — S–M
12. `!` escape in the CLI desugaring to `lib/shell` with inherited stdio
    (Q4) — S

**P4 — platform + integration end-state**

13. Full REPL at wdbg breakpoints; `debugger` statement enters the wdbg
    loop from the prompt (Q6 b/c) — M
14. arm64, then darwin, REPL — M–L
15. Websocket repl server for the web UI (ui.txt) — L, unblocked by item 5

Issue actions: close #33 with a comment mapping its leftovers to this
plan; keep #114 open and schedule it after the split; file fresh issues
for P0.1, P1.5 and P2.7 as they start.
