---
name: w-check-diagnostics
description: Diagnose W compile errors and warnings with the compiler's structured check mode instead of full compiles. Use when a .w file fails to compile, when the edit hook reports diagnostics, or before running any tests on modified W code.
---

# Diagnosing W code with `w check`

## Commands

```sh
./bin/wv2 check --json file.w        # compile-only, NDJSON diagnostics on stdout
./bin/wv2 check --json x64 file.w    # same, 64-bit target
./bin/wv2 check --strict file.w      # warnings promoted to a failing exit
./bin/wv2 symbols --json file.w      # declaration metadata (go-to-definition)
```

`bin/wv2` comes from `./wbuild build` (or any `./wbuild` target). No ELF is
written in check mode, so this is the cheapest way to validate an edit.

## Reading the output

One JSON object per line: `file`, `line`, `column` (1-based), `severity`
(`warning` | `error`), `message`, `token`, `arch`. Empty stdout with exit
0 means the file is clean. Exit 1 means an error record was emitted.

Limitations to remember:

- The compiler is single-pass: you get **all warnings up to the first
  error, then it stops**. After fixing the reported error, re-run check —
  there may be more behind it.
- Warnings matter: the self-host build stages compile with `--strict`,
  so a stray warning fails `./wbuild build`.

## Which file to check

- Ordinary programs, `lib/`, `structures/`, `tests/`, `tools/`: check the
  file itself.
- Compiler tree (`compiler/`, `grammar/`, `code_generator/`, `w.w`,
  `grammar.w`, `codegen.w`): modules do not compile standalone; check the
  entry point `w.w`.
- Debugger modules: check `debugger/debugger.w`.

The `postToolUse` hook in `.cursor/hooks.json` applies this mapping
automatically after every `.w` edit and injects any diagnostics into the
conversation.

## Typical loop

1. Edit the file.
2. `./bin/wv2 check --json <file>` (or read the hook's injected output).
3. Fix, re-check until stdout is empty.
4. Pick tests with `./bin/wtest changed <file>` (see the w-select-tests
   skill) and run them.
