# wbuild: x64 deps=tools/unicode/WordBreakTest.txt
# lib/unicode_text.w's UAX #29 word boundaries against the Unicode 18.0.0
# conformance file (tools/unicode/WordBreakTest.txt), plus the segments a
# double-click selects.
import lib.testing
import lib.stream
import lib.utf8
import lib.unicode_text
import structures.string


# One WordBreakTest line ("÷ 0041 × 0042 ÷ ...") as UTF-8 text plus the
# byte offsets of its expected boundaries after 0. Returns 0 for a
# comment line.
int wb_parse(char* line, string_builder* text, list[int] breaks):
	string_clear(text)
	breaks.clear()
	int i = 0
	int seen = 0
	while ((line[i] != 0) && (line[i] != '#')):
		int c = line[i] & 255
		if ((c == 0xc3) && ((line[i + 1] & 255) == 0xb7)):
			# ÷: a boundary at the current end, the leading one excepted.
			if (seen): breaks.push(text.length)
			i = i + 2
		else if ((c == 0xc3) && ((line[i + 1] & 255) == 0x97)): i = i + 2
		else if (c == ' ' || c == 9): i = i + 1
		else:
			int cp = 0
			while (((line[i] >= '0') && (line[i] <= '9')) || ((line[i] >= 'A') && (line[i] <= 'F'))):
				int d = line[i]
				if (d <= '9'): d = d - '0'
				else: d = d - 'A' + 10
				cp = cp * 16 + d
				i = i + 1
			char[4] bytes
			int n = utf8_encode(&bytes[0], cp)
			for k in range(n): string_append_char(text, bytes[k])
			seen = 1
	return seen


void test_word_break_conformance():
	wstream* src = stream_open_read(c"tools/unicode/WordBreakTest.txt")
	asserts(c"WordBreakTest.txt opens", src != 0)
	string_builder* line = string_new()
	string_builder* text = string_new()
	list[int] breaks = new list[int]
	int total = 0
	int failures = 0
	while (stream_read_line(src, line)):
		if (wb_parse(line.data, text, breaks) == 0): continue
		total = total + 1
		int at = 0
		int ok = 1
		for expected in breaks:
			at = ut_word_next(text.data, text.length, at)
			if (at != expected): ok = 0
		if (ok == 0):
			failures = failures + 1
			if (failures <= 5): println(strjoin(c"word break mismatch: ", line.data))
	stream_close(src)
	assert_equal(0, failures)
	asserts(c"conformance file has its 1900-odd cases", total > 1900)


void test_word_properties():
	assert_equal(ut_wb_aletter, ut_word_break('a'))
	assert_equal(ut_wb_numeric, ut_word_break('7'))
	assert_equal(ut_wb_midnumlet, ut_word_break('.'))
	assert_equal(ut_wb_wsegspace, ut_word_break(' '))
	assert_equal(ut_wb_lf, ut_word_break(10))
	assert_equal(ut_wb_katakana, ut_word_break(0x30a2))
	assert_equal(ut_wb_hebrew_letter, ut_word_break(0x05d0))
	assert_equal(ut_wb_other, ut_word_break('!'))


void check_word(char* text, int at, int start, int end):
	int s = 0
	int e = 0
	ut_word_at(text, strlen(text), at, &s, &e)
	assert_equal(start, s)
	assert_equal(end, e)


void test_word_at():
	# "can't stop", "3.14", spaces and punctuation as their own segments
	check_word(c"can't stop  now!", 2, 0, 5)
	check_word(c"can't stop  now!", 5, 5, 6)
	check_word(c"can't stop  now!", 10, 10, 12)
	check_word(c"can't stop  now!", 15, 15, 16)
	check_word(c"can't stop  now!", 16, 15, 16)
	check_word(c"pi=3.14;", 4, 3, 7)
	check_word(c"snake_case x", 3, 0, 10)
	# Multi-byte letters stay whole: "naïve café" (ï and é are 2 bytes).
	check_word(c"na\xc3\xafve caf\xc3\xa9", 3, 0, 6)
	check_word(c"na\xc3\xafve caf\xc3\xa9", 9, 7, 12)
	check_word(c"", 0, 0, 0)


# ut_utf8_scan (kept local to stay freestanding) agrees with lib.lib's
# utf8_scan on every lead byte with assorted continuation patterns,
# truncations included.
void test_utf8_scan_matches_lib():
	char* buf = cast(char*, malloc(8))
	int[8] tails
	tails[0] = 0x80
	tails[1] = 0xbf
	tails[2] = 0x9f
	tails[3] = 0xa0
	tails[4] = 0x8f
	tails[5] = 0x90
	tails[6] = 0x41
	tails[7] = 0xc0
	for lead in range(256):
		for t in range(8):
			for avail in range(1, 5):
				buf[0] = lead
				buf[1] = tails[t]
				buf[2] = tails[(t + 3) % 8]
				buf[3] = 0x80
				int a = 0
				int b = 0
				int na = utf8_scan(buf, avail, &a)
				int nb = ut_utf8_scan(buf, avail, &b)
				assert_equal(na, nb)
				if (na != 0): assert_equal(a, b)
	free(buf)
