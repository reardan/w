# General direct-expression planning for complete-input prediction only.
# Each binding-power rule loops over every operator admitted at that minimum,
# so a low-binding postfix may be followed by a higher-binding postfix/binary.
# Source alternatives and element labels remain attached to normalized nodes.
import libs.extras.grammars.antlr_to_pg.normalize_operators
import libs.extras.grammars.antlr_to_pg.source_metadata


struct at_precedence_operator:
	at_alt* source
	int right_operand
	int right_associative


int at_expression_self(at_element* e, char* name);
int at_expression_associativity(at_alt* alt);
at_element* at_expression_reference(char* name, pg_token* location);
at_rule* at_expression_helper(at_rule* owner, char* suffix);
int at_expression_base_direct(list[at_alt*] alts, char* owner);
int at_expression_productive(char* owner);


int at_precedence_alts_nullable(list[at_alt*] alts);


int at_precedence_atom_nullable(at_element* element):
	if (element.kind == 3): return at_precedence_alts_nullable(element.group_alts)
	if ((element.kind == 2) && (element.text in g_at_rules)):
		if (g_at_rules[element.text].is_lexer): return 0
	return at_audit_atom_nullable(element)


int at_precedence_alts_nullable(list[at_alt*] alts):
	for at_alt* alt in alts:
		int nullable = 1
		for at_element* element in alt.elements:
			if ((element.suffix == '?') || (element.suffix == '*')): continue
			if (at_precedence_atom_nullable(element) == 0): nullable = 0
		if (nullable): return 1
	return 0


# Require an operator/prefix to consume before it may call its expression.
# The final audit still checks every nullable-prefix cycle after publication.
int at_precedence_prefix_safe(at_alt* alt, int begin, int end, char* owner):
	at_alt* prefix = new at_alt()
	prefix.elements = new list[at_element*]
	for i in range(begin, end): prefix.elements.push(alt.elements[i])
	list[at_alt*] alts = new list[at_alt*]
	alts.push(prefix)
	if (at_precedence_alts_nullable(alts)): return 0
	return at_audit_left_path(alts, owner, new map[char*, int]) == 0


int at_precedence_plain(list[at_alt*] alts):
	for at_alt* alt in alts:
		if ((alt.sites != 0) && (alt.sites.length > 0)): return 0
		for at_element* element in alt.elements:
			if (element.nongreedy): return 0
			if ((element.sites != 0) && (element.sites.length > 0)): return 0
			if ((element.kind == 3) && (at_precedence_plain(element.group_alts) == 0)): return 0
	return 1


int at_normalize_prediction_expression(at_rule* rule, list[at_rule*] rules):
	if (rule.is_lexer || rule.is_fragment): return 0
	if ((rule.options != 0) && (rule.options.length > 0)): return at_normalization_guard(rule, c"prediction_expression", 0, c"rule_options")
	list[at_precedence_operator*] operators = new list[at_precedence_operator*]
	list[at_alt*] primaries = new list[at_alt*]
	list[int] prefix_binding = new list[int]
	for ai, alt in rule.alts:
		if (alt.elements.length == 0): return at_normalization_guard(rule, c"prediction_expression", ai + 1, c"empty_alternative")
		at_alt* plain = new at_alt()
		plain.elements = alt.elements
		list[at_alt*] singleton = new list[at_alt*]
		singleton.push(plain)
		if (at_precedence_plain(singleton) == 0): return at_normalization_guard(rule, c"prediction_expression", ai + 1, c"element_semantics")
		int last = alt.elements.length - 1
		if (at_expression_self(alt.elements[0], rule.name)):
			if (last < 1): return at_normalization_guard(rule, c"prediction_expression", ai + 1, c"self_only_alternative")
			int assoc = at_expression_associativity(alt)
			if (assoc < 0): return at_normalization_guard(rule, c"prediction_expression", ai + 1, c"alternative_options")
			int operand = -1
			if (at_expression_self(alt.elements[last], rule.name)): operand = last
			int first_operand = 1
			while (first_operand < alt.elements.length):
				if (at_expression_self(alt.elements[first_operand], rule.name)): break
				first_operand++
			if (at_precedence_prefix_safe(alt, 1, first_operand, rule.name) == 0): return at_normalization_guard(rule, c"prediction_expression", ai + 1, c"operator_prefix_not_proven")
			at_precedence_operator* op = new at_precedence_operator()
			op.source = alt
			op.right_operand = operand
			op.right_associative = assoc
			operators.push(op)
		else:
			if ((alt.sites != 0) && (alt.sites.length > 0)): return at_normalization_guard(rule, c"prediction_expression", ai + 1, c"primary_semantics")
			int binding = -1
			if ((last > 0) && at_expression_self(alt.elements[last], rule.name)):
				if (at_precedence_prefix_safe(alt, 0, last, rule.name) == 0): return at_normalization_guard(rule, c"prediction_expression", ai + 1, c"primary_prefix_not_proven")
				binding = operators.length
			else:
				if (at_precedence_alts_nullable(singleton)): return at_normalization_guard(rule, c"prediction_expression", ai + 1, c"nullable_primary")
				if (at_expression_base_direct(singleton, rule.name) == 0): return at_normalization_guard(rule, c"prediction_expression", ai + 1, c"primary_owner_not_delimited")
				if (at_audit_left_path(singleton, rule.name, new map[char*, int])): return at_normalization_guard(rule, c"prediction_expression", ai + 1, c"primary_nullable_prefix_cycle")
			primaries.push(alt)
			prefix_binding.push(binding)
	if ((operators.length == 0) || (primaries.length == 0)): return at_normalization_guard(rule, c"prediction_expression", 0, c"missing_operator_or_primary")
	if (at_expression_productive(rule.name) == 0): return at_normalization_guard(rule, c"prediction_expression", 0, c"base_not_proven_productive")
	# All refusals precede helper registration and source mutation.
	at_rule* primary = at_expression_helper(rule, c"primary")
	list[at_rule*] tiers = new list[at_rule*]
	for i in range(operators.length): tiers.push(at_expression_helper(rule, cstr(f"bp{i}")))
	for p, source in primaries:
		at_alt* copy = new at_alt()
		at_source_copy(copy, source)
		copy.elements = at_clone_elements_prefix(source.elements, source.elements.length)
		int binding = prefix_binding[p]
		if (binding >= 0):
			char* target = primary.name
			if (binding > 0): target = tiers[binding - 1].name
			int last = copy.elements.length - 1
			char* label = copy.elements[last].label
			copy.elements[last] = at_expression_reference(target, rule.first)
			copy.elements[last].label = label
		primary.alts.push(copy)
	rules.push(primary)
	for i, tier in tiers:
		at_element* loop = new at_element()
		loop.kind = 3
		loop.suffix = '*'
		loop.first = rule.first
		loop.group_alts = new list[at_alt*]
		for j in range(i + 1):
			at_precedence_operator* op = operators[j]
			at_alt* tail = new at_alt()
			at_source_copy(tail, op.source)
			tail.source_lhs_label = op.source.elements[0].label
			tail.elements = new list[at_element*]
			for e in range(1, op.source.elements.length):
				at_element* element = at_clone_element(op.source.elements[e])
				if (e == op.right_operand):
					char* target = primary.name
					if (j > 0): target = tiers[j - 1].name
					if (op.right_associative): target = tiers[j].name
					char* label = element.label
					element = at_expression_reference(target, element.first)
					element.label = label
				tail.elements.push(element)
			loop.group_alts.push(tail)
		at_alt* body = new at_alt()
		body.elements = new list[at_element*]
		body.elements.push(at_expression_reference(primary.name, rule.first))
		body.elements.push(loop)
		tier.alts.push(body)
		rules.push(tier)
	at_alt* entry = new at_alt()
	entry.elements = new list[at_element*]
	entry.elements.push(at_expression_reference(tiers[tiers.length - 1].name, rule.first))
	rule.alts = new list[at_alt*]
	rule.alts.push(entry)
	return 1


# A nullable list base is valid when every suffix consumes before an indirect
# recursive body. Named statement rules can guard recursion with keywords;
# no hard-coded keyword delimiter pairing is inferred. Direct owner operands
# are left to precedence lowering, not flattened into list semantics.
int at_normalize_prediction_list(at_rule* rule):
	if (rule.is_lexer || rule.is_fragment): return 0
	if ((rule.options != 0) && (rule.options.length > 0)): return at_normalization_guard(rule, c"prediction_list", 0, c"rule_options")
	if (at_precedence_plain(rule.alts) == 0): return at_normalization_guard(rule, c"prediction_list", 0, c"element_semantics")
	list[at_alt*] bases = new list[at_alt*]
	list[at_alt*] tails = new list[at_alt*]
	int nullable = 0
	for ai, alt in rule.alts:
		int recursive = 0
		if (alt.elements.length > 0): recursive = at_expression_self(alt.elements[0], rule.name)
		at_alt* part = new at_alt()
		at_source_copy(part, alt)
		part.elements = new list[at_element*]
		int begin = 0
		if (recursive):
			begin = 1
			part.source_lhs_label = alt.elements[0].label
		for i in range(begin, alt.elements.length): part.elements.push(at_clone_element(alt.elements[i]))
		list[at_alt*] singleton = new list[at_alt*]
		singleton.push(part)
		if (at_audit_left_path(singleton, rule.name, new map[char*, int])): return at_normalization_guard(rule, c"prediction_list", ai + 1, c"tail_nullable_prefix_cycle")
		if (recursive):
			if (at_precedence_alts_nullable(singleton)): return at_normalization_guard(rule, c"prediction_list", ai + 1, c"nullable_tail")
			if (at_expression_base_direct(singleton, rule.name) == 0): return at_normalization_guard(rule, c"prediction_list", ai + 1, c"tail_owner_not_delimited")
			tails.push(part)
		else:
			if (at_precedence_alts_nullable(singleton)): nullable = 1
			bases.push(part)
	if ((nullable == 0) || (bases.length == 0) || (tails.length == 0)): return at_normalization_guard(rule, c"prediction_list", 0, c"missing_nullable_base_or_tail")
	if (at_expression_productive(rule.name) == 0): return at_normalization_guard(rule, c"prediction_list", 0, c"base_not_proven_productive")
	at_alt* normalized = new at_alt()
	normalized.elements = new list[at_element*]
	at_element* base = new at_element()
	base.kind = 3
	base.group_alts = bases
	base.first = rule.first
	normalized.elements.push(base)
	at_element* tail = new at_element()
	tail.kind = 3
	tail.group_alts = tails
	tail.suffix = '*'
	tail.first = rule.first
	normalized.elements.push(tail)
	rule.alts = new list[at_alt*]
	rule.alts.push(normalized)
	return 1
