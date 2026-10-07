# wbuild: x64 arch=arm64_darwin
# Structural ARM64 optimizer checks run on any host: exercise the actual
# backend and inspect its output without executing foreign instructions.
import lib.assert
import compiler.compiler


void arm64_fold_reset():
	be_notes_reset()
	codepos = 64
	target_isa = 1
	target_os = 1
	word_size = 8
	word_size_log2 = 3


void arm64_fold_word(int pos, int instruction):
	for i in range(4):
		assert_equal((instruction >> (i * 8)) & 255, code[pos + i] & 255)


void test_arm64_load_widths():
	int[7] instructions
	instructions[0] = op(0xf9, 0x400000)
	instructions[1] = op(0x39, 0x800000)
	instructions[2] = op(0x79, 0x800000)
	instructions[3] = op(0xb9, 0x800000)
	instructions[4] = op(0x39, 0x400000)
	instructions[5] = op(0x79, 0x400000)
	instructions[6] = op(0xb9, 0x400000)
	for i in range(7):
		arm64_fold_reset()
		be_lea_acc_wstack(24)
		if (i == 0): promote_eax()
		elif (i == 1): promote_int8_eax()
		elif (i == 2): promote_int16_eax()
		elif (i == 3): promote_int32_eax()
		elif (i == 4): promote_uint8_eax()
		elif (i == 5): promote_uint16_eax()
		else: promote_uint32_eax()
		assert_equal(68, codepos)
		int scale = (instructions[i] >> 30) & 3
		arm64_fold_word(64, instructions[i] | (28 << 5) | ((24 >> scale) << 10))
		assert_equal(24, load_note_disp)


void test_arm64_fields_and_limits():
	arm64_fold_reset()
	be_lea_acc_wstack(16)
	add_eax_int32(8)
	assert_equal(68, codepos)
	assert_equal(24, lea_note_disp)
	add_eax_int32(0)
	assert_equal(68, codepos)
	promote_eax()
	assert_equal(68, codepos)
	arm64_fold_word(64, op(0xf9, 0x400380) | (3 << 10))
	# A direct word load reaches farther than the ADD immediate.
	arm64_fold_reset()
	be_lea_acc_wstack(32760)
	promote_eax()
	assert_equal(68, codepos)
	arm64_fold_word(64, op(0xf9, 0x400380) | (4095 << 10))
	# Beyond the scaled displacement limit, preserve the address and load.
	arm64_fold_reset()
	be_lea_acc_wstack(32768)
	int end = codepos
	promote_eax()
	assert_equal(end + 4, codepos)
	assert_equal(0, load_note_end)
	arm64_fold_reset()
	be_lea_acc_wstack(9)
	promote_eax()
	assert_equal(72, codepos)
	assert_equal(0, load_note_end)
	arm64_fold_reset()
	be_lea_acc_wstack(-8)
	end = codepos
	promote_eax()
	assert_equal(end + 4, codepos)
	assert_equal(0, load_note_end)


void test_arm64_operand_shuttle():
	arm64_fold_reset()
	push_eax()
	be_lea_acc_wstack(24)
	promote_eax()
	pop_ebx()
	assert_equal(72, codepos)
	arm64_fold_word(64, op(0xaa, 0x0003e1))
	arm64_fold_word(68, op(0xf9, 0x400380) | (2 << 10))
	# Narrow loads keep their extension and adjust the byte displacement.
	arm64_fold_reset()
	push_eax()
	be_lea_acc_wstack(9)
	promote_int8_eax()
	pop_ebx()
	assert_equal(72, codepos)
	arm64_fold_word(68, op(0x39, 0x800380) | (1 << 10))
	# Constants can use several materialization instructions.
	arm64_fold_reset()
	push_eax()
	mov_eax_int(-123456)
	int end = codepos
	pop_ebx()
	assert_equal(end, codepos)
	arm64_fold_word(64, op(0xaa, 0x0003e1))
	assert_equal(0, push_note_end)
	# Reading the pushed temporary itself cannot remove that push.
	arm64_fold_reset()
	push_eax()
	be_lea_acc_wstack(0)
	promote_eax()
	pop_ebx()
	assert_equal(76, codepos)
	arm64_fold_word(64, op(0xf8, 0x1f8f80))


void test_arm64_fold_barriers():
	arm64_fold_reset()
	be_lea_acc_wstack(24)
	be_notes_reset()
	promote_eax()
	assert_equal(72, codepos)
	arm64_fold_reset()
	push_eax()
	mov_eax_int(7)
	be_notes_reset()
	int end = codepos
	pop_ebx()
	assert_equal(end + 4, codepos)
	# Emitting an unrelated instruction also breaks adjacency.
	arm64_fold_reset()
	push_eax()
	a64(op(0xd5, 0x03201f))
	mov_eax_int(7)
	end = codepos
	pop_ebx()
	assert_equal(end + 4, codepos)
	# A rollback must discard the old address note even if codepos later
	# returns to the same numeric position.
	arm64_fold_reset()
	be_lea_acc_wstack(24)
	peep_rollback(64)
	a64(op(0xd5, 0x03201f))
	promote_eax()
	assert_equal(72, codepos)


int main():
	test_arm64_load_widths()
	test_arm64_fields_and_limits()
	test_arm64_operand_shuttle()
	test_arm64_fold_barriers()
	be_notes_reset()
	println2(c"arm64_load_fold_test OK")
	return 0
