# C-string convenience functions (docs/projects/golf_ergonomics.md):
# non-mutating counterparts to the in-place helpers in lib/lib.w and
# structures/list.w. Results are malloc'd and owned by the caller.
import lib.lib


# Bytes [start, end) as a new C string. Out-of-range bounds clamp, so
# substring(s, 0, 999) is a safe "rest of the string".
char* substring(char* s, int start, int end):
	int length = strlen(s)
	if (start < 0):
		start = 0
	if (end > length):
		end = length
	if (end < start):
		end = start
	char* result = malloc(end - start + 1)
	int i = 0
	while (start + i < end):
		result[i] = s[start + i]
		i = i + 1
	result[i] = 0
	return result


# First index where needle appears in s, or -1. An empty needle
# matches at 0.
int index_of(char* s, char* needle):
	int i = 0
	while (s[i] != 0):
		int j = 0
		while ((needle[j] != 0) && (s[i + j] == needle[j])):
			j = j + 1
		if (needle[j] == 0):
			return i
		i = i + 1
	if (needle[0] == 0):
		return 0
	return 0 - 1


# Split on a single-character delimiter without touching the input;
# every piece is a fresh C string. Adjacent delimiters produce empty
# pieces ("a,,b" -> "a", "", "b"), like Python's split.
list[char*] split(char* s, char delimiter):
	list[char*] pieces = new list[char*]
	int start = 0
	int i = 0
	while (1):
		if ((s[i] == delimiter) || (s[i] == 0)):
			pieces.push(substring(s, start, i))
			start = i + 1
		if (s[i] == 0):
			return pieces
		i = i + 1
	return pieces


# All occurrences of needle replaced with replacement, in a new string.
# An empty needle returns a plain copy.
char* replace(char* s, char* needle, char* replacement):
	if (needle[0] == 0):
		return strclone(s)
	int needle_length = strlen(needle)
	int replacement_length = strlen(replacement)
	# Count matches to size the result exactly
	int matches = 0
	int i = 0
	while (s[i] != 0):
		int j = 0
		while ((needle[j] != 0) && (s[i + j] == needle[j])):
			j = j + 1
		if (needle[j] == 0):
			matches = matches + 1
			i = i + needle_length
		else:
			i = i + 1
	char* result = malloc(strlen(s) + matches * (replacement_length - needle_length) + 1)
	int out = 0
	i = 0
	while (s[i] != 0):
		int k = 0
		while ((needle[k] != 0) && (s[i + k] == needle[k])):
			k = k + 1
		if (needle[k] == 0):
			int r = 0
			while (r < replacement_length):
				result[out] = replacement[r]
				out = out + 1
				r = r + 1
			i = i + needle_length
		else:
			result[out] = s[i]
			out = out + 1
			i = i + 1
	result[out] = 0
	return result


# The pieces joined with the delimiter between them, as a new C string.
char* join(list[char*] pieces, char* delimiter):
	int delimiter_length = strlen(delimiter)
	int total = 1
	int i = 0
	while (i < pieces.length):
		total = total + strlen(pieces[i])
		if (i > 0):
			total = total + delimiter_length
		i = i + 1
	char* result = malloc(total)
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
