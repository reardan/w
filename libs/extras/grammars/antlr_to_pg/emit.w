# .pg text emission for parsed and classified ANTLR rules.
import libs.extras.grammars.antlr_to_pg.types
import libs.extras.grammars.antlr_to_pg.classify


# w's pg.pg (unlike the real grammar_reader.w) models parser/token/skip/
# literal/start/rule/recover as globally reserved literals rather than
# context-sensitive keywords, so a translated parser rule literally named
# e.g. "rule" or "token" (both plausible, lowercase English words) would
# corrupt the self-check parse. Rename any exact collision consistently.
int at_is_pg_reserved(char* name):
	if (strcmp(name, c"parser") == 0):
		return 1
	if (strcmp(name, c"token") == 0):
		return 1
	if (strcmp(name, c"skip") == 0):
		return 1
	if (strcmp(name, c"literal") == 0):
		return 1
	if (strcmp(name, c"start") == 0):
		return 1
	if (strcmp(name, c"rule") == 0):
		return 1
	if (strcmp(name, c"recover") == 0):
		return 1
	if (strcmp(name, c"mode") == 0): return 1
	if (strcmp(name, c"import") == 0): return 1
	if (strcmp(name, c"fragment") == 0): return 1
	if (strcmp(name, c"lexer") == 0): return 1
	if (strcmp(name, c"lexer_mode") == 0): return 1
	if (strcmp(name, c"lexer_rule") == 0): return 1
	if (strcmp(name, c"lexer_guard") == 0): return 1
	if (strcmp(name, c"lexer_action") == 0): return 1
	if (strcmp(name, c"lexer_command") == 0): return 1
	if (strcmp(name, c"lexer_priority") == 0): return 1
	if (strcmp(name, c"goal") == 0): return 1
	return 0


char* at_resolve_parser_rule_name(char* name):
	if ((name in g_name_remap)):
		return g_name_remap.get(name, 0)
	if (at_is_pg_reserved(name)):
		# Not a rule we've declared (most likely a dangling reference into
		# another grammar file via `import`, already reported separately as
		# undefined) but still collides with a pg keyword -- rename on the
		# fly so the emitted term stays valid pg syntax either way.
		string_builder* b = string_new()
		string_append(b, name)
		string_append(b, c"_")
		char* renamed = strclone(b.data)
		string_free(b)
		g_name_remap[name] = renamed
		return renamed
	return name


void at_collect_rule_names(list[at_rule*] rules):
	int i = 0
	while (i < rules.length):
		at_rule* r = rules[i]
		if ((r.is_fragment == 0) && (r.is_lexer == 0)):
			char* final_name = r.name
			if (at_is_pg_reserved(r.name)):
				string_builder* b = string_new()
				string_append(b, r.name)
				string_append(b, c"_")
				final_name = strclone(b.data)
				string_free(b)
				# Keep appending '_' until the remapped name is free -- a
				# sibling rule may already be named `start_` when we rename
				# reserved `start`, etc.
				while ((final_name in g_all_rule_names) | (final_name in g_seen_rule_names)):
					string_builder* b2 = string_new()
					string_append(b2, final_name)
					string_append(b2, c"_")
					free(final_name)
					final_name = strclone(b2.data)
					string_free(b2)
				g_name_remap[r.name] = final_name
			g_all_rule_names[final_name] = 1
		i = i + 1


# ---------------------------------------------------------------------------
# parser-rule translation: literal collection + group lifting
# ---------------------------------------------------------------------------

char* at_next_group_name(char* owning_rule):
	int n = g_group_counter.get(owning_rule, 0) + 1
	g_group_counter[owning_rule] = n
	string_builder* b = string_new()
	string_append(b, owning_rule)
	string_append(b, c"_g")
	string_append_int(b, n)
	char* name = strclone(b.data)
	string_free(b)
	return name


list[list[at_term*]] at_translate_altlist(char* owning_rule, list[at_alt*] alts);


at_term* at_translate_element(char* owning_rule, at_element* e):
	at_term* term = new at_term()
	term.suffix = e.suffix
	if (e.kind == 2):
		char* resolved = at_resolve_parser_rule_name(e.text)
		if (strcmp(e.text, c"EOF") != 0):
			if (((resolved in g_all_rule_names) == 0) & ((resolved in g_used_names) == 0)):
				string_builder* b = string_new()
				string_append(b, c"reference to undefined rule/token '")
				string_append(b, e.text)
				string_append(b, c"'")
				at_report_plain(owning_rule, b.data)
				string_free(b)
		term.name = strclone(resolved)
		return term
	if (e.kind == 0):
		if ((e.text in g_text_to_name)):
			term.name = strclone(g_text_to_name.get(e.text, 0))
		else:
			char* name = at_synth_literal_name(e.text)
			at_register_literal(name, e.text)
			term.name = name
		return term
	if (e.kind == 3):
		char* helper = at_next_group_name(owning_rule)
		g_parser_rule_names.push(strclone(helper))
		g_rule_alts[helper] = at_translate_altlist(helper, e.group_alts)
		term.name = helper
		return term
	if (e.kind == 4):
		term.name = strclone(at_ensure_any_token())
		return term
	if (e.kind == 5):
		if (e.text != 0):
			char* neg_tok = at_ensure_negated_charset_token(e.text)
			if (neg_tok != 0):
				term.name = strclone(neg_tok)
				return term
		at_report_plain(owning_rule, c"negated set (~...) is not a simple charset -- emitting an undeclared UNSUPPORTED_NEGATED_SET reference")
		term.name = c"UNSUPPORTED_NEGATED_SET"
		return term
	at_report_plain(owning_rule, c"unsupported parser atom -- emitting an undeclared UNSUPPORTED_ATOM reference")
	term.name = c"UNSUPPORTED_ATOM"
	return term


list[at_term*] at_translate_alt(char* owning_rule, at_alt* alt):
	list[at_term*] terms = new list[at_term*]
	int i = 0
	while (i < alt.elements.length):
		at_element* e = alt.elements[i]
		terms.push(at_translate_element(owning_rule, e))
		i = i + 1
	return terms


list[list[at_term*]] at_translate_altlist(char* owning_rule, list[at_alt*] alts):
	list[list[at_term*]] out = new list[list[at_term*]]
	int i = 0
	while (i < alts.length):
		at_alt* alt = alts[i]
		out.push(at_translate_alt(owning_rule, alt))
		i = i + 1
	return out


void at_translate_all_parser_rules(list[at_rule*] rules):
	int i = 0
	while (i < rules.length):
		at_rule* r = rules[i]
		if ((r.is_fragment == 0) && (r.is_lexer == 0)):
			char* final_name = at_resolve_parser_rule_name(r.name)
			g_parser_rule_names.push(strclone(final_name))
			g_rule_alts[final_name] = at_translate_altlist(final_name, r.alts)
		i = i + 1


# ---------------------------------------------------------------------------
# emit .pg text
# ---------------------------------------------------------------------------

void at_append_pg_string_literal(string_builder* out, char* text):
	string_append_char(out, '"')
	int i = 0
	while (text[i] != 0):
		int c = text[i]
		if (c == 92):
			string_append(out, c"\\\\")
		else if (c == '"'):
			string_append(out, c"\\\"")
		else if (c == 10):
			string_append(out, c"\\n")
		else if (c == 9):
			string_append(out, c"\\t")
		else if (c == 13):
			string_append(out, c"\\r")
		else:
			string_append_char(out, c)
		i = i + 1
	string_append_char(out, '"')


void at_emit(string_builder* out, char* parser_name):
	string_append(out, c"parser ")
	string_append(out, parser_name)
	string_append(out, c"\n\n")
	# Always-emitted skips use reserved names so source lexer rules named
	# NEWLINE/TAB (common keyword literals, or visible tab tokens) don't
	# collide with the generated `*_token_NEWLINE` / `*_token_TAB` symbols.
	string_append(out, c"# Always present: the pg lexer only auto-skips inline space/CR, not tabs or newlines.\n")
	string_append(out, c"skip PG_SKIP_NEWLINE newline\n")
	string_append(out, c"skip PG_SKIP_TAB tabs\n")
	int i = 0
	while (i < g_skip_names.length):
		string_append(out, c"skip ")
		string_append(out, g_skip_names[i])
		string_append_char(out, ' ')
		string_append(out, g_skip_matchers[i])
		string_append_char(out, 10)
		i = i + 1
	string_append_char(out, 10)

	i = 0
	while (i < g_token_names.length):
		string_append(out, c"token ")
		string_append(out, g_token_names[i])
		string_append_char(out, ' ')
		string_append(out, g_token_matchers[i])
		string_append_char(out, 10)
		i = i + 1
	string_append_char(out, 10)

	i = 0
	while (i < g_literal_order.length):
		char* name = g_literal_order[i]
		char* text = g_literal_text.get(name, 0)
		string_append(out, c"literal ")
		string_append(out, name)
		string_append_char(out, ' ')
		at_append_pg_string_literal(out, text)
		string_append_char(out, 10)
		i = i + 1
	string_append_char(out, 10)

	if (g_parser_rule_names.length > 0):
		string_append(out, c"start ")
		string_append(out, g_parser_rule_names[0])
		string_append_char(out, 10)
	string_append_char(out, 10)

	i = 0
	while (i < g_parser_rule_names.length):
		char* name = g_parser_rule_names[i]
		list[list[at_term*]] alts = g_rule_alts.get(name, 0)
		string_append(out, c"rule ")
		string_append(out, name)
		string_append(out, c" = ")
		int j = 0
		while (j < alts.length):
			if (j > 0):
				string_append(out, c" | ")
			list[at_term*] terms = alts[j]
			int k = 0
			while (k < terms.length):
				if (k > 0):
					string_append_char(out, ' ')
				at_term* term = terms[k]
				string_append(out, term.name)
				if (term.suffix != 0):
					string_append_char(out, term.suffix)
				k = k + 1
			j = j + 1
		string_append_char(out, 10)
		i = i + 1

	if (g_report_lines.length > 0):
		string_append(out, c"\n# --- translation report (see build log / --report for details) ---\n")
		i = 0
		while (i < g_report_lines.length):
			string_append(out, c"# ")
			string_append(out, g_report_lines[i])
			string_append_char(out, 10)
			i = i + 1


