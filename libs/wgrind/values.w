# Bit-level definedness propagation, shared by execution frontends. A set
# undefined bit means either concrete value is possible. Correlations
# between distinct operands are not assumed; frontends handle identities
# such as xor rax,rax only when operand identity is proven.
import libs.wgrind.shadow

const int WG_AND = 1
const int WG_OR = 2
const int WG_XOR = 3
const int WG_ADD = 4
const int WG_SUB = 5
const int WG_EQ = 6
const int WG_SHL = 7
const int WG_SHR = 8
const int WG_SAR = 9


void wg_value_set(wg_value* out, int value, int undefined, int origin):
	out.value = value
	out.undefined = undefined
	out.origin = 0
	if (undefined): out.origin = origin


# Inputs are snapshotted so out may alias either input (register writes).
# Unsupported operations/widths set an incomplete-check error.
int wg_binary(wg_context* c, int op, int size, wg_value* a, wg_value* b, wg_value* out):
	if (c.error): return 0
	if ((size < 1) || (size > __word_size__)): return wg_error(c, WG_INCOMPLETE, 0, size, 0, 0)
	int mask = wg_mask(size)
	int av = a.value & mask
	int bv = b.value & mask
	int au = a.undefined & mask
	int bu = b.undefined & mask
	int origin = a.origin
	if (au == 0): origin = b.origin
	int value = 0
	int u = 0
	if (op == WG_AND):
		value = av & bv
		int from_a = au & (bv | bu)
		u = from_a | (bu & (av | au))
		if (from_a == 0): origin = b.origin
	elif (op == WG_OR):
		value = av | bv
		int from_a = au & (~bv | bu)
		u = from_a | (bu & (~av | au))
		if (from_a == 0): origin = b.origin
	elif (op == WG_XOR):
		value = av ^ bv
		u = au | bu
	elif (op == WG_EQ):
		value = av == bv
		# A known differing bit proves inequality even if other bits
		# are undefined. Otherwise equality needs every compared bit.
		if (((av ^ bv) & ~(au | bu) & mask) == 0):
			if (au | bu): u = 1
	elif ((op == WG_ADD) || (op == WG_SUB)):
		value = av + bv
		int carry = 1 # bitset of possible carry values: 1 = {0}
		if (op == WG_SUB):
			value = av - bv
			bv = ~bv
			carry = 2 # a + ~b + 1
		for i in range(size * 8):
			int abit = (av >> i) & 1
			int bbit = (bv >> i) & 1
			int outcomes = 0
			int carries = 0
			for x in range(2):
				if ((((au >> i) & 1) == 0) && (x != abit)): continue
				for y in range(2):
					if ((((bu >> i) & 1) == 0) && (y != bbit)): continue
					for z in range(2):
						if (((carry >> z) & 1) == 0): continue
						int sum = x + y + z
						outcomes = outcomes | (1 << (sum & 1))
						carries = carries | (1 << (sum >> 1))
			if (outcomes == 3): u = u | (1 << i)
			carry = carries
	else: return wg_error(c, WG_INCOMPLETE, 0, op, 0, 0)
	wg_value_set(out, value & mask, u & mask, origin)
	return 1


# Concrete fixed-width shift. Only called after opcode/count validation.
int wg_shift_bits(int op, int size, int value, int n):
	int mask = wg_mask(size)
	int bits = size * 8
	value = value & mask
	if (op == WG_SHL): return (value << n) & mask
	int low = mask
	if (n): low = mask ^ (-1 << (bits - n))
	int sign = (value >> (bits - 1)) & 1
	value = (value >> n) & low
	if ((op == WG_SAR) && sign): value = value | (mask ^ low)
	return value & mask


# ISA frontends normalize/mask counts before this call. An undefined
# count propagates uncertainty, just like an undefined data operand;
# it is not itself a branch/address/output use. Merge all possible
# counts, so shifting zero remains defined even for an unknown count.
int wg_shift(wg_context* c, int op, int size, wg_value* a, wg_value* count, int site, wg_value* out):
	if (c.error): return 0
	if ((size < 1) || (size > __word_size__)): return wg_error(c, WG_INCOMPLETE, 0, size, site, 0)
	if ((op != WG_SHL) && (op != WG_SHR) && (op != WG_SAR)): return wg_error(c, WG_INCOMPLETE, 0, op, site, 0)
	int n = count.value
	int cu = count.undefined
	int bits = size * 8
	# Every possible count must have modeled semantics. Counts outside
	# this primitive's range need ISA-specific normalization/emulation.
	if ((n < 0) || (cu < 0) || ((n | cu) >= bits)): return wg_error(c, WG_INCOMPLETE, 0, n, site, count.origin)
	int value = wg_shift_bits(op, size, a.value, n)
	int initial_u = wg_shift_bits(op, size, a.undefined, n)
	int u = initial_u
	int origin = a.origin
	if (cu):
		for k in range(bits):
			if ((k ^ n) & ~cu): continue
			int other = wg_shift_bits(op, size, a.value, k)
			int other_u = wg_shift_bits(op, size, a.undefined, k)
			if ((value ^ other) & ~(initial_u | other_u)): origin = count.origin
			u = u | other_u | (value ^ other)
	wg_value_set(out, value, u, origin)
	return 1


# A condition is defined when any known bit is one, or all bits are
# defined zero. Merely loading/copying an undefined word is not a use.
int wg_nonzero(wg_context* c, int size, wg_value* a, wg_value* out):
	if (c.error): return 0
	if ((size < 1) || (size > __word_size__)): return wg_error(c, WG_INCOMPLETE, 0, size, 0, 0)
	int mask = wg_mask(size)
	int value = a.value & mask
	int u = a.undefined & mask
	int unknown = 0
	if ((value & ~u) == 0):
		if (u): unknown = 1
	wg_value_set(out, value != 0, unknown, a.origin)
	return 1
