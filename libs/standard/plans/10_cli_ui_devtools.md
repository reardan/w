# Plan: CLI, terminal UI, testing, debugging, profiling, and runtime tools

## Target area

Base code directory: `libs/standard/cli/`, `libs/standard/testing/`,
`libs/standard/debug/`, and `libs/standard/runtime/`

Suggested modules:

- `libs.standard.cli.argparse`
- `libs.standard.cli.getpass`
- `libs.standard.cli.fileinput`
- `libs.standard.cli.cmd`
- `libs.standard.cli.curses`
- `libs.standard.testing.unittest`
- `libs.standard.testing.mock`
- `libs.standard.testing.doctest`
- `libs.standard.debug.pdb`
- `libs.standard.debug.trace`
- `libs.standard.debug.timeit`
- `libs.standard.debug.profile`
- `libs.standard.runtime.sys`
- `libs.standard.runtime.warnings`
- `libs.standard.runtime.dataclasses`
- `libs.standard.runtime.contextlib`
- `libs.standard.runtime.inspect`
- `libs.standard.runtime.importlib`
- `libs.standard.runtime.venv`
- `libs.standard.runtime.pydoc`

## Python 3.14 reference implementations

Consult these CPython sources first:

- `Lib/argparse.py` - parser, actions, help formatting.
- `Lib/getpass.py` - password prompt behavior.
- `Lib/fileinput.py` - multi-file line iteration.
- `Lib/cmd.py` - line-oriented command interpreters.
- `Lib/curses/` - terminal control wrappers.
- `Lib/unittest/`, `Lib/unittest/mock.py` - test framework and mocks.
- `Lib/doctest.py` - examples-in-docstrings runner.
- `Lib/pdb.py`, `Lib/bdb.py`, `Lib/trace.py` - debugger and tracing.
- `Lib/timeit.py`, `Lib/profile.py`, `Lib/cProfile.py`, `Modules/_lsprof.c`.
- `Lib/sys.py` docs via runtime C implementation - runtime process info.
- `Lib/warnings.py`, `Lib/contextlib.py`, `Lib/dataclasses.py`.
- `Lib/inspect.py`, `Lib/importlib/`, `Lib/pydoc.py`, `Lib/venv/`.
- `Lib/tkinter/` and `Lib/turtle.py` only as long-term GUI references.

## Current W starting point

- `lib/args.w` provides basic flag/value/positional parsing.
- `lib/termios.w` and `lib/line_edit.w` support raw terminal mode and REPL line
  editing.
- `lib/testing.w` discovers test symbols via ELF introspection.
- `debugger/` implements `wdbg`, an in-process debugger.
- The compiler has diagnostics but no Python-like warnings runtime.
- No mocking, doctest, profiler, runtime reflection, importlib facade, venv, or
  documentation generator exists.

## Goals

1. Add a stronger command-line parser with help text and subcommands.
2. Add terminal utilities that build on existing termios/line_edit.
3. Add a more expressive test framework while preserving current simple tests.
4. Add timing/profiling and trace helpers useful to W developers.
5. Add runtime/sys/import metadata facades where W can support them.

## Non-goals for MVP

- No Tkinter/turtle GUI equivalent.
- No full Python `mock` magic; W lacks dynamic attribute replacement.
- No source-level `pdb` clone before debugger integration is designed.
- No full reflection of arbitrary W values unless compiler metadata supports it.

## API sketch

`cli/argparse.w`

- `arg_parser* argparse_new(char* program)`
- `void argparse_description(arg_parser* p, char* text)`
- `void argparse_add_flag(arg_parser* p, char* name, char* help)`
- `void argparse_add_option(arg_parser* p, char* name, char* metavar, char* help)`
- `void argparse_add_positional(arg_parser* p, char* name, char* help)`
- `void argparse_add_subcommand(arg_parser* p, char* name, arg_parser* child)`
- `arg_namespace* argparse_parse(arg_parser* p, int argc, int argv)`
- `char* argparse_help(arg_parser* p)`

`cli/fileinput.w`

- `fileinput* fileinput_new(list[char*] paths)`
- `char* fileinput_readline(fileinput* in)`
- `char* fileinput_filename(fileinput* in)`
- `int fileinput_lineno(fileinput* in)`

`cli/cmd.w`

- `cmd_loop* cmd_new(cmd_handler* handler, void* ctx)`
- `void cmdloop(cmd_loop* loop)`
- Use `lib.line_edit` for interactive input.

`testing/unittest.w`

- `test_case* unittest_case_new(char* name)`
- Assertions: equal int/string, true/false, fail, raises-like compile/runtime
  helpers where possible.
- `test_suite* unittest_discover(char* prefix)`
- `test_result* unittest_run(test_suite* suite)`

`testing/mock.w`

- MVP: fake function tables and call recording for explicit dependency structs.
- `mock_calls* mock_new()`
- `void mock_record(mock_calls* m, char* name, char* arg_summary)`
- `int mock_called(mock_calls* m, char* name)`

`debug/timeit.w`

- `int timeit_run_ms(timeit_fn* fn, void* ctx, int iterations)`
- `timeit_result* timeit_repeat(...)`

`debug/trace.w`

- `void trace_enable_calls()`
- `void trace_disable()`
- Requires compiler/runtime hooks; start with manual scoped trace helpers.

`runtime/sys.w`

- `list[char*] sys_argv(int argc, int argv)`
- `char* sys_executable()`
- `int sys_word_size()`
- `char* sys_platform()`

`runtime/warnings.w`

- `void warnings_warn(char* category, char* message)`
- `void warnings_filter(char* category, int action)`

## Implementation phases

### Phase 1: argparse

- Build on `lib.args` but replace ambiguous flag-value behavior with declared
  argument specs.
- Support `--help`, short/long flags, options, positionals, required options,
  defaults, and subcommands.
- Generate help text deterministically.
- Tests: help output, missing required, unknown arg, subcommand parse, `--`.

### Phase 2: fileinput and getpass

- `fileinput`: iterate stdin or provided files, track filename/line number.
- `getpass`: use `lib.termios` to disable echo, restore on errors.
- Tests: multiple files, stdin path marker, terminal restore path via unit-level
  termios abstraction if possible.

### Phase 3: cmd and terminal helpers

- Wrap `lib.line_edit` into command loop with prompt, dispatch, EOF handling.
- Keep command dispatch explicit: handler gets raw line and context.
- Curses can be a later FFI wrapper to ncurses; do not block cmd on curses.

### Phase 4: unittest facade

- Layer suites/results/reporting on top of existing ELF symbol discovery.
- Add setup/teardown function naming conventions if needed.
- Tests: passing/failing assertions, result counts, failure messages.

### Phase 5: mocks and doctest

- Mocks should be explicit call recorders, not runtime monkeypatching.
- Doctest can parse comments/doc blocks in W files only after a doc-comment
  convention is chosen.
- Tests: call recording, expected/actual output parsing for simple examples.

### Phase 6: timeit/profile/trace

- Implement `timeit` using monotonic clock.
- Profiling needs compiler instrumentation or debugger hooks; write a design doc
  before public `profile` API.
- Trace can start as manual event logging with timestamps.

### Phase 7: runtime/sys/import/doc tools

- `sys` can expose argv, platform, word size, compiler version.
- `importlib` should initially wrap package discovery from `pkg` plan.
- `pydoc` equivalent needs parsed comments plus module discovery.
- `venv` equivalent belongs with package ecosystem once install roots exist.

## Compatibility notes from Python

- Python `argparse` is feature-rich but portable to W in stages; prioritize clear
  errors and help text.
- Python `unittest.mock` relies on dynamic object semantics. W should use explicit
  dependency injection and call recording.
- Python debugging/profiling hooks depend on interpreter frames. W may need
  compiler-emitted metadata and debugger integration instead.
- Python GUI modules are out of scope for a systems-first W stdlib.

## Acceptance criteria

- `argparse` can replace `lib.args` in at least one repo tool without behavior
  loss and with better help/errors.
- `unittest` reports pass/fail/error counts and integrates with the existing test
  runner.
- `timeit` produces repeatable relative measurements for small W functions.
- Terminal helpers restore TTY state after normal and error paths.
