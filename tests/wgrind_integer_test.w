# wbuild: target=wgrind_integer_test tag=tests dep=wv2
# wbuild: step="bin/wv2 x64 tests/wgrind_integer_test.w -o bin/wgrind_integer_test"
# wbuild: step="bin/wgrind_integer_test" expect_stdout="wgrind_integer_test: OK"
import lib.assert
import libs.wgrind.execute_integer


void integer_register(wg_machine* m, int reg, int value, int undefined):
	wg_value v
	wg_value_set(&v, value, undefined, 77)
	assert1(wg_register_write(m.context, &m.registers, reg, 0, 8, 0, 123, &v))


void integer_instruction(wg_machine* m, char* name, int size):
	asm_insn_clear(&m.instruction)
	m.instruction.mnemonic = name
	asm_x86_set_reg(&m.instruction.op1, ASM_RCLASS_GP, 0, size)
	asm_x86_set_reg(&m.instruction.op2, ASM_RCLASS_GP, 1, size)
	m.raw[16] = 123
	m.rex = 0x48
	m.bytes[0] = 0x48
	wg_flags_init(&m.flags, 0, 0, 0)


void integer_shift_cases(wg_machine* m):
	wg_value input
	wg_value result
	for value in range(256):
		wg_value_set(&input, value, 0, 0)
		for count in range(32):
			assert1(wg_integer_shift_value(m.context, WG_SHL, 1, &input, count, &result))
			assert_equal((value << count) & 255, result.value)
			assert_equal(0, result.undefined)
			assert1(wg_integer_shift_value(m.context, WG_SHR, 1, &input, count, &result))
			assert_equal(value >> count, result.value)
			assert1(wg_integer_shift_value(m.context, WG_SAR, 1, &input, count, &result))
			int signed_value = value
			if (value >= 128): signed_value = value - 256
			assert_equal((signed_value >> count) & 255, result.value)
	integer_instruction(m, c"shl", 8)
	integer_register(m, 0, 1, 0)
	integer_register(m, 1, 0, 1)
	m.instruction.op2.size = 1
	wg_value_set(&m.flags.af, 0, 0, 0)
	assert1(wg_native_integer(m))
	assert_equal(3, m.registers.undefined[0]) # possible values 1 and 2
	assert_equal(1, m.flags.af.undefined) # possible nonzero count makes AF unspecified
	assert_equal(0, m.context.error) # shifting undefined count is propagation
	integer_register(m, 0, 7, 0)
	integer_register(m, 1, 0, ~63)
	assert1(wg_native_integer(m))
	assert_equal(0, m.registers.undefined[0]) # bits discarded by ISA mask
	integer_instruction(m, c"shr", 8)
	integer_register(m, 0, 1 << 63, 0)
	integer_register(m, 1, 1, 0)
	assert1(wg_native_integer(m))
	assert_equal(1 << 62, m.registers.values[0])
	assert_equal(1, m.flags.of.value)
	assert_equal(0, m.flags.of.undefined)
	integer_instruction(m, c"sar", 8)
	integer_register(m, 0, 1 << 63, 1 << 63)
	integer_register(m, 1, 63, 0)
	assert1(wg_native_integer(m))
	assert_equal(-1, m.registers.undefined[0])
	assert_equal(1, m.flags.of.undefined) # OF unspecified for count > 1


void integer_product_cases(wg_machine* m):
	wg_value a
	wg_value b
	wg_value product
	for av in range(16):
		for au in range(16):
			for bv in range(16):
				wg_value_set(&a, av, au, 1)
				wg_value_set(&b, bv, 0, 0)
				assert1(wg_integer_product(m.context, 1, &a, &b, &product))
				int first = -1
				int differs = 0
				for concrete in range(16):
					if (((concrete ^ av) & ~au) == 0):
						int p = (concrete * bv) & 255
						if (first < 0): first = p
						differs = differs | (first ^ p)
				# Independent V bits can over-approximate correlated partial
				# products, but every possibly-changing bit must be marked.
				assert_equal(differs, differs & product.undefined)
				assert_equal((av * bv) & 255, product.value)
	assert_equal(-2, wg_integer_high_product(-1, -1, 8))
	assert_equal(0, wg_integer_high_product(1 << 32, wg_mask(4), 8))
	assert_equal(1, wg_integer_high_product(1 << 32, 1 << 32, 8))
	integer_instruction(m, c"imul", 8)
	integer_register(m, 0, 1 << 63, 0)
	integer_register(m, 1, -1, 0)
	assert1(wg_native_integer(m))
	assert_equal(1, m.flags.of.value)
	assert_equal(0, m.flags.of.undefined)
	integer_register(m, 0, 87, -1)
	assert_equal(1, m.flags.af.undefined) # IMUL leaves AF unspecified
	integer_register(m, 1, 0, 0)
	assert1(wg_native_integer(m))
	assert_equal(0, m.registers.undefined[0])
	assert_equal(0, m.flags.of.undefined)
	integer_instruction(m, c"mul", 1)
	m.instruction.op2.kind = ASM_OP_NONE
	m.instruction.op1.reg = 1
	integer_register(m, 0, 200, 0)
	integer_register(m, 1, 2, 0)
	assert1(wg_native_integer(m))
	assert_equal(400, m.registers.values[0] & 65535)
	assert_equal(1, m.flags.cf.value)


void integer_misc_cases(wg_machine* m):
	integer_instruction(m, c"inc", 8)
	integer_register(m, 0, -1, 0)
	wg_value_set(&m.flags.cf, 1, 1, 12)
	assert1(wg_native_integer(m))
	assert_equal(0, m.registers.values[0])
	assert_equal(1, m.flags.cf.value)
	assert_equal(1, m.flags.cf.undefined)
	assert_equal(1, m.flags.zf.value)
	integer_instruction(m, c"dec", 8)
	integer_register(m, 0, 0, 0)
	assert1(wg_native_integer(m))
	assert_equal(-1, m.registers.values[0])
	integer_instruction(m, c"cqo", 8)
	integer_register(m, 0, 1 << 63, 1 << 63)
	assert1(wg_native_integer(m))
	assert_equal(-1, m.registers.undefined[2])
	integer_instruction(m, c"cdqe", 8)
	integer_register(m, 0, 1 << 31, 1 << 31)
	assert1(wg_native_integer(m))
	assert_equal(~((1 << 31) - 1), m.registers.undefined[0])
	integer_instruction(m, c"idiv", 8)
	integer_register(m, 0, 10, 1)
	integer_register(m, 2, 0, 0)
	m.instruction.op1.reg = 1
	integer_register(m, 1, 2, 0)
	assert1(wg_native_integer(m))
	assert_equal(-1, m.registers.undefined[0])
	assert_equal(-1, m.registers.undefined[2])
	assert_equal(0, m.context.error)
	integer_instruction(m, c"cmovcc", 8)
	m.condition = 4
	wg_value_set(&m.flags.zf, 1, 1, 88)
	wg_flags_forget_joint(&m.flags)
	integer_register(m, 0, 4, 0)
	integer_register(m, 1, 5, 0)
	assert1(wg_native_integer(m))
	assert_equal(1, m.registers.undefined[0])
	assert_equal(5, m.registers.values[0])
	integer_register(m, 0, 5, 0)
	assert1(wg_native_integer(m))
	assert_equal(0, m.registers.undefined[0]) # equal alternatives cancel taint
	integer_instruction(m, c"unknown", 8)
	assert_equal(-1, wg_native_integer(m))
	assert_equal(0, m.context.error)


int main():
	wg_machine m
	m.context = wg_create(8, 8, 4)
	assert1(m.context != 0)
	wg_registers_init(&m.registers, 0)
	integer_shift_cases(&m)
	integer_product_cases(&m)
	integer_misc_cases(&m)
	wg_destroy(m.context)
	println(c"wgrind_integer_test: OK")
	return 0
