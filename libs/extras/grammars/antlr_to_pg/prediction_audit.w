# Conservative parser-decision audit, separate from byte-level lexer analysis.
# FIRST/FOLLOW overlap is an unproven continuation, not a claimed counterexample.
import libs.extras.grammars.antlr_to_pg.normalize_operators
import libs.extras.grammars.antlr_to_pg.prediction_absorption


struct at_prediction_facts:
	map[char*, int] first
	map[char*, int] follow
	int nullable


map[char*, at_prediction_facts*] g_at_prediction_facts


int at_prediction_union(map[char*, int] target, map[char*, int] source):
	int changed = 0
	for char* token in source:
		if ((token in target) == 0):
			target[token] = 1
			changed = 1
	return changed


int at_prediction_overlap(map[char*, int] left, map[char*, int] right):
	if ((left.length == 0) || (right.length == 0)): return 0
	if ((c"*" in left) || (c"*" in right)): return 1
	for char* token in left:
		if (token in right): return 1
	return 0


int at_prediction_alts_nullable(list[at_alt*] alts);


int at_prediction_atom_nullable(at_element* element):
	if (element.kind == 3): return at_prediction_alts_nullable(element.group_alts)
	if (element.kind == 0): return strlen(element.text) == 0
	if ((element.kind == 2) && (element.text in g_at_prediction_facts)):
		return g_at_prediction_facts[element.text].nullable
	# A lexer rule's byte-nullability never makes its token nullable here.
	return 0


int at_prediction_alt_nullable(at_alt* alt):
	for at_element* element in alt.elements:
		if ((element.suffix == '?') || (element.suffix == '*')): continue
		if (at_prediction_atom_nullable(element) == 0): return 0
	return 1


int at_prediction_alts_nullable(list[at_alt*] alts):
	for at_alt* alt in alts:
		if (at_prediction_alt_nullable(alt)): return 1
	return 0


map[char*, int] at_prediction_first_alts(list[at_alt*] alts);


map[char*, int] at_prediction_first_atom(at_element* element):
	map[char*, int] first = new map[char*, int]
	if (element.kind == 3): return at_prediction_first_alts(element.group_alts)
	if (element.kind == 0):
		if (strlen(element.text) > 0): first[cstr(f"literal {element.text}")] = 1
	else if (element.kind == 2):
		if (element.text in g_at_prediction_facts): return g_at_prediction_facts[element.text].first
		at_element* atom = at_clone_element(element)
		atom.suffix = 0
		char* spelling = at_expression_spelling(atom)
		if (spelling != 0): first[cstr(f"literal {spelling}")] = 1
		else: first[cstr(f"token {element.text}")] = 1
	else: first[c"*"] = 1
	return first


map[char*, int] at_prediction_first_alt(at_alt* alt):
	map[char*, int] first = new map[char*, int]
	for at_element* element in alt.elements:
		at_prediction_union(first, at_prediction_first_atom(element))
		if ((element.suffix == '?') || (element.suffix == '*')): continue
		if (at_prediction_atom_nullable(element) == 0): break
	return first


map[char*, int] at_prediction_first_alts(list[at_alt*] alts):
	map[char*, int] first = new map[char*, int]
	for at_alt* alt in alts: at_prediction_union(first, at_prediction_first_alt(alt))
	return first


int at_prediction_follow(list[at_alt*] alts, map[char*, int] following):
	int changed = 0
	for at_alt* alt in alts:
		map[char*, int] next = new map[char*, int]
		at_prediction_union(next, following)
		int i = alt.elements.length - 1
		while (i >= 0):
			at_element* element = alt.elements[i]
			map[char*, int] first = at_prediction_first_atom(element)
			map[char*, int] inside = new map[char*, int]
			at_prediction_union(inside, next)
			if ((element.suffix == '*') || (element.suffix == '+')): at_prediction_union(inside, first)
			if (element.kind == 3):
				if (at_prediction_follow(element.group_alts, inside)): changed = 1
			else if ((element.kind == 2) && (element.text in g_at_prediction_facts)):
				if (at_prediction_union(g_at_prediction_facts[element.text].follow, inside)): changed = 1
			map[char*, int] before = new map[char*, int]
			at_prediction_union(before, first)
			if ((element.suffix == '?') || (element.suffix == '*') || at_prediction_atom_nullable(element)):
				at_prediction_union(before, next)
			next = before
			i--
	return changed


void at_prediction_find_risks(at_rule* owner, list[at_alt*] alts, map[char*, int] following, list[at_element*] outer):
	for i, alt in alts:
		map[char*, int] first = at_prediction_first_alt(alt)
		for j in range(i + 1, alts.length):
			int overlap = at_prediction_overlap(first, at_prediction_first_alt(alts[j]))
			if (at_prediction_alt_nullable(alt)): overlap = 1
			if (at_prediction_alt_nullable(alts[j]) && at_prediction_overlap(first, following)): overlap = 1
			if (overlap && (at_prediction_prefix_disjoint(alt, alts[j]) == 0) && (at_prediction_common_terminator(alt, alts[j]) == 0)):
				at_loss_code(owner.first, owner.name, c"AT_PARSER_CONTINUATION", c"parser_prediction", c"unproven", cstr(f"unproven parser continuation: alternatives {i + 1} and {j + 1} overlap or precede a nullable fallback; use --prediction or a reviewed adaptation"))
		map[char*, int] next = new map[char*, int]
		at_prediction_union(next, following)
		int e = alt.elements.length - 1
		while (e >= 0):
			at_element* element = alt.elements[e]
			map[char*, int] atom_first = at_prediction_first_atom(element)
			int optional_eof = (element.kind == 2) && (strcmp(element.text, c"EOF") == 0) && (element.suffix == '?')
			list[at_element*] tail = at_abs_tail(alt, e, outer, 1)
			if ((element.suffix != 0) && (optional_eof == 0) && (owner.precedence_helper == 0) && at_prediction_overlap(atom_first, next) && (at_prediction_absorption(owner, element, tail) == 0)):
				at_loss_code(element.first, owner.name, c"AT_PARSER_CONTINUATION", c"parser_prediction", c"unproven", cstr(f"unproven parser continuation: greedy term {e + 1} overlaps its caller/following input; use --prediction or a reviewed adaptation"))
			map[char*, int] inside = new map[char*, int]
			at_prediction_union(inside, next)
			if ((element.suffix == '*') || (element.suffix == '+')): at_prediction_union(inside, atom_first)
			if (element.kind == 3): at_prediction_find_risks(owner, element.group_alts, inside, tail)
			at_abs_free_tail(tail, element, 1)
			map[char*, int] before = new map[char*, int]
			at_prediction_union(before, atom_first)
			if ((element.suffix == '?') || (element.suffix == '*') || at_prediction_atom_nullable(element)):
				at_prediction_union(before, next)
			next = before
			e--


void at_audit_prediction(list[at_rule*] rules):
	if (g_at_prediction): return
	g_at_prediction_facts = new map[char*, at_prediction_facts*]
	for at_rule* rule in rules:
		if (rule.is_lexer): continue
		at_prediction_facts* facts = new at_prediction_facts()
		facts.first = new map[char*, int]
		facts.follow = new map[char*, int]
		facts.nullable = 0
		g_at_prediction_facts[rule.name] = facts
	int changed = 1
	while (changed):
		changed = 0
		for at_rule* rule in rules:
			if (rule.is_lexer): continue
			at_prediction_facts* facts = g_at_prediction_facts[rule.name]
			if ((facts.nullable == 0) && at_prediction_alts_nullable(rule.alts)):
				facts.nullable = 1
				changed = 1
			if (at_prediction_union(facts.first, at_prediction_first_alts(rule.alts))): changed = 1
	for at_rule* rule in rules:
		if (rule.is_lexer == 0):
			g_at_prediction_facts[rule.name].follow[c"token EOF"] = 1
			break
	changed = 1
	while (changed):
		changed = 0
		for at_rule* rule in rules:
			if (rule.is_lexer): continue
			if (at_prediction_follow(rule.alts, g_at_prediction_facts[rule.name].follow)): changed = 1
	for at_rule* rule in rules:
		if (rule.is_lexer == 0): at_prediction_find_risks(rule, rule.alts, g_at_prediction_facts[rule.name].follow, new list[at_element*])
