# Assembler / Disassembler Libraries (x86, x64, arm64)

Status: **planning** — no code yet. This doc is the design and the
issue-breakdown proposal.

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
5. **Asm: arm64 support** — depends on 1 only (parallel with 2-4).
   - [ ] A64 word decode/encode for the `arm64.w`/`arm64_asm.w` subset
   - [ ] golden test on the arm64 self-host build (host-side, no qemu)
   - [ ] drop the `binutils-aarch64-linux-gnu` recommendation in AGENTS.md
6. **wdbg: disassembly view** — depends on 2 (x86) then 4/5 per arch.
   - [ ] `disas [addr|fn] [count]` command, in-process mode
   - [ ] instruction context at breakpoint/step stops
   - [ ] attach mode (#123) parity
   - [ ] seed-graph constraint honored; `./wbuild verify` byte-identical
7. **Codegen: stubs generated from assembly text** — depends on 3/4/5.
   - [ ] `tools/gen_stubs.w` + drift test against committed `*_asm.w`
   - [ ] retire `debugger/convert.w`
   - [ ] (separate decision, not in this epic: direct import into
         `code_generator/`)
8. **Asm: property/fuzz harness + docs** — ongoing once 3 lands.
   - [ ] randomized round-trip within the supported subset
   - [ ] `docs/todo.txt` inventory updates; README pointer

Suggested order: 1 → 2 → 3 → {4, 5 in parallel} → 6/7 as arches land;
8 trails. Items 2 and 6 deliver the first user-visible value (wdbg
disassembly); 7 removes the last binutils crutch.
