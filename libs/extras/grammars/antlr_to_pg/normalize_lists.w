# Bounded source normalization for lists and postfix chains.
# Nested recursion needs consuming paired delimiters; indirect left recursion,
# labels and host actions/predicates remain unsupported.
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


# Recognize mandatory delimiter literals, including single-literal lexer aliases.
# Arbitrary consuming prefixes are insufficient: '+' operand can hide another
# unparenthesized expression whose ANTLR precedence would need separate lowering.
int at_list_delimiter(at_element* e, int depth):
	if ((depth > 16) || (e.suffix != 0)): return 0
	if (e.kind == 0):
		if (strlen(e.text) == 1): return cast(int, e.text[0])
		return 0
	if ((e.kind != 2) || ((e.text in g_at_rules) == 0)): return 0
	at_rule* rule = g_at_rules[e.text]
	if ((rule.is_lexer == 0) || (rule.alts.length != 1)): return 0
	if ((rule.commands != 0) && (rule.commands.length > 0)): return 0
	if ((rule.options != 0) && (rule.options.length > 0)): return 0
	if ((rule.mode != 0) && (strcmp(rule.mode, c"DEFAULT_MODE") != 0)): return 0
	if (at_rewrite_plain_alts(rule.alts) == 0): return 0
	if (rule.alts[0].elements.length != 1): return 0
	return at_list_delimiter(rule.alts[0].elements[0], depth + 1)


int at_list_nested_element(at_alt* alt, int position):
	int before = 0
	while (before < position):
		int opener = at_list_delimiter(alt.elements[before], 0)
		int closer = 0
		if (opener == '('): closer = ')'
		if (opener == '['): closer = ']'
		if (opener == '{'): closer = '}'
		if (closer != 0):
			int after = position + 1
			while (after < alt.elements.length):
				if (at_list_delimiter(alt.elements[after], 0) == closer): return 1
				after++
		before++
	return 0


# Inspect all references until a mandatory delimiter pair encloses the call.
# In particular, consuming a binary operator alone does not make recursion a
# nested operand. A fresh DFS set per candidate alternative keeps this proof
# independent of source-rule order. The final audit still rejects left cycles.
int at_list_unguarded_reaches(list[at_alt*] alts, char* target, map[char*, int] visited):
	for at_alt* alt in alts:
		int index = 0
		while (index < alt.elements.length):
			at_element* e = alt.elements[index]
			int nested = at_list_nested_element(alt, index)
			index++
			if (nested): continue
			if (e.kind == 3):
				if (at_list_unguarded_reaches(e.group_alts, target, visited)): return 1
			else if (e.kind == 2):
				if (strcmp(e.text, target) == 0): return 1
				if (strcmp(e.text, c"EOF") == 0): continue
				if ((e.text in g_at_rules) == 0): return 1
				if ((e.text in visited) == 0):
					visited[e.text] = 1
					if (at_list_unguarded_reaches(g_at_rules[e.text].alts, target, visited)): return 1
	return 0


# A: A suffix | base -> A: base (suffix)*. Every alternative may occur
# only in one of those two forms. Tails must consume; bases may be empty.
# Recursive operands must be delimiter-contained, annotations unsupported.
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
	int nullable_base = 0
	for at_alt* alt in rule.alts:
		if (alt.elements.length == 0):
			bases.push(alt)
			nullable_base = 1
			continue
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
		if (recursive && at_audit_alts_nullable(singleton)): return 0
		if (at_list_unguarded_reaches(singleton, rule.name, new map[char*, int])): return 0
		if (recursive): tails.push(part)
		else:
			bases.push(part)
			if (at_audit_alts_nullable(singleton)): nullable_base = 1
	if ((bases.length == 0) || (tails.length == 0)): return 0
	# Ordered choices can let an empty base hide a later consuming base.
	# A consuming optional base can also steal the start of a tail (x? (xy)*).
	# Accept nullable bases only as one syntactically empty alternative.
	if (nullable_base):
		if (bases.length > 1): return 0
		if (bases[0].elements.length > 0): return 0
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
