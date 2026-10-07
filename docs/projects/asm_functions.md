# Assembly function bodies

A function can open its body with hand-written assembly for one or more
instruction sets. When the compile target matches a block, that block is
the function's machine code; every other target, and any build with
`--no-asm`, compiles the portable W body that follows. This is the
"inline asm functions" item from `docs/todo.txt`, scoped to what the
stdlib's hot paths need: whole-function bodies, not asm statements mixed
into W code.

```
int strlen(char* c):
	asm x86:
		"mov eax,[esp+4]"
		"mov edx,eax"
		"dec eax"
		"next:"
		"inc eax"
		"cmp byte [eax],0"
		"jne next"
		"sub eax,edx"
		"ret"
	asm arm64:
		"ldr x1,[x28]"
		"mov x0,x1"
		"next:"
		"ldrb w2,[x0],#1"
		"cbnz w2,next"
		"sub x0,x0,x1"
		"sub x0,x0,#1"
		"ret"
	int length = 0
	while(c[length]): length = length + 1
	return length
```

## Why

Profiling the self-compile and the whole `./wbuild tests` run with
`perf record -e cpu-clock` (October 2026) put a handful of small,
branchy stdlib and container-runtime functions at the top of every
profile: the SipHash behind every `map`/`set`, the bounds-checked list
element address, SHA-256 (the ELF build-id of every binary the compiler
writes), and the C string functions. They are leaves with simple
contracts, so assembly can keep everything in registers where the
single-pass code generator spills every expression through the stack.

Measured on the stdlib bodies that follow this PR (see "Staging"):
self-compile of `w.w` by a compiler built with the asm bodies vs. the
same sources built `--no-asm`, best of 9 runs:

| target of the compiler binary | portable | asm    | speedup |
|-------------------------------|----------|--------|---------|
| x86                           | 677 ms   | 535 ms | 1.26x   |
| x64                           | 715 ms   | 543 ms | 1.32x   |
| arm64 (qemu-user)             | 692 ms   | 509 ms | 1.36x   |

Per function, x86 self-compile, perf samples over five runs
(`cpu-clock`, 10 kHz; the whole run fell from 49,678 to 39,562 samples):

| function           | portable | asm   | speedup |
|--------------------|----------|-------|---------|
| `__w_hash_sip`     | 3,715    | 652   | 5.7x    |
| `sha256_block_w`   | 3,228    | 740   | 4.4x    |
| `strcpy`           | 725      | 168   | 4.3x    |
| `__w_strlen`       | 834      | 294   | 2.8x    |
| `strcmp`           | 2,283    | 871   | 2.6x    |
| `strlen`           | 317      | 134   | 2.4x    |
| `__w_list_addr`    | 2,361    | 1,002 | 2.4x    |
| `__w_strcmp`       | 1,135    | 586   | 1.9x    |

## Syntax

- `asm <isa>:` blocks come first in the body, one per ISA at most, each
  followed by an indented run of string literals (`"..."` or `c"..."`),
  one or more instructions per string separated by `;`. `#` comments
  after a string are ordinary comments.
- `<isa>` is `x86` (32-bit x86), `x64` (x86-64: Linux and win64) or
  `arm64` (Linux and Darwin). Anything else is an error even when the
  target would not have used it, so typos do not silently fall back.
- A portable W body must follow the blocks. It is what every target
  without a block (wasm, or an ISA the function has no block for) and
  every `--no-asm` build compiles.
- `asm` is not a keyword: it is only special as `asm <ident>:` opening a
  function body, so it stays usable as an identifier. An asm block
  after the first statement is an error rather than a mis-parse.

The parser-generator grammar (`tests/parser_generator/w.pg`) has the
form as `asm_block_stmt`.

## Syntax choices

New syntax was needed: the existing `raw_asm("\x..")` statement emits
raw machine-code bytes into a W body, which works for a trap or a
syscall but not for a function (no per-target selection, no labels, no
fallback, and the bytes run after the W prologue). The options weighed:

- **Whole-function blocks with a W fallback (chosen).** One source of
  truth per function, the W body doubles as the specification and the
  fallback for wasm and new ports, and `--no-asm` gives differential
  testing for free. Blocks are string lines so the tokenizer needs no
  new mode, `#` comments keep working, and the text goes through the
  same assembler and canonical syntax as the runtime stubs.
- **A top-level `asm name(args):` declaration with bare instruction
  lines**, as sketched in the unused `debugger/context.w` and the
  parser-generator grammar's `asm_decl`: no fallback and no
  per-ISA selection, and bare lines need a tokenizer mode for `[esp+4]`
  and friends.
- **Statement-level inline asm mixed with W** (GCC style): needs operand
  constraints and register-allocator cooperation that the single-pass
  generator does not have, and conflicts with the register-allocation
  work planned separately.
- **Separate `.s` files per ISA**: adds a second source of truth and a
  build-graph concept for something the existing assembler already
  handles in-process.

## Instruction text

Each line is assembled by the `libs/asm` text assembler, the same one
the runtime stubs use (`code_generator/asm_text.w`; canonical Intel
syntax for x86/x64, A64 syntax for arm64; see
`docs/projects/assembler_disassembler.md`). On top of that syntax the
block adds:

- **Named labels.** `name:` at the start of a line defines a label at
  the next instruction; any operand word naming a label refers to it.
  The block assembles twice to learn every instruction's position,
  rewrites label references to the assembler's dot-relative form, and
  relaxes x86 `jcc` from rel32 down to rel8 where the target is in
  reach (shrinking never pushes another branch out of reach, so the
  passes terminate). `jmp`/`call` to a label are always rel32.
- **`portable`**, a reserved label at the first byte of the W body.
  Jumping to it hands the call to the W body with the stack exactly as
  the caller left it, so an asm fast path can leave the rare cases
  (an out-of-range index that must trap, say) to W. A block that never
  names `portable` drops the W body from that target entirely.
- **`db 0xNN, ...`** for raw bytes on every ISA (tables, padding). An
  arm64 instruction after `db` bytes must still be 4-byte aligned.

Operands are checked before encoding, because the text assembler is
lenient: an unknown word is reported as an unknown register or label
(`r8d` in an x86 block, a misspelled register), and an arm64 mnemonic the
A64 encoder cannot build is an error instead of a silent zero word.

Diagnostics point at the offending string literal:

| message | cause |
|---------|-------|
| `unknown asm target 'sparc' (expected x86, x64 or arm64)` | bad ISA name |
| `duplicate asm block for 'x86'` | two blocks for one ISA |
| `an asm block's lines must be indented string literals` | empty block |
| `asm block lines must be string literals, found 'mov'` | unquoted line |
| `function 'f' needs a portable W body after its asm blocks` | no W body |
| `an asm block must open a function body, before its first statement` | block after a statement |
| `asm label 'x' is defined twice` / `asm label 'portable' is reserved for the portable W body` | label clashes |
| `undefined asm label in '...'` / `unknown register or asm label in '...'` | bad operand |
| `cannot assemble x86 instruction '...'` (and x64, arm64) | encoder rejected the line |
| `unknown arm64 branch condition in '...'` | `b.<cond>` typo |
| `arm64 instruction '...' is not 4-byte aligned (pad the db bytes before it)` | `db` misaligned the stream |

## Calling convention

A block is the function's whole entry: no prologue runs before it. It
sees W's internal calling convention, where arguments are pushed left to
right (the last argument is nearest the top of the stack) and the caller
pops them:

| ISA   | return address | argument k of n (1-based)        | result | return |
|-------|----------------|----------------------------------|--------|--------|
| x86   | `[esp]`        | `[esp + 4*(n-k+1)]`              | `eax`  | `ret`  |
| x64   | `[rsp]`        | `[rsp + 8*(n-k+1)]`              | `rax`  | `ret`  |
| arm64 | `x30`          | `[x28 + 8*(n-k)]` (x28 = W stack) | `x0`   | `ret`  |

Register rules for blocks:

- Preserve the platform's callee-saved registers (x86 `ebx esi edi
  ebp`; x64 `rbx rbp r12-r15`; arm64 `x19-x29`, including `x28`/`x29`).
  The code generator does not rely on all of them today, but the
  register-allocation work will, and following the platform ABI keeps
  the blocks valid when it lands.
- arm64: never touch `x18` (reserved on Darwin) and keep `x30` intact or
  restored before `ret`.
- Before `jmp portable`, restore everything the W body expects at entry:
  the stack pointer(s) and, on arm64, `x30`.
- `int` is the word size (`char` is signed on every target), and struct
  fields sit at word offsets; a block that reads a struct should have a
  test asserting the layout it assumes.

Blocks cannot yet name W symbols (call another function, load a
global): their text only reaches labels inside the block. That is the
main limit on which hot functions qualify (see the report below).

## `--no-asm`

`--no-asm` makes every function compile its portable body, for
differential testing and for debugging a suspected asm bug. Tests built
around asm functions run both ways: the default build exercises the
blocks, a `--no-asm` step exercises the W bodies.

## Staging (seed constraint)

`lib/lib.w`, `lib/sha256.w`, `structures/hash_table.w` and
`structures/w_list.w` are all in `w.w`'s import graph, so they are
compiled by the pinned seed, which predates this syntax. The feature
therefore lands in two steps:

1. The compiler support (`grammar/asm_function.w`,
   `code_generator/asm_body.w`, the `libs/asm` fixes it needed),
   `tests/asm_function_test.w`, the `asm_function_error_test` fixtures,
   and this document. Everything here builds under the current seed.
2. After a release is tagged at step 1 and `SEEDS` points at it, the
   stdlib bodies: `strlen`, `strcpy`, `strcmp` and their runtime twins
   `__w_strlen`/`__w_strcpy`/`__w_strcmp`, `__w_hash_sip`,
   `__w_list_addr` (x86, x64, arm64) and `sha256_block_w` (x86, x64;
   arm64 waits on immediate rotates in the A64 text assembler), with
   `tests/stdlib_asm_test.w` comparing each against a W reference with
   and without `--no-asm`.

## Report: the top 20 stdlib/runtime functions

Self time across every binary of a full `./wbuild tests` run (perf,
`cpu-clock`, x86 and x64 binaries aggregated; compiler-internal functions
such as `getc`, `peek` and `type_get_alias_target` excluded because they
are not stdlib). "Done" means an asm body in step 2.

| #  | function               | file                              | % of suite | status |
|----|------------------------|-----------------------------------|-----------:|--------|
| 1  | `__w_hash_sip`         | structures/hash_table.w           | 5.90 | done (x86, x64, arm64) |
| 2  | `__w_list_addr`        | structures/w_list.w               | 3.56 | done; out-of-range jumps to `portable` to trap |
| 3  | `sha256_block_w`       | lib/sha256.w                      | 2.87 | done (x86, x64); arm64 needs immediate `ror`/`lsr` in the A64 assembler |
| 4  | `strlen`               | lib/lib.w                         | 2.74 | done |
| 5  | `strcmp`               | lib/lib.w                         | 2.40 | done |
| 6  | `__w_hash_table_slot`  | structures/hash_table.w           | 1.79 | needs calls (hash, key compare) from asm |
| 7  | `__w_strcmp`           | structures/hash_table.w           | 1.62 | done |
| 8  | `strcpy`               | lib/lib.w                         | 1.35 | done |
| 9  | `__w_strlen`           | structures/hash_table.w           | 1.31 | done |
| 10 | `freelist_malloc`      | lib/memory_freelist.w             | 0.83 | needs globals and calls; better served by an allocator redesign |
| 11 | `bignum_divmod`        | libs/standard/crypto/bignum.w     | 0.71 | candidate: word-at-a-time division with `div`/`udiv` |
| 12 | `freelist_realloc`     | lib/memory_freelist.w             | 0.47 | as #10 |
| 13 | `bignum_mul`           | libs/standard/crypto/bignum.w     | 0.40 | candidate: widening `mul`/`umulh` inner loop |
| 14 | `__w_hash_key_hash`    | structures/hash_table.w           | 0.39 | needs calls; mostly dispatch into #1 |
| 15 | `__w_list_push`        | structures/w_list.w               | 0.30 | needs calls (grow path) |
| 16 | `__w_size_add`         | structures/hash_table.w           | 0.29 | tiny overflow check; better inlined by the compiler |
| 17 | `__w_hash_key_equal`   | structures/hash_table.w           | 0.25 | needs calls; dispatch into #7 |
| 18 | `malloc_low_bit`       | lib/memory_freelist.w             | 0.24 | candidate: one `bsf`/`rbit+clz` |
| 19 | `__w_map_contains`     | structures/hash_table.w           | 0.24 | needs calls |
| 20 | `malloc_bin_push`      | lib/memory_freelist.w             | 0.23 | needs globals |

Next in line: `x25519_fe_mul` 0.21, `__w_hash_slot_size` 0.21,
`__w_map_get` 0.21, `malloc_size_bin` 0.21. The kernel took 8.8% of the
suite (mostly `int 0x80` syscalls and `fork`/exec), and the
compiler's own tokenizer and type-table lookups (`getc`, `peek`,
`type_get_alias_target`, `accept`) sit above everything from #6 down;
those are code-generator and data-structure problems, not asm ones.

## Follow-ups

- Symbol references in blocks (`call name`, `mov eax,[global]`), which
  would open #6, #10, #14, #15, #17, #19 and #20 to asm.
- Immediate shifts and rotates (`ror`, `lsl`, `lsr` with `#imm`),
  logical immediates and `movk ..., lsl #n` in the A64 text assembler,
  for an arm64 `sha256_block_w` and simpler constants in the SipHash
  body.
- `bignum_divmod` / `bignum_mul` (#11, #13) and `malloc_low_bit` (#18)
  fit the current feature as they are.
- DWARF line rows per string line: blocks add none of their own today,
  so the debugger cannot step through a block line by line.
