# Label text metrics shared by layout, the display list and SVG export.
# Widths are the native preview's own pixel advances: Liberation Sans
# Regular/Bold at 16px (graphics/ui/font.w strike 0 and the bold face at
# the same size), one letter per printable ASCII code point, encoded as
# 'a' + advance. Italic faces share the upright advances. Liberation Sans
# is metric-compatible with Arial/Helvetica, which SVG export names first,
# so both backends wrap and center text from the same numbers. Pair
# kerning is ignored, which can only overestimate a run's width.
import lib.lib

const int MM_TEXT_BOLD = 1
const int MM_TEXT_ITALIC = 2
const int MM_TEXT_SIZE = 16
const int MM_TEXT_ASCENT = 14
# Line box of one label line, and the baseline-to-baseline pitch.
const int MM_TEXT_LINE = 16
const int MM_TEXT_PITCH = 20

char* mm_text_advances(int style):
	if (style & MM_TEXT_BOLD): return c"efijjomeffgjefeejjjjjjjjjjffjjjkqmmmmlkmmejmknmmlmmlkmlpllkfefjjfjkjkjfkkeejeokkkkgjfkjmjjigegj"
	return c"eegjjoldffgjefeejjjjjjjjjjeejjjjqllmmlkmmeiljnmmlmmlkmlpllkeeeijfjjijjejjeeienjjjjfiejimiiifefj"

# East Asian wide and emoji blocks take a full em; combining marks none.
int mm_text_codepoint_width(int cp, int style):
	if (cp >= 32 && cp < 127): return mm_text_advances(style)[cp - 32] - 'a'
	if (cp < 32 || cp == 127): return 0
	if (cp >= 0x300 && cp < 0x370): return 0
	if (cp >= 0x200b && cp <= 0x200f): return 0
	if ((cp >= 0x1100 && cp < 0x1160) || (cp >= 0x2e80 && cp < 0xa4d0) || (cp >= 0xac00 && cp < 0xd7a4) || (cp >= 0xf900 && cp < 0xfb00) || (cp >= 0xfe30 && cp < 0xfe50) || (cp >= 0xff00 && cp < 0xff61) || (cp >= 0xffe0 && cp < 0xffe7) || (cp >= 0x1f300 && cp < 0x1fb00) || cp >= 0x20000): return MM_TEXT_SIZE
	if (style & MM_TEXT_BOLD): return 10
	return 9

# Decode one UTF-8 sequence at text[i]; invalid bytes count as U+FFFD.
int mm_text_next(char* text, int i, int end, int* cp):
	int c = text[i] & 255
	int length = 1
	int value = c
	if (c >= 0xf0 && c < 0xf8):
		length = 4
		value = c & 7
	else if (c >= 0xe0):
		length = 3
		value = c & 15
	else if (c >= 0xc0):
		length = 2
		value = c & 31
	else if (c >= 0x80):
		cp[0] = 0xfffd
		return i + 1
	if (length > 1 && c >= 0xf8):
		cp[0] = 0xfffd
		return i + 1
	if (i + length > end):
		cp[0] = 0xfffd
		return i + 1
	for k in range(1, length):
		int next = text[i + k] & 255
		if ((next & 0xc0) != 0x80):
			cp[0] = 0xfffd
			return i + 1
		value = (value << 6) | (next & 63)
	cp[0] = value
	return i + length

int mm_text_width_range(char* text, int start, int end, int style):
	int width = 0
	int i = start
	while (i < end):
		int cp = 0
		i = mm_text_next(text, i, end, &cp)
		width = width + mm_text_codepoint_width(cp, style)
	return width

# Pixel width of one unbroken line of text in the given style flags.
int mm_text_width(char* text, int style):
	if (text == 0): return 0
	return mm_text_width_range(text, 0, strlen(text), style)
