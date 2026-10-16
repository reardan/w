# Read-only ANTLR 4.13.2 precedence analysis; this module never lowers rules.
# Reference: tool/src/org/antlr/v4/parse/LeftRecursiveRuleWalker.g and
# tool/src/org/antlr/v4/analysis/LeftRecursiveRuleAnalyzer.java at tag 4.13.2.
# Source pointers are borrowed and must outlive the plan. Treat returned
# descriptors as immutable. An incomplete plan must never drive lowering.
import libs.extras.grammars.antlr_to_pg.types


struct at_lr_occurrence:
	at_element* source
	# Zero-based element, group-alt, element, ... from the outer alternative.
	list[int] path
	# One suffix per element along the path (including enclosing groups).
	list[int] suffixes
	int role                  # 0 ordinary, 1 removed left operand, 2 constrained
	int binding               # ordinary = 0; removed left operand = -1


struct at_lr_alternative:
	at_alt* source
	int source_index          # one-based original OUTER alternative
	int kind                  # 0 other, 1 binary, 2 prefix, 3 suffix
	int precedence            # total original alternatives - source_index + 1
	int primary_binding       # prefix = precedence; other = 0; operator = -1
	int right_associative
	int invalid_associativity
	at_site* associativity_site
	int ignored_associativity # nested/element options do not set outer assoc
	int decision_index        # one-based within primary or operator decision
	list[at_lr_occurrence*] occurrences
	at_lr_occurrence* left_operand
	at_lr_occurrence* constrained


struct at_lr_plan:
	at_rule* owner
	list[at_lr_alternative*] alternatives
	int complete
	char* reason              # empty on success, stable refusal identifier
	int work                  # nodes, sites, option characters, path entries
	int work_limit
	int direct_recursive
	int recursive_occurrences


char* at_lr_kind_name(int kind):
	if (kind == 1): return c"binary"
	if (kind == 2): return c"prefix"
	if (kind == 3): return c"suffix"
	return c"other"


int at_lr_charge(at_lr_plan* plan):
	if (plan.reason[0] != 0): return 0
	if (plan.work >= plan.work_limit):
		plan.reason = c"analysis_budget"
		return 0
	plan.work++
	return 1


int at_lr_direct(at_element* element, char* owner):
	return (element.kind == 2) && (element.suffix == 0) && (strcmp(element.text, owner) == 0)


# -2 absent, -1 invalid, 0 left, 1 right. Parse retained option spelling
# without marking a semantic site resolved. Comments/whitespace are skipped;
# malformed/foreign options remain borrowed source metadata for the audit.
int at_lr_assoc(at_lr_plan* plan, at_site* site):
	if (strcmp(site.kind, c"element option") != 0): return -2
	string_builder* compact = string_new()
	int comment = 0
	int i = 0
	while (site.raw[i] != 0):
		if (at_lr_charge(plan) == 0):
			string_free(compact)
			return -2
		int ch = site.raw[i]
		int next = site.raw[i + 1]
		if (comment == 1):
			if (ch == 10): comment = 0
		else if (comment == 2):
			if ((ch == '*') && (next == '/')):
				comment = 0
				i++
		else if ((ch == '/') && (next == '/')):
			comment = 1
			i++
		else if ((ch == '/') && (next == '*')):
			comment = 2
			i++
		else if ((ch != 32) && (ch != 9) && (ch != 10) && (ch != 13)):
			string_append_char(compact, ch)
		i++
	# The importer accepts a single option per block. Do not certify a
	# manually supplied richer ANTLR option list with an accidental default.
	for j in range(compact.length):
		if (compact.data[j] == ','): plan.reason = c"analysis_option_shape"
	int result = -2
	if (starts_with(compact.data, c"<assoc=")): result = -1
	if (strcmp(compact.data, c"<assoc=left>") == 0): result = 0
	if (strcmp(compact.data, c"<assoc=right>") == 0): result = 1
	string_free(compact)
	return result


void at_lr_collect(at_lr_plan* plan, at_lr_alternative* item, at_alt* alt, list[int] path, list[int] suffixes, int depth):
	if (depth > 128):
		plan.reason = c"analysis_depth"
		return
	if (at_lr_charge(plan) == 0): return
	if (alt.sites != 0):
		at_site* previous_site = 0
		for at_site* site in alt.sites:
			if (at_lr_charge(plan) == 0): return
			int epsilon_option = 0
			if ((previous_site != 0) && (previous_site.position == site.position)):
				epsilon_option = (strcmp(previous_site.kind, c"action") == 0) || (strcmp(previous_site.kind, c"predicate") == 0)
			int outer_option = (previous_site == 0) && (site.position == 0)
			previous_site = site
			int assoc = at_lr_assoc(plan, site)
			if (plan.reason[0] != 0): return
			if ((strcmp(site.kind, c"element option") == 0) && (site.position > 0) && (site.position <= alt.elements.length) && (epsilon_option == 0)):
				at_element* previous = alt.elements[site.position - 1]
				if ((previous.kind == 2) && (strcmp(previous.text, plan.owner.name) == 0)):
					plan.reason = c"analysis_reference_options"
			if (plan.reason[0] != 0): return
			if (assoc == -2): continue
			if ((depth == 0) && outer_option && (item.kind != 0)):
				item.associativity_site = site
				item.right_associative = assoc == 1
				item.invalid_associativity = assoc < 0
			else: item.ignored_associativity++
	for i, element in alt.elements:
		if (at_lr_charge(plan) == 0): return
		path.push(i)
		suffixes.push(element.suffix)
		if ((element.kind == 2) && (strcmp(element.text, plan.owner.name) == 0)):
			at_lr_occurrence* occurrence = new at_lr_occurrence()
			occurrence.source = element
			occurrence.path = new list[int]
			occurrence.suffixes = new list[int]
			item.occurrences.push(occurrence)
			for int component in path:
				if (at_lr_charge(plan) == 0): return
				occurrence.path.push(component)
			for int suffix in suffixes:
				if (at_lr_charge(plan) == 0): return
				occurrence.suffixes.push(suffix)
			plan.recursive_occurrences++
		if ((element.kind == 2) && (strcmp(element.text, plan.owner.name) == 0) && (i + 1 < alt.elements.length)):
			if (alt.elements[i + 1].kind == 1):
				plan.reason = c"analysis_reference_arguments"
				return
		if (element.sites != 0):
			for at_site* site in element.sites:
				if (at_lr_charge(plan) == 0): return
				if (at_lr_assoc(plan, site) != -2): item.ignored_associativity++
		if (element.kind == 3):
			for a, nested in element.group_alts:
				path.push(a)
				at_lr_collect(plan, item, nested, path, suffixes, depth + 1)
				if (plan.reason[0] != 0): return
				path.pop()
		path.pop()
		suffixes.pop()


# Semantic actions/predicates are epsilonElement in the pinned walker but
# are kept outside matching atoms by the importer. A leading action prevents
# the first atom from being an immediate recursive operand. A trailing action
# can supply suffix's element+ even for an otherwise bare owner reference.
int at_lr_classify(at_lr_plan* plan, at_alt* alt):
	int count = alt.elements.length
	if (count == 0): return 0
	int leading = 0
	int trailing = 0
	int first_option = 0
	int last_option = 0
	if (alt.sites != 0):
		at_site* previous_site = 0
		for at_site* site in alt.sites:
			if (at_lr_charge(plan) == 0): return 0
			int option = strcmp(site.kind, c"element option") == 0
			int epsilon_option = 0
			if ((previous_site != 0) && (previous_site.position == site.position)):
				epsilon_option = (strcmp(previous_site.kind, c"action") == 0) || (strcmp(previous_site.kind, c"predicate") == 0)
			previous_site = site
			if ((site.position == 0) && (option == 0)): leading = 1
			if ((site.position == count) && (option == 0)): trailing = 1
			if ((site.position == count) && option && (epsilon_option == 0)): last_option = 1
			if ((site.position == 1) && option && (epsilon_option == 0)): first_option = 1
	int first = (leading == 0) && (first_option == 0) && at_lr_direct(alt.elements[0], plan.owner.name)
	int last = (last_option == 0) && at_lr_direct(alt.elements[count - 1], plan.owner.name)
	# Walker priority is binary, prefix, suffix, other. A suffix/group on
	# the final self reference is an element, never the mandatory recurse.
	if (first && last && (count > 1)): return 1
	if (last && ((count > 1) || leading)): return 2
	if (first && ((count > 1) || trailing || last_option)): return 3
	return 0


at_lr_plan* at_lr_plan_build(at_rule* owner, int work_limit):
	at_lr_plan* plan = new at_lr_plan()
	plan.owner = owner
	plan.alternatives = new list[at_lr_alternative*]
	plan.reason = c""
	plan.work_limit = work_limit
	if (owner.is_lexer || owner.is_fragment):
		plan.reason = c"not_parser_rule"
		return plan
	for i, alt in owner.alts:
		if (at_lr_charge(plan) == 0): return plan
		at_lr_alternative* item = new at_lr_alternative()
		item.source = alt
		item.source_index = i + 1
		item.precedence = owner.alts.length - i
		item.kind = at_lr_classify(plan, alt)
		item.primary_binding = 0
		if ((item.kind == 1) || (item.kind == 3)): item.primary_binding = -1
		if (item.kind == 2): item.primary_binding = item.precedence
		item.occurrences = new list[at_lr_occurrence*]
		plan.alternatives.push(item)
		list[int] path = new list[int]
		list[int] suffixes = new list[int]
		at_lr_collect(plan, item, alt, path, suffixes, 0)
		path.free()
		suffixes.free()
		if (plan.reason[0] != 0): return plan
		if ((item.kind == 1) || (item.kind == 3)):
			plan.direct_recursive = 1
			item.left_operand = item.occurrences[0]
			item.left_operand.role = 1
			item.left_operand.binding = -1
		if ((item.kind == 1) || (item.kind == 2)):
			# The mandatory final recurse is the rightmost preorder RULE_REF.
			# Earlier nested references retain ordinary full-precedence entry.
			item.constrained = item.occurrences[item.occurrences.length - 1]
			item.constrained.role = 2
			item.constrained.binding = item.precedence
			if ((item.kind == 1) && (item.right_associative == 0)): item.constrained.binding++
	int primary = 0
	int binary = 0
	for at_lr_alternative* item in plan.alternatives:
		if (at_lr_charge(plan) == 0): return plan
		if ((item.kind == 0) || (item.kind == 2)):
			primary++
			item.decision_index = primary
		if (item.kind == 1):
			binary++
			item.decision_index = binary
	# Analyzer emits all binary alternatives before suffix alternatives,
	# retaining source order within each partition (not global source order).
	for at_lr_alternative* item in plan.alternatives:
		if (at_lr_charge(plan) == 0): return plan
		if (item.kind == 3):
			binary++
			item.decision_index = binary
	plan.complete = 1
	return plan


# Release only owned analysis storage, never borrowed rule/AST/site metadata.
void at_lr_plan_free(at_lr_plan* plan):
	if (plan == 0): return
	for at_lr_alternative* item in plan.alternatives:
		for at_lr_occurrence* occurrence in item.occurrences:
			occurrence.path.free()
			occurrence.suffixes.free()
			free(occurrence)
		item.occurrences.free()
		free(item)
	plan.alternatives.free()
	free(plan)
