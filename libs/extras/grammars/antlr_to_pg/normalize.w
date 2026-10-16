# Bounded parser recursion normalization.
import libs.extras.grammars.antlr_to_pg.normalize_lists


int at_normalize_expression(at_rule* rule, list[at_rule*] rules);


int at_normalize_parser_lists(list[at_rule*] rules):
	at_audit_prepare_rules(rules)
	int count = 0
	int source_count = rules.length
	int i = 0
	while (i < source_count):
		at_rule* rule = rules[i]
		if (at_normalize_expression(rule, rules)): count = count + 1
		else: count = count + at_normalize_parser_list(rule)
		i = i + 1
	return count


int at_expression_self(at_element* e, char* name):
	return (e.kind == 2) && (e.suffix == 0) && (strcmp(e.text, name) == 0)


# Operators and delimiters may name a lexer token with one fixed spelling.
# Resolve only plain literal tokens: aliases, commands and variable-width
# patterns require token-identity analysis beyond this expression slice.
char* at_expression_spelling(at_element* e):
	if (e.suffix != 0): return 0
	if (e.kind == 0): return e.text
	if ((e.kind != 2) || ((e.text in g_at_rules) == 0)): return 0
	at_rule* token = g_at_rules[e.text]
	if ((token.is_lexer == 0) || token.is_fragment): return 0
	if ((token.mode != 0) && (strcmp(token.mode, c"DEFAULT_MODE") != 0)): return 0
	if ((token.commands != 0) && (token.commands.length > 0)): return 0
	if ((token.options != 0) && (token.options.length > 0)): return 0
	if ((token.alts.length != 1) || (token.alts[0].elements.length != 1)): return 0
	if (at_rewrite_plain_alts(token.alts) == 0): return 0
	at_element* literal = token.alts[0].elements[0]
	if ((literal.kind != 0) || (literal.suffix != 0)): return 0
	return literal.text


# Spellings must be unique across binary precedence alternatives, including
# aliases expressed once as a literal and once as a named lexer token.
int at_expression_operator(at_element* e, map[char*, int] spellings):
	if (e.suffix != 0): return 0
	char* spelling = at_expression_spelling(e)
	if (spelling != 0):
		if ((strlen(spelling) == 0) || (spelling in spellings)): return 0
		spellings[spelling] = 1
		return 1
	if (e.kind != 3): return 0
	if (e.group_alts.length == 0): return 0
	for at_alt* alt in e.group_alts:
		if (alt.elements.length != 1): return 0
		if (at_expression_operator(alt.elements[0], spellings) == 0): return 0
	return 1


# Collect possible first token identities through nullable prefixes. Named
# variable-spelling lexer tokens have their own identity; fixed literal tokens
# share the spelling key used by implicit literals and prefix operators.
int at_expression_first(list[at_alt*] alts, map[char*, int] first, map[char*, int] visited):
	for at_alt* alt in alts:
		for at_element* e in alt.elements:
			at_element* atom = at_clone_element(e)
			atom.suffix = 0
			char* spelling = at_expression_spelling(atom)
			if (spelling != 0):
				if (strlen(spelling) > 0): first[spelling] = 1
			else if (e.kind == 3):
				if (at_expression_first(e.group_alts, first, visited) == 0): return 0
			else if (e.kind == 2):
				if ((e.text in g_at_rules) == 0): return 0
				at_rule* referenced = g_at_rules[e.text]
				if (referenced.is_lexer):
					first[strclone(cstr(f"token {e.text}"))] = 1
				else if ((e.text in visited) == 0):
					visited[e.text] = 1
					if (at_expression_first(referenced.alts, first, visited) == 0): return 0
			else: return 0
			if (at_audit_element_nullable(e) == 0): break
	return 1


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
	helper.first = owner.first
	helper.last = owner.last
	helper.mode = c"DEFAULT_MODE"
	helper.commands = new list[at_command*]
	helper.options = new list[at_site*]
	helper.alts = new list[at_alt*]
	g_at_rules[name] = helper
	g_seen_rule_names[name] = 1
	return helper


# Restricted ANTLR precedence model: earlier binary alternatives bind more
# tightly; left association calls the next tighter tier, right association
# calls the same tier. A prefix operand admits the binary alternatives
# preceding that prefix in source order, preserving its own binding power.
# See LeftRecursiveRuleAnalyzer.precedence/nextPrecedence (ANTLR 4.13.2).
int at_normalize_expression(at_rule* rule, list[at_rule*] rules):
	if (rule.is_lexer || rule.is_fragment): return 0
	if ((rule.options != 0) && (rule.options.length > 0)): return 0
	list[at_alt*] binaries = new list[at_alt*]
	list[int] associativity = new list[int]
	list[at_alt*] primary_alts = new list[at_alt*]
	list[int] primary_precedence = new list[int]
	map[char*, int] binary_operators = new map[char*, int]
	map[char*, int] prefix_operators = new map[char*, int]
	int bases = 0
	for at_alt* alt in rule.alts:
		if ((alt.label != 0) || (alt.elements.length == 0)): return 0
		# Check element annotations without discarding a recognized assoc site.
		at_alt* plain = new at_alt()
		plain.elements = alt.elements
		list[at_alt*] singleton = new list[at_alt*]
		singleton.push(plain)
		if (at_rewrite_plain_alts(singleton) == 0): return 0
		at_element* first = alt.elements[0]
		int binary = at_expression_self(first, rule.name)
		if (binary):
			if (alt.elements.length != 3): return 0
			if (at_expression_self(alt.elements[2], rule.name) == 0): return 0
			if (at_expression_operator(alt.elements[1], binary_operators) == 0): return 0
			int assoc = at_expression_associativity(alt)
			if (assoc < 0): return 0
			binaries.push(alt)
			associativity.push(assoc)
			continue
		if ((alt.sites != 0) && (alt.sites.length > 0)): return 0
		if ((alt.elements.length == 2) && at_expression_self(alt.elements[1], rule.name)):
			if (at_expression_operator(first, prefix_operators) == 0): return 0
			primary_alts.push(alt)
			primary_precedence.push(binaries.length)
			continue
		int primary_kind = -1
		if ((alt.elements.length == 3) && at_expression_self(alt.elements[1], rule.name)):
			char* open = at_expression_spelling(first)
			char* close = at_expression_spelling(alt.elements[2])
			if ((open == 0) || (close == 0)): return 0
			if ((strcmp(open, c"(") != 0) || (strcmp(close, c")") != 0)): return 0
			primary_kind = -2
		else:
			# Compound bases must consume and may not hide an expression
			# reference in a group or referenced rule. Preserve every element,
			# including optional/repeated prefixes such as ('+' | '-')* atom.
			if (at_audit_alts_nullable(singleton)): return 0
			if (at_normalize_reaches(singleton, rule.name, new map[char*, int])): return 0
			bases = bases + 1
		primary_alts.push(alt)
		primary_precedence.push(primary_kind)
	if ((binaries.length == 0) || (bases == 0)): return 0
	# New compound bases must not be shadowed by an earlier successful
	# prefix/group/base alternative in the generated ordered-choice parser.
	map[char*, int] base_first = new map[char*, int]
	int bi = 0
	while (bi < primary_alts.length):
		at_alt* alt = primary_alts[bi]
		int kind = primary_precedence[bi]
		bi = bi + 1
		if (kind != -1): continue
		int compound = (alt.elements.length != 1) || (alt.elements[0].kind == 3) || (alt.elements[0].suffix != 0)
		list[at_alt*] singleton = new list[at_alt*]
		singleton.push(alt)
		map[char*, int] first = new map[char*, int]
		if (at_expression_first(singleton, first, new map[char*, int]) == 0): return 0
		for char* token in first:
			if ((token in prefix_operators) || (strcmp(token, c"(") == 0) || (strcmp(token, c")") == 0)): return 0
			if ((token in base_first) && (compound || (base_first[token] == 2))): return 0
			base_first[token] = 1 + compound
	# Validation above is atomic: only now allocate and publish helper rules.
	at_rule* primary = at_expression_helper(rule, c"primary")
	list[at_rule*] tiers = new list[at_rule*]
	int i = 0
	while (i < binaries.length):
		tiers.push(at_expression_helper(rule, cstr(f"prec{i}")))
		i = i + 1
	int pi = 0
	for at_alt* alt in primary_alts:
		at_alt* copy = new at_alt()
		copy.elements = at_clone_elements_prefix(alt.elements, alt.elements.length)
		int precedence = primary_precedence[pi]
		if (precedence >= 0):
			char* operand = primary.name
			if (precedence > 0): operand = tiers[precedence - 1].name
			copy.elements[1] = at_expression_reference(operand, rule.first)
		primary.alts.push(copy)
		pi = pi + 1
	rules.push(primary)
	at_rule* higher = primary
	i = 0
	while (i < binaries.length):
		at_rule* tier = tiers[i]
		at_alt* tail = new at_alt()
		tail.elements = new list[at_element*]
		tail.elements.push(at_clone_element(binaries[i].elements[1]))
		char* rhs = higher.name
		if (associativity[i]): rhs = tier.name
		tail.elements.push(at_expression_reference(rhs, rule.first))
		at_element* loop = new at_element()
		loop.kind = 3
		loop.suffix = '*'
		if (associativity[i]): loop.suffix = '?'
		loop.group_alts = new list[at_alt*]
		loop.group_alts.push(tail)
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
