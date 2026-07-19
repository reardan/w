# Sonnet wave plan C (late July 2026): open issues → parallel-subagent tasks

Status: plan (2026-07-19). Successor to
`docs/projects/sonnet_wave_plan_2026_07b.md`, whose four waves are merged
(PR #339). Inputs: all 23 open GitHub issues (bodies + every comment
through 2026-07-18, including PR #339's per-issue status comments on
#123/#251/#252/#276/#287/#323/#327/#329/#334/#335/#337/#338/#16), the
friction backlog in `docs/projects/ai_tooling_next_steps.md`, the #323
stage-2 inventory in `docs/projects/build_system_next.md` (12 shell
scripts + 168 hand-written `build.base.json` targets, bucketed A–K by
exact migration blocker), and verification of head (`20e3a35`): the
`:sh` shell mode (`repl/shell_translate.w`, `lib/shell_commands.w`),
`wv2 defhash`, `wexec --trace`, compress stage 2 + zlib-compressed CAS
objects, the attach memory seam, and PG milestone 3 are all in-tree;
bracketed paste and tab completion are **not** (grep-verified — still
open from #276 P2), and `lib/stat.w` + the Unix metadata CLI tools
landed post-plan-B via PRs #340/#343.

Execution model (unchanged): waves of parallel **Sonnet 5** subagent
PRs, one task per agent in an isolated worktree, sequential merge after
green. Every task is specified with files, gates, and a care level.
**HIGH**-care tasks touch the seed import graph, `grammar/`,
`code_generator/`, or the compiler front end; at most one per wave, and
it merges **last and alone** with `./wbuild verify` (+ `verify_x64`)
green. Investigation tasks are timeboxed with a written diagnosis as the
acceptable fallback deliverable.

## Execution status

**Wave 1 complete (2026-07-19): all 8 tasks merged.** Executed by
parallel Sonnet 5 subagents in isolated worktrees, merged sequentially
(1b last & alone), `verify` + `verify_x64` green at every seed-touching
merge, full suite at wave close: 422/430 succeeded — the 7 failures are
exactly this environment's missing-`libc6:i386` dynamic 32-bit targets
(CI covers them), plus the dependent `tests` umbrella skip. Per-task:

- **1a** doc/tracker sync: defhash/silent-exit/itoa/stream summaries
  moved to `ai_tooling.md`, todo.txt refreshed (stale attach-phase claim
  fixed), plan §0 updated for #344's merge.
- **1b** imported-file diagnostic lines: the backlog's `compile_save
  + 1` theory was HALF the story — paired defects (stale `nextc`
  lookahead priming the imported file's line counter at 1, and
  `compile_save` never saving `nextc`, which the `+ 1` mis-compensated).
  Both fixed; 135/135 closure diagnostics shift to exact lines;
  regression fixture pins importer + imported lines.
- **1c** generator coroutine-stack mmap now checked
  (`__w_gen_mmap_failed`, message + exit 1).
- **1d** `# wfixture: <selector>` directive; all 13 x64-gated
  `cuda_diagnostics_test` steps migrated into fixture headers (target
  is now one wfixture invocation over 15 fixtures).
- **1e** `lib/args.w` `args_declare_bool`/`args_has_bool_flag`
  (declaration model, zero behavior change for undeclared callers);
  stat/readlink migrated off hand-rolled argv walks.
- **1f** wexec single-writer lock (`bin/.wexec_lock`, pid + liveness
  via `kill(pid,0)` for darwin-compat, stale reclaim, `defer` release,
  `WEXEC_LOCK_HELD` env reentrancy for nested wexec test invocations);
  `wexec_lock_test`. Found+logged: `wexec_resolve_program` picks the
  first *readable* (not executable) PATH candidate.
- **1g** `unrecognized option: '<arg>'` diagnostic in `link_impl`'s
  shared flag loop (covers link/check/deps/symbols/defhash);
  `unrecognized_option_test` guards `--bounds=off` stays valid.
- **1h** `lib/ptr.w` generic `ptr_add[T]`/`ptr_diff[T]` (grammar took
  the generic on the first try); exemplar `&p[n]` conversions in
  compress; README/CLAUDE.md rule updated.

Process notes: agent worktrees cut from origin/main (not the program
branch) — wave-2+ agents must fetch+reset onto the program branch tip
first; the shared backlog file (`ai_tooling_next_steps.md`) conflicted
on nearly every merge (1a's rewrite vs. per-task edits) — resolved by
union, entries marked shipped.

**Wave 2 complete (2026-07-19): all 8 tasks merged.** Full suite at
wave close: 430/438 — only the 7 environmental dynamic-linker failures
plus the dependent umbrella skip. Between the waves, one CI-only
failure was found and fixed by the orchestrator: `wexec_pid_alive`
treated `kill(1,0)`'s `-EPERM` (unprivileged CI runner probing pid 1)
as "dead"; only `-ESRCH` means the holder is gone. Per-task:

- **2a** bucket D: 11/21 migrated (incl. the 4 `X_test_x64`→`X_64_test`
  renames); the other 10 documented as real blockers, 6 of which 2b's
  `name=` now unlocks as follow-up.
- **2b** `name=`/`argv=` directives; 14 targets generated, five legacy
  bundled 32+64 targets split into standard twins; the
  x64-only-source gap (no way to suppress the default-arch twin) is
  the documented remainder.
- **2c** `compile_fail` directive (reuses wexec's generic per-step
  expect fields); `int64_x86_error_test` generated from its own source.
- **2d** `tool=` path-resolved target deps + `fixture_group=` sidecar
  files (`<fixture>.w.wbuild` — inline directives would shift fixtures'
  self-referenced line numbers); 11 bucket-K targets migrated including
  `warning_test`/`type_system_*`; combined manifest: 479 targets, 325
  generated (was 284 at wave start).
- **2e** zlib interop shell script ported to W (`lib.process`-spawned
  python3, binary-safe via files, skip semantics preserved); script
  deleted. Friction logged: `process_run` stdin is strlen-based.
- **2f** `pac_flag_check.sh` ported to W (discovery: the script never
  parsed ELF — byte-pattern greps + one fixed-offset read; the W tool
  mirrors that scope with per-assertion messages); script deleted.
- **2g** opt-in `wtest --defhash`: comment-only edits skip
  import-closure selection; fail-open everywhere; default selection
  proven byte-identical; scratch-git-repo test target.
- **2h** recursion-depth guard: `(`-grouping (limit 1000) +
  `statement()` (limit 200 — boxed empirically between lib.w's real
  132-branch else-if chain and the pre-existing `ctrl_stack[256]`
  bound, which is now documented); REPL-longjmp-safe via
  reset-at-entry; 4 fixtures; 100k-deep parens now error cleanly.

Process notes: six of eight agents stalled waiting on their own
backgrounded test runs (the plan-B failure mode at larger scale —
~20 load average from 8 concurrent suites); explicit
resume-with-foreground-commands recovered every one, and wave-3
prompts must forbid self-backgrounding outright. Transient
`http_server_*` failures under load re-run green individually.
`wtest_map_test` showed baseline-reproducible flakiness in one
worktree (not on the program branch) — unexplained, logged.

**Wave 3 complete (2026-07-19): all 6 tasks merged, zero stalls**
(prompts forbade self-backgrounding — the fix worked). Full suite at
wave close: 433/441, only the environmental failures. Per-task:

- **3a** REPL bracketed paste (ESC[2004 mode, atomic paste consumption,
  auto-indent/blank-line suspension), tab completion (lib-agnostic
  `le_complete_hook` fed by the live symbol table), Ctrl-R incremental
  reverse search. Ctrl-R is untestable under `script -qc` (canonical-
  mode race drops the byte pre-raw-mode — diagnosed, documented, PTY
  transcript + pure-logic unit test instead).
- **3b** shell mode stage 2: echo/head/tail/wc/mkdir_p/rm/cp/mv native
  (`mkdir` name collides with the syscall wrapper — renamed; `mv` is
  atomic `rename(2)`); valued-flag translator machinery (`-n N`);
  pipes explicitly deferred per the design doc's own bar.
- **3c** #123: register seam (sigcontext vs ptrace behind the memory
  seam's dispatch idiom), locals/args/frames + `set` in attach mode
  (reusing locals.w unmodified), x86-64 attach symbolization
  (`bin/wdbg64`); attach_test grew 32-bit + x64 sections; real ptrace
  verification (no YAMA in this container).
- **3d** the 6 c_import/preprocessor `error(c"")` sites migrated to
  `diag_part` — `--json` NDJSON records now carry full messages (was
  empty), stderr byte-identical, proven by old-vs-new compiler diff
  over crafted repros; 2 unreachable-site residues documented.
- **3e** `bin/wtest archs <file> [--check]`: enumerates every
  (arch, root) whose closure contains the file (incl. wexec_darwin via
  a wv2_darwin-aware root scan) and per-arch `check` — the win64
  sys_socket class of break is now visible pre-build; synthetic
  arch-broken fixture proves the FAIL path.
- **3f** PG milestone 4 (closes #329's list): `{ code }` actions +
  `&{ expr }` predicates (streaming-mode only; AST mode rejects),
  action-safety via milestone 3's whole-grammar committed-dispatch
  guarantee, `$n`/`text(n)` bindings with their own validator, grammar
  `import` directive, emit-as-you-parse demo grammar + 10 tests;
  `generated_c_parser.w` byte-identical. Bonus find: a pre-existing
  streaming-codegen segfault (factorable prefix + nullable suffix),
  reproduced independently and documented.

## 0. In-flight work — keep clear

**Update (2026-07-19): PR #344 has merged.** CUDA stage 4 (atomics,
explicit memory API, device intrinsics, `range(start, end)`, the
const-based capture-write diagnostic) is now in-tree (merge commit
`108db42`). Task 1d's `cuda_diagnostics_test` migration is therefore
**unblocked** — its fixture payoff no longer needs the "only if #344
has merged by execution time" hedge from its task row below.

One PR remains open on the CUDA/GPU surface: **#342** (torch stages
1–3: `lib/tensor.w`, `gpu_atomic_add`, `gpu_available` — branch
`claude/torch-stage123-tensor-gpu`, not yet merged). Its surface
(`lib/cuda.w`, `lib/tensor.w`, `grammar/gpu_builtin.w`,
`grammar/atomic_builtin.w`, `code_generator/ptx.w`,
`docs/projects/cuda.md`/`torch.md`, and the cuda/gpu/tensor test
targets) stays off-limits — no task below may touch it. Tasks that
brush against the grammar (2h's grammar-wide change) carry explicit
defer/rebase notes. #17's bfloat16 half and #28's remaining scope ride
#342's track, not this plan.

Also verified landed (do NOT schedule): everything in plan B's four
waves (see its Execution status section and PR #339's issue comments) —
shell mode MVP, defhash, `--trace`, real DEFLATE + compressed objects,
silent-exit audit, allocator root cause, PG streaming mode, attach
calibration/list, the compilation-model/ui-framework/protobuf/
repl-shell design docs — plus #340 (unlink/rename syscalls), #343
(`lib/stat.w`, stat/readlink/basename-style tools), #344 (CUDA stage 4,
per the update above), and #345 (Unix metadata primitives: utimens,
chown, passwd, wait_any).

## 1. Prioritization rationale

1. **Root-caused bugs with written fix sketches first.** The
   imported-file diagnostic line-number bug (+1 on every diagnostic in
   every imported file) is root-caused in the backlog with the exact
   culprit (`compile_save` saves `line_number + 1`); the
   `lib/generator.w` unchecked `mmap()` and `lib/args.w` bool-flag bugs
   are small and sketched. Cheap, real correctness wins.
2. **Doc/tracker sync stays wave 1** — the standing lesson from three
   prior programs: stale backlogs cause duplicate agent work.
3. **The #323 stage-2 sweep is this plan's ideal parallel-Sonnet
   workload** — `build_system_next.md`'s bucket inventory is
   self-enumerating and chunkable by disjoint target sets: 21 targets
   are pure migration debt (bucket D), ~20 more unlock with two small
   `wbuildgen` directives (`name=`, `argv=`), and the shell-script ports
   are separable. It gets its own wave so nothing else races
   `build.base.json`.
4. **Continue shipped tracks** before opening new ones: the
   `wtest --defhash` consumer (its plan is already written in the
   backlog), REPL paste/completion (the two verified-missing #276 P2
   items), shell-mode stage 2 (#335 — reinforced by the maintainer's own
   stat-tools push in #343), attach phases (#123), PG milestone 4
   (#329's last milestone).
5. **Newly unblocked bigger bets last**: #251's 4b (commit-ranged
   selection) lost its blocker when #252's waves all landed; #110 now
   has a real body (restored 2026-07-17 — the #16-duplicate anomaly
   plan B flagged is resolved) and needs an assessment doc before any
   optimization work.
6. **Blocked work is listed, not scheduled** (§6).

## 2. Wave 1 — bug fixes, sync, tooling QoL (8 tasks)

| ID | Task | Source | Files | Care |
|----|------|--------|-------|------|
| 1a | **Doc/tracker sync**: move shipped `ai_tooling_next_steps.md` entries (defhash D4a ship note, silent-exit audit appendix) into `ai_tooling.md`'s status section per the file's own maintenance rule; refresh `docs/todo.txt`; record that #110's body is restored (real Optimization proposal, 4d below) and that #16 is protobuf's canonical home; check #344/#342 merge state and update §0 constraints for later waves. Docs only. | backlog | `docs/*` | LOW |
| 1b | **Imported-file diagnostic line numbers**: `compiler/compiler.w`'s `compile_save` saves `line_number + 1` before compiling an import, so every diagnostic in every imported (non-root) file reports one line high. Fix the save/restore; update every fixture whose expected line numbers shift (`warning_test`, `type_system_*`, wfixture-directive fixtures). The backlog demanded "its own gated PR" — this is it. Merges **last & alone**. Gates: `verify`, `verify_x64`, full tests. | backlog | `compiler/compiler.w`, fixtures | **HIGH** |
| 1c | **`lib/generator.w` unchecked `mmap()`**: `__w_gen_create`'s 64KB coroutine-stack mmap is unchecked — same failure shape as the fixed memory_debug gap (small negative int used as a pointer, segfault with no diagnostic). Check + clear message, mirroring `debug_tbl_mmap_failed()`. No fixture (needs memory exhaustion), same precedent as 35ed0f5. | backlog | `lib/generator.w` | MED |
| 1d | **wfixture arch selector**: a `# wfixture: x64` directive (or argv forwarding) so arch-gated compile-diagnostic fixtures single-source their expectations; add a test fixture exercising it. Migrating `cuda_diagnostics_test` back to fixtures is the payoff but **only if #344 has merged** by execution time (it edits that target); otherwise land the mechanism with a non-cuda x64-gated fixture and leave the migration logged. | backlog | `tools/wfixture.w`, `build.base.json`, fixtures | MED |
| 1e | **`lib/args.w` boolean flags**: a bare `-f`/`--nofollow` consumes the next positional. Add a non-consuming boolean API (`args_bool(...)` or declared-bool-names), document it in the header, migrate `tools/stat.w`/`tools/readlink.w` off their hand-rolled argv walks, unit tests. | backlog | `lib/args.w`, `tools/{stat,readlink}.w`, tests | MED |
| 1f | **`bin/` single-writer lock**: two `./wbuild`/`wexec` invocations racing one worktree corrupt each other with a bare "could not open output file". Take an advisory lock (lock file with O_CREAT/O_EXCL + stale-pid detection, or flock if the syscall layer grows it) at wexec startup; second invocation fails fast with a clear "another wbuild is running (pid N)" message. Test via two overlapped invocations in a scratch dir. | backlog | `tools/wexec.w`, tests | MED |
| 1g | **Unknown-flag driver diagnostic**: `bin/wv2 --bounds=xyz` falls through the flag loop and errors as "no such file: '--bounds=xyz'". Detect leading `--`/`-` non-files and say "unrecognized option" (frozen-text fixture in the same commit). | backlog | `compiler/compiler.w` driver, fixture | MED |
| 1h | **`ptr_add` helper for the `T* + int` footgun**: a leaf-lib generic helper (`ptr_add[T](T* p, int n)` returning `&p[n]`, which scales correctly) plus doc updates recommending it over raw `p + n` in library code; migrate the documented `lib/sha256.w`-style `p + i * width` idiom sites in one or two exemplar files. No grammar change; the check-warning half stays unrealizable per the backlog. | backlog | new `lib/` leaf file, docs, exemplars | MED |

Merge order: 1a first (later PRs edit the freshly-accurate docs), 1c–1h
in any order, 1b last & alone.

## 3. Wave 2 — #323 stage 2: the manifest/shell de-churn sweep (8 tasks)

Source of truth: `build_system_next.md`'s bucket inventory (re-run the
classification against the current tree before starting; counts are
pinned to its commit). Chunks are target-disjoint but all regenerate
`build.json` and most edit `build.base.json` — merge sequentially in ID
order, regenerating on conflict (`./wbuild manifest`), never
hand-merging.

| ID | Task | Bucket | Files | Care |
|----|------|--------|-------|------|
| 2a | **Bucket D migration (21 targets)**: pure migration debt — add `# wbuild:` directives to the sources, delete the hand-written targets, `./wbuild manifest`. Includes accepting the 4 legacy `X_test_x64` → `X_64_test` renames; grep for downstream references to the old names first. | D | tests' sources, `build.base.json`, `build.json` | MED |
| 2b | **`name=` + `argv=` directives**: teach `tools/wbuildgen.w` a `# wbuild: name=<target>` override (bucket G's 18 basename-mismatch targets) and an `argv=` run-argument directive (bucket H's `x25519_iterated_test`); migrate both buckets. Mac-only targets in G (`net_darwin`, `graphics_darwin`, `pac_darwin`) migrate compile-side only. | G, H | `tools/wbuildgen.w`, sources, manifests | MED |
| 2c | **Compile-error directive class**: a directive expressing "this source must fail to compile" with expected stderr (mirroring wfixture's `# expect_stderr:` header convention), so bucket I's `int64_x86_error_test` — and future compile-error tests — generate. Coordinate with 1d's wfixture work (same convention family, different tool). | I | `tools/wbuildgen.w`, `tools/wexec.w`, source | MED |
| 2d | **Path-based target deps**: the C+K gap (29 targets) — let a generated target depend on "compile this file first" by path instead of a hand-maintained target name (`deps=tools/wfixture.w` resolving to the tool binary). Design note in the PR; migrate the 9 wfixture-dependent fixture targets as the exemplar slice, leave the rest enumerated. | C, K | `tools/wbuildgen.w`, `tools/wexec.w`, manifests | MED |
| 2e | **Port `tools/compress_zlib_interop_test.sh` to W**: a W harness spawning the system `zlib`/`gzip` via `lib/process.w` and comparing against `libs/extras/compress/` — retires one bucket-E script, and is the template for the openssl port (4e). | E | new test source, `build.base.json` | MED |
| 2f | **Port `tools/pac_flag_check.sh` to W**: needs the missing ELF-flag-*reading* tool (the compiler only writes ELF); small reader over the ELF header + PAC flag check, retiring the script. | E | new `tools/` file, `build.base.json` | MED |
| 2g | **`wtest --defhash` selection refinement**: the backlog's written plan — in `tools/test_map.w` rule (b), when `--defhash` is passed, shell out to `bin/wv2 defhash` on `git show HEAD:<path>` vs the worktree copy and skip import-closure targets when the recorded name set + hashes are unchanged (comment-only edits stop selecting every importer). Follow the named patterns: `tests/wtest/map_expectations.expect`, the `-f <manifest>` synthetic-manifest trick, a self-contained `git init` scratch-dir step for the HEAD-vs-worktree comparison. Opt-in flag; default selection byte-identical. | #251 4a follow-up | `bin/wtest` (`tools/`), `tools/test_map.w`, tests | MED |
| 2h | **Parser recursion-depth guard**: deeply nested expressions/instantiations overflow the stack and die as a raw SIGSEGV with nothing printed (logged in the silent-exit audit as the known unaddressed gap). Add a depth counter at the recursive-descent entry points with a clean `error("expression nesting too deep")` at a generous limit; fixture for the message. Merges **last & alone**; rebase over any merged #344 grammar changes first. Gates: `verify`, `verify_x64`, `warning_test`, w.pg check. | backlog | `grammar/` entry points, `compiler/tokenizer.w`, fixture | **HIGH** |

## 4. Wave 3 — features on shipped tracks (6 tasks)

| ID | Task | Issue | Files | Care |
|----|------|-------|-------|------|
| 3a | **REPL bracketed paste + tab completion + Ctrl-R**: the two verified-missing #276 P2 items, one task because both live in `lib/line_edit.w` + the reader. Paste mode (ESC[200~/201~) suspends auto-indent and blank-line entry termination; completion hook in `line_edit` fed from the live symbol table; Ctrl-R incremental history search. Scripted `repl_test` cases where PTY behavior allows; manual-verification notes otherwise. | #276 P2 | `lib/line_edit.w`, `repl.w`, `repl/core.w`, tests | MED |
| 3b | **Shell mode stage 2** per `repl_shell_mode.md`: next slice of native tools in `lib/shell_commands.w` (echo/head/tail/wc/mkdir/rm at minimum — reuse #343's `lib/stat.w` where it fits), translator coverage in `repl/shell_translate.w` (+ unit tests), and the doc's staged pipe question answered or explicitly deferred in the PR. | #335 | `lib/shell_commands.w`, `repl/shell_translate.w`, tests | MED |
| 3c | **#123 register seam + locals/frames**: unify the sigcontext vs `user_regs_struct` register access behind the existing memory-seam dispatch idiom (documented follow-up in `debugger_attach.md`), then route locals/frame selection through the seam; x86-64 symbolization for attach. In-process path byte-identical. Gates: `verify` (debugger/ is seed-compiled via `--debug`), `attach_test`. | #123 | `debugger/` | MED |
| 3d | **c_import/preprocessor `diag_part` migration**: the 6 audited sites where `error(c"")` follows raw `print_error(...)` fragments emit an *empty* NDJSON record in `--json` mode while the text lands on stderr — breaking the JSON contract. Migrate to `diag_part` composition; check `c_import` fixtures for text changes. Seed-graph files (seed-era syntax only). Gates: `verify`, `verify_x64`, c_import tests. | backlog | `libs/extras/c_import/importer.w`, `libs/extras/c_preprocessor/` | MED |
| 3e | **Arch-aware closure check**: the "import breaks a different compile target" gap — a `bin/wtest archs <file>` (or `wexec` query) that enumerates, from the manifest, every target arch a file's closure is compiled under, and a documented one-liner (or `wtest changed` note) running `w check` per arch. Uses only existing per-arch `check`/`deps` selectors; no compiler change. | backlog | `tools/` (wtest/wexec), docs | MED |
| 3f | **PG milestone 4 — actions + predicates** (#329's last milestone): `{ code }` action blocks and `&{ expr }` predicates per the design doc §4.2–4.4 — commit-time execution only, the action-safety analysis (generation-time error if an action is reachable from an uncommitted decision), `$n`/`text(n)` text bindings, and an emit-as-you-parse sample grammar as a test target. AST mode untouched; `generated_c_parser.w` byte-identical. Merges **last & alone**. Gates: `verify`, full PG tests, `parser_generator_w_test`. | #329 | `libs/extras/parser_generator/` | **HIGH** |

## 5. Wave 4 — bigger bets + newly unblocked work (6 tasks)

| ID | Task | Issue | Files | Care |
|----|------|-------|-------|------|
| 4a | **#123 phase 4 — execution control**: breakpoints via `PTRACE_POKETEXT` int3 patching, `PTRACE_SINGLESTEP`/`PTRACE_CONT` + `wait4` loop, `c/s/n/si/fin` in the attach command loop, clean detach restoring patched bytes. Builds on 3c's seam. Extend `attach_test` (or its 2e-era W port). Gates: `verify`, attach suite. | #123 | `debugger/` | MED |
| 4b | **Commit-ranged selection MVP** (#251 4b, unblocked now that #252's waves are all landed): `wtest changed A..B` — enumerate changed files between two commits (`git diff --name-only A..B`), reuse 2g's defhash comparison per file pair (`git show` both sides), select impacted targets. The full semantic index over history stays future work; this is the useful subset. | #251 | `tools/` (wtest), tests | MED |
| 4c | **#110 optimization assessment doc**: the restored issue body asks for an optimization pass "either from the generated code (v0), or additional passes of the AST (v2)". Survey what a v0 peephole over emitted bytes could do (the emitter's patterns are highly regular), how v2 relates to the #231/#337 AST assessments already written, measure 2–3 hot spots (self-compile, PG sweep), staged recommendation. No code. | #110 | `docs/projects/optimization.md` | LOW |
| 4d | **Protobuf stage 1 — wire-format runtime** (#16): the design doc's first stage is decision-free (pure leaf library, no `message` keyword, no protoc dependency): varint/zigzag/tag codec + message encode/decode against golden hex vectors. **Confirm the maintainer has read `protobuf.md` with no objection before starting** (the stage-3 keyword decision stays theirs either way). | #16 | `libs/extras/protobuf/`, tests | MED |
| 4e | **Port `tools/openssl_interop_test.sh` to W**: same shape as 2e's zlib port (spawn system `openssl` via `lib/process.w`, TLS round-trip compare), retiring the largest remaining bucket-E script. Keep the target shell-gated on openssl's presence. | E / #323 | new test source, `build.base.json` | MED |
| 4f | **defhash generics + operator coverage**: thread `defhash_note` bookkeeping through the scan-ahead/re-parse machinery (`grammar/generic.w`, `grammar/operator_overload.w`) so generic and operator definitions stop being invisible to `defhash` (documented limitation); makes 2g/4b's selection sound for files defining them. Also swap `--closure`'s linear ref scan for a hash-table lookup while there. Merges **last & alone**. Gates: `verify`, `verify_x64`, `defhash_test` extensions. | #251 | `grammar/generic.w`, `grammar/operator_overload.w`, `compiler/compiler.w` | **HIGH** |

## 6. Blocked / gated — listed, not scheduled

Maintainer-decision gates (each has a doc or comment awaiting an answer):

- **#327** map default factory — surface pick requested
  (`map_default_factory.md`, 2026-07-17 comment); the `new map[K,V](...)`
  w.pg/compiler mismatch reconciles when picked up.
- **#231** wbuildd — `wbuildd.md` §6 questions open; daemon phase 1 and
  the #276 P4 websocket REPL server both wait on it.
- **#287** stage 2 — UTF-8 identifiers is a policy call
  (`utf8_source.md`).
- **#207** assembler into the seed graph — permanent seed-size budget
  call.
- **#27** matrix — whether ndarray v1 (+ #342's tensor track) suffices
  or a dedicated matrix type is wanted.
- **#338 / #337 / #334 / #332 / #333** — compilation-model, LLVM,
  UI-framework docs landed with explicit "your call" asks; no
  implementation until answered.
- **#98** web UI debugger — low priority per the issue; needs its design
  doc first, and plausibly shares a protocol decision with #231.

In-flight (§0): **#28**/**#17-bf16** CUDA + torch track (PRs #344,
#342) — owned by other sessions; do not schedule against it.

Mac-gated (ride the next Mac/darwin session): **#210**
`arm64_darwin_smoke_test`, wexec darwin directory hashing
(`getdirentries64` accessors), arm64/darwin REPL.

Research-scale / needs a decision first: multi-error reporting (parser
recovery), top-level `int x = 5` initialization sugar (the `:save`
round-trip asymmetry — grammar decision), `getchar()` read-error vs EOF
sentinel plumbing, `wvc` pack-style multi-object files ("if ever
wanted"), #323 buckets A/B/F/J remainder (bootstrap chain, umbrella
tags, generated-source directives, scan-convention widening — each needs
a design choice 2a–2d don't), #123 phases 5–6 (hw watchpoints,
restricted eval — after 4a).

## 7. Execution protocol (carried forward)

- One task per agent, isolated worktree, `claude/…` branch per task;
  sequential merge after green; on `build.json` conflict regenerate
  (`./wbuild manifest`), never hand-merge.
- Every PR: `git diff --name-only HEAD | ./bin/wtest changed` and run
  the printed targets (`--run` capable); compiler-tree or seed-graph
  diffs additionally `./wbuild verify` (+ `verify_x64` for
  word-size-sensitive work). Long suites run in the foreground with
  generous timeouts (the first post-build `wtest changed` can far
  exceed 2 minutes on a cold deps cache).
- Seed-graph files use seed-era syntax only; HIGH-care PRs merge last
  and alone in their wave.
- New tests follow the manifest convention (`tests/foo_test.w` +
  `# wbuild:` directives + `./wbuild manifest`); irregular steps go in
  `build.base.json` (until wave 2 shrinks that set).
- Diagnostic text is frozen by fixtures — message changes update
  fixtures in the same commit.
- Treat a worktree's `bin/` as single-writer until 1f ships: never
  background a `./wbuild`/`wexec` call and start another before the
  first finishes.
- Friction found while executing goes into
  `docs/projects/ai_tooling_next_steps.md` in the same PR; wave 1a
  resets that file to accurate first.
- Scratchpad files are task-ID-prefixed (plan B process note: one
  same-name collision was investigated as a suspected injection).
- Orchestrator follow-through after each wave: comment progress on the
  touched issues (PR #339's per-issue status comments are the model),
  update this file's execution status, surface §6 decision asks to the
  maintainer, and re-check §0's in-flight PRs before waves 2–4 launch.
