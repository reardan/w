# Plan-driven ANTLR 4.13.2 direct left-recursion lowering, prediction mode only.
# Runs after every older normalizer has refused a rule, so it never changes the
# lowering or AST of a rule those normalizers already accept. Classification,
# precedence and operand bindings come from the immutable at_lr_plan
# (precedence_plan.w), which is checked against pinned ANTLR snapshots
# (tests/grammars/antlr_left_recursion/README.md).
#
# Lowered shape (same helper layout as at_normalize_prediction_expression):
#   R         : R_bp{last}
#   R_primary : <prefix and other alternatives, source order>
#   R_bp{i}   : R_primary ( <operator tails admitted at tier i> )*
# Operators are the binary and suffix alternatives in source order; tier i
# admits operators 0..i, i.e. every operator whose ANTLR precedence is at least
# that of operator i. A constrained operand with binding b calls the tier that
# admits exactly the operators with precedence >= b (`R[b]` in ANTLR's
# rewritten rule). Ordinary recursive references keep calling R (`R[0]`).
# Within a loop, binary tails precede suffix tails, each in source order:
# the transformed decision order of LeftRecursiveRuleAnalyzer.
#
# Safety: unlike the older normalizers, an operator may begin with a nullable
# prefix (adjacent operands, optional separators) and a primary may contain an
# undelimited ordinary owner call, because both are proven here directly:
# every loop tail must consume a token, the primary group must not reach the
# owner through a nullable prefix, and with a nullable primary every tail must
# consume before any operand. The final left-path audit and the generator's
# grammar safety check remain independent backstops.
import libs.extras.grammars.antlr_to_pg.normalize_prediction
import libs.extras.grammars.antlr_to_pg.precedence_plan


int g_at_precedence_plan_limit = 1000000


# Only ANTLR associativity options are inert for lowering: the plan applies the
# outer one and ANTLR ignores nested ones. Other options, actions, predicates
# and nongreedy decisions keep the rule refused.
int at_plan_assoc_site(at_site* site):
	if (strcmp(site.kind, c"element option") != 0): return 0
	string_builder* compact = string_new()
	int i = 0
	while (site.raw[i] != 0):
		int c = site.raw[i]
		if ((c != 32) && (c != 9) && (c != 10) && (c != 13)): string_append_char(compact, c)
		i++
	# Invalid values are left to the plan, which reports them as invalid.
	int result = starts_with(compact.data, c"<assoc=") && (compact.data[compact.length - 1] == '>')
	string_free(compact)
	return result


int at_plan_sites_inert(list[at_site*] sites):
	if (sites == 0): return 1
	for at_site* site in sites:
		if (at_plan_assoc_site(site) == 0): return 0
	return 1


int at_plan_elements_inert(list[at_element*] elements):
	for at_element* element in elements:
		if (element.nongreedy): return 0
		if (at_plan_sites_inert(element.sites) == 0): return 0
		if (element.kind == 3):
			for at_alt* nested in element.group_alts:
				if (at_plan_sites_inert(nested.sites) == 0): return 0
				if (at_plan_elements_inert(nested.elements) == 0): return 0
	return 1


at_alt* at_plan_alt(list[at_element*] elements, int begin, int end):
	at_alt* alt = new at_alt()
	alt.elements = new list[at_element*]
	for i in range(begin, end): alt.elements.push(elements[i])
	return alt


list[at_alt*] at_plan_singleton(at_alt* alt):
	list[at_alt*] alts = new list[at_alt*]
	alts.push(alt)
	return alts


# Number of operators admitted by binding b: ANTLR's precpred(b) holds for an
# operator alternative k exactly when its precedence N - k + 1 >= b.
int at_plan_admitted(at_lr_plan* plan, list[at_lr_alternative*] operators, int binding):
	int count = 0
	int limit = plan.owner.alts.length - binding + 1
	for at_lr_alternative* op in operators:
		if (op.source_index <= limit): count++
	return count


char* at_plan_target(at_rule* primary, list[at_rule*] tiers, int admitted):
	if (admitted == 0): return primary.name
	return tiers[admitted - 1].name


int at_normalize_prediction_plan(at_rule* rule, list[at_rule*] rules):
	if (rule.is_lexer || rule.is_fragment): return 0
	if ((rule.options != 0) && (rule.options.length > 0)): return at_normalization_guard(rule, c"prediction_plan", 0, c"rule_options")
	at_lr_plan* plan = at_lr_plan_build(rule, g_at_precedence_plan_limit)
	if (plan.complete == 0): return at_normalization_guard(rule, c"prediction_plan", 0, plan.reason)
	if (plan.direct_recursive == 0): return at_normalization_guard(rule, c"prediction_plan", 0, c"not_direct_recursive")
	list[at_lr_alternative*] primaries = new list[at_lr_alternative*]
	list[at_lr_alternative*] operators = new list[at_lr_alternative*]
	int nullable_primary = 0
	for at_lr_alternative* item in plan.alternatives:
		at_alt* alt = item.source
		int index = item.source_index
		if (at_plan_sites_inert(alt.sites) == 0): return at_normalization_guard(rule, c"prediction_plan", index, c"element_semantics")
		if (at_plan_elements_inert(alt.elements) == 0): return at_normalization_guard(rule, c"prediction_plan", index, c"element_semantics")
		if (item.invalid_associativity): return at_normalization_guard(rule, c"prediction_plan", index, c"alternative_options")
		int count = alt.elements.length
		if ((item.kind == 1) || (item.kind == 3)):
			# Only the consumed outer associativity option may sit on an operator.
			if (alt.sites != 0):
				for at_site* site in alt.sites:
					if (site != item.associativity_site): return at_normalization_guard(rule, c"prediction_plan", index, c"alternative_options")
			operators.push(item)
			continue
		if (item.kind == 2):
			at_alt* prefix = at_plan_alt(alt.elements, 0, count - 1)
			if (at_precedence_alts_nullable(at_plan_singleton(prefix))): return at_normalization_guard(rule, c"prediction_plan", index, c"primary_prefix_not_proven")
			if (at_audit_left_path(at_plan_singleton(prefix), rule.name, new map[char*, int])): return at_normalization_guard(rule, c"prediction_plan", index, c"primary_nullable_prefix_cycle")
		else:
			at_alt* whole = at_plan_alt(alt.elements, 0, count)
			if (at_audit_left_path(at_plan_singleton(whole), rule.name, new map[char*, int])): return at_normalization_guard(rule, c"prediction_plan", index, c"primary_nullable_prefix_cycle")
			if (at_precedence_alts_nullable(at_plan_singleton(whole))): nullable_primary = 1
		primaries.push(item)
	if ((operators.length == 0) || (primaries.length == 0)): return at_normalization_guard(rule, c"prediction_plan", 0, c"missing_operator_or_primary")
	# Every loop iteration must consume. A constrained operand consumes only
	# when every primary does; the rest of the tail must consume otherwise.
	# With a nullable primary, nothing before the tail's first token may reach
	# the owner, or the owner's entry could recurse without consuming.
	for at_lr_alternative* op in operators:
		at_alt* alt = op.source
		int end = alt.elements.length
		if (op.kind == 1): end = end - 1
		at_alt* rest = at_plan_alt(alt.elements, 1, end)
		int rest_nullable = at_precedence_alts_nullable(at_plan_singleton(rest))
		if (rest_nullable && ((op.kind == 3) || nullable_primary)): return at_normalization_guard(rule, c"prediction_plan", op.source_index, c"nullable_operator_tail")
		if (nullable_primary && at_audit_left_path(at_plan_singleton(rest), rule.name, new map[char*, int])): return at_normalization_guard(rule, c"prediction_plan", op.source_index, c"tail_nullable_prefix_cycle")
	if (at_expression_productive(rule.name) == 0): return at_normalization_guard(rule, c"prediction_plan", 0, c"base_not_proven_productive")
	# All refusals precede helper registration and source mutation.
	at_rule* primary = at_expression_helper(rule, c"primary")
	list[at_rule*] tiers = new list[at_rule*]
	for i in range(operators.length): tiers.push(at_expression_helper(rule, cstr(f"bp{i}")))
	for at_lr_alternative* item in primaries:
		at_alt* source = item.source
		at_alt* copy = new at_alt()
		at_source_copy(copy, source)
		copy.sites = source.sites
		copy.elements = at_clone_elements_prefix(source.elements, source.elements.length)
		if (item.kind == 2):
			int last = copy.elements.length - 1
			char* label = copy.elements[last].label
			char* target = at_plan_target(primary, tiers, at_plan_admitted(plan, operators, item.constrained.binding))
			copy.elements[last] = at_expression_reference(target, source.elements[last].first)
			copy.elements[last].label = label
		primary.alts.push(copy)
	rules.push(primary)
	for i, tier in tiers:
		at_element* loop = new at_element()
		loop.kind = 3
		loop.suffix = '*'
		loop.first = rule.first
		loop.group_alts = new list[at_alt*]
		for pass in range(2):
			for j in range(i + 1):
				at_lr_alternative* op = operators[j]
				if ((pass == 0) != (op.kind == 1)): continue
				at_alt* source = op.source
				at_alt* tail = new at_alt()
				at_source_copy(tail, source)
				tail.source_lhs_label = source.elements[0].label
				tail.tree_role = 2
				tail.elements = new list[at_element*]
				int last = source.elements.length - 1
				for e in range(1, source.elements.length):
					at_element* element = at_clone_element(source.elements[e])
					if ((op.kind == 1) && (e == last)):
						char* target = at_plan_target(primary, tiers, at_plan_admitted(plan, operators, op.constrained.binding))
						element = at_expression_reference(target, source.elements[e].first)
						element.label = source.elements[e].label
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
	at_lr_plan_free(plan)
	return 1
