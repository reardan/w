/*
RFC 4648 base32 and base32hex codecs, pure W (stdlib parity P3.7d).

Mirrors Python's base64.b32encode / b32decode / b32hexencode /
b32hexdecode. Encoders emit the uppercase alphabet with '=' padding to a
multiple of eight characters.

Decoders follow Python's validation exactly:
- the input length must be a multiple of eight ("Incorrect padding");
- the trailing '=' run must be 0, 1, 3, 4 or 6 characters long;
- every other character must be in the alphabet (no whitespace, no '='
  in the middle);
- unused trailing bits of the final quantum are discarded, not checked
  (Python accepts "MZ======" and "MY======" alike).
The _opts variants add Python's options: casefold accepts lowercase
letters, and map01 (base32 only; 0 = off, otherwise the character the
digit '1' maps to, normally 'I' or 'L') maps the digit '0' to 'O' and
'1' to that character before validation (RFC 4648 section 2.4). As in
Python the mapping happens before casefolding, so map01 = 'l' only works
together with casefold.

Same conventions as libs/standard/crypto/base64.w: inputs are pointer +
length, returned buffers are malloc'd, NUL-terminated one byte past the
payload and owned by the caller. Decoders return 0 and set *out_len to 0
on invalid input.
*/
import lib.memory


char* base32_alphabet():
	return c"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"


char* base32hex_alphabet():
	return c"0123456789ABCDEFGHIJKLMNOPQRSTUV"


# Encoded length in characters for len input bytes, excluding the NUL.
int base32_encoded_length(int len):
	if (len <= 0): return 0
	return ((len + 4) / 5) * 8


char* base32_encode_with(char* data, int len, char* alphabet):
	if (len < 0): len = 0
	int total = base32_encoded_length(len)
	char* out = cast(char*, malloc(total + 1))
	# acc never holds more than 12 pending bits, so it fits any int.
	int acc = 0
	int bits = 0
	int o = 0
	for i in range(len):
		acc = (acc << 8) | (data[i] & 255)
		bits = bits + 8
		while (bits >= 5):
			bits = bits - 5
			out[o] = alphabet[(acc >> bits) & 31]
			o = o + 1
		acc = acc & ((1 << bits) - 1)
	if (bits > 0):
		out[o] = alphabet[(acc << (5 - bits)) & 31]
		o = o + 1
	while (o < total):
		out[o] = '='
		o = o + 1
	out[o] = 0
	return out


# Encodes len bytes at data with the RFC 4648 base32 alphabet.
char* base32_encode(char* data, int len):
	return base32_encode_with(data, len, base32_alphabet())


# Encodes len bytes at data with the base32hex ("extended hex") alphabet.
char* base32hex_encode(char* data, int len):
	return base32_encode_with(data, len, base32hex_alphabet())


# The 0..31 value of ch in the base32 (hex == 0) or base32hex (hex != 0)
# alphabet, or -1. Only uppercase letters are digits.
int base32_digit(int ch, int hex):
	if (hex == 0):
		if ((ch >= 'A') && (ch <= 'Z')): return ch - 'A'
		if ((ch >= '2') && (ch <= '7')): return ch - '2' + 26
		return -1
	if ((ch >= '0') && (ch <= '9')): return ch - '0'
	if ((ch >= 'A') && (ch <= 'V')): return ch - 'A' + 10
	return -1


# Applies Python's map01 translation and casefold to one input character.
int base32_normalize_char(int ch, int casefold, int map01):
	if (map01 != 0):
		if (ch == '0'): ch = 'O'
		else if (ch == '1'): ch = map01 & 255
	if ((casefold != 0) && (ch >= 'a') && (ch <= 'z')): ch = ch - 32
	return ch


char* base32_decode_with(char* text, int len, int hex, int casefold, int map01, int* out_len):
	*out_len = 0
	if (len < 0): return 0
	if ((len % 8) != 0): return 0
	int pad = 0
	while ((pad < len) && ((text[len - 1 - pad] & 255) == '=')):
		pad = pad + 1
	if ((pad != 0) && (pad != 1) && (pad != 3) && (pad != 4) && (pad != 6)): return 0
	int chars = len - pad
	char* out = cast(char*, malloc((len / 8) * 5 + 1))
	int acc = 0
	int bits = 0
	int o = 0
	for i in range(chars):
		int ch = base32_normalize_char(text[i] & 255, casefold, map01)
		int d = base32_digit(ch, hex)
		if (d < 0):
			free(out)
			return 0
		acc = ((acc << 5) | d) & 4095
		bits = bits + 5
		if (bits >= 8):
			bits = bits - 8
			out[o] = (acc >> bits) & 255
			o = o + 1
	out[o] = 0
	*out_len = o
	return out


# Decodes len characters of base32 text (Python b32decode(s)).
char* base32_decode(char* text, int len, int* out_len):
	return base32_decode_with(text, len, 0, 0, 0, out_len)


# Python b32decode(s, casefold, map01); map01 is 0 for None.
char* base32_decode_opts(char* text, int len, int casefold, int map01, int* out_len):
	return base32_decode_with(text, len, 0, casefold, map01, out_len)


# Decodes len characters of base32hex text (Python b32hexdecode(s)).
char* base32hex_decode(char* text, int len, int* out_len):
	return base32_decode_with(text, len, 1, 0, 0, out_len)


# Python b32hexdecode(s, casefold).
char* base32hex_decode_opts(char* text, int len, int casefold, int* out_len):
	return base32_decode_with(text, len, 1, casefold, 0, out_len)
