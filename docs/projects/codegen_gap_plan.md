# Closing the code-generation gap to gcc: where the remaining 2-6x goes, and a staged plan

Status: analysis and plan, 2026-10-07, written against `main` at `d3c98ff`
(the merge of #582, "Register allocation and profile-guided optimization").
Companion to [register_allocation_pgo.md](register_allocation_pgo.md) (the
plan #582 executed; its §11 holds each unit's measurements),
[optimization.md](optimization.md) (the peephole-vs-AST assessment whose
"mechanism 1" notes every unit below reuses) and
[asm_functions.md](asm_functions.md) on PR #579 (hand-written bodies for
the stdlib's hot leaves, in progress). Every number in §1-§3 was measured
on this checkout, on the same idle 4-core x86-64 cloud container, with
the commands in §9.

## 0. Summary

- **After #582, W's x64 output is a gcc `-O0`-class compiler with
  registers for scalar loop counters.** On the eight-program corpus of
  `tests/bench/` it executes 2.5-6.3x the instructions of `gcc -O2` and
  takes 1.0-6.1x the wall time (§1). Against `gcc -O0` it is ahead on
  `sum` and `sieve` and behind on everything that touches memory through
  pointers, structs or calls (`inflate_corpus`: 5.2 G instructions vs
  2.6 G at `-O0`).
- **The gap is not one thing; it is five mechanisms the single-pass
  emitter still lacks, in this order of cost** (§2): (G1) pointer and
  struct-pointer locals never get a register, so every `a[i]` and
  `c.field` reloads its base from the stack; (G2) no memory operands or
  addressing modes, so `a[i]` is six instructions and `c.field` three;
  (G3) expression temporaries still go through `push`/`pop` whenever the
  right operand is more than one instruction (16-29% of the hot loops);
  (G4) calls cost about 20 instructions of pure overhead and nothing is
  inlined, so per-bit, per-byte and per-compare helpers dominate
  `inflate_corpus`, `strcmp_sort` and `siphash_keys`; (G5) loop shape:
  no bottom-tested loops, no invariant hoisting, no strength reduction.
  Then the long tail: boolean materialisation in `&&` chains, the
  32-bit-mask idiom instead of `ror`, x86-32's two-register budget.
- **Two experiments bound what the first units are worth.** Rewriting
  `matmul_256`'s inner loop so its array bases are pointer locals the
  allocator already accepts (what G1 + strength reduction would emit)
  cut it from 411 ms to 200 ms on x64, which is `gcc -O2`'s 190 ms, with
  40% fewer instructions (§3.1). The SHA-256 round loop is 145
  instructions where gcc's is 48; 42 of the 145 are `push`/`pop` pairs
  and 33 are register-to-register moves the accumulator model forces
  (§2.3), so G3 alone is worth about a third of that loop.
- **#579 (asm bodies) is complementary, not an alternative.** It makes
  six to eight stdlib leaves gcc-class by hand and is the fastest way to
  fix `sha256_block_w` and `__w_hash_sip`, which are 75% and 38% of two
  corpus programs; it does nothing for the other six programs or for any
  user code, and its stdlib half waits on a seed bump. Land its compiler
  side now (after a rebase onto #582's callee-saved contract), keep a
  `--no-asm` row in the benchmark so asm bodies cannot hide codegen
  regressions, and treat each asm body as a target the compiler should
  eventually match on the portable body (§4).
- **The plan (§5) is two waves of units in the style of #582** — each a
  note-based emission change, seed-safe, gated by the self-host fixpoints
  and `regalloc_diff_test`, measured on the corpus — followed by the
  optimizer-pass slot the AST plan already reserves (C3.5) for the loop
  transformations the single-pass model cannot express. Wave A (G1-G4
  and the long tail) is estimated to take the x64 corpus from 2.5-6.3x
  of gcc's instruction count to roughly 1.5-2.5x and the wall-time gap
  from 1.0-6.1x to about 1.2-2.5x; wave B (bottom-tested loops, scaled
  addressing on induction variables, inlining with the profile) closes
  most of the rest on scalar code. What stays out of reach without an IR
  is what gcc does with one (§6): vectorisation (`matmul_256` under
  clang, `sum` folded to a closed form) and whole-function scheduling.

## 1. Where things stand (measured 2026-10-07)

`tools/bench_vs_c.sh -n 5` on `main` at `d3c98ff`, `bin/wv2` built by
`./wbuild build`, C twins (`tests/bench/c/*.c`, line-for-line ports of
the W programs including the library code they lean on) built with
`gcc 13.3 -O2` and `clang -O2` for x86-64; no 32-bit multilib on this
box, so there is no `gcc -m32` column. Every binary in every column
printed the same checksum line. The `gcc -O0` / `-O1` columns were
added by hand for scale (§9).

Wall time, best of 5, ms:

| program | W x86 | W x64 | gcc -O2 | clang -O2 | gcc -O0 | gcc -O1 | W x64 / gcc -O2 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| sum | 431 | 220 | 218 | 3 | 1583 | 227 | 1.0x |
| sieve | 286 | 300 | 237 | 235 | 567 | 244 | 1.3x |
| sha256_1m | 373 | 363 | 122 | 122 | 299 | 125 | 3.0x |
| siphash_keys | 616 | 808 | 305 | 311 | 665 | 310 | 2.6x |
| inflate_corpus | 493 | 470 | 77 | 73 | 272 | 96 | 6.1x |
| regex_backtrack | 475 | 478 | 216 | 182 | 546 | 209 | 2.2x |
| matmul_256 | 374 | 411 | 190 | 203 | 413 | 189 | 2.2x |
| strcmp_sort | 443 | 471 | 198 | 197 | 348 | 199 | 2.4x |

Instructions executed (callgrind Ir, deterministic per binary), G:

| program | W x86 | W x64 | gcc -O2 | clang -O2 | gcc -O0 | gcc -O1 | W x64 / gcc -O2 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| sum | 3.00 | 3.00 | 1.20 | 0.0002 | 3.60 | 2.40 | 2.5x |
| sieve | 1.68 | 1.66 | 0.59 | 0.80 | 1.63 | 0.79 | 2.8x |
| sha256_1m | 5.59 | 5.37 | 1.29 | 1.31 | 2.86 | 1.40 | 4.2x |
| siphash_keys | 4.58 | 4.85 | 1.18 | 1.15 | 3.23 | 1.23 | 4.1x |
| inflate_corpus | 5.36 | 5.18 | 0.99 | 0.84 | 2.65 | 1.29 | 5.3x |
| regex_backtrack | 6.60 | 6.68 | 2.54 | 2.42 | 4.73 | 2.98 | 2.6x |
| matmul_256 | 5.07 | 5.07 | 1.18 | 0.68 | 4.05 | 1.18 | 4.3x |
| strcmp_sort | 3.61 | 3.61 | 0.57 | 0.59 | 1.47 | 0.62 | 6.3x |

Reading the two tables together:

- `sum` is at parity in wall time because its loop is already the
  five-instruction ideal of #582's R3 and the machine is bound by the
  loop-carried `add`, not by issue width. gcc executes two instructions
  per iteration to W's five and runs no faster; clang folds the loop to
  a closed form, which is an optimiser ceiling, not codegen. `sieve` is
  close for the same reason: the strided store is bound by the memory
  system.
- Everything else is 2-6x and the instruction ratio tracks the
  wall-time ratio. These programs are issue-bound, so the plan's unit
  of account is instructions per hot-loop iteration (§2), which
  callgrind measures deterministically and which the fixpoint gates
  can watch.
- The `-O0` column is the useful scale. gcc `-O0` keeps every variable
  in memory and emits no addressing-mode tricks, yet `inflate_corpus`,
  `strcmp_sort` and `sha256_1m` execute 1.9-2.5x *more* instructions
  under W than under `-O0`, which is what §2's G2-G4 cost: `-O0` still
  uses `mov eax,[rdi+0x30]` for a field, `call rel32` for a call and
  never pushes a temporary. `-O1` is the realistic end state of §5's
  waves A and B (it is "registers, addressing modes, inlining, loop
  inversion, no vectorisation"); on this corpus `-O1` is within 5% of
  `-O2` in wall time except on `inflate_corpus` (25%), where `-O2`'s
  inlining budget matters.
- x86-32 and x64 are within 10% of each other on every row but
  `siphash_keys` (the 64-bit word doubles the hash table's slot and key
  traffic) and `sum`. The x64 numbers are the comparison that matters
  (the C columns are x86-64), and the plan targets x64 first as #582
  did; x86-32's two-register budget is the long tail (§2.7).

Per-program hot spots on x64 (callgrind, share of the program's Ir):

| program | hottest W functions | note |
| --- | --- | --- |
| sum | `sum_to` 100% | 5 instructions/iteration, the R3 ideal |
| sieve | `sieve` 96% | inner strided store 7 instructions/iteration (gcc: 4) |
| sha256_1m | `sha256_block_w` 75%, `bench_rand` 17% | round loop 145 instructions (gcc: 48) |
| siphash_keys | `__w_hash_sip` 38%, `__w_hash_table_rehash` 10%, `__w_hash_table_slot` 7%, `freelist_malloc` 4%, `__w_strcmp` 3% | hash per lookup through two dispatch calls |
| inflate_corpus | `inf_get_bit` 20%, `wh_decode` 18%, `__w_size_add` 12%, `string_append_char` 9%, `string_reserve` 7%, `inf_emit_byte` 6%, `inf_copy_match` 6% | one call per input bit, one per output byte, one overflow-check call per push |
| regex_backtrack | `rx_here` 42% (recursive), `regex_match_length` 30%, `rx_element_matches` 9%, `rx_class_matches` 6% | call-heavy, every local a stack slot across the recursion |
| matmul_256 | `matmul` 99.7% | inner loop 30 instructions/iteration (gcc -O2: 7, clang: vectorised) |
| strcmp_sort | `__w_list_compare_values` 22%, `__w_list_merge_sort` 19%, `__w_list_sort_compare` 17%, `__w_list_load_word` 9%, `bench_rand` 8% | three calls per comparison, 26-instruction character loop (gcc inlines it: ~6) |

## 2. Where the instructions go

Static instruction classes of the hottest loop or function of each
program, x64 build (`objdump -d -Mintel`, classified by a small script;
"slot load" is `mov rax,[rsp+N]`/`[rbp±N]`, "shuttle" the
`push rax`/`pop rbx` pair and `mov rbx,rax` the operand model needs,
"reg-reg mov" mostly `mov rax,R`/`mov R,rax` around a register-resident
local):

| region | instructions | ALU | push+pop | reg-reg mov | slot load | data load/store | branch+cmp | call |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `sha256_block_w` round loop | 145 | 54 (37%) | 42 (29%) | 33 (23%) | 6 | 3 | 3 | 0 |
| `matmul` inner loop | 30 | 9 | 8 (27%) | 4 | 2 | 2 | 3 | 0 |
| `__w_hash_sip` (whole) | 296 | 56 | 65 (22%) | 58 | 28 | 21 | 12 | 2 |
| `rx_here` (whole) | 394 | 53 | 111 (28%) | 9 | 50 (13%) | 19 | 73 | 18 |
| `wh_decode` (whole) | 115 | 18 | 42 (37%) | 16 | 5 | 6 | 9 | 5 |
| `__w_list_merge_sort` (whole) | 268 | 27 | 74 (28%) | 20 | 45 (17%) | 15 | 36 | 11 |

gcc's versions of the same regions are 4-7 instructions per matmul
iteration, 48 per SHA-256 round, and a handful of loads and compares
per character in the string compare. The sections below name each
mechanism, show the shape it produces today, say what the fix is in
the emitter's terms and which programs it moves. Line references are
to `main` at `d3c98ff`.

### 2.1 G1: pointer and struct-pointer locals never get a register

`compiler/regalloc_scan.w` excludes from promotion any name that is
subscripted, called or field-accessed (its header comment and
`rs_excluded` at lines 934-947: an identifier followed by `(`, `[` or
`.`). That rule was the conservative choice for R2 and it is the single
largest remaining cost on the corpus, because it means **every array
base and every struct pointer lives in a stack slot**, and every use of
it is a slot load plus a push/pop pair around the index arithmetic:

```
; matmul inner loop, x64: acc = acc + a[i * n + k] * b[k * n + j]
; i=r15 j=r14 acc=r13 k=r12 n=rsi; a and b are NOT in registers
 805f1e4: mov rax,r13               ; acc
 805f1e7: push rax
 805f1e8: mov rax,[rsp+0x78]        ; a         <- slot load
 805f1ed: push rax
 805f1ee: mov rax,r15
 805f1f1: imul rax,rsi              ; i*n       <- loop-invariant
 805f1f5: add rax,r12
 805f1f8: imul rax,rax,0x8          ; scale     <- G2
 805f1ff: pop rbx
 805f200: add rax,rbx
 805f203: mov rax,[rax]
 805f206: push rax
 805f207: mov rax,[rsp+0x78]        ; b         <- slot load
 ... same again for b[k*n+j] ...
 805f225: pop rbx
 805f226: imul rax,rbx
 805f22a: pop rbx
 805f22b: add rax,rbx
 805f22e: mov r13,rax
 805f231: add r12,0x1
 805f235: jmp 805f1db               ; back to cmp r12,rsi / jge
```

The same shape is `composite[j] = 1` in `sieve` (7 instructions for a
one-instruction store), `w[i]`, `k[i]`, `h[...]` and `block + i * 4` in
`sha256_block_w`, `table.states[i]` / `table.keys[i]` in
`__w_hash_table_slot` (`table` is both field-accessed and the base of
every subscript), `c.status` / `c.bit_pos` / `c.in_data` in
`inf_get_bit` (eight field accesses through one excluded argument), and
`sa[j]` / `sb[j]` in `__w_list_compare_values`.

What the fix is: lift the exclusion for word-sized pointer locals and
arguments whose uses are `name[...]` reads and writes and `name.field`
reads and writes (the address being formed is the element's or the
field's, never the variable's, so the register is never
address-taken), and make the subscript and field paths in
`grammar/postfix_expr.w` (`accept(c"[")` at line 446, `accept(c".")` at
line 622) read the base through the same `sym_emit_value` →
register path the scalar reads already use. The fail-closed guard
(`regalloc_scan.w:349/360`) turns any path that still materialises
the slot into a compile-time internal error, so the unit is safe by
construction and `regalloc_diff_test` (406 programs with and without
`--no-regs`) is its correctness gate. Section 3.1 measures what it is
worth on `matmul_256`.

Also in this unit: the loop-register pass (R3) ranks only scalar
candidates, so `a`, `b` and `out` in `matmul` do not even compete for
`r8`-`r11` while `mask` does; the per-loop candidate ranking should
weight a subscripted base by its subscripts.

### 2.2 G2: no memory operands, no addressing modes

The emitter has one addressing form for data: compute the address into
`rax`, then `mov rax,[rax]` (or `mov rbx,rax; mov [rbx],rax` for a
store). So:

- `a[i]` with both in registers would still be `mov rax,R_i; imul
  rax,rax,8; add rax,R_a; mov rax,[rax]` — four instructions and a
  3-cycle `imul` for what is one `mov rax,[R_a+R_i*8]`. The scale is
  emitted as `imul rax,rax,0x8` (`imul_eax_int32`, 7 bytes) rather than
  `shl rax,3` or, better, folded into the SIB byte.
- `c.field` is `mov rax,[rsp+N]; add rax,0x30; mov rax,[rax]` (3) for
  `mov rax,[R_c+0x30]` (1); `inf_get_bit` does this about a dozen times
  per call. With G1 it becomes `mov rax,R_c; add rax,0x30; mov rax,[rax]`,
  still three.
- A store through a register base, `hh = g` with `hh` on the stack, is
  `lea rax,[rsp+0x30]; mov rbx,rax; mov rax,r9; mov [rbx],rax` (4) for
  one `mov [rsp+0x30],r9`.
- `cmp rax,0x0` after `movsx rax,byte [rax]` where `cmp byte [R],0`
  would do; `mov eax,0x0; mov r13,rax` for `xor r13d,r13d`;
  `mov eax,0x1; neg rax` for `-1`.

What the fix is: the same note mechanism #582 used (`imm_note`,
`regload_note`, `push_left_reg`): after G1 the base and the index of a
subscript are both "one instruction from a register", so the subscript
emitter can note (base register, index register, scale, displacement)
and emit a single `mov rax,[base+index*scale+disp]` load or
`mov [base+index*scale+disp],rax` store; the field path notes (base
register, offset) likewise. `code_generator/x86.w` already has the
ModRM/SIB helpers (`emit_eax_esp_disp`, the REX helpers R2 added for
`r12`-`r15`) and `libs/asm`'s x64 decoder can verify every new encoding
form in `asm_fuzz_x64_test` as R2 did. Expected: `a[i]` read 6 → 1-2
instructions, `c.field` 3 → 1, element store 6 → 1-2.

### 2.3 G3: expression temporaries through push/pop

#582's R3 removed the `push`/`pop` pair when the right operand of a
binary operator is one simple instruction (a constant, a local load, a
register). Anything larger still pushes the left value, evaluates the
right into `rax`, pops into `rbx` and operates. SHA-256's rotate idiom
`((x >> 7) & 0x1ffffff) | (x << 25)` is the canonical case:

```
 805f81b: mov rax,r14        ; e
 805f81e: sar rax,0x6
 805f822: and rax,0x3ffffff
 805f828: push rax           ; <- left operand parked
 805f829: mov rax,r14
 805f82c: shl rax,0x1a
 805f830: pop rbx
 805f831: or rax,rbx
 805f834: push rax           ; <- parked again for the ^
 ...
```

24 pushes and 18 pops per round, 29% of the loop; 22% of
`__w_hash_sip`, 28% of `rx_here`, 37% of `wh_decode`. Each pair is
also a store-forwarding round trip on the critical path of the
expression.

What the fix is: a small *expression register stack*. Instead of
pushing a parked left value, keep it in the next free scratch register
of a fixed sequence (x64: `rcx rdx r8 r9 r10 r11`, minus whatever the
loop pass owns and minus `rcx`/`rdx` in an expression that contains a
variable shift, `/`, `%` or a call; x86-32: `ecx edx` under the same
rules) and spill to the real stack only when the sequence is
exhausted or a call is emitted. This is the classic cc500 → tcc step
and it fits the existing design exactly: `push_eax`/`pop_ebx`
(`x86.w:790-830`) are already the only two entry points and already
carry notes; `stack_pos` bookkeeping stays untouched because a parked
register occupies a *virtual* slot that the pop consumes before any
other slot arithmetic sees it. The right-operand folds of R3 remain
and compose (`add rax,rcx` instead of `pop rbx; add rax,rbx`). Expected:
every push/pop pair in a call-free expression becomes zero or one
`mov`; the SHA-256 round drops from 145 to roughly 100 instructions
before G1/G2 take their share.

### 2.4 G4: call overhead and no inlining

A direct call to a known function today:

```
 805f294: mov eax,0x805f099       ; callee address
 805f299: push rax                ; parked on the stack
 805f29a: mov rax,r15 ; push rax  ; each argument: materialise, push
 805f29e: mov rax,r13 ; push rax
 805f2a2: mov rax,[rsp+0x10]      ; reload the callee address
 805f2a7: call rax
 805f2a9: add rsp,0x18            ; pop callee + arguments
```

plus, in the callee, `push rbp; mov rbp,rsp`, four `push r12-r15` when
the function promotes anything, `lea rsp,[rbp-0x20]`, four pops, `pop
rbp`, `ret`; plus R3's spill/reload of loop-owned registers around the
call in the caller. For `bench_fold` (one multiply and an add) the call
is about 20 instructions of overhead around 3 of work; `inf_get_bit`
(one bit) is called once per input bit; `__w_size_add`
(an overflow check) is 12% of `inflate_corpus` on its own; a
`strcmp_sort` comparison is three nested calls
(`__w_list_sort_compare` → `__w_list_load_word` ×2 →
`__w_list_compare_values`). gcc inlines all of these.

What the fix is, in two units:

- **Direct calls.** When the callee is a known W function (the
  `callee_type == 4` branch of `finish_call`, `grammar/postfix_expr.w`
  line ~260), emit `call rel32` (`call_relative32` exists, `x86.w:775`)
  through the same forward-reference patch chain that `sym_get_value`
  already maintains for undefined globals, and drop the address push
  and reload: 5 instructions → 1 per call. Keep `call rax` for pointers
  and the FFI. (The prologue already pushes only the callee-saved
  registers the scan assigned: `__w_list_compare_values` pushes `r12`
  alone.)
- **Inlining of small leaf callees (P3 of #582's plan).** The AST
  dependency P3 waited on has landed in a usable form: S2.3 (#580)
  reparses generic instantiations and deferred expressions from
  retained token spans without seeking the source. A call to a function
  whose body is small (the plan's "under ~12 tokens", or a profile-hot
  callee under a size budget), has no loops, no calls, no `defer`,
  `goto`, `raw_asm` or asm block, and whose arguments are simple, is
  emitted by binding the arguments as fresh locals and re-parsing the
  callee's token span in place with `return` lowered to a jump to the
  call's end. The profile (`--profile-use`) decides which hot call
  sites get it; without a profile a size threshold does. Expected:
  removes `bench_fold`, `inf_get_bit`, `__w_size_add`,
  `__w_list_load_word`, `__w_hash_value_copy` and the hash table's
  `key_hash`/`key_equal` dispatch from the call graph, which is
  20-40% of `inflate_corpus`, `strcmp_sort` and `siphash_keys`.

### 2.5 G5: loop shape

Every `while` is top-tested with an unconditional `jmp` back to the
compare (two taken branches per iteration), there is no
loop-invariant hoisting (`i * n` in `matmul` is recomputed every
iteration, `table.capacity` reloaded every probe, `wh_maxbits` loaded
from memory every bit) and no strength reduction (an induction
variable that only ever indexes an array still goes through
`imul ,8`). gcc's loops are bottom-tested, hoist `i*n` to the middle
loop and walk `a` and `b` with pointer increments (§2.1's listing of
gcc's `.L7` loop is six instructions: load, `imul` with a memory
operand, two pointer adds, `add`, `cmp`/`jne`).

What the fix is: loop rotation is a note-level change in
`grammar/while_statement.w` (emit the condition at the bottom and enter
the loop with a jump to it; the existing branch fusion already gives
the `cmp`/`jcc` pair), saving one taken branch per iteration everywhere
and removing the `cmp`+`jge` 32-byte-boundary sensitivity R3 noted
(§11 of the regalloc doc). Invariant hoisting and strength reduction
need to see the whole loop before emitting it; that is wave B (§5.2),
on the retained tree.

### 2.6 Boolean materialisation in `&&`/`||`

`while ((table.states[i] != 0) && (probes < table.capacity))` emits
each operand as a full boolean (`cmp; setne al; movzx eax,al`), tests
it, then after the chain booleanises again (`test rax,rax; setne al;
movzx; test rax,rax; je`): eight instructions of flag shuffling per
condition. #427/§1.3 of `optimization.md` fused the *bare* comparison
case with `be_br_zero_discard`; `logical_and_expr` deliberately keeps
`be_br_zero` because its taken edge carries the operand value to the
final `setne`. In condition context (an `if`/`while` header) nothing
needs the value, so the chain can branch straight on each comparison's
flags to the false label and the final booleanise disappears. Affects
`rx_here` (73 branch/compare instructions out of 394),
`__w_hash_table_slot`, `__w_list_compare_values`.

### 2.7 The long tail

- **32-bit arithmetic on the 64-bit word.** `lib/sha256.w` and the
  SipHash body keep every value masked (`& mask` after each add/shift)
  and spell rotates as two shifts, a mask and an `or` because `int` is
  64 bits on x64. Two cheap moves: use the existing `rotl`/`rotr`
  intrinsics (`grammar/bit_builtin.w`; `__w_hash_sip` already does,
  `sha256_block_w` does not), and promote `int32`/`uint32` locals on
  x64 with 32-bit operations (`add r12d,...` zero-extends for free), so
  code written in 32-bit types needs no masks at all. The scan declines
  narrow types today (`regalloc_type_ok`). This is the `uint32`
  arithmetic path #582's R4 left open.
- **x86-32.** Only `esi`/`edi` promote and no loop owns registers (R3:
  "x86 gets no loop registers"), because the shift-by-variable and
  division sequences use `ecx`/`edx`. The scan already records the
  per-loop hazard bit (`rs_lp_has_divshift`); R4 proper is to hand
  `ecx`/`edx` to loops without that hazard and `ebx` to functions
  whose expressions never need the shuttle after G3. The x86 column
  matters for the seed-compiled compiler itself (the bootstrap chain
  is x86); for the corpus x64 is the target.
- **Constants and conditions**: `xor`-zeroing, `mov R,imm` without the
  `eax` detour, `cmp byte [R],0`, `test`/`jcc` on the flags of the ALU
  op that just ran. Each is a one-line note in `x86.w`; together they
  are perhaps 3-5% of the hot loops and worth doing as the examples
  come up in the diffs of the units above, not as a unit.
- **Global reads** are `mov eax,imm32; mov rax,[rax]` (an absolute
  address through `eax`); `mov rax,[rip+disp32]` is one instruction
  and the ELF layout already knows the distance. Minor; matters for
  `const` globals that should fold as immediates (`wh_maxbits`).
- **The runtime's data-structure shapes.** `__w_list_merge_sort` and
  the hash table do kind-dispatch per element (`__w_list_compare_values`
  switches on `kind` for every comparison; `__w_hash_key_hash` on
  `key_kind` for every lookup) and `__w_list_addr` bounds-checks every
  element access. These are library designs, not codegen: a sort
  specialised per kind at the call site, or `sort()` on `list[char*]`
  going straight to a string comparator, would remove a third of
  `strcmp_sort`'s calls. Out of scope here except as a note: after
  G4's inlining the dispatch costs a compare, not a call.

## 3. Experiments that bound the units

### 3.1 G1 + strength reduction on `matmul_256`

The inner loop rewritten so the array bases are plain pointer locals
(which the scan already promotes when they are only dereferenced, never
subscripted) and walked by increments, i.e. what G1 and wave B's
strength reduction would produce from the original source:

```
int* ap = arow            # &a[i * n], hoisted to the j loop
int* bp = &b[j]
while (k < n):
	acc = acc + *ap * *bp
	ap = ap + __word_size__
	bp = bp + stride      # n * __word_size__, hoisted to the function
	k = k + 1
```

| build | Ir | best of 5, ms | vs today |
| --- | ---: | ---: | ---: |
| `matmul_256` as written, W x64 | 5.07 G | 411 | — |
| pointer-walking variant, W x64 | 3.06 G | 200 | 1.66x fewer instructions, 2.05x faster |
| `gcc -O2` | 1.18 G | 190 | — |
| as written, W x86 | 5.07 G | 374 | — |
| pointer-walking variant, W x86 | 4.40 G | 333 | 1.15x fewer, 1.12x faster |

The x64 variant is at gcc's wall time with 2.6x gcc's instruction
count because the loop is now bound by the two loads and the multiply,
not by issue: the remaining 18 instructions per iteration are G2's
`mov rax,R; mov rax,[rax]` pairs and G3's push/pop around the multiply.
On x86-32, with two callee-saved registers and no loop registers, the
extra pointer locals compete with `acc` and `k` for `esi`/`edi` and
the gain is small; that is the R4 budget problem (§2.7), not G1.

### 3.2 Pointer walking on `sieve`

The same rewrite on `sieve`'s strided store: Ir 1.66 G → 1.58 G on x64
(300 → 287 ms), and *worse* on x86 (1.68 G → 2.16 G, 286 → 384 ms) for
the register-budget reason above. The inner loop is already bound by
the stores (gcc's four-instruction version runs 237 ms), so `sieve` is
a program where the remaining gap is G5's loop shape and the memory
system, not registers. It is the control for not over-claiming: G1-G3
buy the most where the loop is issue-bound (`sha256`, `matmul`, the
hash and string loops), least where it is memory-bound.

### 3.3 What #582's own numbers say about G3

R3's "folds" step alone (the one-instruction right-operand fold) took
the corpus from 17% to 69% fewer instructions (regalloc doc §11, R3:
"most of it is the folds"). G3 is the same fold extended to the general
case, and the push/pop share left in the hot loops (22-37%, §2's table)
is the direct measure of what remains.

## 4. PR #579 (asm function bodies): what it covers, how it interacts

What it is: `asm x86:` / `asm x64:` / `asm arm64:` blocks opening a
function body, assembled by `libs/asm`, with a portable W body as the
fallback for other targets and for `--no-asm`. The compiler side is on
the PR; the stdlib bodies (`strlen`, `strcpy`, `strcmp`, their `__w_`
twins, `__w_hash_sip`, `__w_list_addr`, `sha256_block_w`) are in files
the pinned seed compiles, so they follow a release tag and a `SEEDS`
bump. Its measured effect is a 1.26-1.36x faster self-compile; per
function, 2.4-5.7x on the leaves it rewrites.

On the corpus, by the hot-spot table in §1:

| program | share in functions #579 rewrites | expected effect |
| --- | ---: | --- |
| sha256_1m | 75% (`sha256_block_w`) | the hand-written body is gcc-class; the program would land near the C twin's 122 ms plus `bench_rand`'s share |
| siphash_keys | ~41% (`__w_hash_sip` 38%, `__w_strcmp` 3%) | the hash becomes cheap; the table walk (`__w_hash_table_slot`, `rehash`, `value_copy`, `freelist_malloc`) stays as it is: perhaps 1.6x |
| strcmp_sort | ~9% (`__w_list_load_word` is not on the list; `__w_list_compare_values` is a separate function from `__w_strcmp`) | little, unless `compare_values` is added |
| inflate_corpus | ~12% (`__w_list_addr` is behind `__w_size_add`'s callers) | little |
| sum, sieve, matmul_256, regex_backtrack | 0% | none |

So #579 is the right tool for exactly two of the eight programs and for
the compiler's own hot leaves, and the wrong tool for everything a user
writes. The plan treats it as follows:

- **Land its compiler side first, rebased.** The PR is based on
  `4f0efd0`, five merges behind `main`, and a local merge against
  `d3c98ff` conflicts in five files: `compiler/compiler.w` (both PRs
  added an option block), `grammar/program.w` (both inserted a step at
  the top of the function body: #582's `regalloc_function_scan` and
  #579's `asm_function_body`), the two `tests/asm/corpus_*.txt` files
  and `ai_tooling_next_steps.md`. The `program.w` one is the real
  interaction and its resolution is the design rule: run
  `asm_function_body` first and skip the register scan and the prologue
  for a function whose body is the target's asm block (the block is the
  whole function; the scan must never hand a register to a body it does
  not emit). Beyond that, #582 changed the
  contract the PR's design already anticipated: asm bodies must preserve
  `esi`/`edi` (x86), `r12`-`r15` (x64) and `x19`-`x28` (arm64), and a
  block that jumps to `portable` must leave the callee-saved set and
  the stack exactly as the W prologue expects, since the W body now
  pushes those registers itself. `tests/asm_function_test.w` needs a
  case where an asm function is called from inside a loop that owns
  `rsi`/`rdi`/`r8`-`r11` (R3 spills them around every `call`, so this
  should already hold; the test pins it) and from a function with
  promoted locals.
- **Keep the portable bodies honest.** Add a `--no-asm` row to
  `tools/bench_vs_c.sh` and `bin/wbench --programs` once the stdlib
  bodies exist, so the compiler's own output on the portable W bodies
  stays measured and a codegen regression cannot hide behind an asm
  fast path. Each asm body is also the target for its portable twin:
  when wave A lands, the gap between `--no-asm` and default on
  `sha256_1m` is a direct measure of what the compiler still lacks.
- **Do not widen the asm surface to chase the corpus.** "Symbol
  references from blocks" (the PR's first follow-up) would open
  `__w_hash_table_slot`, `__w_list_push` and the allocator to asm, which
  is where G1, G4 and G6 already deliver most of the same win for every
  program. The one addition worth making is `__w_list_compare_values`'s
  string case, which is the `strcmp` loop under another name.
- **Sequence with the seed.** The stdlib bodies and any wave-A unit
  that changes `grammar/` or `code_generator/` both need the next
  release tag; neither depends on the other's syntax (wave A adds no
  syntax at all), so they can share a release.

## 5. The plan

Every unit below follows #582's rules: a note-based change in the
single-pass emitter, no new syntax (everything is under the seed
constraint, CLAUDE.md), x64 first with x86 where the budget allows,
arm64/win64/wasm output byte-identical unless the unit says otherwise,
on by default under the existing `--no-regs` / `-O0` opt-out (new
units add their own `--no-<unit>` only when a differential test needs
one), one owner for `code_generator/x86.w` per wave, and a dated
section appended to this document's §8 with the unit's measurements.
Gates for every unit: `./wbuild verify verify_x64 verify_arm64
verify_pgo`, `regalloc_diff_test` (extended to compare the new unit's
opt-out too), `asm_x64_test` / `asm_fuzz_x64_test` for any new
encoding, `./wbuild tests`, and `./wbuild bench_compare` with the
corpus numbers in the unit's section. Wall time informs, instruction
counts gate (`tests/bench/baseline.txt` is refreshed by the unit that
moves it, as `docs/testing.md` requires).

### 5.1 Wave A: finishing the register model (no AST dependency)

| unit | what | files | expected (x64 corpus) |
| --- | --- | --- | --- |
| **A1** pointer bases in registers (G1) | lift the subscript/field exclusion for word-sized pointer locals and arguments; subscript and field emitters read the base through the register path; loop-register ranking counts subscripts | `compiler/regalloc_scan.w`, `grammar/postfix_expr.w`, `code_generator/expression_ast.w` (the retained twin), `tests/regalloc_test.w` | matmul 5.07 → ~3.5 G, sieve 1.66 → ~1.5 G, sha256 −10%, inflate/siphash/strcmp −10-15% each |
| **A2** addressing modes (G2) | subscript note → `[base+index*scale+disp]` loads and stores; field note → `[base+disp]`; `shl` for power-of-two scales that cannot fold; `cmp byte [R],imm`; `xor` zeroing; `mov R,imm` | `code_generator/x86.w` (owner), `grammar/postfix_expr.w`, `libs/asm` corpus for the new forms | matmul → ~2.2 G, inflate −20%, hash/list runtime −15% |
| **A3** expression register stack (G3) | parked left operands in `rcx rdx r8-r11` (x86: `ecx edx`) with spill on exhaustion, call or hazard; `pop_ebx` consumes from the virtual stack first | `code_generator/x86.w` (owner, after A2 merges), `grammar/stack_slot.w`, `compiler/regalloc_scan.w` (loop pass yields the registers the expression pass needs) | sha256 5.37 → ~3.8 G, siphash −20%, regex −20%, inflate −15% |
| **A4** direct calls (G4a) | `call rel32` with a patch chain for known W callees; no callee-address push/reload | `grammar/postfix_expr.w`, `code_generator/x86.w`, `compiler/symbol_table.w` (reference chain kind) | every call −5 instructions: regex −8%, inflate −10%, strcmp −10% |
| **A5** inlining small leaf callees (G4b, P3) | token-span re-parse of small, loop-free, call-free callees at the call site, profile-ranked; `--no-inline` for the differential sweep | `grammar/postfix_expr.w`, `compiler/compiler.w` (span table from S2.3), `code_generator/retained_emit.w`, `profiles/` | inflate −30% (`inf_get_bit`, `__w_size_add`), strcmp −25%, siphash −15%, sieve −3% |
| **A6** branch-on-flags for `&&`/`||` in condition context (G6) | condition-context `logical_and_expr`/`logical_or_expr` branch per operand on the comparison's flags; no booleanise | `grammar/logical_and_expr.w`, `logical_or_expr.w`, `grammar/statement.w`/`while_statement.w` (the context flag) | regex −8%, hash table −10%, strcmp −10% |
| **A7** loop rotation (G5a) | bottom-tested `while`/`for`, entered by a jump to the condition; keeps the P2 alignment of the head | `grammar/while_statement.w`, `for_statement.w`, `code_generator/loop_ast.w` | one taken branch per iteration everywhere: sum 5 → 4 instructions/iteration, 2-5% across the corpus |
| **A8** narrow integer promotion and `ror` (§2.7) | `int32`/`uint32` locals in 32-bit registers on x64; `rotl`/`rotr` in `sha256.w`; `uint32` arithmetic without masks | `compiler/regalloc_scan.w`, `code_generator/x86.w`, `lib/sha256.w` | the portable `sha256_block_w` −30%; frees users from the `& mask` idiom |
| **A9** x86-32 budget (R4) | `ecx`/`edx` as loop registers where the scan's shift/division hazard bit is clear; `ebx` for functions whose expressions A3 keeps register-only | `compiler/regalloc_scan.w`, `code_generator/x86.w` | x86 rows catch up with x64: sum/sieve/matmul −20-30% on x86 |

Ordering and ownership: A1 and A4 can start together (different files);
A2 waits for A1 (it needs the register base), A3 waits for A2 (both own
`x86.w`'s operand model), A5 waits for A4 (it reuses the span table and
the direct-call bookkeeping), A6 and A7 are independent of all of them
and of each other (grammar files only), A8 and A9 come last because
they re-rank registers A1-A3 hand out. Three agents in parallel is the
practical width: one on `x86.w` (A1 → A2 → A3), one on calls (A4 →
A5), one on grammar shape (A6 → A7 → A8/A9).

Estimated end of wave A on x64, by adding the per-unit estimates above
with the overlaps removed (an instruction removed by A1 cannot be
removed again by A2): `sum` 3.0 → 2.4 G (gcc 1.2), `sieve` 1.66 →
1.3 G (0.59), `sha256_1m` 5.4 → 2.8 G (1.29), `siphash_keys` 4.9 →
2.6 G (1.18), `inflate_corpus` 5.2 → 2.3 G (0.99), `regex_backtrack`
6.7 → 3.8 G (2.54), `matmul_256` 5.1 → 2.0 G (1.18), `strcmp_sort` 3.6
→ 1.7 G (0.57). That is 1.5-3x gcc's instruction count instead of
2.5-6.3x, and by the wall-time/instruction relation in §1 (and §3.1's
direct measurement for matmul) a wall-time gap of about 1.2-2.5x with
`inflate_corpus` and `strcmp_sort` still the furthest behind, because
their remaining cost is library shape (§2.7) and gcc's deeper
inlining.

### 5.2 Wave B: loop transformations on the retained tree (after S2.5 / C3.5)

The AST plan (`ast_completion_plan.md`) makes retained emission the only
emitter in S2.5 and reserves C3.5 for "an optional tree-rewriting pass
slot for #110". The units that need to see a whole loop before emitting
it go there:

| unit | what | expected |
| --- | --- | --- |
| **B1** loop-invariant hoisting | expressions over loop-invariant names (no assignment in the loop, no call in the loop, or a call with the profile's "pure" bit) computed once in a loop register before the head | matmul `i*n`, hash `table.capacity`/`table.states`, inflate `c.in_data`: 5-15% |
| **B2** strength reduction of subscripts | an induction variable that only indexes becomes a pointer walk; the scaled `[base+index*8]` of A2 becomes `[ptr]` with `add ptr,8` | matmul to ~1.5 G, the gcc -O2 shape; sha256's message schedule |
| **B3** profile-driven inlining depth and cold splitting | A5's budget raised for hot call sites; `entries=0` functions moved after the hot ones (the regalloc doc's §3.4 non-goal, now possible with deferred emission) | inflate, strcmp: gcc -O2's inlining of two-level helpers |
| **B4** a real allocator | linear scan over the retained body's live ranges, replacing the token pre-scan's ranking: every scalar and pointer local, not the top k; register arguments for W-to-W calls | the remaining slot loads in `rx_here` (13%) and `merge_sort` (17%) |

Wave B's end state is gcc `-O1` on scalar code: by the `-O1` column in
§1 that is within 5% of `-O2`'s wall time on seven of the eight
programs and 25% on `inflate_corpus`.

### 5.3 What stays out of reach, and why that is fine

- **Vectorisation** (`matmul_256` under clang: 0.68 G; `sum` under
  clang: a closed form). W has no vector types and no IR to prove
  independence over; this is a different project (the `ndarray`/GPU
  work covers the use case differently).
- **Whole-function scheduling and register renaming across basic
  blocks.** Without an IR the plan's register model stays "one
  accumulator, scratch parking, promoted locals". The measured ceiling
  for that model is §3.1: at gcc's wall time with 2.6x its instruction
  count on an issue-bound loop, because modern cores retire the extra
  moves for free when the dependency chain is the same. The plan's
  honest target is therefore "within 1.2-1.5x of `gcc -O2` wall time
  on scalar code" rather than instruction parity.
- **Library shape** (§2.7): kind-dispatch in the containers, bounds
  checks, the freelist allocator. These are W design choices with
  their own trade-offs (traps on misuse, insertion order) and belong to
  the runtime's owners, not to codegen.

## 6. Risks

- **Fail-closed guard and the differential sweep are the only
  correctness net.** Every unit changes which instruction reads a value
  the previous instruction wrote; the fixpoint catches miscompiles of
  the compiler, `regalloc_diff_test` catches miscompiles of the suite,
  and neither catches a miscompile of code the suite does not exercise.
  A3 (expression registers) is the riskiest: it must give up its
  registers at every call, every hazard instruction and every
  `be_ctrl_*` join; the design rule is "a parked register never lives
  across a control-flow edge" (an `&&`/`||` operand, a conditional
  expression and a loop body are spill points), which keeps it local.
- **Compile-time cost.** #582's pre-scan cost 15% of compile wall time
  until C1 fixed its seeks. A5's re-parse of callee bodies is the only
  wave-A unit that adds parsing work; the size budget and the profile
  gate keep it bounded, and `tools/wbench.w` (`wbench_compare`) is the
  gate, as it was for #582.
- **x86-32 is the bootstrap target.** Units are x64-first, but the
  compiler is built as x86 by the seed; a unit that regresses x86 code
  slows every build. Measure both widths in every section.
- **The seed.** No unit adds syntax, so none waits on a release; but
  the stdlib bodies of #579 and A8's `rotr` in `lib/sha256.w` are
  seed-compiled files: A8's library edit needs the pinned seed to
  accept `rotr` (it does; the intrinsic predates the seed), #579's
  bodies need the release that carries its grammar.
- **Benchmarks as targets.** The corpus is eight programs; the
  self-compile (`./wbuild bench`'s `self` row) is the ninth and the
  one users feel. Every unit's section reports both; `wbench_compare`
  guards compile time.

## 7. Recommended order of work

1. Rebase and land #579's compiler side with the callee-saved test
   cases (§4); tag the next release; bump `SEEDS`; land the stdlib asm
   bodies with the `--no-asm` benchmark row.
2. Wave A in three parallel lanes (§5.1): A1 → A2 → A3 on the emitter;
   A4 → A5 on calls; A6 → A7 → A8 → A9 on grammar shape. Each unit
   appends its measurements to §8 and refreshes `tests/bench/baseline.txt`
   and `profiles/` where its output moved them.
3. Add the bench job to CI from `regalloc-pgo/ci-bench.patch` (#582 could
   not push workflow changes) so wave A's numbers are recorded per merge.
4. Wave B behind S2.5/C3.5 of the AST plan.

## 8. Landed units

(Appended by each unit, dated, with the §1 tables re-measured.)

### A4 — direct calls, `call rel32` to known W functions (2026-10-07)

What landed (x86 and x64 Linux ELF, and win64 PE by sharing the
emitter; arm64, `arm64_darwin` and wasm images are byte-identical to
before):

- **The call shape.** A call whose callee is a known W function
  (symbol type 2, 'D' or 'U', not a kernel, not `thread_local`; or a
  generic instantiation) is one `call rel32` (`call_direct_to` /
  `call_direct_link`, `code_generator/x86.w`). The callee-address
  `mov eax,imm; push` before the arguments and the `mov eax,[esp+N];
  call eax` after them are gone, and the `add esp` after the call no
  longer pops a callee word: five instructions and one stack word per
  call become one instruction. Calls through function pointers,
  struct-member callees, `cast(...)` expressions, C imports, C
  variadics, dynamic imports and every non-x86 ISA keep the `call eax`
  shape. `--no-direct-calls` (whole-program, a `link_option`) restores
  the old shape exactly: with it the x86 and x64 self-host images are
  byte-identical to the base commit's, and `regalloc_diff_test` now
  asserts the same for every program it already sweeps (a third
  `.nodirect` build per program, compared byte-for-byte against the
  image a `--no-direct-calls`-built compiler produces).
- **Forward references.** An undefined callee links its `rel32` slot
  into a per-symbol chain (`compiler/symbol_table.w`, record field
  150; `symbol_data_size` 150 → 154), patched by
  `sym_define_global_at` through `rel_chain_patch` (displacement =
  address − (slot + 4)), the twin of the existing `mov imm` chain.
  Generic instantiations (`grammar/generic.w`, `rel_chain` on the
  instantiation record) and the lazily imported runtime helpers
  (`grammar/lazy_runtime.w`, `rel_chains`) keep their own chains and
  patch them when the body lands; the REPL's late-binding registry
  (`repl/core.w`) records a slot kind and writes a displacement for
  kind 1.
- **The call record.** Every call now records itself on a small stack
  (`grammar/stack_slot.w`: base slot, kind, id, aux — kind 0 an
  indirect call whose callee word was pushed, 1 a symbol, 2 a generic
  instantiation, 3 a lazy runtime helper) and `finish_call` /
  `rt_call_end` pop their own record and assert the base matches
  (`internal error: call record does not match`). Keying by base alone
  was ambiguous: a call's first argument can begin another call at the
  same base. The pending callee between the identifier and the `(` is
  a note keyed on `codepos` (`direct_callee_kind/id/end`,
  `code_generator/code_emitter.w`); `emit()` fails closed (`internal
  error: direct call target '<name>' used by an unhandled path ...`)
  if any byte is emitted while a note is current, `peep_rollback`
  drops a note it rolls past, and `primary_expr` materialises the note
  as an ordinary function value when no `(` follows. A bare callee
  wrapped in parentheses — `(f)(x)`, `((f))(x)` — keeps the note
  across the `)` that closes the group it filled (a token-serial
  match, no lookahead), and an explicit generic call whose
  instantiation already has a body is noted like any other known
  function, because the AST emitter drops grouping and the two
  emitters must agree byte-for-byte (`ast_expression_test`).
- **R3 and the frame.** `regalloc_call_spill` / `regalloc_call_reload`
  wrap the direct call exactly as they wrap `call eax`; a loop-owned
  register is still spilled around it (`dc_loop_calls` in the test
  shows `mov [rbp+0x10],rsi; call <__w_list_addr>; mov rsi,[rbp+0x10]`).
  Argument slots below the base are addressed with `lea_slot` /
  `load_slot` instead of `s - 1` arithmetic, since no callee word is
  parked. `emitted_call_count` (PGO) counts direct calls too.
- **Both emitters.** `code_generator/expression_ast.w` (the retained
  emitter: `--ast-required`, `--ast-emit-retained`, the REPL) makes the
  same decision from the same `direct_callee_ok` predicate at its 'C',
  'W', 'G', 'z', 'F' and print/template sites; `verify_pgo`'s
  `wv3_pgo_ast == wv3_pgo` and `ast_expression_test`'s legacy/AST
  image parity over every fixture pin that.
- **Decoder.** `libs/asm/x86_decode.w` read disp32 and rel32 fields
  as unsigned on a 64-bit host, so `bin/wdbg`'s `disas` printed a
  backward `call rel32` as `call .+0xffffff87` and `debug_test_x64`
  failed (no backward `call rel32` existed in a W image before). It
  now sign-extends (`asm_x86_s32`); `asm_x64_test` (3,968 functions,
  435,293 instructions, 0 unknown, 0 mismatch) and the asm fuzz
  targets cover the encoder/decoder round trip.
- Tests: `tests/direct_call_test.w` (+ `_64` twin, and a
  `--no-direct-calls` build of the same program as extra steps) covers
  forward references, recursion, prototypes defined later and in an
  imported file, nested calls as arguments, struct-returning callees,
  methods and operator overloads, W variadics, explicit/inferred/forward
  generics and an instantiation calling an already-instantiated one,
  an asm-body callee (#579), function values and parenthesized
  callees, loops with register-owned locals, `defer`, generators and
  the lazily imported runtime helpers.

Measurements (`./wbuild bench`: callgrind Ir in thousands, which is
deterministic; best-of wall ms on the shared 4-core container with
other agents' builds running, so the ms columns are noise-level
evidence only; `bytes` is the ELF size; before = `main` at 1335f06):

x64

| program | kIr before | kIr after | ΔIr | ms before | ms after | bytes before | bytes after |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `sum` | 3,000,254 | 3,000,254 | +0.0% | 191 | 210 | 211,592 | 203,400 |
| `sieve` | 1,664,276 | 1,647,240 | −1.0% | 349 | 259 | 211,592 | 203,400 |
| `sha256_1m` | 5,373,446 | 5,253,121 | −2.2% | 332 | 335 | 219,792 | 211,600 |
| `siphash_keys` | 4,849,412 | 4,690,602 | −3.3% | 869 | 838 | 215,688 | 203,400 |
| `inflate_corpus` | 5,179,840 | 4,791,395 | −7.5% | 368 | 306 | 281,512 | 269,224 |
| `regex_backtrack` | 6,682,831 | 6,453,595 | −3.4% | 455 | 402 | 223,880 | 215,688 |
| `matmul_256` | 5,065,035 | 5,063,658 | −0.0% | 368 | 363 | 215,696 | 203,408 |
| `strcmp_sort` | 3,609,401 | 3,405,300 | −5.7% | 521 | 499 | 211,592 | 203,400 |

x86

| program | kIr before | kIr after | ΔIr | ms before | ms after | bytes before | bytes after |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `sum` | 3,000,259 | 3,000,258 | −0.0% | 239 | 196 | 181,572 | 173,380 |
| `sieve` | 1,683,750 | 1,666,714 | −1.0% | 318 | 279 | 181,572 | 173,380 |
| `sha256_1m` | 5,586,837 | 5,466,512 | −2.2% | 394 | 397 | 185,672 | 177,480 |
| `siphash_keys` | 4,575,623 | 4,420,135 | −3.4% | 684 | 726 | 181,572 | 173,380 |
| `inflate_corpus` | 5,357,384 | 4,969,281 | −7.2% | 392 | 331 | 239,060 | 226,772 |
| `regex_backtrack` | 6,600,523 | 6,371,287 | −3.5% | 425 | 367 | 189,764 | 181,572 |
| `matmul_256` | 5,068,987 | 5,067,610 | −0.0% | 333 | 324 | 181,576 | 173,384 |
| `strcmp_sort` | 3,605,684 | 3,402,203 | −5.6% | 441 | 442 | 181,572 | 173,380 |

Self-compile, same input for both compilers (the base commit's source
tree, compiled from a checkout of 1335f06, so the `self` row of
`bench.txt` — which compiles the current, larger tree — is not the
comparison): callgrind Ir of `wv3 --quiet w.w` 6,743,941,970 →
6,450,379,663 (−4.4%), and of the x64 compiler compiling `x64 w.w`
6,708,082,896 → 6,475,835,007 (−3.5%). Compiler image (`objdump -d
-Mintel`, lines with an opcode): x86 `bin/wv3` 584,144 → 497,012
instructions (−14.9%), 2,744,884 → 2,527,852 bytes (−7.9%); x64 image
576,400 → 488,250 instructions (−15.3%), 3,130,576 → 2,880,728 bytes
(−8.0%); `call eax` sites in the x86 image 29,378 → 678 and `call rax`
in the x64 image 29,562 → 686 (the survivors are function pointers,
the C-import shims, the hash table's `key_hash`/`key_equal` dispatch
and the generator/`new` paths listed below).

Static before/after for the hot loop of `inflate_corpus`
(`libs/extras/compress/inflate.w`, `wh_decode` line 242 `code = code |
inf_get_bit(c)`, x64, `objdump -d -Mintel`; the whole `inflate_corpus`
image has 1,736 `call rax` before and 217 after):

```
before                                     after
 mov    rax,r12                             mov    rax,r12
 push   rax                                 push   rax
 mov    eax,0x806429e      ; callee          mov    rax,QWORD PTR [rsp+0x60]  ; c
 push   rax                ; parked          push   rax
 mov    rax,QWORD PTR [rsp+0x68]  ; c        call   8061926 <inf_get_bit>
 push   rax                                 add    rsp,0x8
 mov    rax,QWORD PTR [rsp+0x8]   ; reload   pop    rbx
 call   rax                                 or     rax,rbx
 add    rsp,0x10
 pop    rbx
 or     rax,rbx
```

The plan's §2.4 expectation for this unit alone (x64:
`regex_backtrack` −8%, `inflate_corpus` −10%, `strcmp_sort` −10%) was
not met in full: −3.4%, −7.5% and −5.7%. The per-call saving is the
five instructions predicted; what the estimate over-counted is how
much of those loops is the call *shape* versus the callee's own
prologue/epilogue and R3's spill/reload around the call (both
untouched here — the inlining unit, A5, is what removes those). `sum`
and `matmul_256` have no calls in their loops and are unchanged to
within one instruction.

What this unit does not claim:

- `new T` / `__w_new_object`, the `malloc` inside
  `buffer_push_range_descriptor`, `str_from_cstr` coercions, generator
  calls and the C-variadic path keep their indirect shape (each emits
  its callee outside `finish_call` and records a kind-0 call, see
  `direct_call_record(s, 0, 0)` in `code_generator/expression_ast.w`
  and `grammar/`). A forward generic call (`generic_forward_call_expr`,
  resolved at the drain) stays indirect too.
- Inlining (A5) is not started; `inf_get_bit`, `__w_size_add`,
  `bench_fold` and the sort comparators are still calls.
- win64 (`tests_win64`, `verify_win`) could not be run here: wine is
  not installed on the container. The PE emitter shares the x86-64
  code emitter, so win64 images change in the same way (`call rax`
  29,623 → 686 in the win64 self-host image, 3,145,728 → 2,891,776
  bytes) and need a wine run before release.

Deviations from the plan's sketch: (1) every call records itself
rather than only direct ones, because the base slot alone does not
identify a call; (2) the lazily imported runtime helpers (`print`,
f-strings, `var`, JSON, the bounds-check trap) are direct calls too,
through their own chains, since they are among the hottest helper
sites in the self-compile; (3) the REPL late-binding hook gained a
slot kind; (4) the `libs/asm` decoder fix above; (5) win64 changed
(as the plan allowed) and is unverified for lack of wine.

Gates: `verify`, `verify_x64`, `verify_pgo`, `verify_arm64`
(qemu-user-static), `regalloc_diff_test` (0 mismatches over 408
compared builds), `asm_x64_test`, `asm_fuzz_x86_test`,
`asm_fuzz_x64_test`, `ast_expression_test`, `direct_call_test` +
`_64`, `git diff --name-only 1335f06 | bin/wtest changed` (41
targets), `./wbuild tests` (921 targets).

## 9. Reproducing

```sh
./wbuild build                                     # bin/wv2 (x86), seed-bootstrapped
tools/bench_vs_c.sh -n 5                           # §1 tables (gcc -O2 / clang -O2, callgrind)
for p in sum sieve sha256_1m siphash_keys inflate_corpus regex_backtrack matmul_256 strcmp_sort; do
	gcc -O0 -o /tmp/$p.O0 tests/bench/c/$p.c; gcc -O1 -o /tmp/$p.O1 tests/bench/c/$p.c
done                                               # the -O0/-O1 columns; time with the script's loop
callgrind_annotate bin/bench_vs_c/<p>.w_x64.callgrind | head -20   # §1 hot spots (nm -n maps the addresses)
bin/wv2 x64 tests/bench/matmul_256.w -o /tmp/mm && objdump -d -Mintel /tmp/mm   # §2 listings
```

The `matmul_256` and `sieve` variants of §3 are the programs in
`tests/bench/` with the inner loop replaced by the pointer-walking
version quoted in §3.1 (and `char* p = composite + j; *p = 1; p = p + i`
for `sieve`); they print the corpus checksums and are not committed,
since they measure a hypothetical emitter, not the compiler.
