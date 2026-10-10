# wsh: standalone W shell

`wsh` starts the W REPL engine in shell mode (issue #335). Bare commands
use the shared shell dispatcher: session-defined W functions and built-in
tools run in W, and external commands are available through the same
shell syntax. The launcher shares its implementation with `repl`.

Build and start it from the repository root:

```sh
./wbuild wsh
./bin/wsh
```

A terminal session uses the REPL line editor and `sh>` prompt. `:quit`
exits; `:help` describes the shared REPL commands. `./bin/wsh --help`
prints command-line help without starting a session. Run from the
repository root so the runtime compiler can find W library sources.

For scripts, use `-c` or pipe input:

```sh
./bin/wsh -c 'echo hello; pwd'
./bin/wsh -c 'false || echo recovered'
printf 'echo hello\npwd\n' | ./bin/wsh
./bin/wsh -c 'false'
echo "$?"                         # 1
```

`-c` executes its shell command string and exits without reading a
prompt session. Unquoted newlines separate commands, as do semicolons;
pipelines and `&&`/`||` use the shared shell parser. The exit code is the
last command's status. Piped and interactive sessions likewise return
the last shell status at EOF or `:quit`. A missing `-c` argument is a
usage error (status 2); an empty command string succeeds. Piped sessions
write prompts to stderr, leaving stdout for program output.

In a prompt or piped session, prefix a line with `!` to evaluate W while
staying in shell mode:

```text
sh> !int answer = 41
sh> !answer + 1
42
sh> echo still in shell mode
```

`:sh` toggles between W and shell syntax. In W mode, `!` runs a shell
command instead. Switch to W mode to define a multiline function, then
switch back to call it with shell syntax or use it in a pipeline:

```text
:sh
int greet():
	println(c"hello from W")
	return 0

:sh
greet | cat
:quit
```

The `!` W escape and `:sh` are session commands; `-c` accepts shell
commands. `cd` and `export` update the shared session state.

Add `--json` for a JSON record describing the entire shell command line,
including a pipeline: `entry`, captured `output` and `stderr`, numeric
`status`, and null `echo`/`error`. The process still exits with the shell
status, so automation can inspect either the exit code or the record.

The entry point in `wsh.w` imports `repl.frontend` and calls
`repl_main(argc, argv, 1)`; `repl.w` calls the same function with `0`.
Keeping `main` in the two wrappers avoids importing another entry point.
There is no separate parser or evaluator in the launcher.
The build directives live in `tests/wsh_test.w`, a directory scanned by
the manifest generator; they compile the root-level `wsh.w` source.

`./wbuild wsh_x64` builds the 64-bit launcher. `./wbuild wsh_test` runs
scripted checks against both architectures, covering exit status,
command lists, input, mode switching, W escapes, session state, help,
JSON output, interactive PTY input, and native/session-function pipelines.
