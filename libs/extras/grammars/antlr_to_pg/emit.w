# .pg text emission for parsed and classified ANTLR rules.
import libs.extras.grammars.antlr_to_pg.types
import libs.extras.grammars.antlr_to_pg.classify
import libs.extras.grammars.antlr_to_pg.source_metadata


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
	if (strcmp(name, c"node_meta") == 0): return 1
	if (strcmp(name, c"term_meta") == 0): return 1
	if (strcmp(name, c"import") == 0): return 1
	if (strcmp(name, c"fragment") == 0): return 1
	if (strcmp(name, c"lexer") == 0): return 1
	if (strcmp(name, c"lexer_mode") == 0): return 1
	if (strcmp(name, c"lexer_rule") == 0): return 1
	if (strcmp(name, c"lexer_guard") == 0): return 1
	if (strcmp(name, c"lexer_action") == 0): return 1
	if (strcmp(name, c"lexer_command") == 0): return 1
	if (strcmp(name, c"lexer_priority") == 0): return 1
	if (strcmp(name, c"lexer_progress") == 0): return 1
	if (strcmp(name, c"lexer_channel") == 0): return 1
	if (strcmp(name, c"lexer_eof") == 0): return 1
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
	while (1):
		char* name = strclone(cstr(f"{owning_rule}_g{n}"))
		if (((name in g_all_rule_names) == 0) && ((name in g_used_names) == 0)):
			g_group_counter[owning_rule] = n
			g_all_rule_names[name] = 1
			return name
		free(name)
		n = n + 1
	return 0


list[list[at_term*]] at_translate_altlist(char* owning_rule, list[at_alt*] alts);


char* at_translate_parser_set(char* owner, at_element* element):
	if (g_at_parser_sets == 0): g_at_parser_sets = new list[at_parser_set*]
	at_parser_set* pending = new at_parser_set()
	pending.helper = at_next_group_name(owner)
	pending.excluded = new map[char*, int]
	if (element.kind == 5):
		for at_alt* alternative in element.group_alts:
			at_element* excluded = alternative.elements[0]
			char* name = excluded.text
			if (excluded.kind == 0):
				name = g_text_to_name.get(excluded.text, 0)
				if (name == 0):
					name = at_synth_literal_name(excluded.text)
					at_register_literal(name, excluded.text)
			pending.excluded[name] = 1
	g_at_parser_sets.push(pending)
	return pending.helper


void at_finish_parser_sets():
	if (g_at_parser_sets == 0): return
	map[char*, int] kinds = new map[char*, int]
	for char* name in g_literal_order: kinds[name] = 1
	for char* name in g_token_names: kinds[name] = 1
	for char* name in g_at_token_identities: kinds[name] = 1
	for at_parser_set* pending in g_at_parser_sets:
		list[at_alt*] alternatives = new list[at_alt*]
		for char* name in kinds:
			if (name in pending.excluded): continue
			at_alt* alternative = new at_alt()
			alternative.elements = new list[at_element*]
			at_element* atom = new at_element()
			atom.kind = 2
			atom.text = name
			alternative.elements.push(atom)
			alternatives.push(alternative)
		if (alternatives.length == 0):
			# An empty complement is a valid never-matching token set.
			char* never = at_next_group_name(pending.helper)
			g_at_token_identities.push(never)
			at_mark_used(never)
			at_alt* alternative = new at_alt()
			alternative.elements = new list[at_element*]
			at_element* atom = new at_element()
			atom.kind = 2
			atom.text = never
			alternative.elements.push(atom)
			alternatives.push(alternative)
		g_parser_rule_names.push(pending.helper)
		g_rule_alts[pending.helper] = at_translate_altlist(pending.helper, alternatives)
	kinds.free()


at_term* at_translate_element(char* owning_rule, at_element* e):
	at_term* term = new at_term()
	term.suffix = e.suffix
	if (g_at_prediction && ((e.kind == 4) || (e.kind == 5)) && at_parser_set_supported(e)):
		term.name = at_translate_parser_set(owning_rule, e)
		term.label = e.label
		return term
	term.label = e.label
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
	if (g_at_prediction): g_at_source_alts[owning_rule] = alts
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
	at_finish_parser_sets()


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


char* at_pg_mode_name(char* mode):
	if (strcmp(mode, c"DEFAULT_MODE") == 0): return c"DEFAULT"
	return cstr(f"AT_MODE_{mode}")


void at_emit_stateful_lexer(string_builder* out):
	string_append(out, c"lexer stateful\nlexer_priority ordered\nlexer_eof any_mode\n")
	if (g_at_channels != 0):
		for char* channel in g_at_channels: string_append(out, cstr(f"lexer_channel AT_CHANNEL_{channel}\n"))
	if (g_at_exact_lexer): string_append(out, c"lexer_progress guarded\n")
	if (g_at_token_identities != 0):
		for char* name in g_at_token_identities:
			at_rule* source = g_lexer_rules.get(name, 0)
			# A fragment does not declare a token, even when a tokens{} name
			# shares its spelling and another rule emits that name with type().
			if ((source == 0) || source.is_fragment): string_append(out, cstr(f"token {name}\n"))
	for char* mode in g_at_modes:
		string_append(out, cstr(f"lexer_mode {at_pg_mode_name(mode)}\n"))
	# Implicit parser literals outrank explicit lexer rules on equal length.
	# Explicit literals are emitted below, in original lexer declaration order.
	for char* name in g_literal_order:
		if (name in g_lexer_rules): continue
		string_append(out, cstr(f"literal {name} "))
		at_append_pg_string_literal(out, g_literal_text[name])
		string_append_char(out, 10)
	for at_lowered_lexer* lowered in g_at_lowered_lexer:
		at_rule* source = lowered.source
		if (lowered.literal != 0):
			string_append(out, cstr(f"literal {source.name} "))
			at_append_pg_string_literal(out, lowered.literal)
			string_append_char(out, 10)
		else:
			string_append(out, cstr(f"token {source.name} {lowered.matcher}\n"))
		string_append(out, cstr(f"lexer_rule {source.name} {at_pg_mode_name(source.mode)}\n"))
		for ci, command in source.commands:
			if (at_stateful_command_emittable(source, ci) == 0): continue
			string_append(out, cstr(f"lexer_command {source.name} {command.name}"))
			if (command.argument != 0):
				char* argument = command.argument
				if ((strcmp(command.name, c"mode") == 0) || (strcmp(command.name, c"pushMode") == 0)):
					argument = at_pg_mode_name(argument)
				else if (strcmp(command.name, c"channel") == 0):
					if (strcmp(argument, c"HIDDEN") == 0): argument = c"hidden"
					else if (strcmp(argument, c"DEFAULT_TOKEN_CHANNEL") == 0): argument = c"default"
					else if (at_custom_channel(argument)): argument = cstr(f"AT_CHANNEL_{argument}")
				string_append(out, cstr(f" {argument}"))
			string_append_char(out, 10)
	# Legacy parser wildcard/negated-set fallbacks are retained in best-effort
	# mode, after the explicit rules. The semantic audit rejects them strictly.
	for i, name in g_token_names:
		if (name in g_lexer_rules): continue
		string_append(out, cstr(f"token {name} {g_token_matchers[i]}\n"))
	string_append_char(out, 10)


void at_emit(string_builder* out, char* parser_name):
	string_append(out, c"parser ")
	string_append(out, parser_name)
	string_append(out, c"\n\n")
	if (g_at_prediction): string_append(out, c"mode antlr\n\n")
	int i = 0
	if (g_at_stateful):
		at_emit_stateful_lexer(out)
	else:
		# Always-emitted skips use reserved names so source lexer rules named
		# NEWLINE/TAB (common keyword literals, or visible tab tokens) don't
		# collide with the generated `*_token_NEWLINE` / `*_token_TAB` symbols.
		string_append(out, c"# Always present: the pg lexer only auto-skips inline space/CR, not tabs or newlines.\n")
		string_append(out, c"skip PG_SKIP_NEWLINE newline\n")
		string_append(out, c"skip PG_SKIP_TAB tabs\n")
		i = 0
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
		if (g_at_start_rule != 0): string_append(out, g_at_start_rule)
		else: string_append(out, g_parser_rule_names[0])
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

	at_source_emit(out)

	if (g_report_lines.length > 0):
		string_append(out, c"\n# --- translation report (see build log / --report for details) ---\n")
		i = 0
		while (i < g_report_lines.length):
			string_append(out, c"# ")
			string_append(out, g_report_lines[i])
			string_append_char(out, 10)
			i = i + 1
