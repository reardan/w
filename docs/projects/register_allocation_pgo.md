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
  function entry and per loop head (the body's first instruction: since
  unit A7 of codegen_gap_plan.md rotated the loops, the count is the
  loop's iterations, not its condition evaluations), the runtime writes
  the counters at exit, `bin/wprof` merges runs into a text profile keyed by each
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

### B1 — benchmark corpus and harness (2026-10-07)

**Landed.** `tests/bench/`: eight programs (`sum`, `sieve`, `sha256_1m`,
`siphash_keys`, `inflate_corpus`, `regex_backtrack`, `matmul_256`,
`strcmp_sort`) plus the `self` row, each deterministic, size-argument
driven, printing one `<name> size=<n> checksum=<hex>` line that is
identical on x86 and x64 (masked-32-bit arithmetic as in `lib/sha256.w`,
`tests/bench/bench_lib.w`); a C twin for each in `tests/bench/c/` that
ports the W library code it exercises (sha256, HalfSipHash + the
runtime's table, inflate, regex, the runtime's merge sort) and prints
the same line. Targets: `bench_<name>` (tag `bench`: full size, both
widths, checksum asserted), `bench_<name>_smoke_test` (tag `tests`:
tiny size, both widths), `bench` (umbrella → `bench_report`, writes
`bin/bench.txt`), `bench_compare` (against `tests/bench/baseline.txt`).
`bin/wbench --programs` (`tools/wbench.w`): per `<name>.<arch>` row the
executable bytes, callgrind `kIr` (once per row, when valgrind is on
PATH) with the three hottest functions resolved through `nm -n`, best
wall time of `-n` runs; `--compiler`/`--compiler64` pick the compilers,
`--size`, `--no-valgrind`, `--prefix`; the compare rules are wbench's
(bytes and kIr gate within tolerance, kIr skipped — not failed — when
either side lacks it, wall time reported). `tools/bench_vs_c.sh`
builds the corpus with W (x86, x64) and gcc/clang `-O2` (and `-m32`
when multilib exists), checks the lines agree and prints markdown
tables. `wbench_compare_test` gained the programs-mode fixtures
(`tests/bench/fixtures/`). `docs/testing.md` "The benchmark corpus".
The optional CI bench job is a patch at
`/mnt/project-files/regalloc-pgo/ci-bench.patch` (not committed).
`build.base.json` got the step-less `bench` umbrella and a
`no_umbrella` entry for `bench_compare` — the minimal edit the tag
mechanism needs; P2 owns the rest of that file.

**Baseline (this unmodified compiler, 4-core Xeon 2.1 GHz cloud
container, best of 3, `./wbuild bench` and `tools/bench_vs_c.sh`; the
Ir columns are callgrind instruction counts, deterministic per binary
except for the random map seed in `siphash_keys`/`self`):**

| program | W x86 ms | W x64 ms | gcc -O2 ms | clang -O2 ms | W x86 Ir | W x64 Ir | gcc Ir | clang Ir |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| sum | 759 | 751 | 205 | 3 | 13.80 G | 13.80 G | 1.20 G | 0.24 M |
| sieve | 444 | 434 | 225 | 228 | 4.07 G | 4.07 G | 0.59 G | 0.80 G |
| sha256_1m | 492 | 496 | 116 | 119 | 7.70 G | 7.70 G | 1.29 G | 1.31 G |
| siphash_keys | 710 | 987 | 298 | 311 | 6.15 G | 6.91 G | 1.18 G | 1.15 G |
| inflate_corpus | 510 | 505 | 71 | 69 | 6.78 G | 6.72 G | 0.99 G | 0.84 G |
| regex_backtrack | 624 | 592 | 220 | 170 | 10.19 G | 10.19 G | 2.54 G | 2.42 G |
| matmul_256 | 518 | 526 | 171 | 196 | 8.77 G | 8.77 G | 1.18 G | 0.68 G |
| strcmp_sort | 473 | 524 | 187 | 187 | 4.60 G | 4.72 G | 0.57 G | 0.59 G |
| self (compiling w.w) | 908 | 805 | — | — | 7.34 G | 7.57 G | — | — |

Hottest functions per row (from `bin/bench.txt`): `sum_to` 100%;
`sieve` 98%; `sha256_block_w` 76% (`bench_rand` 14% is the data fill);
`__w_hash_sip` 39%, `__w_hash_table_rehash` 8–12%; `wh_decode` 22%,
`inf_get_bit` 18%, `__w_size_add` 12%; `rx_here` 37%; `matmul` 99.8%;
`__w_list_compare_values` 23%, `__w_list_merge_sort` 20%; self:
`sha256_block_w` 13–15%, `__w_hash_sip` 11–12%, `strcmp` 9%.

**What the numbers say.** W emits 6–11x the instructions of gcc -O2 on
the loop-bound programs and runs 2.4–7x slower in wall time (the gap
in cycles is smaller than in instructions because W's memory-operand
instructions overlap in the pipeline). `sum` is the §1.1/§1.3 loop verbatim: 23
instructions per iteration (13.8 G / 600 M; `objdump` of
`bin/wbench_prog_sum_x86` shows the §1.1 shape with 23 instructions —
§1.1's listing undercounts the `mov ebx,eax` shuttles by three) — the
per-iteration count is the one R1/R2 move; gcc is 2 instructions per
iteration and clang folds the loop to a closed form, so that row's C
columns are an optimiser ceiling, not a loop. The x64
rows are not faster than x86 today (`siphash_keys` and `strcmp_sort`
are slower: 8-byte words through the same accumulator model), which
is the state R2 starts from. `self` x64 is faster in wall time than
x86 (805 vs 908 ms) with 3% more instructions. Everything else §1
predicted holds: `sha256_block_w` and `__w_hash_sip` are 25% of the
self-compile's instructions.

**Not claimed:** no compiler change; the baseline's wall times are
this container's and only the bytes/kIr columns gate. The `self.x64`
row needs `bin/wv2_64` (`build_x64`, which `bench`/`bench_compare`
depend on) and is skipped otherwise. Two tooling notes went to
`ai_tooling_next_steps.md` (valgrind does not read W's `.symtab`, so
`wbench` resolves addresses with `nm`; 32-bit `wbench` records Ir in
thousands).

### P2 — profile-driven decisions and the PGO bootstrap chain, phase A (2026-10-07)

**What landed.** `--profile-use=<path>` (compiler/compiler.w option
block; whole-program like `--profile-generate`, applied in link_impl's
pre-scan so the runtime closure sees it; explicit only, §3.5 rule 1).
`compiler/profile_use.w` (new) parses the §3.3 text format, indexes `f`
and `l` entries by defhash, and answers the optimizer's questions for
the function whose body is being compiled: `profile_function_class()`
(0 unknown / 1 cold / 2 hot, with `profile_function_is_hot/_is_cold`),
`profile_function_entries()`, `profile_loop_iters(ordinal)` and
`profile_loop_hot(ordinal)`; R2/R3 wire these in phase B. hot = entries
≥ 10,000 or any loop with ≥ 16 head evaluations per entry (≥ 256 in
all); cold = matched and not hot, or absent from a profile that has
entries for the function's file; unknown = no profile, file not
covered, or hash mismatch (the static heuristic applies). Counts
saturate at 2^30 on every host and ratios divide, so an x86-hosted and
an x64-hosted compiler decide identically (the x64 leg of `verify_pgo`
proves it).

*Identifying the function at the start of its body.* defhash's span end
is not known until the body has been parsed, so `profile_use_function_begin`
(called from P1's `profile_function_enter`/`profile_generator_enter` hooks,
which already sit after the prologue on the streaming and the retained
path) computes the hash by a bounded look-ahead over the source: it saves
the lexer with `tokenizer_snapshot`, reopens the file on its own fd,
seeks to the definition's first token (the recognizer in
grammar/program.w and `generic_instantiate_function` in grammar/generic.w
store that offset in `profile_use_definition_start`, the same start
`defhash_note` records later), runs `get_token()` under
`defhash_rehash_mode`, feeds the same `<kind><len>:<text>` stream as
`defhash_process_span` into sha256 and stops at the first token that
opens a line at tab level 0 — the body's end for any definition that
parses (a tab-0 continuation line inside a body ends the scan early,
which mismatches and yields "unknown", never a wrong class). The
look-ahead is paid only for functions whose name the profile knows
(`profile_use_names` is the prefilter; a generic instantiation's mangled
name is cut at `$`): 926 of 3,787 functions in the self-compile, which
re-lexes roughly a quarter of the source once more. Measured cost of the
flag on the self-compile (best of 5, 4-core cloud container): x86
813 → 927 ms (+14%), x64 815 → 879 ms (+8%) — paid by the PGO chain's
builds, not by the compiler they produce. Phase B can fold the hash into
R2's scan, which tokenizes the same span anyway.

*Hot loop alignment.* `profile_use_loop_align()` is one tagged call before
each `be_ctrl_loop` (grammar/while_statement.w, grammar/for_statement.w
×2, code_generator/loop_ast.w ×3); it counts the loop ordinal exactly as
profile_counters.w numbers the `l` entries and, when the profile marks
the loop hot on x86/x64, pads with `0x90` to the next 16-byte boundary
before the head label is placed. Every branch is rel32 and every
peephole note compares its end to `codepos`, so nothing folds across the
pad; the retained path emits the same bytes (asserted by `verify_pgo`).
`--stats` prints a `Profile use:` summary and one line per aligned head
(file offset, pad, function, ordinal), which `tests/profile_use_test.w`
reads back to check the pad bytes and the alignment in the image.

*Targets.* `build.base.json`: `build_pgo` (inputs: the two self profiles,
plus the deps-driven `w.w` closure) builds `wv3_pgo → wv4_pgo → wv5_pgo`
with `--profile-use=profiles/self.wprof`, `wv3_pgo_ast` with
`--ast-emit-retained`, and `wv3_pgo_64 → wv4_pgo_64` with
`profiles/self_x64.wprof` from the x86 host; `verify_pgo` (in `tests`,
six self-compiles ≈ 7 s) asserts `wv3_pgo == wv4_pgo == wv5_pgo ==
wv3_pgo_ast` and `wv3_pgo_64 == wv4_pgo_64`. The plain `verify` chain is
unchanged. `profile_check` (in `tests`, FORCE, never fails) runs
`bin/wprof stats` for the three committed profiles (`stats` gained
`--arch` so the x64 profile is checked against the x64 closure).
`profiles/self.wprof`, `self_x64.wprof` and `bench.wprof` were
regenerated by `./wbuild profile_refresh` against this tree
(`bench.wprof` is populated now that B1's corpus exists: 271 lines, 170
functions; `profile_check` reports 100% for all three). CLAUDE.md,
README.md and docs/testing.md mention the three targets.

**Measurements** (4-core cloud container, `w.w` self-compile, matched
input; with only loop alignment driven by the profile the expected
difference is ≈ 0, and that is what was measured):

| binary | callgrind Ir (3 runs, x86; 1 run, x64) | wall, best of 5, two rounds |
| --- | --- | --- |
| `bin/wv3` (x86, plain) | 7.31–7.42 G | 844 / 799 ms |
| `bin/wv3_pgo` (x86, `--profile-use=profiles/self.wprof`) | 7.29–7.35 G | 823 / 816 ms |
| `bin/wv3_64` (x64, plain) | 7.43 G | 795 / 802 ms |
| `bin/wv3_pgo_64` (x64, `self_x64.wprof`) | 7.44 G | 851 / 812 ms |

The PGO x86 compiler differs from the plain one in 333 pad bytes at 39
loop heads (x64: 334 bytes, 44 heads; 339 / 345 functions classified
hot, 1,828 cold, 0 stale); the image size is unchanged because the pad
lands inside the page the code occupies before the data segment. Bench
programs built with `profiles/bench.wprof`, x86: `sha256_1m` Ir
7.6847 → 7.6926 G (+0.1%, the sleds executed per `sha256_block_w`
entry), wall 469 → 476 ms / 465 → 469 ms; `sum` Ir 13,200,429,963 →
13,200,431,633 (+1.7 k), wall 750 → 751 ms / 757 → 761 ms. All inside
this container's ±3% run-to-run noise; the alignment pad is a
correctness-neutral no-op here until R2/R3 shorten the loop bodies
enough for fetch alignment to matter, which is the only honest reading
of these numbers.

**Not claimed / gaps.** Phase B (hot functions get R2's scan and
promotion, cold ones skip it, loop weights from `profile_loop_iters`)
waits for R2 to merge. "cold" for a function absent from a covered file
is a heuristic: a function added after the profile was taken reads as
cold until `profile_refresh` (performance only — the static heuristic
is skipped, nothing is mis-emitted). Generic instantiations share the
template's hash (P1's map keys them so too), so their counts are summed
across instantiations. A script's implicit `main` and generator bodies
carry no defhash (P1) and are never matched. The bench profile merges
every program, so the runtime's list-sort and rehash loops count as hot
in all of them (harmless: a 16-byte pad each). arm64/wasm/darwin/win64
accept the flag (classes are computed) but no alignment is emitted
there. The look-ahead reopens the source file once per candidate
function (926 opens in a self-compile); under `--ast-emit-retained` it
still reads the file, not the retained copy, which is correct because
`retained_source_byte` verifies and records the same bytes in order.

### R2 — function-scoped register promotion, x86/x64 (2026-10-07)

Landed as three commits on top of R1 and P1/B1: the promotion itself
(`compiler/regalloc_scan.w`, new; `code_generator/{x86,code_emitter,
arm64,dwarf,dwarf_info,x86_asm,x64_asm,expression_ast,statement_ast}.w`;
`compiler/{symbol_table,compiler,analysis}.w`; `grammar/{program,
expression,unary_expression,variable_declaration,multi_assign,
stack_slot}.w`; `repl/core.w`; `debugger/locals.w`; `lib/{lib,setjmp,
stack_trace}.w`), R2b (`grammar/for_statement.w`,
`code_generator/loop_ast.w`), and the tests (`tests/regalloc_test.w`,
`tests/regalloc_diff_test.w`, `dwarf_variables_test`, `repl_test`
steps). Promotion is **on by default**; `--no-regs` (alias `-O0`)
turns it off and `--regs` turns it back on, both whole-program.

What landed, against §2.2:

- **The scan** is a byte-level pre-scan of the function body run from
  `function_definition` before the prologue, reading the source fd
  through `getchar`'s own buffer and seeking back; it never touches the
  tokenizer, so no token, line, warning or retained-AST state moves. It
  agrees with the tokenizer on comments and literals and is
  conservative everywhere else: a candidate is a name with exactly one
  recognised declaration that is never address-taken, subscripted,
  called, field-accessed or compound-assigned (`+=`, `++`); uses are
  weighted 8^depth by `while`/`for` nesting; only names used inside a
  loop rank, so a loop-free body is never scanned past its first pass.
  A body naming `raw_asm`, `setjmp`/`longjmp`, `yield`, `gpu`/`launch`/
  `kernel`, or containing an f-string (which re-enters the tokenizer)
  promotes nothing; so do variadic functions and generator bodies.
  `goto`/labels and `defer` are allowed as planned.
- **Deviation: no kind `'R'`.** Symbol records keep kind `'L'` and gain
  a register field (offset 146, `symbol_data_size` 150 — appended,
  nothing repurposed). `sym_emit_value` sets a *register lvalue note*
  (`reg_lvalue`/`reg_lvalue_end`, the same `*_end == codepos`
  discipline as the lea/imm notes) instead of emitting an address;
  `promote()` consumes it as `mov eax,R`, plain `=` and declarations
  with initializers as `mov R,eax`, multi-assignment (both the
  streaming and the retained-AST emitter) as a parked register. `&x`
  on a promoted local and any consumer that reaches `emit()` with the
  note still current are compile-time internal errors ("used by an
  unhandled path (compile with --no-regs and report this)"), and
  `load_slot` asserts that a promoted local's never-written stack word
  is not read (`regalloc_slot_assert`, keyed by name because scope
  exits truncate the table and offsets alias). The guard fired exactly
  once during development on a path the plan had not listed — the
  retained-AST parallel assignment, found by `ast_canary_64_test` — and
  that emitter was made register-aware.
- **Prologue/epilogue** as planned: `push R` for each promoted register
  right after `mov ebp,esp` (so P1's function counter follows them),
  `be_frame_words` = 1 + saved, every `return` through
  `lea esp,[ebp-W*n]; pop ...; pop ebp; ret`. `.debug_frame` carries
  `DW_CFA_offset r, 3+i` after the frame setup and `DW_CFA_restore` at
  the leave; promoted locals get `DW_OP_reg<n>` locations; wdbg reads
  them from the stop's sigcontext (frame 0) or the inner frame's save
  slot (`p i`, conditions and logpoints on `debug_fixture3.w`, whose
  `i` and `sum` are promoted, pass unchanged; attach mode has no
  register context and reports the local as unavailable).
- **Stubs**: x86 `syscall7` and `stack_create` now save `esi`/`edi`
  (the audit found nothing else on x86 or x64 touching the set);
  `repl_setjmp`/`repl_longjmp` save and restore `ebx esi edi` /
  `rbx r12–r15`, `jmp_buf` grew to 8 words (`jmp_buf_words`,
  `lib/lib.w`), and `lib/setjmp.w`, README state the contract: asm
  bodies and stubs preserve `ebx/esi/edi`, `rbx/r12–r15`, `x19–x28`.
- **R2b**: `for` headers are declarations to the scan, so a range or
  container loop variable ranks like any local; the loop's start copy,
  condition, increment (`add R,1` / `add R,eax`) and container stores
  go through the register, and the stack paths assert the slot. The
  hidden end/step slots stay on the stack: the condition's end-slot
  read folds into `pop_ebx`'s shuttle (`mov_eax_esp_plus` is now noted
  like a local load), so `for i in range(n): s = s + i` is an 11-
  instruction loop with one memory read.
- **`mov eax,R` is noted too** (`regload_note`), so a register operand
  on the right of a binary operator takes the shuttle
  (`mov ebx,eax; mov eax,R`) instead of a `push`/`pop` pair.
- **Budget and heuristic**: top-4 on x64 (`r12`–`r15`), top-2 on x86
  (`esi`/`edi`), use count > 7 required, no profile input yet (§3.4's
  hook is the ranking function). arm64, darwin, win64 and wasm promote
  nothing and emit byte-identical output (`verify_arm64` passes).

Measurements (4-core cloud container; "before" is the integration
branch at cd88aba7 built by the pinned seed, "after" this branch built
the same way; best-of-5 wall, callgrind Ir):

| workload (`bin/wbench --programs -n 5`, kIr = callgrind, best wall) | before kIr | after kIr | before ms | after ms |
| --- | --- | --- | --- | --- |
| siphash_keys x86 / x64 | 6,064,249 / 6,801,967 | 5,954,186 (−1.8%) / 6,488,888 (−4.6%) | 725 / 1124 | 734 / 1058 |
| inflate_corpus x86 / x64 | 6,734,003 / 6,679,124 | 6,480,057 (−3.8%) / 6,351,846 (−4.9%) | 513 / 542 | 492 / 496 |
| regex_backtrack x86 / x64 | 10,052,926 / 10,052,926 | 9,692,806 (−3.6%) / 9,791,912 (−2.6%) | 649 / 629 | 568 / 601 |
| matmul_256 x86 / x64 | 8,603,595 / 8,603,595 | 7,597,846 (−11.7%) / 7,595,874 (−11.7%) | 540 / 517 | 465 / 442 |
| strcmp_sort x86 / x64 | 4,550,180 / 4,665,301 | 4,497,147 (−1.2%) / 4,576,365 (−1.9%) | 510 / 607 | 481 / 586 |

| micro-benchmark (best-of-5 wall, callgrind Ir) | before | after |
| --- | --- | --- |
| §1.1 `sum_to` while loop, 10^9 iterations, x86 | 1.215 s, 22.000 G | 0.878 s, 16.000 G (−27%) |
| same, x64 | 1.225 s, 22.000 G | 0.872 s, 16.000 G |
| `for i in range(10^9): s = s + i` (R2b), x86 | 1.075 s, 16.000 G | 0.708 s, 12.000 G (−25%) |
| same, x64 | 1.028 s, 16.000 G | 0.682 s, 12.000 G |
| sha256 over a few MB (`lib/sha256.w`), x86 / x64 | 0.185 s, 3.067 G / 0.192 s, 3.067 G | 0.184 s, 2.979 G (−2.8%) / 0.179 s, 2.955 G (−3.6%) |
| map insert loop (`map[int,int]`, 10^6 keys), x86 / x64 | 1.013 s, 5.219 G / 1.522 s, 6.412 G | 1.091 s, 5.163 G (−1.1%) / 1.501 s, 6.082 G (−5.1%) |

| self-compile of `w.w` (best-of-5 wall, callgrind Ir) | before (base tree, seed-built) | after: promoted fixpoint compiler (`bin/wv3`) | after with `--no-regs` (same binary, scan off) |
| --- | --- | --- | --- |
| x86 | 0.915 s, 7.431 G | 0.980 s, 8.050 G | 0.837 s, 7.425 G |
| x64 | 0.831 s, 7.604 G | 0.844 s, 8.076 G | 0.812 s, 7.723 G |

The seed-built `bin/wv2` (unpromoted code, but it runs the scan) is
the slowest point of the chain on x86: 1.082 s, 8.303 G. Callgrind Ir
of the compiler moves by up to ~3% between runs of the same binary on
the same input (`structures/hash_table.w` draws a per-process siphash
seed, so collision patterns differ), so Ir deltas under that are
noise; the wall figures are best-of-5 on an otherwise idle box.

The while-loop benchmark goes from 22 to 16 instructions per iteration
(the accumulator model still spends `mov eax,R; mov ebx,eax` on each
register operand, §1.3's 5-instruction loop needs R3/peepholes), the
range loop from 16 to 12. `w.w` on x86 promotes 1,491 locals in 1,001
scanned loop bodies (2,147 on x64 with four registers); the x86 image
is 2,786,408 → 2,782,312 bytes (607,253 → 613,180 instructions, the
pushes/pops and `mov R,eax` stores outnumber the removed `[esp+N]`
operands), the x64 image 3,168,464 → 3,184,848 bytes (594,688 →
603,755 instructions).

Compile-time cost of the pre-scan (one binary, `w.w`, callgrind, scan on
vs `--no-regs`): `bin/wv3` runs 8,049,655,177 vs 7,424,880,971 Ir, +625
M (+8.4%); `bin/wv3_64` on the x64 build 8,075,569,244 vs 7,722,777,155
(+4.6%); the unpromoted seed-built `bin/wv2` pays +823 M (+11%), the
scanner's own loops being exactly what promotion helps. The promoted
compiler compiling `w.w` runs about 7% slower on x86 wall than the base
compiler (0.915 → 0.980 s) and 1.6% slower on x64 (0.831 → 0.844 s): the
scan costs more than promotion wins back on the compiler's own loops
(the promoted binary with the scan off compiles `w.w` in 0.837 s on x86,
9% faster than base). Skipping the scan for cold functions once a
profile says which bodies matter (P2 phase B) and a cheaper scan are
where the compile-time budget goes next.

Gates: `verify`, `verify_x64`, `verify_arm64`, `tests` (916
targets, 604 s), `regalloc_test` + `_64`, `regalloc_diff_test` (408
programs compared on their own width, 0 mismatches; race/timing tests
reported nondeterministic and skipped), `dwarf_variables_test`,
`repl_test`, `debug_test`, `wdbg_web_test`, `ast_expression_test`,
`ast_retained_emit_test`, `ast_canary_test` + `_64`, the `asm_*`
suites, `bench_*_smoke_test`.

Not claimed / for the next unit:
- Hidden range slots, `ebx`, floats, narrow integers and aggregates
  stay on the stack; R3's loop-scoped caller-saved allocation and the
  profile-driven ranking (§3.4) are untouched — `rs_assign_registers`
  is where a profile's counts replace the static weights.
- A `longjmp` caller promotes nothing (only the `setjmp` caller needs
  to); relaxing that is safe but was not needed.
- `regalloc_diff_test` skips sources that spawn processes, write files
  or import the compiler (they would race their own manifest run) and
  blanks hex addresses (`lib/testing.w` prints function addresses).
- The accumulator model still materialises `mov eax,R; mov ebx,eax`
  for a register operand; a direct `op eax,R` form is the obvious next
  peephole.

### P2 — phase B: the profile decides the register scan (2026-10-07)

**What landed.** With R2 merged, `--profile-use` now drives the
register pre-scan (`compiler/regalloc_scan.w`) through one new file,
`compiler/regalloc_profile.w`, imported by the scanner right after its
byte source (`rs_next`/`rs_c`):

- *The decision.* `regalloc_function_scan` asks `rs_profile_begin`
  for the function's class before the heuristic runs. A **cold**
  function skips the scan entirely (no probe, no full pass, nothing
  promoted); a **hot** one goes straight to the full pass without the
  loop probe; an **unknown** one (no profile, file not covered, hash
  mismatch) keeps R2's heuristic unchanged. The class is computed even
  where nothing else runs (`--no-regs`, other targets, variadic
  bodies) because the loop alignment of phase A reads it.
- *The weights.* In a matched function `rs_weight()` returns, for a
  use inside a loop, that loop's head evaluations per entry from the
  profile (`profile_loop_iters(ordinal) / entries`, clamped to
  [1, 2^20], 1 for a loop that never ran) instead of 8^depth; the
  loop's ordinal is the n-th `while`/`for` keyword at a line start,
  which is how P1 numbered the `l` entries. Outside loops the weight
  stays 1, so the "> 7 uses" threshold now means "> 7 dynamic uses
  per entry" for a matched function.
- *The hash.* The function is identified by its defhash before its
  body is parsed, and the hash is computed from the scanner's byte
  source instead of phase A's tokenizer look-ahead: `rs_hash_span` is
  a `get_token`-compatible byte lexer (identifier runs with UTF-8
  sequences, `s"`/`c"`/`f"` and plain literals with escapes, numbers
  with fraction and exponent, the `<=>|&!` runs, `+ - * % ^` with `=`
  or doubling, `:=`, both comment forms, single characters) over the
  same window R2 reads, feeding `profile_use.w`'s `<kind><len>:<text>`
  framing (spelled inline, no allocation per token) into sha256. Its
  end rule is defhash's (the first token opening a line at tab level
  0 after the first token). Anything the real tokenizer would reject
  aborts and leaves the function unknown. The result is bit-exact: a
  freshly generated profile matches every hashed function (`stale 0`
  on 982 x86 / 1,020 x64 hashes in the self-compile; `profile_check`
  reports 100% for the three committed profiles). The hash is only
  computed for names the profile knows (`profile_use_names`); a
  function whose name is absent from a profile covering its file is
  cold without a hash.
- *Edits to R2's file* are confined to tagged `# P2` lines: the
  import after `rs_next`, the first line of `rs_weight`, one call per
  loop push in `rs_identifier`, and the function-level decision in
  `regalloc_function_scan` (an early return for cold, `rs_mode = 1`
  for hot, the pass-begin calls and the fruitless-pass counter).
- *`--stats`* prints `regalloc: full passes promoting nothing: N` and,
  with a profile, `regalloc: profile: cold bodies skipped: N hot
  bodies scanned: M`; `tests/profile_use_test.w` asserts them on its
  fixture (3 cold skipped, 1 hot scanned) and compares the
  stale-profile image with a `--no-regs` build (a stale, matched-by-
  name function is unknown and takes the heuristic; the fixture's
  other, cold functions skip it, so the image differs from the plain
  one by exactly R2's promotions).
- The three profiles were regenerated against this tree with
  `./wbuild profile_refresh` (every compiler function's hash changed
  with R2); `verify_pgo` and `profile_check` pass.

**Where the `--profile-use` compile time goes** (callgrind, one
compiler binary built from this tree, x86, `w.w`; the per-function
split uses B1's `nm -n` mapping):

| `bin/wv3` on `w.w` | Ir | vs default |
| --- | ---: | ---: |
| `--no-regs` (no scan) | 7.431 G | −575 M |
| default (static heuristic) | 8.006 G | — |
| `--profile-use=<fresh self profile>` | 8.338 G | +332 M (+4.1%) |

Phase A's look-ahead cost +8–14% of wall time; this phase's hash pass
costs +4.1% of instructions on the same binary, and 250 M of those
332 M are `sha256_block_w`: `lib/sha256.w` runs at ≈ 350 Ir/byte and
the 982 hashed spans frame to ≈ 0.7 MB. The lexer and framing
(`rs_hash_ident_run`, `rs_hash_token`, `profile_hash_token`,
`rs_hnext`, `rs_hash_put`: ≈ 90 M), the map lookups and name copies
(`__w_hash_sip`, `strcmp`, `strcpy`, `profile_use_load`: ≈ 80 M) are
the rest; skipping 1,878 cold bodies saves only ≈ 70 M because R2's
probe already stops at the first loop or hazard, so the bodies that
are cheap to skip were cheap to scan. An earlier cut of this phase
used `itoa`/`malloc` per token and `is_ident_part_byte` per byte and
cost +449 M; the inline framing and the ASCII fast path in the
identifier loop removed 117 M. What remains is the hash function:
sha256 is the profile's key (P1's `.wprofmap`, `w defhash`), so the
same bytes must be hashed by the same function, and a faster
`lib/sha256.w` (a word-at-a-time message schedule, or R3's loop
registers in its compression loop) is the only lever left — it would
also cut the ≈ 12% of every compile that the GNU build-id hash of the
image costs, which is the larger prize.

**Goal 3 — should the static heuristic be cheaper?** Measured on the
self-compile without a profile: of 1,006 full passes, 109 (10.8%)
promote nothing, so a pre-filter could cut at most a tenth of the
full-pass time, and the whole scan is 575 M Ir ≈ 7% of the compile;
the gain is bounded by < 1% and no pre-filter was added. (With the
profile, 352 of 836 full passes promote nothing: hot functions are
forced into the full pass and many have no local used > 7 times per
entry. That is the price of not probing, ≈ 20 M Ir, and it is what
makes the hot path's result exact.)

**Measurements** (4-core cloud container, `w.w` self-compile, same
input tree; callgrind Ir is one run, wall is best of 5 with the median
beside it; "base" is the main-branch compiler before R1/R2/P2 from the
scratchpad, built by the pinned seed):

| self-compile of `w.w` | callgrind Ir | wall, best of 5 (median), 4 rounds |
| --- | --- | --- |
| base main x86 (`scratchpad/base/wv_x86`) | 7.517 G | 802 (813) ms |
| `bin/wv3` x86, plain fixpoint | 8.00–8.05 G (4 runs) | 966 (1009), 908 (953), 939 (974), 941 (979) ms |
| `bin/wv3_pgo` x86, built with `self.wprof` | 7.82–8.07 G (4 runs: 7.834, 7.823, 7.972, 8.073) | 995 (1045), 911 (938), 936 (981), 970 (988) ms |
| base main x64 (`scratchpad/base/wv_x64`) | 7.801 G | 860 (875) ms |
| `bin/wv3_64` x64, plain fixpoint | 8.060 G | 862 (880), 813 (831), 835 (881), 824 (844) ms |
| `bin/wv3_pgo_64` x64, built with `self_x64.wprof` | 8.036 G | 897 (915), 793 (805), 797 (823), 820 (822) ms |

Reading: the PGO-built compiler is not measurably faster than the
plain fixpoint. Three of four x86 Ir runs are 0.5–2.7% below the plain
compiler's band and one is 0.5% above it; the wall figures of the two
interleave on every round (another agent's builds shared the box, so
the medians drift by up to 10% between rounds and only the best-of-5
within a round compares). The x86 PGO image is byte-for-byte the same
size (2,794,912) and the x64 one 4,096 bytes smaller (3,193,664 vs
3,197,760: 789 promoted locals instead of 1,496 on x86, 1,150 instead
of 2,156 on x64, so fewer push/pop pairs and `mov R,eax` stores). The
compiler's own hot code is the build-id sha256, the hash tables and
the tokenizer, whose loops R2 already promotes with or without a
profile; what the profile changes is that 1,879 cold functions are
left on the stack, and that is neutral for a program whose time is in
a few dozen functions. Against the base main compiler the fixpoint
compilers run 0.5 G (x86) / 0.26 G (x64) more instructions and
≈ 100–160 ms / ≈ 0 ms more wall: that is the cost of running R2's scan on
every compile (`--no-regs` on the same binary: 7.524 G, 730–781 ms on
x86), not of the promoted code, which runs the same instruction count
as the unpromoted base.

Decision counts in the x86 self-compile with the committed
`profiles/self.wprof`: functions seen 3,866, hot 365, cold 1,879, stale 0, hashes computed 982; 836 bodies scanned, 789 locals promoted, 352 full passes promoting nothing (static heuristic: 1,007 / 1,496 / 109); 47 loops aligned, 395 pad bytes. x64 with `self_x64.wprof`: functions seen 3,871, hot 373, cold 1,877, stale 0, hashes computed 1,020; 844 / 1,150 / 357 (static: 1,007 / 2,156 / 109); 52 loops aligned, 375 pad bytes.

The compile-time cost of the flag itself, on the fixpoint compilers
(the input to the `build_pgo` chain's builds, not to the compiler it
produces):

| `w.w`, same binary | callgrind Ir | syscalls (`strace -c`) | wall, best of 5, 4 rounds |
| --- | --- | --- | --- |
| `bin/wv3` x86, `--no-regs` | 7.524 G | 1,496 (691 read, 4 lseek) | 781, 756, 756, 730 ms |
| `bin/wv3` x86, default scan | 7.99–8.14 G (4 runs) | 10,126 (1,140 read, 8,185 lseek) | 978, 900, 943, 985 ms |
| `bin/wv3` x86, `--profile-use=profiles/self.wprof` | 8.32–8.47 G (4 runs; +0.19 to +0.48 G, mean +0.31 G = +3.8%) | 8,440 (1,103 read, 6,350 lseek) | 906, 941, 945, 955 ms |
| `bin/wv3_64` x64, `--no-regs` | 7.520 G | | 780 ms |
| `bin/wv3_64` x64, default scan | 8.242 G | | 819 ms |
| `bin/wv3_64` x64, `--profile-use=profiles/self_x64.wprof` | 8.367 G (+1.5%) | | 841 ms |

The flag's wall cost is inside the noise of the default scan on x86:
its extra instructions are the hash pass, and against them every cold
body skips the scan's `lseek` pair (each scanned body saves and
restores the fd position; hashed bodies pay one pair too), so the
compile makes 1,700 fewer system calls. R2's scan itself is the larger
item on both axes (+0.5 G and +8,600 system calls over `--no-regs`,
150–200 ms of wall); phase A's +8–14% is gone.

Bench corpus (`tests/bench/*.w`, built by `bin/wv2` with and without
`profiles/bench.wprof`; callgrind Ir and best-of-5 wall of the
produced programs):

| program | x86 Ir plain | x86 Ir pgo | x86 ms plain / pgo | x64 Ir plain | x64 Ir pgo | x64 ms plain / pgo |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| sum | 9.600 G | 9.600 G (+0.0%) | 488 / 531 | 9.600 G | 9.600 G (+0.0%) | 508 / 533 |
| sieve | 3.597 G | 3.597 G (+0.0%) | 395 / 401 | 3.590 G | 3.590 G (+0.0%) | 377 / 377 |
| sha256_1m | 7.485 G | 7.406 G (−1.1%) | 430 / 444 | 7.436 G | 7.361 G (−1.0%) | 462 / 463 |
| siphash_keys | 5.955 G | 5.682 G (−4.6%) | 664 / 663 | 6.492 G | 6.137 G (−5.5%) | 884 / 778 |
| inflate_corpus | 6.480 G | 6.478 G (−0.0%) | 480 / 478 | 6.352 G | 6.347 G (−0.1%) | 466 / 473 |
| regex_backtrack | 9.693 G | 9.695 G (+0.0%) | 545 / 551 | 9.792 G | 9.703 G (−0.9%) | 565 / 558 |
| matmul_256 | 7.598 G | 7.606 G (+0.1%) | 443 / 441 | 7.596 G | 7.602 G (+0.1%) | 456 / 431 |
| strcmp_sort | 4.497 G | 4.490 G (−0.2%) | 446 / 438 | 4.576 G | 4.562 G (−0.3%) | 490 / 477 |

Reading: the program's instruction count is exact (no hash-seed
noise in these programs), so the Ir column is the result. `sum` and
`sieve` are byte-identical in their loops (the one hot function
promotes the same locals either way). `siphash_keys` gains 4.6% / 5.5%
and `sha256_1m` 1%: with real iteration counts the rank inside the
hashing loops changes (siphash_keys x64: 134 locals promoted with the
profile against 227 without, 60 hot bodies, 221 cold ones skipped),
and the two registers on x86 / four on x64 go to the locals the loop
actually touches per iteration rather than to the ones with the most
textual uses at the deepest nesting. `regex_backtrack` x64 −0.9% is the
same effect in the matcher; the rest is within ±0.3%, and nothing got
slower by more than 0.1%. Wall columns are best of 5 on a shared box
and differ by up to 9% on identical instruction counts (`sum` x86), so
only the Ir column is read.

**Not claimed / gaps.** The weight function changes which locals a
hot function promotes, not how many registers it has (2 on x86, 4 on
x64) or what the promoted code looks like; R3's loop-scoped registers
and the peepholes are where the hot path's instructions go down. A
function whose profile entry is stale takes the static heuristic, so
a tree with many edits since `profile_refresh` drifts toward R2's
default rather than toward "no promotion" — the PGO chain's result is
then a mixture, which `profile_check` makes visible but does not fail.
Cold-by-absence (a function added after the profile) still skips the
scan (phase A's caveat). Generic instantiations share a hash and so a
class. The `l` ordinals assume a loop keyword at a line start; a
`while` after a `:` on the same line shifts the ordinals after it
(weights only). arm64, darwin, win64 and wasm compute classes and
promote nothing, as before.

### R3 — compound operators, operand folds, loop-scoped registers (2026-10-07)

Landed as two commits on top of R2 and P2 phase A (merged with phase B
before the final gates): the folds (`code_generator/x86.w`,
`grammar/{expression,increment}.w`, `code_generator/{expression_ast,
retained_emit}.w`) and the loop-scoped allocation
(`compiler/regalloc_scan.w`, `grammar/{while_statement,for_statement,
statement}.w`, `code_generator/{loop_ast,ffi}.w`, one hook in
`compiler/symbol_table.w`), with the cases in `tests/regalloc_test.w`
(`test_r3_shapes`, `test_r3_loops`; every expected value comes from a
gcc `-O0` oracle of the same functions, not from the compiler under
test). Both are **on by default** under R2's switch: `--no-regs` turns
the scan off, and with it the folds' register paths and the loop
registers.

What landed, against §2.3:

- **Compound assignment and `++`/`--` on a promoted local** emit
  `op R,imm` / `op R,eax` / `op R,[esp+d]` / `op R,R2` in place
  (`regalloc_reg_store` consumes a *binop note* that `alu_*` leave
  behind, the same `*_end == codepos` discipline as the other notes;
  `imul` keeps its `69 /r` form so `asm_x64_test`'s encode identity
  stays byte-exact). The scan counts these as two uses instead of
  excluding the name. `x = x + y`-shaped plain assignments fold the
  same way when the left operand of the binary operator is the stored
  register (and `x = y + x` for the commutative operators), and the
  value stays in `eax` only when the assignment is not at statement
  position (`stmt_context`, `ast_statement_root1` for the retained
  walk) — so `s = s + i` is one instruction.
- **Register-operand fusion**: `pop_ebx`'s shuttle now also folds a
  pushed left operand that came straight from a register
  (`push_left_reg`): `mov eax,R1; push; mov eax,R2; pop ebx; add eax,ebx`
  becomes `mov eax,R1; add eax,R2`, the comparison forms become
  `cmp R1,R2` / `cmp R,imm` / `cmp R,[esp+d]` feeding the existing
  branch fusion, and `mov eax,R; mov ebx,eax` folds to `mov ebx,R`.
  64-bit constants outside the int32 range and non-word loads decline
  the fold.
- **Loop-scoped caller-saved registers (x64 only)**: the scan's full
  pass records each loop keyword's file offset, the uses gained inside
  it (ranked, ten candidates per loop) and the hazards its body
  contains (any call, including the hidden ones: `in` over a
  container, `new`, method and field calls, subscripted containers;
  `/`, `%`, shifts are recorded but harmless on x64 since `rcx`/`rdx`
  are not in the set). `loop_enter()` (both the streaming grammar and
  the retained walk go through it) looks the loop up by that offset
  and, in a call-free loop of a function without `goto`/labels or
  `defer`, loads the candidates that are live locals or arguments
  (`sym_probe`, one declaration, `regalloc_type_ok`) from their
  frame-pointer-relative homes into `rsi rdi r8–r11` (`mov R,[rbp±d]`),
  marks the symbol record's register field, and `loop_leave()` writes
  the live ones back where every exit edge lands. A for-range's hidden
  end and step words join as kind `'H'` (no write-back), so
  `for i in range(n): s = s + i` is the same five-instruction loop as
  the `while` form. A candidate declared inside the loop body is
  pending until its declaration (`rl_declare_pending`, kind `'B'`).
  Any call the emitter still meets inside such a loop (`call_eax`, the
  inline FFI path) parks the live registers in their homes and fetches
  them back (`regalloc_call_spill`/`_reload`): the scan's facts are
  only a hint, correctness never depends on them, and the stack-slot
  assertions stay fail-closed. `loops owning registers: 402, loop
  registers: 306` for `w.w` on x64.
- **Deviations from §2.3**: a `return` inside the loop writes nothing
  back (every loop-owned value is dead at a return once `defer` is
  excluded); x86 `ecx`/`edx` are not taken (the shift and division
  sequences use them and the function-level budget already holds
  `esi`/`edi`; `rl_target_mask` is where an x86 mask would go);
  win64 stays off with the rest of promotion (`target_os != 0`);
  hot-loop alignment is P2's (`profile_use_loop_align`). arm64,
  darwin, win64 and wasm output is byte-identical (`verify_arm64`).
- **The scan stops counting `x = i * m` as a `T* name` declaration**:
  `*` after an identifier is a type only where a statement, parameter,
  cast or generic argument may begin (line start, after `( , [ { ; :`
  or a keyword). It still over-counts (`f(a * b)`) and never
  under-counts; `m` in `s = s + i * m` ranks for function-level
  promotion now too.

Measurements (4-core cloud container; "before" is the integration
branch at 7f147be7 — R2 + P2 phase A — built to its fixpoint, "after"
this branch's fixpoint `bin/wv3` / `bin/wv3_64` after the merge with
P2 phase B, "main" the pre-plan compilers; best-of-5 wall, callgrind
Ir):

| micro-benchmark, 10^9 iterations (instructions per iteration from Ir at 10^7) | main | before | after |
| --- | --- | --- | --- |
| §1.1 `sum_to` while loop, x86 | 1.340 s, 23 | 0.889 s, 16 | 0.340 s, 5 |
| same, x64 | 1.263 s, 23 | 0.878 s, 16 | 0.690 s, 5 (0.326–0.363 s with the loop placed elsewhere, see below) |
| `for i in range(n): s = s + i`, x86 | 1.119 s, 17 | 0.702 s, 12 | 0.349 s, 5 |
| same, x64 | 1.090 s, 17 | 0.709 s, 12 | 0.339 s, 5 |
| `s += i; i++` while loop, x86 | 1.313 s, 23 | 1.226 s, 22 | 0.338 s, 5 |
| same, x64 | 1.227 s, 23 | 1.242 s, 22 | 0.655 s, 5 (layout, as above) |

The x64 `sum_to` loop is §1.3's variant B exactly (`cmp r12,rsi; jge;
add r13,r12; add r12,1; jmp`, `n` in `rsi` for the loop's extent), yet
its wall time depends on where the five instructions land: moving the
function by a few bytes (a padding function of k statements before
it) gives 363, 355, 340, 668, 326, 351, 684, 352 ms for k = 0..7, the
slow placements being those where `cmp`+`jge` end on or straddle a
32-byte boundary (the fused-branch erratum of the Skylake-family
cores this container runs on). It is the layout sensitivity §2.3's
alignment step exists for; `--profile-use` pads hot heads to 16 bytes
(P2), the default build does not, so the unaligned number is the
honest one for the table.

| `bin/wbench --programs -n 5` (kIr, best ms) | main | before | after |
| --- | --- | --- | --- |
| sum x86 / x64 | 13,800,447 (815) / 13,800,447 (775) | 9,600,395 (517) / 9,600,395 (524) | 3,000,259 (423) / 3,000,254 (202) |
| sieve x86 / x64 | 4,066,658 (440) / 4,066,658 (441) | 3,597,355 (371) / 3,590,054 (387) | 1,683,751 (284) / 1,664,277 (279) |
| sha256_1m x86 / x64 | 7,701,753 (468) / 7,701,753 (473) | 7,485,168 (459) / 7,436,410 (453) | 5,586,837 (360) / 5,373,447 (347) |
| siphash_keys x86 / x64 | 6,148,476 (703) / 6,908,822 (1166) | 5,953,930 (670) / 6,490,605 (858) | 4,576,849 (596) / 4,849,309 (861) |
| inflate_corpus x86 / x64 | 6,777,705 (499) / 6,721,188 (502) | 6,480,057 (487) / 6,351,846 (484) | 5,357,385 (456) / 5,179,840 (454) |
| regex_backtrack x86 / x64 | 10,185,946 (588) / 10,185,946 (620) | 9,692,806 (557) / 9,791,912 (563) | 6,600,524 (433) / 6,682,831 (443) |
| matmul_256 x86 / x64 | 8,771,516 (523) / 8,771,516 (521) | 7,597,846 (442) / 7,595,874 (446) | 5,068,987 (360) / 5,065,035 (392) |
| strcmp_sort x86 / x64 | 4,601,677 (483) / 4,721,782 (525) | 4,497,147 (476) / 4,576,365 (490) | 3,605,684 (443) / 3,609,401 (485) |

Against "before", the corpus instruction counts fall by 17% (inflate)
to 69% (sum), 25–33% for sha256, regex and matmul; most of it is the
folds (step A alone: sum 9.60 → 3.00 G, sieve 3.60 → 2.15 G, sha256
7.49 → 5.59 G, matmul 7.60 → 5.07 G), the loop registers add the rest
on x64 (sieve 2.15 → 1.66 G, sha256 5.54 → 5.37 G).

| self-compile of `w.w` (compiler binary compiling this tree's `w.w`; best-of-5 wall, callgrind Ir) | main | before | after |
| --- | --- | --- | --- |
| x86 | 0.854 s, 8.024 G | 0.981 s, 8.087 G | 0.929 s, 6.786 G |
| x64 | 0.799 s, 7.875 G | 0.880 s, 8.192 G | 0.824 s, 6.733 G |

The compiler executes 16–18% fewer instructions than before (and 15%
fewer than main, scan included) but the wall clock recovers only half
of R2's regression on x86: the scan's extra passes over the source
are memory- and syscall-bound (seeks), not issue-bound. The `w.w`
image shrinks from 2,828,672 to 2,705,792 bytes on x86 (622,759 →
577,960 instructions) and from 3,232,512 to 3,085,056 on x64 (619,726
→ 574,402).

Gates (merged tree, refreshed profiles): `verify`, `verify_x64`,
`verify_arm64`, `verify_pgo`, `tests` (916 targets, 0 failures),
`regalloc_test` + `_64`, `regalloc_diff_test` (406 programs compared
on their own width, 0 mismatches; the race/timing tests skipped as
nondeterministic), `asm_x64_test` (528,076 instructions re-encoded, 0
unknown, 0 mismatches), `asm_fuzz_{x86,x64,arm64}_test`,
`local_load_fold_test` + `_64`, the `ast_*` suites (canary, expression,
retained, retained_emit, semantic, symbol_probe, tree_query, audit),
`repl_test` + `_x64`, `debug_test`, `dwarf_variables_test`,
`wdbg_web_test`, `wdbg_ui_test`, `compound_assign_*`, `const_fold_*`,
`defer_*`, `goto_*`, `generator_*`, `for_*`, `increment_*`,
`switch_*`, `warning_test`, `self_host_warning_test`,
`parser_generator_w_test`, `profile_check` (100% after
`profile_refresh`). `verify_win` could not run (no `wine` on the
box); win64 code is unchanged by construction (`target_os != 0`
returns before the scan).

Not claimed / for the next unit:
- **x86 gets no loop registers** (`loops owning registers: 0`): an
  x86 mask of `ecx`/`edx` needs the shift-by-variable and
  division sequences to spill them first (they are the only emitter
  paths that touch those two), or a loop hazard bit the scan already
  records (`rs_lp_has_divshift`) to decline such loops.
- **wdbg shows a loop-owned local's stale stack word inside the
  loop**: `.debug_info` keeps the `fbreg` location (the home), which
  is only current at loop entry, after write-back, and around calls.
  A location list per loop extent would fix it.
- A name used only in the range arguments (`n` in `for i in
  range(n)`) still gets a register, a load and a write-back it never
  needs: the scan's per-loop use delta counts the header.
- Loop candidates beyond the first ten per loop, nested loops sharing
  a budget (the inner loop takes what the outer left), floats, narrow
  integers and aggregates are untouched; the profile's loop weights
  (P2) rank function-level candidates, not yet the per-loop ones.
- The micro-benchmarks' layout sensitivity above is the strongest
  argument yet for aligning hot loop heads in the default build (a
  size budget per function, not only under `--profile-use`).

### C1 — the x86 self-compile wall-time regression (2026-10-07)

**Symptom.** With R1–R3 and P2 landed, the default x86 `bin/wv3`
executed 11% fewer instructions than main's compiler on `w.w` (6.58 G
vs 7.39 G Ir) yet took 15% more wall time (920 / 972 ms best / median
of 10 interleaved runs against 798 / 855 ms, orchestrator's
measurement on the 4-core container); the same binary with `--no-regs`
was the fastest compiler of the three (745 / 803 ms). x64 showed no
regression. R2's scan was known to cost ≈ 480 M Ir (≈ 7%), far less
than the 125–175 ms gap.

**Root cause, measured.** Two parts, and the smaller one in
instructions was the larger one in time:

1. *System calls.* R2's byte source saved, seeked, read and restored
   the source fd around every scanned body: `strace -c` counted 8,262
   `lseek` + 1,151 `read` per `w.w` compile against 0 + 695 with
   `--no-regs`. On this box a 32-bit `int 0x80` system call costs
   ≈ 7.5 µs where the x64 `syscall` costs ≈ 0.15 µs (a W program doing
   8,000 `lseek`s: 62 ms as x86, 2.8 ms as x64; 8,000 seek+read pairs:
   61 / 2.7 ms), so the scan's ≈ 8,700 extra calls were ≈ 65 ms of
   wall on x86 and ≈ 1 ms on x64 — exactly the asymmetry in the
   symptom. (The x86 compiler's own `read`s of the source, 695 of
   them, are ≈ 5 ms by the same arithmetic; main pays them too.)
2. *The lexer.* The rest of the gap was the scan's ≈ 100 Ir per source
   byte: a function call per byte (`rs_next`), four range compares per
   identifier byte, up to four `strcmp`s per identifier for the
   keyword and hazard tests, and a mode-0 probe that lexed every token
   of every body to answer "does a `while`/`for` open a line here".
   Cachegrind put the scan's 480 M Ir at +3.3 M conditional-branch
   mispredictions (+27%) and +0.5 M D1 misses over `--no-regs`.

Hypothesis (b) of the brief — something microarchitectural in the
promoted output — is ruled out by the `--no-regs` number: that is the
promoted binary (R2 epilogues, pushes of `esi`/`edi`, R3 folds and all)
with only the scan switched off, and it beats main by 7%.

**What landed** (`compiler/regalloc_scan.w`, `compiler/regalloc_profile.w`,
`lib/lib.w`, `code_generator/retained_emit.w`; no grammar or emitter
change):

- *One image per file.* The first scan of an fd binding reads the whole
  file into a private image (`seek` to 0, `read` to the end, `seek`
  back: four system calls per file, 637 `lseek` + 907 `read` per `w.w`
  compile) and every scan and P2 hash pass is served from it; the
  byte loops see one run per body with no boundary before the end of
  the file. `lib/lib.w` gained `getchar_generation[fd]`, bumped by
  `getchar_reset` and by `retained_emit`'s window swap, so a recycled
  fd number is told apart from the stream the image was taken of; the
  image is a snapshot of bytes the compiler already treats as immutable
  (every reparse path reopens the path and seeks to a recorded offset).
  getchar's window still serves what the image lacks (the retained
  `/dev/null` fds), a pipe (not seekable, no image) aborts past the
  window as before, and `rs_end_scan`/`rs_saved_offset` are gone — the
  P2 hash pass no longer seeks either.
- *Byte loops in locals through a class table.* `rs_take_ident`,
  `rs_skip_blanks`, `rs_newline`, the comment and literal skips walk
  `rs_p`/`rs_end` in locals (which the scan's own promotion puts in
  registers — the dogfooding works) and test one bit of a 258-entry
  class table per byte (`rs_class[-1]` is valid, so the end-of-input
  test is gone from the loops); an identifier is measured, then copied
  once. `rs_is_keyword`/`rs_is_hazard` became one probe of a 64-slot
  open-addressed table on the hash `rs_take_ident` already accumulates
  (one `strcmp` on a hash hit; `range`, which is not a keyword, lives
  there with kind 0 — occupancy is the text pointer, which the first
  cut got wrong and the x64 identity sweep caught through
  `rs_lp_has_call`). The body loop reads the class once per token and
  computes the loop-head offset R3 keys its facts by only for a
  `while`/`for` at a line start.
- *`rs_probe_lines`.* For a `:` body of unknown class the mode-0 probe
  is now line-based on the image: skip the signature line's blanks and
  comment, then per line count the leading tabs, apply the dedent rule,
  test for `while`/`for` as the line's first identifier and skip the
  rest of the line through the stop-byte class (newline, NUL, `#`,
  quotes, `/`, braces). Anything the line view cannot follow — a token
  on the signature line, a brace, `/*`, a `/` opening a line, a literal
  running past its line, a NUL, bytes a window serves — answers 2 and
  the full lexer decides as before, so the answer is never a guess and
  the output cannot depend on which path decided (a probe that said
  "loop" when there is none would run a full pass that promotes names
  with 8+ plain uses). The image carries a NUL sentinel for it.
  Brace bodies, hot (P2) bodies and the full pass itself are unchanged.

**Decisions are unchanged.** The `w.w` image compiled by the old and
the new compiler is byte-identical on x86 and x64 (`--stats`: 1,026
bodies scanned, 1,530 / 2,214 locals promoted, 414 loops owning 309
registers on x64), and so is every program of `tests/`, `tests/bench/`
and `tools/` that compiles: 530 on x86, 568 on x64, 0 differing
(`scratchpad/ident_sweep.py`, head compiler vs this one, same tree).

**Measurements** (4-core cloud container, idle; `w.w` self-compile;
"main" is `scratchpad/base/wv_x86` / `wv_x64`, the pre-plan compilers
built by the seed; "before" the branch's fixpoint `bin/wv3` at R3;
best / median of 10 interleaved runs):

| `w.w` self-compile, best / median ms | main | before (R3 fixpoint) | after | after `--no-regs` | after, PGO-built (`bin/wv3_pgo`) |
| --- | ---: | ---: | ---: | ---: | ---: |
| x86 | 835 / 860 | 942 / 967 | **782 / 833** | 745 / 783 | 796 / 828 |
| x64 | 851 / 870 | 791 / 843 | **777 / 824** | 711 / 757 | 747 / 791 |

Earlier rounds on the same box gave the same ordering (x86 main
803 / 850, before 907 / 988, after 766 / 826; x64 main 829 / 877, after
770 / 807): the default x86 compiler is now 6% faster than main's
instead of 13% slower, and the scan's whole remaining cost is the
≈ 40 ms between the "after" and `--no-regs` columns on either width.

| `bin/wv3` x86 on `w.w` | callgrind Ir | regalloc_scan.w self Ir | `lseek` / `read` |
| --- | ---: | ---: | ---: |
| before, default | 6.744 G | 410 M (+ ≈ 75 M in `strcmp`, list helpers) | 8,262 / 1,151 |
| before, `--no-regs` | 6.259 G | 0 | 0 / 695 |
| after, default | 6.617 G | 203 M | 637 / 907 |
| after, `--profile-use=profiles/self.wprof` | | | 637 / 911 |

(Ir totals move by ±1–3% between runs of the same binary through the
hash tables' per-process seed — 76 M of one default-vs-`--no-regs`
diff was `__w_hash_table_slot` probe chains at equal call counts — so
the per-file self column is the one to read.) Of the 203 M: the full
pass's token loop 40 M, `rs_probe_lines` 34 M (≈ 12 Ir per byte over
the ≈ 2.9 MB of source), `rs_take_ident` 34 M, `rs_identifier` 16 M,
the keyword probe 9 M, `rs_tables_clear` 8 M.

Bench corpus (`bin/wbench --programs --compiler bin/wv3 --compiler64
bin/wv3_64 -n 3 --compare tests/bench/baseline.txt`, kIr = callgrind
Ir / 1000, best ms of 3): every program's instruction count is the
same as R3's table to within the hash-seed noise (the programs with no
map are bit-exact: `sum` 3,000,261 / 3,000,256, `sieve` 1,683,752 /
1,664,278, `sha256_1m` 5,586,839 / 5,373,448, `regex_backtrack`
6,600,525 / 6,682,833, `matmul_256` 5,068,989 / 5,065,037,
`strcmp_sort` 3,605,686 / 3,609,403, `inflate_corpus` 5,357,386 /
5,179,842, `siphash_keys` 4,574,735 / 4,851,498 for x86 / x64), as it
must be when the emitted code is byte-identical; `wbench: no
regression against tests/bench/baseline.txt` (every row 17–78% under
the pre-plan baseline's Ir). The `self` rows of the same run: x86
6.528 G Ir, 803 ms; x64 6.619 G, 817 ms (baseline 7.336 G / 908 ms and
7.570 G / 805 ms).

**Gates** (this tree, after `profile_refresh`): `verify`, `verify_x64`,
`verify_arm64`, `verify_pgo` (`wv3_pgo == wv4_pgo == wv5_pgo`, x86 and
x64), `profile_check` (100% on the three refreshed profiles), `tests`
(916 targets, 0 failures), `tests_x64` (353 targets, 0 failures), and the identity
sweeps above. `wtest changed` selects every umbrella for this diff
(`lib/lib.w` is in every program's import closure).

Not claimed / for the next unit:
- The remaining scan cost is ≈ 203 M Ir ≈ 3% of the compile and ≈ 40 ms
  of wall over `--no-regs`; the next levers are `rs_tables_clear`'s
  256-bucket wipe after every full pass (clear the chain instead) and
  the full pass's per-token global traffic, neither worth a unit alone.
- The image is per fd binding, not per path: a path reopened for a
  generic or defer reparse (4 times in a `w.w` compile) is read again.
- `rs_probe_lines` answers 2 for a same-line body (`int f(): return x`),
  so those still pay the full lexer for one line; a `{`-body or a
  body with a block comment pays it whole. Both are rare in this tree.
- The 32-bit system-call cost measured here (≈ 7.5 µs per `int 0x80`
  on a 64-bit Firecracker kernel) is the box's property, not the
  compiler's; `sysenter`/vDSO would not help a static seed binary, and
  the only remaining per-compile calls (open/close/getcwd per import,
  one read chunk per 8 KB of source, the output write) are main's too.

### Combined result: main vs this branch vs C (2026-10-07)

Measured after every unit above had merged (integration branch at the
C1 merge), on the same idle 4-core cloud container. "main" is the
compiler built from `86fb3803` (this plan's merge commit) before any
unit landed; "new" is this branch's `bin/wv3`, compiling each program
with default flags; "PGO" adds `--profile-use=profiles/bench.wprof`.
C twins are `tests/bench/c/*.c` built with `gcc -O2` / `clang -O2`
(x86-64; no 32-bit multilib here). Every binary in every column printed
the same checksum line. `--no-asm` legs are absent: the asm-bodies
work (#579) is not on this branch's base.

Instruction counts (callgrind Ir, deterministic per binary):

| program | main x86 | main x64 | new x86 | new x64 | new x64 PGO | gcc -O2 | clang -O2 | new x64 vs main x64 | new x64 vs gcc |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| sum | 13.80 G | 13.80 G | 3.00 G | 3.00 G | 3.00 G | 1.20 G | 0.27 M | 4.60x fewer | 2.5x more |
| sieve | 4.07 G | 4.07 G | 1.68 G | 1.66 G | 1.66 G | 0.59 G | 0.80 G | 2.44x fewer | 2.8x more |
| sha256_1m | 7.70 G | 7.70 G | 5.59 G | 5.37 G | 5.29 G | 1.29 G | 1.31 G | 1.43x fewer | 4.2x more |
| siphash_keys | 6.15 G | 6.91 G | 4.58 G | 4.85 G | 4.42 G | 1.18 G | 1.15 G | 1.43x fewer | 4.1x more |
| inflate_corpus | 6.78 G | 6.72 G | 5.36 G | 5.18 G | 5.18 G | 0.99 G | 0.84 G | 1.30x fewer | 5.3x more |
| regex_backtrack | 10.19 G | 10.19 G | 6.60 G | 6.68 G | 6.68 G | 2.54 G | 2.42 G | 1.52x fewer | 2.6x more |
| matmul_256 | 8.77 G | 8.77 G | 5.07 G | 5.07 G | 5.07 G | 1.18 G | 0.68 G | 1.73x fewer | 4.3x more |
| strcmp_sort | 4.60 G | 4.72 G | 3.61 G | 3.61 G | 3.60 G | 0.57 G | 0.59 G | 1.31x fewer | 6.3x more |

Wall time, best of 7 runs, ms:

| program | main x86 | new x86 | x86 speedup | main x64 | new x64 | new x64 PGO | gcc -O2 | clang -O2 | main x86 / gcc | new x86 / gcc |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| sum | 766 | 407 | 1.88x | 1211 | 210 | 409 | 201 | 1 | 3.8x | 2.0x |
| sieve | 476 | 278 | 1.71x | 488 | 286 | 274 | 222 | 221 | 2.1x | 1.3x |
| sha256_1m | 462 | 353 | 1.31x | 466 | 336 | 342 | 114 | 118 | 4.1x | 3.1x |
| siphash_keys | 695 | 581 | 1.20x | 1018 | 820 | 734 | 314 | 309 | 2.2x | 1.9x |
| inflate_corpus | 515 | 465 | 1.11x | 529 | 453 | 428 | 67 | 69 | 7.7x | 6.9x |
| regex_backtrack | 600 | 431 | 1.39x | 626 | 430 | 464 | 210 | 171 | 2.9x | 2.1x |
| matmul_256 | 520 | 367 | 1.42x | 528 | 390 | 404 | 178 | 190 | 2.9x | 2.1x |
| strcmp_sort | 515 | 434 | 1.19x | 542 | 464 | 493 | 190 | 195 | 2.7x | 2.3x |

`sum`'s x64 wall times are layout-bound (R3's note: the same five-instruction
loop runs in ~330 or ~670 ms depending on where cmp+jge fall against a
32-byte boundary), so they move between builds: an earlier run of the
same table had main x64 805 ms, new x64 221 ms, new x64 PGO 212 ms. The
x86 columns and all instruction counts are stable. clang folds `sum`
to a closed form, so its 1 ms is an optimiser ceiling, not codegen.

Self-compile of `w.w` by the compiler binary (best of 7, ms): main x86
805, new x86 809, new x86 PGO-built 786; main x64 833,
new x64 831, new x64 PGO-built 756. Callgrind Ir: main x86 7.39 G, new
x86 6.36 G, PGO 6.26 G; main x64 7.33 G, new x64 6.36 G, PGO 6.13 G. The
new compiler does more work per compile (the register pre-scan) and
still finishes at or below main's time; the PGO-built x64 compiler is
the fastest of the six.

What this does not claim: R4 (arm64 registers, x86 ecx/edx loop
registers) and P3 (inlining) are not built; x86-32 still has only
esi/edi plus no loop-scoped registers, which is why x64 gains more on
the loop-heavy rows. On x86, W remains 1.3-6.9x slower than gcc -O2
(x86-64) in wall time, down from 2.1-7.7x on main, with `inflate_corpus`
and `sha256_1m` furthest behind.
