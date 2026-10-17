# Read-only parser token-progress analysis. This does not authorize lowering.
# Productivity means a finite syntactic derivation, not lexer/host feasibility.
# EOF is a zero-token assertion; every other named token consumes a cursor slot,
# even when its lexer span is empty. Facts are usable only when complete == 1.
import libs.extras.grammars.antlr_to_pg.types

struct at_progress_limits:
	int max_rules
	int max_work
	int max_depth

struct at_progress_edge:
	char* target
	at_element* source

struct at_progress_cycle:
	char* owner
	int mutual
	list[char*] path

struct at_progress_fact:
	at_rule* rule
	int nullable
	int productive
	list[at_progress_edge*] edges
	at_progress_cycle* self_cycle
	at_progress_cycle* mutual_cycle
	int visited

struct at_progress_issue:
	char* code
	char* rule
	at_element* element

struct at_progress_result:
	at_progress_limits* limits
	map[char*, at_progress_fact*] facts
	list[at_progress_fact*] order
	list[at_progress_cycle*] cycles
	list[at_progress_issue*] issues
	int complete
	int exhausted
	char* reason
	int work
	int edge_count

struct at_progress_frame:
	at_progress_fact* fact
	int next_edge

at_progress_limits* at_progress_default_limits():
	at_progress_limits* limits = new at_progress_limits()
	limits.max_rules = 4096
	limits.max_work = 1000000
	limits.max_depth = 128
	return limits

int at_progress_spend(at_progress_result* result, int depth):
	if (result.exhausted): return 0
	if (depth > result.limits.max_depth):
		result.exhausted = 1
		result.reason = c"depth_limit"
		return 0
	if (result.work >= result.limits.max_work):
		result.exhausted = 1
		result.reason = c"work_limit"
		return 0
	result.work++
	return 1

void at_progress_issue_add(at_progress_result* result, char* code, char* rule, at_element* element):
	at_progress_issue* issue = new at_progress_issue()
	issue.code = code
	issue.rule = rule
	issue.element = element
	result.issues.push(issue)

# Flags: 1 nullable, 2 productive. Zero is conservative while converging.
int at_progress_alts_flags(at_progress_result* result, list[at_alt*] alts, int depth);

int at_progress_atom_flags(at_progress_result* result, at_element* element, int depth):
	if (at_progress_spend(result, depth) == 0): return 0
	if (element.kind == 3): return at_progress_alts_flags(result, element.group_alts, depth + 1)
	if (element.kind == 0):
		if ((element.text == 0) || (strlen(element.text) == 0)): return 3
		return 2
	if (element.kind == 2):
		if (element.text == 0): return 0
		if (strcmp(element.text, c"EOF") == 0): return 3
		at_progress_fact* fact = result.facts.get(element.text, 0)
		if (fact != 0): return fact.nullable | (fact.productive << 1)
		if ((element.text[0] >= 'A') && (element.text[0] <= 'Z')): return 2
		return 0
	# Wildcard/complement consume one token. Charset in a parser is unsupported.
	if ((element.kind == 4) || (element.kind == 5)): return 2
	return 0

int at_progress_element_flags(at_progress_result* result, at_element* element, int depth):
	int flags = at_progress_atom_flags(result, element, depth)
	if ((element.suffix == '?') || (element.suffix == '*')): return 3
	return flags

int at_progress_alts_flags(at_progress_result* result, list[at_alt*] alts, int depth):
	int flags = 0
	for at_alt* alt in alts:
		if (at_progress_spend(result, depth) == 0): return 0
		int branch = 3
		for at_element* element in alt.elements:
			branch = branch & at_progress_element_flags(result, element, depth)
			if (result.exhausted): return 0
		flags = flags | branch
	return flags

# Visit all nested terms for repetition checks, but add only nullable-prefix
# calls to the owner's sparse graph. Keep borrowed element pointers for sites.
void at_progress_scan(at_progress_result* result, at_progress_fact* owner, list[at_alt*] alts, int prefix, int depth):
	for at_alt* alt in alts:
		if (at_progress_spend(result, depth) == 0): return
		int reachable = prefix
		for at_element* element in alt.elements:
			int flags = at_progress_atom_flags(result, element, depth)
			if (result.exhausted): return
			if (((element.suffix == '*') || (element.suffix == '+')) && (flags & 1)):
				at_progress_issue_add(result, c"nullable_repetition", owner.rule.name, element)
			if (element.kind == 3):
				at_progress_scan(result, owner, element.group_alts, reachable, depth + 1)
			else if (element.kind == 2):
				at_progress_fact* target = result.facts.get(element.text, 0)
				if ((target != 0) && reachable):
					at_progress_edge* edge = new at_progress_edge()
					edge.target = target.rule.name
					edge.source = element
					owner.edges.push(edge)
					result.edge_count++
				else if ((target == 0) && (flags == 0)):
					at_progress_issue_add(result, c"unresolved_reference", owner.rule.name, element)
			else if (flags == 0):
				at_progress_issue_add(result, c"unsupported_atom", owner.rule.name, element)
			if (result.exhausted): return
			if ((element.suffix != '?') && (element.suffix != '*') && ((flags & 1) == 0)): reachable = 0

void at_progress_record_cycle(at_progress_result* result, at_progress_fact* owner, list[at_progress_frame*] stack, int mutual):
	at_progress_cycle* cycle = new at_progress_cycle()
	cycle.owner = owner.rule.name
	cycle.mutual = mutual
	cycle.path = new list[char*]
	for at_progress_frame* frame in stack: cycle.path.push(frame.fact.rule.name)
	cycle.path.push(owner.rule.name)
	result.cycles.push(cycle)
	if (mutual): owner.mutual_cycle = cycle
	else: owner.self_cycle = cycle

# Iterative DFS per owner gives each rule its own concrete mutual witness.
# Self edges are recorded separately so they cannot conceal a mutual cycle.
# Worst-case search is O(V*(V+E)); all traversals share the explicit work budget.
void at_progress_cycles(at_progress_result* result):
	int epoch = 0
	for at_progress_fact* owner in result.order:
		epoch++
		list[at_progress_frame*] stack = new list[at_progress_frame*]
		at_progress_frame* initial = new at_progress_frame()
		initial.fact = owner
		stack.push(initial)
		owner.visited = epoch
		for at_progress_edge* edge in owner.edges:
			if (at_progress_spend(result, 0) == 0): return
			if ((strcmp(edge.target, owner.rule.name) == 0) && (owner.self_cycle == 0)):
				at_progress_record_cycle(result, owner, stack, 0)
		while (stack.length > 0):
			if (at_progress_spend(result, 0) == 0): return
			at_progress_frame* frame = stack[stack.length - 1]
			if (frame.next_edge >= frame.fact.edges.length):
				stack.pop()
				continue
			at_progress_edge* edge = frame.fact.edges[frame.next_edge]
			frame.next_edge++
			at_progress_fact* target = result.facts[edge.target]
			if (target == frame.fact): continue
			if (target == owner):
				at_progress_record_cycle(result, owner, stack, 1)
				break
			if (target.visited == epoch): continue
			target.visited = epoch
			at_progress_frame* next = new at_progress_frame()
			next.fact = target
			stack.push(next)

at_progress_result* at_progress_analyze(list[at_rule*] rules, at_progress_limits* limits):
	at_progress_result* result = new at_progress_result()
	result.limits = limits
	result.facts = new map[char*, at_progress_fact*]
	result.order = new list[at_progress_fact*]
	result.cycles = new list[at_progress_cycle*]
	result.issues = new list[at_progress_issue*]
	for at_rule* rule in rules:
		if (at_progress_spend(result, 0) == 0): return result
		if (rule.is_lexer): continue
		if (result.order.length >= limits.max_rules):
			result.exhausted = 1
			result.reason = c"rule_limit"
			return result
		if (rule.name in result.facts):
			at_progress_issue_add(result, c"duplicate_rule", rule.name, 0)
			continue
		at_progress_fact* fact = new at_progress_fact()
		fact.rule = rule
		fact.edges = new list[at_progress_edge*]
		result.facts[rule.name] = fact
		result.order.push(fact)
	int changed = 1
	while (changed):
		changed = 0
		for at_progress_fact* fact in result.order:
			int flags = at_progress_alts_flags(result, fact.rule.alts, 0)
			if (result.exhausted): return result
			if ((flags & 1) && (fact.nullable == 0)):
				fact.nullable = 1
				changed = 1
			if ((flags & 2) && (fact.productive == 0)):
				fact.productive = 1
				changed = 1
	for at_progress_fact* fact in result.order:
		if (fact.productive == 0): at_progress_issue_add(result, c"nonproductive_rule", fact.rule.name, 0)
		at_progress_scan(result, fact, fact.rule.alts, 1, 0)
		if (result.exhausted): return result
	at_progress_cycles(result)
	if (result.exhausted == 0): result.complete = 1
	return result

# Structural token-progress gate only. Host semantics, metadata, name collisions
# with lexer/helper namespaces and downstream grammar safety remain independent.
int at_progress_candidate_valid(at_progress_result* result):
	return result.complete && (result.issues.length == 0) && (result.cycles.length == 0)

int at_progress_rule_consumes(at_progress_result* result, char* name):
	if (result.complete == 0): return 0
	at_progress_fact* fact = result.facts.get(name, 0)
	return (fact != 0) && fact.productive && (fact.nullable == 0)
