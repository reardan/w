int bignum_limb_count():
	return 96


int bignum_size():
	return 4 + bignum_limb_count() * 4


void bignum_clear(int n):
	save_int(n, 1)
	int i = 0
	while (i < bignum_limb_count()):
		save_int(n + 4 + i * 4, 0)
		i = i + 1


int bignum_new():
	int n = malloc(bignum_size())
	bignum_clear(n)
	return n


int bignum_length(int n):
	return load_int(n)


void bignum_set_length(int n, int length):
	save_int(n, length)


int bignum_limb(int n, int i):
	return load_int(n + 4 + i * 4)


void bignum_set_limb(int n, int i, int value):
	save_int(n + 4 + i * 4, value & 0xffff)


void bignum_normalize(int n):
	int length = bignum_length(n)
	while ((length > 1) & (bignum_limb(n, length - 1) == 0)):
		length = length - 1
	bignum_set_length(n, length)


void bignum_set_u32(int n, int value):
	bignum_clear(n)
	bignum_set_limb(n, 0, value & 0xffff)
	bignum_set_limb(n, 1, (value >> 16) & 0xffff)
	if (bignum_limb(n, 1) != 0):
		bignum_set_length(n, 2)
	else:
		bignum_set_length(n, 1)


void bignum_copy(int dst, int src):
	int i = 0
	while (i < bignum_limb_count()):
		bignum_set_limb(dst, i, bignum_limb(src, i))
		i = i + 1
	bignum_set_length(dst, bignum_length(src))


int bignum_is_zero(int n):
	return (bignum_length(n) == 1) & (bignum_limb(n, 0) == 0)


void bignum_add_small(int n, int add):
	int carry = add
	int i = 0
	while (carry != 0):
		if (i >= bignum_limb_count()):
			error(c"bignum overflow")
		int value = bignum_limb(n, i) + carry
		bignum_set_limb(n, i, value & 0xffff)
		carry = value >> 16
		i = i + 1
	if (i > bignum_length(n)):
		bignum_set_length(n, i)
	bignum_normalize(n)


int bignum_low32(int n):
	return bignum_limb(n, 0) + (bignum_limb(n, 1) << 16)


int bignum_bits_32_51(int n):
	return bignum_limb(n, 2) + ((bignum_limb(n, 3) & 15) << 16)


void bignum_set_bit(int n, int bit):
	int limb = bit / 16
	if (limb >= bignum_limb_count()):
		error(c"bignum overflow")
	int value = bignum_limb(n, limb) | (1 << (bit % 16))
	bignum_set_limb(n, limb, value)
	if (limb + 1 > bignum_length(n)):
		bignum_set_length(n, limb + 1)


void bignum_mul_small(int n, int mul):
	int carry = 0
	int i = 0
	int length = bignum_length(n)
	while (i < length):
		int value = bignum_limb(n, i) * mul + carry
		bignum_set_limb(n, i, value & 0xffff)
		carry = value >> 16
		i = i + 1
	while (carry != 0):
		if (i >= bignum_limb_count()):
			error(c"bignum overflow")
		bignum_set_limb(n, i, carry & 0xffff)
		carry = carry >> 16
		i = i + 1
	bignum_set_length(n, i)
	bignum_normalize(n)


void bignum_mul_pow10(int n, int pow):
	while (pow > 0):
		bignum_mul_small(n, 10)
		pow = pow - 1


void bignum_shl1(int n):
	int carry = 0
	int i = 0
	int length = bignum_length(n)
	while (i < length):
		int value = (bignum_limb(n, i) << 1) + carry
		bignum_set_limb(n, i, value & 0xffff)
		carry = value >> 16
		i = i + 1
	if (carry != 0):
		if (i >= bignum_limb_count()):
			error(c"bignum overflow")
		bignum_set_limb(n, i, carry)
		i = i + 1
	bignum_set_length(n, i)
	bignum_normalize(n)


void bignum_shl_bits(int n, int bits):
	while (bits > 0):
		bignum_shl1(n)
		bits = bits - 1


int bignum_cmp(int a, int b):
	bignum_normalize(a)
	bignum_normalize(b)
	int al = bignum_length(a)
	int bl = bignum_length(b)
	if (al > bl):
		return 1
	if (al < bl):
		return -1
	int i = al - 1
	while (i >= 0):
		int av = bignum_limb(a, i)
		int bv = bignum_limb(b, i)
		if (av > bv):
			return 1
		if (av < bv):
			return -1
		i = i - 1
	return 0


void bignum_sub(int a, int b):
	int borrow = 0
	int i = 0
	int length = bignum_length(a)
	while (i < length):
		int value = bignum_limb(a, i) - bignum_limb(b, i) - borrow
		if (value < 0):
			value = value + 65536
			borrow = 1
		else:
			borrow = 0
		bignum_set_limb(a, i, value)
		i = i + 1
	bignum_normalize(a)


int bignum_bit_length(int n):
	bignum_normalize(n)
	if (bignum_is_zero(n)):
		return 0
	int i = bignum_length(n) - 1
	int value = bignum_limb(n, i)
	int bits = 0
	while (value > 0):
		bits = bits + 1
		value = value >> 1
	return i * 16 + bits


int bignum_get_bit(int n, int bit):
	int limb = bit / 16
	if (limb >= bignum_length(n)):
		return 0
	return (bignum_limb(n, limb) >> (bit % 16)) & 1


int bignum_is_power_of_two(int n, int bit):
	if (bignum_bit_length(n) != bit + 1):
		return 0
	int i = 0
	while (i < bit):
		if (bignum_get_bit(n, i)):
			return 0
		i = i + 1
	return bignum_get_bit(n, bit)


int bignum_floor_log2_ratio(int num, int den):
	int exponent = bignum_bit_length(num) - bignum_bit_length(den)
	int scaled_den = bignum_new()
	bignum_copy(scaled_den, den)
	if (exponent > 0):
		bignum_shl_bits(scaled_den, exponent)
	if (exponent < 0):
		int scaled_num = bignum_new()
		bignum_copy(scaled_num, num)
		bignum_shl_bits(scaled_num, 0 - exponent)
		if (bignum_cmp(scaled_num, den) < 0):
			exponent = exponent - 1
		free(scaled_num)
	else if (bignum_cmp(num, scaled_den) < 0):
		exponent = exponent - 1
	free(scaled_den)
	return exponent


int bignum_div_scaled_to_int(int num, int den, int shift, int rem):
	int dividend = bignum_new()
	int divisor = bignum_new()
	bignum_copy(dividend, num)
	bignum_copy(divisor, den)
	if (shift >= 0):
		bignum_shl_bits(dividend, shift)
	else:
		bignum_shl_bits(divisor, 0 - shift)

	bignum_clear(rem)
	int quotient = 0
	int bit = bignum_bit_length(dividend) - 1
	while (bit >= 0):
		bignum_shl1(rem)
		if (bignum_get_bit(dividend, bit)):
			bignum_add_small(rem, 1)
		if (bignum_cmp(rem, divisor) >= 0):
			bignum_sub(rem, divisor)
			if (bit >= 31):
				error(c"bignum quotient overflow")
			quotient = quotient + (1 << bit)
		bit = bit - 1

	free(dividend)
	free(divisor)
	return quotient


void bignum_div_scaled_to_bignum(int num, int den, int shift, int rem, int quotient):
	int dividend = bignum_new()
	int divisor = bignum_new()
	bignum_copy(dividend, num)
	bignum_copy(divisor, den)
	if (shift >= 0):
		bignum_shl_bits(dividend, shift)
	else:
		bignum_shl_bits(divisor, 0 - shift)

	bignum_clear(rem)
	bignum_clear(quotient)
	int bit = bignum_bit_length(dividend) - 1
	while (bit >= 0):
		bignum_shl1(rem)
		if (bignum_get_bit(dividend, bit)):
			bignum_add_small(rem, 1)
		if (bignum_cmp(rem, divisor) >= 0):
			bignum_sub(rem, divisor)
			bignum_set_bit(quotient, bit)
		bit = bit - 1

	free(dividend)
	free(divisor)


int bignum_round_up(int rem, int den, int quotient):
	int twice = bignum_new()
	bignum_copy(twice, rem)
	bignum_shl1(twice)
	int cmp = bignum_cmp(twice, den)
	free(twice)
	if (cmp > 0):
		return 1
	if ((cmp == 0) & ((quotient & 1) == 1)):
		return 1
	return 0


int bignum_round_up_big(int rem, int den, int quotient):
	int twice = bignum_new()
	bignum_copy(twice, rem)
	bignum_shl1(twice)
	int cmp = bignum_cmp(twice, den)
	free(twice)
	if (cmp > 0):
		return 1
	if ((cmp == 0) & bignum_get_bit(quotient, 0)):
		return 1
	return 0
