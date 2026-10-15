# Structural RegExp Pattern early errors for the ES2020 lexer profile.
# This pass recognizes disjunctions, groups/assertions, class/escape boundaries
# and quantifiers. It does not execute regexes or claim complete validation of
# escape values, class ranges, named captures/backreferences or Unicode properties.
# https://tc39.es/ecma262/multipage/text-processing.html#sec-patterns
import lib.container
import libs.extras.javascript.lexical


# Compare unbounded decimal quantifier bounds without overflowing a W word.
int js_regexp_bound_greater(char* text, int left, int left_end, int right, int right_end):
	while (left < left_end && text[left] == '0'): left = left + 1
	while (right < right_end && text[right] == '0'): right = right + 1
	if (left_end - left != right_end - right): return left_end - left > right_end - right
	while (left < left_end):
		if (text[left] != text[right]): return text[left] > text[right]
		left = left + 1
		right = right + 1
	return 0


# Return end after a complete QuantifierPrefix, 0 for legacy literal braces,
# or -1 for a reversed finite range. Caller handles quantifiability and lazy ?.
int js_regexp_quantifier(char* text, int start, int end):
	int i = start + 1
	int lower = i
	while (i < end && js_digit(text[i])): i = i + 1
	if (i == lower): return 0
	int lower_end = i
	if (i < end && text[i] == '}'): return i + 1
	if (i >= end || text[i] != ','): return 0
	i = i + 1
	int upper = i
	while (i < end && js_digit(text[i])): i = i + 1
	if (i >= end || text[i] != '}'): return 0
	if (i != upper && js_regexp_bound_greater(text, lower, lower_end, upper, i)): return -1
	return i + 1


int js_regexp_structure(char* text, int end, int unicode):
	list[int] groups = new list[int]
	int depth = 0
	int atom = 0
	int valid = 1
	int i = 1
	while (i < end && valid):
		int ch = text[i]
		if (ch == 92):
			i = i + 1
			if (i >= end):
				valid = 0
				break
			atom = text[i] != 'b' && text[i] != 'B'
			# Braced Unicode/property escapes are a single Atom. Their value
			# validation is a separate future pass, not quantifier parsing.
			if (unicode && (text[i] == 'u' || text[i] == 'p' || text[i] == 'P') && text[i + 1] == '{'):
				i = i + 2
				while (i < end && text[i] != '}'): i = i + 1
				if (i >= end): valid = 0
			i = i + 1
			continue
		if (ch == '['):
			i = i + 1
			while (i < end && text[i] != ']'):
				if (text[i] == 92): i = i + 1
				i = i + 1
			if (i >= end): valid = 0
			i = i + 1
			atom = 1
			continue
		if (ch == '('):
			int quantifiable = 1
			i = i + 1
			if (i < end && text[i] == '?'):
				i = i + 1
				if (text[i] == '=' || text[i] == '!'):
					# Annex B permits quantified lookahead only without u.
					quantifiable = unicode == 0
					i = i + 1
				else if (text[i] == ':'): i = i + 1
				else if (text[i] == '<'):
					i = i + 1
					if (text[i] == '=' || text[i] == '!'):
						quantifiable = 0
						i = i + 1
					else:
						int name_start = i
						while (i < end && text[i] != '>'): i = i + 1
						if (i == name_start || i >= end): valid = 0
						i = i + 1
				else:
					valid = 0
			groups.push(quantifiable)
			depth = depth + 1
			atom = 0
			continue
		if (ch == ')'):
			if (depth == 0):
				valid = 0
				break
			depth = depth - 1
			atom = groups[depth]
			groups.pop()
			i = i + 1
			continue
		if (ch == '|' || ch == '^' || ch == '$'):
			atom = 0
			i = i + 1
			continue
		int next = 0
		if (ch == '*' || ch == '+' || ch == '?'): next = i + 1
		if (ch == '{'): next = js_regexp_quantifier(text, i, end)
		if (next < 0 || (next > 0 && atom == 0)):
			valid = 0
			break
		if (next > 0):
			i = next
			if (i < end && text[i] == '?'): i = i + 1
			atom = 0
			continue
		if (unicode && (ch == '{' || ch == '}' || ch == ']')):
			valid = 0
			break
		atom = 1
		i = i + 1
	if (depth != 0): valid = 0
	list_free[int](groups)
	return valid


int js_regexp_syntax(char* text):
	# Tokenization already identified the closing slash and validated flags;
	# a backwards scan cannot confuse escaped slashes inside the pattern.
	int end = strlen(text) - 1
	int unicode = 0
	while (end > 0 && text[end] != '/'):
		if (text[end] == 'u'): unicode = 1
		end = end - 1
	if (end <= 0): return 0
	return js_regexp_structure(text, end, unicode)
