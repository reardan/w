# Prioritized backlog → parallel Fable-5 subagent waves (program 2026-07b)

## Context

**Why now.** The previous program (`docs/projects/wave_plan_2026_07.md`) ran waves 1–4
and landed as PRs #381–#384; its wave 5 was never started. Three earlier programs
(`issue_audit_2026_07.md` → `consolidated_plan_2026_07.md` → `sonnet_wave_plan_2026_07{,b,c}.md`)
are fully drained. So the tracker is stale in both directions again — the exact failure
mode every prior plan called out — and there is no live program.

**What's still open**, from the three canonical sources:
- `docs/todo.txt` — "current limitations" (constructors, struct-array value copies, heuristic
  backtrace, software watchpoints, x64 DWARF `address_size 4`, thread.w Linux-only, wasm gaps)
  and "next priorities" (type system, c_import, wasm stage-5 residue, **W^X split for x86/x64**,
  `import grammar` vs `grammar.*`).
- `docs/projects/ai_tooling_next_steps.md` — ~23 open friction entries (T1–T23 below), the
  repo's dogfooding queue.
- **26 open GitHub issues.** Actionable here: #17 (float16/bf16 residue), #27 (ndarray index
  sugar), #123-residue, #251 (build-system directions), #252 (VCS packing — now unblocked by the
  real DEFLATE encoder), #276 (REPL D1 crash-kills-session), #323 (ban generated files),
  #377 (error messages), #378 (stack traces). Explicitly *not* scheduled: #361 split repo,
  #337 LLVM, #334/#379 UI+fonts, #338 libraries-for-everything, #110 optimization, #332/#333,
  #98 web debugger UI, #28 CUDA (no GPU here), #231 (architecture decision), #287 stage 2
  (policy), #16 protobuf stages 2–3 (maintainer-gated), #107 lambdas (closed not-planned),
  multi-error reporting (research-scale), all darwin-only items (no Mac).

**Intended outcome.** 20 independently-mergeable units across 4 waves, each run by a
Fable-5 subagent in its own git worktree, each opening its own draft PR.

## Environment (this remote Linux x86_64 container)

| Capability | Status | Consequence |
|---|---|---|
| `./w` seed | not present; `https://github.com/reardan/w/releases/.../w-x86-linux` returns 200 | `./wbuild` downloads + sha256-verifies it on first run |
| `node` | present (`/opt/node22/bin/node`) | wasm gates run via `tools/run_wasm.sh`; `wasmtime` absent |
| `/lib/ld-linux.so.2` | **absent**, `libc6:i386` not in apt index | `dynamic_test`, `c_import_test`, `c_import_errno_test`, `c_import_libc_test`, `float_abi_test`, `varargs_test`, `extern_data_test` are **env-blocked** (CI covers them) |
| `qemu-aarch64` | absent | `verify_arm64` and arm64 run targets env-blocked |
| GPU / Mac / wine | absent | `cuda_test`, all `*_darwin`, `tests_win64` env-blocked |
| `bin/` | not built | every worktree bootstraps once |

Units are scoped so **no unit's acceptance depends on an env-blocked target**.

## Execution model

- **Program branch**: `claude/parallel-task-batching-fable5-tuz88l` — carries this plan as
  `docs/projects/wave_plan_2026_07b.md`, pushed first, draft PR opened.
- **Unit branches**: `claude/pb-<id>-<slug>`, cut from the program-branch tip (not `origin/main`
  — a lesson from plan C), one draft PR each into `main`.
- **Waves**: launched as a batch of parallel background `Agent` calls with
  `isolation: "worktree"`, `model: "fable"`. Wave N+1 launches after wave N's green units are
  integrated into the program branch.
- **File disjointness** is by construction; the tables name the conflict zone each unit owns.
  ≤2 units per wave touch `grammar/`, and never the same file. `tests/parser_generator/w.pg`
  additions are append-only and merge trivially.
- **Never hand-edit `build.json`** — it is generated. Agents run `./wbuild manifest`; on
  conflict, regenerate. `docs/projects/ai_tooling_next_steps.md` is union-merged; each agent
  deletes only its own entry.
- **Agents must not background their own test runs** (6 of 8 stalled in plan B wave 2 doing
  this; prompts forbidding it gave zero stalls afterwards). The first cold-cache
  `wtest changed` run takes several minutes and prints progress — budget for it.
- **Single writer per worktree**: never two `./wbuild` invocations against one tree.

## Work units

### Wave 1 — hygiene + build/test tooling (no compiler files → no `verify` gate)

| # | Unit | Files it owns | Change |
|---|---|---|---|
| U1 | Doc/tracker truth sweep | `docs/todo.txt`, `docs/projects/{ai_tooling_next_steps,ai_tooling,parser_generator,wave_plan_2026_07}.md`, new `docs/projects/wave_plan_2026_07b.md` | Delete todo.txt's stale "PG milestone 4 remaining" (shipped 2026-07); resolve the self-contradicting `wc`/strlen entry (T14); move shipped `ai_tooling_next_steps` entries into `ai_tooling.md`; record waves 1–4 close-out; verify issue-audit items 10 (generator-stack leak on `return` out of a `for`) and 23 (struct method chaining) against the tree and write down which are actually open; land this program doc. **Merges first** — every later PR edits these files. |
| U2 | wexec robustness | `tools/wexec.w`, `tests/wexec/` | Per-run-step timeout (T21 — a deadlocked test currently hangs all of `./wbuild` silently), plumbed as a `timeout=` value in the step schema; kill spawned run-step children on termination (T20 half — the ETXTBSY→"could not open output file" confusion); exit-127 diagnostic names the resolved-but-unusable candidate (T5-wexec residue). |
| U3 | wtest selection UX | `tools/test_map.w`, `tools/wtest.w` | Collapse the ~450-target selection for auto-imported-runtime edits (`structures/w_list.w`, `lib/__arch__/*/syscalls.w`) to umbrella targets plus a one-line summary above a threshold; add a `--runnable-here` filter that drops env-blocked targets (T6); stop caching `deps w.w` *failures* against w.w's content hash, which silently pins the seed-graph rule to its prefix floor (T8). |
| U4 | Small dogfooding fixes | `tools/parser_generator_w_batches.sh`, `tools/attach_test.sh`, `libs/extras/c_preprocessor/pp_directives.w`, `lib/shell_commands.w` | `parser_generator_w_test` batch output echoes `batch N (files X..Y) FAILED` (T16); `attach_test`'s `timeout 30` raised/made load-aware after its cold-parallel flake (T15); c_preprocessor "could not read" TOCTOU path gets a real test or is removed (T4); verify-and-prune `wc`'s strlen/NUL truncation claim (T14 code half). |
| U5 | wbuildgen tool-target mode | `tools/wbuildgen.w`, `build.base.json` | New generation mode for "invoke a tool as the whole target" so `manifest`, `manifest_check`, `metadata_check`, `wvdiff_test`, `wexec_keep_going_test`, `wexec_ordered_output_test`, `asm_seed_gate` generate instead of living hand-written (T9; #323 progress, #251 direction 1). Re-verify and close or restate T10's `arch_only=` gap. |

### Wave 2 — compiler driver + diagnostics (seed graph → `verify` required)

| # | Unit | Files it owns | Change |
|---|---|---|---|
| U6 | Compiler `--help` + arg-loop fixes | `compiler/compiler.w`, `build.base.json` (skills_test) | Real top-level and per-subcommand `--help`/`-h` text (only bare `usage:` lines exist today); a `skills_test` asserting every flag documented in `.cursor/skills/` and `AGENTS.md` appears in `--help` (T23); fix "a flag before the arch selector turns the selector into the input file" — `bin/wv2 --strict x64 f.w` → `no such file: 'x64'` (T22); resolve auto-imported runtime relative to `argv[0]`'s directory as well as CWD so the compiler works from outside a checkout (T7); name path + errno in the "could not open output file" assert (T20 half). Serves #377. |
| U7 | `w check` sees inside generics | `grammar/generic.w`, `compiler/compiler.w` (check driver only — coordinate with U6 at integration) | T1: `w check structures/heap.w` today exits clean with ill-typed bodies, because uninstantiated generics are never parsed past the header. Self-instantiate each generic with a synthetic word-sized type argument during `check` so bodies are actually type-checked. This has already let real bugs through twice. |
| U8 | Import diagnostics + `grammar.*` | `grammar/import.w`, diagnostic fixtures | T5: `import lib/assert.w` reports the mangled `cannot locate 'lib/assert/w.w'` with no hint — echo the path as written and hint the dotted form. Settle `import grammar` vs `grammar.*` behavior (todo.txt "directory and build cleanup"). Diagnostic text is frozen by fixtures — update `# expect_stderr:` headers in the same commit. |
| U9 | Better crash stack traces | `debugger/`, `lib/` crash handler, tests | #378: install a fault handler that symbolizes and prints a stack trace on SIGSEGV/SIGBUS/SIGFPE using the DWARF + backtrace machinery already in `debugger/`, plus core-dump metadata. Note (do not fix here) that the backtrace is heuristic without frame pointers. |
| U10 | c_import gaps | `libs/extras/c_import/importer.w`, `tests/` fixtures | Old-style (K&R) declarations; extern arrays of unknown length (`sys_errlist`); add system-header torture fixtures. Bit-field layout fidelity is a stretch within this unit. c_import is in the seed graph → seed-syntax-safe + `verify`. Note: the `c_import_*_test` run targets are env-blocked (no i386 loader) — assert via compile-time fixtures instead. |

### Wave 3 — features on already-shipped tracks

| # | Unit | Files it owns | Change |
|---|---|---|---|
| U11 | ndarray index sugar `m[i, j]` | `grammar/` index path, `tests/parser_generator/w.pg`, `tests/`, `docs/projects/ndarray.md` | #27 remainder / old-plan W5d. The `lib/ndarray.w` substrate shipped; this is the grammar-level multi-index lowering onto it. New syntax → `w.pg` must accept it. `verify` + `verify_x64`. |
| U12 | VCS object packing | new `libs/extras/vcs/pack.w`, `tools/wvc.w`, tests | #252 wave-3 remainder / old-plan W5a — unblocked now that `libs/extras/compress/deflate.w` does real fixed+dynamic Huffman compression. Pack-file format over the existing `cas.w` store + `wvc pack`/`unpack`. Leaf library → no `verify`. |
| U13 | threads: mutexes, atomics, join reclamation | `lib/thread.w`, `lib/__arch__/*`, `docs/projects/threads.md`, tests | todo.txt "threading" limitation: mutex + atomic primitives, worker stack/handle reclamation on join. Keep the arm64/darwin/win64/wasm ports out of scope (env-blocked here) but leave the arch seams in place. |
| U14 | x64 DWARF `address_size` | `code_generator/dwarf.w`, tests | todo.txt x64 limitation: line info still declares `address_size 4` as a gdb-only workaround. Emit 8 for x64 and add a structural regression test that parses the emitted DWARF. `verify` + `verify_x64`. Related history: a `dwarf.w` realloc bug (f13ab7f) was root cause for one of plan C's suspected miscompiles — read that before touching this file. |
| U15 | `type <=> json`: floats + `map[string, V]` | `structures/json_codec.w`, `grammar/json_builtin.w`, tests | todo.txt "future language features": the base feature works; float fields and `map[string, V]`-typed fields are the gap. Touches auto-imported runtime → `verify`. |

### Wave 4 — bigger bets and the risk items

| # | Unit | Files it owns | Change |
|---|---|---|---|
| U16 | **W^X split, stages B + C** | `code_generator/elf_32.w`, `elf_64.w`, `elf_dynamic.w`, `docs/projects/wx_split.md` | **Solo risk item.** win64 stage A landed (two-section R+X / R+W image); x86 and x64 Linux still emit a single RWX segment. Real motivation: RWX makes the IAT unwritable under Windows Memory Integrity/HVCI — a reproducible crash, not hardening theatre. Perturbs ELF layout under every other test → **full verify matrix** (`verify`, `verify_x64`, `verify_wasm`, plus `tests`). No other unit in this wave may touch `elf_*`. |
| U17 | x64 codegen investigation | `code_generator/x64.w` / `x86.w` + regression tests, or a written diagnosis | Plan C flagged two independent sightings in one wave: a "local cached before and after a conditional" crash in `debugger/attach.w`, and a miscompile of a direct `return <name> in <map>` in `compiler/compiler.w`. Both have workarounds in-tree; minimal repros do not trigger. **Timeboxed — a written diagnosis in `docs/projects/` is an acceptable deliverable.** If root-caused, add the regression test and remove the workaround. |
| U18 | Type-system next priorities | `compiler/type_table.w`, `grammar/` type-name resolution | todo.txt: finish `type.fields` usage for globals and imports; qualified type names through import aliases (`f.SomeStruct`). Explicitly *not* in scope: migrating `symbol_table` off its hand-packed byte blob (deliberate — offsets are stable handles). `verify`. |
| U19 | wasm stage-5 residue | `code_generator/wasm*.w`, `docs/projects/wasm_backend.md` | Real-signature exports (instead of the current uniform shape) and the accumulator globals-vs-locals measurement. wasm64 stays deferred. Gates run here via `node` (`verify_wasm`, `wasm_smoke_test`, `wasm_extern_test`). |
| U20 | REPL D1: faults no longer kill the session | `repl.w`, `repl/`, tests | #276's top verified defect: `int* p = 0; p[0]` exits 139 and `1 / 0` exits 136, killing the session — compile errors already recover cleanly through `repl_setjmp`/`repl_longjmp` + the ~20-global checkpoint. Install SIGSEGV/SIGBUS/SIGFPE handlers that long-jump back to the prompt and roll back the same checkpoint. |

## End-to-end test recipe (given to every worker)

The deliverable of this repo is a compiler that compiles itself, so "e2e" means
bootstrap it, run the fixpoint, and execute a real produced binary.

```sh
# 0. One-time per worktree (downloads + sha256-verifies the pinned seed, ~minutes)
./wbuild build

# 1. After every edit — warnings are errors (self-host stages use --strict)
./bin/wv2 check --json <edited-file>          # empty stdout + exit 0 == clean
#    compiler-tree files (compiler/, grammar/, code_generator/) don't check
#    standalone — check w.w instead:
./bin/wv2 check --json w.w
#    a file compiled under several arches:
./bin/wtest archs <edited-file> --check

# 2. Regenerate the manifest if you added or changed a test
./wbuild manifest && ./wbuild manifest_check   # NEVER hand-edit build.json

# 3. Focused tests — derive them, don't guess. RUN IN THE FOREGROUND; the first
#    cold-cache run takes several minutes and prints progress to stderr.
git diff --name-only HEAD | ./bin/wtest changed
./wbuild test_changed

# 4. Self-host fixpoint — REQUIRED if you touched compiler/, grammar/,
#    code_generator/, structures/, debugger/, or any seed-graph lib/ file
./wbuild verify                 # wv3 == wv4 == wv5
./wbuild verify_x64             # additionally for codegen / word-size work
./wbuild verify_wasm            # wasm work (uses node)

# 5. TRUE END-TO-END — compile and RUN a program that exercises your change
mkdir -p bin
./bin/wv2 tests/<your>_test.w -o bin/<your>_test && ./bin/<your>_test
./bin/wv2 x64 tests/<your>_test.w -o bin/<your>_test_64 && ./bin/<your>_test_64
#    language/runtime behavior — drive the REPL non-interactively:
./bin/wv2 repl.w -o bin/repl
printf '<expr>\n:quit\n' | ./bin/repl
#    runtime failures — script the debugger over stdin instead of print statements:
./wbuild wdbg && printf 'b main\nrun\nbt\nquit\n' | ./bin/wdbg <file>.w

# 6. Before declaring done
./wbuild tests                  # full suite; see env-blocked list below
```

**Env-blocked targets** — expected to fail in this container, *not* your regression;
list them in the PR body as CI-covered rather than chasing them:
`dynamic_test`, `c_import_test`, `c_import_errno_test`, `c_import_libc_test`,
`float_abi_test`, `varargs_test`, `extern_data_test` (no `/lib/ld-linux.so.2`);
`verify_arm64` + arm64 run targets (no qemu); all `*_darwin` (no Mac);
`tests_win64` (no wine); `cuda_test` (no GPU).
Capture a `./wbuild tests` baseline *before* your change so gates fail only on regressions.

## Conventions every worker must follow

- **Tab-indented** W source; blocks open with `:`; no semicolons; `#` comments; trailing newline
  required. Spaces are a compiler warning, and warnings fail the self-host build.
- **Seed constraint** — `compiler/`, `grammar/`, `code_generator/`, `debugger/`,
  `structures/hash_table.w`, `structures/w_list.w`, `libs/extras/{c_import,c_preprocessor,parser_generator}`
  and any `lib/` file they import are compiled by the *pinned* seed. **No post-seed syntax there**
  until `SEEDS` is bumped by a release. New syntax is fine in `tests/` and leaf consumers.
- **New syntax must also be added to `tests/parser_generator/w.pg`** — `parser_generator_w_test`
  parses every tracked `.w` file and fails on anything unknown.
- **Diagnostic text is frozen by fixtures.** Rewording a message requires updating
  `# expect_stderr:` / `# reject_stderr:` / `# expect_fail` headers (asserted by `bin/wfixture`)
  or the `build.json` step fields, in the same commit.
- **Adding a test** = create `tests/foo_test.w` (use `lib/assert.w` / `lib/testing.w`), add a
  `# wbuild: x64` directive for a 64-bit twin, then `./wbuild manifest`. Only irregular targets
  get hand-written entries in `build.base.json`.
- **Expression gotchas** that repeatedly bite generated code: `|`/`&` never short-circuit (use
  `&&`/`||` for guards); a hex literal with bit 31 set sign-extends on every target, so
  `x & 0xffffffff` never truncates — build 32-bit masks at runtime (`lib/sha256.w`); `byte` is a
  type name, so `byte = ...` parses as a declaration; **`T* + int` is a raw unscaled byte offset**
  — prefer `&p[n]` or `lib/ptr.w`'s `ptr_add(p, n)`.
- **Dogfooding rule**: any friction hit in `w check`, `wtest`, `wexec` or the other agent-facing
  surfaces gets an entry appended to `docs/projects/ai_tooling_next_steps.md` **in the same PR**.
- `bin/` is gitignored; hand-run compiles need `mkdir -p bin` first.
- Do **not** background your own test runs.

## Verification of the program as a whole

After each wave, green units are merged into `claude/parallel-task-batching-fable5-tuz88l`,
then, on the integrated tip:

```sh
./wbuild manifest && ./wbuild manifest_check
git diff --name-only <pre-merge> | ./bin/wtest changed && ./wbuild test_changed
./wbuild verify && ./wbuild verify_x64 && ./wbuild verify_wasm
./wbuild tests            # minus the env-blocked list
```

Close-out: comment on #17, #27, #123, #251, #252, #276, #323, #377, #378 with what landed;
update `docs/projects/wave_plan_2026_07b.md`'s execution-status section.

## Execution status

| Wave | Unit | Status | PR |
|---|---|---|---|
| 1 | U1 doc/tracker truth sweep | launched | — |
| 1 | U2 wexec robustness | launched | — |
| 1 | U3 wtest selection UX | launched | — |
| 1 | U4 small dogfooding fixes | launched | — |
| 1 | U5 wbuildgen tool-target mode | launched | — |
| 2 | U6–U10 | queued | — |
| 3 | U11–U15 | queued | — |
| 4 | U16–U20 | queued | — |
