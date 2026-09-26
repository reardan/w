# Hexadecimal digits and byte strings: the one digit table and parser
# behind lib.w's hex()/from_hex and every hex encoder/decoder in the
# libraries. Seed graph (lib.w imports it): plain syntax only.
import lib.memory


# Lowercase hex digit for 0..15.
int hex_digit(int n):
	return c"0123456789abcdef"[n]


# Uppercase hex digit for 0..15 (percent-encoding, RFC 3986 §2.1).
int hex_digit_upper(int n):
	return c"0123456789ABCDEF"[n]


# The 0..15 value of one hex digit (either case), or -1.
int hex_decode_char(int ch):
	if ((ch >= '0') && (ch <= '9')): return ch - '0'
	if ((ch >= 'a') && (ch <= 'f')): return ch - 'a' + 10
	if ((ch >= 'A') && (ch <= 'F')): return ch - 'A' + 10
	return 0 - 1


# Writes byte b as two lowercase hex characters at out[0], out[1].
void hex_put_byte(char* out, int b):
	out[0] = hex_digit((b >> 4) & 15)
	out[1] = hex_digit(b & 15)


# Encodes len bytes at data as 2 * len lowercase hex characters. Returns
# a malloc'd NUL-terminated string.
char* hex_encode(char* data, int len):
	if (len < 0): len = 0
	char* out = malloc(len * 2 + 1)
	for i in range(len): hex_put_byte(&out[i * 2], data[i] & 255)
	out[len * 2] = 0
	return out


# Decodes len hex characters. Returns a malloc'd buffer with a NUL one
# byte past the payload and stores the decoded byte count in *out_len;
# returns 0 (with *out_len = 0) on odd lengths or non-hex characters.
char* hex_decode(char* text, int len, int* out_len):
	*out_len = 0
	if (len < 0): return 0
	if ((len % 2) != 0): return 0
	char* out = malloc(len / 2 + 1)
	for i in range(0, len, 2):
		int hi = hex_decode_char(text[i] & 255)
		int lo = hex_decode_char(text[i + 1] & 255)
		if ((hi < 0) || (lo < 0)):
			free(out)
			return 0
		out[i / 2] = (hi << 4) | lo
	out[len / 2] = 0
	*out_len = len / 2
	return out


# Decodes the 2 * n hex characters at text into n bytes at out, with no
# validation and no allocation (fixed-size vectors and constants).
void hex_decode_into(char* text, char* out, int n):
	for i in range(n):
		out[i] = (hex_decode_char(text[i * 2] & 255) << 4) | hex_decode_char(text[i * 2 + 1] & 255)


# Decodes the hex digits of a NUL-terminated string, skipping every
# other character (spaces, separators) and a trailing odd digit, into a
# malloc'd buffer; stores the byte count in *out_len.
char* hex_decode_loose(char* text, int* out_len):
	int len = 0
	while (text[len] != 0): len = len + 1
	char* out = malloc(len / 2 + 1)
	int n = 0
	int hi = 0 - 1
	for i in range(len):
		int v = hex_decode_char(text[i] & 255)
		if (v >= 0):
			if (hi < 0): hi = v
			else:
				out[n] = (hi << 4) | v
				n = n + 1
				hi = 0 - 1
	out[n] = 0
	*out_len = n
	return out


# "0x" followed by the low `digits` nibbles of v, lowercase (malloc'd).
char* hex_fixed(int v, int digits):
	char* s = malloc(digits + 4)
	s[0] = '0'
	s[1] = 'x'
	s[digits + 2] = 0
	int i = digits - 1
	while (i >= 0):
		s[i + 2] = hex_digit(v & 15)
		v = v >> 4
		i = i - 1
	return s


# Decodes a NUL-terminated even-length hex string (test vectors, built-in
# constants) into a malloc'd buffer; 0 when it is not valid hex.
char* hex_bytes(char* text):
	int len = 0
	while (text[len] != 0): len = len + 1
	int n = 0
	return hex_decode(text, len, &n)
