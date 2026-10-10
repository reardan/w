# Conservative semantic audit before lowering. It does not execute host code.
# Diagnostics have input/rule locations and deterministic input order. The
# legacy report is left stable; these losses are printed separately on stderr.
import libs.extras.grammars.antlr_to_pg.types
import lib.utf8

list[char*] g_at_loss_lines
map[char*, int] g_at_nullable
map[char*, at_rule*] g_at_rules
int g_at_structural_hazard

void at_loss(pg_token* location, char* rule_name, char* reason):
	char* filename = c"<grammar>"
	int line = 1
	int column = 1
	if (location != 0):
		filename = location.filename
		line = location.line
		column = location.column
	char* message = strclone(cstr(f"{filename}:{line}:{column}: semantic loss [{rule_name}]: {reason}"))
	g_at_loss_lines.push(message)
	g_at_semantic_losses = g_at_semantic_losses + 1


int at_audit_alts_nullable(list[at_alt*] alts);

int at_audit_atom_nullable(at_element* e):
	if (e.kind == 3): return at_audit_alts_nullable(e.group_alts)
	if (e.kind == 2):
		if (strcmp(e.text, c"EOF") == 0): return 1
		return e.text in g_at_nullable
	if ((e.kind == 0) && (e.text != 0)): return strlen(e.text) == 0
	return 0


int at_audit_element_nullable(at_element* e):
	if ((e.suffix == '?') || (e.suffix == '*')): return 1
	return at_audit_atom_nullable(e)


int at_audit_alts_nullable(list[at_alt*] alts):
	int ai = 0
	while (ai < alts.length):
		at_alt* alt = alts[ai]
		int nullable = 1
		int ei = 0
		while (ei < alt.elements.length):
			if (at_audit_element_nullable(alt.elements[ei]) == 0): nullable = 0
			ei = ei + 1
		if (nullable): return 1
		ai = ai + 1
	return 0


# Follow only nullable prefixes. Each DFS has its own visited set, so cycles
# involving nullable siblings cannot recurse indefinitely during the audit.
int at_audit_left_path(list[at_alt*] alts, char* target, map[char*, int] visited):
	int ai = 0
	while (ai < alts.length):
		at_alt* alt = alts[ai]
		int ei = 0
		while (ei < alt.elements.length):
			at_element* e = alt.elements[ei]
			if (e.kind == 2):
				if (strcmp(e.text, target) == 0): return 1
				if ((e.text in g_at_rules) && ((e.text in visited) == 0)):
					visited[e.text] = 1
					if (at_audit_left_path(g_at_rules[e.text].alts, target, visited)): return 1
			else if (e.kind == 3):
				if (at_audit_left_path(e.group_alts, target, visited)): return 1
			if (at_audit_element_nullable(e) == 0): break
			ei = ei + 1
		ai = ai + 1
	return 0


int at_audit_unicode(char* text):
	if (text == 0): return 0
	int i = 0
	while (text[i] != 0):
		int c = text[i]
		if ((c < 0) || (c > 127)): return 1
		if (c == 92):
			i = i + 1
			if (text[i] == 0): return 0
			if ((text[i] == 'p') || (text[i] == 'P')): return 1
			if (text[i] == 'u'):
				# Reject Unicode escapes conservatively, including escaped ASCII:
				# the legacy string unescaper does not decode them uniformly.
				return 1
		i = i + 1
	return 0


void at_audit_alts(at_rule* rule, list[at_alt*] alts):
	int ai = 0
	while (ai < alts.length):
		at_alt* alt = alts[ai]
		if (alt.sites != 0):
			int si = 0
			while (si < alt.sites.length):
				at_site* site = alt.sites[si]
				at_loss(site.first, rule.name, cstr(f"unmapped {site.kind} at atom position {site.position}: {site.raw}"))
				si = si + 1
		int ei = 0
		while (ei < alt.elements.length):
			at_element* e = alt.elements[ei]
			if (e.sites != 0):
				int si = 0
				while (si < e.sites.length):
					at_site* site = e.sites[si]
					at_loss(site.first, rule.name, cstr(f"unmapped {site.kind}: {site.raw}"))
					si = si + 1
			if ((e.kind == 2) && (strcmp(e.text, c"EOF") != 0)):
				if ((e.text in g_at_rules) == 0): at_loss(e.first, rule.name, cstr(f"unresolved rule/token reference {e.text}"))
			if (e.nongreedy): at_loss(e.first, rule.name, c"non-greedy matching requires an explicit adaptation")
			char* raw_atom = e.text
			if ((e.kind == 0) && (e.first != 0)): raw_atom = e.first.text
			if (at_audit_unicode(raw_atom)): at_loss(e.first, rule.name, c"Unicode escape/property or non-ASCII matching is not verified")
			if (((e.suffix == '*') || (e.suffix == '+')) && at_audit_atom_nullable(e)):
				at_loss(e.first, rule.name, c"zero-consumption repetition")
				g_at_structural_hazard = 1
			if (e.group_alts != 0): at_audit_alts(rule, e.group_alts)
			ei = ei + 1
		ai = ai + 1


# Returns 1 for structural hazards that must also stop best-effort generation.
int at_audit(list[at_rule*] rules):
	g_at_loss_lines = new list[char*]
	g_at_semantic_losses = 0
	g_at_structural_hazard = 0
	g_at_nullable = new map[char*, int]
	g_at_rules = new map[char*, at_rule*]
	int i = 0
	while (i < rules.length):
		g_at_rules[rules[i].name] = rules[i]
		i = i + 1
	int changed = 1
	while (changed):
		changed = 0
		i = 0
		while (i < rules.length):
			at_rule* rule = rules[i]
			if (((rule.name in g_at_nullable) == 0) && at_audit_alts_nullable(rule.alts)):
				g_at_nullable[rule.name] = 1
				changed = 1
			i = i + 1
	int unsafe = 0
	i = 0
	while (i < g_at_dependencies.length):
		at_site* site = g_at_dependencies[i]
		at_loss(site.first, c"<grammar>", cstr(f"unresolved {site.kind}: {site.raw}"))
		i = i + 1
	i = 0
	while (i < rules.length):
		at_rule* rule = rules[i]
		if (at_audit_left_path(rule.alts, rule.name, new map[char*, int])):
			at_loss(rule.first, rule.name, c"unsupported left recursion (including nullable prefixes)")
			unsafe = 1
		if (rule.is_lexer && (rule.name in g_at_nullable)):
			at_loss(rule.first, rule.name, c"zero-consumption lexer rule")
			unsafe = 1
		if ((rule.is_fragment == 0) && (strcmp(rule.mode, c"DEFAULT_MODE") != 0)): at_loss(rule.first, rule.name, cstr(f"lexer mode {rule.mode} is not lowered"))
		int ci = 0
		while (ci < rule.commands.length):
			at_command* cmd = rule.commands[ci]
			int supported = strcmp(cmd.name, c"skip") == 0
			if ((strcmp(cmd.name, c"channel") == 0) && (cmd.argument != 0)):
				supported = strcmp(cmd.argument, c"HIDDEN") == 0
			if (supported == 0):
				char* argument = cmd.argument
				if (argument == 0): argument = c""
				at_loss(cmd.first, rule.name, cstr(f"unsupported command {cmd.name}({argument})"))
			ci = ci + 1
		ci = 0
		while (ci < rule.options.length):
			at_site* site = rule.options[ci]
			at_loss(site.first, rule.name, cstr(f"unmapped rule option: {site.raw}"))
			ci = ci + 1
		at_audit_alts(rule, rule.alts)
		i = i + 1
	return unsafe || g_at_structural_hazard


void at_print_audit(char* path):
	string_builder* out = string_new()
	int i = 0
	while (i < g_at_loss_lines.length):
		string_append(out, g_at_loss_lines[i])
		string_append_char(out, 10)
		i = i + 1
	print2(out.data)
	if (path != 0): file_write_text(path, out.data)
	string_free(out)
