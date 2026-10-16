# Translator-owned continuation IR. Source rules remain untouched: unlike the
# legacy matcher path, no ASCII approximation or recursive rewrite is applied.
import libs.extras.grammars.antlr_to_pg.types
import libs.extras.grammars.antlr_to_pg.matchers_ascii


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


char* at_exact_reason_alts(list[at_alt*] alts, map[char*, int] visited):
	for at_alt* alt in alts:
		for at_element* e in alt.elements:
			if (e.kind == 0):
				if (utf8_validate_bytes(e.text, strlen(e.text)) == 0): return c"invalid UTF-8 lexer literal"
			else if ((e.kind == 1) || (e.kind == 5)):
				if (e.text == 0): return c"exact matcher needs a normalized charset"
				if (at_charset_has_non_ascii(e.text)): return c"exact Unicode charset lowering is not implemented"
			else if (e.kind == 2):
				if (strcmp(e.text, c"EOF") == 0): continue
				at_rule* target = g_lexer_rules.get(e.text, 0)
				if (target == 0): return c"unknown lexer rule or fragment"
				if ((e.text in g_at_exact_productive) == 0): return c"nonproductive lexer rule or fragment"
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
		if ((rule.name in g_at_exact_productive) == 0): reason = c"nonproductive lexer rule or fragment"
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
