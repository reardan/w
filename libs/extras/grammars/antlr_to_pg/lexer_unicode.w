# Exact scalar ranges and ANTLR escapes. Unicode property data is pinned to
# the reference tool; case-insensitive ranges mirror LexerATNFactory's
# endpoint mapping (properties themselves are added without case expansion).
import lib.utf8
import structures.string
import libs.extras.grammars.antlr_to_pg.unicode_data


int at_unicode_hex(int ch):
	if ((ch >= '0') && (ch <= '9')): return ch - '0'
	if ((ch >= 'a') && (ch <= 'f')): return ch - 'a' + 10
	if ((ch >= 'A') && (ch <= 'F')): return ch - 'A' + 10
	return -1


int at_unicode_character(char* raw, int* position, int end, int charset):
	int i = *position
	if (i >= end): return -1
	int codepoint = 0
	if (raw[i] != 92):
		int width = utf8_scan(raw + i, end - i, &codepoint)
		if (width == 0): return -1
		*position = i + width
		return codepoint
	i++
	if (i >= end): return -1
	int ch = raw[i]
	i++
	if (ch == 'u'):
		int digits = 4
		int braced = 0
		if ((i < end) && (raw[i] == '{')):
			braced = 1
			digits = 0
			i++
			int cursor = i
			while ((cursor < end) && (raw[cursor] != '}')):
				digits++
				cursor++
			if ((cursor == end) || (digits == 0) || (digits > 6)): return -1
		if (i + digits > end): return -1
		for j in range(digits):
			int digit = at_unicode_hex(raw[i + j])
			if (digit < 0): return -1
			codepoint = codepoint * 16 + digit
		i = i + digits + braced
		if (codepoint > 1114111): return -1
	else if (ch == 'n'): codepoint = 10
	else if (ch == 'r'): codepoint = 13
	else if (ch == 't'): codepoint = 9
	else if (ch == 'b'): codepoint = 8
	else if (ch == 'f'): codepoint = 12
	else if ((ch == 92) || (ch == 39) || (ch == 34)): codepoint = ch
	else if (charset && ((ch == ']') || (ch == '-'))): codepoint = ch
	else: return -1
	*position = i
	return codepoint


char* at_unicode_literal(char* raw):
	int end = strlen(raw) - 1
	if ((end < 1) || (raw[0] != 39) || (raw[end] != 39)): return 0
	string_builder* out = string_new()
	int i = 1
	int valid = 1
	while (i < end):
		int cp = at_unicode_character(raw, &i, end, 0)
		if ((cp >= 55296) && (cp <= 56319)):
			int tail = at_unicode_character(raw, &i, end, 0)
			if ((tail < 56320) || (tail > 57343)): cp = -1
			else: cp = 65536 + (cp - 55296) * 1024 + tail - 56320
		if ((cp <= 0) || ((cp >= 55296) && (cp <= 57343))):
			valid = 0
			break
		char[4] encoded
		int width = utf8_encode(&encoded[0], cp)
		for j in range(width): string_append_char(out, encoded[j])
	char* result = 0
	if (valid): result = strclone(out.data)
	string_free(out)
	return result


void at_unicode_add(list[int] ranges, int low, int high, int case_insensitive):
	if (case_insensitive):
		at_unicode_data_init()
		int lf = g_at_unicode_lower.get(low, low)
		int uf = g_at_unicode_upper.get(low, low)
		int lt = g_at_unicode_lower.get(high, high)
		int ut = g_at_unicode_upper.get(high, high)
		int mixed = (lf == low) != (lt == high)
		if (((lf != uf) || (lt != ut)) && (mixed == 0) && (lt - lf == ut - uf)):
			ranges.push(lf)
			ranges.push(lt)
			ranges.push(uf)
			ranges.push(ut)
			return
	ranges.push(low)
	ranges.push(high)


list[int] at_unicode_normalize(list[int] ranges, int negate):
	# Insertion sorting is linear for the already-sorted property tables.
	int i = 2
	while (i < ranges.length):
		int low = ranges[i]
		int high = ranges[i + 1]
		int j = i
		while ((j > 0) && (ranges[j - 2] > low)):
			ranges[j] = ranges[j - 2]
			ranges[j + 1] = ranges[j - 1]
			j = j - 2
		ranges[j] = low
		ranges[j + 1] = high
		i = i + 2
	list[int] merged = new list[int]
	for r in range(0, ranges.length, 2):
		int low = ranges[r]
		int high = ranges[r + 1]
		if ((merged.length > 0) && (low <= merged[merged.length - 1] + 1)):
			int last = merged.length - 1
			if (high > merged[last]): merged[last] = high
		else:
			merged.push(low)
			merged.push(high)
	ranges.free()
	if (negate == 0): return merged
	list[int] complement = new list[int]
	int cursor = 0
	for r in range(0, merged.length, 2):
		if (cursor < merged[r]):
			complement.push(cursor)
			complement.push(merged[r] - 1)
		cursor = merged[r + 1] + 1
	if (cursor <= 1114111):
		complement.push(cursor)
		complement.push(1114111)
	merged.free()
	return complement


int at_unicode_property(list[int] ranges, char* name, int negate):
	at_unicode_data_init()
	# ANTLR UnicodeData.normalize: lowercase and replace '-' with '_'.
	string_builder* normalized = string_new()
	for i in range(strlen(name)):
		int ch = name[i]
		if (ch == '-'): ch = '_'
		if ((ch >= 'A') && (ch <= 'Z')): ch = ch + 32
		string_append_char(normalized, ch)
	char* data = g_at_unicode_properties.get(normalized.data, 0)
	string_free(normalized)
	if (data == 0): return 0
	list[int] values = new list[int]
	int index = 0
	while (data[index] != 0):
		int number = 0
		while ((data[index] >= '0') && (data[index] <= '9')):
			number = number * 10 + data[index] - '0'
			index++
		values.push(number)
		if (data[index] != 0): index++
	values = at_unicode_normalize(values, negate)
	for int value in values: ranges.push(value)
	values.free()
	return 1


list[int] at_unicode_charset(char* raw, int negate, int case_insensitive):
	if (raw == 0): return 0
	int end = strlen(raw) - 1
	if ((end < 2) || (raw[0] != '[') || (raw[end] != ']')): return 0
	list[int] ranges = new list[int]
	int i = 1
	int valid = 1
	while (i < end):
		if ((raw[i] == 92) && (i + 2 < end) && ((raw[i + 1] == 'p') || (raw[i + 1] == 'P')) && (raw[i + 2] == '{')):
			int inverse = raw[i + 1] == 'P'
			i = i + 3
			int start = i
			while ((i < end) && (raw[i] != '}')): i++
			if (i == end):
				valid = 0
				break
			char* property = cast(char*, malloc(i - start + 1))
			for j in range(i - start): property[j] = raw[start + j]
			property[i - start] = 0
			valid = at_unicode_property(ranges, property, inverse)
			free(property)
			i++
			if ((i + 1 < end) && (raw[i] == '-')): valid = 0
			if (valid == 0): break
			continue
		int low = at_unicode_character(raw, &i, end, 1)
		int high = low
		if ((i + 1 < end) && (raw[i] == '-')):
			i++
			high = at_unicode_character(raw, &i, end, 1)
		if ((low < 0) || (high < low)):
			valid = 0
			break
		at_unicode_add(ranges, low, high, case_insensitive)
	if (valid == 0):
		ranges.free()
		return 0
	return at_unicode_normalize(ranges, negate)


# Range endpoints are scalars, not NUL-terminated strings. U+0000 is valid
# in a mathematical set even though the matcher input domain excludes NUL.
int at_unicode_scalar_literal(char* raw):
	int end = strlen(raw) - 1
	if ((end < 1) || (raw[0] != 39) || (raw[end] != 39)): return -1
	int position = 1
	int cp = at_unicode_character(raw, &position, end, 0)
	if ((cp >= 55296) && (cp <= 56319)):
		int tail = at_unicode_character(raw, &position, end, 0)
		if ((tail < 56320) || (tail > 57343)): return -1
		cp = 65536 + (cp - 55296) * 1024 + tail - 56320
	if ((position != end) || ((cp >= 55296) && (cp <= 57343))): return -1
	return cp


char* at_unicode_range_literal(char* left, char* right):
	int low = at_unicode_scalar_literal(left)
	int high = at_unicode_scalar_literal(right)
	if ((low < 0) || (high < low)): return 0
	string_builder* out = string_new()
	string_append(out, c"[\\u{")
	char* hex = c"0123456789abcdef"
	int shift = 20
	while (shift >= 0):
		string_append_char(out, hex[(low >> shift) & 15])
		shift = shift - 4
	string_append(out, c"}-\\u{")
	shift = 20
	while (shift >= 0):
		string_append_char(out, hex[(high >> shift) & 15])
		shift = shift - 4
	string_append(out, c"}]")
	char* result = strclone(out.data)
	string_free(out)
	return result
