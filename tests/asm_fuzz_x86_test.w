/*
x86 (32-bit) property/fuzz round-trip test (issue #171): randomized
extension of asm_x86_asm_test's corpus round-trips. tests/
asm_fuzz_x86_common.w has the shared driver, mutation and reporting code
(shared with tests/asm_fuzz_x64_test.w, since the 32-bit and x64 paths
are the same decoder/encoder/parser/formatter family); this file just
seeds the corpus/arch/mode/register-count parameters for the 32-bit mode.

Checks, per generated instruction: decode(encode(insn)) == insn and
parse(format(insn)) == insn, with a fixed PRNG seed so a CI failure
reproduces byte-for-byte on re-run (see tests/asm_fuzz_prng.w's header
for exactly how). Default iteration count is CI-budget-modest
(ASM_FUZZ_DEFAULT_ITERS() in tests/asm_fuzz_prng.w); set W_ASM_FUZZ_ITERS
to run a much larger batch by hand, e.g.:

	W_ASM_FUZZ_ITERS=200000 ./bin/asm_fuzz_x86_test

Coverage grows for free as tests/asm/corpus_x86.txt grows: every
iteration samples a random corpus line as the instruction "form" to
mutate, so a newly added corpus entry is fuzzed the next time this test
runs, with no separate table to update.

docs/projects/assembler_disassembler.md.
*/
import lib.lib
import lib.assert
import libs.asm.insn
import tests.asm_fuzz_prng
import tests.asm_fuzz_x86_common


int main():
	asm_fuzz_x86_run(c"tests/asm/corpus_x86.txt", ASM_ARCH_X86(), 4, 8, c"x86")
	println(c"asm_fuzz_x86_test passed")
	return 0
