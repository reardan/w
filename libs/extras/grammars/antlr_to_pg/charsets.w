# ---------------------------------------------------------------------------
# charset analysis
# ---------------------------------------------------------------------------
import libs.extras.grammars.antlr_to_pg.types

int at_charset_negated(char* raw):
	return raw[1] == '^'


int at_charset_has_range(char* raw):
	int n = strlen(raw) - 1
	int i = 1
	while (i < n):
		if (raw[i] == 92):
			i = i + 2
		else:
			i = i + 1
		if ((i < n) && (raw[i] == '-') && (i + 1 < n) && (raw[i + 1] != ']')):
			return 1
	return 0


int at_unescape_charset_char(int c);


char* at_charset_single_letter(char* raw):
	if (at_charset_negated(raw)):
		return 0
	if (at_charset_has_range(raw)):
		return 0
	int n = strlen(raw) - 1
	int i = 1
	int letter = 0
	while (i < n):
		int c = raw[i]
		if (c == 92):
			c = at_unescape_charset_char(raw[i + 1])
			i = i + 2
		else:
			i = i + 1
		int upper = c
		if ((upper >= 'a') && (upper <= 'z')):
			upper = upper - 32
		if (letter == 0):
			letter = upper
		else if (letter != upper):
			return 0
	if (letter == 0):
		return 0
	char* out = cast(char*, malloc(2))
	out[0] = letter
	out[1] = 0
	return out


int at_is_digit_char(int c):
	return pg_lexer_is_digit(c)


int at_is_alpha_or_us_char(int c):
	return pg_lexer_is_alpha(c)


int at_is_alnum_or_us_char(int c):
	return pg_lexer_is_alnum(c)


int at_is_sign_char(int c):
	return (c == '+') | (c == '-')


int at_is_e_char(int c):
	return (c == 'e') | (c == 'E')


int at_is_space_char(int c):
	return (c == ' ') | (c == 9) | (c == 13) | (c == 10) | (c == 11) | (c == 12)


# Maps a charset escape's letter (the char right after '\') to the literal
# codepoint it denotes -- \t/\n/\r are control chars, anything else (\], \-,
# \\, ...) stands for itself.
int at_unescape_charset_char(int c):
	if (c == 't'):
		return 9
	if (c == 'n'):
		return 10
	if (c == 'r'):
		return 13
	return c


int at_charset_all_match(char* raw, at_char_pred* pred, int allow_ranges):
	if (at_charset_negated(raw)):
		return 0
	int n = strlen(raw) - 1
	int i = 1
	int saw_any = 0
	while (i < n):
		int c = raw[i]
		if (c == 92):
			c = at_unescape_charset_char(raw[i + 1])
			i = i + 2
		else:
			i = i + 1
		if (pred(c) == 0):
			return 0
		saw_any = 1
		if (allow_ranges):
			if ((i < n) && (raw[i] == '-') && (i + 1 < n) && (raw[i + 1] != ']')):
				i = i + 1
				int c2 = raw[i]
				if (c2 == 92):
					c2 = at_unescape_charset_char(raw[i + 1])
					i = i + 2
				else:
					i = i + 1
				if (pred(c2) == 0):
					return 0
	return saw_any


int at_charset_is_digits(char* raw):
	return at_charset_all_match(raw, at_is_digit_char, 1)


int at_charset_is_alpha_us(char* raw):
	return at_charset_all_match(raw, at_is_alpha_or_us_char, 1)


int at_charset_is_alnum_us(char* raw):
	return at_charset_all_match(raw, at_is_alnum_or_us_char, 1)


int at_charset_is_sign(char* raw):
	return at_charset_all_match(raw, at_is_sign_char, 0)


int at_charset_is_e(char* raw):
	return at_charset_all_match(raw, at_is_e_char, 0)


int at_charset_is_space(char* raw):
	return at_charset_all_match(raw, at_is_space_char, 0)


int at_charset_is_csv_text_stopset(char* raw):
	if (at_charset_negated(raw)):
		return 0
	if (at_charset_has_range(raw)):
		return 0
	int saw_comma = 0
	int saw_newline = 0
	int saw_return = 0
	int saw_quote = 0
	int n = strlen(raw) - 1
	int i = 1
	while (i < n):
		int c = raw[i]
		if (c == 92):
			c = at_unescape_charset_char(raw[i + 1])
			i = i + 2
		else:
			i = i + 1
		if (c == ','):
			saw_comma = 1
		else if (c == 10):
			saw_newline = 1
		else if (c == 13):
			saw_return = 1
		else if (c == '"'):
			saw_quote = 1
		else:
			return 0
	return saw_comma & saw_newline & saw_return & saw_quote


int at_text_is_digits(char* text):
	if (strlen(text) == 0):
		return 0
	int i = 0
	while (text[i] != 0):
		if (pg_lexer_is_digit(text[i]) == 0):
			return 0
		i = i + 1
	return 1


int at_text_is_alpha(char* text):
	if (strlen(text) == 0):
		return 0
	int i = 0
	while (text[i] != 0):
		int c = text[i]
		if (((c >= 'a') && (c <= 'z')) == 0):
			if (((c >= 'A') && (c <= 'Z')) == 0):
				return 0
		i = i + 1
	return 1


char* at_uppercase_clone(char* text):
	int n = strlen(text)
	char* out = cast(char*, malloc(n + 1))
	int i = 0
	while (i < n):
		int c = text[i]
		if ((c >= 'a') && (c <= 'z')):
			c = c - 32
		out[i] = c
		i = i + 1
	out[n] = 0
	return out


char* at_lowercase_clone(char* text):
	int n = strlen(text)
	char* out = cast(char*, malloc(n + 1))
	int i = 0
	while (i < n):
		int c = text[i]
		if ((c >= 'A') && (c <= 'Z')):
			c = c + 32
		out[i] = c
		i = i + 1
	out[n] = 0
	return out


# ---------------------------------------------------------------------------
# fragments / leaf resolution
# ---------------------------------------------------------------------------

at_rule* at_lookup_fragment(char* name):
	if ((name in g_fragments) == 0):
		return 0
	return g_fragments.get(name, 0)


# Fragments or other lexer rules (e.g. FLOAT referencing INT). Used by the
# matcher generator so multi-token lexer compositions resolve.
at_rule* at_lookup_lexer_piece(char* name):
	at_rule* frag = at_lookup_fragment(name)
	if (frag != 0):
		return frag
	if ((name in g_lexer_rules) == 0):
		return 0
	return g_lexer_rules.get(name, 0)


# Recognizes ANTLR's `fragment A: [aA];` case-insensitive-keyword idiom.
char* at_fragment_case_letter(at_rule* frag):
	if (frag == 0):
		return 0
	if (frag.alts.length != 1):
		return 0
	at_alt* alt = frag.alts[0]
	if (alt.elements.length != 1):
		return 0
	at_element* e = alt.elements[0]
	if (e.suffix != 0):
		return 0
	if (e.kind != 1):
		return 0
	return at_charset_single_letter(e.text)


char* at_leaf_charset_text(at_element* e):
	if (e.kind == 1):
		return e.text
	if (e.kind == 2):
		at_rule* frag = at_lookup_fragment(e.text)
		if (frag != 0):
			if (frag.alts.length == 1):
				at_alt* alt = frag.alts[0]
				if (alt.elements.length == 1):
					at_element* inner = alt.elements[0]
					if ((inner.suffix == 0) && (inner.kind == 1)):
						return inner.text
	return 0


int at_contains_doubled_delim(list[at_element*] elements, int delim):
	int i = 0
	while (i < elements.length):
		at_element* e = elements[i]
		if (e.kind == 0):
			if (strlen(e.text) == 2):
				if ((e.text[0] == delim) && (e.text[1] == delim)):
					return 1
		if (e.kind == 3):
			int j = 0
			while (j < e.group_alts.length):
				at_alt* alt = e.group_alts[j]
				if (at_contains_doubled_delim(alt.elements, delim)):
					return 1
				j = j + 1
		i = i + 1
	return 0


int at_is_newline_char(int c):
	return (c == 10) | (c == 13)


int at_is_tab_char(int c):
	return c == 9


int at_charset_is_newline(char* raw):
	return at_charset_all_match(raw, at_is_newline_char, 0)


int at_charset_is_tabs(char* raw):
	return at_charset_all_match(raw, at_is_tab_char, 0)


int at_all_charsets_space_like(list[at_element*] elements):
	if (elements.length == 0):
		return 0
	int i = 0
	while (i < elements.length):
		at_element* e = elements[i]
		if (e.kind != 1):
			return 0
		if (at_charset_is_space(e.text) == 0):
			return 0
		i = i + 1
	return 1


# 1 when every leaf charset is newline-only (CR/LF). Used to map referenced
# NL/EOL-style rules onto the existing `newline` matcher as visible tokens.
int at_all_charsets_newline_like(list[at_element*] elements):
	if (elements.length == 0):
		return 0
	int i = 0
	while (i < elements.length):
		at_element* e = elements[i]
		char* cs = at_leaf_charset_text(e)
		if (cs == 0):
			return 0
		if (at_charset_is_newline(cs) == 0):
			return 0
		i = i + 1
	return 1


int at_all_charsets_tab_like(list[at_element*] elements):
	if (elements.length == 0):
		return 0
	int i = 0
	while (i < elements.length):
		at_element* e = elements[i]
		char* cs = at_leaf_charset_text(e)
		if (cs == 0):
			return 0
		if (at_charset_is_tabs(cs) == 0):
			return 0
		i = i + 1
	return 1


int at_numeric_walk_element(at_element* e, int depth, int* has_digit);


int at_numeric_walk_elements(list[at_element*] elements, int depth, int* has_digit):
	int i = 0
	while (i < elements.length):
		at_element* e = elements[i]
		if (at_numeric_walk_element(e, depth, has_digit) == 0):
			return 0
		i = i + 1
	return 1


int at_numeric_walk_element(at_element* e, int depth, int* has_digit):
	if (e.kind == 0):
		if (at_text_is_digits(e.text)):
			return 1
		if ((strcmp(e.text, c".") == 0) | (strcmp(e.text, c"+") == 0) | (strcmp(e.text, c"-") == 0)):
			return 1
		return 0
	if (e.kind == 1):
		if (at_charset_is_digits(e.text)):
			has_digit[0] = 1
			return 1
		if (at_charset_is_sign(e.text)):
			return 1
		if (at_charset_is_e(e.text)):
			return 1
		return 0
	if (e.kind == 2):
		if (depth > 6):
			return 0
		at_rule* frag = at_lookup_fragment(e.text)
		if (frag == 0):
			return 0
		int j = 0
		while (j < frag.alts.length):
			at_alt* alt = frag.alts[j]
			if (at_numeric_walk_elements(alt.elements, depth + 1, has_digit) == 0):
				return 0
			j = j + 1
		return 1
	if (e.kind == 3):
		int j = 0
		while (j < e.group_alts.length):
			at_alt* alt = e.group_alts[j]
			if (at_numeric_walk_elements(alt.elements, depth + 1, has_digit) == 0):
				return 0
			j = j + 1
		return 1
	return 0


