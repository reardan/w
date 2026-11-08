# Native inline assembly statements

A *statement-level* inline assembly form, with GNU (`asm volatile(...)`)
semantics, that emits its instructions **inline** in the surrounding W
function's machine code -- no separate assembler, no outlined helper
function, no call. It is the counterpart to the whole-function `asm
<isa>:` blocks (`docs/projects/asm_functions.md`): those replace a
function body, this interleaves a handful of instructions with ordinary
W code and binds W values to the instruction operands.

The audience is machine-level code that W must express directly: C
translators lowering GNU inline asm, and freestanding kernels, which use
inline asm for the privileged and atomic operations that have no
portable spelling (CPUID, the timestamp counter, `lock`-prefixed
read-modify-writes, flag-producing bit operations, memory barriers).

This document is the design. The first landed piece is the assembler
substrate it builds on (see "Status").

## Why inline, not outlined

A translator can already lower each GNU `asm` to a System V helper
function, assembled by an external assembler, with the operands marshalled
through registers and pointers at the call boundary. That works but costs
a call and a stack frame per statement, hides the instructions from W's
own code stream (so the frame-pointer unwinder sees an extra frame and a
`lea 1f(%rip)` yields an address inside the helper rather than the call
site), and depends on `as`. Emitting the instructions inline removes all
of that: the asm runs in the caller's frame with the caller's stack
pointer, and W keeps its own register state around it.

## Assembler strategy: native encoding (chosen)

The templates are assembled by W's in-house encoder (`libs/asm/`),
extended for the instruction and directive set a freestanding kernel
uses, so the object carries real machine code with no external
assembler. The alternative -- writing a gas-compatible side stream for
`--emit=obj` and splicing it -- is kept only as a fallback for genuinely
exotic templates (see "Fallback").

The substrate:

- `libs/asm/att.w` parses one line of **AT&T syntax** (source-first
  operands, `%reg`, `$imm`, `disp(%base,%index,scale)`, the `b/w/l/q`
  size suffix) into the architecture-neutral `asm_insn`, reversing it
  into the encoder's destination-first form. GNU inline asm is AT&T, so
  this is the template dialect.
- `libs/asm/x86_encode.w` encodes the integer/atomic/serializing
  instruction set (`asm_functions.md` lists the baseline; the kernel
  growth adds cpuid, rdtsc, the MSR/PMC reads, `lock`-prefixed ALU/bit
  forms, bit scans and tests, the fences, `xsetbv`, the flag
  instructions and the GNU condition-code synonyms).
- The two-pass label layout from `code_generator/asm_body.w` (size pass
  with every `jcc` long, then relax to `rel8`) resolves local labels
  inside a statement.

## Statement shape

A native inline-asm statement names, around the template text:

- **Inputs** -- a W expression evaluated into a chosen register (or, for
  a memory constraint, whose address is taken) before the template.
- **Outputs** -- a W lvalue written from a register (or a flag, via
  `set<cc>`) after the template; a read-write (`+`) output is loaded
  first.
- **Clobbers** -- registers the template destroys (`cc` and `memory`
  included); a clobbered callee-saved register is preserved around the
  statement, the rest come from the free pool.
- **Goto labels** -- W jump targets an `asm goto` may branch to.

W's single-pass code generator spills every expression through the
stack at statement boundaries, so an inline-asm statement is a register
hazard (like `raw_asm`, `grammar/regalloc_scan.w`): register promotion
is off in a function that contains one, which leaves the caller-clobberable
GP registers free for the asm and means W holds no live value in a
register across it. The statement therefore only has to preserve the
platform callee-saved set (`rbx rbp r12-r15 rsp`) and whatever the
clobber list and operand allocation reserve.

### Operand references and modifiers

The template references operands with `%N` / `%[name]` / `%lN`
(`asm goto` label) and the width/format modifiers GCC defines
(`%b %h %w %k %q` register widths, `%c %P %p %a` bare constant/address,
`%z` size suffix, `%V`, `%H`, `%%`, `%=`, and the `{att|intel}` dialect
alternative). The operand's substituted text (a register name at the
modifier's width, an immediate, a memory `(%reg)`) is produced before
`att.w` parses the resulting line.

### Constraints

The supported constraints are the register classes (`r q Q R`, the
fixed `a b c d S D`), memory (`m o V`), the immediates (`i n e Z I..O s`),
the generic `g X p`, the output markers `= +`, `&` (early clobber),
matching `"0"`, and the flag outputs `=@cc<cond>`. x87/SSE/mask-register
constraints and `"A"` pairs are out of scope (they fall back).

### Directives and sections

A kernel template often ends with `.pushsection`/`.popsection` blocks
(`__ex_table`, `__bug_table`, `.altinstructions`, `.smp_locks`,
`__jump_table`), numeric local labels (`1b`/`2f`) and raw data
directives (`.byte`, `.long`, `_ASM_EXTABLE`-style records). These do
not go through the instruction encoder: they are emitted as object
sections with relocations against the statement's inline instructions.
This is the largest remaining piece of the native path (it reuses the
object writer's section/relocation machinery, `code_generator/elf_object.w`).

## Fallback

A template the native path cannot assemble -- an unsupported constraint
or instruction, or a directive form the section emitter does not yet
handle -- is reported so the caller can fall back to the outlined form.
The fraction that falls back is expected to shrink as the encoder and
section emitter grow; it is reported per build.

## Seed constraint

The statement syntax is new, so it must not appear in any source the
committed seed compiles (`docs/release.md`). It is available to leaf
consumers once `bin/wv2` exists. The assembler substrate (`libs/asm/`)
stays seed-compilable, enforced by the `asm_seed_gate`.

## Status

- **Done**: the AT&T front end (`libs/asm/att.w`) and the kernel
  instruction-set encoder growth (`libs/asm/x86_encode.w`), with
  byte-exact tests against the GNU assembler (`tests/asm_att_test.w`)
  and seed-gate coverage.
- **Done**: the statement itself (`grammar/inline_asm_stmt.w`, the
  `asm_native:` block), its inline emission with input/inout/output and
  single flag-output operand binding, clobbers and the 1/2/4/8-byte
  widths, in both front ends and the parser-generator grammar. A gcc
  C-link test (`tests/native_asm_test.w`) checks each statement against
  the same operation in C inline asm. `verify`, `verify_x64`,
  `native_asm_test`, `parser_generator_w_test` and `wfmt_check` pass.
- **Next**: templates with local numeric labels and internal branches;
  the directive/section emitter (`.pushsection`, `.byte` records) and
  relocations for symbol operands and external calls, through the object
  writer (`code_generator/elf_object.w`); multiple flag outputs and
  `asm goto`; the per-build fallback report.
