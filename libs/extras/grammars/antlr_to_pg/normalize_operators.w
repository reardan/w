# Operator identity and FIRST-token analysis for expression lowering.
import libs.extras.grammars.antlr_to_pg.normalize_lists


# Resolve one plain literal spelling for delimiter recognition. Operator
# aliases and finite alternatives use the separate proof below; commands and
# variable-width patterns remain outside this fixed-spelling proof.
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


# A finite operator alias has exactly one consuming atom per alternative.
# Parser references stay in the AST; this traversal only proves their possible
# token identities. Lexer aliases may use literal fragments, but parser rules
# may not reference fragments, and lexer rules may not reference parser rules.
int at_expression_operator_finite(at_element* e, map[char*, int] spellings, map[char*, int] active, int depth, int in_lexer):
	if ((depth > 64) || (e.suffix != 0) || e.nongreedy || (e.label != 0)): return 0
	if ((e.sites != 0) && (e.sites.length > 0)): return 0
	if (e.kind == 0):
		if ((strlen(e.text) == 0) || (e.text in spellings)): return 0
		spellings[e.text] = 1
		return 1
	list[at_alt*] alts = 0
	at_rule* referenced = 0
	if (e.kind == 3): alts = e.group_alts
	else if (e.kind == 2):
		if ((e.text in g_at_rules) == 0): return 0
		referenced = g_at_rules[e.text]
		if (active.get(e.text, 0)): return 0
		if (in_lexer && (referenced.is_lexer == 0)): return 0
		if ((in_lexer == 0) && referenced.is_fragment): return 0
		if ((referenced.commands != 0) && (referenced.commands.length > 0)): return 0
		if ((referenced.options != 0) && (referenced.options.length > 0)): return 0
		if ((referenced.mode != 0) && (strcmp(referenced.mode, c"DEFAULT_MODE") != 0)): return 0
		alts = referenced.alts
	else: return 0
	if ((alts == 0) || (alts.length == 0)): return 0
	if (at_rewrite_plain_alts(alts) == 0): return 0
	if (referenced != 0): active[e.text] = 1
	int child_lexer = in_lexer
	if (referenced != 0): child_lexer = referenced.is_lexer
	for at_alt* alt in alts:
		if (alt.elements.length != 1): return 0
		if (at_expression_operator_finite(alt.elements[0], spellings, active, depth + 1, child_lexer) == 0): return 0
	if (referenced != 0):
		active[e.text] = 0
		if (referenced.is_lexer && (referenced.is_fragment == 0)):
			char* identity = strclone(cstr(f"token {referenced.name}"))
			if (identity in spellings): return 0
			spellings[identity] = 1
	return 1


# Commit only after every branch and duplicate identity has been checked.
# The caller's map and the source rules remain unchanged on refusal.
int at_expression_operator(at_element* e, map[char*, int] spellings):
	map[char*, int] found = new map[char*, int]
	if (at_expression_operator_finite(e, found, new map[char*, int], 0, 0) == 0): return 0
	for char* spelling in found:
		if (spelling in spellings): return 0
	for char* spelling in found:
		spellings[spelling] = 1
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
					map[char*, int] finite = new map[char*, int]
					if (at_expression_operator(atom, finite)):
						for char* identity in finite:
							first[identity] = 1
					else: first[strclone(cstr(f"token {e.text}"))] = 1
				else if ((e.text in visited) == 0):
					visited[e.text] = 1
					if (at_expression_first(referenced.alts, first, visited) == 0): return 0
			else: return 0
			if (at_audit_element_nullable(e) == 0): break
	return 1
