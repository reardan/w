import libs.extras.grammars.antlr_to_pg.lexer_ir


int at_lex_lower_alts(at_lex_program* p, list[at_alt*] alts, int continuation);


int at_lex_lower_rule(at_lex_program* p, at_rule* rule):
	int existing = p.entries.get(rule.name, -1)
	if (existing >= 0): return existing
	int entry = at_lex_add(p, 3, 0, 0, 0, 0, 0)
	p.entries[rule.name] = entry
	int ret = at_lex_add(p, 5, 0, 0, 0, 0, 0)
	int previous_case = p.case_insensitive
	p.case_insensitive = at_exact_case(rule)
	p.states[entry].next = at_lex_lower_alts(p, rule.alts, ret)
	p.case_insensitive = previous_case
	return entry


int at_lex_lower_ranges(at_lex_program* p, list[int] ranges, int next):
	ranges = at_unicode_normalize(ranges, 0)
	int entry = 0
	if (ranges.length == 0): entry = at_lex_add(p, 1, next, 0, 1, 0, 0)
	else if (ranges.length == 2): entry = at_lex_add(p, 1, next, 0, ranges[0], ranges[1], 0)
	else:
		# Range data is contiguous and sorted. One consuming configuration
		# binary-searches the set instead of spawning a thread per interval.
		int first = p.states.length
		for index in range(0, ranges.length, 2):
			at_lex_add(p, 0, 0, 0, ranges[index], ranges[index + 1], 0)
		entry = at_lex_add(p, 7, next, 0, first, ranges.length / 2, 0)
	ranges.free()
	return entry


int at_lex_lower_charset(at_lex_program* p, at_element* e, int next):
	int saved_suffix = e.suffix
	e.suffix = 0
	list[int] ranges = at_exact_atom_ranges(e, p.case_insensitive, 0)
	e.suffix = saved_suffix
	return at_lex_lower_ranges(p, ranges, next)


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
			list[int] ranges = new list[int]
			at_unicode_add(ranges, codepoint, codepoint, p.case_insensitive)
			next = at_lex_lower_ranges(p, ranges, next)
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
