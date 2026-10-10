# ---------------------------------------------------------------------------
# AST -> at_rule/at_alt/at_element
# ---------------------------------------------------------------------------
import libs.extras.grammars.antlr_to_pg.types
import bin.generated_antlr4_parser


# Copy exact bytes, including trivia between terminals. Token spans survive
# until the input parse is released; semantic text is independently owned.
at_site* at_build_site(pg_ast_node* node, char* kind, int position):
	at_site* site = new at_site()
	site.kind = kind
	site.first = node.first_token
	site.last = node.last_token
	site.position = position
	site.raw = c""
	if ((site.first != 0) && (site.last != 0)):
		site.raw = pg_substr(g_at_source, site.first.offset, site.last.offset + site.last.length - site.first.offset)
	return site


char* at_unescape_antlr_string(char* raw):
	string_builder* out = string_new()
	int n = strlen(raw) - 1
	int i = 1
	while (i < n):
		int c = raw[i]
		if ((c == 92) && (i + 1 < n)):
			int nc = raw[i + 1]
			int mapped = nc
			if (nc == 'n'):
				mapped = 10
			else if (nc == 'r'):
				mapped = 13
			else if (nc == 't'):
				mapped = 9
			string_append_char(out, mapped)
			i = i + 2
		else:
			string_append_char(out, c)
			i = i + 1
	char* result = strclone(out.data)
	string_free(out)
	return result


list[at_alt*] at_build_altlist(pg_ast_node* node);


void at_report(char* prefix, char* rule_name, char* payload);


# group = LPAREN group_colon_prefix? altlist RPAREN — altlist is the child
# whose kind is antlr4_ast_altlist (skip optional colon-prefix).
pg_ast_node* at_group_altlist_node(pg_ast_node* group_node):
	int cnt = pg_ast_child_count(group_node)
	int i = 0
	while (i < cnt):
		pg_ast_node* ch = pg_ast_child(group_node, i)
		if (ch.kind == antlr4_ast_altlist):
			return ch
		i = i + 1
	# Fallback: historical shape LPAREN altlist RPAREN
	if (cnt >= 2):
		return pg_ast_child(group_node, 1)
	return pg_ast_child(group_node, 0)


at_element* at_build_atom(pg_ast_node* node):
	pg_ast_node* child = pg_ast_child(node, 0)
	at_element* elem = new at_element()
	elem.suffix = 0
	elem.first = node.first_token
	elem.last = node.last_token
	elem.group_alts = 0
	elem.text = 0
	elem.sites = new list[at_site*]
	# `'a'..'z'` range: four children STRINGLIT DOT DOT STRINGLIT. Fold into
	# a charset so the matcher generator / classifier see one atom.
	if (pg_ast_child_count(node) == 4):
		if ((child.kind == antlr4_token_STRINGLIT) & (pg_ast_child(node, 1).kind == antlr4_token_DOT) & (pg_ast_child(node, 2).kind == antlr4_token_DOT) & (pg_ast_child(node, 3).kind == antlr4_token_STRINGLIT)):
			char* lo = at_unescape_antlr_string(child.text)
			char* hi = at_unescape_antlr_string(pg_ast_child(node, 3).text)
			if ((strlen(lo) == 1) & (strlen(hi) == 1)):
				string_builder* cs = string_new()
				string_append_char(cs, '[')
				string_append_char(cs, lo[0])
				string_append_char(cs, '-')
				string_append_char(cs, hi[0])
				string_append_char(cs, ']')
				elem.kind = 1
				elem.text = strclone(cs.data)
				string_free(cs)
				free(lo)
				free(hi)
				return elem
			free(lo)
			free(hi)
	if (child.kind == antlr4_token_STRINGLIT):
		elem.kind = 0
		elem.text = at_unescape_antlr_string(child.text)
	else if (child.kind == antlr4_token_CHARSET):
		elem.kind = 1
		elem.text = strclone(child.text)
	else if (child.kind == antlr4_token_DOT):
		elem.kind = 4
	else if (child.kind == antlr4_ast_negated_atom):
		elem.kind = 5
		pg_ast_node* negated_atom = pg_ast_child(child, 1)
		if (pg_ast_child_count(negated_atom) > 0):
			pg_ast_node* negated_inner = pg_ast_child(negated_atom, 0)
			if (negated_inner.kind == antlr4_token_CHARSET):
				elem.text = strclone(negated_inner.text)
			else if (negated_inner.kind == antlr4_token_STRINGLIT):
				# ~'>'  → treat as negated singleton charset
				char* lit = at_unescape_antlr_string(negated_inner.text)
				if (strlen(lit) == 1):
					string_builder* cs = string_new()
					string_append_char(cs, '[')
					string_append_char(cs, lit[0])
					string_append_char(cs, ']')
					elem.text = strclone(cs.data)
					string_free(cs)
				free(lit)
			else if (negated_inner.kind == antlr4_token_IDENT):
				# ~RP / ~LeftParen — defer token-ref fold (needs lexer tables).
				elem.group_alts = new list[at_alt*]
				at_alt* ra = new at_alt()
				ra.elements = new list[at_element*]
				at_element* re = new at_element()
				re.kind = 2
				re.text = strclone(negated_inner.text)
				re.group_alts = 0
				re.suffix = 0
				ra.elements.push(re)
				elem.group_alts.push(ra)
			else if (negated_inner.kind == antlr4_ast_group):
				# ~ ( 'a' | 'b' | '\n' | '0'..'9' | [ \t] | TokenRef )
				# → charset of singleton ASCII bytes / ranges. Token refs
				# resolve later in at_fold_negated_token_refs (needs lexer
				# tables); here we fold literals/charsets/ranges only.
				pg_ast_node* galtlist = at_group_altlist_node(negated_inner)
				list[at_alt*] galts = at_build_altlist(galtlist)
				string_builder* cs = string_new()
				string_append_char(cs, '[')
				int ok = 1
				int saw_token_ref = 0
				int gi = 0
				while (gi < galts.length):
					at_alt* galt = galts[gi]
					if (galt.elements.length != 1):
						ok = 0
					else:
						at_element* ge = galt.elements[0]
						if (ge.suffix != 0):
							ok = 0
						else if ((ge.kind == 0) && (ge.text != 0) & (strlen(ge.text) == 1)):
							int ch = ge.text[0]
							if ((ch == ']') || (ch == '-') || (ch == 92) || (ch == '^')):
								string_append_char(cs, 92)
							string_append_char(cs, ch)
						else if ((ge.kind == 1) && (ge.text != 0)):
							# Inline charset contents (drop brackets).
							int cn = strlen(ge.text)
							if ((cn >= 2) && (ge.text[0] == '[')):
								int ci = 1
								if (ge.text[1] == '^'):
									ok = 0
								else:
									while (ci < cn - 1):
										string_append_char(cs, ge.text[ci])
										ci = ci + 1
							else:
								ok = 0
						else if (ge.kind == 2):
							# Token/rule ref — defer; mark for later fold.
							saw_token_ref = 1
							ok = 0
						else:
							ok = 0
					gi = gi + 1
				string_append_char(cs, ']')
				if (ok):
					elem.text = strclone(cs.data)
				else if (saw_token_ref):
					# Keep the group so a later pass can resolve token refs
					# to single-char literals (cpp/icalendar/objc).
					elem.group_alts = galts
				string_free(cs)
			else if (pg_ast_child_count(negated_atom) == 4):
				# ~'a'..'z' — inner atom is STRINGLIT DOT DOT STRINGLIT.
				if ((negated_inner.kind == antlr4_token_STRINGLIT) & (pg_ast_child(negated_atom, 1).kind == antlr4_token_DOT) & (pg_ast_child(negated_atom, 2).kind == antlr4_token_DOT) & (pg_ast_child(negated_atom, 3).kind == antlr4_token_STRINGLIT)):
					char* lo = at_unescape_antlr_string(negated_inner.text)
					char* hi = at_unescape_antlr_string(pg_ast_child(negated_atom, 3).text)
					if ((strlen(lo) == 1) & (strlen(hi) == 1)):
						string_builder* cs = string_new()
						string_append_char(cs, '[')
						string_append_char(cs, lo[0])
						string_append_char(cs, '-')
						string_append_char(cs, hi[0])
						string_append_char(cs, ']')
						elem.text = strclone(cs.data)
						string_free(cs)
					free(lo)
					free(hi)
	else if (child.kind == antlr4_ast_group):
		elem.kind = 3
		elem.group_alts = at_build_altlist(at_group_altlist_node(child))
		if (pg_ast_child_count(child) > 3):
			pg_ast_node* prefix = pg_ast_child(child, 1)
			if (pg_ast_child_count(prefix) > 1):
				elem.sites.push(at_build_site(prefix, c"block option", 0))
	else:
		elem.kind = 2
		elem.text = strclone(child.text)
	return elem


at_element* at_build_atom_from_labeled(pg_ast_node* node):
	int cnt = pg_ast_child_count(node)
	if (cnt == 3):
		at_element* elem = at_build_atom(pg_ast_child(node, 2))
		elem.label = pg_substr(g_at_source, node.first_token.offset, pg_ast_child(node, 1).last_token.offset + pg_ast_child(node, 1).last_token.length - node.first_token.offset)
		return elem
	return at_build_atom(pg_ast_child(node, 0))


at_element* at_build_real_element(pg_ast_node* node):
	at_element* elem = at_build_atom_from_labeled(pg_ast_child(node, 0))
	if (pg_ast_child_count(node) > 1):
		pg_ast_node* suffix_node = pg_ast_child(node, 1)
		elem.nongreedy = pg_ast_child_count(suffix_node) > 1
		pg_ast_node* suf_tok = pg_ast_child(suffix_node, 0)
		if (suf_tok.kind == antlr4_token_QUESTION):
			elem.suffix = '?'
		else if (suf_tok.kind == antlr4_token_STAR):
			elem.suffix = '*'
		else:
			elem.suffix = '+'
	return elem


# Semantic elements are retained in alt.sites with their atom position.
# Matching-only atoms remain separate for legacy best-effort classification.
at_element* at_build_element(pg_ast_node* node):
	pg_ast_node* inner = pg_ast_child(node, 0)
	if ((inner.kind == antlr4_ast_elem_option) || (inner.kind == antlr4_token_ACTION)):
		return 0
	return at_build_real_element(inner)


at_alt* at_build_alt(pg_ast_node* node):
	at_alt* alt = new at_alt()
	alt.elements = new list[at_element*]
	alt.sites = new list[at_site*]
	int cnt = pg_ast_child_count(node)
	int limit = cnt
	if (cnt > 0):
		if (pg_ast_child(node, cnt - 1).kind == antlr4_ast_alt_label):
			limit = cnt - 1
			alt.label = strclone(pg_ast_child(pg_ast_child(node, cnt - 1), 1).text)
	int i = 0
	while (i < limit):
		pg_ast_node* element_node = pg_ast_child(node, i)
		pg_ast_node* inner = pg_ast_child(element_node, 0)
		if (inner.kind == antlr4_ast_elem_option):
			alt.sites.push(at_build_site(inner, c"element option", alt.elements.length))
		else if (inner.kind == antlr4_token_ACTION):
			char* kind = c"action"
			if (inner.text[strlen(inner.text) - 1] == '?'): kind = c"predicate"
			alt.sites.push(at_build_site(inner, kind, alt.elements.length))
		at_element* elem = at_build_element(element_node)
		if (elem != 0):
			alt.elements.push(elem)
		i = i + 1
	return alt


list[at_alt*] at_build_altlist(pg_ast_node* node):
	list[at_alt*] alts = new list[at_alt*]
	alts.push(at_build_alt(pg_ast_child(node, 0)))
	int i = 1
	int cnt = pg_ast_child_count(node)
	while (i < cnt):
		pg_ast_node* tail = pg_ast_child(node, i)
		alts.push(at_build_alt(pg_ast_child(tail, 1)))
		i = i + 1
	return alts


int at_is_upper_first(char* name):
	return (name[0] >= 'A') & (name[0] <= 'Z')


at_rule* at_build_rule(pg_ast_node* node):
	int cnt = pg_ast_child_count(node)
	int is_fragment = 0
	int name_idx = 0
	if (pg_ast_child(node, 0).kind == antlr4_token_KW_FRAGMENT):
		is_fragment = 1
		name_idx = 1
	char* name = pg_ast_child(node, name_idx).text
	# Skip over rule_trailer_item* (params/returns/locals/throws/options)
	# by scanning forward for the altlist node itself, rather than assuming
	# a fixed offset -- there can be any number of trailer items.
	int altlist_idx = name_idx + 1
	while (pg_ast_child(node, altlist_idx).kind != antlr4_ast_altlist):
		altlist_idx = altlist_idx + 1
	pg_ast_node* altlist_node = pg_ast_child(node, altlist_idx)
	# Walk every command_item (ARROW a, b, c). Prefer a refused mode-like
	# command if any; else skip/channel for hidden; else type (allowed,
	# remap ignored); else the first name. Looking only at the first item
	# would let `-> type(X), mode(Y)` slip through once type is allowed.
	char* command = 0
	list[at_command*] commands = new list[at_command*]
	if (altlist_idx + 1 < cnt):
		pg_ast_node* maybe_cmd = pg_ast_child(node, altlist_idx + 1)
		if (maybe_cmd.kind == antlr4_ast_rule_command):
			char* first = 0
			char* hidden = 0
			char* type_cmd = 0
			char* refused = 0
			int ci = 1
			while (ci < pg_ast_child_count(maybe_cmd)):
				pg_ast_node* item_or_tail = pg_ast_child(maybe_cmd, ci)
				pg_ast_node* item = item_or_tail
				if (item_or_tail.kind == antlr4_ast_command_item_tail):
					# COMMA command_item
					item = pg_ast_child(item_or_tail, 1)
				if (item.kind == antlr4_ast_command_item):
					pg_ast_node* command_name_node = pg_ast_child(item, 0)
					char* cname = pg_ast_child(command_name_node, 0).text
					at_command* cmd = new at_command()
					cmd.name = strclone(cname)
					cmd.first = item.first_token
					cmd.last = item.last_token
					if (pg_ast_child_count(item) > 1):
						pg_ast_node* args_node = pg_ast_child(item, 1)
						cmd.argument = strclone(pg_ast_child(pg_ast_child(args_node, 1), 0).text)
					commands.push(cmd)
					if (first == 0):
						first = cname
					if ((strcmp(cname, c"mode") == 0) | (strcmp(cname, c"pushMode") == 0) | (strcmp(cname, c"popMode") == 0) | (strcmp(cname, c"more") == 0)):
						if (refused == 0):
							refused = cname
					else if ((strcmp(cname, c"skip") == 0) | (strcmp(cname, c"channel") == 0)):
						if (hidden == 0):
							hidden = cname
					else if (strcmp(cname, c"type") == 0):
						if (type_cmd == 0):
							type_cmd = cname
				ci = ci + 1
			if (refused != 0):
				command = strclone(refused)
			else if (hidden != 0):
				command = strclone(hidden)
			else if (type_cmd != 0):
				command = strclone(type_cmd)
			else if (first != 0):
				command = strclone(first)
	at_rule* rule = new at_rule()
	rule.name = strclone(name)
	rule.is_fragment = is_fragment
	rule.is_lexer = at_is_upper_first(name)
	rule.alts = at_build_altlist(altlist_node)
	rule.command = command
	rule.commands = commands
	rule.first = node.first_token
	rule.last = node.last_token
	rule.options = new list[at_site*]
	int ti = name_idx + 1
	while (ti < altlist_idx):
		pg_ast_node* trailer = pg_ast_child(node, ti)
		if (trailer.kind == antlr4_ast_rule_trailer_item):
			rule.options.push(at_build_site(trailer, c"rule option", 0))
		ti = ti + 1
	return rule


list[at_rule*] at_collect_rules(pg_ast_node* root):
	list[at_rule*] rules = new list[at_rule*]
	int n = pg_ast_child_count(root) - 1
	int i = 0
	char* active_mode = c"DEFAULT_MODE"
	while (i < n):
		pg_ast_node* item_node = pg_ast_child(root, i)
		pg_ast_node* inner = pg_ast_child(item_node, 0)
		if (inner.kind == antlr4_ast_rule_def):
			at_rule* rule = at_build_rule(inner)
			rule.mode = strclone(active_mode)
			# Multi-file directories sometimes hold independent grammars (not
			# just a lexer/parser pair). Keep the first definition of each
			# rule name and report later duplicates so merged inputs don't
			# emit colliding .pg symbols.
			if ((rule.name in g_seen_rule_names)):
				at_report(c"SKIPPED duplicate rule ", rule.name, c"already collected from an earlier input file")
			else:
				g_seen_rule_names[rule.name] = 1
				rules.push(rule)
		else if (inner.kind == antlr4_ast_mode_decl):
			active_mode = pg_ast_child(inner, 1).text
			g_at_dependencies.push(at_build_site(inner, c"mode declaration", 0))
		else if ((inner.kind == antlr4_ast_bare_marker) || (inner.kind == antlr4_ast_at_action) || (inner.kind == antlr4_ast_import_decl)):
			g_at_dependencies.push(at_build_site(inner, c"grammar dependency", 0))
		else if (inner.kind == antlr4_ast_grammar_decl):
			if (g_grammar_name == 0):
				int cnt = pg_ast_child_count(inner)
				g_grammar_name = strclone(pg_ast_child(inner, cnt - 2).text)
		i = i + 1
	return rules


