# Bounded parser recursion normalization.
import libs.extras.grammars.antlr_to_pg.normalize_operators
import libs.extras.grammars.antlr_to_pg.normalize_prediction


int at_normalize_expression(at_rule* rule, list[at_rule*] rules);


int at_normalize_parser_lists(list[at_rule*] rules):
	at_audit_prepare_rules(rules)
	int count = 0
	int source_count = rules.length
	int i = 0
	while (i < source_count):
		at_rule* rule = rules[i]
		if (at_normalize_expression(rule, rules)): count = count + 1
		else if (g_at_prediction && at_normalize_prediction_expression(rule, rules)): count = count + 1
		else if (g_at_prediction && at_normalize_prediction_list(rule)): count = count + 1
		else: count = count + at_normalize_parser_list(rule)
		i = i + 1
	return count


int at_expression_self(at_element* e, char* name):
	return (e.kind == 2) && (e.suffix == 0) && (strcmp(e.text, name) == 0)


# -1 unsupported; 0 default/explicit left; 1 explicit right. Only this
# exact alternative-level option is consumed by expression lowering.
int at_expression_associativity(at_alt* alt):
	if ((alt.sites == 0) || (alt.sites.length == 0)): return 0
	if (alt.sites.length != 1): return -1
	at_site* site = alt.sites[0]
	if ((site.position != 0) || (strcmp(site.kind, c"element option") != 0)): return -1
	string_builder* compact = string_new()
	int i = 0
	while (site.raw[i] != 0):
		int c = site.raw[i]
		if ((c != 32) && (c != 9) && (c != 10) && (c != 13)): string_append_char(compact, c)
		i = i + 1
	int result = -1
	if (strcmp(compact.data, c"<assoc=left>") == 0): result = 0
	if (strcmp(compact.data, c"<assoc=right>") == 0): result = 1
	string_free(compact)
	return result


at_element* at_expression_reference(char* name, pg_token* location):
	at_element* ref = new at_element()
	ref.kind = 2
	ref.text = name
	ref.first = location
	return ref


at_rule* at_expression_helper(at_rule* owner, char* suffix):
	char* name = strclone(cstr(f"{owner.name}_{suffix}"))
	while (name in g_at_rules):
		name = strclone(cstr(f"{name}_"))
	at_rule* helper = new at_rule()
	helper.name = name
	helper.precedence_helper = 1
	helper.first = owner.first
	helper.last = owner.last
	helper.mode = c"DEFAULT_MODE"
	helper.commands = new list[at_command*]
	helper.options = new list[at_site*]
	helper.alts = new list[at_alt*]
	g_at_rules[name] = helper
	g_seen_rule_names[name] = 1
	return helper


# Direct owner calls in a copied base must remain delimiter-contained. Calls
# through another parser rule retain that rule's ordinary full-precedence call;
# unlike a direct prefix/binary occurrence, ANTLR does not rewrite their binding.
int at_expression_base_direct(list[at_alt*] alts, char* owner):
	for at_alt* alt in alts:
		int i = 0
		while (i < alt.elements.length):
			at_element* e = alt.elements[i]
			if (at_list_nested_element(alt, i) == 0):
				if ((e.kind == 2) && (strcmp(e.text, owner) == 0)): return 0
				if ((e.kind == 3) && (at_expression_base_direct(e.group_alts, owner) == 0)): return 0
			i = i + 1
	return 1


int at_expression_productive_alts(list[at_alt*] alts, map[char*, int] productive):
	for at_alt* alt in alts:
		int complete = 1
		for at_element* e in alt.elements:
			if ((e.suffix == '?') || (e.suffix == '*')): continue
			if ((e.kind == 3) && (at_expression_productive_alts(e.group_alts, productive) == 0)): complete = 0
			if ((e.kind == 2) && (strcmp(e.text, c"EOF") != 0) && ((e.text in productive) == 0)): complete = 0
		if (complete): return 1
	return 0


int at_expression_productive(char* owner):
	map[char*, int] productive = new map[char*, int]
	int changed = 1
	while (changed):
		changed = 0
		for char* name in g_at_rules:
			if ((name in productive) == 0):
				if (at_expression_productive_alts(g_at_rules[name].alts, productive)):
					productive[name] = 1
					changed = 1
	return owner in productive


# A compound prefix needs an explicit final token boundary. Otherwise an
# optional/variable-spelling last atom can greedily steal the expression operand
# (for example '-' NUMBER? expr on '-1'). Parser aliases may end in a fixed
# token, such as FOREVERY variable ':', without being finite token aliases.
int at_expression_prefix_boundary(at_element* e, int depth):
	if ((depth > 32) || (e.suffix != 0)): return 0
	if (at_expression_operator(e, new map[char*, int])): return 1
	list[at_alt*] alts = 0
	if (e.kind == 3): alts = e.group_alts
	else if ((e.kind == 2) && (e.text in g_at_rules)):
		at_rule* referenced = g_at_rules[e.text]
		if (referenced.is_lexer): return 0
		if ((referenced.options != 0) && (referenced.options.length > 0)): return 0
		alts = referenced.alts
	if ((alts == 0) || (alts.length == 0)): return 0
	if (at_rewrite_plain_alts(alts) == 0): return 0
	for at_alt* alt in alts:
		if (alt.elements.length == 0): return 0
		int last = alt.elements.length - 1
		if (at_expression_prefix_boundary(alt.elements[last], depth + 1) == 0): return 0
	return 1


# Prefix sequences are new ordered-choice consumers, so prove their internal
# continuation boundaries as well as their last token. An optional/repeated
# atom must not take the first token needed by the remaining prefix. Carry the
# caller's continuation through parser aliases to catch hidden trailing loops.
int at_expression_sequence_first(at_alt* alt, map[char*, int] seen);


int at_expression_prefix_parts(list[at_alt*] alts, map[char*, int] following, int depth):
	if (depth > 32): return 0
	map[char*, int] choices = new map[char*, int]
	for at_alt* alt in alts:
		list[at_alt*] singleton = new list[at_alt*]
		singleton.push(alt)
		if (alts.length > 1):
			if (at_audit_alts_nullable(singleton)): return 0
			if (at_expression_sequence_first(alt, choices) == 0): return 0
		int i = 0
		while (i < alt.elements.length):
			at_element* e = alt.elements[i]
			at_alt* rest = new at_alt()
			rest.elements = new list[at_element*]
			int j = i + 1
			while (j < alt.elements.length):
				rest.elements.push(alt.elements[j])
				j = j + 1
			list[at_alt*] remainder = new list[at_alt*]
			remainder.push(rest)
			map[char*, int] next = new map[char*, int]
			if (at_expression_first(remainder, next, new map[char*, int]) == 0): return 0
			if (at_audit_alts_nullable(remainder)):
				for char* token in following: next[token] = 1
			at_element* atom = at_clone_element(e)
			atom.suffix = 0
			at_alt* atom_alt = new at_alt()
			atom_alt.elements = new list[at_element*]
			atom_alt.elements.push(atom)
			list[at_alt*] atom_alts = new list[at_alt*]
			atom_alts.push(atom_alt)
			map[char*, int] first = new map[char*, int]
			if (at_expression_first(atom_alts, first, new map[char*, int]) == 0): return 0
			if ((e.suffix != 0) || at_audit_atom_nullable(e)):
				for char* token in first:
					if (token in next): return 0
			if ((e.suffix == '*') || (e.suffix == '+')):
				for char* token in first: next[token] = 1
			if (e.kind == 3):
				if (at_expression_prefix_parts(e.group_alts, next, depth + 1) == 0): return 0
			else if ((e.kind == 2) && (e.text in g_at_rules)):
				at_rule* referenced = g_at_rules[e.text]
				if (referenced.is_lexer == 0):
					if ((referenced.options != 0) && (referenced.options.length > 0)): return 0
					if (at_rewrite_plain_alts(referenced.alts) == 0): return 0
					if (at_expression_prefix_parts(referenced.alts, next, depth + 1) == 0): return 0
			i = i + 1
	return 1


# Collect the FIRST identities of a consuming prefix/postfix sequence. FIRST
# sets must be disjoint within each position so ordered generated choices cannot
# silently select a shorter operator or a different binding tier.
int at_expression_sequence_first(at_alt* alt, map[char*, int] seen):
	list[at_alt*] singleton = new list[at_alt*]
	singleton.push(alt)
	map[char*, int] first = new map[char*, int]
	if (at_expression_first(singleton, first, new map[char*, int]) == 0): return 0
	if (first.length == 0): return 0
	for char* token in first:
		if (token in seen): return 0
	for char* token in first:
		seen[token] = 1
	return 1


# Restricted ANTLR precedence model: earlier recursive alternatives bind more
# tightly. Binary alternatives call the next tier on their RHS (the same tier
# for right association). Leading postfix alternatives share one repeated
# suffix tier, allowing mixed chains; later/interleaved postfix tiers refuse.
# A prefix operand admits exactly the recursive alternatives preceding that
# prefix in source order. Prefix sequences remain intact in the primary AST.
int at_normalize_expression(at_rule* rule, list[at_rule*] rules):
	if (rule.is_lexer || rule.is_fragment): return 0
	if ((rule.options != 0) && (rule.options.length > 0)): return 0
	list[at_alt*] recursive_alts = new list[at_alt*]
	list[int] binary_kinds = new list[int]
	list[at_alt*] postfix_tails = new list[at_alt*]
	int postfix_prefix_seen = 0
	list[int] associativity = new list[int]
	list[at_alt*] primary_alts = new list[at_alt*]
	list[int] primary_precedence = new list[int]
	map[char*, int] binary_operators = new map[char*, int]
	map[char*, int] prefix_operators = new map[char*, int]
	int binaries = 0
	for at_alt* alt in rule.alts:
		if ((alt.label != 0) || (alt.elements.length == 0)): return 0
		at_alt* plain = new at_alt()
		plain.elements = alt.elements
		list[at_alt*] singleton = new list[at_alt*]
		singleton.push(plain)
		if (at_rewrite_plain_alts(singleton) == 0): return 0
		at_element* first = alt.elements[0]
		int last = alt.elements.length - 1
		if (at_expression_self(first, rule.name)):
			if (alt.elements.length < 2): return 0
			int assoc = at_expression_associativity(alt)
			if (assoc < 0): return 0
			int binary = (alt.elements.length == 3) && at_expression_self(alt.elements[2], rule.name)
			if (binary):
				if (at_expression_operator(alt.elements[1], binary_operators) == 0): return 0
				binaries = binaries + 1
			else:
				# One highest-binding suffix loop permits arbitrary interleaving.
				# Lower postfix tiers would need a precedence-climbing parser.
				if ((binaries > 0) || postfix_prefix_seen): return 0
				at_alt* suffix = new at_alt()
				at_source_copy(suffix, alt)
				suffix.elements = new list[at_element*]
				int si = 1
				while (si < alt.elements.length):
					suffix.elements.push(alt.elements[si])
					si = si + 1
				list[at_alt*] suffixes = new list[at_alt*]
				suffixes.push(suffix)
				if (at_audit_alts_nullable(suffixes)): return 0
				if (at_list_unguarded_reaches(suffixes, rule.name, new map[char*, int])): return 0
				if (at_expression_sequence_first(suffix, binary_operators) == 0): return 0
				postfix_tails.push(suffix)
				if (postfix_tails.length > 1): continue
			recursive_alts.push(alt)
			binary_kinds.push(binary)
			associativity.push(assoc)
			continue
		if ((alt.sites != 0) && (alt.sites.length > 0)): return 0
		if ((alt.elements.length >= 2) && at_expression_self(alt.elements[last], rule.name)):
			at_alt* prefix = new at_alt()
			prefix.elements = at_clone_elements_prefix(alt.elements, last)
			list[at_alt*] prefixes = new list[at_alt*]
			prefixes.push(prefix)
			if (at_audit_alts_nullable(prefixes)): return 0
			if (at_normalize_reaches(prefixes, rule.name, new map[char*, int])): return 0
			if (at_expression_prefix_boundary(alt.elements[last - 1], 0) == 0): return 0
			if (at_expression_prefix_parts(prefixes, new map[char*, int], 0) == 0): return 0
			if (at_expression_sequence_first(prefix, prefix_operators) == 0): return 0
			if ((postfix_tails.length > 0) && (binaries == 0)): postfix_prefix_seen = 1
			primary_alts.push(alt)
			primary_precedence.push(recursive_alts.length)
			continue
		if (at_audit_alts_nullable(singleton)): return 0
		if (at_expression_base_direct(singleton, rule.name) == 0): return 0
		if (at_audit_left_path(singleton, rule.name, new map[char*, int])): return 0
		primary_alts.push(alt)
		primary_precedence.push(-1)
	if ((binaries == 0) || (primary_alts.length == 0)): return 0
	if (at_expression_productive(rule.name) == 0): return 0
	# Every base, including a guarded recursive base, keeps its source AST.
	# A recursive base's FIRST walk stops at its mandatory consuming prefix.
	map[char*, int] base_first = new map[char*, int]
	int bi = 0
	while (bi < primary_alts.length):
		at_alt* alt = primary_alts[bi]
		int kind = primary_precedence[bi]
		bi = bi + 1
		if (kind >= 0): continue
		int compound = (alt.elements.length != 1) || (alt.elements[0].kind == 3) || (alt.elements[0].suffix != 0)
		list[at_alt*] singleton = new list[at_alt*]
		singleton.push(alt)
		if (at_normalize_reaches(singleton, rule.name, new map[char*, int])): compound = 1
		map[char*, int] first = new map[char*, int]
		if (at_expression_first(singleton, first, new map[char*, int]) == 0): return 0
		for char* token in first:
			if (token in prefix_operators): return 0
			if ((token in base_first) && (compound || (base_first[token] == 2))): return 0
			base_first[token] = 1 + compound
	# Validation above is atomic: only now allocate and publish helper rules.
	at_rule* primary = at_expression_helper(rule, c"primary")
	list[at_rule*] tiers = new list[at_rule*]
	int i = 0
	while (i < recursive_alts.length):
		tiers.push(at_expression_helper(rule, cstr(f"prec{i}")))
		i = i + 1
	int pi = 0
	for at_alt* alt in primary_alts:
		at_alt* copy = new at_alt()
		at_source_copy(copy, alt)
		copy.elements = at_clone_elements_prefix(alt.elements, alt.elements.length)
		int precedence = primary_precedence[pi]
		if (precedence >= 0):
			char* operand = primary.name
			if (precedence > 0): operand = tiers[precedence - 1].name
			int copy_last = copy.elements.length - 1
			copy.elements[copy_last] = at_expression_reference(operand, rule.first)
		primary.alts.push(copy)
		pi = pi + 1
	rules.push(primary)
	at_rule* higher = primary
	i = 0
	while (i < recursive_alts.length):
		at_rule* tier = tiers[i]
		at_alt* source = recursive_alts[i]
		at_alt* tail = new at_alt()
		at_source_copy(tail, source)
		tail.elements = new list[at_element*]
		int end = source.elements.length
		if (binary_kinds[i]): end = end - 1
		int si = 1
		while (si < end):
			tail.elements.push(at_clone_element(source.elements[si]))
			si = si + 1
		if (binary_kinds[i]):
			char* rhs = higher.name
			if (associativity[i]): rhs = tier.name
			tail.elements.push(at_expression_reference(rhs, rule.first))
		at_element* loop = new at_element()
		loop.kind = 3
		loop.suffix = '*'
		if (binary_kinds[i] && associativity[i]): loop.suffix = '?'
		loop.group_alts = new list[at_alt*]
		if (binary_kinds[i]): loop.group_alts.push(tail)
		else:
			for at_alt* suffix in postfix_tails:
				at_alt* copy = new at_alt()
				at_source_copy(copy, suffix)
				copy.elements = at_clone_elements_prefix(suffix.elements, suffix.elements.length)
				loop.group_alts.push(copy)
		loop.first = rule.first
		at_alt* body = new at_alt()
		body.elements = new list[at_element*]
		body.elements.push(at_expression_reference(higher.name, rule.first))
		body.elements.push(loop)
		tier.alts.push(body)
		rules.push(tier)
		higher = tier
		i = i + 1
	at_alt* entry = new at_alt()
	entry.elements = new list[at_element*]
	entry.elements.push(at_expression_reference(higher.name, rule.first))
	rule.alts = new list[at_alt*]
	rule.alts.push(entry)
	return 1
