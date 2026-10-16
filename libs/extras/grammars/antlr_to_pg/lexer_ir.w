# Translator-owned continuation IR. Source rules remain untouched: unlike the
# legacy matcher path, no ASCII approximation or recursive rewrite is applied.
import libs.extras.grammars.antlr_to_pg.types
import lib.utf8
import libs.extras.grammars.antlr_to_pg.matchers_ascii
import libs.extras.grammars.antlr_to_pg.lexer_unicode
import libs.extras.grammars.antlr_to_pg.lexer_options


struct at_lex_state:
	int op
	int next
	int other
	int low
	int high
	int nongreedy


struct at_lex_program:
	list[at_lex_state*] states
	map[char*, int] entries
	int case_insensitive


map[char*, char*] g_at_exact_reasons
map[char*, int] g_at_exact_productive


int at_exact_productive_alts(list[at_alt*] alts):
	for at_alt* alt in alts:
		int productive = 1
		for at_element* e in alt.elements:
			if ((e.suffix == '*') || (e.suffix == '?')): continue
			if ((e.kind == 2) && (strcmp(e.text, c"EOF") != 0)):
				if ((e.text in g_at_exact_productive) == 0): productive = 0
			else if (e.kind == 3):
				if (at_exact_productive_alts(e.group_alts) == 0): productive = 0
		if (productive): return 1
	return 0


list[int] at_exact_atom_ranges(at_element* e, int case_insensitive, int depth);


list[int] at_exact_alt_ranges(list[at_alt*] alts, int case_insensitive, int depth):
	list[int] union = new list[int]
	for at_alt* alt in alts:
		if (alt.elements.length != 1):
			union.free()
			return 0
		list[int] ranges = at_exact_atom_ranges(alt.elements[0], case_insensitive, depth + 1)
		if (ranges == 0):
			union.free()
			return 0
		for int value in ranges: union.push(value)
		ranges.free()
	return at_unicode_normalize(union, 0)


list[int] at_exact_atom_ranges(at_element* e, int case_insensitive, int depth):
	if ((depth > 64) || (e.suffix != 0)): return 0
	if ((e.kind == 1) || ((e.kind == 5) && (e.text != 0))):
		return at_unicode_charset(e.text, e.kind == 5, case_insensitive)
	if (e.kind == 0):
		int codepoint = 0
		int length = strlen(e.text)
		if ((length == 0) || (utf8_scan(e.text, length, &codepoint) != length)): return 0
		list[int] ranges = new list[int]
		at_unicode_add(ranges, codepoint, codepoint, case_insensitive)
		return ranges
	if ((e.kind == 3) || ((e.kind == 5) && (e.group_alts != 0))):
		list[int] ranges = at_exact_alt_ranges(e.group_alts, case_insensitive, depth + 1)
		if (ranges == 0): return 0
		return at_unicode_normalize(ranges, e.kind == 5)
	if (e.kind == 2):
		at_rule* rule = g_lexer_rules.get(e.text, 0)
		if (rule != 0): return at_exact_alt_ranges(rule.alts, at_exact_case(rule), depth + 1)
	return 0


char* at_exact_reason_alts(list[at_alt*] alts, map[char*, int] visited):
	for at_alt* alt in alts:
		for at_element* e in alt.elements:
			if (e.kind == 0):
				if (utf8_validate_bytes(e.text, strlen(e.text)) == 0): return c"invalid UTF-8 lexer literal"
				if ((e.first != 0) && (e.first.text[0] == 39)):
					char* decoded = at_unicode_literal(e.first.text)
					if (decoded == 0): return c"invalid or unrepresentable lexer literal escape"
					free(decoded)
			else if ((e.kind == 1) || (e.kind == 5)):
				int saved_suffix = e.suffix
				e.suffix = 0
				list[int] ranges = at_exact_atom_ranges(e, 0, 0)
				e.suffix = saved_suffix
				if (ranges == 0): return c"invalid Unicode charset, range, or property"
				ranges.free()
			else if (e.kind == 2):
				if (strcmp(e.text, c"EOF") == 0): continue
				at_rule* target = g_lexer_rules.get(e.text, 0)
				if (target == 0): return c"unknown lexer rule or fragment"
				if ((target.is_fragment == 0) && ((e.text in g_at_exact_productive) == 0)): return c"nonproductive lexer rule or fragment"
				if ((e.text in visited) == 0):
					visited[e.text] = 1
					char* reason = at_exact_reason_alts(target.alts, visited)
					if (reason != 0): return reason
			else if (e.kind == 3):
				char* reason = at_exact_reason_alts(e.group_alts, visited)
				if (reason != 0): return reason
			else if (e.kind != 4): return c"unsupported exact lexer atom"
	return 0


void at_exact_prepare(list[at_rule*] rules):
	at_exact_prepare_cases(rules)
	g_at_exact_reasons = new map[char*, char*]
	g_at_exact_productive = new map[char*, int]
	int changed = 1
	while (changed):
		changed = 0
		for at_rule* rule in rules:
			if (rule.is_lexer && ((rule.name in g_at_exact_productive) == 0)):
				if (at_exact_productive_alts(rule.alts)):
					g_at_exact_productive[rule.name] = 1
					changed = 1
	for at_rule* rule in rules:
		if (rule.is_lexer == 0): continue
		char* reason = 0
		if ((rule.is_fragment == 0) && ((rule.name in g_at_exact_productive) == 0)): reason = c"nonproductive lexer rule or fragment"
		else:
			map[char*, int] visited = new map[char*, int]
			visited[rule.name] = 1
			reason = at_exact_reason_alts(rule.alts, visited)
			visited.free()
		g_at_exact_reasons[rule.name] = reason


int at_exact_supported(at_rule* rule):
	if ((g_at_exact_lexer == 0) || (rule.is_lexer == 0)): return 0
	return g_at_exact_reasons.get(rule.name, c"unprepared exact lexer rule") == 0


int at_lex_add(at_lex_program* p, int op, int next, int other, int low, int high, int nongreedy):
	at_lex_state* state = new at_lex_state()
	state.op = op
	state.next = next
	state.other = other
	state.low = low
	state.high = high
	state.nongreedy = nongreedy
	int index = p.states.length
	p.states.push(state)
	return index


void at_lex_program_free(at_lex_program* p):
	for at_lex_state* state in p.states: free(state)
	p.states.free()
	p.entries.free()
	free(p)


int at_exact_unicode_atom(at_rule* rule, at_element* element):
	if (at_exact_supported(rule)): return 1
	if (g_at_exact_lexer && (element.kind == 0) && (element.first != 0)):
		char* decoded = at_unicode_literal(element.first.text)
		if (decoded != 0):
			free(decoded)
			return 1
	return 0


void at_exact_audit_case_literals(at_rule* rule, list[at_alt*] alts):
	for at_alt* alt in alts:
		for at_element* element in alt.elements:
			if (element.kind == 0):
				int declared = 0
				for at_rule* candidate in g_at_source_rules:
					if (candidate.is_lexer && (candidate.is_fragment == 0) && (candidate.alts.length == 1)):
						at_alt* body = candidate.alts[0]
						if ((body.elements.length == 1) && (body.elements[0].kind == 0) && (body.elements[0].suffix == 0)):
							if (strcmp(body.elements[0].text, element.text) == 0): declared = 1
				if (declared == 0): at_loss_code(element.first, rule.name, c"AT_CASE_LITERAL", c"case_insensitive", c"unsupported", c"case-insensitive parser literals require explicit lexer token rules")
			if (element.group_alts != 0): at_exact_audit_case_literals(rule, element.group_alts)


void at_exact_audit_rule(at_rule* rule):
	if (g_at_exact_lexer == 0): return
	if (rule.is_lexer):
		char* reason = g_at_exact_reasons.get(rule.name, c"unprepared exact lexer rule")
		if (reason != 0):
			char* code = c"AT_EXACT_LEXER_UNSUPPORTED"
			if ((rule.name in g_at_exact_productive) == 0): code = c"AT_NONPRODUCTIVE_LEXER"
			at_loss_code(rule.first, rule.name, code, c"lexer_matcher", c"unsupported", reason)
	else if (at_exact_case(rule)):
		# Implicit literal tokens are still emitted by the PG literal path.
		# Until synthesized as case-aware lexer rules, refuse this shape.
		at_exact_audit_case_literals(rule, rule.alts)
