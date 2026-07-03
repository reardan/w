import lib.lib
import lib.assert


int utf8_validate_bytes(char* data, int length):
	int i = 0
	while (i < length):
		int c = data[i] & 255
		int need = 0
		int codepoint = 0
		if (c < 128):
			i = i + 1
		else if ((c >= 194) & (c <= 223)):
			need = 1
			codepoint = c & 31
		else if ((c >= 224) & (c <= 239)):
			need = 2
			codepoint = c & 15
		else if ((c >= 240) & (c <= 244)):
			need = 3
			codepoint = c & 7
		else:
			return 0
		if (need > 0):
			if (i + need >= length):
				return 0
			int j = 1
			while (j <= need):
				int d = data[i + j] & 255
				if ((d < 128) | (d > 191)):
					return 0
				codepoint = (codepoint << 6) | (d & 63)
				j = j + 1
			if ((need == 1) & (codepoint < 128)):
				return 0
			if ((need == 2) & (codepoint < 2048)):
				return 0
			if ((need == 3) & (codepoint < 65536)):
				return 0
			if ((codepoint >= 55296) & (codepoint <= 57343)):
				return 0
			if (codepoint > 1114111):
				return 0
			i = i + need + 1
	return 1


int utf8_validate(string s):
	return utf8_validate_bytes(s.data, s.length)


int utf8_next(string s, int byte_index):
	assert1(byte_index >= 0)
	assert1(byte_index < s.length)
	int c = s.data[byte_index] & 255
	if (c < 128):
		return byte_index + 1
	if (c < 224):
		return byte_index + 2
	if (c < 240):
		return byte_index + 3
	return byte_index + 4


int utf8_codepoint_count(string s):
	int count = 0
	int i = 0
	while (i < s.length):
		i = utf8_next(s, i)
		count = count + 1
	return count


int utf8_equals(string a, string b):
	if (a.length != b.length):
		return 0
	int i = 0
	while (i < a.length):
		if (a.data[i] != b.data[i]):
			return 0
		i = i + 1
	return 1


char* cstr(string s):
	int i = 0
	while (i < s.length):
		assert1(s.data[i] != 0)
		i = i + 1
	assert1(s.data[s.length] == 0)
	return s.data


void utf8_write(int file, string s):
	write(file, s.data, s.length)


void utf8_print(string s):
	utf8_write(1, s)
