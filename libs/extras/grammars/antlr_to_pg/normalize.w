# Bounded source normalization for lists and a restricted expression slice.
# Labels, host actions/predicates and indirect recursion remain unsupported.
import libs.extras.grammars.antlr_to_pg.audit
import libs.extras.grammars.antlr_to_pg.matchers_analyze


# Any occurrence, not merely a nullable-prefix occurrence: expression
# operands may hide recursion behind a rule/group and must not be flattened.
int at_normalize_reaches(list[at_alt*] alts, char* target, map[char*, int] visited):
	for at_alt* alt in alts:
		for at_element* e in alt.elements:
			if (e.kind == 3):
				if (at_normalize_reaches(e.group_alts, target, visited)): return 1
			else if (e.kind == 2):
				if (strcmp(e.text, target) == 0): return 1
				if (strcmp(e.text, c"EOF") == 0): continue
				if ((e.text in g_at_rules) == 0): return 1
				if ((e.text in visited) == 0):
					visited[e.text] = 1
					if (at_normalize_reaches(g_at_rules[e.text].alts, target, visited)): return 1
	return 0


# A: A suffix | base -> A: base (suffix)*. Every alternative may occur
# only in one of those two forms. Consuming bases/suffixes, no transitive
# reference back to A, and no semantic annotations are mandatory.
#
# AST contract: preserve A as the owning source-rule node. Its children
# contain the chosen base followed by one generated suffix-group node per
# iteration, in source order. Multiple bases use a generated base-group.
# This is a normalized W AST, not an ANTLR left-nested parse tree.
int at_normalize_parser_list(at_rule* rule):
	if (rule.is_lexer || rule.is_fragment): return 0
	if ((rule.options != 0) && (rule.options.length > 0)): return 0
	if (at_rewrite_plain_alts(rule.alts) == 0): return 0
	list[at_alt*] bases = new list[at_alt*]
	list[at_alt*] tails = new list[at_alt*]
	for at_alt* alt in rule.alts:
		if (alt.elements.length == 0): return 0
		at_element* first = alt.elements[0]
		int recursive = (first.kind == 2) && (strcmp(first.text, rule.name) == 0)
		at_alt* part = alt
		if (recursive):
			if ((first.suffix != 0) || (alt.elements.length < 2)): return 0
			part = new at_alt()
			part.elements = new list[at_element*]
			int i = 1
			while (i < alt.elements.length):
				part.elements.push(at_clone_element(alt.elements[i]))
				i = i + 1
		list[at_alt*] singleton = new list[at_alt*]
		singleton.push(part)
		if (at_audit_alts_nullable(singleton)): return 0
		if (at_normalize_reaches(singleton, rule.name, new map[char*, int])): return 0
		if (recursive): tails.push(part)
		else: bases.push(part)
	if ((bases.length == 0) || (tails.length == 0)): return 0
	at_alt* normalized = new at_alt()
	normalized.elements = new list[at_element*]
	if (bases.length == 1):
		for at_element* e in bases[0].elements:
			normalized.elements.push(at_clone_element(e))
	else:
		at_element* base_group = new at_element()
		base_group.kind = 3
		base_group.group_alts = bases
		base_group.first = rule.first
		normalized.elements.push(base_group)
	at_element* tail_group = new at_element()
	tail_group.kind = 3
	tail_group.suffix = '*'
	tail_group.group_alts = tails
	tail_group.first = rule.first
	normalized.elements.push(tail_group)
	rule.alts = new list[at_alt*]
	rule.alts.push(normalized)
	return 1


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


# Only literal operators and groups of literal operators are admitted.
# Their spellings must be unique across binary precedence alternatives.
int at_expression_operator(at_element* e, map[char*, int] spellings):
	if (e.suffix != 0): return 0
	if (e.kind == 0):
		if ((strlen(e.text) == 0) || (e.text in spellings)): return 0
		spellings[e.text] = 1
		return 1
	if (e.kind != 3): return 0
	if (e.group_alts.length == 0): return 0
	for at_alt* alt in e.group_alts:
		if (alt.elements.length != 1): return 0
		if (at_expression_operator(alt.elements[0], spellings) == 0): return 0
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
# calls the same tier. Prefix alternatives must precede every binary alt,
# giving them tighter binding than all binary operators. This follows
# LeftRecursiveRuleAnalyzer.precedence/nextPrecedence (ANTLR 4.13.2).
int at_normalize_expression(at_rule* rule, list[at_rule*] rules):
	if (rule.is_lexer || rule.is_fragment): return 0
	if ((rule.options != 0) && (rule.options.length > 0)): return 0
	list[at_alt*] binaries = new list[at_alt*]
	list[int] associativity = new list[int]
	list[at_alt*] primary_alts = new list[at_alt*]
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
			if (binaries.length > 0): return 0
			if (at_expression_operator(first, prefix_operators) == 0): return 0
			primary_alts.push(alt)
			continue
		if (alt.elements.length == 3):
			at_element* last = alt.elements[2]
			if ((first.kind != 0) || (last.kind != 0) || (first.suffix != 0) || (last.suffix != 0)): return 0
			if ((strcmp(first.text, c"(") != 0) || (strcmp(last.text, c")") != 0)): return 0
			if (at_expression_self(alt.elements[1], rule.name) == 0): return 0
		else:
			# A single nonrecursive terminal/rule is the remaining base form.
			if (alt.elements.length != 1): return 0
			if ((first.kind != 0) && (first.kind != 2)): return 0
			if (first.suffix != 0): return 0
			if (at_audit_alts_nullable(singleton)): return 0
			if (at_normalize_reaches(singleton, rule.name, new map[char*, int])): return 0
			bases = bases + 1
		primary_alts.push(alt)
	if ((binaries.length == 0) || (bases == 0)): return 0
	# Literal bases cannot compete with prefix operators or parentheses.
	for at_alt* alt in primary_alts:
		if ((alt.elements.length == 1) && (alt.elements[0].kind == 0)):
			char* text = alt.elements[0].text
			if ((text in prefix_operators) || (strcmp(text, c"(") == 0) || (strcmp(text, c")") == 0)): return 0
	# Validation above is atomic: only now allocate and publish helper rules.
	at_rule* primary = at_expression_helper(rule, c"primary")
	for at_alt* alt in primary_alts:
		at_alt* copy = new at_alt()
		copy.elements = at_clone_elements_prefix(alt.elements, alt.elements.length)
		if (copy.elements.length == 2): copy.elements[1] = at_expression_reference(primary.name, rule.first)
		primary.alts.push(copy)
	rules.push(primary)
	at_rule* higher = primary
	int i = 0
	while (i < binaries.length):
		at_rule* tier = at_expression_helper(rule, cstr(f"prec{i}"))
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
