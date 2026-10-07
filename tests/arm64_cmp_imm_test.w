# wbuild: x64 arch=arm64_darwin
# Inspect the actual ARM64 emitter on any host: semantic tests alone do
# not prove that literals avoid loads or that comparison branches fuse.
import lib.assert
import compiler.compiler


void a64_test_reset():
	codepos = 4
	be_notes_reset()
	ctrl_stack_pos = 0


# Interpret move-wide encodings using four 16-bit lanes, so the oracle
# has identical behavior on 32-bit and 64-bit test hosts.
void a64_test_materialized(int lo, int hi, int wide, int reg):
	int[4] parts
	for i in range(4): parts[i] = 0
	asserts(c"move-wide sequence length", codepos > 4 && codepos <= 20)
	int pos = 4
	while (pos < codepos):
		int insn = load_int32(code + pos)
		int top = (insn >> 24) & 255
		assert_equal(wide, top >> 7)
		assert_equal(reg, insn & 31)
		int kind = top & 127
		int lane = (insn >> 21) & 3
		int imm = (insn >> 5) & 65535
		asserts(c"only MOVZ/MOVN/MOVK", kind == 0x52 || kind == 0x12 || kind == 0x72)
		if (kind != 0x72):
			assert_equal(4, pos)
			int fill = 0
			if (kind == 0x12): fill = 65535
			for i in range(4): parts[i] = fill
			if (kind == 0x12): imm = 65535 - imm
		parts[lane] = imm
		if (wide == 0):
			parts[2] = 0
			parts[3] = 0
		pos = pos + 4
	assert_equal(lo & 65535, parts[0])
	assert_equal((lo >> 16) & 65535, parts[1])
	assert_equal(hi & 65535, parts[2])
	assert_equal((hi >> 16) & 65535, parts[3])


void test_move_wide():
	list[int] values = list[int]{0, 1, 65535, 65536, 65537, 2147483647, -1, -65536, -65537, -2147483647, -2147483647 - 1}
	for i in range(11):
		int v = values[i]
		a64_test_reset()
		arm64_load_scratch(9, v)
		a64_test_materialized(v, (v >> 16) >> 16, 1, 9)
		if (v >= -65536 && v <= 65535): assert_equal(8, codepos)
		a64_test_reset()
		arm64_mov_eax_int32(v)
		a64_test_materialized(v, 0, 0, 0)
		asserts(c"32-bit literal at most two instructions", codepos <= 12)
	# Explicit halves exercise full-width values on 32-bit hosts too.
	list[int] lows = list[int]{0, 0, -1, 0x12345678, -1, 0, -2, 0x12345678}
	list[int] highs = list[int]{1, -2147483647 - 1, -1, 0x76543210, 0, -1, -1, -1}
	for i in range(8):
		a64_test_reset()
		arm64_mov_rax_int64_halves(lows[i], highs[i])
		a64_test_materialized(lows[i], highs[i], 1, 0)


void test_comparison_branches():
	list[int] setcc = list[int]{0x94, 0x95, 0x9c, 0x9d, 0x9e, 0x9f, 0x92, 0x93, 0x96, 0x97}
	list[int] cond = list[int]{0, 1, 11, 10, 13, 12, 3, 2, 9, 8}
	for i in range(10):
		for truth in range(2):
			a64_test_reset()
			int h = be_ctrl_block()
			alu_cmp_set(setcc[i])
			assert_equal(12, codepos)
			if (truth): be_br_nonzero_discard(h)
			else: be_br_zero_discard(h)
			assert_equal(12, codepos)
			int expected = cond[i]
			if (truth == 0): expected = jcc_invert(expected)
			int branch = load_int32(code + 8)
			assert_equal(0x54, (branch >> 24) & 255)
			assert_equal(expected, branch & 31)
			be_ctrl_end(h)
			assert_equal(1, (load_int32(code + 8) >> 5) & 0x7ffff)
	# Ordinary branches still carry a materialized accumulator value.
	a64_test_reset()
	int h = be_ctrl_block()
	alu_cmp_set(0x94)
	be_br_zero(h)
	assert_equal(16, codepos)
	assert_equal(0xb4, (load_int32(code + 12) >> 24) & 255)
	be_ctrl_end(h)
	# A merge boundary prevents reaching back into an earlier block.
	a64_test_reset()
	h = be_ctrl_block()
	alu_cmp_set(0x94)
	be_notes_reset()
	be_br_zero_discard(h)
	assert_equal(16, codepos)
	be_ctrl_end(h)
	# Two fused branches share a forward patch chain.
	a64_test_reset()
	h = be_ctrl_block()
	alu_cmp_set(0x94)
	be_br_zero_discard(h)
	int first = codepos
	alu_cmp_set(0x95)
	be_br_nonzero_discard(h)
	assert_equal(first, arm64_branch_link_get(codepos))
	be_ctrl_end(h)
	assert_equal(3, (load_int32(code + first - 4) >> 5) & 0x7ffff)
	# Back edges retain the signed imm19 displacement.
	a64_test_reset()
	h = be_ctrl_loop()
	alu_cmp_set(0x9c)
	be_br_nonzero_discard(h)
	assert_equal(0x7ffff, (load_int32(code + 8) >> 5) & 0x7ffff)
	be_ctrl_end(h)


int main():
	code_size = 4096
	code = cast(char*, malloc(code_size))
	target_isa = 1
	word_size = 8
	word_size_log2 = 3
	test_move_wide()
	test_comparison_branches()
	println(c"arm64 comparison and immediate test OK")
	return 0
