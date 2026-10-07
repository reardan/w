# Registers for hot loops, and profiles to find them: a staged plan

Status: plan, 2026-10-07, written against `main` at `4389c2f` (AST S2.2b,
the last of the statement-walk families). Companion to
[optimization.md](optimization.md) (the v0 emission-time "note" folds,
all landed), [compiler_performance.md](compiler_performance.md) §13 (the
load fusion and register shuttle those notes bought) and
[ast_completion_plan.md](ast_completion_plan.md) (what the production AST
does and does not give an optimizer today). Every number below was
measured on this checkout, in a 4-core Xeon 2.1 GHz cloud container,
with `./wbuild build` and the tools named in §10; estimates are labelled
as estimates.

## 0. Summary and the recommended path

- **Every W local lives in memory, and every loop pays for it.** The
  one-register accumulator model (`eax`/`rax` current value, `ebx` operand
  scratch, `[esp+N]` slots for locals) means `i = i + 1` is five
  instructions with a load, a store and a loop-carried dependency through
  the stack. In `bin/wv3` (x86), 13.0% of all instructions are local-slot
  loads and 19.7% are `push eax`; the 64-round compression loop of
  `lib/sha256.w`, the single hottest function in the compiler's own
  self-compile, is 214 instructions per round of which 106 are memory
  traffic for 20 locals and 56 do arithmetic (§1.2).
- **The win is real and large where it applies.** Hand-patching one
  summation loop so its two locals live in `esi`/`edi` *without changing
  anything else about the accumulator model* ran 1.5x faster; the ideal
  five-instruction loop ran 3.2x faster (§1.3). Two leaf arithmetic
  functions (`sha256_block_w`, `__w_hash_sip`) are 25% of the compiler's
  self-compile instruction count (§1.2), so the compiler itself is the
  first beneficiary.
- **Recommended design (§2): function-scoped promotion of word-sized,
  non-address-taken scalar locals into callee-saved registers, decided by
  a token-level pre-scan of the function body, emitted through the
  existing `sym_emit_value` → `promote()` → assignment path with a
  fail-closed guard** — any grammar path that touches a promoted local in
  a way the design did not anticipate is a compile-time internal error,
  never a silent miscompile. The stack frame layout does not change (the
  slot stays allocated and unused), so every `stack_pos` computation,
  every DWARF frame rule and the debugger's slot arithmetic stay valid;
  wdbg and DWARF get a register location kind instead. x86/x64 first;
  x64 gets `r12`–`r15` (four registers), x86-32 only `esi`/`edi` (two),
  which is why the 64-bit target is where most of the win lands and why
  stage 3 adds caller-saved registers for call-free loops.
- **Performance-driven optimization (§3): compiler-inserted counters,
  not sampling.** `--profile-generate` adds one `inc [counter]` per
  function entry and per loop head, the runtime writes the counters at
  exit, `bin/wprof` merges runs into a text profile keyed by each
  function's `w defhash` hash (so a stale entry just stops matching), and
  `--profile-use=<file>` reads it as an explicit input: the fixpoint and
  wexec's content-hash cache stay deterministic because the profile is a
  committed file hashed like any other input. The profile decides *which*
  functions get the (compile-time-costly) register work, the register
  budget inside them, hot-loop alignment and, later, which small hot
  callees to inline; the correctness facts (address-taken, calls, raw
  asm) never come from the profile.
- **Finding (§3.1): the test suite is not a benchmark.** Of five
  "expensive-looking" test binaries, three run 1.4–5.0 M instructions
  (startup-dominated: `malloc_debug_env_check`, DWARF line-table parsing
  in `lib/stack_trace.w`); only `sha256_test` (366 M) and `regex_test`
  (239 M) exercise a hot loop. PGO needs a small benchmark corpus
  (`./wbuild bench`, §5) on top of the suite, and the self-compile is its
  largest real workload.
- **Staging (§6):** R1 (two removable instructions, measurable today:
  `add esp,0` and the 7-byte `lea`) → R2 (the promotion mechanism, x64,
  hot leaf functions only, gated on a fixpoint and a differential sweep)
  → P1 (counters, profile file, `bin/wprof`) → R3 (loop-scoped,
  caller-saved registers) → P2 (profile-driven budget, alignment,
  self-compile PGO in the bootstrap chain) → R4/P3 (x86-32 tuning,
  arm64, inlining). Each unit is sized for one agent.

## 1. Where things stand

### 1.1 The emission model

`grammar/*.w` parses and emits in one pass through `code_generator/x86.w`
(CLAUDE.md "Architecture"). The register map is fixed: `eax` is the
value being computed, `ebx` the other operand of a binary operator,
`ecx` a shift count (`mov_ecx_eax`, x86.w:1248) or `cmpxchg` desired
value, `edx` the high half of `mul`/`div`. Locals and arguments are
words on the machine stack addressed from `esp`
(`compiler/symbol_table.w:891`, `sym_emit_value`: a local is
`(stack_pos - slot - 1) << word_size_log2`, an argument
`(stack_pos + number_of_args - slot + 1) << word_size_log2`) — not from
the frame pointer, which `be_function_prologue`
(`code_generator/arm64.w:521`) pushes only so `lib/stack_trace.w` and
the DWARF CFI (`.debug_frame`, #555) can walk frames. Every grammar rule
that pushes a word mirrors it in `stack_pos` (`grammar/stack_slot.w`:
`push_slot`, `load_slot`, `push_slot_copy`), so slot offsets are
recomputed at every reference.

A local read is `sym_emit_value` → `be_lea_acc_wstack(k)` →
`lea eax,[esp+k]`, then `promote()` (`grammar/promote.w:276`) loads
through it; §13's note fuses the pair into `mov eax,[esp+k]`. A local
write parses the lvalue the same way, pushes the address, evaluates the
right side, pops it into `ebx` and stores (`grammar/expression.w:225–262`,
`assign_store`); the register shuttle turns `push; <one instruction>;
pop ebx` into `mov ebx,eax`. `&x` is "the lvalue address already in
`eax`" (`grammar/unary_expression.w:213`). What this produces for the
smallest possible loop (`bin/wv2 shapes.w`, x86; x64 is the same shape
with `rsp`, plus 10-byte `movabs` constants):

```
int sum_to(int n):
	int i = 0
	int s = 0
	while (i < n):
		s = s + i
		i = i + 1
	return s

 8057f40: mov eax,[esp+0x4]      ; i          <- loop head
 8057f44: mov ebx,eax
 8057f46: mov eax,[esp+0x10]     ; n
 8057f4a: cmp ebx,eax
 8057f4c: jge 8057f8c
 8057f52: lea eax,[esp+0x0]      ; &s   (7 bytes: disp32 form)
 8057f59: push eax
 8057f5a: mov eax,[esp+0x4]      ; s
 8057f5e: mov ebx,eax
 8057f60: mov eax,[esp+0x8]      ; i
 8057f64: add eax,ebx
 8057f66: pop ebx
 8057f67: mov [ebx],eax          ; s = ...
 8057f69: lea eax,[esp+0x4]      ; &i
 8057f70: push eax
 8057f71: mov eax,[esp+0x8]      ; i
 8057f75: mov ebx,eax
 8057f77: mov eax,0x1
 8057f7c: add eax,ebx
 8057f7e: pop ebx
 8057f7f: mov [ebx],eax          ; i = ...
 8057f81: add esp,0x0            ; be_pop(0) at the block's end
 8057f87: jmp 8057f40
```

Twenty instructions per iteration: five loads, two stores, two
push/pop pairs, two address materialisations, one `add esp,0`, five
that do the work. `for i in range(n)` is better only at the increment
(`inc DWORD PTR [esp+0x4]`, `grammar/for_statement.w:301`) — its
condition still reloads both the loop variable and the hidden end slot
through a push/pop pair.

Static shares in `bin/wv3` (x86, 593,036 instructions, 2,760,012 bytes;
`objdump -d -Mintel`, §10):

| pattern | count | share of instructions |
| --- | --- | --- |
| `mov eax,[esp+N]` (local/argument read) | 76,803 | 13.0% |
| `push eax` (operands, call arguments) | 116,850 | 19.7% |
| `pop ebx` / `pop eax` | 14,025 / 3,079 | 2.9% |
| `mov [ebx],eax` (store through an lvalue address) | 10,234 | 1.7% |
| `lea eax,[esp+N]` (surviving address materialisations) | 5,995 | 1.0% |
| `add esp,0x0` (`be_pop(0)`, x86.w:671) | 13,687 | 2.3%, 82 KB |
| `call` | 34,829 | 5.9% |

The last row is a free win: `be_pop(0)` emits a six-byte no-op at every
block end whose scope held no locals. It is a jump target (the `while`
back edge lands on it), but an instruction that emits nothing simply
moves the label, so dropping it needs no note bookkeeping. `lea_eax_esp_plus`
(x86.w:581) always uses the disp32 form where `emit_eax_esp_disp` already
knows the disp8 one; `mov_eax_int` on x64 uses a 10-byte `movabs` for
every constant including 0 and 1. These three are unit R1 (§6).

### 1.2 Where the time goes

Callgrind over the self-compile (`valgrind --tool=callgrind bin/wv2
--quiet w.w -o …`, 7,251,167,663 Ir; wall time without valgrind
0.92–0.96 s, three runs), addresses mapped back to functions with the
binary's symbol table:

| share | Ir | function |
| --- | --- | --- |
| 13.25% | 960,827,862 | `lib/sha256.w` `sha256_block_w` |
| 11.73% | 850,271,327 | `structures/hash_table.w` `__w_hash_sip` |
| 6.80% | 493,196,048 | `compiler/tokenizer.w` `getc` |
| 6.73% | 488,141,925 | `structures/w_list.w` `__w_list_addr` |
| 6.22% | 451,271,970 | `lib/lib.w` `strcmp` |
| 4.37% | 317,031,614 | `hash_table.w` `__w_hash_table_slot` |
| 3.62% | 262,465,493 | `compiler/type_table.w` `type_lookup_pointer` |
| 3.07% | 222,656,469 | `type_table.w` `type_get_alias_target` |
| 3.07% | 222,409,122 | `hash_table.w` `__w_strcmp` |
| 2.84% | 205,635,954 | `tokenizer.w` `get_character` |

A quarter of the compiler's time is two leaf functions with no calls in
their loops and 12–20 word-sized locals each: the SHA-256 compression
(`code_generator/elf_all.w` hashes the whole image for the GNU build-id
note, #378, and `compiler/compiler.w:2065` hashes every definition for
`defhash`) and the SipHash of every map key. `sha256_block_w` costs
about 22,000 instructions per 64-byte block; a C implementation is
under 3,000. Its round loop, statically (`objdump` of `bin/wv2`, the
region between the third `cmp ebx,eax; jge` and its `jmp`):

| per round (214 instructions) | count |
| --- | --- |
| `mov eax,[esp+N]` | 49 |
| `push eax` / `pop ebx` | 27 / 21 |
| `mov [ebx],eax` | 9 |
| `lea eax,[esp+N]` + `mov ebx,eax` for those stores | 9 + 9 |
| ALU (`and or xor add sub shl sar shr imul`) | 56 |
| constants (`mov eax,imm`) | 8 |
| control (`cmp`, `jcc`, `jmp`) | 3 |

The eight-way variable rotation at the end of the round (`hh = g; g = f;
…`) is four instructions per assignment (`lea; mov ebx,eax; mov
eax,[esp+M]; mov [ebx],eax`) where a register-resident version is one
`mov`. `__w_hash_sip` has the same shape with eleven locals.

The same measurement over the five most compute-looking test binaries
in `tests` (built by `./wbuild`, run under callgrind):

| binary | Ir | hottest function |
| --- | --- | --- |
| `sha256_test` | 365,705,189 | `sha256_block_w` 95.2% |
| `regex_test` | 238,553,961 | `lib/regex.w` `rx_here` 74.3% (recursive backtracking, `steps[0]` through a pointer) |
| `compress_corpus_test` | 5,036,289 | `__w_size_add` 12.2%, `malloc_debug_env_check` 8.7% |
| `json_test` | 3,482,963 | `malloc_debug_env_check` 12.6%, `freelist_malloc` 7.9% |
| `matrix_test` | 1,437,210 | `malloc_debug_env_check` 30.4%, `lib/stack_trace.w` `st_*` 41% |

Three of the five spend their time in process startup (the debug
allocator's environment check, the stack-trace module's DWARF line-table
parse). That is the state of "performance info from actual tests" today:
the suite is a correctness corpus with two hot loops in it, and §3's
profile must come from a benchmark set as well as from the tests.

### 1.3 What a register would remove (measured)

`sum_to(1000000000)` from §1.1, x86, three runs each. Variant A rewrites
only the loop's locals: `i` in `esi`, `s` in `edi`, every other property
of the accumulator model kept (the right operand still goes through
`ebx`, `n` is still read from the frame, the slots are still allocated).
Variant B is the five-instruction loop a real allocator would emit
(`cmp esi,edx; jge; add edi,esi; add esi,1; jmp`). Both were produced by
patching the function's bytes in place (nop-padded to the original
length) so nothing else in the binary moved, and all three print the
same result.

| | loop instructions | wall time | speedup |
| --- | --- | --- | --- |
| as emitted today | 20 | 1.37 / 1.43 / 1.41 s | — |
| A: locals in registers, accumulator model kept | 16 | 0.92 / 0.93 / 0.89 s | 1.5x |
| B: ideal | 5 | 0.45 / 0.39 / 0.47 s | 3.2x |

Variant A is what stage R2 (§6) produces; B is the ceiling that R3's
loop-scoped allocation plus the existing notes approach. Estimates for
the self-compile, labelled as such: with `r12`–`r15` and (R3) the
caller-saved registers free in call-free loops, the two functions in
§1.2 fit 10 of their locals in registers on x64 and lose roughly 40% of
their instructions (A-shaped), which is about 10% of the whole
self-compile instruction count and, since both loops are
store-forwarding-bound rather than issue-bound, plausibly 5–10% of wall
time. x86-32 with two registers gets the induction variable and one
accumulator per function — the build-id hash improves little there until
R4.

### 1.4 Register inventory per target

W-to-W calls use W's own convention (arguments pushed, result in the
accumulator, the callee pops nothing; `grammar/program.w:381–415`), so
"callee-saved" below is the discipline *this plan introduces* for W
functions, chosen to coincide with the C ABI's so that FFI calls
(`code_generator/ffi.w`: cdecl re-push on x86, System V on x64, AAPCS64
on arm64, Microsoft x64 on win64) preserve promoted registers for free.

| target | used today | free, callee-saved in the C ABI (R2) | free, caller-saved (R3, call-free loops only) |
| --- | --- | --- | --- |
| x86-32 | eax ebx ecx edx ebp(frame) esp | **esi edi** (2) | ecx edx when the loop has no variable shift, `/`, `%`, `cmpxchg` |
| x64 SysV | rax rbx rcx rdx rbp rsp | **r12 r13 r14 r15** (4) | rsi rdi r8 r9 r10 r11 (6), rcx/rdx as above |
| win64 | same encodings | r12–r15, plus rsi rdi are callee-saved in the Microsoft ABI (6) | r8–r11 |
| arm64 | x0 x1 x2 x9 x10 x28(W sp) x29 x30 | **x19–x27** (9) | x3–x8, x11–x17 |
| wasm32 | module globals / per-function locals | n/a: wasm locals already are registers to the engine (`code_generator/wasm.w` header: locals form is 13% faster than globals) | n/a |

`r12`–`r15` need REX.B/REX.R encodings the emitter does not have yet
(`emit_x64_opcode` only emits `0x48`); `libs/asm/registers.w` and the
x64 decoder already know them, so `asm_fuzz_x64_test` can check the new
encoder forms. Runtime stubs that clobber the callee-saved set must be
fixed in R2: on x86 `syscall7` loads `esi`/`edi` as syscall arguments and
does not restore them (`code_generator/x86_asm.w:16–22`), and
`stack_create` does the same (x86_asm.w:133–137); the x64 stubs use
`rsi`/`rdi`/`r8`–`r11` only. `gen_switch` already saves `ebx esi edi ebp`
(x86_asm.w:178) and `rbx rbp r12–r15` (x64_asm.w:62–65), so promoted
registers survive a generator switch. `repl_setjmp` saves only the
resume address, `esp` and `ebp` (x86_asm.w, `lib/setjmp.w` header) — see
§2.4.

### 1.5 What the AST gives an allocator today

The question that decides where the analysis lives: is a function body
available as a tree before its code is emitted? **No, not yet.** The
state after S2.2b (`ast_migration.md`, "Blocks, if/elif/else and while
from their records"): under `--ast-emit-retained` every statement and
every loop/switch *header* is parsed completely before its code is
emitted and then emitted by a walk (`code_generator/retained_emit.w`,
`retained_emit_statement`), `--stats` reports zero immediate statements
on `w.w`, but "no body is parsed whole before emission (the unit is
still one statement or header, and every body is preceded by a drain)".
Streaming is still the production default (P1.4 has not flipped it),
and `--ast-emit-retained` costs 1.9 s against 0.9 s for `w.w`.
`--ast-retain` records the whole forest, including function nodes with
nested statements and bindings, but it is written *after* each
construct's emission; `w tree --json` and `module_dependencies.w` read it
back, the emitter does not.

So a whole-body pre-pass over the retained tree is what checkpoint B's
S2.3–S2.5 will make possible (and `ast_completion_plan.md` C3.5 already
reserves "an optional tree-rewriting pass slot for #110" after S2.5),
but nothing an allocator can use in the next few months. The plan
therefore starts with a **token-level pre-scan** of the function body,
which the tokenizer already supports (`tokenizer_snapshot_save` /
`tokenizer_snapshot_restore`, `compiler/tokenizer.w:889/934`, the same
machinery the AST probe uses to speculate and rewind), computes exactly
the facts §2.2 needs, is seed-safe, and works identically under the
streaming grammar and under `--ast-emit-retained` (both reach the body
through `statement()` from `grammar/program.w:400` or
`grammar/ast_function.w:27`). When bodies become tree-first, the same
facts are read off the retained function node and the token scan is
deleted — the allocation decision and the emission mechanism are
unchanged. The retained forest *is* useful before then for the
differential test in §5: `w tree --json` lists every local and its uses
independently of the scan, which is an oracle for the scan's
address-taken and use-count facts.

### 1.6 Stats and profiling infrastructure that exists

- `w --stats` (`compiler/compiler.w:862`) prints symbol-lookup counters
  and the AST mode counters; `tools/wbench.w` runs four compile
  workloads, compares the deterministic counters and output size against
  `tools/wbench_baseline.txt` (`./wbuild wbench_compare`, not in `tests`),
  and reports wall time without failing on it (`docs/testing.md`,
  "Performance"). This is the model for §5: deterministic counts gate,
  wall time informs.
- `tools/wcoverage.w` is import-closure coverage (which modules no test
  imports), not line or edge coverage; nothing in the tree counts
  executed blocks.
- wexec caches toolchain targets by the content hash of their declared
  `inputs` (`tools/wexec.w:51–60`); `# wbuild:` directives accept
  `input=`/`data=` for extra inputs (`tools/wbuildgen_lib.w:976–986`).
  A profile file is an ordinary input under this scheme.
- `w defhash` emits one NDJSON record per definition with a SHA-256 of
  its token stream (`compiler/compiler.w:1900–2065`): the stable key §3.3
  needs, already computed by the compiler.
- Every image carries a GNU build-id (`elf_all.w:20`), DWARF line tables,
  subprograms, variables with `DW_OP_fbreg` locations and CFI (#555,
  `code_generator/dwarf_info.w:326–389`), so `perf record`/`perf report`
  would map samples back to W source lines if `perf` were available — it
  is not in this container (no `linux-tools`), and `valgrind` is. wdbg
  reads locals from the trapped `esp` and the statement's recorded
  `stack_pos` (`debugger/locals.w:95`, `debug_line_note` in
  `code_generator/dwarf.w:67`) and has every register of the stop in
  `debugger/sigcontext.w` (`sigcontext_esi`, `sigcontext_r12`, …).
- `lib/testing.w` has a run summary, `--filter`, and `W_TEST_LEAKS`; the
  runtime reads the environment through `lib/env.w` `env_get`, and every
  program exits through `lib/lib.w` `_main` → `exit(main(argc, argv))`
  (lib.w:39) or an explicit `exit()`: the places a profile dump hooks.

## 2. Register allocation: options and the recommended design

### 2.1 Options

| option | substrate needed | fits today? | ceiling | risk |
| --- | --- | --- | --- | --- |
| (a) function-scoped promotion of hot scalar locals into callee-saved registers, decided by a pre-scan | token pre-scan now, retained tree later | yes | variant A of §1.3 (1.5x on loop-bound code) | low: frame layout unchanged, fail-closed emission |
| (b) loop-scoped allocation: induction variables and loop-invariant locals, caller-saved registers in call-free loops | (a) plus loop extent from the scan | yes, after (a) | approaches variant B for simple loops | medium: register lifetime ends at the loop exit, spill on every exit edge incl. `break`/`return`/`goto` |
| (c) linear scan over a lightweight IR built from the retained tree | tree-first bodies (S2.5) | no, 2027 | general | high: a second lowering of every construct; `ast_completion_plan.md` C3.5 is the slot for it |
| (d) graph colouring | an IR with liveness | no | general | rejected: cost and compile-time budget (`optimization.md` §2.3) for a language whose point is a fast single pass |

Recommendation: (a) then (b), both in the emitter, both seed-safe, both
inside the existing fixpoint gate; (c) is revisited when C3.5 exists and
then *reuses* (a)'s emission mechanism (the register lvalue), only
replacing the decision procedure.

### 2.2 The promotion mechanism (unit R2)

**Decision.** At the start of a function body (`grammar/program.w`
before `statement()` at line ~400, and `ast_function_body` in
`grammar/ast_function.w:27`), `regalloc_prescan()` snapshots the
tokenizer, walks tokens to the end of the body (the first non-blank line
at indentation 0 that is not a comment; the same extent
`generic_reparse_start` and `defer` already compute from offsets), and
restores. It records per identifier: declaration count, read count and
write count weighted by loop nesting (`while`/`for` keyword depth from
indentation, weight 8^depth), whether it ever follows `&`, `.`, `->`, or
precedes `[`, `.`, `(`, `++`, `--`, or a compound operator (R2 promotes
plain `=` only; `+=` and `++` join in R3 as `add reg,…`), and
function-level facts: contains a call (`(` after an identifier that is
not a keyword), `raw_asm`, `goto`/label, `setjmp`/`longjmp`, `yield`,
`defer`, a variadic signature, a thread-local reference. A name declared
twice (shadowing compiles; `lint`'s `shadow` rule is opt-in) is not
promoted. The scan is conservative by construction: `a &x` with a
bitwise `&` looks like address-of and only loses an optimisation. The
candidates are word-sized `int`/pointer locals (`type_stack_words == 1`,
not `float`, not a struct, not `int8`/`int16`/`int32`/`bool` whose
narrow loaders would otherwise need register twins), ranked by weighted
use count; the top `k` (2 on x86, 4 on x64) become promoted, mapped to
registers at their declaration. Functions with `raw_asm`, generator
bodies (frameless, `be_frame_active == 0`), variadic functions and
functions calling `setjmp` promote nothing.

**Emission.** `sym_declare` for a promoted local records the register
in the symbol record (one spare field; the record layout is
`compiler/symbol_table.w`'s packed table, append a field rather than
overload the slot). `sym_emit_value` (`symbol_table.w:841`) for a
promoted `'L'` symbol emits no bytes and sets a *register lvalue note*
(`reg_lvalue = R`, `reg_lvalue_end = codepos`, same contract as the lea
note: valid only while nothing has been emitted since). The consumers:

- `promote()`'s word-sized path (`grammar/promote.w:315–345`,
  `promote_eax`) with a current note emits `mov eax,R` and clears it;
- the assignment rule (`grammar/expression.w:225`) with a current note
  after the lvalue parse remembers `R`, skips the address push and the
  `pop_ebx`, evaluates the right side, coerces, and emits `mov R,eax`;
- `&x` (`unary_expression.w:213`) with a current note is an internal
  error (the scan excluded it);
- `for_range_loop` / `emit_loop_ast_walk` store and increment the loop
  variable through `store_stack_var`/`inc_dword_esp_plus`
  (`for_statement.w:274/301`, `code_generator/loop_ast.w:9/99`); when
  `for_var`'s symbol is promoted they emit `mov R,eax` / `add R,1`
  instead, and the condition reads `R` directly, which is where the
  `inc DWORD PTR [esp+4]`-shaped loops of the compiler get their win.

**Fail-closed guard.** `emit()` in `code_generator/code_emitter.w` (the
one byte sink every helper uses) checks `reg_lvalue_end == codepos &&
reg_lvalue != 0` on entry and raises an internal error naming the local
("register-resident local used by an unhandled path"). A grammar path
that materialises the lvalue address for anything other than the
consumers above therefore fails the compile loudly, and since
`./wbuild build` compiles the compiler and `./wbuild tests` compiles
850-odd test programs, the places the list above missed are found by the
gates, not by users. The cost is one integer compare per emitted byte
sequence, inside a function that is 1.08% of the self-compile (§1.2).
The low-level slot helpers (`load_slot`, `push_slot_copy`,
`store_stack_var` with a promoted slot) get the same assertion via a
per-function bitmap of promoted slots.

**Frame.** The promoted local keeps its stack word: `variable_declaration.w`
still pushes it (`stack_pos` arithmetic, `drop_slots`, `pop_to`, every
`stack_pos - slot` computation and the DWARF `DW_OP_fbreg` of *other*
locals are untouched), it just holds the initial value and is never read.
The prologue pushes the function's promoted registers right after `mov
ebp,esp` and `be_frame_words()` (`arm64.w:505`) returns `1 + saved`, so
argument addressing stays correct through the existing
`stack_pos = stack_pos + frame_words` at `program.w:387`; `be_return`
(`x86.w:1547`) becomes `lea esp,[ebp-8*saved]; pop …; pop ebp; ret` in
place of `leave; ret`, and `be_return_bare` the same. `.debug_frame` CFI
(`dwarf_leave_note`) records the extra pushes. `lib/stack_trace.w`'s
walk (`[ebp]` → caller's `ebp`, `[ebp+word]` → return address) is
unchanged. Deferred expressions re-parsed at exits (`grammar/defer.w`)
resolve the same symbol and emit `mov eax,R` like any other read.

### 2.3 Loop-scoped allocation (unit R3)

With (a) in place, the loop extent from the scan lets a *loop* own
registers: in a loop whose body contains no call (`emitted_call_count`
snapshots, x86.w:444, already do this for `operand_is_pure`), no
variable shift, `/`, `%` or atomic, the caller-saved set is free:
`rsi rdi r8–r11` on x64, `ecx edx` on x86. The loop header loads each
loop-owned local from its home (slot or callee-saved register) into the
caller-saved register and every exit edge writes it back: the loop's
break region end (`be_ctrl_end(loop_break_chain)`), each `return`
inside the body (the exit phase in `grammar/statement.w` that already
runs the for-cleanup registry and deferred statements), and `goto` out
of the loop (R3 declines loops in functions with labels). Promoted
compound assignments and `++` (`compound_assign_apply`,
`expression.w:95`) emit `add R,…` directly. The loop head is aligned to
16 bytes with a nop sled when §3 marks it hot (alignment is the one
transformation that *needs* the profile: it costs bytes everywhere else).

### 2.4 Hazards, and the rule for each

| hazard | rule |
| --- | --- |
| address-taken locals (`&x`, `x.f`, `x[i]` on an array local, aggregates) | never candidates; scan excludes, emission asserts |
| calls inside loops | R2 uses callee-saved registers, so a call costs nothing; the callee's prologue saves what it uses. R3 uses caller-saved registers only in call-free loops |
| `defer` | reparse at exits goes through `sym_emit_value`, works unchanged; functions with `defer` are allowed in R2, excluded from R3 (exit edges multiply) |
| `goto`/labels | function-scoped promotion is unaffected (registers are live for the whole body); R3 declines functions with labels |
| `raw_asm` | the function promotes nothing (an asm block may use any register) |
| `setjmp`/`longjmp` | `repl_setjmp` must save and `repl_longjmp` restore the callee-saved set (x86 `ebx esi edi`, x64 `rbx r12–r15`, arm64 `x19–x28`) so a frame *below* the `setjmp` caller that promoted a register cannot leak its value into the caller's caller; the `setjmp` caller itself promotes nothing, which also keeps `lib/setjmp.w`'s documented "locals keep their latest value" contract for that frame. `lib/setjmp.w`'s header comment ("there is no register allocation") is rewritten in the same PR |
| threads / `thread_local` | a new thread starts in `thread_create` with fresh registers; TLS is `fs:`/`gs:`-relative (`be_tls_address`, `arm64.w:414`) and uses no GPR; nothing to do |
| generators | bodies are frameless and switch stacks through `gen_switch`, which saves the callee-saved set; R2 excludes generator bodies rather than reason about resumption |
| REPL / wdbg in-process compilers | the notes and the per-function bitmap are compiler globals reset at function end; `repl/core.w`'s checkpoint/rollback captures compiler globals already (`peep_rollback` is called from the REPL rollback path) — the new state joins the same reset list, and `ast_expression_test`'s REPL legs cover it |
| wdbg variable lookup | `debug_local_note` (`dwarf.w:126`) gains kind `'R'` with the register number in the slot field; `dbg_local_runtime_addr` (`debugger/locals.w:95`) returns the saved register from the stop's sigcontext for `'R'` (read-only in the first cut; writes go to the register save area the stop restores from). `wdbg_*` tests get a case with a promoted local |
| DWARF | `dwarf_variable_note` emits `DW_OP_reg<n>` for `'R'` locals instead of `DW_OP_fbreg`; `gdb` on a `--profile-use` build shows locals, checked by a new `dwarf_register_variable_test` with the small DIE walker C3.3 brought |
| stack traces / unwinding | unchanged (frame chain) |
| float / SSE | float bits travel as integers in `eax` (`code_generator/sse.w` header) and would promote as words — excluded in R2 because `promote()`'s float coercions read memory operands; revisit when there is a case for it |
| 32- vs 64-bit pressure | two registers on x86-32 is why the plan says "x64 first": the compiler's hot loops have 12–20 live locals. x86-32 gains the loop variable and one accumulator per function (R2), `ecx`/`edx` in call-free loops (R3) |
| variadic (`w_variadic`) functions | excluded: argument addressing uses `number_of_args` at run time |
| diagnostics | no message text changes, so `warning_test` and the fixtures stay; promotion emits no diagnostics |

## 3. Performance-driven optimization

### 3.1 What a profile must tell the compiler

Two kinds of fact: *where the time is* (which functions, which loops,
how many iterations per entry) and *what is cold* (never executed in any
run). The first chooses the register budget and compile-time spend; the
second drives layout. None of it is needed for correctness, so a
missing, stale or wrong profile only costs performance. §1.2 says the
suite alone will mark `sha256_block_w`, `rx_here`, a few `lib/stack_trace.w`
and allocator functions and the compiler's own tokenizer/table code as
hot, and nothing else; the benchmark corpus in §5 supplies the rest.

### 3.2 Collection: instrumented counters (recommended), sampling (optional)

`--profile-generate` (compiler flag, compiler.w option block) makes the
emitter:

- reserve one 8-byte counter per function and per loop head in the RW
  data segment (`emit_data_global_storage`, `grammar/program.w:424`,
  already lays out zero-initialised globals there) and emit
  `inc QWORD PTR [abs]` (x86-32: `add [abs],1; adc [abs+4],0`) at the
  function's first instruction after the prologue and at every
  `be_ctrl_loop` (`x86.w:787`) site reached from `while`/`for`;
- write a sidecar `<output>.wprofmap` (text, one line per counter:
  index, kind, `defhash` of the enclosing function, function name, file,
  line) at compile time, so the binary carries only integers;
- route program exit through `__w_profile_flush` (a runtime function in a
  new `lib/profile.w`, auto-imported in this mode the way
  `compiler/compiler.w` auto-imports the container runtime): if
  `W_PROFILE_OUT` is set, append `index count` lines to that path with
  `O_APPEND` so concurrent test processes do not interleave records
  (each line is written with one `write`). `_main`'s `exit(main(...))`
  (lib.w:39) and the `exit` stub both reach it; `_exit` after a crash
  does not, which is acceptable (a crashing run is not a performance
  sample).

Cost: one memory increment per loop iteration and per call, no
registers touched (`inc mem` preserves everything but flags, and the
sites chosen never sit between a `cmp` and its branch). Deterministic,
available on every CI runner, works for the self-compile under wexec.
x86/x64 first; arm64 can follow with `ldr/add/str` through `x9`.

Sampling alternatives are documented, not built: `perf record` with the
existing build-id, DWARF line and subprogram tables already gives
function- and line-level attribution on a machine that has `perf`
(`tools/perf_report.sh`-style glue, no compiler change), and wdbg could
sample a child by `SIGPROF` (`debugger/sigcontext.w` has the PC) — a
later nicety for interactive use, not the CI path.

### 3.3 Profile format, keying, storage

`bin/wprof` (`tools/wprof.w`, a leaf tool, newer syntax allowed) merges
raw dumps with their maps into a text profile:

```
# wprof v1  generated 2026-10-07 from: tests, bench/self
f 7c1e…a9 sha256_block_w lib/sha256.w 101 entries=43021
l 7c1e…a9 sha256_block_w lib/sha256.w 128 head=1 iters=2753344
l 7c1e…a9 sha256_block_w lib/sha256.w 136 head=3 iters=2753344
f 30e4…53 sum_range tests/bench/sum.w 9 entries=1
```

The key is the function's `defhash` (`w defhash`, already a 64-hex token
hash of the definition): rename the file, reformat, move the function,
and the entry still matches; change one token of the body and it
silently stops matching, so the function is treated as "unknown" (the
static heuristic applies) rather than mis-optimised. `l` lines are keyed
by hash plus the loop's ordinal within the function (`head=`), not by
line number, for the same reason; line and name are informational.
Counts are merged by summation across runs; `bin/wprof stats` prints
how many entries of a profile still match a source tree (the staleness
number a PR body quotes).

Storage: `profiles/<name>.wprof` committed, small (one line per function
and loop that ever ran: a few thousand lines for the compiler), text, so
diffs review. Two files to start: `profiles/self.wprof` (the compiler
compiling `w.w` under `--profile-generate`) and `profiles/bench.wprof`
(`./wbuild bench` corpus plus the test suite). `./wbuild profile_refresh`
regenerates them (not in `tests`, like `wbench_compare`); a PR that
changes hot code re-runs it and commits the result, saying why the
numbers moved — the same policy `docs/testing.md` sets for the wbench
baseline.

### 3.4 What the profile decides

- **Who gets the registers.** A function with entries above a threshold
  or any loop with `iters/entries ≥ 16` is *hot*: the pre-scan runs and
  promotion happens. Cold functions skip the scan (the scan's cost is
  the compile-time budget `optimization.md` §2.3 worries about: a token
  walk over 58k lines is 10–20% of a compile if done everywhere, almost
  nothing if done for the 3% of functions that matter). Without a
  profile, R2's heuristic is "any function containing a loop", which is
  what the first measurements use.
- **Register budget inside a hot function.** The weighted use counts use
  real iteration counts instead of 8^depth where a loop has an `l` entry.
- **Hot loop alignment** (R3) and, later, **cold block layout**: a
  function with `entries=0` in every profile moves after the hot
  functions in the image (`be_function_define` order is the emission
  order today, so this is a deferred-emission question that waits for
  tree-first bodies — recorded as a non-goal for now).
- **Inlining small hot callees** (P3): W has no inliner ("W has no
  inliner", x86.w:486); the candidates are leaf functions under ~12
  tokens of body with a hot call count (`sha256_rotr`, `rotl`,
  `type_get_kind` accessors). This needs the callee's body as a tree or
  a token span and the AST's S2.3 reparse-from-tree work; it is planned
  but not scheduled.

### 3.5 Determinism: fixpoint and cache keys

The output of a compile must be a pure function of (sources, flags,
profile file). Three rules keep it so:

1. The profile is read only from `--profile-use=<path>`; the compiler
   never looks for one implicitly, never reads `W_PROFILE_OUT`, never
   writes one. `./wbuild verify` builds `wv3`, `wv4`, `wv5` with the
   *same* flag and the *same committed* `profiles/self.wprof`, so the
   stages are byte-identical by the same argument as today's fixpoint.
   `verify` with no profile flag remains the required gate for every
   compiler change; `verify_pgo` (new) is the fixpoint with the flag.
2. Every target that passes `--profile-use` lists the profile as an
   `input=` (wexec content-hash cache, `tools/wexec.w:51`), so editing
   the profile invalidates exactly the targets that read it.
3. `--profile-generate` output is also deterministic (the counter table
   is laid out in emission order); only the *runs* are not, and their
   dumps are merged offline by `bin/wprof`, whose output is sorted.

The seed does not know either flag (§4), so `bin/wv2` is always built
without a profile; `wv3` onwards may use one. The promoted-register
*mechanism* is not profile-dependent, so its fixpoint is the plain
`verify`.

### 3.6 The compiler as the first PGO target

Both of §1.2's top functions are in `w.w`'s import graph, so the first
`--profile-use` build of `bin/wv3` is where the plan's claims are
checked: `bin/wbench self` (wall) and callgrind Ir for the matched-input
compile before and after, with the numbers in the PR body as every
`compiler_performance.md` section does. Side finding to carry along: at
22k instructions per block, hashing the 2.7 MB image for the build-id is
13% of every compile today; the register work is the right fix (it is
also what makes `defhash` cheap), but if R2's x86-32 result is weak, an
explicit `uint32` arithmetic path for `& mask`-emulated 32-bit code is
the fallback worth measuring.

## 4. Seed constraint

Everything in §2 and the counter emission of §3 lives in
`code_generator/`, `grammar/`, `compiler/`, and `lib/profile.w` would be
auto-imported by the compiler: all of it is compiled by the pinned seed
(`SEEDS`, v0.3.0) and may use no syntax newer than it (CLAUDE.md "Seed
constraint"). `tools/wprof.w` and `tests/bench/*` are leaf consumers and
may use anything `bin/wv2` accepts. No unit here adds language syntax,
so `tests/parser_generator/w.pg` does not change. The bootstrap chain
after P2: seed → `wv2` (plain) → `wv3` (`--profile-use profiles/self.wprof`)
→ `wv4` → `wv5`, with `verify_pgo` asserting `wv3 == wv4 == wv5`; a
`SEEDS` bump later makes `wv2` itself a PGO build, which changes nothing
about the gate.

## 5. Verification and benchmarking

**Correctness gates** (every compiler-tree unit): `./wbuild verify`,
`verify_x64`, `tests` (which includes `parser_generator_w_test`,
`warning_test`, the `type_system_*` fixtures and `manifest_check`);
`verify_arm64`, `verify_win`, `verify_wasm`, `verify_darwin` for units
that touch shared emitters (R2's prologue change does); `verify_pgo`
once P2 lands.

**Differential test** (new, `tests/regalloc_diff_test.w` owning a
target): compile every tracked `.w` outside the compiler tree that has a
`main` twice — with `--no-regs` (the opt-out flag R2 adds; `-O0` is the
alias) and without — run both where the manifest says the program runs,
and compare exit status, stdout and stderr; S2.2c's "518 tracked files
with a `for` or `switch`" sweep is the template. In addition compile
`w.w` both ways and compare `bin/wv2 --no-regs` vs `bin/wv2` *outputs*
on the fixture corpus (the images differ, their behaviour must not).
`tests/regalloc_test.w` (`# wbuild: x64`) pins the contract the way
`tests/local_load_fold_test.w` does: every hazard row of §2.4 has a case
(address-taken neighbour, call in loop, defer, goto, shadowing, setjmp
across a promoted frame, generator, variadic, `break`/`return` from an
R3 loop), each asserting the computed value.

**Debugger gates:** `wdbg_*` with a promoted local (read a register
local at a breakpoint), `dwarf_register_variable_test`, `repl_*` and
`ast_expression_test`'s REPL legs (in-process compiler state).

**Benchmark corpus and harness:** `tests/bench/` holds small
compute-bound programs with a `# wbuild: target=bench_<name> tag=bench`
block each — `sum` (§1.3), `sieve`, `sha256_1m` (1 MB through
`lib/sha256.w`), `siphash_keys` (a million map inserts), `inflate_corpus`
(the compress corpus 50x), `regex_backtrack`, `matmul_256`, `strcmp_sort`
(`list.sort` on strings), plus `self` (`bin/wv3 --quiet w.w`). `bin/wbench`
grows a `--programs` mode: for each, best-of-N wall time and, when
`valgrind` is present, callgrind Ir and the Ir of the top three
functions; `./wbuild bench` runs them and writes `bin/bench.txt`;
`./wbuild bench_compare` compares against `tests/bench/baseline.txt` with
the wbench rules (deterministic counts gate within tolerance, wall time
reported only; Ir is deterministic per binary and so can gate when the
runner has valgrind, and is skipped — not failed — when it does not).
Instruction count is the CI metric; wall time is the number the PR body
reports from an idle machine, labelled with the machine.

**CI:** no change to the main leg (`./wbuild tests tests_interop`,
`.github/workflows/ci.yml:79`); a new optional `bench` job runs
`./wbuild bench_compare` on pushes to `main` and uploads `bin/bench.txt`
as an artifact so regressions are visible without gating merges on a
shared runner's clock. The job is described, not committed, here; a
patch is at `/mnt/project-files/opt-plan/ci-bench.patch` for the
maintainer to apply.

## 6. Staged plan

Each unit is sized for one agent on one branch and one PR, in the
`ast_completion_plan.md` §3 protocol (branch `opt/<unit>-<slug>`, PR body
Before/After/How with the measurements the unit names, `bin/wtest
changed` for focused targets, `./wbuild tests` before declaring done,
stop and report rather than widen scope when a gate fails outside the
unit's files). "Owns" is what the unit may edit; shared-file rules are
in §6.1.

**R1 — remove what costs nothing to remove (first, small, measurable).**
`be_pop(0)` emits nothing (x86.w:671; arm64/wasm twins already have the
`n == 0` question — check and align); `lea_eax_esp_plus` uses the disp8
form through `emit_eax_esp_disp` when the displacement fits (the
`lea_note_disp` fold and `peep_rollback` are unaffected, since the note
records `codepos` not a length — confirm `lea_load_fold` does not assume
7 bytes); `mov_eax_int` on x64 emits `mov eax,imm32` for values in
`[0, 2^31)` (zero-extends) and `mov rax,simm32` for negative values that
fit, keeping `movabs` otherwise and keeping the immediate note's `start`
correct. Expected: `bin/wv3` −13.7k instructions and ≈−90 KB on x86
(2.3% of instructions by count), a further few percent of bytes on x64;
self-compile Ir change small but nonzero (the `add esp,0` sits on loop
back edges). Owns: `code_generator/x86.w`, `tests/local_load_fold_test.w`
(new cases). Gates: `verify`, `verify_x64`, `local_load_fold_test`,
`asm_x64_test`/`asm_fuzz_x86_test` (the decoder sees new forms), `tests`.
Measurements in the PR: the §1.1 table before/after, `wbench self`.

**R2 — function-scoped promotion (the mechanism), x64 then x86.**
§2.2 in full: the token pre-scan (`compiler/regalloc_scan.w`, new), the
symbol-record register field, the register lvalue note and its
consumers, the `emit()` guard, the prologue/epilogue change with CFI,
REX.B/REX.R helpers for `r12`–`r15`, the x86 stub fixes (`syscall7`,
`stack_create` save/restore `esi`/`edi`), `repl_setjmp`/`repl_longjmp`
saving the callee-saved set, `--no-regs`/`-O0`, `'R'` kind in
`debug_local_note` with wdbg and DWARF support, and `lib/setjmp.w`'s
comment. Heuristic without a profile: functions containing a loop,
budget 4 on x64 and 2 on x86, by weighted use count. Expected (estimate,
§1.3): `bench_sum` ≈1.5x on both widths; `sha256_1m`/`self` on x64
−10–25% Ir in the two hot functions, a few percent of the whole
self-compile; x86 smaller. Owns: `code_generator/x86.w`, `x86_asm.w`,
`x64_asm.w`, `arm64.w` (prologue/`be_frame_words` only), `dwarf.w`,
`dwarf_info.w`, `compiler/symbol_table.w` (record field + `sym_emit_value`),
`compiler/regalloc_scan.w` (new), `grammar/promote.w`,
`grammar/expression.w` (assignment), `grammar/unary_expression.w`,
`grammar/variable_declaration.w`, `grammar/program.w` and
`grammar/ast_function.w` (one call each), `debugger/locals.w`,
`debugger/registers.w`, `lib/setjmp.w`, `tests/regalloc_test.w`,
`tests/regalloc_diff_test.w` (new). Gates: `verify`, `verify_x64`,
`verify_arm64` (prologue), `tests`, the two new tests, `wdbg_*`,
`repl_*`, `ast_expression_test`, `ast_retained_emit_test`
(`--ast-emit-retained` must take the same path). This is the HIGH-care
unit: it merges alone, after R1.

**R2b — for-range loop variables and hidden range slots (after R2,
small).** `for i in range(...)`'s `for_var` and the hidden end/step slots
through the register path in both `for_statement.w` and
`code_generator/loop_ast.w` (the S2.2c walk), `inc R` for the increment,
and the condition's compare against a register. Expected: every
`for`-range loop in the compiler loses its push/pop pair and both loads.
Owns: `grammar/for_statement.w`, `code_generator/loop_ast.w`,
`grammar/ast_loop.w` (record the variable's register). Gates:
`for_*`/`iteration_*` targets, `regalloc_test`, `verify`, `verify_x64`.

**P1 — counters, dump, merge (parallel with R2; independent files).**
`--profile-generate`, the counter table and map sidecar, `lib/profile.w`,
`bin/wprof merge|stats`, the `.wprof` format, `W_PROFILE_OUT`, and
`./wbuild profile_refresh` producing `profiles/self.wprof` and
`profiles/bench.wprof` (the latter needs B1). Expected: a `w.w`
self-compile under `--profile-generate` costs a few percent (one `inc
mem` per loop iteration and call); the profile for the compiler is a
few thousand lines. Owns: `compiler/compiler.w` option block (one tagged
block), `code_generator/profile_counters.w` (new), `lib/profile.w` (new),
`tools/wprof.w` (new), `profiles/` (new), `tests/profile_generate_test.w`
(new: compile a fixture, run it with `W_PROFILE_OUT`, merge, assert
counts). Gates: new test, `verify` (counters off is the default),
`verify_profile_generate` (fixpoint with the flag on, like
`ast_expression_verify`), `tests`.

**B1 — benchmark corpus and harness (parallel with R2 and P1).**
`tests/bench/*` programs, `bin/wbench --programs`, `./wbuild bench`,
`bench_compare`, `tests/bench/baseline.txt`, the callgrind integration
(skip when absent). Owns: `tests/bench/`, `tools/wbench.w`,
`docs/testing.md` (Performance section). Gates: `wbench_compare_test`,
`bench` runs green, `tests`.

**R3 — loop-scoped allocation and compound operators (after R2, R2b).**
§2.3: caller-saved registers in call-free loops, write-back on exit
edges, `+=`/`++` on promoted locals, `ecx`/`edx` on x86 when the loop
has no variable shift/`div`, 16-byte hot loop alignment behind a flag
(default off until P2). Expected (estimate): `bench_sum` toward the 3.2x
of variant B; sha256's round loop on x64 with 10 registers loses most of
its 106 memory operations. Owns: `compiler/regalloc_scan.w`,
`code_generator/x86.w` (loop header/exit helpers), `grammar/while_statement.w`,
`for_statement.w`, `statement.w` (exit phase write-backs), `expression.w`
(compound path), `increment.w`, `tests/regalloc_test.w`. Gates: as R2
plus `defer_*`, `goto_*`, `generator_*`.

**P2 — profile-driven decisions and the PGO bootstrap chain (after R2,
P1, B1).** `--profile-use`, hot/cold classification, budget from real
counts, alignment on hot heads, `verify_pgo`, `build.base.json` entries
for `wv3`–`wv5` with the profile as `input=`, `./wbuild profile_check`
(staleness report, non-failing) in `tests`. Expected: the self-compile
numbers of §3.6 in the PR body (callgrind Ir and `wbench self`, matched
input), plus `bench_compare` before/after. Owns: `compiler/compiler.w`
(option block), `compiler/profile_use.w` (new), `build.base.json`,
`profiles/`, `wbuild` docs in CLAUDE.md/README. Gates: `verify`,
`verify_pgo`, `profile_generate_test`, `bench_compare`, `tests`.

**R4 — the 32-bit target and arm64 (after R3).** Measure x86-32 with the
corpus; if the two-register budget leaves `sha256_block_w` slow, add the
`uint32` arithmetic path of §3.6 or accept the result and say so. arm64:
`x19`–`x27` with `stp`/`ldp` save pairs in `be_function_prologue`, the
same lvalue note, `verify_arm64` under qemu. Owns: `code_generator/arm64.w`,
`sse.w` (no float promotion; confirm), `tests/regalloc_test.w` (arm64
leg). Gates: `verify_arm64`, `tests_arm64`.

**P3 — inlining small hot leaf callees (after S2.3 of the AST plan).**
Design-only in this document (§3.4); its unit is written when
tree-from-retained reparse exists.

### 6.1 Waves, ownership, shared files

| wave | units in parallel | serial gate before next |
| --- | --- | --- |
| 1 | R1, P1, B1 | R1 merged (x86.w settles before R2 edits it) |
| 2 | R2 (alone on the emitter), P1/B1 finishing | R2 merged |
| 3 | R2b, P2 | both merged |
| 4 | R3, R4 | — |
| 5 | P3 (when its AST dependency exists) | — |

Shared-file rules: `compiler/compiler.w`'s option block takes one
contiguous tagged block per unit (as `ast_completion_plan.md` §3
requires); `code_generator/x86.w` is owned by exactly one unit per wave
(R1, then R2, then R3); `compiler/symbol_table.w`'s record gets a field
appended, never a repurposed slot; `build.base.json` is edited only by
P2; every unit appends a dated section to this document's §11 rather
than rewriting §1–§5, and a unit that measures something different from
what §1 predicts says so there.

## 7. Non-goals

- A general IR, linear scan or graph colouring (options (c)/(d)); the
  slot for a tree pass is C3.5 of the AST plan and this plan's emission
  mechanism is designed to be its backend.
- Register allocation for wasm (the engine does it) and PTX (the driver
  JIT does it; `cuda.md` says so).
- Float/SSE register residency.
- Function reordering, hot/cold splitting, outlining: all need deferred
  emission (tree-first bodies).
- Changing W's calling convention (arguments stay on the stack; the
  accumulator stays the return channel).
- Sampling profilers in CI; `perf` glue is documented, not built.
- Making any optimisation non-deterministic or implicit: no automatic
  profile discovery, no time-based decisions.

## 8. Risks

- **The guard finds too many paths.** The `emit()` assertion will fire
  in grammar paths §2.2 did not list (struct-returning calls parking
  buffers, `multi_assign.w`, `ndarray_index.w`, operator overloads
  rewinding the tokenizer). Each is either made register-aware or added
  to the scan's exclusion list; the unit stops and reports if the list
  grows past what one PR can review. The scan excluding a local is
  always safe.
- **Compile time.** The pre-scan is a second token walk over every
  function containing a loop; budget: `w.w` compile within 1.05x of
  today's 0.92 s without a profile, within 1.02x with one (cold functions
  skip the scan). `wbench` gates the counters, the PR reports the clock.
- **Callee-saved discipline is new.** Every W function that promotes
  pays `push`/`pop` pairs; functions that are called in a hot loop but
  promote inside a cold path lose. The weighted use count and, with P2,
  the profile keep promotion to functions where the loop count justifies
  the prologue; the differential sweep catches a function that promotes
  and misbehaves.
- **REPL/wdbg state** (the sharpest risk `wbuildd.md` names for every
  compiler-state change): new globals must join the checkpoint/rollback
  set; the existing REPL legs of `ast_expression_test` and `repl_*` are
  the detector, and R2 adds a REPL case with a promoted local redefined.
- **Stale profiles mislead.** Keying by `defhash` makes a changed
  function unknown rather than misjudged; `profile_check` reports the
  match rate so a PR that drops it below, say, 80% refreshes the profile.
- **arm64/darwin verification needs qemu or a Mac** (CLAUDE.md
  platform notes); R2's prologue change is cross-checked by
  `verify_arm64` in CI's arm64 leg, R4's register work waits for that
  leg to be exercised locally.

## 9. Open decisions for the maintainer

1. **x64 first, x86-32 best-effort?** §1.4's inventory is the reason;
   the alternative is to also take `ebx` as a promotable register on
   x86 by moving the operand shuttle to `ecx`, a wide change to
   `x86.w` with its own fixpoint risk. Recommendation: x64 first, decide
   on `ebx` after R2's x86 numbers.
2. **Default-on or flag?** `optimization.md`'s third open question
   applies: the plan makes promotion default-on with `--no-regs`/`-O0`
   as the opt-out once R2's differential sweep is clean, because an
   opt-in optimiser is not exercised by the fixpoint. Recommendation:
   default-on for R2 with the sweep in `tests`; alignment and R3's
   caller-saved mode default-off until P2.
3. **Where profiles live.** Committed `profiles/*.wprof` regenerated by
   `./wbuild profile_refresh` (recommended; mirrors the wbench
   baseline), versus generated in CI and never committed (which makes
   `verify_pgo` depend on a build artefact, so it is not recommended).
4. **Instruction-count gating in CI.** `bench_compare` gating on
   callgrind Ir needs `valgrind` on the runner (an `apt install` in the
   bench job); otherwise it reports only. Recommendation: install it in
   the optional bench job, keep the main leg untouched.
5. **Whether R1's `mov_eax_int` change waits for a seed bump.** It
   changes every x64 image and so the x64 fixpoint; it is seed-safe
   (emitter code, no new syntax) and needs no bump, but it is the one R1
   item that changes bytes everywhere rather than removing a no-op.

## 10. Commands that back §1

```sh
./wbuild build                                   # bin/wv2..wv5 (0.92-0.96 s per self-compile here)
objdump -d -Mintel bin/wv3 > /tmp/wv3.dis        # §1.1 table: grep -cP for each pattern
valgrind --tool=callgrind --callgrind-out-file=/tmp/self.out bin/wv2 --quiet w.w -o /tmp/x
callgrind_annotate /tmp/self.out | head -40      # §1.2: map addresses with objdump's symbol lines
./wbuild sha256_test compress_corpus_test matrix_test regex_test json_test
for t in sha256_test regex_test compress_corpus_test json_test matrix_test; do
  valgrind --tool=callgrind --callgrind-out-file=/tmp/$t.out bin/$t; done
bin/wv2 /tmp/bench_sum.w -o /tmp/bench_sum32 && time /tmp/bench_sum32   # §1.3 (sum_to(1e9))
bin/wv2 defhash tests/sha256_test.w | head -3    # §3.3 key format
bin/wv2 check --quiet --ast-retain --ast-required --stats w.w             # §1.5 counters
```

The hand-patched variants of §1.3 were produced by rewriting
`sum_to`'s bytes at file offset `vaddr - 0x08048000` (the single R E
`LOAD` segment) and nop-padding to the original 105 bytes; the
instruction sequences are listed in §1.3's text.

## 11. Landed units

(each unit appends a dated section here: what landed, the
measurements, what it does not claim.)

### R1 — remove what costs nothing to remove (2026-10-07)

Landed in `code_generator/x86.w` (three emitters, nothing else) and
`tests/local_load_fold_test.w` (three new cases, both widths):

- `be_pop(0)` emits nothing, on every ISA (the `n == 0` return sits
  before the dispatch: x86/x64 lose the 6-byte `add esp,0`, arm64 the
  `add x28,x28,#0`, wasm the four-op `global.get/i32.const 0/i32.add/
  global.set`, PTX the `add.u64 %sp,%sp,0` line — no fixture pins any of
  them). The sp-relative notes stay valid across the site because the
  stack does not move; the one behavioural change is that a comparison's
  flags now survive a scope end, which is exactly what `cmp_fuse` needs.
- `lea_eax_esp_plus` goes through `emit_eax_esp_disp`, so a displacement
  in `[-128, 127]` is the 4-byte (5 on x64) disp8 form. `lea_load_fold`,
  the `add_eax_int32` member-offset fold and `peep_rollback` only ever
  used the note's start/end positions, so nothing assumed 7 bytes.
- `mov_eax_int` on x64 emits `mov eax,imm32` (5 bytes, zero-extending)
  for `0 <= v < 2^31` and keeps the 10-byte `movabs` otherwise. The
  classification `(v >> 31) != 0` is host-independent (a 32-bit
  compiler cannot hold a value the 64-bit one would classify
  differently; bit-31 literals are negative on both). **Deviation from
  the plan:** the `mov rax,simm32` (REX.W C7 /0) form for negative
  values is *not* emitted. `libs/asm` has no C7 /0 decoder, so
  `asm_x64_test`'s encode-identity pass over the self-host image would
  report unknown opcodes, and teaching the decoder, encoder, text
  parser and fuzz tables the form touches PR #579's files for 96
  instructions (288 bytes) in the x64 compiler image. Address slots
  (`be_addr_slot_emit`) never go through `mov_eax_int`, so every patched
  immediate keeps its fixed width.

Measurements (4-core cloud container, `objdump -d -Mintel`, instruction
count = lines with an opcode, which differs slightly from §1.1's
593,036 for the same binary; x64 image = `bin/wv3 --quiet x64 w.w`):

| | x86 `bin/wv3` before | after | x64 image before | after |
| --- | --- | --- | --- | --- |
| bytes | 2,801,048 | 2,698,648 (−3.7%) | 3,328,816 | 3,070,768 (−7.8%) |
| instructions | 600,316 | 586,420 (−2.3%) | 587,875 | 573,993 (−2.4%) |
| `add esp,0x0` | 13,851 | 0 | 13,864 | 0 |
| `lea eax,[esp+N]` disp32 / disp8 | 6,041 / 2 | 96 / 5,947 | 6,068 / 2 | 201 / 5,868 |
| `movabs rax,imm64` | — | — | 28,591 | 106 |
| `mov eax,imm32` | 69,287 | 69,291 | 40,733 | 69,213 |

The 106 surviving `movabs` are 96 negative constants (the C7 /0
candidates), 3 values past 32 bits and 7 objdump misreads of inline
data. Self-compile (`bin/wv3 --quiet w.w -o /tmp/x`, x86): callgrind Ir
7,329,806,622 → 7,294,272,227 (−35.5 M, −0.48%); wall time, seven
interleaved before/after pairs on an idle container, best 0.752 s →
0.743 s with both spreads overlapping (0.752–0.861 s vs 0.743–0.799 s),
i.e. within run-to-run noise. §1.1's
"small but nonzero" Ir prediction holds; the instruction-count and byte
predictions (−13.7k, ≈−90 KB on x86) were met or exceeded.

Gates: `verify`, `verify_x64`, `verify_arm64` (qemu-user-static),
`verify_wasm` (node), `local_load_fold_test` + `_64`, `asm_x64_test`,
`asm_fuzz_x86_test`, `asm_fuzz_x64_test`, `const_fold_test` + `_64`,
`manifest_check`, `parser_generator_w_test`, `tests`.

### P1 — counters, dump, merge (2026-10-07)

**What landed.** `--profile-generate` (compiler/compiler.w option block;
whole-program, applied in link_impl's flag pre-scan; x86 and x64 Linux
ELF only — every other target is rejected with an error).
`code_generator/profile_counters.w` (new) emits one 8-byte counter per
function and per while/for loop head: `inc QWORD PTR [abs32]` on x64,
`add DWORD PTR [abs32],1 ; adc DWORD PTR [abs32+4],0` on x86, after the
prologue and right after `be_ctrl_loop`, so no register is touched and
no site sits between a compare and its branch. The hooks are one-line
calls after `be_function_prologue` (grammar/program.w's
function_definition and script_main, code_generator/function_ast.w) and
after `be_ctrl_loop` (grammar/while_statement.w, grammar/for_statement.w
x2, code_generator/loop_ast.w x3); generator bodies get a counter-less
record so their loops are attributed to them (grammar/generator_decl.w,
function_ast.w). The streaming grammar and `--ast-emit-retained` produce
byte-identical instrumented binaries and maps (asserted by
`verify_profile_generate`). Counters are laid out as one contiguous
table at finish, so indices are emission order and the output is a pure
function of sources and flags (§3.5). A loop counter counts head
evaluations (iterations + 1 per entry that leaves through the
condition).

`lib/profile.w` (new, auto-imported only in this mode, compiled with the
counters off) flushes to `$W_PROFILE_OUT` with O_APPEND, one `index
count` line per nonzero counter per write(2), from a snapshot of the
table; the compiler redirects lib's `exit()` to `__w_profile_exit` by
writing a `jmp rel32` over its first five bytes, so `_main`'s
`exit(main(...))` and direct `exit()` calls both flush (`_exit`/crash do
not). The sidecar `<output>.wprofmap` is tab-separated: index, kind f/l,
defhash of the enclosing definition (the exact `w defhash` sha256:
profile_defhash_find/_hex_at in compiler.w look the definition up by
declaration file and line among the entries defhash_note recorded, which
the flag arms over the whole closure), name (whitespace stripped), file,
line, loop ordinal. `--profile-generate` requires `-o`.

`tools/wprof.w` (new, `bin/wprof`, built x64 so sums are 64-bit): `merge`
(maps + raw dumps + existing .wprof files → sorted §3.3 text, counts
summed per (defhash, kind, ordinal), nonzero entries only unless
`--zeros`), `stats` (share of a profile's functions/entries whose hash
is still produced by `w defhash --closure` of the given files), `top`,
`clear` (truncate dumps before a run) and `corpus` (compile+run every
`<dir>/*.w`, merging the dumps; a missing directory yields a header-only
profile so `profile_refresh` works before B1's tests/bench/ exists).
`./wbuild profile_refresh` (owned by tools/wprof.w's directive block;
`build.base.json` only gained its `no_umbrella` line) regenerates
`profiles/self.wprof` (x86), `profiles/self_x64.wprof` and
`profiles/bench.wprof` (empty until B1). `tests/profile_generate_test.w`
compiles a fixture for both targets, runs it through the return and the
exit() paths, merges, asserts exact counts, the defhash key and
cross-target summation; its `verify_profile_generate` block is the
flag-on fixpoint (prof_wv3 == prof_wv4 and their maps, streaming ==
retained, x86 and x64).

**Measurements** (4-core cloud container, `w.w` self-compile, matched
input; callgrind Ir varies ±1.5% between runs of the same binary here
even with ASLR off, so ranges of three runs are given):

| compiler | wall (7 runs, median) | callgrind Ir (3 runs) |
| --- | --- | --- |
| main `bin/wv3`, x86, flag off | 0.76–0.84 s (0.815) | 7.32–7.46 G |
| this branch `bin/wv3`, x86, flag off | 0.76–0.83 s (0.787) | 7.29–7.52 G |
| `bin/prof_wv3`, x86, flag on | 0.83–0.92 s (0.861) | 7.66 G (one clean run) |
| this branch `bin/wv3_64`, x64, flag off | 0.76–0.84 s (0.822) | 7.52–7.62 G |
| `bin/prof_wv3_64`, x64, flag on | 0.78–0.92 s (0.848) | 7.76–7.95 G |

Flag off is unchanged within noise (the hooks are a flag test per
function and loop head, ~6.5k per compile; the flag-off compiler's
output for sha256_test.w, x86, x64 and `--ast-emit-retained`, is
byte-identical to main's). Flag on costs 151 M (x86) / 158 M (x64)
counter hits per self-compile — the expected +4% / +2% of Ir — and
+5–9% wall time on x86, +3% on x64. Image sizes: x86 2,817,496 →
2,931,808 bytes (+4.1%), x64 3,349,424 → 3,435,112 (+2.6%). The x86 map
has 5,072 counters (3,682 functions, 1,389 loops, plus the one script
main); `profiles/self.wprof` is 1,155 lines / 143 KB (924 functions and
230 loops ran), `self_x64.wprof` 1,194 lines / 147 KB.

Top 20 of `profiles/self.wprof` (`bin/wprof top profiles/self.wprof`),
functions by entries: `__w_list_addr` 13.6 M, `type_real` 8.9 M, `peek`
6.1 M, `type_record` 5.7 M, `accept` 3.8 M, `type_get_alias_target`
3.5 M, `type_canonical` 3.5 M, `get_character` 2.8 M, `getc` 2.8 M,
`load_int` 2.3 M, `takechar` 1.6 M, `resize_code` 1.5 M,
`__w_hash_key_equal` 1.5 M, `__w_strcmp` 1.5 M, `type_get_const_target`
1.4 M, `type_unqualified` 1.4 M, `sym_index_offset` 1.1 M,
`type_get_kind` 0.9 M, `save_int` 0.8 M, `__w_strlen` 0.8 M. Loops by
head evaluations: `__w_strlen` 8.9 M, `type_lookup_pointer` 5.6 M,
`__w_strcmp` 4.4 M, `type_canonical` 3.5 M, `__w_hash_sip` loop 1 3.4 M
and loop 3 3.3 M, `sha256_block_w` loop 3 2.9 M, `emit` 2.6 M,
`sha256_block_w` loop 2 2.2 M, `__w_hash_table_slot` 1.9 M,
`freelist_realloc` 1.8 M, `__w_hash_sip` loop 2 1.8 M, `take_ident_run`
1.7 M, `type_unqualified` 1.4 M, `get_token` loop 1 0.84 M, `sha256_block_w`
loop 1 0.75 M, `get_token` loop 2 0.75 M, `get_token` loop 11 0.66 M,
`peek` 0.61 M, `sym_index_sync` 0.50 M. This differs from §1.2's
callgrind picture in one way worth noting for P2/P3: by *entry count*
the hottest code is the small accessor layer (`__w_list_addr`,
`type_real`, `type_record`, the tokenizer's `peek`/`accept`), i.e. P3's
inlining candidates, while `sha256_block_w` and `__w_hash_sip` dominate
by *loop iterations* as §1.2 predicted.

**Not claimed / gaps.** arm64, darwin, win64 and wasm are rejected, not
instrumented (arm64 needs `ldr/add/str` through a scratch register).
`_exit`, signals and `thread_exit` do not flush. Profile counts are not
bit-reproducible across refreshes: the hash-table probe loops'
counts (`__w_strcmp`, `__w_hash_key_equal`) depend on addresses, so two
consecutive `profile_refresh` runs differed in 4 of 1,155 lines of
`self.wprof` (and the Ir of a compile varies ±1.5%, see above); a PR
commits the refreshed files only when hot code changed, as §3.3 says.
`bench.wprof` is header-only until B1 lands `tests/bench/`; `wprof
corpus` runs each program with no arguments, which B1 may need to
extend. Functions the defhash scan does not record (a script's implicit
`main`, generator bodies) carry a zero hash and will never match a
`--profile-use` lookup. The `defhash_note` capacity was raised from
8,000 to 20,000 definitions because the flag records the whole closure.
