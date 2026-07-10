/*
RFC 4648 base64 and hex codecs, pure W (plan 11 phase 1, issue #193).

base64 uses the standard alphabet (A-Za-z0-9+/) with '=' padding. The
decoder is strict: it rejects characters outside the alphabet (including
whitespace), lengths that are not a multiple of four, misplaced or
excessive padding, and encodings whose unused trailing bits are not zero
(so every accepted input has exactly one canonical encoding — the right
default for the certificate and key material this module feeds).

hex encodes to lowercase and decodes either case, rejecting odd lengths
and non-hex characters.

All returned buffers are malloc'd, NUL-terminated one byte past the
payload, and owned by the caller (free() them). Decoders return 0 and set
*out_len to 0 on invalid input, so callers can fail closed.
*/
import lib.memory


char* base64_alphabet():
	return c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


# Encoded length in characters for len input bytes, excluding the NUL.
int base64_encoded_length(int len):
	if (len <= 0):
		return 0
	return ((len + 2) / 3) * 4


# Encodes len bytes at data. Returns a malloc'd NUL-terminated string of
# base64_encoded_length(len) characters.
char* base64_encode(char* data, int len):
	if (len < 0):
		len = 0
	char* alphabet = base64_alphabet()
	char* out = malloc(base64_encoded_length(len) + 1)
	int i = 0
	int o = 0
	while (i + 3 <= len):
		int v = ((data[i] & 255) << 16) | ((data[i + 1] & 255) << 8) | (data[i + 2] & 255)
		out[o] = alphabet[(v >> 18) & 63]
		out[o + 1] = alphabet[(v >> 12) & 63]
		out[o + 2] = alphabet[(v >> 6) & 63]
		out[o + 3] = alphabet[v & 63]
		i = i + 3
		o = o + 4
	int rem = len - i
	if (rem == 1):
		int v = (data[i] & 255) << 16
		out[o] = alphabet[(v >> 18) & 63]
		out[o + 1] = alphabet[(v >> 12) & 63]
		out[o + 2] = '='
		out[o + 3] = '='
		o = o + 4
	else if (rem == 2):
		int v = ((data[i] & 255) << 16) | ((data[i + 1] & 255) << 8)
		out[o] = alphabet[(v >> 18) & 63]
		out[o + 1] = alphabet[(v >> 12) & 63]
		out[o + 2] = alphabet[(v >> 6) & 63]
		out[o + 3] = '='
		o = o + 4
	out[o] = 0
	return out


# The 0..63 value of one base64 alphabet character, or -1 for anything
# else (including '=' — the decoder handles padding by position).
int base64_decode_char(int ch):
	if ((ch >= 'A') & (ch <= 'Z')):
		return ch - 'A'
	if ((ch >= 'a') & (ch <= 'z')):
		return ch - 'a' + 26
	if ((ch >= '0') & (ch <= '9')):
		return ch - '0' + 52
	if (ch == '+'):
		return 62
	if (ch == '/'):
		return 63
	return -1


# Decodes len characters of base64 text. Returns a malloc'd buffer with a
# NUL one byte past the payload and stores the decoded byte count in
# *out_len; returns 0 (with *out_len = 0) on any invalid input.
char* base64_decode(char* text, int len, int* out_len):
	*out_len = 0
	if (len < 0):
		return 0
	if ((len % 4) != 0):
		return 0
	if (len == 0):
		char* empty = malloc(1)
		empty[0] = 0
		return empty
	# Padding may only be the last one or two characters.
	int pad = 0
	if ((text[len - 1] & 255) == '='):
		pad = 1
		if ((text[len - 2] & 255) == '='):
			pad = 2
	char* out = malloc((len / 4) * 3 + 1)
	int i = 0
	int o = 0
	while (i < len):
		int chars = 4
		if ((i + 4 == len) & (pad > 0)):
			chars = 4 - pad
		int v = 0
		int j = 0
		while (j < chars):
			int d = base64_decode_char(text[i + j] & 255)
			if (d < 0):
				free(out)
				return 0
			v = (v << 6) | d
			j = j + 1
		if (chars == 4):
			out[o] = (v >> 16) & 255
			out[o + 1] = (v >> 8) & 255
			out[o + 2] = v & 255
			o = o + 3
		else if (chars == 3):
			# 18 bits carry 2 bytes; the low 2 bits must be zero padding.
			if ((v & 3) != 0):
				free(out)
				return 0
			out[o] = (v >> 10) & 255
			out[o + 1] = (v >> 2) & 255
			o = o + 2
		else if (chars == 2):
			# 12 bits carry 1 byte; the low 4 bits must be zero padding.
			if ((v & 15) != 0):
				free(out)
				return 0
			out[o] = (v >> 4) & 255
			o = o + 1
		else:
			# chars == 1 ("x===") never decodes to whole bytes.
			free(out)
			return 0
		i = i + 4
	out[o] = 0
	*out_len = o
	return out


# Encodes len bytes at data as 2 * len lowercase hex characters. Returns
# a malloc'd NUL-terminated string.
char* hex_encode(char* data, int len):
	if (len < 0):
		len = 0
	char* digits = c"0123456789abcdef"
	char* out = malloc(len * 2 + 1)
	int i = 0
	while (i < len):
		int b = data[i] & 255
		out[i * 2] = digits[(b >> 4) & 15]
		out[i * 2 + 1] = digits[b & 15]
		i = i + 1
	out[len * 2] = 0
	return out


# The 0..15 value of one hex digit (either case), or -1.
int hex_decode_char(int ch):
	if ((ch >= '0') & (ch <= '9')):
		return ch - '0'
	if ((ch >= 'a') & (ch <= 'f')):
		return ch - 'a' + 10
	if ((ch >= 'A') & (ch <= 'F')):
		return ch - 'A' + 10
	return -1


# Decodes len hex characters. Returns a malloc'd buffer with a NUL one
# byte past the payload and stores the decoded byte count in *out_len;
# returns 0 (with *out_len = 0) on odd lengths or non-hex characters.
char* hex_decode(char* text, int len, int* out_len):
	*out_len = 0
	if (len < 0):
		return 0
	if ((len % 2) != 0):
		return 0
	char* out = malloc(len / 2 + 1)
	int i = 0
	while (i < len):
		int hi = hex_decode_char(text[i] & 255)
		int lo = hex_decode_char(text[i + 1] & 255)
		if ((hi < 0) | (lo < 0)):
			free(out)
			return 0
		out[i / 2] = (hi << 4) | lo
		i = i + 2
	out[len / 2] = 0
	*out_len = len / 2
	return out
