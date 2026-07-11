# WebAssembly Backend for W (wasm32 + WASI)

Plan for adding a WebAssembly backend: `w wasm file.w -o out.wasm` produces a
self-contained wasm32 module that runs under any WASI runtime (wasmtime is
the reference). Companion to the x64/arm64/win64 work and follows the same
playbook (`docs/projects/arm64.md` is the template): same grammar, a
per-target instruction module, a per-target container writer, an `__arch__`
runtime split, and a CLI target flag. Closes the placeholder issue #30.

**Status: Stages 0–4 implemented.** `w wasm file.w -o out.wasm` compiles
to a wasm32 + WASI module that runs under wasmtime or Node's built-in
WASI (`tools/run_wasm.sh` picks whichever is installed). The structured
control-flow layer (D3) landed first as a byte-inert refactor across all
native targets; the emitter (`code_generator/wasm.w`), module writer
(`wasm_module.w`), WASI stub layer, and `lib/__arch__/wasm/` runtime are
in place, including float32 and the limb/bit intrinsics. The full
toolchain self-hosts: the x86 compiler cross-compiles `w.w` to wasm, and
running that module under a WASI runtime recompiles `w.w`
byte-for-byte — `./wbuild verify_wasm` asserts `wv2_wasm == wv3_wasm`,
which (like `verify_x64`'s first cmp) also proves the output is
host-independent. `./wbuild wasm_smoke_test` runs a six-test slice
(lib_test, hash_table, map/set, compound assign, limb builtins, floats)
under the runner. Modules carry a `name` custom section, so engine
stack traces show W function names. See the execution notes at the end
for what shifted in flight.

## Target definition: what "WebAssembly" implies

Four layers, and — as with arm64 — they are separable:

1. **ISA** — the wasm32 core VM: a validated, typed stack machine with
   32-bit linear memory, `i32`/`i64`/`f32`/`f64` value types, typed
   functions, a `funcref` table for indirect calls, and **structured
   control flow only** (`block`/`loop`/`if`/`br`/`br_if` — no arbitrary
   jump targets). Modules must pass validation before they run, so
   "mostly right" codegen fails loudly and early.
2. **OS ABI** — WASI preview1: the module imports its whole OS surface
   (`fd_write`, `fd_read`, `path_open`, `args_get`, `clock_time_get`,
   `proc_exit`, ...) from the `wasi_snapshot_preview1` namespace and
   exports `_start`. This is exactly the shape the win64 target already
   proved out: `lib/__arch__/win64/syscalls.w` implements the per-arch
   wrapper surface entirely on `extern` imports that arrive through the
   container (kernel32 there, the wasm import section here).
3. **Container** — the wasm binary module format: magic + versioned,
   LEB128-encoded sections (type, import, function, table, memory,
   global, export, element, code, data). Much simpler than ELF — no
   relocations, no page alignment, no signing.
4. **The forcing constraint** — unlike every existing target, there are
   **no raw branches and no code addresses**: code is not readable
   memory, branch targets are enclosing-block labels by relative depth,
   and function "addresses" only exist as table indices. This is the
   wasm analog of arm64's W^X/signing wrinkle: the one thing that forces
   real design work (D3) instead of a mechanical port.

## What survives from W's backend model — and what does not

The audit is encouraging. Things that carry over unchanged or nearly so:

- **The accumulator stack machine.** wasm locals cannot have their
  address taken and the wasm operand stack cannot be indexed, but W
  already runs everything through an accumulator plus a
  software-addressed stack (`[esp + k]`, `stack_pos` bookkeeping). A
  shadow stack in linear memory (D2) preserves the entire model — the
  same move as dedicating `x28` on arm64.
- **Every call is already indirect through the accumulator**
  (`call_eax()` in `code_generator/x86.w`): materialize the callee's
  address, then call it. On wasm the "address" becomes a table index
  and the call becomes `call_indirect` — the model needs no change at
  all (D2).
- **The arm64 seams.** `be_addr_slot_emit/read/write` (split-immediate
  address slots with backpatch chains threaded through them),
  `be_branch_patch`/`be_branch_link_get`, the Stage 3 W^X text/data
  split (`emit_data_zeros`/`emit_data_word`, `data_offset`), and the
  arm64 string-literal path (descriptor in the data segment, referenced
  through an addr slot) are all reused directly.
- **word_size = 4.** wasm32 is a 32-bit target, same as the seed and the
  default target: `int` is 4 bytes, pointers are `i32` linear-memory
  offsets, `int64`/`float64` are rejected exactly as on x86. The whole
  32-bit test corpus is the natural acceptance suite.

Things that structurally cannot survive:

- **Position-patched jumps** (~21 `be_branch_patch` / `patch_jump_chain`
  sites across `grammar/`) — replaced by a structured control layer (D3).
- **The call-over-data string trick** (`grammar/string_literal.w`) —
  code is not addressable; literals move to the data segment, which the
  arm64 descriptor path already half-did.
- **Runtime stack switching** (`gen_switch`) — generators are impossible
  in core wasm; rejected at compile time (D7).
- **mmap-exec** — REPL and wdbg do not apply to this target (D7).
- **brk/mmap** — the allocator gets a `memory.grow` mode (D5).

## Design decisions

### D1: Target selection and naming

- `w wasm file.w -o out.wasm` — wasm32 + WASI. One name, lowercase, in
  the `x64`/`arm64`/`win64` positional-selector family. `wasm32`/`wasi`
  rejected as names: there is no second wasm target to disambiguate
  against yet (wasm64 and a browser-shim host are both deferred), and
  values are cheap to add later.
- Plumbing in `compiler/compiler.w`, mirroring the existing selectors:
  `word_size = 4`, `target_isa = 2` (0 = x86 family, 1 = arm64,
  2 = wasm), `target_os = 3` (0 = linux, 1 = darwin, 2 = windows,
  3 = wasi). `data_split = 1` — wasm *requires* the text/data
  separation the arm64 Stage 3 work created.
- `import_resolve_arch` (`grammar/import_statement.w`) gains `wasm` as
  an `__arch__` value; `tools/wmeta.w` expands it; `package.wmeta`
  lists the new modules (`metadata_check` gates this).
- `be_start`/`be_finish` (`code_generator/elf.w`) dispatch on
  `target_os == 3` to the wasm module writer.
- `check`/`symbols`/`deps` remain default-target-only, unchanged — same
  caveat the other selectors already have.

### D2: Execution model — shadow stack, accumulator globals, one function type

wasm's own operand stack cannot be the W evaluation stack: values on it
cannot be addressed (`&local` is everywhere in W code), pushes and pops
cross statement and branch boundaries in ways validation forbids, and
call arguments could not be re-read positionally. Rejected. Instead:

- **Shadow stack in linear memory.** A wasm global `$sp` holds the W
  stack pointer; `push_eax` → store accumulator at `$sp - 4`, decrement;
  locals/args are loads/stores at `$sp + k`. `stack_pos` bookkeeping and
  `sym_get_value`'s offset math are untouched (still 4-byte words,
  `word_size_log2 = 2`). This is exactly the x28 move from arm64 D2.
- **Registers become wasm globals**: `$ax` (accumulator), `$bx`
  (secondary), `$cx` (shift/scratch), all `i32`. Each `x86.w` helper
  gains a `target_isa == 2` dispatch to its wasm twin in
  `code_generator/wasm.w`, emitting short sequences like
  `global.get $ax / global.get $bx / i32.add / global.set $ax` — the
  same dispatch-inside-the-helper pattern D3 of the arm64 plan
  established, keeping x86/x64/arm64 output byte-identical.
  (Per-function locals for `$ax`/`$bx` might be faster — engines
  register-allocate locals more readily than globals — but globals are
  simpler and survive calls the way real registers do not have to here;
  measure later, it is a backend-local change.)
- **Every W function has wasm type `[] -> []`.** Arguments travel on the
  shadow stack and the return value in `$ax`, exactly as today. No
  signature bookkeeping, no per-arity types, and validation can never
  see an arity mismatch W's own type checker missed.
- **All functions live in one `funcref` table; a function's "address"
  is its table index.** `sym_get_value` on a function materializes the
  table index via the existing `be_addr_slot` seam (the slot is an
  `i32.const` with a 5-byte padded LEB128 immediate — see D4 — so
  `sym_define_global`'s backpatch chains thread through it unchanged).
  Every call is `global.get $ax`-free: push args, materialize index,
  `call_indirect (type $wfn)`. Table index 0 is reserved as the null
  function pointer (calls to it trap in the engine, matching a null
  call's crash semantics elsewhere).
- This uniformity has a second payoff: **import-index immunity**. In the
  wasm function index space, imports precede defined functions, so a
  late `extern` declaration would renumber every defined function.
  Because W code never calls defined functions by function index (only
  by table index, which the compiler assigns itself in definition
  order), the element segment can map table index → function index once,
  at `be_finish`, when the import count is final. Only direct calls *to
  imports* (D5's WASI shims) use function indices, and an import's index
  is fixed the moment it is declared.
- Direct-call optimization (emit `call f` when the callee is already
  defined and the call is not through a pointer) is deferred; it is a
  pure backend change and `call_indirect` is correct from day one.

### D3: Structured control flow — the crux

W has no `goto`. Every one of the ~21 patch sites descends from a
structured source construct, and the audit shows they all reduce to
exactly two patterns:

1. **Forward jump(s) to a merge point** — the chain protocol: a chain
   head starts at 0, `jmp_*_int32(chain)` threads sites through the
   displacement fields, and `patch_jump_chain(chain, codepos)` resolves
   them all at the merge point, which always comes *after* every branch
   site. Used by: if/else and `?` propagation (`grammar/statement.w`),
   `?:` (`conditional_expr.w`), `&&`/`||` short-circuit booleanize
   (`logical_and_expr.w`/`logical_or_expr.w`), switch case/body/end
   chains (`switch_statement.w`), break/continue chains
   (`statement.w`), loop exits, and the bounds-check skip branches
   (`x86.w` + `unary_expression.w`).
2. **Backward jump to a loop head** — `be_branch_patch(codepos, p1)`
   right after emitting the jump. Used by: `while_statement.w`,
   `for_statement.w` (both forms), and the small scan loop in
   `unary_expression.w`.

These two patterns are precisely wasm's `block` (branches forward to its
`end`) and `loop` (branches backward to its head). So the fix is to
raise the grammar's protocol from positions to labels:

- `int be_merge_begin()` — on wasm emits `block` (void block type) and
  pushes a control-stack entry; on x86/arm64 emits nothing and returns a
  fresh chain head (0). Replaces "declare a chain variable".
- `be_br(h)` / `be_br_zero(h)` / `be_br_nonzero(h)` — on wasm emits
  (`i32.eqz` +) `br_if`/`br` with relative depth computed from the
  control stack; on x86/arm64 emits today's `jmp_int32`/`jmp_zero_int32`
  /`jmp_nonzero_int32` with chain threading, byte-identically. Replaces
  every `jmp_*_int32(chain)` site.
- `be_merge_end(h)` — on wasm emits `end` and pops; on x86/arm64 runs
  `patch_jump_chain(h, codepos)`. Replaces every merge-point patch.
- `int be_loop_begin()` / `be_loop_back(h)` / `be_loop_end(h)` — wasm
  `loop` / `br` / `end`; x86/arm64 record `codepos` / emit the back jump
  + `be_branch_patch` / nothing.
- if/else maps even more directly onto wasm `if`/`else`/`end` since the
  grammar's emission order (cond, then-body, else-body, merge) matches
  the opcode order exactly; whether to special-case it or express it as
  merge blocks is an implementation detail of the same layer.

Emission order never fights the single pass: a block must open before
its first branch, and in every audited construct the grammar reaches a
natural "begin" point (loop entry, first `&&`, case start) before any
branch to the merge is emitted. Loops need the standard three-label
shape — `block $exit { loop $top { cond; br_if $exit; block $cont
{ body }; step; br $top } }` — so `continue` (which targets the re-test
or the step code) is `br $cont`, `break` is `br $exit`; the loop-context
globals (`loop_break_chain` et al.) simply hold label handles instead of
chain heads on wasm. `break`/`continue`'s stack unwinding (`stack_pos`
restoration) is shadow-stack arithmetic on `$sp`, unchanged. `return`
inside any nesting is the wasm `return` opcode, with defer re-emission
before it exactly as today.

Two invariants keep validation trivial: every block is void-typed (all
values travel in `$ax`/the shadow stack, so no operand-stack values ever
cross a label), and all control emission goes through the `be_` layer so
the depth counter cannot drift (assert depth == 0 at each function end).

**The refactor is testable before any wasm exists.** Port the grammar
sites to the `be_merge_*`/`be_loop_*` helpers with only the x86/arm64
lowering implemented: `./wbuild verify`, `verify_x64` and `verify_arm64`
must stay byte-identical, proving the new layer inert — the same
guard-the-refactor-with-the-fixpoint trick arm64 D3 used. This is
Stage 1, and it de-risks the whole project.

Rejected alternatives:

- **Relooper / goto-recovery** (Emscripten's approach): machinery for
  reconstructing structure from arbitrary CFGs. W never destructures —
  the grammar *is* the structure — so this solves a problem we do not
  have.
- **Dispatch-loop trampoline** (one `loop` + `br_table` over a
  basic-block index): mechanical, but generates slow, opaque code and
  defeats engine optimization. Worth remembering only as the known
  technique for resumable functions if generators are ever attempted
  (Asyncify-style), not for ordinary control flow.

### D4: Container writer — single-pass sections via padded LEB128

New `code_generator/wasm_module.w` (container) + `code_generator/wasm.w`
(opcode emitters), dispatched from `be_start`/`be_finish`. The
single-pass problem: wasm prefixes every section and every function body
with its byte size, and immediates (call targets, `i32.const` symbol
slots) may need backpatching after emission. The spec makes this easy:
**LEB128 encodings need not be minimal** — a `u32` may occupy up to 5
bytes with redundant continuation bits. So:

- Every backpatchable integer — function-body sizes, `i32.const`
  address-slot immediates, `call`/`call_indirect` indices patched
  through symbol chains — is emitted as a **fixed 5-byte padded
  LEB128**, giving the same "write a placeholder, patch it in place"
  model the ELF writers use for rel32 fields. `be_addr_slot_read`/
  `write` reassemble the 5-byte split immediate exactly as the arm64
  versions reassemble `movz`/`movk` pairs.
- Branch depths never need patching (the depth is known when the `br`
  is emitted — D3), and canonical LEB is fine for them.
- Buffers: the code section streams into the existing `code` buffer
  (each function body opens with a 5-byte size placeholder patched at
  its `end` — the prologue/epilogue helpers are the natural hook); data
  streams into the existing `data` buffer (globals via
  `emit_data_zeros`/`emit_data_word`, string bytes + descriptors — the
  arm64 descriptor layout carries over, minus the inline-in-text
  variant). The small sections (type, import, function, table, memory,
  global, export, element) are assembled at `be_finish` from the symbol
  table and concatenated in order — the same "patch the headers at
  finish" role `elf_finish` plays.
- Memory layout (single linear memory, exported as `"memory"`):
  `[0, 1k)` reserved so address 0 stays out of circulation (wasm memory
  has no unmapped pages, so null dereferences read zeros instead of
  faulting — a documented soft spot; explicit bounds checks still work),
  then the data segment at 1k (one active data segment initializes it),
  then a fixed-size shadow-stack region (default 1 MiB, `$sp` starts at
  its top), then the heap, grown with `memory.grow`.
- Entry: `_start` (the WASI command export) is the W entry stub as a
  regular function — initialize `$sp`, fetch `args_sizes_get`/`args_get`
  into linear memory, build `argc`/`argv`, call `_main` through its
  addr slot, `proc_exit($ax)`.
- No DWARF/symtab: runtime stack traces are silently skipped, exactly
  the Mach-O/PE behavior (`lib/stack_trace.w` already handles absent
  sections). The wasm **name custom section** (function names) is a
  cheap later add that makes engine-side traces readable — worth doing
  in Stage 5.

### D5: OS layer — WASI preview1

New `lib/__arch__/wasm/syscalls.w` keeping the same wrapper surface as
the other per-arch modules so `lib/` and `structures/` compile
unmodified — the win64 module is the template, down to the "primitives
with no equivalent return -1" convention:

- Declared as `c_lib "wasi_snapshot_preview1"` + `extern` declarations,
  reusing the existing extern machinery; the wasm backend routes
  `c_lib`/`extern` to the import section instead of PT_DYNAMIC/PE
  imports. WASI imports have real typed signatures, so the `ffi.w`
  wasm branch is the one place with per-signature wasm types: load the
  args from the shadow stack onto the operand stack, `call` the import
  by function index, store the result to `$ax`. (No calling-convention
  marshalling at all — this is the simplest FFI shim of any target.)
- Mapping notes: fds 0/1/2 are preopened; `open` maps to `path_open`
  against the preopened directories (wasmtime's `--dir .` gives the
  compiler its cwd); `read`/`write` map to `fd_read`/`fd_write` with a
  single iovec in scratch memory; `exit` is `proc_exit`; time via
  `clock_time_get`. `brk`/`mmap` do not exist: `lib/memory.w` grows a
  `malloc_wasm_mode` alongside `malloc_mmap_mode`, backed by
  `memory.grow` (a bump region above the shadow stack).
- The raw `syscall(...)` builtin is a compile-time error on the wasm
  target — there is nothing meaningful to lower it to, and everything
  in `lib/` reaches the OS through the wrapper surface. Programs that
  bypass `lib/` (e.g. `tests/hello.w`'s hand-rolled `_main`) are simply
  not wasm-portable, as they are already not win64-portable.
- `c_lib` of anything other than the WASI namespace (and later,
  explicitly host-provided namespaces), `c_import`, and `extern` data
  objects are rejected on this target: there are no shared libraries to
  bind.

### D6: Floats

Simplest float target yet. The "float bits ride the integer pipeline"
design (`docs/projects/float.md`) maps via `f32.reinterpret_i32` /
`i32.reinterpret_f32` around native `f32` arithmetic — the wasm twins of
the ~36 `sse.w` helpers are two-to-four opcodes each (`f32.add`,
`f32.eq` + the 0/1 result already being an `i32`, `f32.convert_i32_s`,
`i32.trunc_f32_s`). No ABI, no register classes.

### D7: Out of scope on this target (rejected with diagnostics)

- **Generators** — `gen_switch` swaps machine stacks; core wasm cannot.
  (The stack-switching proposal is not standard; a trampoline rewrite is
  a research project.) `yield`/generator declarations are a compile
  error on wasm. The smoke-test slice therefore excludes
  `generator_test`, unlike arm64's.
- **Threading** — already x86-only; unchanged.
- **REPL / wdbg** — both compile into an mmap'd buffer and execute it
  in-process; no such thing in wasm. The `debugger` statement lowers to
  `unreachable`: a standalone binary hitting `int3` today dies on
  SIGTRAP, and `unreachable` preserves exactly that semantics (and
  engines stop debuggers on it).
- **Runtime stack traces** — skipped (D4); engine traces plus the name
  section are the substitute.
- **`c_import` / shared-library FFI / extern data** — no dynamic
  linking (D5).

None of the new code needs post-seed syntax — `code_generator/`,
`grammar/`, `compiler/`, `lib/` changes all compile with the committed
seed, so no `./wbuild update` (and no darwin-seed refresh) is required
at any stage.

## Staged path

- **Stage 0 — model spikes.** Hand-write (hexdump or a throwaway
  script, as the arm64 appendix did with `.s` files) a minimal module
  exercising every load-bearing bet at once: shadow-stack pushes/pops
  through `$sp`, accumulator globals, two `[] -> []` functions called
  via `call_indirect`, a `block`/`loop` with `br_if`, an `fd_write`
  hello through the import section, **5-byte padded LEB128 sizes and
  immediates**, and `proc_exit`. Must validate and run under wasmtime
  (`wasm-tools validate` as the second opinion). The padded-LEB point
  is the one to prove early — it is spec-legal, but it is the
  foundation of the whole single-pass design.
- **Stage 1 — structured-control refactor, no wasm yet.** Introduce
  `be_merge_begin/br/end` + `be_loop_begin/back/end` in the backend
  layer and port all audited grammar sites (while, for ×2, if/else,
  `?:`, `&&`/`||`, switch, break/continue, `?`, bounds checks, the
  unary scan loop). Acceptance: `./wbuild verify`, `verify_x64`,
  `verify_arm64` byte-identical, full `./wbuild tests` green. This
  stage is pure risk retirement and merges on its own.
- **Stage 2 — emitter + container MVP ("webassembly hello world").**
  `code_generator/wasm.w` (helper twins dispatched on
  `target_isa == 2`), `wasm_module.w` (section writer, memory layout,
  `_start`), minimal `lib/__arch__/wasm/syscalls.w` (`write`, `exit`),
  the `wasm` CLI flag + `__arch__` value, `ffi.w` import calls.
  Acceptance: a print-based hello and a small arithmetic/control-flow
  test compile, validate, and run under wasmtime; all existing verify
  targets still byte-identical.
- **Stage 3 — full language + smoke slice.** Strings/UTF-8 descriptors,
  containers (map/set/list runtime), floats, defer, generics,
  compound assignment, limb/bit builtins, bounds-check traps; full
  WASI file I/O + args + `malloc_wasm_mode`. Acceptance: a
  `wasm_smoke_test` mirroring `arm64_smoke_test` (lib_test,
  hash_table_test, map_set_builtin_test, compound_assign_test,
  limb_builtin_test — no generator_test) green under wasmtime.
- **Stage 4 — self-hosting ("webassembly self-compiling").** The
  compiler is an ordinary 32-bit W program that opens files, allocates,
  and writes an output — all in WASI's vocabulary. `verify_wasm`:
  `bin/wv2 wasm w.w -o bin/wv2_wasm`, then run `wv2_wasm` under
  wasmtime (`tools/run_wasm.sh`, the `run_arm64.sh` analog, with
  `--dir .`) compiling `w.w` to `bin/wv3_wasm`; `cmp` byte-identical.
  As with `verify_x64`, the first comparison also proves the emitted
  bytes are independent of the host stage.
- **Stage 5 — polish (each its own follow-up).** Name custom section;
  direct-`call` optimization for defined callees; a browser host shim
  (JS providing the WASI subset, or a wasi-polyfill) with a demo page;
  `# wbuild: wasm` twin-target support in `tools/wbuildgen.w` if the
  smoke slice outgrows hand-written targets; wasm64 when engines make
  it boring; exported W functions with real signatures for embedding.

## Testing / CI strategy

- **Runtime**: wasmtime, a single static binary — same dependency class
  as `qemu-user-static` for arm64; bake it into the environment setup
  the same way. `wasm-tools validate` (or `wasmtime compile`) runs in
  the wasm targets as a validation gate distinct from "it happened to
  work".
- **Targets** are hand-written in `build.base.json` (`wasm_hello_test`,
  `wasm_smoke_test`, `verify_wasm`), outside the default `tests`
  umbrella like the arm64/qemu targets, until the toolchain dependency
  is universal. `bin/wtest` picks them up via the manifest as usual.
- **The existing fixpoints guard every stage**: `verify`, `verify_x64`,
  `verify_arm64` must stay byte-identical throughout, proving the
  Stage 1 control-flow layer and all subsequent dispatch additions are
  inert for the native targets.
- Negative tests: fixtures asserting the target's rejections (generator
  on wasm, `syscall()` on wasm, `c_import` on wasm) via the
  `# expect_stderr:` directive machinery.

## Open questions

- Accumulator representation: module globals (planned) vs per-function
  locals — locals may JIT better; backend-local change, measure in
  Stage 5.
- `$sp` overflow: the shadow stack region is fixed-size; is a check in
  the function prologue worth the cost, or is "reserve generously"
  (1 MiB default, flag to grow) enough for the MVP? (Native targets
  currently do not check either.)
- Padded-LEB tolerance in third-party tooling: engines must accept it
  per spec; some optimizers (binaryen) canonicalize on rewrite, which is
  fine, but confirm nothing in the planned test path *requires*
  canonical encodings. (Stage 0 settles this.)
- Is rejecting `int64` on wasm32 the right call long-term, given wasm
  has native `i64`? Deferred: `int64`-on-32-bit-targets would be a
  language change, not a backend one.
- Browser story scope: WASI-in-the-browser shims exist, but graphics/
  events would want a real host-import design (a `c_lib "env"`
  convention?) — out of scope here, worth a design note when attempted.
  **Resolved**: docs/projects/wasm_webgl.md — `c_lib`/`extern` compile
  to typed host imports, the funcref table and `$ax` are exported for
  host→W callbacks, and `graphics/` renders through WebGL2 via
  `tools/web/` (`wasm_extern_test` / `wasm_webgl_test` gates).

## Execution notes (Stages 0–4 landed, 2026-07-11)

- **Stage 1 shipped exactly as planned** and was verified stronger than
  promised: beyond the three fixpoints, a pristine-main compiler and the
  refactored one emit byte-identical output for a test corpus (including
  `w.w`) across all five native targets. The bounds-check emitters
  changed protocol (they take a control-region handle and thread the
  chain themselves) since their branches are condition-coded rather than
  accumulator tests.
- **The one W gotcha bit anyway**: the signed-LEB termination test used
  `(v == -1) & (b & 0x40)` — a bitwise AND of `1 & 64` — which never
  terminates for negative constants. CLAUDE.md warns about exactly this.
- **Function definition hooks**: `be_function_define` (symbol value =
  table index on wasm, code position elsewhere) and
  `be_function_epilogue` (body-size patch + `end`) joined
  `be_function_prologue` as the per-target function seams; the
  synthesized `__w_test_main` uses `be_function_define_declare`.
- **The import stubs are fatter than sketched**: `wasi_clock_time_get`
  does the ns→{sec,nsec} division in the stub (where i64 arithmetic
  exists — W has no int64 on 32-bit targets), and `path_open` takes one
  32-bit rights word zero-extended into both u64 rights arguments.
  Strict preview1 hosts (uvwasi/Node) reject rights masks broader than
  the preopen's inheriting set, so `open()` requests exactly the
  regular-file set (0x08E001FF), not all-ones.
- **`getcwd()` reports "/"** on wasm: the compiler's upward import
  search then does exactly one pass, and `open()` strips the leading
  slash and resolves against the first preopen (fd 3). `brk()` returns
  0 (the arm64_darwin convention), flipping malloc into mmap mode, and
  `mmap` bump-allocates over `memory.grow`.
- **Trap stubs**: the debugger/library trees reference the classic asm
  stubs (`syscall`, `gen_switch`, `repl_longjmp`, sockets, threads...).
  On wasm they are defined as `unreachable` bodies so the import graph
  links and any actual call dies loudly. `repl_setjmp` fills a zero pc,
  which keeps `lib/stack_trace.w` collection a silent no-op (the zero
  probe fails `sys_mincore`, which returns -1 here).
- **The name section landed in Stage 2**, not Stage 5 — engine-side
  symbolized traces paid for themselves during bring-up within minutes.
- **Float-to-int uses `i32.trunc_sat_f32_s`** (trap-free saturation)
  rather than the trapping form; NaN converts to 0 where x86 gives
  INT_MIN. Documented divergence.
- **`i32.const` address slots** are 1 opcode + 5 padded bytes + 
  `global.set $ax`; the slot cell convention (`codepos - 4`) is
  preserved, with the immediate at `[pos-3, pos+2)`.
- **json builtins are rejected** on wasm for now (their descriptor blobs
  still live in the code stream); generators, threads, REPL, wdbg, and
  `c_lib`/`extern`/`c_import` are absent or trap as planned (D7).
- Runner: `tools/run_wasm.sh` (wasmtime, else `tools/run_wasm.mjs` on
  Node ≥ 20). Targets: `build_wasm`, `verify_wasm`, `wasm_smoke_test`
  in `build.base.json`, outside the default `tests` umbrella like the
  qemu-bound arm64 targets.

## References

- wasm core spec (binary format, LEB128 non-minimal encodings, control
  instructions): https://webassembly.github.io/spec/core/
- WASI preview1 API:
  https://github.com/WebAssembly/WASI/blob/main/legacy/preview1/docs.md
- wasmtime CLI (preopens via `--dir`): https://docs.wasmtime.dev/
- wasm-tools (validator): https://github.com/bytecodealliance/wasm-tools
- Shadow-stack precedent (LLVM/Emscripten user-space stack in linear
  memory): https://github.com/WebAssembly/tool-conventions/blob/main/BasicCABI.md
- Relooper background (the road not taken):
  https://github.com/emscripten-core/emscripten/blob/main/docs/paper.pdf
- Stack-switching proposal status (why generators are out of scope):
  https://github.com/WebAssembly/stack-switching
