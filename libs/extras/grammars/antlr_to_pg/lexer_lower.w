import libs.extras.grammars.antlr_to_pg.lexer_ir


int at_lex_lower_alts(at_lex_program* p, list[at_alt*] alts, int continuation);


int at_lex_lower_rule(at_lex_program* p, at_rule* rule):
	int existing = p.entries.get(rule.name, -1)
	if (existing >= 0): return existing
	int entry = at_lex_add(p, 3, 0, 0, 0, 0, 0)
	p.entries[rule.name] = entry
	int ret = at_lex_add(p, 5, 0, 0, 0, 0, 0)
	p.states[entry].next = at_lex_lower_alts(p, rule.alts, ret)
	return entry


# ASCII sets are normalized to disjoint scalar ranges; a negated ASCII set
# includes non-ASCII scalar values, rather than truncating them to bytes.
int at_lex_lower_charset(at_lex_program* p, at_element* e, int next):
	int[128] included
	for i in range(128): included[i] = 0
	char* raw = e.text
	int negated = e.kind == 5
	int index = 1
	if (at_charset_negated(raw)):
		negated = negated == 0
		index = 2
	int end = strlen(raw) - 1
	while (index < end):
		int width = 1
		int low = cast(int, raw[index]) & 255
		if (raw[index] == 92): low = at_parse_charset_escape(raw, index, end, &width)
		index = index + width
		int high = low
		if ((index + 1 < end) && (raw[index] == '-')):
			index++
			width = 1
			high = cast(int, raw[index]) & 255
			if (raw[index] == 92): high = at_parse_charset_escape(raw, index, end, &width)
			index = index + width
		for codepoint in range(low, high + 1): included[codepoint] = 1
	int entry = -1
	if (negated): entry = at_lex_add(p, 1, next, 0, 128, 1114111, 0)
	int codepoint = 127
	while (codepoint >= 0):
		if (included[codepoint] != negated):
			int high = codepoint
			while ((codepoint > 0) && (included[codepoint - 1] != negated)): codepoint--
			int branch = at_lex_add(p, 1, next, 0, codepoint, high, 0)
			if (entry < 0): entry = branch
			else: entry = at_lex_add(p, 2, branch, entry, 0, 0, 0)
		codepoint--
	if (entry < 0): entry = at_lex_add(p, 1, next, 0, 1, 0, 0)
	return entry


int at_lex_lower_atom(at_lex_program* p, at_element* e, int next):
	if (e.kind == 0):
		list[int] points = new list[int]
		int index = 0
		int length = strlen(e.text)
		while (index < length):
			int codepoint = 0
			index = index + utf8_scan(e.text + index, length - index, &codepoint)
			points.push(codepoint)
		while (points.length > 0):
			int codepoint = points.pop()
			next = at_lex_add(p, 1, next, 0, codepoint, codepoint, 0)
		points.free()
		return next
	if ((e.kind == 1) || (e.kind == 5)): return at_lex_lower_charset(p, e, next)
	if (e.kind == 4): return at_lex_add(p, 1, next, 0, 0, 1114111, 0)
	if (e.kind == 3): return at_lex_lower_alts(p, e.group_alts, next)
	if (strcmp(e.text, c"EOF") == 0): return at_lex_add(p, 6, next, 0, 0, 0, 0)
	int target = at_lex_lower_rule(p, g_lexer_rules[e.text])
	return at_lex_add(p, 4, target, next, 0, 0, 0)


int at_lex_lower_element(at_lex_program* p, at_element* e, int next):
	if (e.suffix == 0): return at_lex_lower_atom(p, e, next)
	int split = at_lex_add(p, 2, 0, 0, 0, 0, e.nongreedy)
	int tail = split
	if (e.suffix == '?'): tail = next
	int body = at_lex_lower_atom(p, e, tail)
	if (e.nongreedy):
		p.states[split].next = next
		p.states[split].other = body
	else:
		p.states[split].next = body
		p.states[split].other = next
	if (e.suffix == '+'): return body
	return split


int at_lex_lower_alts(at_lex_program* p, list[at_alt*] alts, int continuation):
	int entry = -1
	int ai = alts.length
	while (ai > 0):
		ai--
		at_alt* alt = alts[ai]
		int branch = continuation
		int ei = alt.elements.length
		while (ei > 0):
			ei--
			branch = at_lex_lower_element(p, alt.elements[ei], branch)
		if (entry < 0): entry = branch
		else: entry = at_lex_add(p, 2, branch, entry, 0, 0, 0)
	return entry
