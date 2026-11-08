# Grapheme byte boundaries shared by editable controls and caret hit testing.
# The Unicode break tables live in lib.grapheme; offsets remain UTF-8 bytes.
import lib.grapheme
import lib.unicode_text


int ui_grapheme_next_n(char* text, int length, int at):
	int[2] descriptor
	descriptor[0] = cast(int, text)
	descriptor[1] = length
	string s = cast(string, cast(int, &descriptor[0]))
	if (at < 0): at = 0
	if (at >= s.length): return s.length
	int next = grapheme_next(s, at)
	if (next > s.length): return s.length
	return next


int ui_grapheme_next(char* text, int at):
	return ui_grapheme_next_n(text, strlen(text), at)


int ui_grapheme_prev(char* text, int at):
	int length = strlen(text)
	int previous = 0
	int i = 0
	while (i < at):
		previous = i
		int next = ui_grapheme_next_n(text, length, i)
		if (next <= i): return i
		i = next
	return previous


int ui_grapheme_floor(char* text, int at):
	int length = strlen(text)
	int i = 0
	while (i < at):
		int next = ui_grapheme_next_n(text, length, i)
		if ((next <= i) || (next > at)): return i
		i = next
	return i


# Insertions move past a cluster that absorbed their trailing bytes.
int ui_grapheme_ceil(char* text, int at):
	int length = strlen(text)
	int i = 0
	while (i < at):
		int next = ui_grapheme_next_n(text, length, i)
		if (next <= i): return i
		i = next
	return i


# The word segment (UAX #29, lib/unicode_text.w) of text[0..length) that
# holds byte offset at, as start[0]..end[0]: what a double-click selects.
void ui_word_bounds(char* text, int length, int at, int* start, int* end):
	if (at < 0): at = 0
	if (at > length): at = length
	ut_word_at(text, length, at, start, end)
