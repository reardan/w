/*
Base85 codecs, pure W (stdlib parity P3.7d): Python's base64.b85encode /
b85decode (the RFC 1924 / git alphabet) and a85encode / a85decode
(Ascii85 as used by btoa, PostScript and PDF).

Both encode each 4-byte big-endian group as five base-85 digits. A short
final group is zero-filled; unless pad is set, the digits standing for
the fill bytes are dropped again (Python's pad=False default).

Ascii85 extras, matching Python:
- an all-zero 4-byte group encodes as 'z' (always on in a85encode);
- foldspaces encodes four spaces as 'y' (btoa) and accepts 'y' on decode;
- wrapcol > 0 inserts '\n' after at most every wrapcol characters
  (counting the '<~' frame; at least 2 with adobe, 1 without);
- adobe frames the output in '<~' ... '~>'; on decode, adobe requires the
  trailing '~>' and strips a leading '<~' if present;
- the decoder skips whitespace (" \t\n\r\v" by default, or a caller set
  through ascii85_decode_ignoring) and rejects 'z'/'y' inside a group,
  any other character outside '!'..'u', and groups above 2^32 - 1.
  As in Python a lone trailing digit is silently dropped.

The b85 decoder ignores nothing: any character outside the alphabet and
any group above 2^32 - 1 is an error. A short final group is filled with
'~' (digit 84) as Python does.

32-bit safety: a group is an unsigned 32-bit value, which overflows a
signed x86 int, so all group arithmetic here runs on two 16-bit halves.

Same conventions as libs/standard/crypto/base64.w: inputs are pointer +
length, returned buffers are malloc'd, NUL-terminated one byte past the
payload and owned by the caller. Decoders return 0 and set *out_len to 0
on invalid input.
*/
import lib.memory


# The RFC 1924 alphabet used by b85encode.
char* base85_alphabet():
	return c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+-;<=>?@^_`{|}~"


# Writes the five base-85 digits (most significant first) of the 32-bit
# group hi:lo (16-bit halves) to out[0..4], as alphabet characters or, for
# alphabet == 0, offset from '!' (Ascii85).
void base85_group_digits(int hi, int lo, char* alphabet, char* out):
	int k = 4
	while (k >= 0):
		int rh = hi % 85
		hi = hi / 85
		int mid = (rh << 16) | lo
		int d = mid % 85
		lo = mid / 85
		if (alphabet == 0): out[k] = '!' + d
		else: out[k] = alphabet[d]
		k = k - 1


# Decoding accumulator *hi:*lo (16-bit halves): multiplies by 85 and adds
# d; returns 0 once the value passes 2^32 - 1.
int base85_group_push(int* hi, int* lo, int d):
	int l = *lo * 85 + d
	int h = *hi * 85 + (l >> 16)
	*lo = l & 65535
	*hi = h
	if (h > 65535): return 0
	return 1


# Stores the 32-bit group hi:lo big-endian at out[0..3].
void base85_group_bytes(int hi, int lo, char* out):
	out[0] = (hi >> 8) & 255
	out[1] = hi & 255
	out[2] = (lo >> 8) & 255
	out[3] = lo & 255


# Encodes len bytes into out with group digits mapped by alphabet (b85) or
# offset from '!' (alphabet == 0, Ascii85). Returns characters written;
# out needs ((len + 3) / 4) * 5 bytes.
int base85_encode_core(char* data, int len, char* alphabet, int pad, int foldnuls, int foldspaces, char* out):
	int o = 0
	int i = 0
	while (i < len):
		int n = len - i
		if (n > 4): n = 4
		int hi = 0
		int lo = 0
		for j in range(4):
			int b = 0
			if (j < n): b = data[i + j] & 255
			if (j < 2): hi = (hi << 8) | b
			else: lo = (lo << 8) | b
		int keep = 5
		if ((n < 4) && (pad == 0)): keep = n + 1
		if ((foldnuls != 0) && (hi == 0) && (lo == 0) && (keep == 5)):
			out[o] = 'z'
			o = o + 1
		else if ((foldspaces != 0) && (hi == 8224) && (lo == 8224)):
			out[o] = 'y'
			o = o + 1
		else:
			# Digits past keep land in out's slack and are overwritten.
			base85_group_digits(hi, lo, alphabet, &out[o])
			o = o + keep
		i = i + 4
	return o


# Python b85encode(data, pad): RFC 1924 alphabet.
char* base85_encode(char* data, int len, int pad):
	if (len < 0): len = 0
	char* out = cast(char*, malloc(((len + 3) / 4) * 5 + 1))
	int o = base85_encode_core(data, len, base85_alphabet(), pad, 0, 0, out)
	out[o] = 0
	return out


# The 0..84 value of ch in the RFC 1924 alphabet, or -1.
int base85_digit(int ch):
	if ((ch >= '0') && (ch <= '9')): return ch - '0'
	if ((ch >= 'A') && (ch <= 'Z')): return ch - 'A' + 10
	if ((ch >= 'a') && (ch <= 'z')): return ch - 'a' + 36
	char* tail = c"!#$%&()*+-;<=>?@^_`{|}~"
	for k in range(23):
		if ((tail[k] & 255) == ch): return 62 + k
	return -1


# Python b85decode(text): returns 0 on a bad character or overflow.
char* base85_decode(char* text, int len, int* out_len):
	*out_len = 0
	if (len < 0): return 0
	int groups = (len + 4) / 5
	char* out = cast(char*, malloc(groups * 4 + 1))
	int o = 0
	int i = 0
	while (i < len):
		int hi = 0
		int lo = 0
		int n = len - i
		if (n > 5): n = 5
		for j in range(5):
			int d = 84
			if (j < n):
				d = base85_digit(text[i + j] & 255)
				if (d < 0):
					free(out)
					return 0
			if (base85_group_push(&hi, &lo, d) == 0):
				free(out)
				return 0
		# A short group of n digits carries n - 1 bytes; out has slack
		# for the whole quad.
		base85_group_bytes(hi, lo, &out[o])
		if (n == 5): o = o + 4
		else: o = o + n - 1
		i = i + 5
	out[o] = 0
	*out_len = o
	return out


# Python a85encode(data, foldspaces=, wrapcol=, pad=, adobe=).
char* ascii85_encode(char* data, int len, int foldspaces, int wrapcol, int pad, int adobe):
	if (len < 0): len = 0
	int core_cap = ((len + 3) / 4) * 5 + 2
	char* core = cast(char*, malloc(core_cap + 1))
	int n = 0
	if (adobe != 0):
		core[0] = '<'
		core[1] = '~'
		n = 2
	n = n + base85_encode_core(data, len, 0, pad, 1, foldspaces, &core[n])
	if (wrapcol < 0): wrapcol = 0
	if (wrapcol > 0):
		if ((adobe != 0) && (wrapcol < 2)): wrapcol = 2
	# Worst case: a newline per character plus one extra and the frame.
	char* out = cast(char*, malloc(2 * n + 4))
	int o = 0
	int last = 0
	for i in range(n):
		if ((wrapcol > 0) && (i > 0) && ((i % wrapcol) == 0)):
			out[o] = '\n'
			o = o + 1
			last = 0
		out[o] = core[i]
		o = o + 1
		last = last + 1
	free(core)
	if (adobe != 0):
		if ((wrapcol > 0) && (last + 2 > wrapcol)):
			out[o] = '\n'
			o = o + 1
		out[o] = '~'
		out[o + 1] = '>'
		o = o + 2
	out[o] = 0
	return out


int ascii85_ignored(int ch, char* ignorechars):
	if (ignorechars == 0): return 0
	int k = 0
	while (ignorechars[k] != 0):
		if ((ignorechars[k] & 255) == ch): return 1
		k = k + 1
	return 0


# Python a85decode(text, foldspaces=, adobe=, ignorechars=); ignorechars
# is a NUL-terminated set (0 ignores nothing).
char* ascii85_decode_ignoring(char* text, int len, int foldspaces, int adobe, char* ignorechars, int* out_len):
	*out_len = 0
	if (len < 0): return 0
	int start = 0
	int end = len
	if (adobe != 0):
		if ((len < 2) || ((text[len - 2] & 255) != '~') || ((text[len - 1] & 255) != '>')): return 0
		end = len - 2
		if ((len >= 2) && ((text[0] & 255) == '<') && ((text[1] & 255) == '~')): start = 2
		if (end < start): end = start
	# Each input character yields at most four bytes ('z' / 'y').
	char* out = cast(char*, malloc((end - start) * 4 + 1))
	int hi = 0
	int lo = 0
	int count = 0
	int o = 0
	int i = start
	while (i < end + 4):
		int ch = 'u'
		if (i < end): ch = text[i] & 255
		if ((ch >= '!') && (ch <= 'u')):
			if (base85_group_push(&hi, &lo, ch - '!') == 0):
				free(out)
				return 0
			count = count + 1
			if (count == 5):
				base85_group_bytes(hi, lo, &out[o])
				o = o + 4
				hi = 0
				lo = 0
				count = 0
		else if ((ch == 'z') || ((foldspaces != 0) && (ch == 'y'))):
			if (count != 0):
				free(out)
				return 0
			int fill = 0
			if (ch == 'y'): fill = ' '
			for k in range(4): out[o + k] = fill
			o = o + 4
		else if (ascii85_ignored(ch, ignorechars) == 0):
			free(out)
			return 0
		i = i + 1
	# The four 'u' fillers completed the last partial group (or sit unused
	# in a fresh one); drop the bytes they stand for, as Python does.
	int padding = 4 - count
	if (padding != 0):
		o = o - padding
		if (o < 0): o = 0
	out[o] = 0
	*out_len = o
	return out


# Python a85decode with the default ignorechars (ASCII whitespace).
char* ascii85_decode(char* text, int len, int foldspaces, int adobe, int* out_len):
	return ascii85_decode_ignoring(text, len, foldspaces, adobe, c" \t\n\r\x0b", out_len)
