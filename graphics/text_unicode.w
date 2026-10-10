# Platform-independent conversion for native UTF-16 input and window titles.
import lib.lib
import lib.mem


# Return a Unicode scalar, or -1 while waiting for the low surrogate.
# An isolated low surrogate becomes U+FFFD; a superseded unmatched high
# surrogate is discarded. Focus changes clear pending.
int gfx_utf16_input(int32* pending, int unit):
	unit = unit & 65535
	if ((unit >= 55296) && (unit <= 56319)):
		pending[0] = unit
		return 0 - 1
	int high = pending[0]
	pending[0] = 0
	if ((unit >= 56320) && (unit <= 57343)):
		if (high == 0): return 65533
		return 65536 + (high - 55296) * 1024 + unit - 56320
	return unit


# Owned, little-endian UTF-16, terminated by two zero bytes. Invalid UTF-8
# consumes one byte as U+FFFD; a caller must free the result.
char* gfx_utf16_from_utf8(char* text):
	int length = strlen(text)
	char* result = cast(char*, malloc((length + 1) * 2))
	int at = 0
	int out = 0
	while (at < length):
		int cp = 0
		int n = utf8_scan(text + at, length - at, &cp)
		if (n == 0):
			cp = 65533
			n = 1
		if (cp > 65535):
			cp = cp - 65536
			save_int16(result + out, 55296 + (cp >> 10))
			out = out + 2
			cp = 56320 + (cp & 1023)
		save_int16(result + out, cp)
		out = out + 2
		at = at + n
	save_int16(result + out, 0)
	return result
