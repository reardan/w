# Additional scalar instruction effects. These change shadow state only;
# ptrace executes the real instruction and refreshes actual register values.
import libs.wgrind.decode_x64


int wg_integer_signed(int value, int size):
	int mask = wg_mask(size)
	value = value & mask
	if (value & (1 << (size * 8 - 1))): value = value | ~mask
	return value


void wg_integer_merge(wg_value* into, wg_value* alternative):
	int mask = into.undefined | alternative.undefined | (into.value ^ alternative.value)
	int origin = into.origin
	if (origin == 0): origin = alternative.origin
	wg_value_set(into, into.value, mask, origin)


# The ISA masks the count to five bits (six for a qword). Counts at or
# beyond a byte/word operand's width are legal, unlike the shared IR shift.
int wg_integer_shift_value(wg_context* c, int op, int size, wg_value* input, int count, wg_value* out):
	int bits = size * 8
	if (count < bits):
		wg_value n
		wg_value_set(&n, count, 0, 0)
		return wg_shift(c, op, size, input, &n, 0, out)
	int value = 0
	int undefined = 0
	if (op == WG_SAR):
		if ((input.value >> (bits - 1)) & 1): value = wg_mask(size)
		if ((input.undefined >> (bits - 1)) & 1): undefined = wg_mask(size)
	wg_value_set(out, value, undefined, input.origin)
	return 1


int wg_integer_shift_flags(wg_context* c, wg_x64_flags* flags, wg_x64_flags* before, int op, int size, wg_value* input, int count, wg_value* result, int site):
	if (count == 0):
		*flags = *before
		return 1
	wg_value zero
	wg_value_set(&zero, 0, 0, 0)
	if (wg_flags_update(c, flags, WG_OR, size, result, &zero, result, site) == 0): return 0
	int bits = size * 8
	int cf = 0
	int cu = 0
	int origin = input.origin
	if ((count >= bits) && (op != WG_SAR)):
		cu = 1
		origin = site
	else:
		int bit = count - 1
		if (op == WG_SHL): bit = bits - count
		if (bit >= bits): bit = bits - 1
		cf = (input.value >> bit) & 1
		cu = (input.undefined >> bit) & 1
	wg_value_set(&flags.cf, cf, cu, origin)
	int overflow = 0
	int ou = 0
	int oo = input.origin
	if (count == 1):
		if (op == WG_SHL):
			overflow = ((result.value >> (bits - 1)) & 1) ^ cf
			ou = ((result.undefined >> (bits - 1)) & 1) | cu
		elif (op == WG_SHR):
			overflow = (input.value >> (bits - 1)) & 1
			ou = (input.undefined >> (bits - 1)) & 1
	else:
		ou = 1
		oo = site
	wg_value_set(&flags.of, overflow, ou, oo)
	wg_flags_forget_joint(flags)
	return 1


int wg_integer_shift(wg_machine* m, int op):
	asm_insn* insn = &m.instruction
	wg_value input
	wg_value count
	wg_value result
	if (wg_native_read(m, &insn.op1, &input) == 0): return 0
	if (wg_native_read(m, &insn.op2, &count) == 0): return 0
	int size = insn.op1.size
	if ((size != 1) && (size != 2) && (size != 4) && (size != 8)): return wg_native_incomplete(m)
	int countmask = 31
	if (size == 8): countmask = 63
	int actual = count.value & countmask
	wg_x64_flags before = m.flags
	if (wg_integer_shift_value(m.context, op, size, &input, actual, &result) == 0): return 0
	if (wg_integer_shift_flags(m.context, &m.flags, &before, op, size, &input, actual, &result, m.raw[16]) == 0): return 0
	for n in range(countmask + 1):
		if ((n == actual) || (((n ^ actual) & ~count.undefined & countmask) != 0)): continue
		wg_value possible
		wg_x64_flags flags
		if (wg_integer_shift_value(m.context, op, size, &input, n, &possible) == 0): return 0
		if (wg_integer_shift_flags(m.context, &flags, &before, op, size, &input, n, &possible, m.raw[16]) == 0): return 0
		if (possible.origin == 0): possible.origin = count.origin
		if (flags.cf.origin == 0): flags.cf.origin = count.origin
		if (flags.of.origin == 0): flags.of.origin = count.origin
		if (flags.zf.origin == 0): flags.zf.origin = count.origin
		if (flags.sf.origin == 0): flags.sf.origin = count.origin
		if (flags.pf.origin == 0): flags.pf.origin = count.origin
		if (flags.af.origin == 0): flags.af.origin = count.origin
		wg_integer_merge(&result, &possible)
		wg_integer_merge(&m.flags.cf, &flags.cf)
		wg_integer_merge(&m.flags.of, &flags.of)
		wg_integer_merge(&m.flags.zf, &flags.zf)
		wg_integer_merge(&m.flags.sf, &flags.sf)
		wg_integer_merge(&m.flags.pf, &flags.pf)
		wg_integer_merge(&m.flags.af, &flags.af)
		wg_flags_forget_joint(&m.flags)
	return wg_native_write(m, &insn.op1, &result)


# Abstract long multiplication retains determined low bits and annihilation
# by known zero. Unknown arithmetic is propagated, never reported as a use.
int wg_integer_product(wg_context* c, int size, wg_value* a, wg_value* b, wg_value* out):
	int mask = wg_mask(size)
	int value = (a.value * b.value) & mask
	if (((a.undefined | b.undefined) & mask) == 0):
		wg_value_set(out, value, 0, 0)
		return 1
	wg_value sum
	wg_value_set(&sum, 0, 0, 0)
	for bit in range(size * 8):
		wg_value term
		int v = 0
		int u = 0
		int origin = a.origin
		if ((b.value >> bit) & 1):
			v = a.value << bit
			u = a.undefined << bit
		if ((b.undefined >> bit) & 1):
			u = (a.value | a.undefined) << bit
			origin = b.origin
		wg_value_set(&term, v & mask, u & mask, origin)
		if (wg_binary(c, WG_ADD, size, &sum, &term, &sum) == 0): return 0
	wg_value_set(out, value, sum.undefined, sum.origin)
	return 1


int wg_integer_imul(wg_machine* m):
	asm_insn* insn = &m.instruction
	if (insn.op2.kind == ASM_OP_NONE): return -1
	wg_value a
	wg_value b
	wg_value result
	if (insn.op3.kind == ASM_OP_NONE):
		if (wg_native_read(m, &insn.op1, &a) == 0): return 0
		if (wg_native_read(m, &insn.op2, &b) == 0): return 0
	else:
		if (wg_native_read(m, &insn.op2, &a) == 0): return 0
		if (wg_native_read(m, &insn.op3, &b) == 0): return 0
	int size = insn.op1.size
	if ((size != 2) && (size != 4) && (size != 8)): return wg_native_incomplete(m)
	if (wg_integer_product(m.context, size, &a, &b, &result) == 0): return 0
	int av = wg_integer_signed(a.value, size)
	int bv = wg_integer_signed(b.value, size)
	int rv = wg_integer_signed(result.value, size)
	int overflow = 0
	if (bv):
		int minimum = 1 << 63
		if ((rv == minimum) && (bv == -1)): overflow = 1
		else: overflow = (rv / bv != av)
	int unknown = (a.undefined | b.undefined) != 0
	if (((a.value == 0) && (a.undefined == 0)) || ((b.value == 0) && (b.undefined == 0))): unknown = 0
	wg_flags_init(&m.flags, 0, -1, m.raw[16])
	int origin = a.origin
	if (a.undefined == 0): origin = b.origin
	wg_value_set(&m.flags.cf, overflow, unknown, origin)
	wg_value_set(&m.flags.of, overflow, unknown, origin)
	wg_flags_forget_joint(&m.flags)
	return wg_native_write(m, &insn.op1, &result)


int wg_integer_high_product(int a, int b, int size):
	int mask = wg_mask(size)
	a = a & mask
	b = b & mask
	if (size < 8): return ((a * b) >> (size * 8)) & mask
	int half = wg_mask(4)
	int a0 = a & half
	int a1 = (a >> 32) & half
	int b0 = b & half
	int b1 = (b >> 32) & half
	int low = a0 * b0
	int mid = ((low >> 32) & half) + a1 * b0
	int high = (mid >> 32) & half
	mid = (mid & half) + a0 * b1
	return a1 * b1 + high + ((mid >> 32) & half)


int wg_integer_multiply_full(wg_machine* m, int signed):
	int size = m.instruction.op1.size
	if ((size != 1) && (size != 2) && (size != 4) && (size != 8)): return wg_native_incomplete(m)
	wg_value a
	wg_value b
	wg_value low
	wg_value high
	if (wg_register_read(m.context, &m.registers, 0, 0, size, m.raw[16], &a) == 0): return 0
	if (wg_native_read(m, &m.instruction.op1, &b) == 0): return 0
	if (wg_integer_product(m.context, size, &a, &b, &low) == 0): return 0
	int hv = wg_integer_high_product(a.value, b.value, size)
	if (signed):
		if (wg_integer_signed(a.value, size) < 0): hv = hv - b.value
		if (wg_integer_signed(b.value, size) < 0): hv = hv - a.value
	hv = hv & wg_mask(size)
	int unknown = (a.undefined | b.undefined) != 0
	if (((a.value == 0) && (a.undefined == 0)) || ((b.value == 0) && (b.undefined == 0))): unknown = 0
	int hu = 0
	if (unknown): hu = wg_mask(size)
	int origin = a.origin
	if (a.undefined == 0): origin = b.origin
	wg_value_set(&high, hv, hu, origin)
	int overflow = hv != 0
	if (signed):
		int signfill = 0
		if (wg_integer_signed(low.value, size) < 0): signfill = wg_mask(size)
		overflow = hv != signfill
	wg_flags_init(&m.flags, 0, -1, m.raw[16])
	wg_value_set(&m.flags.cf, overflow, unknown, origin)
	wg_value_set(&m.flags.of, overflow, unknown, origin)
	wg_flags_forget_joint(&m.flags)
	if (wg_register_write(m.context, &m.registers, 0, 0, size, size == 4, m.raw[16], &low) == 0): return 0
	int reg = 2
	int offset = 0
	if (size == 1):
		reg = 0
		offset = 1
	return wg_register_write(m.context, &m.registers, reg, offset, size, size == 4, m.raw[16], &high)


int wg_integer_divide(wg_machine* m):
	int size = m.instruction.op1.size
	if ((size != 1) && (size != 2) && (size != 4) && (size != 8)): return wg_native_incomplete(m)
	wg_value divisor
	wg_value lo
	wg_value hi
	if (wg_native_read(m, &m.instruction.op1, &divisor) == 0): return 0
	int width = size
	if (size == 1): width = 2
	if (wg_register_read(m.context, &m.registers, 0, 0, width, m.raw[16], &lo) == 0): return 0
	wg_value_set(&hi, 0, 0, 0)
	if (size != 1):
		if (wg_register_read(m.context, &m.registers, 2, 0, size, m.raw[16], &hi) == 0): return 0
	int unknown = lo.undefined | hi.undefined | divisor.undefined
	int origin = lo.origin
	if (origin == 0): origin = hi.origin
	if (origin == 0): origin = divisor.origin
	int mask = 0
	if (unknown): mask = wg_mask(size)
	# Actual quotient/remainder are obtained from GETREGS after the CPU
	# executes. No host divide: a guest zero/overflow must not crash us.
	wg_value output
	wg_value_set(&output, 0, mask, origin)
	if (wg_register_write(m.context, &m.registers, 0, 0, size, size == 4, m.raw[16], &output) == 0): return 0
	int reg = 2
	int offset = 0
	if (size == 1):
		reg = 0
		offset = 1
	if (wg_register_write(m.context, &m.registers, reg, offset, size, size == 4, m.raw[16], &output) == 0): return 0
	wg_flags_init(&m.flags, 0, -1, m.raw[16])
	return 1


int wg_native_integer(wg_machine* m):
	char* name = m.instruction.mnemonic
	wg_value left
	wg_value right
	wg_value result
	int site = m.raw[16]
	if (strcmp(name, c"shl") == 0): return wg_integer_shift(m, WG_SHL)
	if (strcmp(name, c"shr") == 0): return wg_integer_shift(m, WG_SHR)
	if (strcmp(name, c"sar") == 0): return wg_integer_shift(m, WG_SAR)
	if (strcmp(name, c"imul") == 0):
		if (m.instruction.op2.kind == ASM_OP_NONE): return wg_integer_multiply_full(m, 1)
		return wg_integer_imul(m)
	if (strcmp(name, c"mul") == 0): return wg_integer_multiply_full(m, 0)
	if ((strcmp(name, c"div") == 0) || (strcmp(name, c"idiv") == 0)): return wg_integer_divide(m)
	if ((strcmp(name, c"inc") == 0) || (strcmp(name, c"dec") == 0)):
		if (wg_native_read(m, &m.instruction.op1, &left) == 0): return 0
		wg_value_set(&right, 1, 0, 0)
		wg_value carry = m.flags.cf
		int op = WG_ADD
		if (strcmp(name, c"dec") == 0): op = WG_SUB
		int size = m.instruction.op1.size
		if (wg_binary(m.context, op, size, &left, &right, &result) == 0): return 0
		if (wg_flags_update(m.context, &m.flags, op, size, &left, &right, &result, site) == 0): return 0
		wg_flags_preserve_carry(&m.flags, &carry)
		return wg_native_write(m, &m.instruction.op1, &result)
	if ((strcmp(name, c"cqo") == 0) || (strcmp(name, c"cdq") == 0)):
		if ((m.bytes[0] & 255) == 0x66): return wg_native_incomplete(m)
		int size = 8
		if (strcmp(name, c"cdq") == 0): size = 4
		if (wg_register_read(m.context, &m.registers, 0, 0, size, site, &left) == 0): return 0
		int value = 0
		int undefined = 0
		if ((left.value >> (size * 8 - 1)) & 1): value = wg_mask(size)
		if ((left.undefined >> (size * 8 - 1)) & 1): undefined = wg_mask(size)
		wg_value_set(&result, value, undefined, left.origin)
		return wg_register_write(m.context, &m.registers, 2, 0, size, size == 4, site, &result)
	if ((strcmp(name, c"cdqe") == 0) || (strcmp(name, c"cwde") == 0)):
		if ((m.bytes[0] & 255) == 0x66): return wg_native_incomplete(m)
		int size = 4
		if (strcmp(name, c"cwde") == 0): size = 2
		if (wg_register_read(m.context, &m.registers, 0, 0, size, site, &left) == 0): return 0
		wg_value_set(&result, wg_integer_signed(left.value, size), wg_integer_signed(left.undefined, size), left.origin)
		return wg_register_write(m.context, &m.registers, 0, 0, size * 2, size == 2, site, &result)
	if (strcmp(name, c"cmovcc") == 0):
		# The memory source is accessed even when the condition is false.
		if (wg_native_read(m, &m.instruction.op1, &left) == 0): return 0
		if (wg_native_read(m, &m.instruction.op2, &right) == 0): return 0
		if (wg_flags_condition(m.context, &m.flags, m.condition, site, &result) == 0): return 0
		int selected = result.value
		if (result.undefined):
			if (left.origin == 0): left.origin = result.origin
			wg_integer_merge(&left, &right)
			if (selected): left.value = right.value
			return wg_native_write(m, &m.instruction.op1, &left)
		if (selected): return wg_native_write(m, &m.instruction.op1, &right)
		return wg_native_write(m, &m.instruction.op1, &left)
	return -1
