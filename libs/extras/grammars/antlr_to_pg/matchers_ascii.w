/*
Generated-matcher emitter for antlr_to_pg (this file plus the
matchers_analyze/matchers_emit modules). Compiles regular ANTLR lexer
rules (literals, charsets, negated charsets, fragment refs, groups,
wildcard, ? / * / + , multi-alternative) into W matcher functions named
pg_lexer_matcher_g_<parser>_<RULE>, with fragment helpers
pg_g_<parser>_frag_<NAME>. See MATCHER_GENERATION_PLAN.md Phase 2.

Emitted matchers avoid goto (W has break/continue but no labels): they
use a local `_ok` flag and early return / break instead.
*/
import libs.extras.grammars.antlr_to_pg.types
import libs.extras.grammars.antlr_to_pg.charsets


string_builder* g_matchers_out
map[char*, int] g_generated_frags
map[char*, int] g_frag_generating
int g_matcher_tmp
char* g_matcher_parser_prefix


char* at_frag_fn_name(char* frag_name):
	string_builder* b = string_new()
	string_append(b, c"pg_g_")
	string_append(b, g_matcher_parser_prefix)
	string_append(b, c"_frag_")
	string_append(b, frag_name)
	char* result = strclone(b.data)
	string_free(b)
	return result


char* at_token_matcher_fn_name(char* short_name):
	string_builder* b = string_new()
	string_append(b, c"pg_lexer_matcher_")
	string_append(b, short_name)
	char* result = strclone(b.data)
	string_free(b)
	return result


int at_byte_is_ascii(int c):
	# Mask: W may promote signed char bytes >127 as negative ints.
	int b = c & 255
	return b <= 127


int at_text_is_ascii(char* text):
	int i = 0
	while (text[i] != 0):
		if (at_byte_is_ascii(text[i]) == 0):
			return 0
		i = i + 1
	return 1


int at_parse_charset_escape(char* raw, int i, int n, int* adv);


int at_charset_has_non_ascii(char* raw):
	int n = strlen(raw) - 1
	int i = 1
	if (at_charset_negated(raw)):
		i = 2
	while (i < n):
		int adv = 0
		int c = 0
		if (raw[i] == 92):
			c = at_parse_charset_escape(raw, i, n, &adv)
			if ((adv <= 0) || (c < 0)):
				return 1
			i = i + adv
		else:
			c = raw[i]
			i = i + 1
		if (at_byte_is_ascii(c) == 0):
			return 1
		if ((i < n) && (raw[i] == '-') && (i + 1 < n) && (raw[i + 1] != ']')):
			i = i + 1
			int c2 = 0
			if (raw[i] == 92):
				c2 = at_parse_charset_escape(raw, i, n, &adv)
				if ((adv <= 0) || (c2 < 0)):
					return 1
				i = i + adv
			else:
				c2 = raw[i]
				i = i + 1
			if (at_byte_is_ascii(c2) == 0):
				return 1
	return 0


int at_hex_value(int c):
	if ((c >= '0') && (c <= '9')):
		return c - '0'
	if ((c >= 'a') && (c <= 'f')):
		return c - 'a' + 10
	if ((c >= 'A') && (c <= 'F')):
		return c - 'A' + 10
	return -1


# Parse \uXXXX / \u{...} / \n etc at raw[i] where raw[i]=='\\'.
# Returns codepoint or -1; sets *adv to bytes consumed (including '\\').
int at_parse_charset_escape(char* raw, int i, int n, int* adv):
	if ((i >= n) || (raw[i] != 92)):
		*adv = 0
		return -1
	if (i + 1 >= n):
		*adv = 1
		return -1
	int nc = raw[i + 1]
	if (nc == 'u'):
		# \u{HHHH...} (ANTLR brace form) or \uXXXX
		if ((i + 2 < n) && (raw[i + 2] == '{')):
			int j = i + 3
			int cp = 0
			int digits = 0
			while ((j < n) && (raw[j] != '}')):
				int hv = at_hex_value(raw[j])
				if (hv < 0):
					*adv = 2
					return -1
				cp = cp * 16 + hv
				digits = digits + 1
				j = j + 1
			if ((digits == 0) || (j >= n) || (raw[j] != '}')):
				*adv = 2
				return -1
			*adv = j - i + 1
			return cp
		if (i + 5 >= n):
			*adv = 2
			return -1
		int v0 = at_hex_value(raw[i + 2])
		int v1 = at_hex_value(raw[i + 3])
		int v2 = at_hex_value(raw[i + 4])
		int v3 = at_hex_value(raw[i + 5])
		if ((v0 < 0) || (v1 < 0) || (v2 < 0) || (v3 < 0)):
			*adv = 2
			return -1
		*adv = 6
		return (((v0 * 16) + v1) * 16 + v2) * 16 + v3
	# \p{...} / \P{...} Unicode properties — not expanded here; treat as
	# non-ASCII so ASCII-subset / UTF-8 fallbacks can decide.
	if ((nc == 'p') || (nc == 'P')):
		*adv = 2
		return 256
	*adv = 2
	return at_unescape_charset_char(nc)


void at_append_charset_byte(string_builder* out, int c):
	if (c == 9):
		string_append(out, c"\\t")
	else if (c == 10):
		string_append(out, c"\\n")
	else if (c == 13):
		string_append(out, c"\\r")
	else if ((c == ']') || (c == '-') || (c == 92) || (c == '^')):
		string_append_char(out, 92)
		string_append_char(out, c)
	else if ((c >= 32) && (c <= 126)):
		string_append_char(out, c)
	else if ((c > 0) && (c <= 127)):
		# Other ASCII controls (e.g. \\u000C form feed): keep as raw byte.
		string_append_char(out, c)


# Drop \\u / bytes>127 from a charset; clamp ranges into 1..127. Returns a
# fresh "[...]" / "[^...]" string, or 0 when nothing ASCII remains.
char* at_charset_ascii_subset(char* raw):
	if (raw == 0):
		return 0
	int n = strlen(raw) - 1
	if ((n < 1) || (raw[0] != '[')):
		return 0
	int start = 1
	int negated = 0
	if (at_charset_negated(raw)):
		negated = 1
		start = 2
	string_builder* out = string_new()
	string_append_char(out, '[')
	if (negated):
		string_append_char(out, '^')
	int i = start
	int kept = 0
	# Track which ASCII bytes 1..127 are in the positive set (for negated emptiness).
	char* ascii_mem = cast(char*, malloc(128))
	int ai = 0
	while (ai < 128):
		ascii_mem[ai] = 0
		ai = ai + 1
	while (i < n):
		int adv = 0
		int c = 0
		if (raw[i] == 92):
			c = at_parse_charset_escape(raw, i, n, &adv)
			if ((adv <= 0) || (c < 0)):
				free(ascii_mem)
				string_free(out)
				return 0
			i = i + adv
		else:
			c = raw[i]
			i = i + 1
			adv = 1
		int has_range = 0
		int c2 = c
		if ((i < n) && (raw[i] == '-') && (i + 1 < n) && (raw[i + 1] != ']')):
			has_range = 1
			i = i + 1
			if (raw[i] == 92):
				c2 = at_parse_charset_escape(raw, i, n, &adv)
				if ((adv <= 0) || (c2 < 0)):
					free(ascii_mem)
					string_free(out)
					return 0
				i = i + adv
			else:
				c2 = raw[i]
				i = i + 1
		# Clamp into ASCII; drop if the intersection is empty.
		if (has_range):
			if (c < 0):
				c = 0
			if (c2 < 0):
				c2 = 0
			if (c > 127):
				# Entire range above ASCII.
				pass
			else:
				if (c2 > 127):
					c2 = 127
				if (c <= c2):
					int lo = c
					if (lo < 1):
						# Keep NUL out of the matcher string; start at 1.
						lo = 1
					if (lo <= c2):
						at_append_charset_byte(out, lo)
						if (lo < c2):
							string_append_char(out, '-')
							at_append_charset_byte(out, c2)
						kept = 1
						int k = lo
						while (k <= c2):
							if (k < 128):
								ascii_mem[k] = 1
							k = k + 1
		else:
			if ((c >= 1) && (c <= 127)):
				at_append_charset_byte(out, c)
				ascii_mem[c] = 1
				kept = 1
	string_append_char(out, ']')
	if (kept == 0):
		free(ascii_mem)
		string_free(out)
		return 0
	if (negated):
		# If every ASCII byte 1..127 is in the positive set, ~S matches no ASCII.
		int all = 1
		ai = 1
		while (ai < 128):
			if (ascii_mem[ai] == 0):
				all = 0
			ai = ai + 1
		if (all):
			free(ascii_mem)
			string_free(out)
			return 0
	free(ascii_mem)
	char* result = strclone(out.data)
	string_free(out)
	return result


int g_ascii_approx_flag

char* at_approx_element_ascii(at_element* e);
char* at_approx_altlist_ascii(list[at_alt*] alts);


# If raw is a singleton non-ASCII codepoint charset (e.g. `[∀]` or
# `[\u2200]`), return a freshly allocated UTF-8 byte string for that
# codepoint; otherwise 0.
char* at_charset_singleton_utf8(char* raw):
	if (raw == 0):
		return 0
	if (at_charset_negated(raw)):
		return 0
	int n = strlen(raw) - 1
	if ((n < 2) || (raw[0] != '[')):
		return 0
	int i = 1
	int adv = 0
	int cp = 0
	if (raw[i] == 92):
		cp = at_parse_charset_escape(raw, i, n, &adv)
		if ((adv <= 0) || (cp < 0)):
			return 0
		i = i + adv
	else:
		# Raw UTF-8 sequence inside [...] — take one codepoint's bytes.
		# Mask to 0..255: W chars may be signed, so lead bytes look negative.
		int c0 = raw[i] & 255
		if (c0 < 128):
			return 0
		int need = 0
		if ((c0 & 224) == 192):
			need = 2
		else if ((c0 & 240) == 224):
			need = 3
		else if ((c0 & 248) == 240):
			need = 4
		else:
			return 0
		if (i + need > n):
			return 0
		# Verify continuation bytes.
		int k = 1
		while (k < need):
			int ck = raw[i + k] & 255
			if ((ck & 192) != 128):
				return 0
			k = k + 1
		string_builder* lit = string_new()
		k = 0
		while (k < need):
			string_append_char(lit, raw[i + k])
			k = k + 1
		i = i + need
		if (i != n):
			string_free(lit)
			return 0
		char* result = strclone(lit.data)
		string_free(lit)
		return result
	if ((i != n) || (cp <= 127)):
		return 0
	# Encode codepoint as UTF-8.
	string_builder* lit = string_new()
	if (cp <= 2047):
		string_append_char(lit, 192 | (cp / 64))
		string_append_char(lit, 128 | (cp & 63))
	else if (cp <= 65535):
		string_append_char(lit, 224 | (cp / 4096))
		string_append_char(lit, 128 | ((cp / 64) & 63))
		string_append_char(lit, 128 | (cp & 63))
	else if (cp <= 1114111):
		string_append_char(lit, 240 | (cp / 262144))
		string_append_char(lit, 128 | ((cp / 4096) & 63))
		string_append_char(lit, 128 | ((cp / 64) & 63))
		string_append_char(lit, 128 | (cp & 63))
	else:
		string_free(lit)
		return 0
	char* result = strclone(lit.data)
	string_free(lit)
	return result


# Rewrite non-ASCII charsets in-place to their ASCII subset (or fold a
# singleton Unicode charset to a UTF-8 literal). Returns 0 on success, or
# a refuse reason when nothing usable remains.
char* at_approx_element_ascii(at_element* e):
	if (e.kind == 0):
		# Non-ASCII / UTF-8 literals match as raw byte sequences.
		return 0
	if ((e.kind == 1) || (e.kind == 5)):
		if (e.text == 0):
			if (e.kind == 5):
				return c"negated atom is not a charset (or singleton-literal group)"
			return c"charset missing text"
		if (at_charset_has_non_ascii(e.text)):
			# Singleton Unicode ops (eiffel ∀ etc.): fold to UTF-8 literal.
			if (e.kind == 1):
				char* utf = at_charset_singleton_utf8(e.text)
				if (utf != 0):
					free(e.text)
					e.kind = 0
					e.text = utf
					g_ascii_approx_flag = 1
					return 0
			char* approx = at_charset_ascii_subset(e.text)
			if (approx == 0):
				if (e.kind == 5):
					return c"non-ASCII negated charset with empty ASCII subset"
				return c"non-ASCII charset with empty ASCII subset"
			free(e.text)
			e.text = approx
			g_ascii_approx_flag = 1
		return 0
	if (e.kind == 3):
		return at_approx_altlist_ascii(e.group_alts)
	if (e.kind == 2):
		# Fragment bodies are approximated when generated.
		return 0
	return 0


char* at_approx_altlist_ascii(list[at_alt*] alts):
	if (alts == 0):
		return c"missing alternatives"
	# Rebuild keeping alts that still have usable elements.
	list[at_alt*] kept = new list[at_alt*]
	int i = 0
	while (i < alts.length):
		at_alt* alt = alts[i]
		list[at_element*] elems = new list[at_element*]
		int ok = 1
		int j = 0
		while (j < alt.elements.length):
			at_element* e = alt.elements[j]
			char* reason = at_approx_element_ascii(e)
			if (reason != 0):
				# Optional / star bodies that vanish are fine; required ones drop the alt.
				if ((e.suffix == '?') || (e.suffix == '*')):
					pass
				else:
					ok = 0
			else:
				elems.push(e)
			j = j + 1
		if (ok):
			alt.elements = elems
			kept.push(alt)
		i = i + 1
	if (kept.length == 0):
		return c"all alternatives empty after ASCII-subset approximation"
	# Replace contents of alts in place (same list object used by callers).
	while (alts.length > 0):
		alts.pop()
	i = 0
	while (i < kept.length):
		alts.push(kept[i])
		i = i + 1
	return 0
