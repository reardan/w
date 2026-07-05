# wexec: the W-native build executor

Goal: replace the Makefile with a build system written in W itself. The
chosen shape (out of the designs considered) is a two-layer, Ninja-like
split: a static JSON manifest describes targets, and a small, dumb
executor written in W runs them. The manifest stays trivially parseable
and analyzable; the executor core stays small enough to trust while
being compiled by the toolchain it is building.

## Pieces

- `tools/wexec.w` — the executor. Loads a manifest, resolves the target
  DAG depth-first (with cycle detection), and runs each step as a child
  process via `lib/process.w`'s `process_run`, so stdout/stderr are
  captured, stdin can be fed from the manifest, and timeouts are
  enforced without any shell.
- `build.json` — the manifest at the repository root. Ported targets so
  far: `wv2`, `build`, `verify` (the self-host fixpoint), `hello`,
  `test`, `lib_test`, `x64_test`, `dynamic_test`,
  `int64_x86_error_test`, `wdbg`, `wexec` (self-rebuild) and the
  aggregate `tests`.
- `wbuild` — the bootstrap script, the only shell in the path:
  `./w w.w -o bin/wv2`, `bin/wv2 tools/wexec.w -o bin/wexec`, then
  exec `bin/wexec "$@"`. Everything after that is manifest-driven.

## Manifest format

The root object has optional `"dirs"` (created with mkdir before any
target runs; `bin/` lives here because it is gitignored) and a
`"targets"` array. Each target: `"name"`, optional `"deps"` (names run
first), optional `"steps"`. Each step:

- `"cmd"` — argv array, required. `argv[0]` is resolved against PATH
  when it contains no slash (execve does no lookup itself).
- `"stdin"` — text piped to the child.
- `"expect_stdout"` / `"expect_stderr"` — substring the captured stream
  must contain; replaces the Makefile's `| grep -q` pipelines.
- `"expect_fail"` — step must exit nonzero; replaces Make's `! cmd`.
- `"timeout_ms"` — per-step timeout, 0/absent = none.

Execution model: targets run at most once per invocation and there is
no caching or staleness check — like the Makefile's FORCE targets,
requesting a target runs it. Steps run sequentially; the first failure
aborts with exit 1.

## Lessons already encoded

- A target that rebuilds a running executable (the `wexec` target
  rebuilding `bin/wexec`) must compile to a staging path and `mv` it
  into place: opening the running binary for write fails with ETXTBSY.
- The seed supports `-o`, so nothing needs the Makefile's
  `> file && chmod +x` redirect dance; wexec has no shell redirection
  on purpose.

## Testing

`make wexec_test` (part of `make tests`) compiles the executor and
drives it over the fixture manifests in `tests/wexec/` (dependency
order, run-once semantics, `--list`, failing steps, `expect_fail`,
missing-substring failures, unknown targets, cycles, invalid JSON,
missing manifest, no-argument usage) and then runs the real
`build.json` `hello` target end to end. `tools/test_map.w` maps
executor/manifest/fixture changes to `wexec_test`.

## Not yet done (the rest of the migration)

- Port the remaining Makefile targets. Most are mechanical; the awkward
  ones are `float_reference_test` (invokes `cc`), `repl_test`'s pty
  case (`script -qc`), `parser_generator_w_test` (`git ls-files` into a
  file), `mcp_test` (python3), and `update` (seed promotion — port
  last, keeping behavior byte-for-byte).
- Content-hash caching so unchanged targets can be skipped, replacing
  both FORCE-everywhere and the `w: *.w */*.w` mtime rule.
- Parallel execution of independent DAG branches.
- Delete the Makefile once parity is reached and CI runs `./wbuild`.
