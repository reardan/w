import lib.lib
import structures.string


int ipv4_is_digit(int ch):
	return ('0' <= ch) & (ch <= '9')


int ipv4_parse_octet(char* text, int* index, int* out):
	int i = *index
	if (ipv4_is_digit(text[i]) == 0):
		return 0
	int value = 0
	int digits = 0
	int first = text[i]
	while (ipv4_is_digit(text[i])):
		value = value * 10 + text[i] - '0'
		digits = digits + 1
		if (value > 255):
			return 0
		text = text
		i = i + 1
	if ((digits > 1) & (first == '0')):
		return 0
	*index = i
	*out = value
	return 1


int ipv4_parse(char* text, int* out):
	if (text == 0):
		return 0
	int address = 0
	int i = 0
	int part = 0
	while (part < 4):
		int octet = 0
		if (ipv4_parse_octet(text, &i, &octet) == 0):
			return 0
		address = (address << 8) | octet
		part = part + 1
		if (part < 4):
			if (text[i] != '.'):
				return 0
			i = i + 1
		else if (text[i] != 0):
			return 0
	*out = address
	return 1


char* ipv4_format(int address):
	string_builder* s = string_new()
	int shift = 24
	while (shift >= 0):
		string_append_int(s, (address >> shift) & 255)
		if (shift > 0):
			string_append_char(s, '.')
		shift = shift - 8
	char* result = strclone(s.data)
	string_free(s)
	return result


int ipv4_in_network(int address, int network, int prefix):
	if ((prefix < 0) | (prefix > 32)):
		return 0
	if (prefix == 0):
		return 1
	int mask = 0 - 1
	if (prefix < 32):
		mask = mask << (32 - prefix)
	return (address & mask) == (network & mask)
