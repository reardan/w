/*
x86-64 property/fuzz round-trip test (issue #171): randomized extension
of asm_x64_test's corpus round-trips, exercising REX prefixes, r8-r15
and RIP-relative addressing through mutated operands. Shares its driver
with tests/asm_fuzz_x86_test.w via tests/asm_fuzz_x86_common.w — see that
file's header for the mutation/round-trip design and tests/
asm_fuzz_prng.w's header for how a failure reproduces from the fixed
seed.

Checks, per generated instruction: decode(encode(insn)) == insn and
parse(format(insn)) == insn. Default iteration count is CI-budget-modest;
set W_ASM_FUZZ_ITERS for a larger manual batch, e.g.:

	W_ASM_FUZZ_ITERS=200000 ./bin/asm_fuzz_x64_test

docs/projects/assembler_disassembler.md.
*/
import lib.lib
import lib.assert
import libs.asm.insn
import tests.asm_fuzz_prng
import tests.asm_fuzz_x86_common


int main():
	asm_fuzz_x86_run(c"tests/asm/corpus_x64.txt", ASM_ARCH_X64(), 8, 16, c"x64")
	println(c"asm_fuzz_x64_test passed")
	return 0
