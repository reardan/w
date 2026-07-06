import lib.lib
import libs.standard.crypto.bytes


int hex_digit_value(int c):
	if ((c >= '0') & (c <= '9')):
		return c - '0'
	if ((c >= 'a') & (c <= 'f')):
		return c - 'a' + 10
	if ((c >= 'A') & (c <= 'F')):
		return c - 'A' + 10
	return -1


int hex_digit_char(int value):
	if (value < 10):
		return '0' + value
	return 'a' + value - 10


char* hex_encode(char* data, int length):
	char* out = malloc(length * 2 + 1)
	if (out == 0):
		return 0
	int i = 0
	while (i < length):
		int byte = data[i] & 255
		out[i * 2] = hex_digit_char(byte >> 4)
		out[i * 2 + 1] = hex_digit_char(byte & 15)
		i = i + 1
	out[length * 2] = 0
	return out


bytes_result hex_decode(char* text):
	int length = strlen(text)
	if (length % 2 != 0):
		return bytes_error(c"hex input length must be even")
	bytes_result result = bytes_alloc_ok(length / 2)
	if (result.ok == 0):
		return result
	int i = 0
	while (i < length):
		int high = hex_digit_value(text[i])
		int low = hex_digit_value(text[i + 1])
		if ((high < 0) | (low < 0)):
			bytes_result_free(result)
			return bytes_error(c"invalid hex digit")
		result.data[i / 2] = (high << 4) | low
		i = i + 2
	return result
