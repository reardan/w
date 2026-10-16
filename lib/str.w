# C-string convenience functions (docs/projects/golf_ergonomics.md):
# non-mutating counterparts to the in-place helpers in lib/lib.w and
# structures/list.w. Results are malloc'd and owned by the caller.
import lib.lib


# Bytes [start, end) as a new C string, for callers that already know
# 0 <= start <= end <= strlen(s): no strlen, so a caller cutting many
# pieces out of one string (split) stays linear (issue #528).
char* str_copy_range(char* s, int start, int end):
	char* result = cast(char*, malloc(end - start + 1))
	int i = 0
	while (start + i < end):
		result[i] = s[start + i]
		i = i + 1
	result[i] = 0
	return result


# Bytes [start, end) as a new C string. Out-of-range bounds clamp, so
# substring(s, 0, 999) is a safe "rest of the string".
char* substring(char* s, int start, int end):
	int length = strlen(s)
	if (start < 0): start = 0
	if (end > length): end = length
	if (end < start): end = start
	return str_copy_range(s, start, end)


# First index where needle appears in s, or -1. An empty needle
# matches at 0.
int index_of(char* s, char* needle):
	int i = 0
	while (s[i] != 0):
		int j = 0
		while ((needle[j] != 0) && (s[i + j] == needle[j])): j = j + 1
		if (needle[j] == 0):
			return i
		i = i + 1
	if (needle[0] == 0): return 0
	return 0 - 1


# grep -qF: 1 when needle occurs in s (a null s contains nothing).
int contains(char* s, char* needle):
	return (s != 0) && (index_of(s, needle) >= 0)


# grep -cx: the number of lines of text exactly equal to line (0 for a
# null text). A trailing newline does not start an extra empty line.
int count_line(char* text, char* line):
	if (text == 0): return 0
	int count = 0
	int i = 0
	while (text[i] != 0):
		int j = 0
		while ((line[j] != 0) && (text[i + j] == line[j])): j = j + 1
		if ((line[j] == 0) && ((text[i + j] == 10) || (text[i + j] == 0))): count = count + 1
		while ((text[i] != 0) && (text[i] != 10)): i = i + 1
		if (text[i] == 10): i = i + 1
	return count


# grep -qx: some line of text is exactly line.
int has_line(char* text, char* line):
	return count_line(text, line) > 0


# Split on a single-character delimiter without touching the input;
# every piece is a fresh C string. Adjacent delimiters produce empty
# pieces ("a,,b" -> "a", "", "b"), like Python's split. With the
# delimiter omitted (0), split(s) splits on runs of ASCII whitespace
# and drops empty pieces, like Python's s.split().
list[char*] split(char* s, char delimiter = 0):
	list[char*] pieces = new list[char*]
	int start = 0
	int i = 0
	while (1):
		int is_break = (s[i] == delimiter) || (s[i] == 0)
		if (delimiter == 0):
			is_break = (s[i] == 0) || (s[i] == ' ') || ((s[i] >= 9) && (s[i] <= 13))
		if (is_break):
			if ((delimiter != 0) || (i > start)): pieces.push(str_copy_range(s, start, i))
			start = i + 1
		if (s[i] == 0):
			return pieces
		i = i + 1
	return pieces


# All occurrences of needle replaced with replacement, in a new string.
# An empty needle returns a plain copy.
char* replace(char* s, char* needle, char* replacement):
	if (needle[0] == 0): return strclone(s)
	int needle_length = strlen(needle)
	int replacement_length = strlen(replacement)
	# Count matches to size the result exactly
	int matches = 0
	int i = 0
	while (s[i] != 0):
		int j = 0
		while ((needle[j] != 0) && (s[i + j] == needle[j])): j = j + 1
		if (needle[j] == 0):
			matches = matches + 1
			i = i + needle_length
		else: i = i + 1
	char* result = cast(char*, malloc(strlen(s) + matches * (replacement_length - needle_length) + 1))
	int out = 0
	i = 0
	while (s[i] != 0):
		int k = 0
		while ((needle[k] != 0) && (s[i + k] == needle[k])): k = k + 1
		if (needle[k] == 0):
			for r in range(replacement_length):
				result[out] = replacement[r]
				out = out + 1
			i = i + needle_length
		else:
			result[out] = s[i]
			out = out + 1
			i = i + 1
	result[out] = 0
	return result


# ASCII character classes and case mapping (issue #360), the libc ctype
# names with byte-sized char in and out. ASCII semantics only: bytes of
# a multi-byte UTF-8 sequence are never ASCII, so they test false and
# map to themselves. Predicates return 1 or 0.
int isdigit(char c):
	return (c >= '0') & (c <= '9')


int isupper(char c):
	return (c >= 'A') & (c <= 'Z')


int islower(char c):
	return (c >= 'a') & (c <= 'z')


int isalpha(char c):
	return isupper(c) | islower(c)


int isalnum(char c):
	return isalpha(c) | isdigit(c)


# Space, tab, newline, vertical tab, form feed, carriage return.
int isspace(char c):
	if (c == ' '): return 1
	return (c >= 9) & (c <= 13)


char tolower(char c):
	if (isupper(c)): return c + ('a' - 'A')
	return c


char toupper(char c):
	if (islower(c)): return c - ('a' - 'A')
	return c


# The pieces joined with the delimiter between them, as a new C string.
char* join(list[char*] pieces, char* delimiter):
	int delimiter_length = strlen(delimiter)
	int total = 1
	int i = 0
	while (i < pieces.length):
		total = total + strlen(pieces[i])
		if (i > 0): total = total + delimiter_length
		i = i + 1
	char* result = cast(char*, malloc(total))
	int out = 0
	i = 0
	while (i < pieces.length):
		if (i > 0):
			int d = 0
			while (delimiter[d] != 0):
				result[out] = delimiter[d]
				out = out + 1
				d = d + 1
		char* piece = pieces[i]
		int j = 0
		while (piece[j] != 0):
			result[out] = piece[j]
			out = out + 1
			j = j + 1
		i = i + 1
	result[out] = 0
	return result


# ---- Python str method counterparts (docs/projects/stdlib_python_parity.md
# P1.2). Every result is a fresh malloc'd C string (or a list of them)
# owned by the caller; the input is never modified. Case mapping and the
# default whitespace set are ASCII only, but multi-byte UTF-8 sequences
# are never split: widths, columns and character sets count code points.

# Length of the UTF-8 sequence that starts with lead byte c: 1 for ASCII
# and for any byte that cannot start a sequence (so malformed input
# still advances one byte at a time).
int str_utf8_width(char c):
	int b = c & 255
	if (b >= 0xf0 && b < 0xf8): return 4
	if (b >= 0xe0 && b < 0xf0): return 3
	if (b >= 0xc0 && b < 0xe0): return 2
	return 1


# 1 when byte c is a UTF-8 continuation byte (10xxxxxx).
int str_utf8_continuation(char c):
	return (c & 0xc0) == 0x80


# Code points in s (bytes that are not continuation bytes).
int str_codepoints(char* s):
	int n = 0
	int i = 0
	while (s[i] != 0):
		if (!str_utf8_continuation(s[i])): n = n + 1
		i = i + 1
	return n


# Width of the character starting at s[i], never running past the
# terminator of a truncated sequence.
int str_char_width(char* s, int i):
	int w = str_utf8_width(s[i])
	int k = 1
	while (k < w):
		if (!str_utf8_continuation(s[i + k])): return k
		k = k + 1
	return w


# 1 when the character s[i .. i+width) is one of the characters of chars
# (compared whole, so a multi-byte character only matches itself), or,
# with chars null, when it is ASCII whitespace.
int str_strip_match(char* s, int i, int width, char* chars):
	if (chars == 0):
		return (width == 1) && isspace(s[i])
	int j = 0
	while (chars[j] != 0):
		int cw = str_char_width(chars, j)
		if (cw == width):
			int k = 0
			while ((k < width) && (chars[j + k] == s[i + k])): k = k + 1
			if (k == width): return 1
		j = j + cw
	return 0


# Index just past the leading characters of s that strip would remove.
int str_strip_start(char* s, char* chars):
	int i = 0
	while (s[i] != 0):
		int w = str_char_width(s, i)
		if (!str_strip_match(s, i, w, chars)): return i
		i = i + w
	return i


# Index just past the last character of s[start ..] that strip keeps.
int str_strip_end(char* s, int start, char* chars):
	int end = strlen(s)
	while (end > start):
		int i = end - 1
		while ((i > start) && str_utf8_continuation(s[i])): i = i - 1
		if (!str_strip_match(s, i, end - i, chars)): return end
		end = i
	return end


# Python's s.strip() / s.strip(chars): a copy without leading and
# trailing ASCII whitespace, or without leading and trailing characters
# that occur in chars (a set of characters, not a prefix/suffix; a
# multi-byte UTF-8 character in chars matches only that whole character).
char* strip(char* s, char* chars = 0):
	int start = str_strip_start(s, chars)
	return str_copy_range(s, start, str_strip_end(s, start, chars))


# Python's s.lstrip([chars]): strip at the start only.
char* lstrip(char* s, char* chars = 0):
	return str_copy_range(s, str_strip_start(s, chars), strlen(s))


# Python's s.rstrip([chars]): strip at the end only.
char* rstrip(char* s, char* chars = 0):
	return str_copy_range(s, 0, str_strip_end(s, 0, chars))


# Last index where needle appears in s, or -1. An empty needle matches
# at strlen(s), like Python's s.rfind("").
int rindex_of(char* s, char* needle):
	int length = strlen(s)
	int needle_length = strlen(needle)
	int i = length - needle_length
	while (i >= 0):
		int j = 0
		while ((j < needle_length) && (s[i + j] == needle[j])): j = j + 1
		if (j == needle_length): return i
		i = i - 1
	return 0 - 1


# Python's s.startswith(prefix, start): 1 when prefix occurs at byte
# offset start. A negative start counts from the end (clamped to 0); a
# start past the end never matches.
int starts_with_at(char* s, char* prefix, int start):
	int length = strlen(s)
	if (start < 0): start = start + length
	if (start < 0): start = 0
	if (start > length): return 0
	int j = 0
	while (prefix[j] != 0):
		if (s[start + j] != prefix[j]): return 0
		j = j + 1
	return 1


# Python's s.count(needle): non-overlapping occurrences, scanning left
# to right. An empty needle counts the gaps between code points
# (code points + 1), as Python does.
int count(char* s, char* needle):
	if (needle[0] == 0): return str_codepoints(s) + 1
	int needle_length = strlen(needle)
	int n = 0
	int i = 0
	while (s[i] != 0):
		int j = 0
		while ((needle[j] != 0) && (s[i + j] == needle[j])): j = j + 1
		if (needle[j] == 0):
			n = n + 1
			i = i + needle_length
		else: i = i + 1
	return n


# The three pieces of a partition as fresh strings.
list[char*] str_three(char* s, int a, int b):
	list[char*] parts = new list[char*]
	parts.push(str_copy_range(s, 0, a))
	parts.push(str_copy_range(s, a, b))
	parts.push(str_copy_range(s, b, strlen(s)))
	return parts


# Python's s.partition(sep) as a 3-element list [head, sep, tail] split
# at the first sep; when sep does not occur the result is [s, "", ""].
# An empty sep matches at 0 (as in index_of), giving ["", "", s].
list[char*] partition(char* s, char* sep):
	int at = index_of(s, sep)
	if (at < 0):
		int length = strlen(s)
		return str_three(s, length, length)
	return str_three(s, at, at + strlen(sep))


# Python's s.rpartition(sep): split at the last sep; when sep does not
# occur the result is ["", "", s]. An empty sep matches at the end
# (as in rindex_of), giving [s, "", ""].
list[char*] rpartition(char* s, char* sep):
	int at = rindex_of(s, sep)
	if (at < 0): return str_three(s, 0, 0)
	return str_three(s, at, at + strlen(sep))


# s padded with left and right copies of the byte fill to width code
# points. A string already that wide or wider comes back as a copy.
char* str_pad(char* s, int left, int right, char fill):
	int length = strlen(s)
	char* result = cast(char*, malloc(left + length + right + 1))
	int out = 0
	while (out < left):
		result[out] = fill
		out = out + 1
	int i = 0
	while (i < length):
		result[out] = s[i]
		out = out + 1
		i = i + 1
	int r = 0
	while (r < right):
		result[out] = fill
		out = out + 1
		r = r + 1
	result[out] = 0
	return result


# Code points of padding s needs to reach width (never negative).
int str_pad_needed(char* s, int width):
	int needed = width - str_codepoints(s)
	if (needed < 0): return 0
	return needed


# Python's s.ljust(width[, fill]): left-justified in width code points.
# fill is a single (ASCII) byte.
char* ljust(char* s, int width, char fill = ' '):
	return str_pad(s, 0, str_pad_needed(s, width), fill)


# Python's s.rjust(width[, fill]): right-justified in width code points.
char* rjust(char* s, int width, char fill = ' '):
	return str_pad(s, str_pad_needed(s, width), 0, fill)


# Python's s.center(width[, fill]), with CPython's rounding: the odd
# extra pad goes left only when both the pad and width are odd.
char* center(char* s, int width, char fill = ' '):
	int needed = str_pad_needed(s, width)
	int left = needed / 2 + (needed & width & 1)
	return str_pad(s, left, needed - left, fill)


# Python's s.zfill(width): left-padded with '0' to width code points,
# keeping a leading '+' or '-' sign in front of the zeros.
char* zfill(char* s, int width):
	int needed = str_pad_needed(s, width)
	char* result = str_pad(s, needed, 0, '0')
	if ((needed > 0) && ((s[0] == '+') || (s[0] == '-'))):
		result[0] = s[0]
		result[needed] = '0'
	return result


# Python's s.capitalize() for ASCII: the first byte upper-cased and the
# rest lower-cased. Non-ASCII bytes are copied unchanged.
char* capitalize(char* s):
	char* result = strclone(s)
	int i = 0
	while (result[i] != 0):
		if (i == 0): result[i] = toupper(result[i])
		else: result[i] = tolower(result[i])
		i = i + 1
	return result


# Python's s.title() for ASCII: every letter that follows a non-letter is
# upper-cased, every other letter lower-cased. Non-ASCII bytes are copied
# unchanged and count as letters (they are nearly always part of one), so
# "café bar" -> "Café Bar" and "émile" keeps its lower-case "mile".
char* title(char* s):
	char* result = strclone(s)
	int previous_cased = 0
	int i = 0
	while (result[i] != 0):
		char c = result[i]
		if (previous_cased): result[i] = tolower(c)
		else: result[i] = toupper(c)
		previous_cased = isalpha(c) || ((c & 0x80) != 0)
		i = i + 1
	return result


# Bytes in the line break that starts at s[i], or 0 when none does.
# Python's str.splitlines boundaries: \n, \r, \r\n, \v, \f, \x1c-\x1e,
# and the UTF-8 encodings of U+0085, U+2028 and U+2029.
int str_line_break(char* s, int i):
	int b = s[i] & 255
	if ((b == 13) && (s[i + 1] == 10)): return 2
	if ((b >= 10) && (b <= 13)): return 1
	if ((b >= 0x1c) && (b <= 0x1e)): return 1
	if ((b == 0xc2) && ((s[i + 1] & 255) == 0x85)): return 2
	if ((b == 0xe2) && ((s[i + 1] & 255) == 0x80)):
		int t = s[i + 2] & 255
		if ((t == 0xa8) || (t == 0xa9)): return 3
	return 0


# Python's s.splitlines([keepends]): the lines of s as fresh strings,
# split at any line boundary (str_line_break). A final line break does
# not start an extra empty line, so "" and "\n"-free text behave as in
# Python ("" -> [], "a\n" -> ["a"], "\n" -> [""]). With keepends set
# each line keeps its break.
list[char*] splitlines(char* s, int keepends = 0):
	list[char*] lines = new list[char*]
	int start = 0
	int i = 0
	while (s[i] != 0):
		int brk = str_line_break(s, i)
		if (brk > 0):
			int end = i
			if (keepends): end = i + brk
			lines.push(str_copy_range(s, start, end))
			i = i + brk
			start = i
		else: i = i + 1
	if (i > start): lines.push(str_copy_range(s, start, i))
	return lines


# Python's s.isascii(): 1 when every byte is below 0x80 (an empty string
# is ASCII).
int is_ascii(char* s):
	int i = 0
	while (s[i] != 0):
		if ((s[i] & 0x80) != 0): return 0
		i = i + 1
	return 1


# Python's s.expandtabs(tabsize=8): each tab replaced by spaces up to the
# next multiple of tabsize columns. Columns count code points and restart
# after \n or \r; a tabsize of 0 or less deletes the tabs.
char* expandtabs(char* s, int tabsize = 8):
	# First pass sizes the result, second pass fills it
	int total = 0
	int phase = 0
	char* result = 0
	while (phase < 2):
		int column = 0
		int out = 0
		int i = 0
		while (s[i] != 0):
			char c = s[i]
			if (c == 9):
				if (tabsize > 0):
					int spaces = tabsize - column % tabsize
					int k = 0
					while (k < spaces):
						if (phase == 1): result[out] = ' '
						out = out + 1
						k = k + 1
					column = column + spaces
			else:
				if (phase == 1): result[out] = c
				out = out + 1
				if ((c == 10) || (c == 13)): column = 0
				else:
					if (!str_utf8_continuation(c)): column = column + 1
			i = i + 1
		if (phase == 0):
			total = out
			result = cast(char*, malloc(total + 1))
		else: result[out] = 0
		phase = phase + 1
	return result
