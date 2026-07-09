/*
Seed-compatibility gate for libs/asm (issue #164, Phase 0.5): the
asm_seed_gate build target compiles THIS FILE WITH THE COMMITTED SEED
./w and runs it, mechanically enforcing that everything under libs/asm/
sticks to seed-understood syntax. That rule exists because the endgame
consumers (debugger/, potentially code_generator/) live in w.w's seed-
compiled import graph; see docs/projects/assembler_disassembler.md.

If this target fails to compile after a libs/asm change, the change
uses post-seed syntax and must be rewritten (or wait for a seed
refresh via ./wbuild update).
*/
import lib.lib
import lib.assert
import libs.asm.insn
import libs.asm.registers
import libs.asm.hexutil
import libs.asm.binary_reader


int main():
	# One touch per module so every file is pulled in and linked.
	asm_buffer* b = asm_buffer_new()
	asm_buffer_int32(b, 0x12345678)
	assert_equal(4, b.length)
	assert_equal(0x78, b.data[0] & 255)

	assert_equal(5, asm_reg_number(asm_reg_lookup_x86(c"ebp")))
	assert_equal(30, asm_reg_number(asm_reg_lookup_arm64(c"x30")))

	char* bytes = malloc(4)
	assert_equal(1, asm_hex_decode(c"c3", bytes, 4))
	assert_equal(0xc3, bytes[0] & 255)

	assert_equal(0, cast(int, asm_binary_open(c"tests/asm_seed_check.w")))

	println(c"asm_seed_check passed")
	return 0
