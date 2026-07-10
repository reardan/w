# Assembler / Disassembler Libraries (x86, x64, arm64)

Status: **x86 (32-bit) + x86-64 + arm64 (A64) complete: foundations +
disassembler + assembler** (issues #164, #165, #166, #167, #168).
`libs/asm/` has the insn model, byte buffer, labels/fixups, register
tables, hex + corpus utilities, cross-arch ELF section reader (#164), the
shared x86/x64 decoder + Intel formatter (#165/#167), the encoder + text
parser (#166/#167), and a separate bitfield-driven arm64 decoder/encoder/
formatter/parser (#168). Coverage:

- `asm_x86_disasm_test` — 345-entry corpus decode round-trip + a
  zero-`.byte` sweep of every function in the self-hosted `bin/wv2`
  (1982 functions / 268k instructions), recognizing the codegen's inline
  string-literal data via the `call`-over-data idiom.
- `asm_x86_asm_test` — corpus semantic round-trip (parse→encode→
  decode→format reproduces every canonical text) plus a **byte-exact
  decode→encode identity over all 268k `bin/wv2` instructions**: the
  encoder reproduces the compiler's exact bytes, carrying the recorded
  displacement/operand widths so even the compiler's non-minimal forms
  (disp32 for small offsets) round-trip.
- `asm_x64_test` — the same two properties in mode 8 (`tests/asm/
  corpus_x64.txt`, 227 entries): REX prefixes, r8–r15, 64-bit operand
  sizes, `movsxd`/`movabs`/`cqo`/`syscall`/`movq`, and RIP-relative
  addressing (`[rip+disp32]`, encoded as `asm_operand.base ==
  ASM_BASE_RIP()`). The golden test is a byte-exact decode→encode
  identity over every function of an ELF64 self-host build (`bin/wv2_64`,
  ~268k instructions, zero unknown / zero mismatch). The x64 decoder and
  encoder reuse the x86 core through the `mode` / `insn.arch` parameter
  and per-form REX helpers, mirroring how the x64 codegen reuses
  `code_generator/x86.w`.

`asm_seed_gate` keeps the whole library seed-compilable (it now exercises
a mode-8 REX.W decode+encode and an arm64 word decode/encode too). Epic:
#163; the remaining phase (wdbg #169) is tracked in its sub-issue.

**Stub generation complete (issue #170).** The runtime stubs in
`code_generator/{x86,x64,arm64}_asm.w` now have assembly-text sources
(`tests/asm/stubs_{x86,x64,arm64}.asm`) assembled by `libs/asm/stubgen.w`;
`tools/gen_stubs.w` prints the `emit(n, c"...")` / `a64(op(...))` lines
and `asm_stubs_test` is the drift test — see "Maintaining the runtime
stubs" below. `debugger/convert.w` (the objdump-parsing crutch this
replaces) is retired. Bugs surfaced by making the stubs assemble:
`swap_endian16` shifted ebx instead of eax (#175), `arm64_add_x9_imm`
pre-set imm12 bit 0 so even immediates encoded `#(imm|1)` (#174), and
`store_context`'s `emit(9, ...)` counted 9 bytes for an 8-byte string,
emitting the terminating NUL as a stray trailing byte.

**arm64 (A64) complete: decoder + formatter + encoder + text parser
(issue #168).** `libs/asm/arm64_decode.w` decodes one little-endian 32-bit
word (bitfield-driven, a separate decoder family from the x86 byte stream)
into the arch-neutral `asm_insn`; `arm64_format.w` renders canonical A64
text (`arm64_text.w` parses it back); `arm64_encode.w` emits the word.
Coverage:

- `asm_arm64_test` — the 151-entry `corpus_arm64.txt` round-trips
  decode→format (all 151) and parse→encode (all 151 byte-exact), plus a
  golden decode→encode identity over an arm64 self-host build
  (`bin/wv2_arm64`, built host-side; no qemu since nothing executes):
  1984 functions / 309077 instructions, **zero `.word` unknowns**, and
  decode→encode reproduces every word. Inline string-literal and
  literal-pool data is recognized via the compiler's branch-over-data idiom
  (`bl`/`b` over padded bytes, `ldr [pc,#8]` + `b`) and skipped.
- Of the 309077 instructions, 309037 are re-encoded *semantically* from
  decoded operands; **40 are recognized-but-opaque** (16 `madd`/`msub` with
  a live accumulator, 24 scalar-FP `fp` ops) — decoded to their real
  mnemonic with the raw word stashed in `asm_insn.raw` and re-emitted
  verbatim, so identity still holds byte-for-byte. These opaque forms format
  as a bare mnemonic without operand detail; modeling their operands (and
  the bitmask/bitfield-immediate, ccmp, csel-family forms the compiler does
  not exercise in its own code) is a follow-up if a richer arm64 disassembly
  view (wdbg #169) needs it.
- The `binutils-aarch64-linux-gnu` recommendation was dropped from
  `AGENTS.md`: this disassembler covers the compiler's arm64 output
  host-side with zero unknown opcodes, no cross toolchain required.

Corpus correction made while implementing #168: zero-offset loads/stores
were harvested inconsistently (`ldr x2,[x28,#0]` vs `ldr x9,[x28]`), so a
single word could not round-trip through one formatter. Canonicalized on
the objdump-style `[Xn]` (omit `#0`), matching the entry-stub
`ldr x13,[x12]`; the 7 `,#0]` entries were corrected.

## Why

The need shows up in four places today:

- **Hand-hexed runtime stubs.** `code_generator/x86_asm.w`, `x64_asm.w`
  and `arm64_asm.w` are raw `emit(n, c"\x8b\x44...")` byte strings with
  the intended assembly living only in comments. Editing one means
  assembling by hand or round-tripping through binutils.
- **`debugger/convert.w`** is a self-described hack that tokenizes
  `objdump -d` output and prints `emit(...)` lines — an external-toolchain
  crutch for the same job.
- **wdbg has no disassembly view.** Breakpoints, `si` stepping and the
  attach mode (issue #123, `docs/projects/debugger_attach.md`) show
  registers and source lines but cannot show the instructions at the
  stop site. `docs/todo.txt` lists "debugger: asm/disasm helpers".
- **Dev-time disassembly needs binutils.** `AGENTS.md` recommends
  `binutils-aarch64-linux-gnu` for ARM64 work; an in-house disassembler
  removes that dependency, in the spirit of the no-assembler/no-linker
  toolchain.

There is also an old prototype, `tests/asm.w` + `tests/asm_test.w`
(`asm_test` in build.json): a tokenizer-based text assembler that only
ever learned `pushad/popad/ret/nop`. This project supersedes it.

## Shape of the library

New directory `libs/asm/` (sibling of `libs/extras/`), one shared core
plus per-ISA modules. Everything is written in **seed-compatible syntax**
from day one: the endgame consumers (`debugger/`, potentially
`code_generator/`) sit in `w.w`'s transitive import graph, and seed-safe
syntax is cheap insurance compared to a later rewrite.

```
libs/asm/
  insn.w        # arch-neutral: instruction struct (mnemonic, operands,
                #   length, bytes), operand model (reg/imm/mem/label),
                #   byte buffer, label + fixup patching
  x86_table.w   # shared x86/x64 opcode tables, register names
  x86_decode.w  # prefixes/REX + opcode + ModRM/SIB/disp/imm -> insn
                #   (mode parameter 32/64, mirroring how the x64 codegen
                #   reuses x86.w via REX helpers)
  x86_encode.w  # insn -> bytes, same tables
  arm64_decode.w  # fixed 32-bit words, bitfield-driven
  arm64_encode.w
  text.w        # text assembler: parse "mov eax,[esp+16]" -> insn
  format.w      # disassembler formatter: insn -> canonical text
```

Layering rule: decode/encode work on a structured `insn`, never on text.
wdbg links only decode+format; the stub generator links only text+encode;
tests link everything and round-trip.

**Syntax**: Intel-style, matching the comments already written throughout
`code_generator/` (`mov eax,[esp+16]`, `movsx eax, byte [eax]`). Those
comments become the initial test corpus for free. An AT&T/objdump-compat
formatter flag can come later if diffing against objdump is wanted.

**Scope control — subset first.** Not a full ISA. The supported subset is
"everything the W compiler emits, plus what wdbg encounters in practice",
enforced by a golden test: disassemble the entire `.text` of `bin/wv2`
(and the x64/arm64 builds) with **zero unknown opcodes**. Unknown bytes
decode gracefully to `.byte 0x..` so partial coverage never crashes a
consumer; the golden test is what ratchets coverage.

## Testing strategy

- **Round-trip**: `encode(parse(text)) == bytes` and
  `format(decode(bytes)) == canonical text` per-instruction tables, plus
  the whole-`.text` decode→encode identity property.
- **Differential vs the codegen**: assemble the `/* ... */` comment next
  to each `emit()` in `x86.w` / `*_asm.w` and compare against the
  committed hex. This doubles as an honesty check on those comments.
- **Coverage golden test**: zero-unknown disassembly of self-hosted
  compiler binaries per arch (arm64 decode runs host-side; no qemu
  needed since nothing executes).
- Usual harness: `tests/asm_*` targets in `build.json`, membership in
  the `tests` umbrella, `tools/test_map.w` entries. No new language
  syntax, so `tests/parser_generator/w.pg` is untouched.

## Compiler integration without touching the seed

Rewriting the `*_asm.w` stubs must not perturb self-hosting. Two options:

1. **(Recommended first)** an offline generator, `tools/gen_stubs.w`:
   reads assembly-text stub sources, prints the `emit(n, c"...")` lines.
   A drift test asserts regenerated output matches the committed files.
   `./wbuild verify` stays byte-identical; `libs/asm` stays out of the
   seed graph entirely. This also retires `debugger/convert.w`.
2. (Later, optional) `code_generator/` imports the assembler directly and
   the stubs become text. That pulls `libs/asm` into the seed graph
   (seed-syntax rule applies, `./wbuild verify` + possible `update` /
   `update_darwin` dance) and is a separate decision.

Inline `asm` blocks in the language, and REPL/JIT uses, are explicitly
**out of scope** for this epic — natural follow-ups once the encoder
exists.

## Maintaining the runtime stubs (issue #170)

The committed `emit()`/`a64(op())` bytes in
`code_generator/{x86,x64,arm64}_asm.w` stay the compiled artifact (the
seed graph is untouched), but their source of truth is now the
assembly-text files `tests/asm/stubs_{x86,x64,arm64}.asm`. To add or
change a stub:

1. Edit the `.asm` stub source: `func NAME` opens a stub, one
   instruction per tab-indented line in the canonical syntax above; a
   tab followed by `#` starts a trailing comment.
2. `./wbuild gen_stubs && bin/gen_stubs tests/asm/stubs_<arch>.asm`
   prints the `sym_define_declare_global_function()` + `emit(n,
   c"\x...")` lines (or `a64(op(...))` words with their assembly
   comments) to paste into the committed `*_asm.w` file.
3. `./wbuild asm_stubs_test` (also part of `./wbuild tests`) re-runs the
   drift check: it re-assembles the stub sources, re-extracts the
   committed byte strings, and fails on any difference — including an
   `emit(n, ...)` length that disagrees with its string's escape count
   (that mismatch class emitted a stray NUL in store_context for years).
4. `./wbuild verify` still gates the change like any other
   `code_generator/` edit.

The extractor understands the committed files' idioms, not general W:
`sym_define_declare_global_function(c"...")` and top-level `void f():`
lines delimit stubs, every `emit(n, c"\xNN...")` / `a64(op(0xAA,
0xBBBBBB))` in source text order contributes bytes (so both branches of
a `target_os`/`arm64_pac` conditional are listed in the stub source, and
the get_context register loop appears as its i=0 base word), and `#`
comment lines are inert. Keep new stub code within those shapes — or
extend `libs/asm/stubgen.w` alongside it.

## Canonical text syntax (Phase 0.2)

One grammar shared by the corpus fixtures, the formatter (#165) and the
text parser (#166). Everything is lowercase.

**x86/x64 (Intel order, dest first):**

- Registers by hardware name: `eax`/`ax`/`al` families, `rax`..`r15`
  (`libs/asm/registers.w` is the authority).
- Immediates: decimal (`18`) or hex (`0x12`); negative with leading `-`.
- Memory operands: `[base]`, `[base+disp]`, `[base-disp]`,
  `[base+index*scale]`, `[base+index*scale+disp]`; scale ∈ {1,2,4,8}.
- Size keywords `byte`/`word`/`dword`/`qword` before a memory or
  immediate operand only where the register operands leave the width
  ambiguous (`inc dword [esp+4]`, `push dword 0x12`).
- Operands separated by `,` with no space after the mnemonic's first
  space (`mov eax,[esp+16]`); instruction sequences join with ` ; `.
- Labels are bare identifiers in operand position (`jmp target`).

**arm64 (A64):**

- Registers `x0`..`x30`/`w0`..`w30`, `sp`/`wsp`, `xzr`/`wzr`.
- Immediates prefixed `#` (`add x9,x9,#16`), hex allowed (`#0x80`).
- Addressing: `[xN]`, `[xN,#imm]`, `[xN,xM]`; condition-coded branches
  as `b.cc .+8` (dot-relative displacement).

**Corpus fixture format** (`tests/asm/corpus_*.txt`, loaded by
`asm_corpus_load`): one `hexbytes|text` entry per line (lowercase hex,
no separators; arm64 words little-endian as stored), `#` comment lines,
blank lines ignored. `# MISMATCH:`-flagged entries record bytes whose
source comment disagreed with the actual encoding.

## Phase 0: shared prerequisites (do once, used by every sub-issue)

These are the tasks where skipping them means every arch issue re-does
the same research or invents its own local copy. They replace/expand the
"core scaffolding" sub-issue (#1 below).

1. **Instruction inventory + machine-readable corpus.** One sweep over
   `code_generator/` harvesting every `emit()` / `a64(op())` call and its
   assembly comment into per-ISA fixture files of `bytes ↔ text` pairs
   (e.g. `tests/asm/corpus_x86.txt`). This single artifact is:
   - the *scope definition* for issues 2-5 (what "the compiler subset"
     concretely is — no per-arch re-research),
   - the differential-test input for the assemblers,
   - the seed test vectors for the disassemblers,
   - an honesty check on the existing comments (any comment that doesn't
     assemble to its committed bytes is a latent doc bug worth finding
     before it seeds the tables).
2. **Canonical text syntax spec.** Write the operand grammar once, in
   this doc: register names, immediate/hex formatting, memory-operand
   shape (`[reg+disp]`), size keywords (`byte`/`word`/`dword`/`qword`),
   label references, and the arm64 flavor. The corpus format (P0.1), the
   formatter (issue 2), the parser (issue 3) and both extra arches all
   reference one spec instead of making four drifting ad-hoc decisions.
3. **Cross-arch binary section reader.** Generalize
   `lib/__arch__/*/elf_introspect.w` — which introspects the *running
   binary's own image* via arch dispatch — into a file-based reader that
   returns `.text` bytes + symbol boundaries for **any** target's binary
   (ELF32/ELF64/arm64 ELF; Mach-O later) regardless of host arch. Every
   golden test (issues 2, 4, 5), the stub drift test (issue 7) and
   wdbg attach symbolization want this; it must exist exactly once.
4. **Byte-diff test helpers.** `assert_bytes_equal` with a hex-dump diff
   on failure, plus the corpus fixture loader, in `lib/testing.w` or
   `libs/asm/test_util.w`. Every round-trip/differential test in every
   sub-issue asserts on byte buffers; without this each test grows its
   own hexdump.
5. **Mechanical seed-compat gate.** A `build.json` target that compiles
   `libs/asm` with the committed seed `./w` directly. Turns the
   "seed-safe syntax from day one" rule from review-time tribal
   knowledge into a cheap automated check that protects the later
   wdbg/codegen integrations.

One further decision belongs in Phase 0 but needs no research: pick the
**opcode-table representation** (data-driven struct/list tables shared by
encode and decode, vs. paired code) before issue 2 starts, since x86,
x64 and arm64 all inherit the choice.

## Issue breakdown

One parent (epic) issue tracking the project, with GitHub **sub-issues**
for each work package below and markdown task checklists inside each
sub-issue. The repo doesn't use labels; keep the existing title-prefix
convention (`Asm:` alongside `Debugger:` / `ParserGenerator:`).

Epic: **Asm: in-house assembler/disassembler libraries (x86, x64, arm64)**
— links this doc.

1. **Asm: shared foundations (`libs/asm/` + Phase 0)** — no per-ISA
   encode/decode logic yet.
   - [ ] instruction inventory → per-ISA corpus fixtures (Phase 0.1)
   - [ ] canonical text-syntax spec in this doc (Phase 0.2)
   - [ ] cross-arch binary section reader (Phase 0.3)
   - [ ] byte-diff test helpers + corpus loader (Phase 0.4)
   - [ ] seed-compat build gate for `libs/asm` (Phase 0.5)
   - [ ] instruction + operand structs, byte buffer, label/fixup patching
   - [ ] register name tables (x86/x64/arm64); opcode-table
         representation decided
   - [ ] build targets + empty test skeletons; retire `tests/asm.w`
         prototype (fold anything useful in)
2. **Asm: x86 (32-bit) disassembler** — depends on 1.
   - [ ] prefix/opcode/ModRM/SIB/disp/imm decode for the compiler subset
   - [ ] formatter (`format.w`) with canonical Intel output
   - [ ] golden test: zero-unknown decode of `bin/wv2` `.text`
   - [ ] instruction-length API (what wdbg's stepper needs)
3. **Asm: x86 assembler + text parser** — depends on 2 (shares tables).
   - [ ] `x86_encode.w` from structured insns
   - [ ] `text.w` parser
   - [ ] round-trip tests; differential test vs `x86.w`/`x86_asm.w`
         comment corpus
4. **Asm: x64 support** — depends on 2/3.
   - [ ] REX, extended registers, RIP-relative, 64-bit operand sizes
   - [ ] mode-64 decode + encode, golden test on the x64 self-host build
   - [ ] differential vs `x64.w` emissions and `x64_asm.w` stubs
5. **Asm: arm64 support** — depends on 1 only (parallel with 2-4). **Done
   (#168).**
   - [x] A64 word decode/encode for the `arm64.w`/`arm64_asm.w` subset
   - [x] golden test on the arm64 self-host build (host-side, no qemu)
   - [x] drop the `binutils-aarch64-linux-gnu` recommendation in AGENTS.md
6. **wdbg: disassembly view** — depends on 2 (x86) then 4/5 per arch.
   - [ ] `disas [addr|fn] [count]` command, in-process mode
   - [ ] instruction context at breakpoint/step stops
   - [ ] attach mode (#123) parity
   - [ ] seed-graph constraint honored; `./wbuild verify` byte-identical
7. **Codegen: stubs generated from assembly text** — depends on 3/4/5.
   **Done (#170).**
   - [x] `tools/gen_stubs.w` + drift test against committed `*_asm.w`
   - [x] retire `debugger/convert.w`
   - [ ] (separate decision, not in this epic: direct import into
         `code_generator/`)
8. **Asm: property/fuzz harness + docs** — ongoing once 3 lands.
   - [ ] randomized round-trip within the supported subset
   - [ ] `docs/todo.txt` inventory updates; README pointer

Suggested order: 1 → 2 → 3 → {4, 5 in parallel} → 6/7 as arches land;
8 trails. Items 2 and 6 deliver the first user-visible value (wdbg
disassembly); 7 removes the last binutils crutch.
