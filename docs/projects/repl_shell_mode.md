# REPL shell mode: design (issue #335)

Status: design, stages 1 and 2 shipped (July 2026). Scopes issue #335
against the shipped `!` escape and `lib/shell.w` (issue #276 P0–P3,
previous plan's waves 1–5) and against the Q4/Q5 reasoning in
`docs/projects/repl_improvements.md`, which this doc extends rather
than revisits. The staged plan in §11 had an intentionally small
stage 1 (Wave 3 task 3b of `docs/projects/sonnet_wave_plan_2026_07b.md`)
and a stage 2 (task 3b of `docs/projects/sonnet_wave_plan_2026_07c.md`)
that fills out the rest of the v1 tool subset; §11 records what
shipped and what stays deferred.

## 1. The issue, verbatim

> Create a shell mode for w's REPL. Also consider whether this should
> be a standalone tool.
>
> This can behave like bash or zsh. It will be more imperative, so
> call the functions directly with shell syntax: `ls -la /home/w/` ->
> which translates to `shell_commands.ls(list=true, all=true,
> path="/home/w/")`.
>
> I'd like to have a complete set of internal tools - mirroring
> command linux command line tools. Also have the ability to farm
> these out to native, probably do this as an MVP.

Three separable asks: (1) a mode where typed lines parse as shell
commands instead of W, (2) a growing library of native
coreutils-alike functions those commands translate to, with (3) a
farm-to-native escape hatch for anything not yet mirrored, explicitly
called out as the MVP shape. §4 covers (1), §5–§6 cover (2), §7
covers (3).

## 2. What already exists

- **The `!` escape** (`repl.w:432`–`490`, issue #276 P3, research
  Q4/Q5): a line starting with `!` is recognized by
  `repl_read_entry` before any W-syntax scanning runs (`repl.w:208`),
  taken verbatim as a single line, and handed to `repl_handle_bang`.
  `!cd dir` and `!export NAME=VALUE` are intercepted builtins that
  mutate the REPL process itself (`chdir`, a session-local env
  override); anything else runs through `lib/shell.w`'s
  `sh_interactive`, `/bin/sh -c` with this process's own stdio
  inherited, so output lands wherever the REPL's own stdout/stderr
  currently point.
- **`lib/shell.w`** (168 lines, on top of `lib/process.w` and
  `lib/env.w`): `sh(cmd)` and `run_argv(argv)` capture stdout/stderr
  into a `shell_result`; `sh_interactive(cmd)` is the non-capturing,
  inherited-stdio twin the `!` escape uses; `cd`/`getenv`/`setenv`
  manage session-local process state (real `chdir`, since there is no
  subshell, but a session-local environment override because this
  platform has no `setenv`/`putenv` syscall).
- **Scripted/agent mode** (issue #276 P3): `-e` one-shot entries,
  `--json` NDJSON output, `--quiet`, prompts routed to stderr when
  stdin is not a tty — all owned by `repl.w`, not `repl/core.w`.
- **The Q1 library split** (already shipped): `repl/core.w` is the
  session/eval engine (`repl_eval`, checkpoint/rollback, fault
  recovery) with no I/O policy; `repl/scan.w` is the continuation
  scanner; `repl.w` is the thin CLI front end owning argument
  parsing, the banner, the prompt loop, `:commands`, and echo
  printing. This split is why shell mode can be built entirely as
  `repl.w`-layer logic (§4, §9) without touching the engine.

## 3. Reconciling the issue with Q4/Q5's reasoning

`repl_improvements.md` Q4 explicitly recommended **against** bare
command fallthrough at the default W prompt:

> Recommended against: making bare `ls -la` fall through to the
> shell — either by "if it fails to compile, run it as a command"
> (every typo becomes a command execution) or by first-token
> heuristics (`ls - la` is valid W when the symbols exist; the
> ambiguity is unresolvable in general).

This design does not overturn that: the default prompt stays
W-first, `!` stays its escape, and no line is ever trial-parsed as
"maybe W, maybe shell." Issue #335 does not actually ask for bare
fallthrough at the *default* prompt either — it asks for a mode
where command-first parsing is the rule, entered by explicit user
action. Q4 anticipated exactly this:

> A dedicated `:sh` toggle that flips the prompt into command-first
> mode is a reasonable later addition if the `!` escape sees heavy
> use.

So `:sh` (§4) resolves the ambiguity by which mode the reader is in,
not by guessing — the same design constraint Q4 imposed, applied to
a second, explicitly-entered mode instead of the default one. Nothing
about the `!` escape's behavior in W mode changes.

## 4. The `:sh` toggle

- `:sh` is a new colon command, dispatched from `main()`'s existing
  `repl_entry`-prefix chain in `repl.w` (`:quit`, `:help`, `:type`,
  ... `repl.w:804`–830) alongside the others, checked before the
  `!`-prefix check and before anything reaches the compiler — exactly
  where every other colon command is already checked.
- It flips a new front-end-only flag, e.g. `repl_shell_mode`, living
  in `repl.w` next to `repl_json_mode` — **not** in `repl/core.w`.
  This mirrors the Q1 split's division of labor (engine vs. I/O
  policy) and needs no engine change. Typing `:sh` again while
  already in shell mode toggles back to W mode: one symmetric
  command, not two.
- On the *first* entry into shell mode in a session, `repl.w`
  synthesizes and evaluates `import lib.shell_commands as
  shell_commands\n` through the ordinary `repl_eval` path — the same
  mechanism `:load` already uses to run a file's declarations into
  the live session (`repl_cmd_load`, `repl.w:382`). A flag remembers
  this happened once per session; `:reset` (which rolls back to the
  genesis checkpoint, undoing everything typed since startup) should
  clear that flag too, since the import itself gets rolled back with
  it.
- The prompt changes to signal the mode (e.g. `sh> ` instead of
  `w> `) so a human and a scripted consumer can both tell which
  grammar the next line parses as. No continuation prompt is needed
  — see the next point.
- **Reading**: `repl_read_entry` (`repl.w:199`) gets one more branch,
  checked in the same place the existing `repl_line.data[0] == '!'`
  check sits (`repl.w:208`): when `repl_shell_mode` is set, the line
  is taken verbatim as a complete, single-line entry, for the same
  reason the `!` case already documents — shell syntax (unbalanced
  quotes, `(`/`)` in a command line) must never reach the W
  bracket/string continuation scanner in `repl/scan.w`. Shell mode,
  like the `!` escape, never spans multiple lines in v1; this is
  exactly why pipes and redirection are deferred (§10).
- **Escaping back, one line at a time**: a shell-mode line beginning
  with `!` is treated as *one W entry* — compiled, run and echoed
  exactly like an ordinary W-mode entry — after which control returns
  to shell-mode dispatch for the next prompt. This reuses the sigil
  symmetrically: `!` always means "the other grammar, for exactly one
  line," in either direction. Concretely, `repl_read_entry`'s
  existing `!`-prefixed branch already isolates the line
  unconditionally; `main()`'s dispatch only needs to check
  `repl_shell_mode` to decide which of "run as W" / "run as a shell
  command" is the *fallthrough* interpretation for a line that did
  *not* start with `!`.
- **Colon commands are unaffected**: they are recognized ahead of
  both the `!` check and the mode branch, so `:quit`, `:help`,
  `:type`, `:time`, `:load`, `:save`, `:reset`, `:symbols` keep
  working verbatim in shell mode (e.g. `:type` on a `shell_commands`
  function, or `:quit` to leave outright). Only bare, non-colon,
  non-bang lines change meaning based on the mode.

## 5. Command-line -> W call translation

### 5.1 Named arguments do not exist — what actually gets generated

`shell_commands.ls(list=true, all=true, path="/home/w/")` from the
issue is illustrative shorthand, not literal W syntax. Checked
against `docs/projects/default_args_variadics.md` and
`grammar/postfix_expr.w`'s `parse_call_suffix`: W has trailing
positional **default parameter values** and W-native **variadic**
parameters, and nothing else — no `name=value` call-site syntax
anywhere in the grammar. The translator must therefore generate a
plain, fully-positional call.

The dotted spelling is closer to reality than it looks, though.
`grammar/import_statement.w`'s header comment documents `import a.b
as f`: it "adds a checked, qualified spelling `f.name`, whose member
must have been declared in the aliased module's file" — the same
mechanism `repl_test`'s `import tests.subfolder as sub` /
`sub.subfolder_value()` case already exercises
(`build.base.json:1431`). So `:sh` synthesizing `import
lib.shell_commands as shell_commands` (§4) makes the issue's own
`shell_commands.ls(...)` spelling compile verbatim — *provided*
`lib/shell_commands.w` declares a bare function literally named `ls`
(the alias is sugar over the same flat global symbol; it does not
create real namespacing — see §8 for the naming-collision tradeoff
this implies).

Only the argument list is fiction: each tool declares a fixed,
documented parameter order with trailing defaults for direct/W-mode
convenience (e.g. `void ls(char* path = c".", bool all = false)`),
but the **translator never relies on the compiler's own
trailing-default mechanism** — command-line flags appear before
positionals (`ls -la /home/w/`) and W's positional call syntax cannot
skip a leading parameter to supply a later one. The translator always
resolves every declared parameter to an explicit literal (a parsed
flag value, or that parameter's documented default) and emits a
fully-positional call:

```
input:     ls -la /home/w/
generated: shell_commands.ls(c"/home/w/", true)
```

(assuming `ls`'s declared order is `path, all`, with `-l` deferred
per §6.2 — the issue's own `list=true` flag has no v1 native
implementation to translate to).

### 5.2 Recognition test — fail closed to native, always

A shell-mode line is translated to a native call only when **all**
of the following hold; any failure hands the **entire original line,
untouched**, to native fallback (§7) — never a partial or best-guess
translation:

1. it contains none of the characters that need real shell semantics
   — `| < > ; & $ ` ~ * ?` (pipe, redirection, chaining, backgrounding,
   variable/command/glob expansion);
2. its first whitespace-separated word names a tool the session's
   translation table knows;
3. every flag token on the line (a word starting with `-`) is one
   that tool's flag table knows, and the remaining positional count
   matches what the tool expects.

This is deliberately simple to implement and to explain: never guess
which of several plausible interpretations was meant.

### 5.3 Tokenization

Reached only once rule 1 above has already excluded every shell
metacharacter. sh-like word splitting: unquoted runs of non-space
bytes are words; `'...'` is a literal span (no escapes recognized
inside); `"..."` recognizes `\"` and `\\` and passes other backslashes
through unchanged; a backslash outside quotes escapes the following
character. No `$VAR` expansion, no `~` expansion, no globbing — those
are exactly the cases rule 1 already routed to native, so the
tokenizer never has to implement them.

### 5.4 Flag and positional mapping

Each tool declares a small table: (short flag, long flag, parameter
index, boolean). A short cluster like `-la` splits into `-l -a`; a
cluster containing one unknown letter fails rule 3 for the whole
line (no partial credit — the letters that *are* known are not
silently applied while dropping the unknown one). Long flags
(`--all`) map to the same parameter as their short form when both
exist. v1 has no valued flags (`-n 5`); a future `head -n 5` would be
the first.

Whatever tokens remain after removing recognized flags are
positionals, assigned to the tool's positional parameters in typed
order (`cp a b` -> `(a, b)`).

### 5.5 Code generation and quoting

One entry text is built and handed to the *same* `repl_eval` any
ordinary entry already goes through — no new engine path, so a bug
inside a `shell_commands` function is covered by the existing
checkpoint/rollback and runtime-fault recovery exactly like a bug in
user code is today. Each value becomes a literal in the generated
text: strings become a `c"..."` C-string literal (matching every
other `char*`-typed helper in `lib/path.w`/`lib/file.w`/`lib/shell.w`)
with backslash and double-quote escaped — a small dedicated escaper,
since this is arbitrary user-typed text becoming source text, not an
already-trusted internal path — and booleans become the literal words
`true`/`false`.

### 5.6 Echo

`shell_commands` functions return `void` in v1 (§6.1), precisely so a
translated call is a plain call-statement rather than a bare
echoable expression — no stray return-code line after every `ls`. A
function reports its own errors the way a real command would (a
message to its own stderr), which reads more naturally next to real
command output than a REPL echo of some encoded status would.

## 6. The native tool set

### 6.1 Return convention

`void`, for the reason in §5.6. Errors print in coreutils' own
phrasing (e.g. `ls: cannot access '...': No such file or directory`)
to stderr, so the wording looks the same whether a command ran
natively or fell back to the real binary via `sh_interactive` (§7).

### 6.2 v1 candidates: cheap over existing primitives

| Tool | Primitive(s) | v1 scope | Notes |
|------|-------------|----------|-------|
| `pwd` | `getcwd()` (`lib/__arch__/*/syscalls.w`) | full | zero-arg, trivial |
| `ls` | `getdents()` (the `tree.w`/`wbuildgen.w`/`wexec.w` walk pattern) | bare, `-a` | `-l` needs mode/size/mtime — **no portable stat wrapper exists** (see below); deferred until one does |
| `cat` | `lib/stream.w` reader/writer copy loop | one or more paths | binary-safe, no size limit |
| `echo` | none — join args, `println` | full | no filesystem primitive needed |
| `mkdir` | `mkdir()` syscall | single dir; `-p` as a loop over `path_dirname`/`path_join` | cheap either way |
| `rm` | `unlink()`/`rmdir()`; `-r` reuses the `tree_snapshot` getdents walk, deleting bottom-up | single path full; `-r` more code, no new primitive | |
| `cp` | `lib/stream.w` copy loop; `-r` reuses the same recursive walk as `rm -r` | single file full; `-r` more code | |
| `mv` | no portable `rename()` wrapper either (see below) | `cp` then `rm` | loses atomicity — already true cross-device; a real `rename` is a cheap later promotion |
| `head`/`tail` | `file_read_lines` sliced to first/last N | full for typical files | loads the whole file first; a streaming version is a later optimization |
| `wc` | `file_read_text`/`file_read_lines` | full | trivial counting |

**File metadata for `ls -l`.** `lib/stat.w` now provides portable
`file_stat_path` / `file_lstat_path` (Linux `statx` under the hood;
Darwin/win64/wasm still stub `-1`), and `libs/extras/vcs/index.w`
uses it instead of the old VCS-scoped `vcs_statx`. `ls -l` can read
size/mtime/mode/is-dir from that API when it is picked up.
`docs/projects/streams.md`'s follow-ups still mention richer path
helpers beyond the metadata foundation. Until `-l` is implemented,
`ls -l` simply fails the recognition test (§5.2 rule 3, unknown flag)
and falls back to the
real `ls`. `mv` above still recommends `cp`+`rm` rather than a real
rename when a portable `rename` is not the path of least resistance —
`lib/__arch__` now wraps `rename` on Linux, but shell mode has not
been wired to it yet.

Neither limitation is a REPL-platform gap: `repl.w` itself only wires
x86/x64 today (`repl_improvements.md` §1), so an x86/x64-first
shell `ls -l` / `mv` loses nothing shell mode would otherwise have.

### 6.3 Deferred: grep, find, sed

None of these are thin wrappers over one or two syscalls — each is
close to its own small engine (a pattern matcher for grep/sed, a
predicate/expression language for find), and nothing in `lib/` or
`libs/extras/` is a reusable regex/pattern core today
(`parser_generator`'s lexer is a generated-parser building block, not
a drop-in matcher). `find` additionally wants the same missing stat
wrapper for most non-trivial predicates (`-newer`, `-size`, `-type`
beyond dir/file). Farm all three to native indefinitely — the
fallback (§7) already handles them for free, since they are simply
unrecognized command names.

### 6.4 Later, unscoped

`touch`/`chmod`/`ln` (want the same stat/mode wrapper as `ls -l`),
`df`/`du` (recursive size + a mounts view), `ps` (wants `/proc`
walking — closer to its own feature than a coreutils mirror). Not
designed here; mentioned so the "complete set" the issue asks for has
a visible runway instead of stopping at v1.

## 7. Native fallback

Every unrecognized command, unrecognized flag, or
shell-metacharacter-bearing line (§5.2) is handed whole, verbatim, to
`sh_interactive(line)` (`lib/shell.w`) — real `/bin/sh -c` semantics,
inherited stdio, so pipes, redirection, globbing, `$VAR`/`~`
expansion, backgrounding, and any actual coreutils binary all work
exactly as they would at a real shell prompt. This is the "farm out
to native... as an MVP" the issue asks for, and it is already built:
the `!` escape's own handler, `repl_handle_bang` (`repl.w:470`), calls
this same `sh_interactive` — shell mode's fallback and the `!` escape
are the same code path with a different trigger (typing `!cmd` in W
mode vs. an unrecognized bare line in shell mode).

**Correction for the wave plan.** Wave 3 task 3b
(`sonnet_wave_plan_2026_07b.md` §4) names the fallback
`lib/shell.run`; the shipped function is `sh_interactive`, not
`run_argv` (no shell, captures output instead of streaming it,
no `$PATH` search, no globbing/expansion) and not a function literally
named `run`. `sh_interactive` is the right fit specifically *because*
its whole contract is "behave like the real shell would" — the same
contract the `!` escape already relies on. `run_argv`'s captured
output would additionally need to be echoed back through the REPL's
own printer, double-handling something the terminal should see
directly and losing the real shell's expansion along the way.

**`cd`/`export` stay intercepted.** They must mutate the REPL process
itself (`chdir`, the session env override), exactly as `!cd`/`!export`
already require — a native fallback would spawn a child that `cd`s
and immediately exits, changing nothing, and they don't belong in
the `shell_commands` tool table either (they are process-global
session state, not coreutils-style file operations). Shell mode's
dispatch should special-case a bare `cd`/`export` line exactly where
`repl_handle_bang` already does, ahead of both the native-tool table
lookup and the `sh_interactive` fallback.

## 8. Where `shell_commands` lives

`lib/shell_commands.w`, sibling to `lib/shell.w` — not
`libs/extras/`, not `libs/standard/`:

- The `libs/extras/` criterion (spelled out in
  `docs/projects/compress.md`: "like `libs/extras/vcs/`, nothing here
  enters `w.w`'s seed import closure... a leaf library nothing in the
  compiler depends on") is about a package's relationship to the
  *compiler*, not about whether it's REPL-only. `lib/shell.w` already
  lives in `lib/` despite being no more "core" than
  `shell_commands` would be — because it's a general-purpose leaf
  helper any W program can import (scripts, wharness tools, `wexec`
  — Q5's own framing), not a REPL-specific module. `shell_commands`
  is the same shape: ordinary functions over `lib/lib.w`,
  `lib/stream.w`, `lib/path.w` primitives, useful to any W program
  wanting coreutils-flavored file operations, not only to `repl.w`.
- `libs/standard/` (`crypto/`, `net/`, `distributed/`, `web/`) is a
  bigger, ecosystem-facing "batteries" tier; `shell_commands` is a
  small, REPL-adjacent utility module much closer in size and spirit
  to `lib/shell.w` or `lib/path.w` than to that tier.
- Either placement keeps it out of the seed import closure: only
  `repl.w` imports it (directly, or via `:sh`'s synthesized session
  import, §4), and `repl.w` itself sits outside `w.w`'s transitive
  graph (CLAUDE.md's "Seed constraint" list). Current language syntax
  is fine throughout; no `SEEDS` bump is implicated.

## 9. Standalone tool?

**REPL mode first; a thin `wsh` binary later, reusing
`repl/core.w`.** Directly answering the issue's own question:

- `repl/core.w` + `repl/scan.w` are *already* split out as a reusable
  session/eval engine specifically so front ends other than
  `repl.w`'s W-prompt loop can be built on them (`repl_improvements.md`
  Q1's whole point, shipped). Shell mode's translator, tool table and
  dispatch are new logic, but the expensive parts underneath — entry
  staging, compile/run, checkpoint/rollback, fault recovery — are
  exactly what `repl/core.w` already gives for free.
- Building shell mode as a *mode* of the existing REPL, rather than a
  new `wsh` binary from scratch, means it inherits at zero extra
  cost: the `!` escape in both directions (§4), `:type`/`:time`/
  `:load`/`:save`/`:symbols`, `--json`/`-e`/`--quiet` scripted mode,
  and runtime-fault recovery — and it gets to be dogfooded inside a
  tool that already has `repl_test`/`repl_test_x64` coverage.
- A standalone `wsh` built first would either reinvent all of that
  (wasteful — it is the same engine) or ship without it, which is a
  strictly worse "just a shell": it would lose exactly the
  composability Q5 already identified as "the better half of the same
  feature" — dropping into W to inspect a `shell_result`, define a
  helper, or loop over a listing is the whole reason to put shell
  mode inside a W REPL instead of shipping a bash clone.
- Once shell-mode logic has proven itself inside `bin/repl` (stage 2
  of §11), extracting `wsh` becomes cheap and low-risk: a new thin
  front-end file, parallel to `repl.w`'s own role per Q1, that boots
  `repl/core.w`, starts in shell mode by default, and skips the
  W-prompt-loop scaffolding it doesn't need. Recommend deferring that
  extraction until two real front ends would actually benefit from
  it — i.e. until someone wants `wsh` as a login-shell-like
  standalone binary — rather than splitting preemptively.

## 10. Pipes and redirection: deferred

Out of scope here. §5.2's fail-closed rule already routes any line
containing `|`/`<`/`>`/`&`/`;` to native `sh_interactive`, so real
shell pipelines keep working today via the fallback — they simply
don't get native `shell_commands` semantics. A *native* pipe between
two `shell_commands` calls (piping `ls`'s listing into a native `wc`,
say) would want exactly the primitives
`docs/projects/streams.md` already built (`wstream` readers/writers)
plus `lib/process.w`'s existing pipe/fd-redirection support (already
used for farmed-out `sh()`) — wiring one call's output into another's
input as streams rather than direct prints. That also means
revisiting the void-return decision in §6.1 (a tool would need to
expose its output as a `wstream`, not just print it). Real design
work, deliberately left to a future doc once the native tool set has
grown enough to make pipelines between native tools worth the
complexity.

## 11. Staged plan

**Stage 1 == Wave 3 task 3b**
(`docs/projects/sonnet_wave_plan_2026_07b.md` §4), scoped small on
purpose:

1. `:sh` colon command in `repl.w`: toggle `repl_shell_mode`, change
   the prompt, synthesize-and-eval `import lib.shell_commands as
   shell_commands` once per session on first entry (§4).
2. `repl_read_entry`'s new verbatim-line branch for shell mode (§4),
   and `main()`'s dispatch: colon commands first (unchanged), then
   `!` as the escape-in-either-direction (§4), then — in shell mode
   only — `cd`/`export` interception (§7), then the recognition test
   (§5.2) choosing between native-call translation (§5) and
   `sh_interactive` fallback (§7).
3. `lib/shell_commands.w` with exactly **three** tools: `pwd`
   (zero-arg), `ls` (bare and `-a`, no `-l`), `cat` (one or more
   paths, no flags) — deliberately proving all three translation
   shapes (no args, boolean flags, required positionals) without
   touching the missing-stat-wrapper problem (§6.2).
4. `build.base.json` additions to `repl_test`/`repl_test_x64`,
   following the existing convention the `!` escape's own cases use
   (`build.base.json:1461`–`1462`): entering/leaving `:sh` and the
   prompt change; `pwd` alone; `ls` in a scratch directory with known
   contents; `ls -a` showing a dotfile that bare `ls` hides; `cat` on
   a fixture file, and a missing-file error landing on the right
   stream; an unrecognized command (or `ls` with an unrecognized
   flag) falling back to `sh_interactive` and actually running;
   `!`-escape-in-shell-mode round-tripping one W entry and returning
   to shell-mode dispatch afterward; `cd`/`export` still working from
   inside shell mode.

**Stage 2 == wave-plan-C task 3b, landed.** The rest of the v1 subset —
`echo`, `mkdir`, `rm`, `cp`, `mv`, `head`, `tail`, `wc` — is now in
`lib/shell_commands.w`, translated by `repl/shell_translate.w`, with
`repl_test`/`repl_test_x64` cases and unit tests
(`tests/shell_commands_test.w`) for each. Differences from this
section's original sketch, both improvements rather than scope
changes:

- `mv` calls `lib.lib`'s `rename(2)` wrapper directly instead of
  falling back to `cp`+`rm` — §6.2's addendum had already flagged this
  as "not wired up yet" once a portable `rename` existed, so wiring it
  directly (atomic within one filesystem) is strictly better than the
  fallback originally sketched here.
- The shell command "mkdir" is implemented as `mkdir_p`, not `mkdir`:
  `lib/shell_commands.w` already imports `lib.lib`, whose transitive
  `lib.linux` import declares a raw `mkdir(2)` syscall wrapper of that
  exact name, and W's single flat symbol table rejects a second
  top-level `mkdir` with a different signature. The translator still
  recognizes the typed word `mkdir`; only the qualified spelling for a
  direct W-mode call differs (`shell_commands.mkdir_p(...)`, not
  `shell_commands.mkdir(...)`).
- `rm -r`/`cp -r`'s recursive walk uses `lib/stat.w`'s
  `file_lstat_path`/`file_is_dir` (landed via #343, after this doc was
  first written) to classify each entry without following symlinks,
  rather than the `getdents` `d_type` byte `libs/extras/vcs/tree.w`
  uses for the same purpose — the "second consumer" promotion §6.2
  anticipated for `lib/stat.w`.
- `head`/`tail` add the valued flag `-n N`/`--lines N` (also accepting
  `-n=N`/`--lines=N` inline) that §5.4 flagged as "v1 has no valued
  flags... a future `head -n 5` would be the first" — that flag shape
  is now general in `repl/shell_translate.w`, not head/tail-specific.
- `ls -l`'s missing-stat-wrapper blocker is gone (`lib/stat.w` landed),
  but implementing `-l` itself was out of this task's scope and stays
  deferred, not because of the wrapper.

Pipes/redirection (§10) were considered and explicitly deferred again,
per this section's own original staging — the native tool set
(11 tools) still doesn't obviously want piping between two of them
enough to justify the void-return-convention rework §10 describes;
revisit once it does.

**Stage 3+** (research-scale, no wave slot): `ls -l` itself (the
wrapper exists now; only the translator/tool work remains); `touch`/
`chmod`/`du` on the same wrapper; `grep`/`find`/`sed` only if a
reusable pattern-matching core ever exists; pipes/redirection (§10)
once the native tool set has grown enough to want them; the `wsh`
standalone extraction (§9) once two real front ends want
`repl/core.w`.

## 12. Open questions for the maintainer

- **Naming collisions.** `shell_commands` declares bare `ls`/`cat`/
  `pwd`/etc. (via the alias-qualified spelling, §5.1) — acceptable to
  pollute a *session's* flat namespace with those short names (only
  once `:sh` has been used), or should the module use prefixed names
  (`shell_commands_ls`) instead? The alias mechanism needs the
  literal declared name either way — a prefixed name would make the
  qualified spelling `shell_commands.shell_commands_ls(...)`, which
  defeats the point. This doc recommends bare names but flags the
  tradeoff.
- **Scripted mode.** Should `:sh` even be reachable under
  `--json`/`-e`/`--quiet`, or is shell mode explicitly
  interactive-only for v1? This doc assumes interactive-only;
  scripting it would want its own NDJSON shape for a translated
  call's stdout/stderr/status, unspecified here.
- **Exit status.** v1's `void`-return convention (§5.6) means a
  sequence of shell-mode commands has no `$?`-style way to check
  whether the previous one succeeded. Worth an `int` status
  convention later (mirroring `lib/shell.w`'s decoded exit status)
  once shell mode is used for more than one-off interactive commands?
- **Prompt string.** Is `sh> ` acceptable, or is a real-shell-like
  `$ ` preferred despite the (minor) collision risk with a command's
  own output that happens to start with `$`?
