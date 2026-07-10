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

Selection is manifest-driven: `bin/wtest` parses `build.json` at runtime,
so a target is selected when (a) one of its steps names the changed path
(fixtures, grammars, scripts, data files) or (b) one of its compile
roots' transitive import closures contains the changed `.w` file
(computed via `bin/wv2 deps`, cached in `bin/.wtest_deps_cache` — the
first run after a build takes ~35s, later runs are sub-second). On top
of that, residue rules documented at the top of `tools/test_map.w`
cover what the import graph cannot see:

- Compiler-tree files map to `verify self_host_warning_test` — the
  self-host fixpoint is the key regression guard; run it for **every**
  compiler/grammar/codegen change, and add `verify_x64` when codegen or
  word-size behavior changed.
- Every existing `.w` change adds `parser_generator_w_test` (it parses
  every tracked `.w` file).
- Deleted `.w` files and `lib/`/`structures/`/`libs/` paths add
  `metadata_check` (declared module trees must resolve to files).
- Docs (`docs/`, `*.md`, `*.txt`) and `.cursor/` map to nothing.
- Paths nothing knows about fall back to the full `tests` umbrella.

A new test target in `build.json` is picked up automatically — its steps
name the test file. Add a residue rule in `tools/test_map.w` only for
coupling the import graph cannot see (run-time data files,
non-default-arch modules).

## The full gate

Focused targets are for iteration. Before declaring work done, run the
full suite: `./wbuild tests` (includes `verify`, x64
fixpoint, stdlib/structures, REPL, debugger, dynamic linking, MCP/LSP
and hook tests).
