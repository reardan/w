# Fixed-width unsigned integers in byte buffers, big- and little-endian.
# Loads assemble unsigned bytes, so a 32-bit load follows the masked
# 32-bit-word convention (zero-extended on 64-bit targets, wrapping to
# negative on 32-bit ones); stores write the low bytes of v.
import structures.string


int load_be16(char* p):
	return ((p[0] & 255) << 8) | (p[1] & 255)


int load_be24(char* p):
	return ((p[0] & 255) << 16) | ((p[1] & 255) << 8) | (p[2] & 255)


int load_be32(char* p):
	return ((p[0] & 255) << 24) | ((p[1] & 255) << 16) | ((p[2] & 255) << 8) | (p[3] & 255)


int load_le16(char* p):
	return (p[0] & 255) | ((p[1] & 255) << 8)


int load_le32(char* p):
	return (p[0] & 255) | ((p[1] & 255) << 8) | ((p[2] & 255) << 16) | ((p[3] & 255) << 24)


void store_be16(char* p, int v):
	p[0] = (v >> 8) & 255
	p[1] = v & 255


void store_be24(char* p, int v):
	p[0] = (v >> 16) & 255
	p[1] = (v >> 8) & 255
	p[2] = v & 255


void store_be32(char* p, int v):
	p[0] = (v >> 24) & 255
	p[1] = (v >> 16) & 255
	p[2] = (v >> 8) & 255
	p[3] = v & 255


void store_le16(char* p, int v):
	p[0] = v & 255
	p[1] = (v >> 8) & 255


void store_le32(char* p, int v):
	p[0] = v & 255
	p[1] = (v >> 8) & 255
	p[2] = (v >> 16) & 255
	p[3] = (v >> 24) & 255


# Big-endian appends to a string_builder (wire headers, length prefixes).
void string_append_be16(string_builder* b, int v):
	string_append_char(b, (v >> 8) & 255)
	string_append_char(b, v & 255)


void string_append_be24(string_builder* b, int v):
	string_append_char(b, (v >> 16) & 255)
	string_append_be16(b, v)


void string_append_be32(string_builder* b, int v):
	string_append_be16(b, (v >> 16) & 65535)
	string_append_be16(b, v)
