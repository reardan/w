# Integer x86 condition flags. CMP uses WG_SUB, TEST uses WG_AND.
# Conditions return a Boolean value; the execution frontend calls wg_use
# only for a consequential use such as a conditional branch.
import libs.wgrind.values


struct wg_x64_flags:
	wg_value zf
	wg_value sf
	wg_value cf
	wg_value of
	wg_value pf
	wg_value af
	int combinations # bitset of (ZF | SF<<1 | CF<<2 | OF<<3 | PF<<4)


void wg_flags_init(wg_x64_flags* f, int value, int undefined, int origin):
	wg_value_set(&f.zf, (value >> 6) & 1, (undefined >> 6) & 1, origin)
	wg_value_set(&f.sf, (value >> 7) & 1, (undefined >> 7) & 1, origin)
	wg_value_set(&f.cf, value & 1, undefined & 1, origin)
	wg_value_set(&f.of, (value >> 11) & 1, (undefined >> 11) & 1, origin)
	wg_value_set(&f.pf, (value >> 2) & 1, (undefined >> 2) & 1, origin)
	wg_value_set(&f.af, (value >> 4) & 1, (undefined >> 4) & 1, origin)
	int actual = f.zf.value | (f.sf.value << 1) | (f.cf.value << 2) | (f.of.value << 3) | (f.pf.value << 4)
	int unknown = f.zf.undefined | (f.sf.undefined << 1) | (f.cf.undefined << 2) | (f.of.undefined << 3) | (f.pf.undefined << 4)
	f.combinations = 0
	for state in range(32):
		if (((state ^ actual) & ~unknown) == 0): f.combinations = f.combinations | (1 << state)


# Call when modifying individual flags without a joint transfer model.
void wg_flags_forget_joint(wg_x64_flags* f):
	f.combinations = 0


# INC/DEC preserve carry. Its correlation with the new result is not
# known, so combine its possibilities with the other new flags.
void wg_flags_preserve_carry(wg_x64_flags* f, wg_value* carry):
	int combinations = 0
	for state in range(32):
		if (((f.combinations >> state) & 1) == 0): continue
		for bit in range(2):
			if ((carry.undefined == 0) && (bit != carry.value)): continue
			combinations = combinations | (1 << ((state & ~4) | (bit << 2)))
	wg_value_set(&f.cf, carry.value, carry.undefined, carry.origin)
	f.combinations = combinations


void wg_flag_possible(wg_value* out, int value, int possibilities, int origin):
	wg_value_set(out, value, possibilities == 3, origin)


int wg_flags_update(wg_context* c, wg_x64_flags* f, int op, int size, wg_value* left, wg_value* right, wg_value* result, int site):
	if (c.error): return 0
	if ((size < 1) || (size > __word_size__)): return wg_error(c, WG_INCOMPLETE, 0, size, site, 0)
	if ((op != WG_ADD) && (op != WG_SUB) && (op != WG_AND) && (op != WG_OR) && (op != WG_XOR)):
		return wg_error(c, WG_INCOMPLETE, 0, op, site, 0)
	int mask = wg_mask(size)
	int av = left.value & mask
	int bv = right.value & mask
	int au = left.undefined & mask
	int bu = right.undefined & mask
	int rv = result.value & mask
	int ru = result.undefined & mask
	int origin = left.origin
	if (au == 0): origin = right.origin
	int result_origin = result.origin
	int bits = size * 8
	int parity = 1
	for i in range(8): parity = parity ^ ((rv >> i) & 1)
	wg_value_set(&f.sf, (rv >> (bits - 1)) & 1, (ru >> (bits - 1)) & 1, result_origin)
	if ((op == WG_AND) || (op == WG_OR) || (op == WG_XOR)):
		wg_value temp
		wg_value_set(&temp, rv, ru, result_origin)
		if (wg_nonzero(c, size, &temp, &f.zf) == 0): return 0
		f.zf.value = f.zf.value ^ 1
		wg_value_set(&f.cf, 0, 0, 0)
		wg_value_set(&f.of, 0, 0, 0)
		wg_value_set(&f.pf, parity, (ru & 255) != 0, result_origin)
		# Logical operations leave AF architecturally undefined.
		wg_value_set(&f.af, 0, 1, site)
		int states = 1 # bit index = parity*2 + nonzero
		f.combinations = 0
		for i in range(bits):
			int next = 0
			for state in range(4):
				if (((states >> state) & 1) == 0): continue
				for bit in range(2):
					if ((((ru >> i) & 1) == 0) && (bit != ((rv >> i) & 1))): continue
					int p = state >> 1
					if (i < 8): p = p ^ bit
					int nz = (state & 1) | bit
					next = next | (1 << (p * 2 + nz))
					if (i == bits - 1): f.combinations = f.combinations | (1 << ((nz ^ 1) | (bit << 1) | ((p ^ 1) << 4)))
			states = next
		return 1
	# State tracks carry, low-byte parity and whether any result bit
	# is nonzero. Keeping these correlations avoids false undefined ZF
	# and PF when the result's independent V bits lose that information.
	int states = 1 # bit index = carry*4 + parity*2 + nonzero
	int transformed_b = bv
	if (op == WG_SUB):
		states = 16 # initial carry1 for a + ~b + 1
		transformed_b = ~bv
	int auxiliary = 0
	int overflows = 0
	f.combinations = 0
	for i in range(bits):
		int next = 0
		int abit = (av >> i) & 1
		int bbit = (transformed_b >> i) & 1
		for state in range(8):
			if (((states >> state) & 1) == 0): continue
			for x in range(2):
				if ((((au >> i) & 1) == 0) && (x != abit)): continue
				for y in range(2):
					if ((((bu >> i) & 1) == 0) && (y != bbit)): continue
					int sum = x + y + (state >> 2)
					int bit = sum & 1
					int p = (state >> 1) & 1
					if (i < 8): p = p ^ bit
					int nz = (state & 1) | bit
					next = next | (1 << ((sum >> 1) * 4 + p * 2 + nz))
					if (i == 3):
						int auxiliary_carry = sum >> 1
						if (op == WG_SUB): auxiliary_carry = auxiliary_carry ^ 1
						auxiliary = auxiliary | (1 << auxiliary_carry)
					if (i == bits - 1):
						# For subtraction y is already the complemented
						# sign bit, so the same addition predicate applies.
						int overflow = (x == y) && (bit != x)
						overflows = overflows | (1 << overflow)
						int carry = sum >> 1
						if (op == WG_SUB): carry = carry ^ 1
						int combination = (nz ^ 1) | (bit << 1) | (carry << 2) | (overflow << 3) | ((p ^ 1) << 4)
						f.combinations = f.combinations | (1 << combination)
		states = next
	int carries = 0
	int zeros = 0
	int parities = 0
	for state in range(8):
		if (((states >> state) & 1) == 0): continue
		int carry = state >> 2
		if (op == WG_SUB): carry = carry ^ 1
		carries = carries | (1 << carry)
		zeros = zeros | (1 << ((state & 1) ^ 1))
		parities = parities | (1 << (((state >> 1) & 1) ^ 1))
	int carry = wg_less(rv, av)
	int overflow = ((~(av ^ bv) & (av ^ rv)) >> (bits - 1)) & 1
	if (op == WG_SUB):
		carry = wg_less(av, bv)
		overflow = (((av ^ bv) & (av ^ rv)) >> (bits - 1)) & 1
	wg_flag_possible(&f.af, ((av ^ bv ^ rv) >> 4) & 1, auxiliary, origin)
	wg_flag_possible(&f.cf, carry, carries, origin)
	wg_flag_possible(&f.of, overflow, overflows, origin)
	wg_flag_possible(&f.zf, rv == 0, zeros, origin)
	wg_flag_possible(&f.pf, parity, parities, origin)
	return 1


int wg_cc_value(int flags, int cc):
	int pair = cc >> 1
	int value = 0
	if (pair == 0): value = (flags >> 3) & 1
	elif (pair == 1): value = (flags >> 2) & 1
	elif (pair == 2): value = flags & 1
	elif (pair == 3): value = ((flags >> 2) | flags) & 1
	elif (pair == 4): value = (flags >> 1) & 1
	elif (pair == 5): value = (flags >> 4) & 1
	elif (pair == 6): value = ((flags >> 1) ^ (flags >> 3)) & 1
	else: value = (((flags >> 1) ^ (flags >> 3)) | flags) & 1
	return value ^ (cc & 1)


# Intel cc encoding: O,NO,B,NB,E,NE,BE,A,S,NS,P,NP,L,GE,LE,G.
int wg_flags_condition(wg_context* c, wg_x64_flags* f, int cc, int site, wg_value* out):
	if (c.error): return 0
	if ((cc < 0) || (cc > 15)): return wg_error(c, WG_INCOMPLETE, 0, cc, site, 0)
	wg_value temp
	int pair = cc >> 1
	if (pair == 0): wg_value_set(&temp, f.of.value, f.of.undefined, f.of.origin)
	elif (pair == 1): wg_value_set(&temp, f.cf.value, f.cf.undefined, f.cf.origin)
	elif (pair == 2): wg_value_set(&temp, f.zf.value, f.zf.undefined, f.zf.origin)
	elif (pair == 3):
		if (wg_binary(c, WG_OR, 1, &f.cf, &f.zf, &temp) == 0): return 0
	elif (pair == 4): wg_value_set(&temp, f.sf.value, f.sf.undefined, f.sf.origin)
	elif (pair == 5): wg_value_set(&temp, f.pf.value, f.pf.undefined, f.pf.origin)
	else:
		if (wg_binary(c, WG_XOR, 1, &f.sf, &f.of, &temp) == 0): return 0
		if (pair == 7):
			if (wg_binary(c, WG_OR, 1, &temp, &f.zf, &temp) == 0): return 0
	int undefined = temp.undefined
	if (f.combinations):
		int possibilities = 0
		for state in range(32):
			if ((f.combinations >> state) & 1): possibilities = possibilities | (1 << wg_cc_value(state, cc))
		undefined = possibilities == 3
	wg_value_set(out, temp.value ^ (cc & 1), undefined, temp.origin)
	return 1
