---
name: w-select-tests
description: Map changed files to the smallest useful set of test targets in the W repository. Use after any code change, before running tests, instead of defaulting to the full `./wbuild tests` suite.
---

# Selecting the right W tests

## Commands

```sh
./wbuild wtest                               # build bin/wtest once
./bin/wtest changed path/to/file.w ...       # print the focused targets
git diff --name-only HEAD | ./bin/wtest changed   # targets for the whole diff
./wbuild test_changed                        # same, and runs them
./bin/wtest changed --verbose ...            # explain file -> target mapping
```

Run the printed targets with `./wbuild <targets>` (independent targets
run in parallel and toolchain builds are content-hash-cached; `-j N`
overrides the parallelism, `--no-cache` forces reruns).

## Interpreting the mapping

- Compiler-tree files map to `verify self_host_warning_test` — the
  self-host fixpoint is the key regression guard; run it for **every**
  compiler/grammar/codegen change, and add `verify_x64` when codegen or
  word-size behavior changed.
- Docs (`docs/`, `*.md`, `*.txt`) map to nothing.
- Unknown paths fall back to the full `tests` umbrella.
- The mapping lives in `tools/test_map.w`; if you add a test target,
  register it there too.

## The full gate

Focused targets are for iteration. Before declaring work done, run the
full suite: `./wbuild tests` (includes `verify`, x64
fixpoint, stdlib/structures, REPL, debugger, dynamic linking, MCP/LSP
and hook tests).
