import lib.lib
import libs.standard.crypto.bytes


int base64_standard_char(int value):
	if (value < 26):
		return 'A' + value
	if (value < 52):
		return 'a' + value - 26
	if (value < 62):
		return '0' + value - 52
	if (value == 62):
		return '+'
	return '/'


int base64_urlsafe_char(int value):
	if (value == 62):
		return '-'
	if (value == 63):
		return '_'
	return base64_standard_char(value)


int base64_value(int c, int urlsafe):
	if ((c >= 'A') & (c <= 'Z')):
		return c - 'A'
	if ((c >= 'a') & (c <= 'z')):
		return c - 'a' + 26
	if ((c >= '0') & (c <= '9')):
		return c - '0' + 52
	if (c == '+'):
		return 62
	if (c == '/'):
		return 63
	if ((urlsafe != 0) & (c == '-')):
		return 62
	if ((urlsafe != 0) & (c == '_')):
		return 63
	return -1


char* base64_encode_with_urlsafe(char* data, int length, int urlsafe):
	int out_length = ((length + 2) / 3) * 4
	char* out = malloc(out_length + 1)
	if (out == 0):
		return 0
	int i = 0
	int j = 0
	while (i + 2 < length):
		int b0 = data[i] & 255
		int b1 = data[i + 1] & 255
		int b2 = data[i + 2] & 255
		if (urlsafe):
			out[j] = base64_urlsafe_char(b0 >> 2)
			out[j + 1] = base64_urlsafe_char(((b0 & 3) << 4) | (b1 >> 4))
			out[j + 2] = base64_urlsafe_char(((b1 & 15) << 2) | (b2 >> 6))
			out[j + 3] = base64_urlsafe_char(b2 & 63)
		else:
			out[j] = base64_standard_char(b0 >> 2)
			out[j + 1] = base64_standard_char(((b0 & 3) << 4) | (b1 >> 4))
			out[j + 2] = base64_standard_char(((b1 & 15) << 2) | (b2 >> 6))
			out[j + 3] = base64_standard_char(b2 & 63)
		i = i + 3
		j = j + 4
	if (i < length):
		int b0 = data[i] & 255
		int b1 = 0
		if (i + 1 < length):
			b1 = data[i + 1] & 255
		if (urlsafe):
			out[j] = base64_urlsafe_char(b0 >> 2)
			out[j + 1] = base64_urlsafe_char(((b0 & 3) << 4) | (b1 >> 4))
			if (i + 1 < length):
				out[j + 2] = base64_urlsafe_char((b1 & 15) << 2)
			else:
				out[j + 2] = '='
		else:
			out[j] = base64_standard_char(b0 >> 2)
			out[j + 1] = base64_standard_char(((b0 & 3) << 4) | (b1 >> 4))
			if (i + 1 < length):
				out[j + 2] = base64_standard_char((b1 & 15) << 2)
			else:
				out[j + 2] = '='
		out[j + 3] = '='
	out[out_length] = 0
	return out


char* base64_b64encode(char* data, int length):
	return base64_encode_with_urlsafe(data, length, 0)


char* base64_urlsafe_b64encode(char* data, int length):
	return base64_encode_with_urlsafe(data, length, 1)


bytes_result base64_decode_with_urlsafe(char* text, int urlsafe):
	int length = strlen(text)
	if (length % 4 != 0):
		return bytes_error(c"base64 input length must be a multiple of four")
	int pad = 0
	if (length > 0):
		if (text[length - 1] == '='):
			pad = pad + 1
		if (text[length - 2] == '='):
			pad = pad + 1
	int out_length = (length / 4) * 3 - pad
	bytes_result result = bytes_alloc_ok(out_length)
	if (result.ok == 0):
		return result
	int i = 0
	int j = 0
	while (i < length):
		int last_chunk = i + 4 == length
		int c0 = text[i]
		int c1 = text[i + 1]
		int c2 = text[i + 2]
		int c3 = text[i + 3]
		if ((c0 == '=') | (c1 == '=')):
			bytes_result_free(result)
			return bytes_error(c"invalid base64 padding")
		if (((c2 == '=') | (c3 == '=')) & (last_chunk == 0)):
			bytes_result_free(result)
			return bytes_error(c"invalid base64 padding")
		if ((c2 == '=') & (c3 != '=')):
			bytes_result_free(result)
			return bytes_error(c"invalid base64 padding")
		int v0 = base64_value(c0, urlsafe)
		int v1 = base64_value(c1, urlsafe)
		int v2 = 0
		int v3 = 0
		if (c2 != '='):
			v2 = base64_value(c2, urlsafe)
		if (c3 != '='):
			v3 = base64_value(c3, urlsafe)
		if ((v0 < 0) | (v1 < 0) | (v2 < 0) | (v3 < 0)):
			bytes_result_free(result)
			return bytes_error(c"invalid base64 character")
		if (j < out_length):
			result.data[j] = (v0 << 2) | (v1 >> 4)
			j = j + 1
		if ((c2 != '=') & (j < out_length)):
			result.data[j] = ((v1 & 15) << 4) | (v2 >> 2)
			j = j + 1
		if ((c3 != '=') & (j < out_length)):
			result.data[j] = ((v2 & 3) << 6) | v3
			j = j + 1
		i = i + 4
	return result


bytes_result base64_b64decode(char* text):
	return base64_decode_with_urlsafe(text, 0)


bytes_result base64_urlsafe_b64decode(char* text):
	return base64_decode_with_urlsafe(text, 1)
