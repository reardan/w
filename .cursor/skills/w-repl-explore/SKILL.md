---
name: w-repl-explore
description: Answer questions about W language behavior by evaluating code in the W REPL instead of writing throwaway test files. Use to check semantics, try expressions, or reproduce a suspected miscompile quickly.
---

# Exploring W behavior in the REPL

The REPL compiles each entry into executable memory and runs it
immediately; definitions persist across entries. It reads stdin, so it is
fully scriptable.

## Setup and scripting

```sh
./bin/wv2 repl.w -o bin/repl     # or: make repl (builds and attaches a prompt)
printf 'print(c"hi\\x0a")\n:quit\n' | ./bin/repl
```

Piped input keeps explicit tabs; a line ending in `:` opens a block and a
blank line closes it (Python-style):

```sh
printf 'int twice(int n):\n\treturn n * 2\n\ntwice(21)\n:quit\n' | ./bin/repl
```

- A bare expression echoes its value.
- Top-level declarations become persistent globals; redefining a name
  shadows the old binding.
- A bad entry rolls back via checkpoint instead of killing the process,
  so one typo does not end the session.
- `./bin/repl file.w [args...]` compiles and runs a program first, then
  attaches the prompt to its live definitions (`--no_main` skips `main`)
  — useful for poking at a program's functions interactively.
- `:quit` exits (always end piped input with it), `:help` lists commands.

Programmatic alternative: the `w-toolchain` MCP server's `repl_eval` tool
takes `entries: string[]` and returns captured output.
