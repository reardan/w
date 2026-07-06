import lib.lib
import structures.string


struct uuid:
	char b0
	char b1
	char b2
	char b3
	char b4
	char b5
	char b6
	char b7
	char b8
	char b9
	char b10
	char b11
	char b12
	char b13
	char b14
	char b15


int uuid_hex_value(int ch):
	if (('0' <= ch) & (ch <= '9')):
		return ch - '0'
	if (('a' <= ch) & (ch <= 'f')):
		return ch - 'a' + 10
	if (('A' <= ch) & (ch <= 'F')):
		return ch - 'A' + 10
	return -1


int uuid_hex_char(int value):
	if (value < 10):
		return '0' + value
	return 'a' + value - 10


int uuid_parse(char* text, uuid* out):
	if ((text == 0) | (out == 0)):
		return 0
	if (strlen(text) != 36):
		return 0
	char* bytes = cast(char*, out)
	int text_index = 0
	int byte_index = 0
	while (byte_index < 16):
		if ((text_index == 8) | (text_index == 13) | (text_index == 18) | (text_index == 23)):
			if (text[text_index] != '-'):
				return 0
			text_index = text_index + 1
		int hi = uuid_hex_value(text[text_index])
		int lo = uuid_hex_value(text[text_index + 1])
		if ((hi < 0) | (lo < 0)):
			return 0
		bytes[byte_index] = (hi << 4) | lo
		byte_index = byte_index + 1
		text_index = text_index + 2
	return 1


char* uuid_format(uuid id):
	char* bytes = cast(char*, &id)
	char* out = malloc(37)
	int text_index = 0
	int byte_index = 0
	while (byte_index < 16):
		if ((text_index == 8) | (text_index == 13) | (text_index == 18) | (text_index == 23)):
			out[text_index] = '-'
			text_index = text_index + 1
		int value = bytes[byte_index] & 255
		out[text_index] = uuid_hex_char((value >> 4) & 15)
		out[text_index + 1] = uuid_hex_char(value & 15)
		text_index = text_index + 2
		byte_index = byte_index + 1
	out[36] = 0
	return out


uuid uuid4():
	uuid id
	char* bytes = cast(char*, &id)
	int i = 0
	while (i < 16):
		bytes[i] = 0
		i = i + 1
	int fd = open(c"/dev/urandom", 0, 0)
	if (fd >= 0):
		int got = read(fd, bytes, 16)
		close(fd)
		if (got < 16):
			i = got
			if (i < 0):
				i = 0
			while (i < 16):
				bytes[i] = i * 17 + 3
				i = i + 1
	else:
		while (i < 16):
			bytes[i] = i * 17 + 3
			i = i + 1
	bytes[6] = (bytes[6] & 15) | 64
	bytes[8] = (bytes[8] & 63) | 128
	return id
