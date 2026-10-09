# Matcher emission engine: charset predicates, element/altlist matchers,
# fragment helpers, and the at_try_generate_matcher driver.
import libs.extras.grammars.antlr_to_pg.types
import libs.extras.grammars.antlr_to_pg.charsets
import libs.extras.grammars.antlr_to_pg.classify
import libs.extras.grammars.antlr_to_pg.matchers_ascii
import libs.extras.grammars.antlr_to_pg.matchers_analyze

void at_emit_indent(string_builder* out, int indent):
	int i = 0
	while (i < indent):
		string_append_char(out, 9)
		i = i + 1


void at_emit_c_char_literal(string_builder* out, int c):
	if (c == 10):
		string_append(out, c"10")
	else if (c == 13):
		string_append(out, c"13")
	else if (c == 9):
		string_append(out, c"9")
	else if (c == 0):
		string_append(out, c"0")
	else if (c == 39):
		string_append(out, c"39")
	else if (c == 92):
		string_append(out, c"92")
	else if ((c >= 32) && (c <= 126)):
		string_append_char(out, 39)
		string_append_char(out, c)
		string_append_char(out, 39)
	else:
		string_append_int(out, c)


# Emit a parenthesized predicate true when var_name is in raw.
# If raw is a negated charset ([^...]), flip force_negated; callers also
# pass force_negated for ~[...] atoms.
void at_emit_charset_pred(string_builder* out, char* raw, char* var_name, int force_negated):
	int negated = force_negated
	int start = 1
	if (at_charset_negated(raw)):
		if (negated):
			negated = 0
		else:
			negated = 1
		start = 2
	# Build the positive membership predicate into a temp, then wrap.
	string_builder* mem = string_new()
	int n = strlen(raw) - 1
	int i = start
	int first = 1
	while (i < n):
		int adv = 0
		int c = 0
		if (raw[i] == 92):
			c = at_parse_charset_escape(raw, i, n, &adv)
			if ((adv <= 0) || (c < 0)):
				c = 0
				adv = 1
			i = i + adv
		else:
			c = raw[i]
			i = i + 1
		int has_range = 0
		int c2 = 0
		if ((i < n) && (raw[i] == '-') && (i + 1 < n) && (raw[i + 1] != ']')):
			has_range = 1
			i = i + 1
			if (raw[i] == 92):
				c2 = at_parse_charset_escape(raw, i, n, &adv)
				if ((adv <= 0) || (c2 < 0)):
					c2 = 0
					adv = 1
				i = i + adv
			else:
				c2 = raw[i]
				i = i + 1
		if (first == 0):
			string_append(mem, c" | ")
		first = 0
		if (has_range):
			string_append_char(mem, '(')
			string_append(mem, var_name)
			string_append(mem, c" >= ")
			at_emit_c_char_literal(mem, c)
			string_append(mem, c") & (")
			string_append(mem, var_name)
			string_append(mem, c" <= ")
			at_emit_c_char_literal(mem, c2)
			string_append_char(mem, ')')
		else:
			string_append_char(mem, '(')
			string_append(mem, var_name)
			string_append(mem, c" == ")
			at_emit_c_char_literal(mem, c)
			string_append_char(mem, ')')
	if (first):
		string_append(mem, c"0")
	if (negated):
		string_append(out, c"(((")
		string_append(out, mem.data)
		string_append(out, c") == 0) & (")
		string_append(out, var_name)
		string_append(out, c" != 0))")
	else:
		string_append_char(out, '(')
		string_append(out, mem.data)
		string_append_char(out, ')')
	string_free(mem)


void at_emit_match_elements(string_builder* out, list[at_element*] elements, int indent);
void at_emit_match_altlist(string_builder* out, list[at_alt*] alts, int indent);
void at_ensure_frag_generated(char* frag_name);


# Emit code that advances `index` on success, or sets `_ok = 0` on failure.
# Caller must declare `int _ok = 1` and check `_ok` after.
void at_emit_match_element(string_builder* out, at_element* e, int indent):
	int tmp = g_matcher_tmp
	g_matcher_tmp = g_matcher_tmp + 1

	if (e.suffix == '?'):
		at_emit_indent(out, indent)
		string_append(out, c"if (_ok):\n")
		at_emit_indent(out, indent + 1)
		string_append(out, c"int _s")
		string_append_int(out, tmp)
		string_append(out, c" = index\n")
		at_emit_indent(out, indent + 1)
		string_append(out, c"int _ok_save")
		string_append_int(out, tmp)
		string_append(out, c" = _ok\n")
		at_element* copy = new at_element()
		copy.kind = e.kind
		copy.text = e.text
		copy.group_alts = e.group_alts
		copy.suffix = 0
		at_emit_match_element(out, copy, indent + 1)
		at_emit_indent(out, indent + 1)
		string_append(out, c"if (_ok == 0):\n")
		at_emit_indent(out, indent + 2)
		string_append(out, c"index = _s")
		string_append_int(out, tmp)
		string_append_char(out, 10)
		at_emit_indent(out, indent + 2)
		string_append(out, c"_ok = _ok_save")
		string_append_int(out, tmp)
		string_append_char(out, 10)
		return

	if ((e.suffix == '*') || (e.suffix == '+')):
		at_emit_indent(out, indent)
		string_append(out, c"if (_ok):\n")
		if (e.suffix == '+'):
			at_element* once = new at_element()
			once.kind = e.kind
			once.text = e.text
			once.group_alts = e.group_alts
			once.suffix = 0
			at_emit_match_element(out, once, indent + 1)
		at_emit_indent(out, indent + 1)
		string_append(out, c"while (_ok):\n")
		at_emit_indent(out, indent + 2)
		string_append(out, c"int _s")
		string_append_int(out, tmp)
		string_append(out, c" = index\n")
		at_element* body = new at_element()
		body.kind = e.kind
		body.text = e.text
		body.group_alts = e.group_alts
		body.suffix = 0
		at_emit_match_element(out, body, indent + 2)
		at_emit_indent(out, indent + 2)
		string_append(out, c"if (_ok == 0):\n")
		at_emit_indent(out, indent + 3)
		string_append(out, c"index = _s")
		string_append_int(out, tmp)
		string_append_char(out, 10)
		at_emit_indent(out, indent + 3)
		string_append(out, c"_ok = 1\n")
		at_emit_indent(out, indent + 3)
		string_append(out, c"break\n")
		at_emit_indent(out, indent + 2)
		string_append(out, c"if (index == _s")
		string_append_int(out, tmp)
		string_append(out, c"):\n")
		at_emit_indent(out, indent + 3)
		string_append(out, c"break\n")
		return

	# Required (no suffix)
	if (e.kind == 0):
		int lit_len = strlen(e.text)
		at_emit_indent(out, indent)
		string_append(out, c"if (_ok):\n")
		at_emit_indent(out, indent + 1)
		string_append(out, c"if (")
		int i = 0
		while (i < lit_len):
			if (i > 0):
				string_append(out, c" | ")
			string_append(out, c"(input[index + ")
			string_append_int(out, i)
			string_append(out, c"] != ")
			at_emit_c_char_literal(out, e.text[i])
			string_append_char(out, ')')
			i = i + 1
		if (lit_len == 0):
			string_append(out, c"0")
		string_append(out, c"):\n")
		at_emit_indent(out, indent + 2)
		string_append(out, c"_ok = 0\n")
		at_emit_indent(out, indent + 1)
		string_append(out, c"else:\n")
		at_emit_indent(out, indent + 2)
		string_append(out, c"index = index + ")
		string_append_int(out, lit_len)
		string_append_char(out, 10)
		return

	if ((e.kind == 1) || (e.kind == 5)):
		int force_neg = 0
		if (e.kind == 5):
			force_neg = 1
		at_emit_indent(out, indent)
		string_append(out, c"if (_ok):\n")
		at_emit_indent(out, indent + 1)
		string_append(out, c"if ((")
		at_emit_charset_pred(out, e.text, c"input[index]", force_neg)
		string_append(out, c") == 0):\n")
		at_emit_indent(out, indent + 2)
		string_append(out, c"_ok = 0\n")
		at_emit_indent(out, indent + 1)
		string_append(out, c"else:\n")
		at_emit_indent(out, indent + 2)
		string_append(out, c"index = index + 1\n")
		return

	if (e.kind == 4):
		at_emit_indent(out, indent)
		string_append(out, c"if (_ok):\n")
		at_emit_indent(out, indent + 1)
		string_append(out, c"if (input[index] == 0):\n")
		at_emit_indent(out, indent + 2)
		string_append(out, c"_ok = 0\n")
		at_emit_indent(out, indent + 1)
		string_append(out, c"else:\n")
		at_emit_indent(out, indent + 2)
		string_append(out, c"index = index + 1\n")
		return

	if (e.kind == 2):
		# EOF is an end-anchor: succeed without consuming (token matchers
		# already stop at NUL). Optional/star wrappers still work.
		if (strcmp(e.text, c"EOF") == 0):
			return
		at_ensure_frag_generated(e.text)
		char* fn = at_frag_fn_name(e.text)
		at_emit_indent(out, indent)
		string_append(out, c"if (_ok):\n")
		at_emit_indent(out, indent + 1)
		string_append(out, c"int _n")
		string_append_int(out, tmp)
		string_append(out, c" = ")
		string_append(out, fn)
		string_append(out, c"(input, index)\n")
		at_emit_indent(out, indent + 1)
		string_append(out, c"if (_n")
		string_append_int(out, tmp)
		string_append(out, c" < 0):\n")
		at_emit_indent(out, indent + 2)
		string_append(out, c"_ok = 0\n")
		at_emit_indent(out, indent + 1)
		string_append(out, c"else:\n")
		at_emit_indent(out, indent + 2)
		string_append(out, c"index = index + _n")
		string_append_int(out, tmp)
		string_append_char(out, 10)
		free(fn)
		return

	if (e.kind == 3):
		at_emit_indent(out, indent)
		string_append(out, c"if (_ok):\n")
		at_emit_match_altlist(out, e.group_alts, indent + 1)
		return

	at_emit_indent(out, indent)
	string_append(out, c"_ok = 0\n")


void at_emit_match_elements(string_builder* out, list[at_element*] elements, int indent):
	int i = 0
	while (i < elements.length):
		at_element* e = elements[i]
		at_emit_match_element(out, e, indent)
		i = i + 1


# Longest-match over alternatives. On entry `_ok` must be 1. On exit,
# `_ok` is 1 and `index` advanced on success, or `_ok` is 0 and `index`
# restored on total failure.
void at_emit_match_altlist(string_builder* out, list[at_alt*] alts, int indent):
	int tmp = g_matcher_tmp
	g_matcher_tmp = g_matcher_tmp + 1
	at_emit_indent(out, indent)
	string_append(out, c"int _best")
	string_append_int(out, tmp)
	string_append(out, c" = -1\n")
	at_emit_indent(out, indent)
	string_append(out, c"int _as")
	string_append_int(out, tmp)
	string_append(out, c" = index\n")
	int i = 0
	while (i < alts.length):
		at_alt* alt = alts[i]
		at_emit_indent(out, indent)
		string_append(out, c"index = _as")
		string_append_int(out, tmp)
		string_append_char(out, 10)
		at_emit_indent(out, indent)
		string_append(out, c"_ok = 1\n")
		if (alt.elements.length == 0):
			at_emit_indent(out, indent)
			string_append(out, c"if (0 > _best")
			string_append_int(out, tmp)
			string_append(out, c"):\n")
			at_emit_indent(out, indent + 1)
			string_append(out, c"_best")
			string_append_int(out, tmp)
			string_append(out, c" = 0\n")
		else:
			at_emit_match_elements(out, alt.elements, indent)
			at_emit_indent(out, indent)
			string_append(out, c"if (_ok):\n")
			at_emit_indent(out, indent + 1)
			string_append(out, c"if ((index - _as")
			string_append_int(out, tmp)
			string_append(out, c") > _best")
			string_append_int(out, tmp)
			string_append(out, c"):\n")
			at_emit_indent(out, indent + 2)
			string_append(out, c"_best")
			string_append_int(out, tmp)
			string_append(out, c" = index - _as")
			string_append_int(out, tmp)
			string_append_char(out, 10)
		i = i + 1
	at_emit_indent(out, indent)
	string_append(out, c"if (_best")
	string_append_int(out, tmp)
	string_append(out, c" < 0):\n")
	at_emit_indent(out, indent + 1)
	string_append(out, c"index = _as")
	string_append_int(out, tmp)
	string_append_char(out, 10)
	at_emit_indent(out, indent + 1)
	string_append(out, c"_ok = 0\n")
	at_emit_indent(out, indent)
	string_append(out, c"else:\n")
	at_emit_indent(out, indent + 1)
	string_append(out, c"index = _as")
	string_append_int(out, tmp)
	string_append(out, c" + _best")
	string_append_int(out, tmp)
	string_append_char(out, 10)
	at_emit_indent(out, indent + 1)
	string_append(out, c"_ok = 1\n")


# Deep-walk fragment refs (including nested groups) so helpers are emitted
# before any caller body. A shallow walk left refs inside nested groups to be
# discovered mid-body; those used to append a new top-level function into
# g_matchers_out while a caller was still open, which split the caller and
# surfaced as bogus "Cannot find symbol: '_asN'/'_sN'" errors (calculator,
# cto, turtle, sparql, vb6, …).
void at_ensure_frags_in_altlist(list[at_alt*] alts);

void at_ensure_frags_in_element(at_element* e):
	if (e.kind == 2):
		at_ensure_frag_generated(e.text)
	else if (e.kind == 3):
		if (e.group_alts != 0):
			at_ensure_frags_in_altlist(e.group_alts)


void at_ensure_frags_in_altlist(list[at_alt*] alts):
	if (alts == 0):
		return
	int i = 0
	while (i < alts.length):
		at_alt* alt = alts[i]
		int j = 0
		while (j < alt.elements.length):
			at_element* e = alt.elements[j]
			at_ensure_frags_in_element(e)
			j = j + 1
		i = i + 1


# Emit a complete fragment function. Body is buffered so any nested
# at_ensure_frag_generated calls finish writing helpers to g_matchers_out
# before this function's text is appended (no mid-function inserts).
void at_emit_frag_function(at_rule* frag):
	if ((frag.name in g_generated_frags)):
		return
	# Reserve the name before body emit so a cyclic ensure is a no-op.
	g_generated_frags[frag.name] = 1
	char* fn = at_frag_fn_name(frag.name)
	int d = 0
	int o = 0
	int c = 0
	if (at_is_nested_delim_frag(frag, &d, &o, &c)):
		at_emit_nested_delim_function(fn, d, o, c, 0)
		free(fn)
		return
	int ol = 0
	int cl = 0
	char* os = 0
	char* cs = 0
	if (at_is_self_nested_block_comment(frag, &ol, &os, &cl, &cs)):
		at_emit_nested_block_comment_function(fn, os, ol, cs, cl, 0)
		free(fn)
		return
	string_builder* body = string_new()
	string_append(body, c"\tint _start = index\n")
	string_append(body, c"\tint _ok = 1\n")
	at_emit_match_altlist(body, frag.alts, 1)
	string_append(body, c"\tif (_ok == 0):\n")
	string_append(body, c"\t\treturn -1\n")
	string_append(body, c"\treturn index - _start\n")
	string_append(g_matchers_out, c"\nint ")
	string_append(g_matchers_out, fn)
	string_append(g_matchers_out, c"(char* input, int index):\n")
	string_append(g_matchers_out, body.data)
	string_free(body)
	free(fn)


void at_ensure_frag_generated(char* frag_name):
	if ((frag_name in g_generated_frags)):
		return
	at_rule* frag = at_lookup_lexer_piece(frag_name)
	if (frag == 0):
		return
	# Cycle guard (classify already refuses recursion; this is belt-and-suspenders).
	if (g_frag_generating.get(frag_name, 0) == 1):
		return
	g_frag_generating[frag_name] = 1
	at_ensure_frags_in_altlist(frag.alts)
	g_frag_generating[frag_name] = 0
	at_emit_frag_function(frag)


void at_emit_token_matcher(at_rule* rule, char* short_name):
	char* fn = at_token_matcher_fn_name(short_name)
	int d = 0
	int o = 0
	int c = 0
	if (at_is_nested_delim_frag(rule, &d, &o, &c)):
		at_emit_nested_delim_function(fn, d, o, c, 1)
		free(fn)
		return
	int ol = 0
	int cl = 0
	char* os = 0
	char* cs = 0
	if (at_is_self_nested_block_comment(rule, &ol, &os, &cl, &cs)):
		at_emit_nested_block_comment_function(fn, os, ol, cs, cl, 1)
		free(fn)
		return
	# Pre-emit every reachable fragment (deep) before opening this function.
	at_ensure_frags_in_altlist(rule.alts)

	string_builder* body = string_new()
	string_append(body, c"\tint _start = index\n")
	string_append(body, c"\tint _ok = 1\n")
	at_emit_match_altlist(body, rule.alts, 1)
	string_append(body, c"\tif (_ok == 0):\n")
	string_append(body, c"\t\treturn 0\n")
	string_append(body, c"\treturn index - _start\n")
	string_append(g_matchers_out, c"\nint ")
	string_append(g_matchers_out, fn)
	string_append(g_matchers_out, c"(char* input, int index):\n")
	string_append(g_matchers_out, body.data)
	string_free(body)
	free(fn)


# Returns short matcher name on success, or 0 (with report) on refuse.
char* at_try_generate_matcher(at_rule* rule):
	g_ascii_approx_flag = 0
	char* reason = at_refuse_reason_rule(rule)
	if (reason != 0):
		at_report(c"UNRECOGNIZED lexer rule ", rule.name, reason)
		return 0
	string_builder* short_b = string_new()
	string_append(short_b, c"g_")
	string_append(short_b, g_matcher_parser_prefix)
	string_append_char(short_b, '_')
	string_append(short_b, rule.name)
	char* short_name = strclone(short_b.data)
	string_free(short_b)
	at_emit_token_matcher(rule, short_name)
	if (g_ascii_approx_flag):
		at_report(c"NOTE ASCII-subset approximation for ", rule.name, c"dropped \\u / bytes>127 from charset(s); ASCII ID/WS shapes kept")
	return short_name
