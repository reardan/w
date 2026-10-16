# Source identity survives generated helper rules without claiming ANTLR's
# generated context-class API. Labels describe normalized nodes and folds.
import lib.utf8
import libs.extras.grammars.antlr_to_pg.types


void at_source_append_string(string_builder* out, char* text):
	string_append_char(out, 34)
	for i in range(strlen(text)):
		int c = text[i]
		if ((c == 34) || (c == 92)): string_append_char(out, 92)
		if (c == 10): string_append(out, c"\\n")
		else if (c == 13): string_append(out, c"\\r")
		else if (c == 9): string_append(out, c"\\t")
		else: string_append_char(out, c)
	string_append_char(out, 34)


char* at_source_label_key(char* prefix, char* raw):
	string_builder* text = string_new()
	string_append(text, prefix)
	for i in range(strlen(raw)):
		int c = raw[i]
		if ((c != 32) && (c != 9) && (c != 10) && (c != 13)): string_append_char(text, c)
	return text.data


void at_source_prepare_alts(char* owner, pg_token* fallback, list[at_alt*] alts):
	for i, alt in alts:
		alt.source_rule = owner
		alt.source_alternative = i + 1
		alt.source_first = fallback
		if (alt.elements.length > 0): alt.source_first = alt.elements[0].first
		for at_element* element in alt.elements:
			if (element.kind == 3): at_source_prepare_alts(owner, element.first, element.group_alts)


void at_source_prepare(list[at_rule*] rules):
	g_at_source_alts = new map[char*, list[at_alt*]]
	if (g_at_prediction == 0): return
	for at_rule* rule in rules:
		if (rule.is_lexer == 0): at_source_prepare_alts(rule.name, rule.first, rule.alts)


void at_source_copy(at_alt* target, at_alt* source):
	target.source_rule = source.source_rule
	target.source_alternative = source.source_alternative
	target.source_first = source.source_first
	target.label = source.label
	target.source_lhs_label = source.source_lhs_label


void at_source_emit_value(string_builder* out, char* rule, int alternative, int term, char* key, int value):
	char* directive = c"node_meta"
	if (term > 0): directive = c"term_meta"
	string_append(out, cstr(f"{directive} {rule} \"{alternative}\" "))
	if (term > 0): string_append(out, cstr(f"\"{term}\" "))
	at_source_append_string(out, key)
	string_append(out, cstr(f" \"{value}\"\n"))


void at_source_emit(string_builder* out):
	if (g_at_prediction == 0): return
	for char* rule in g_parser_rule_names:
		list[at_alt*] alts = g_at_source_alts[rule]
		list[list[at_term*]] terms = g_rule_alts[rule]
		for a, alt in alts:
			if (alt.source_rule != 0):
				at_source_emit_value(out, rule, a + 1, 0, cstr(f"antlr_rule:{alt.source_rule}"), alt.source_alternative)
				if (alt.source_first != 0):
					at_source_emit_value(out, rule, a + 1, 0, c"antlr_source_line", alt.source_first.line)
					at_source_emit_value(out, rule, a + 1, 0, c"antlr_source_column", alt.source_first.column)
			if (alt.label != 0): at_source_emit_value(out, rule, a + 1, 0, cstr(f"antlr_alt:{alt.label}"), alt.source_alternative)
			if (alt.source_lhs_label != 0):
				at_source_emit_value(out, rule, a + 1, 0, at_source_label_key(c"antlr_lhs_label:", alt.source_lhs_label), 1)
			for t, term in terms[a]:
				if (term.label != 0):
					at_source_emit_value(out, rule, a + 1, t + 1, at_source_label_key(c"antlr_label:", term.label), 1)
