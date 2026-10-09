# ---------------------------------------------------------------------------
# lexer rule shape classification
# ---------------------------------------------------------------------------
import libs.extras.grammars.antlr_to_pg.types
import libs.extras.grammars.antlr_to_pg.charsets

at_classification* at_make_classification(int kind, char* payload):
	at_classification* c = new at_classification()
	c.kind = kind
	c.payload = payload
	return c


at_classification* at_classify_lexer_rule(at_rule* rule):
	int wants_hidden = 0
	if (rule.command != 0):
		if ((strcmp(rule.command, c"skip") == 0) | (strcmp(rule.command, c"channel") == 0)):
			wants_hidden = 1

	if (rule.alts.length != 1):
		string_builder* b = string_new()
		string_append_int(b, rule.alts.length)
		string_append(b, c" alternatives -- no single pg lexer matcher can represent a multi-shape token")
		return at_make_classification(4, strclone(b.data))

	at_alt* alt = rule.alts[0]
	list[at_element*] elements = alt.elements
	int n = elements.length

	if (n == 1):
		at_element* only = elements[0]
		if ((only.suffix == 0) && (only.kind == 0)):
			return at_make_classification(0, strclone(only.text))

	if (n > 0):
		int all_ref = 1
		int i = 0
		while (i < n):
			at_element* e = elements[i]
			if ((e.suffix != 0) || (e.kind != 2)):
				all_ref = 0
			i = i + 1
		if (all_ref):
			string_builder* letters = string_new()
			int ok = 1
			i = 0
			while (i < n):
				at_element* e = elements[i]
				char* letter = at_fragment_case_letter(at_lookup_fragment(e.text))
				if (letter == 0):
					ok = 0
				else:
					string_append(letters, letter)
				i = i + 1
			if (ok):
				return at_make_classification(0, strclone(letters.data))

	if (n == 1):
		at_element* only = elements[0]
		if ((only.suffix == 0) && (only.kind == 4)):
			return at_make_classification(1, c"any")

	int referenced = (rule.name in g_parser_refs)
	if (at_all_charsets_newline_like(elements)):
		# Visible newline tokens (NL/EOL) referenced from parser rules must
		# stay as tokens; unreferenced hidden ones are covered by the
		# always-emitted `skip NEWLINE newline`.
		if (referenced):
			return at_make_classification(1, c"newline")
		if (wants_hidden):
			return at_make_classification(3, c"newline-only rule; covered by always-emitted `skip NEWLINE newline`")
		return at_make_classification(1, c"newline")

	if (at_all_charsets_tab_like(elements)):
		if (referenced):
			return at_make_classification(1, c"tabs")
		if (wants_hidden):
			return at_make_classification(3, c"tab-only rule; covered by always-emitted `skip TAB tabs`")
		return at_make_classification(1, c"tabs")

	if (at_all_charsets_space_like(elements)):
		if (referenced):
			# Fall through to the generated-matcher path (kind 4).
			return at_make_classification(4, c"referenced whitespace-only rule")
		return at_make_classification(3, c"whitespace-only rule; the pg generator auto-skips inline space/CR, and this tool always adds `skip NEWLINE newline` / `skip TAB tabs`")

	if (n >= 2):
		at_element* first = elements[0]
		at_element* last = elements[n - 1]
		# Line comments (//, #, --) run to end-of-line/EOF -- the tail is
		# often a group/alternation (CRLF vs EOF), not a plain closing
		# literal, so these only check the opener.
		if (first.kind == 0):
			if (strcmp(first.text, c"//") == 0):
				if (wants_hidden):
					return at_make_classification(2, c"c_line_comment")
				return at_make_classification(1, c"c_line_comment")
			if (strcmp(first.text, c"#") == 0):
				if (wants_hidden):
					return at_make_classification(2, c"line_comment")
				return at_make_classification(1, c"line_comment")
			if (strcmp(first.text, c"--") == 0):
				if (wants_hidden):
					return at_make_classification(2, c"sql_line_comment")
				return at_make_classification(1, c"sql_line_comment")
		if ((first.kind == 0) && (last.kind == 0)):
			if ((strcmp(first.text, c"\"") == 0) & (strcmp(last.text, c"\"") == 0)):
				if (at_contains_doubled_delim(elements, '"')):
					return at_make_classification(1, c"doubled_double_quote_string")
				return at_make_classification(1, c"string")
			if ((strcmp(first.text, c"'") == 0) & (strcmp(last.text, c"'") == 0)):
				if (at_contains_doubled_delim(elements, 39)):
					return at_make_classification(1, c"doubled_quote_string")
				return at_make_classification(1, c"char_literal")
			if ((strcmp(first.text, c"/*") == 0) & (strcmp(last.text, c"*/") == 0)):
				if (wants_hidden):
					return at_make_classification(2, c"block_comment")
				return at_make_classification(1, c"block_comment")

	if (n == 2):
		at_element* e0 = elements[0]
		at_element* e1 = elements[1]
		if (e1.suffix == '*'):
			char* cs1 = at_leaf_charset_text(e0)
			char* cs2 = at_leaf_charset_text(e1)
			if ((cs1 != 0) && (cs2 != 0)):
				if (at_charset_is_alpha_us(cs1)):
					if (at_charset_is_alnum_us(cs2)):
						return at_make_classification(1, c"identifier")

	if (n == 1):
		at_element* only = elements[0]
		if (only.suffix == '+'):
			char* cs = at_leaf_charset_text(only)
			if (cs != 0):
				if (at_charset_is_digits(cs)):
					return at_make_classification(1, c"digits")
		if ((only.suffix == '+') && (only.kind == 5) && (only.text != 0)):
			if (at_charset_is_csv_text_stopset(only.text)):
				return at_make_classification(1, c"csv_text")

	int has_digit = 0
	if (at_numeric_walk_elements(elements, 0, &has_digit)):
		if (has_digit):
			return at_make_classification(1, c"number")

	return at_make_classification(4, c"does not match a recognized lexer shape (identifier / digits / number / quoted string / line or block comment / whitespace / fixed keyword literal)")


# ---------------------------------------------------------------------------
# name / literal registries
# ---------------------------------------------------------------------------

void at_mark_used(char* name):
	g_used_names[name] = 1


char* at_punct_name(char* text):
	if (strcmp(text, c"{") == 0):
		return c"LBRACE"
	if (strcmp(text, c"}") == 0):
		return c"RBRACE"
	if (strcmp(text, c"[") == 0):
		return c"LBRACK"
	if (strcmp(text, c"]") == 0):
		return c"RBRACK"
	if (strcmp(text, c"(") == 0):
		return c"LPAREN"
	if (strcmp(text, c")") == 0):
		return c"RPAREN"
	if (strcmp(text, c",") == 0):
		return c"COMMA"
	if (strcmp(text, c".") == 0):
		return c"DOT"
	if (strcmp(text, c":") == 0):
		return c"COLON"
	if (strcmp(text, c";") == 0):
		return c"SEMI"
	if (strcmp(text, c"=") == 0):
		return c"ASSIGN"
	if (strcmp(text, c"==") == 0):
		return c"EQ"
	if (strcmp(text, c"!=") == 0):
		return c"NEQ"
	if (strcmp(text, c"<>") == 0):
		return c"NEQ2"
	if (strcmp(text, c"<") == 0):
		return c"LT"
	if (strcmp(text, c">") == 0):
		return c"GT"
	if (strcmp(text, c"<=") == 0):
		return c"LE"
	if (strcmp(text, c">=") == 0):
		return c"GE"
	if (strcmp(text, c"+") == 0):
		return c"PLUS"
	if (strcmp(text, c"-") == 0):
		return c"MINUS"
	if (strcmp(text, c"*") == 0):
		return c"STAR"
	if (strcmp(text, c"/") == 0):
		return c"SLASH"
	if (strcmp(text, c"%") == 0):
		return c"PERCENT"
	if (strcmp(text, c"|") == 0):
		return c"PIPE"
	if (strcmp(text, c"||") == 0):
		return c"CONCAT"
	if (strcmp(text, c"&") == 0):
		return c"AMP"
	if (strcmp(text, c"~") == 0):
		return c"TILDE"
	if (strcmp(text, c"?") == 0):
		return c"QUESTION"
	if (strcmp(text, c"->") == 0):
		return c"ARROW"
	if (strcmp(text, c"::") == 0):
		return c"DOUBLE_COLON"
	if (strcmp(text, c"!") == 0):
		return c"BANG"
	return 0


char* at_synth_literal_name(char* text):
	char* cand = at_punct_name(text)
	if (cand != 0):
		if ((cand in g_used_names) == 0):
			return strclone(cand)
	if (at_text_is_alpha(text)):
		char* upper = at_uppercase_clone(text)
		string_builder* b = string_new()
		string_append(b, c"KW_")
		string_append(b, upper)
		free(upper)
		char* result = strclone(b.data)
		string_free(b)
		if ((result in g_used_names) == 0):
			return result
		free(result)
	int n = 1
	while (1):
		string_builder* b = string_new()
		string_append(b, c"SYM_")
		string_append_int(b, n)
		char* cand2 = strclone(b.data)
		string_free(b)
		if ((cand2 in g_used_names) == 0):
			return cand2
		free(cand2)
		n = n + 1
	return 0


char* at_register_literal(char* name, char* text):
	if ((text in g_text_to_name)):
		return g_text_to_name.get(text, 0)
	g_literal_order.push(strclone(name))
	g_literal_text[name] = strclone(text)
	g_text_to_name[text] = strclone(name)
	at_mark_used(name)
	return name


# Parser `.` → builtin `any` matcher (one shared token per grammar).
char* at_ensure_any_token():
	if (g_any_token_name != 0):
		return g_any_token_name
	g_any_token_name = c"PG_ANY"
	g_token_names.push(strclone(g_any_token_name))
	g_token_matchers.push(strclone(c"any"))
	at_mark_used(g_any_token_name)
	return g_any_token_name


# Simple parser ~[...] / ~('a'|'b') (folded to a charset) → synthetic token
# with a generated negated-charset matcher. Dedupes by charset text.
char* at_ensure_negated_charset_token(char* charset_text):
	if (charset_text == 0):
		return 0
	if ((charset_text in g_negset_text_to_name)):
		return g_negset_text_to_name.get(charset_text, 0)
	g_negset_counter = g_negset_counter + 1
	string_builder* nb = string_new()
	string_append(nb, c"PG_NEGSET_")
	string_append_int(nb, g_negset_counter)
	char* tok_name = strclone(nb.data)
	string_free(nb)
	# Build a one-alt synthetic lexer rule and generate its matcher.
	at_element* el = new at_element()
	el.kind = 5
	el.text = strclone(charset_text)
	el.group_alts = 0
	el.suffix = 0
	at_alt* alt = new at_alt()
	alt.elements = new list[at_element*]
	alt.elements.push(el)
	at_rule* syn = new at_rule()
	syn.name = tok_name
	syn.is_fragment = 0
	syn.is_lexer = 1
	syn.alts = new list[at_alt*]
	syn.command = 0
	syn.alts.push(alt)
	char* short_name = at_try_generate_matcher(syn)
	if (short_name == 0):
		return 0
	g_token_names.push(strclone(tok_name))
	g_token_matchers.push(short_name)
	at_mark_used(tok_name)
	g_negset_text_to_name[strclone(charset_text)] = tok_name
	return tok_name


void at_report(char* prefix, char* rule_name, char* payload):
	string_builder* b = string_new()
	string_append(b, prefix)
	string_append(b, rule_name)
	string_append(b, c": ")
	string_append(b, payload)
	g_report_lines.push(strclone(b.data))
	string_free(b)


void at_report_plain(char* rule_name, char* message):
	string_builder* b = string_new()
	string_append(b, c"rule ")
	string_append(b, rule_name)
	string_append(b, c": ")
	string_append(b, message)
	g_report_lines.push(strclone(b.data))
	string_free(b)


# Append one ASCII byte to a charset builder, escaping specials.
void at_charset_append_byte(string_builder* cs, int ch):
	if ((ch < 1) || (ch > 127)):
		return
	if ((ch == ']') || (ch == '-') || (ch == 92) || (ch == '^')):
		string_append_char(cs, 92)
	string_append_char(cs, ch)


# Collect ASCII bytes a lexer piece can match as a single-char (or short
# optional-char) token into `cs`. Returns 1 on success, 0 if the piece is
# too complex (multi-char required literals, recursion, etc.).
# Fallback: if every alt starts with the same 1-byte literal (e.g.
# ESCAPED_CHAR: '\\' ...), contribute that opener only.
int at_collect_token_charset_bytes(char* name, string_builder* cs, map[char*, int] visiting):
	if (name == 0):
		return 0
	if (visiting.get(name, 0) == 1):
		return 0
	at_rule* piece = at_lookup_lexer_piece(name)
	if (piece == 0):
		return 0
	visiting[name] = 1
	int ok = 1
	int ai = 0
	while ((ai < piece.alts.length) & ok):
		at_alt* alt = piece.alts[ai]
		int ei = 0
		while ((ei < alt.elements.length) & ok):
			at_element* e = alt.elements[ei]
			# Optional elements contribute their chars but don't fail.
			if ((e.kind == 0) && (e.text != 0)):
				if (strlen(e.text) == 1):
					at_charset_append_byte(cs, e.text[0])
				else if (e.suffix == '?'):
					# optional multi-char — skip contribution
					pass
				else:
					# Required multi-char literal (e.g. full CRLF "\r\n"):
					# contribute each distinct byte as an approximation.
					int li = 0
					while (li < strlen(e.text)):
						at_charset_append_byte(cs, e.text[li])
						li = li + 1
			else if ((e.kind == 1) && (e.text != 0)):
				int cn = strlen(e.text)
				if ((cn >= 2) && (e.text[0] == '[')):
					int ci = 1
					if (e.text[1] == '^'):
						ok = 0
					else:
						while (ci < cn - 1):
							# Copy raw charset body (may include ranges/escapes).
							string_append_char(cs, e.text[ci])
							ci = ci + 1
				else:
					ok = 0
			else if (e.kind == 2):
				if (strcmp(e.text, c"EOF") == 0):
					pass
				else if (at_collect_token_charset_bytes(e.text, cs, visiting) == 0):
					ok = 0
			else if (e.kind == 3):
				# Group: union of alts.
				int gi = 0
				while ((gi < e.group_alts.length) & ok):
					at_alt* ga = e.group_alts[gi]
					# Inline: only single-element alts of lit/charset/ref.
					if (ga.elements.length == 1):
						at_element* ge = ga.elements[0]
						if ((ge.kind == 0) && (ge.text != 0) & (strlen(ge.text) == 1)):
							at_charset_append_byte(cs, ge.text[0])
						else if ((ge.kind == 1) && (ge.text != 0)):
							int cn = strlen(ge.text)
							int ci = 1
							if ((cn >= 2) && (ge.text[0] == '[') && (ge.text[1] != '^')):
								while (ci < cn - 1):
									string_append_char(cs, ge.text[ci])
									ci = ci + 1
							else:
								ok = 0
						else if (ge.kind == 2):
							if (at_collect_token_charset_bytes(ge.text, cs, visiting) == 0):
								ok = 0
						else:
							ok = 0
					else:
						ok = 0
					gi = gi + 1
			else:
				ok = 0
			ei = ei + 1
		ai = ai + 1
	if (ok == 0):
		# Fallback: shared single-byte literal opener across all alts.
		int shared = -1
		int all_ok = 1
		ai = 0
		while ((ai < piece.alts.length) & all_ok):
			at_alt* alt = piece.alts[ai]
			if (alt.elements.length < 1):
				all_ok = 0
			else:
				at_element* e0 = alt.elements[0]
				if ((e0.kind == 0) && (e0.suffix == 0) && (e0.text != 0) & (strlen(e0.text) == 1)):
					int ch = e0.text[0] & 255
					if (shared < 0):
						shared = ch
					else if (shared != ch):
						all_ok = 0
				else:
					all_ok = 0
			ai = ai + 1
		if ((all_ok) & (shared >= 0)):
			at_charset_append_byte(cs, shared)
			ok = 1
	visiting[name] = 0
	return ok


# Fold parser ~ ( TokenA | TokenB | 'x' | [..] ) groups (kind 5 with
# group_alts and text==0) into a positive charset for PG_NEGSET.
void at_fold_negated_token_refs_element(at_element* e):
	if (e == 0):
		return
	if (e.kind == 3):
		if (e.group_alts != 0):
			int i = 0
			while (i < e.group_alts.length):
				at_alt* a = e.group_alts[i]
				int j = 0
				while (j < a.elements.length):
					at_fold_negated_token_refs_element(a.elements[j])
					j = j + 1
				i = i + 1
		return
	if (e.kind != 5):
		return
	if (e.text != 0):
		return
	if (e.group_alts == 0):
		return
	string_builder* cs = string_new()
	string_append_char(cs, '[')
	int ok = 1
	map[char*, int] visiting = new map[char*, int]
	int gi = 0
	while ((gi < e.group_alts.length) & ok):
		at_alt* galt = e.group_alts[gi]
		if (galt.elements.length != 1):
			ok = 0
		else:
			at_element* ge = galt.elements[0]
			if (ge.suffix != 0):
				ok = 0
			else if ((ge.kind == 0) && (ge.text != 0) & (strlen(ge.text) == 1)):
				at_charset_append_byte(cs, ge.text[0])
			else if ((ge.kind == 1) && (ge.text != 0)):
				int cn = strlen(ge.text)
				if ((cn >= 2) && (ge.text[0] == '[') && (ge.text[1] != '^')):
					int ci = 1
					while (ci < cn - 1):
						string_append_char(cs, ge.text[ci])
						ci = ci + 1
				else:
					ok = 0
			else if (ge.kind == 2):
				# Collect into a temp so a failed piece doesn't pollute cs.
				string_builder* tmp = string_new()
				if (at_collect_token_charset_bytes(ge.text, tmp, visiting) == 0):
					ok = 0
				else:
					string_append(cs, tmp.data)
				string_free(tmp)
			else:
				ok = 0
		gi = gi + 1
	string_append_char(cs, ']')
	if (ok):
		if (strlen(cs.data) > 2):
			e.text = strclone(cs.data)
			e.group_alts = 0
	string_free(cs)


void at_fold_negated_token_refs(list[at_rule*] rules):
	int i = 0
	while (i < rules.length):
		at_rule* r = rules[i]
		int ai = 0
		while (ai < r.alts.length):
			at_alt* alt = r.alts[ai]
			int ei = 0
			while (ei < alt.elements.length):
				at_fold_negated_token_refs_element(alt.elements[ei])
				ei = ei + 1
			ai = ai + 1
		i = i + 1


void at_collect_refs_from_altlist(list[at_alt*] alts);


void at_collect_refs_from_element(at_element* e):
	if (e.kind == 2):
		if (strcmp(e.text, c"EOF") != 0):
			g_parser_refs[e.text] = 1
	else if (e.kind == 3):
		at_collect_refs_from_altlist(e.group_alts)


void at_collect_refs_from_altlist(list[at_alt*] alts):
	int i = 0
	while (i < alts.length):
		at_alt* alt = alts[i]
		int j = 0
		while (j < alt.elements.length):
			at_element* e = alt.elements[j]
			at_collect_refs_from_element(e)
			j = j + 1
		i = i + 1


void at_collect_parser_refs(list[at_rule*] rules):
	int i = 0
	while (i < rules.length):
		at_rule* r = rules[i]
		if ((r.is_fragment == 0) && (r.is_lexer == 0)):
			at_collect_refs_from_altlist(r.alts)
		i = i + 1


void at_classify_all_lexer_rules(list[at_rule*] rules):
	int i = 0
	while (i < rules.length):
		at_rule* r = rules[i]
		if ((r.is_fragment == 0) && (r.is_lexer == 1)):
			at_classification* c = at_classify_lexer_rule(r)
			if (c.kind == 0):
				at_register_literal(r.name, c.payload)
			else if (c.kind == 1):
				g_token_names.push(strclone(r.name))
				g_token_matchers.push(strclone(c.payload))
				at_mark_used(r.name)
				if (strcmp(c.payload, c"number") == 0):
					at_alt* alt0 = r.alts[0]
					if (alt0.elements.length > 0):
						at_element* first = alt0.elements[0]
						if ((first.kind == 0) && (first.suffix == '?')):
							if ((strcmp(first.text, c"+") == 0) | (strcmp(first.text, c"-") == 0)):
								at_report(c"NOTE token ", r.name, c"(matcher=number): source allows an optional leading sign, which lexer.w's `number` matcher does not consume -- negative literals will fail to lex; consider a separate MINUS token handled in the parser grammar instead (see how sql.pg treats unary minus)")
			else if (c.kind == 2):
				# Parser-referenced "hidden" rules must stay visible tokens
				# (d2 COMMENT, plantUML COMMENT, codeql QL_DOC, …).
				if ((r.name in g_parser_refs)):
					g_token_names.push(strclone(r.name))
					g_token_matchers.push(strclone(c.payload))
					at_report(c"NOTE token ", r.name, c"parser-referenced despite skip/channel -- emitted as token")
				else:
					g_skip_names.push(strclone(r.name))
					g_skip_matchers.push(strclone(c.payload))
				at_mark_used(r.name)
			else if (c.kind == 3):
				at_report(c"DROPPED lexer rule ", r.name, c.payload)
			else:
				# Fixed-matcher miss: try generating a W matcher from the IR.
				char* short_name = at_try_generate_matcher(r)
				if (short_name != 0):
					int wants_hidden = 0
					if (r.command != 0):
						if ((strcmp(r.command, c"skip") == 0) | (strcmp(r.command, c"channel") == 0)):
							wants_hidden = 1
					# Same visibility rule for generated matchers.
					if ((r.name in g_parser_refs)):
						wants_hidden = 0
					if (wants_hidden):
						g_skip_names.push(strclone(r.name))
						g_skip_matchers.push(short_name)
					else:
						g_token_names.push(strclone(r.name))
						g_token_matchers.push(short_name)
					at_mark_used(r.name)
					at_report(c"GENERATED matcher for ", r.name, short_name)
		i = i + 1


