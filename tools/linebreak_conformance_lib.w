# Checks lib/linebreak.w against files in the format of the Unicode
# LineBreakTest.txt: hex code points separated by U+00D7 (no break) or
# U+00F7 (a break opportunity), from the start of the text to its end,
# then an optional "#" comment. Mandatory and allowed breaks both read as
# U+00F7. tests/linebreak_test.w runs the committed sample;
# tools/linebreak_conformance.w runs any file, such as the full UCD file.
import lib.lib
import lib.stream
import lib.linebreak
import structures.string


int lb_conf_hex_digit(int c):
	if ((c >= '0') && (c <= '9')): return c - '0'
	if ((c >= 'A') && (c <= 'F')): return c - 'A' + 10
	if ((c >= 'a') && (c <= 'f')): return c - 'a' + 10
	return -1

# Returns 1 when the line passes or is not a test line, 0 on a mismatch
# (or a line it cannot parse).
int lb_conf_line(char* text, int flags, int verbose):
	if ((text[0] == '#') || (text[0] == 0)): return 1
	int length = strlen(text)
	int32* cps = cast(int32*, malloc(length * 4 + 4))
	char* want = cast(char*, malloc(length + 2))
	int count = 0
	int marks = 0
	int at = 0
	int ok = 1
	while ((text[at] != 0) && (text[at] != '#')):
		int c = text[at] & 255
		if ((c == ' ') || (c == 9)):
			at = at + 1
			continue
		# U+00D7 and U+00F7 in UTF-8: C3 97 and C3 B7.
		if ((c == 0xc3) && (((text[at + 1] & 255) == 0x97) || ((text[at + 1] & 255) == 0xb7))):
			if (marks != count): ok = 0
			want[marks] = (text[at + 1] & 255) == 0xb7
			marks = marks + 1
			at = at + 2
			continue
		if (lb_conf_hex_digit(c) < 0):
			ok = 0
			break
		int value = 0
		while (lb_conf_hex_digit(text[at]) >= 0):
			value = value * 16 + lb_conf_hex_digit(text[at])
			at = at + 1
		if (marks != count + 1): ok = 0
		cps[count] = value
		count = count + 1
	if (marks != count + 1): ok = 0
	char* got = cast(char*, malloc(count + 2))
	if (ok):
		lb_breaks(cps, count, flags, got)
		for i in range(count + 1):
			if ((got[i] != lb_break_none) != want[i]): ok = 0
	if ((ok == 0) && verbose):
		print(f"linebreak mismatch: {text}\n  got:")
		for i in range(count + 1):
			if (got[i] != lb_break_none): print(c" /")
			else: print(c" x")
			if (i < count): print(f" {cps[i]}")
		print(c"\n")
	free(cps)
	free(want)
	free(got)
	return ok

# Number of failing lines in path, or -1 when it cannot be read. total
# receives the number of test lines.
int lb_conf_file(char* path, int flags, int verbose, int* total):
	wstream* src = stream_open_read(path)
	if (src == 0): return -1
	string_builder* line = string_new()
	int failures = 0
	total[0] = 0
	while (stream_read_line(src, line)):
		if ((line.length == 0) || (line.data[0] == '#')): continue
		total[0] = total[0] + 1
		if (lb_conf_line(line.data, flags, verbose && (failures < 20)) == 0): failures = failures + 1
	string_free(line)
	stream_close(src)
	return failures
