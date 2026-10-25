# Class member display text against Mermaid 12.2.0: `~T~` generics become
# `<T>` (nested and comma-separated), a method's trailing return type is shown
# as `name(params) : Type`, and a `$` (static) or `*` (abstract) classifier is
# removed from the text and reported separately. Visibility markers (+ - # ~)
# stay as written. The source member text is never changed.
import lib.lib
import lib.str
import structures.string

const int MM_MEMBER_STATIC = 1
const int MM_MEMBER_ABSTRACT = 2

int mm_member_word(int c):
	return isalnum(c) || c == '_' || c == '`' || c >= 128

# Replace generic tildes in text[start, end) and append to out.
void mm_member_generics(string_builder* out, char* text, int start, int end):
	int depth = 0
	for i in range(start, end):
		int c = text[i] & 255
		if (c != '~'):
			string_append_char(out, c)
			continue
		int before = 0
		if (i > start): before = text[i - 1] & 255
		int after = 0
		if (i + 1 < end): after = text[i + 1] & 255
		# `~` opens after a type name when a parameter follows; otherwise it closes one.
		if (i > start && mm_member_word(before) && mm_member_word(after) && depth < 32):
			string_append_char(out, '<')
			depth = depth + 1
		else if (depth > 0):
			string_append_char(out, '>')
			depth = depth - 1
		else: string_append_char(out, c)

int mm_member_space(int c):
	return c == 32 || c == 9

# Owned display text; *classifier receives MM_MEMBER_STATIC / MM_MEMBER_ABSTRACT or 0.
char* mm_class_member_display(char* text, int* classifier):
	classifier[0] = 0
	int length = strlen(text)
	int end = length
	while (end > 0 && mm_member_space(text[end - 1] & 255)): end = end - 1
	int open = index_of(text, c"(")
	string_builder* out = string_new()
	if (open < 0):
		if (end > 0 && (text[end - 1] == '$' || text[end - 1] == '*')):
			if (text[end - 1] == '$'): classifier[0] = MM_MEMBER_STATIC
			else: classifier[0] = MM_MEMBER_ABSTRACT
			end = end - 1
			while (end > 0 && mm_member_space(text[end - 1] & 255)): end = end - 1
		mm_member_generics(out, text, 0, end)
	else:
		int close = -1
		int depth = 0
		for i in range(open, end):
			if (text[i] == '('): depth = depth + 1
			else if (text[i] == ')'):
				depth = depth - 1
				if (depth == 0):
					close = i
					break
		if (close < 0):
			mm_member_generics(out, text, 0, end)
		else:
			mm_member_generics(out, text, 0, close + 1)
			int at = close + 1
			if (at < end && (text[at] == '$' || text[at] == '*')):
				if (text[at] == '$'): classifier[0] = MM_MEMBER_STATIC
				else: classifier[0] = MM_MEMBER_ABSTRACT
				at = at + 1
			int tail = end
			if (tail > at && (text[tail - 1] == '$' || text[tail - 1] == '*') && classifier[0] == 0):
				if (text[tail - 1] == '$'): classifier[0] = MM_MEMBER_STATIC
				else: classifier[0] = MM_MEMBER_ABSTRACT
				tail = tail - 1
			while (at < tail && mm_member_space(text[at] & 255)): at = at + 1
			while (tail > at && mm_member_space(text[tail - 1] & 255)): tail = tail - 1
			if (tail > at):
				string_append(out, c" : ")
				mm_member_generics(out, text, at, tail)
	char* result = out.data
	free(out)
	return result
