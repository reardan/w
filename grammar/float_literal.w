int token_is_float_literal():
	if ((token[0] < '0') | (token[0] > '9')):
		return 0
	if ((token[0] == '0') & (token[1] == 'x')):
		return 0
	int i = 0
	while (token[i]):
		if ((token[i] == '.') | (token[i] == 'e') | (token[i] == 'E')):
			return 1
		i = i + 1
	return 0


int float64_literal_lo
int float64_literal_hi


int parse_exponent_part(int i):
	int sign = 1
	int exponent = 0
	if (token[i] == '+'):
		i = i + 1
	else if (token[i] == '-'):
		sign = -1
		i = i + 1
	if ((token[i] < '0') | (token[i] > '9')):
		error(c"invalid float exponent")
	while ((token[i] >= '0') & (token[i] <= '9')):
		exponent = exponent * 10 + token[i] - '0'
		i = i + 1
	if (token[i] != 0):
		error(c"invalid float literal")
	return exponent * sign


int float32_bits_from_token():
	int mantissa = bignum_new()
	int denominator = bignum_new()
	bignum_set_u32(denominator, 1)

	int i = 0
	int frac_digits = 0
	int saw_dot = 0
	int exponent = 0
	while (token[i]):
		if ((token[i] >= '0') & (token[i] <= '9')):
			bignum_mul_small(mantissa, 10)
			bignum_add_small(mantissa, token[i] - '0')
			if (saw_dot):
				frac_digits = frac_digits + 1
		else if (token[i] == '.'):
			if (saw_dot):
				error(c"invalid float literal")
			saw_dot = 1
		else if ((token[i] == 'e') | (token[i] == 'E')):
			exponent = parse_exponent_part(i + 1)
			i = strlen(token) - 1
		else:
			error(c"invalid float literal")
		i = i + 1

	exponent = exponent - frac_digits
	if (exponent >= 0):
		bignum_mul_pow10(mantissa, exponent)
	else:
		bignum_mul_pow10(denominator, 0 - exponent)

	if (bignum_is_zero(mantissa)):
		bignum_free(mantissa)
		bignum_free(denominator)
		return 0

	int bits = 0
	int binary_exponent = bignum_floor_log2_ratio(mantissa, denominator)
	int remainder = bignum_new()
	int quotient
	if (binary_exponent > 127):
		bits = 0x7f800000
	else if (binary_exponent >= -126):
		quotient = bignum_div_scaled_to_int(mantissa, denominator, 23 - binary_exponent, remainder)
		if (bignum_round_up(remainder, denominator, quotient)):
			quotient = quotient + 1
		if (quotient == 0x1000000):
			quotient = 0x800000
			binary_exponent = binary_exponent + 1
		if (binary_exponent > 127):
			bits = 0x7f800000
		else:
			bits = ((binary_exponent + 127) << 23) + (quotient - 0x800000)
	else:
		quotient = bignum_div_scaled_to_int(mantissa, denominator, 149, remainder)
		if (bignum_round_up(remainder, denominator, quotient)):
			quotient = quotient + 1
		bits = quotient

	bignum_free(remainder)
	bignum_free(mantissa)
	bignum_free(denominator)
	return bits


void float64_bits_from_token():
	int mantissa = bignum_new()
	int denominator = bignum_new()
	bignum_set_u32(denominator, 1)

	int i = 0
	int frac_digits = 0
	int saw_dot = 0
	int exponent = 0
	while (token[i]):
		if ((token[i] >= '0') & (token[i] <= '9')):
			bignum_mul_small(mantissa, 10)
			bignum_add_small(mantissa, token[i] - '0')
			if (saw_dot):
				frac_digits = frac_digits + 1
		else if (token[i] == '.'):
			if (saw_dot):
				error(c"invalid float literal")
			saw_dot = 1
		else if ((token[i] == 'e') | (token[i] == 'E')):
			exponent = parse_exponent_part(i + 1)
			i = strlen(token) - 1
		else:
			error(c"invalid float literal")
		i = i + 1

	exponent = exponent - frac_digits
	if (exponent >= 0):
		bignum_mul_pow10(mantissa, exponent)
	else:
		bignum_mul_pow10(denominator, 0 - exponent)

	float64_literal_lo = 0
	float64_literal_hi = 0
	if (bignum_is_zero(mantissa)):
		bignum_free(mantissa)
		bignum_free(denominator)
		return;

	int binary_exponent = bignum_floor_log2_ratio(mantissa, denominator)
	int remainder = bignum_new()
	int quotient = bignum_new()
	if (binary_exponent > 1023):
		float64_literal_hi = 0x7ff00000
	else if (binary_exponent >= -1022):
		bignum_div_scaled_to_bignum(mantissa, denominator, 52 - binary_exponent, remainder, quotient)
		if (bignum_round_up_big(remainder, denominator, quotient)):
			bignum_add_small(quotient, 1)
		if (bignum_is_power_of_two(quotient, 53)):
			bignum_clear(quotient)
			bignum_set_bit(quotient, 52)
			binary_exponent = binary_exponent + 1
		if (binary_exponent > 1023):
			float64_literal_hi = 0x7ff00000
		else:
			int hidden = bignum_new()
			bignum_set_bit(hidden, 52)
			bignum_sub(quotient, hidden)
			float64_literal_lo = bignum_low32(quotient)
			float64_literal_hi = ((binary_exponent + 1023) << 20) + bignum_bits_32_51(quotient)
			bignum_free(hidden)
	else:
		bignum_div_scaled_to_bignum(mantissa, denominator, 1074, remainder, quotient)
		if (bignum_round_up_big(remainder, denominator, quotient)):
			bignum_add_small(quotient, 1)
		if (bignum_is_power_of_two(quotient, 52)):
			float64_literal_lo = 0
			float64_literal_hi = 0x00100000
		else:
			float64_literal_lo = bignum_low32(quotient)
			float64_literal_hi = bignum_bits_32_51(quotient)

	bignum_free(quotient)
	bignum_free(remainder)
	bignum_free(mantissa)
	bignum_free(denominator)


int float_literal():
	if (token_is_float_literal() == 0):
		return 0
	if (word_size == 8):
		float64_bits_from_token()
		mov_rax_int64_halves(float64_literal_lo, float64_literal_hi)
		return float64_value_type
	mov_eax_int32(float32_bits_from_token())
	return float32_value_type
