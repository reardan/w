# Failing-program minimizer

`w reduce` removes declarations, indented blocks, statements and contiguous
chunks of lines while a user-supplied predicate continues to succeed:

```sh
bin/wv2 reduce failing.w -o minimal.w -- ./interesting.sh
bin/wv2 reduce failing.w --timeout-ms 5000 --max-tests 300 -- ./interesting.sh '{}'
```

The predicate receives a candidate filename as its last argument. If an argument
is exactly `{}`, that argument is replaced instead; multiple placeholders are
allowed. Commands are resolved through `PATH` and executed directly, without a
shell. To use shell expressions, explicitly pass `sh -c` and quote arguments.
The current working directory and environment are inherited.

Exit status **0 means interesting**. Every other exit status, signal or timeout
rejects a candidate. The predicate must reproduce the actual failure: accepting
any compiler error can accidentally reduce a crash to an unrelated syntax error.
For wrong-output bugs, first require compilation to succeed, then compare the
program's output or exit status against the expected bad result. For a compiler
diagnostic, require that particular diagnostic as well as a failed compilation.
For example, an `interesting.sh` for a diagnostic could contain:

```sh
#!/bin/sh
log=$(mktemp) || exit 1
trap 'rm -f "$log"' EXIT
if bin/wv2 check "$1" >"$log" 2>&1; then
    exit 1
fi
grep -Fq "Cannot find symbol: 'problem_name'" "$log"
```

Make the script executable before using it. The reducer discards predicate
stdin, stdout and stderr; write a separate log from the predicate when needed.
Predicates should be deterministic and must treat the candidate as read-only.
They may compile it to their own temporary output. A timeout kills the predicate
process group, including ordinary subprocesses.

The original must satisfy the predicate before reduction starts. Trials use an
exclusively created sibling of the source (`input.w.reduce-PID-N.w`), preserving
the directory used to resolve relative imports. The original file is never
rewritten. The candidate filename differs from the original, so predicates or
programs depending on the exact filename may need adaptation.

The default output is `input.w.reduced.w`; `-o` selects another path. Output is
created exclusively, so an existing file, symlink or hardlink alias is never
overwritten. A failed initial predicate creates no output. The final report
shows original and reduced sizes and the number of predicate invocations.

`--timeout-ms N` defaults to 10000 milliseconds per invocation. `--max-tests N`
defaults to 1000 invocations, including the initial check. Both accept positive
decimal integers through 999999. At the test limit the best accepted source is
saved and the command succeeds with a limit notice. Without a limit interruption,
passes repeat until neither block nor line removal makes progress. This is a
local minimum for those transformations, not a globally smallest program.

The reducer does not require the input or intermediate trials to parse. It uses
indentation to find statement subtrees, then delta debugging over line chunks;
it does not simplify expressions or rewrite tokens. Original bytes, line endings
and missing final newlines are preserved in retained lines. Embedded NUL bytes
are rejected. Imported modules are not reduced. Place the final output beside
the source if it must keep the same relative imports.

This implementation requires a Unix host with subprocess support. Windows and
WebAssembly/WASI host invocations report that reduction is unsupported.
`w reduce --help` (or `-h`) prints the command syntax.
Regression tests in `tests/reduce_test.w` exercise the public compiler command
with compiler-diagnostic and runtime-exit predicates, relative imports, paths
containing spaces, rejected originals, timeouts, budgets and overwrite protection.
