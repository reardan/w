# W as an embedded scripting language: the addon engine plan

Status: **Phase E (E1-E6) and S1 implemented** (2026-10-31): the engine
API is `repl/embed.w` (documented at its top),
`examples/scripting/addon_host.w` runs on the API, and
`tests/addon_host_test.w` (with an x64 twin) covers it. S2 is next. Phases A, P, R and W remain plans. Companion study with the
full inventory, three tier prototypes and benchmark sources: the project
folder `scripting/w_as_scripting_language.md` (not in this repository).

## 0. Goal

Use W on both sides of the "engine + scripts" split that World of Warcraft
gets from C++ plus Lua: a W host program loads W *source* addons at run
time, exposes a host API to them, calls into them every frame, reloads
them when they change, and survives their mistakes. No second language,
no bytecode, no interpreter: the compiler runs inside the host and emits
native code into an executable buffer, which is what `repl/core.w`
already does for the REPL and wdbg.

Non-goals: Erlang-style live state migration (reload resets addon state,
see §3), and a memory sandbox for untrusted in-process code (the wasm
interpreter and `wvm` cells remain the answer for untrusted scripts, §5).

## 1. What exists and what was measured

`repl/core.w` is an in-process W JIT: `repl_init()` maps an 8 MB RWX
buffer and compiles the prelude into it; `repl_eval(text)` compiles one
entry (any mix of imports, structs, globals, functions and statements)
as persistent session symbols, with a checkpoint that rolls back on a
compile error and a signal handler that long-jumps out of a runtime
fault; the #114 late-binding registry repatches every compiled call site
when a function is redefined. `examples/scripting/addon_host.w` uses only
that engine and the symbol table:

| Measured (x64 Linux cloud container, `66a8121`) | |
|---|---|
| `repl_init` (compiles `lib/lib.w` + container runtime) | 53-79 ms, 100 KB of buffer |
| Load a 3-function addon from source (`repl_eval`) | ~1 ms; 24 ms with `import structures.json` |
| Hot reload of one function, older call sites repatched | <1 ms |
| Host -> addon call through a `fn` pointer | 5 ns |
| Compile error in a reload | rejected, previous definitions stay live |
| Null dereference in addon code | caught inside the fault window, host continues |
| Stack overflow in addon code | **killed the process** (no `sigaltstack`); recovered since E1 |
| Host binary | 3.4 MB (the compiler is inside) |

Speed of the generated code is native W: the same four micro-benchmarks
in C (`gcc -O2`), W AOT, W loaded through the engine, node 22, LuaJIT
2.1 and Lua 5.4 gave (ms, best of two):

| benchmark | C | W AOT | W engine | V8 | LuaJIT | Lua 5.4 |
|---|---:|---:|---:|---:|---:|---:|
| `fib(32)` | 5 | 19 | 20 | 29 | 24 | 158 |
| `sieve(10M)` | 54 | 83 | 104 | 74 | 364 | 1073 |
| `map(2M)` int keys | 189 | 2631 | 2775 | 755 | 15 | 70 |
| `strings(1M)` f-strings | 88 | 499 | 719 (3257 with provenance on) | 255 | 373 | 1556 |

So the compiler is not the problem: calls and loops are already ahead of
V8 and LuaJIT and within 1.4-4x of gcc (the single-pass codegen gap,
`docs/projects/codegen_gap_plan.md`). The script-shaped weaknesses are
in the runtime: the `map` implementation and the session's allocation
provenance tracking (§4).

The other two tiers also work today and keep their roles: `--shared` +
`lib/dlcall.w` for precompiled engine modules (native, no isolation,
x64 Linux), and `libs/extras/wasm/runtime.w` for sandboxed untrusted
code (fuel-limited, ~1000x slower than native).

## 2. Gaps

Ranked by how much they block a real host, with the evidence from the
prototype:

| # | Gap | Evidence |
|---|---|---|
| G1 | No in-process engine on arm64 or macOS | `repl_inprocess_setup` wires only `define_asm_functions_x64()`/x86; the fault thunks are x86 bytes; the buffer needs `MAP_32BIT` because tables hold 32-bit addresses |
| G2 | The host needs the W source tree at run time | `repl_init` compiles the runtime from disk; outside a checkout: `cannot locate structures/hash_table.w` |
| G3 | No embedding API | the prototype reaches into `sym_address`, `codepos`, `repl_fault_active`, `repl_fault_jump_buffer`, `repl_setjmp`; diagnostics go to stderr |
| G4 | No capability gating for in-process addons | native code with raw pointers, `syscall`, `asm`, `c_lib`, every `lib/` module; `--safe` is rejected in process |
| G5 | Isolation edge cases | stack overflow is fatal; faults on addon-started threads are fatal by design; no preemption of a runaway loop |
| G6 | Code is never unloaded | shadowed definitions stay in a fixed 8 MB buffer; rollback is LIFO (`repl_state`) |
| G7 | Reload is function-granular | globals and struct layouts are not migrated; old code keeps old globals |
| G8 | Runtime speed for script shapes | `map[int,int]` 14x slower than C and superlinear; provenance tracking costs 5x on allocation-heavy code |
| G9 | Two heaps | addon code uses the session's `lib/lib.w` allocator, the host its own |

## 3. Plan

Sizes: S = hours, M = a focused day or two, L = multi-day. Each unit is
one PR unless noted. Every compiler-touching unit runs `./wbuild verify`
(and `verify_x64`), `./wbuild test_changed`, `wfmt_check`, and the
coverage gate for `compiler/`, `grammar/`, `code_generator/` lines.

### Phase E: the engine API (G3, G2, G5 part, G6, G8 part) — first

**Implemented** (E1-E6, `repl/embed.w`). Measured on the x64 Linux cloud
container with the API (best of a few runs, a loaded 4-core machine):
`engine_init` 58 ms; loading the benchmark addon from source 6 ms
(17 ms with `import structures.json`); `engine_reload` of it with one
later unit replayed 22 ms; `engine_call1` 6 ns per call against 2 ns
through a raw function pointer; `strings(1M)` 292 ms with provenance off
(the engine default) against 2312 ms with `engine_checked`; 20 reloads of
an addon grow the buffer by 0 bytes. Notes on how the units landed:

- E1: `repl/core.w` only gained embedder parameters, all 0 for the REPL
  and wdbg (`repl_buffer_size`, `repl_provenance_off`, `repl_fault_flags`,
  `repl_fault_hook`). The 64 MB buffer stays `MAP_32BIT` on x64 (the
  symbol and chain tables hold 32-bit addresses). The alternate signal
  stack is the calling thread's (the host's main thread). Roots are one
  `:`-separated string. `--profile=script` (P2) has a marked hook point
  in `engine_init_sized` and the reserved flag `engine_script`
  (`engine_script_profile_requested`).
- E2: binds are units too, so a reload replays them in order.
- E3: the sink is `diag_sink` in `compiler/diagnostics.w`; the engine
  turns `diag_json` on around each compile, so results carry the
  `w check --json` records with "file" naming the addon.
- E4: `engine_call0..3(address, args..., &ok)`; the fault is recorded by
  `repl_fault_hook` inside the handler without allocating (innermost
  session function at the pc, plus the innermost addon frame from a
  stack scan bounded by the arming frame), and `engine_fault_text` reads
  `SIGSEGV in addon 'a' function lib_crash (in strlen) (pc ..., address
  0x0)`. Calls must run on the thread that called `engine_init`.
- E5: rollback also re-points late-bind sites below the rollback point
  that had been repatched into released code, and removes the released
  entries' staged files. `engine_reload` compile-checks the new text at
  the end of the session first, so a rejected reload keeps the running
  version and its state; a top-level fault in the new text reloads the
  previous text.

Everything else builds on a frozen surface, so this is the only phase
that must come first. Module: `repl/embed.w`, importing `repl.core`;
the REPL and wdbg keep using `repl/core.w` directly and are unaffected.

- **E1 `engine_init(roots)`** (S). Wraps `repl_init`; takes import roots
  (`import_root_add`, `compiler/compiler.w`) so a host can ship `lib/`
  and `structures/` next to itself instead of running inside a checkout
  (G2, the Lua-ships-its-stdlib answer); turns
  `malloc_provenance_enabled` off in the session unless the host asks
  for checked addons (G8: `strings(1M)` 3257 -> 719 ms); reserves a
  larger buffer (64-256 MB, `MAP_NORESERVE`) in place of the fixed 8 MB
  (G6). Also installs `sigaltstack` + `SA_ONSTACK` for the fault
  handlers so a stack overflow in addon code recovers like a segfault
  (G5; `repl_fault_install` passes only `SA_NODEFER` today).
- **E2 `engine_bind(name, signature, address)`** (S). Declares a typed
  function-pointer global in the session and stores the host address,
  which is what the prototype does with a prelude entry plus
  `sym_address`. The signature is W source text (`fn(char*) -> void`).
  Also `engine_symbol(name)` (= `sym_defined_address`).
- **E3 `engine_load(addon, text) -> engine_result`** (M). `repl_eval`
  on the whole file with diagnostics captured instead of printed: a
  sink hook in `compiler/diagnostics.w` (the `diag_json` NDJSON
  formatter exists; it lacks a destination), so the host gets
  `{status, diagnostics}` per load and can show them in its own UI.
  Records which symbols the addon defined (table range) for E5 and for
  naming frames in fault reports.
- **E4 `engine_call(address, args...)`** (S). The fault window from
  `repl_eval` (`repl_fault_active`, `repl_setjmp(repl_fault_jump_buffer)`)
  as a helper that reports the addon's name and the faulting JIT
  function (the session knows every function's address range; today the
  trace names only host frames and says "entry rolled back").
- **E5 generations** (S). `engine_checkpoint()`/`engine_rollback(cp)`
  over `repl_state_capture`/`repl_state_restore`, with the documented
  rule that reload rolls back to the addon's checkpoint and reloads it
  and everything after it in order (WoW's `/reload` does the same), so
  LIFO rollback suffices and the dead-code leak disappears (G6).
- **E6 example + test** (S). Move `examples/scripting/addon_host.w`
  onto the API and add `tests/addon_host_test.w` (x64 twin) covering
  bind, load, reload with repatching, rejected reload, segfault and
  stack-overflow recovery, generation rollback.

### Phase S: reload semantics and saved state (G7)

**S1 implemented** (below and in `docs/projects/repl.md`).

- **S1 policy** (S, doc): reload = reset addon state; functions
  repatch, data does not migrate. Concretely, `engine_reload` rolls the
  session back to the addon's checkpoint and compiles the addon and every
  unit loaded after it again, in order:
  - every function of those units is the new code, and late-bound call
    sites below the rollback point are repatched to it;
  - every global of those units starts over from its initializer; old
    values, old struct layouts and heap objects reachable only from them
    are not carried over (the old heap blocks leak: the session heap is
    not rolled back);
  - the replaced code is released, not shadowed;
  - addresses a host looked up for those units are stale afterwards.
  Units loaded before the reloaded addon keep their state. What must
  survive goes through saved variables (S2).
- **S2 `lib/saved_vars.w`** (M). SavedVariables for addons on top of
  `to_json`/`from_json` (`structures/json_codec.w`): a host calls
  `saved_vars_store(addon, value)` before rollback and
  `saved_vars_restore` after reload. Struct layout changes are handled
  by JSON's field-name matching, which is the Lua behaviour addon
  authors expect.

### Phase A: arm64 Linux, then macOS (G1) — the long pole for a Mac game

Independent of E and S; can start in parallel. `repl_improvements.md`
Q7 already lists this ("arm64, then darwin REPL, M-L").

- **A1 arm64 Linux engine** (L). `repl_inprocess_setup` selects
  `define_asm_functions_arm64()`; a low-address buffer strategy without
  `MAP_32BIT` (either `mmap` with a hint below 4 GB and `MAP_FIXED_NOREPLACE`,
  or widening the 32-bit address fields in the symbol/chain tables,
  which is the cleaner fix and also removes the x64 `MAP_32BIT`
  dependency); arm64 `ucontext` layout for the fault handler
  (`debugger/sigcontext.w` has the AOT side); instruction-cache flush
  after every entry (`__builtin___clear_cache` equivalent: `ic ivau` /
  `dc cvau` sequence or the `cacheflush` syscall); the REPL's `repl_test`
  under qemu as the gate.
- **A2 arm64 Darwin engine** (L). `MAP_JIT` plus
  `pthread_jit_write_protect_np` toggling around emission (the W^X
  rule the Mach-O writer already follows for files), no signing for
  JIT pages, BSD signal delivery for the fault window,
  `tools/mac/run_darwin_tests.sh` gate. Needs a Mac run; the CLAUDE.md
  platform order applies.
- **A3 threads in the engine on arm64** (M, optional): today the
  session thread rules (`repl_threads_enable`) are x86/x64 only.

### Phase P: script profile (G4)

- **P1 import allowlist** (S). Zero compiler change: an addon import
  root containing only the curated modules, passed to E1, wins over the
  upward search (`--import-root` precedence, `compilation_model.md` §7).
  Document the curated set.
- **P2 `--profile=script`** (M). A compiler flag (also settable by the
  engine) that rejects `asm`, the `syscall*` builtins, `c_lib`/`extern`,
  `thread_create`, `unsafe:` and `cast` to pointer types in addon
  sources, with frozen diagnostics and fixtures like the other
  `*_error_fixture.w` targets. This is API gating in the WoW sense; it
  does not make the code memory-safe.
- **P3 checked addons** (L). Extend `compiler/safe_session.w`'s session
  rules so a whole addon file can be required to use checked pointers
  only (today a requested `--safe` is rejected in process). With
  bounds checks this gives memory safety at compile time, with the
  compiler itself as the trust boundary.

### Phase R: runtime speed for script shapes (G8)

- **R1 `map` runtime** (M). `structures/hash_table.w` SipHashes every
  key including word keys and keeps five parallel arrays per table
  (keys, values, states, order_next, order_prev), so each probe touches
  five cache lines; 250k entries took 204 ms and 2M took 4.4 s. Plan:
  a cheap multiplicative hash for word keys (keep SipHash for strings,
  the flooding case), interleaved key/value/state slots, and optionally
  a dense array part for small non-negative int keys as Lua does. Gate:
  the existing map/set tests plus a `tests/bench/` entry; target within
  3x of the C open-addressing twin.
- **R2 provenance default** (S, folded into E1; done: the engine
  leaves provenance off unless `engine_checked`).
- **R3 string building** (M, later). `strings(1M)` is 2x behind V8 in
  AOT; profile f-string lowering and the string builder before
  deciding.

### Phase W: wasm tier JIT (optional, only if untrusted scripts matter)

- **W1 wasm -> x64 baseline compiler** (L, its own project). Translate
  validated wasm functions to x64 through `code_generator/x64.w`, keeping
  the interpreter's fuel and bounds model. Not planned until a product
  need appears; the interpreter stays the sandbox.

### Order and dependencies

```
E1 -> E2 -> E3 -> E4 -> E5 -> E6        (one thread, sequential, ~1 week)
S1 -> S2                                 (after E5)
A1 -> A2 (-> A3)                         (parallel to E; needs qemu, then a Mac)
P1 (after E1) -> P2 -> P3                (P3 after the safe-mode roadmap allows it)
R1, R3                                   (independent of everything)
W1                                       (only on demand)
```

Suggested issue breakdown: one tracking issue per phase (E, S, A, P, R),
units as sub-issues; R1 can be filed on its own as a performance bug
today.

## 4. Decisions

Open (they change later phases, not Phase E):

- **Trust model.** Community addons in process (WoW's reality: P1+P2 are
  enough) or untrusted user scripts (P3 or the wasm tier)?
- **Mac first?** Then Phase A is the critical path and should start now.
- **Reload keeps or resets addon state?** This plan assumes reset (S1).

Made by this plan:

- The in-process JIT is the addon tier; `--shared` libraries are for
  engine modules; wasm is for untrusted code.
- Reload semantics follow WoW: roll back and reload in order.
- The host owns the API surface by binding named functions (E2); addons
  never link against host symbols directly.

## 5. References

- `repl/core.w` (engine), `repl/incremental.w` (prefix-reuse API),
  `debugger/eval.w` (the other embedder), `compiler/safe_session.w`.
- `docs/projects/repl.md`, `repl_improvements.md` (Q1 library split, Q7
  arm64/darwin), `incremental_compilation.md`, `safe_mode.md` ("Persistent
  REPL and debugger sessions"), `build_libraries.md`, `wasm_backend.md`,
  `vms.md`, `codegen_gap_plan.md`.
- Issues: #114 (late binding), #277 (fault recovery), #713 (checked
  sessions), #625 (libraries), #644 (safe mode).
