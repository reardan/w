# Checks lib/bidi.w against files in the format of the Unicode
# BidiCharacterTest.txt: "cps; direction (0 LTR, 1 RTL, 2 auto);
# paragraph level; levels ('x' for X9-removed); visual order". Each line
# is one paragraph laid out as one line. tests/bidi_test.w runs the
# committed sample; tools/bidi_conformance.w runs any file, such as the
# full 91,000-line UCD file.
import lib.lib
import lib.stream
import lib.bidi
import structures.string


int bidi_conf_hex(char* text, int* at):
	int value = 0
	while (1):
		int c = text[at[0]]
		int digit = -1
		if ((c >= '0') && (c <= '9')): digit = c - '0'
		if ((c >= 'A') && (c <= 'F')): digit = c - 'A' + 10
		if ((c >= 'a') && (c <= 'f')): digit = c - 'a' + 10
		if (digit < 0): return value
		value = value * 16 + digit
		at[0] = at[0] + 1

void bidi_conf_skip_spaces(char* text, int* at):
	while (text[at[0]] == ' '): at[0] = at[0] + 1

# Returns 1 when the line passes or is not a test line, 0 on a mismatch.
int bidi_conf_line(char* text, int verbose):
	if ((text[0] == '#') || (text[0] == 0)): return 1
	int32* cps = cast(int32*, malloc(4 * 1024))
	int count = 0
	int at = 0
	while (text[at] != ';'):
		bidi_conf_skip_spaces(text, &at)
		if (text[at] == ';'): break
		cps[count] = bidi_conf_hex(text, &at)
		count = count + 1
	at = at + 1
	int direction = text[at] - '0'
	at = at + 2
	int want_para = text[at] - '0'
	at = at + 2
	char* classes = cast(char*, malloc(count + 1))
	char* levels = cast(char*, malloc(count + 1))
	int base = direction
	if (direction == 2): base = -1
	int para = bidi_resolve(cps, count, base, classes, levels)
	bidi_line_levels(classes, levels, count, para)
	int ok = para == want_para
	for i in range(count):
		bidi_conf_skip_spaces(text, &at)
		if (text[at] == 'x'):
			at = at + 1
			continue
		int want = 0
		while ((text[at] >= '0') && (text[at] <= '9')):
			want = want * 10 + text[at] - '0'
			at = at + 1
		if (levels[i] != want): ok = 0
	while (text[at] != ';'): at = at + 1
	at = at + 1
	int32* order = cast(int32*, malloc(count * 4 + 4))
	bidi_reorder(levels, count, order)
	for v in range(count):
		int logical = order[v]
		if (bidi_removed(classes[logical])): continue
		bidi_conf_skip_spaces(text, &at)
		int want = 0
		while ((text[at] >= '0') && (text[at] <= '9')):
			want = want * 10 + text[at] - '0'
			at = at + 1
		if (logical != want): ok = 0
	if ((ok == 0) && verbose):
		print(f"bidi mismatch: {text}\n  got level {para}:")
		for i in range(count): print(f" {levels[i]}")
		print(c"\n  order:")
		for v in range(count):
			if (bidi_removed(classes[order[v]]) == 0): print(f" {order[v]}")
		print(c"\n")
	free(cps)
	free(classes)
	free(levels)
	free(order)
	return ok

# Number of failing lines in path, or -1 when it cannot be read.
int bidi_conf_file(char* path, int verbose, int* total):
	wstream* src = stream_open_read(path)
	if (src == 0): return -1
	string_builder* line = string_new()
	int failures = 0
	total[0] = 0
	while (stream_read_line(src, line)):
		if ((line.length == 0) || (line.data[0] == '#')): continue
		total[0] = total[0] + 1
		if (bidi_conf_line(line.data, verbose && (failures < 20)) == 0): failures = failures + 1
	string_free(line)
	stream_close(src)
	return failures
