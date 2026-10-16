# Conservative semantic audit before lowering. It does not execute host code.
# Diagnostics have input/rule locations and deterministic input order. The
# legacy report is left stable; these losses are printed separately on stderr.
import libs.extras.grammars.antlr_to_pg.types
import libs.extras.grammars.antlr_to_pg.lexer_ir
import libs.extras.grammars.antlr_to_pg.matchers_ascii
import lib.utf8
import libs.extras.grammars.antlr_to_pg.audit_json

list[char*] g_at_loss_lines
map[char*, int] g_at_nullable
map[char*, int] g_at_nullable_without_eof
map[char*, at_rule*] g_at_rules
int g_at_structural_hazard

void at_loss_code(pg_token* location, char* rule_name, char* code, char* feature, char* classification, char* reason):
	char* filename = c"<grammar>"
	int line = 1
	int column = 1
	if (location != 0):
		filename = location.filename
		line = location.line
		column = location.column
	at_finding(code, c"translate", feature, classification, filename, line, column, rule_name, reason)
	char* message = strclone(cstr(f"{filename}:{line}:{column}: semantic loss [{rule_name}]: {reason}"))
	g_at_loss_lines.push(message)
	g_at_semantic_losses = g_at_semantic_losses + 1


void at_loss(pg_token* location, char* rule_name, char* reason):
	at_loss_code(location, rule_name, c"AT_UNMAPPED", c"lowering", c"unproven", reason)


# Context 0 counts parser tokens, 1 lexer bytes, 2 lexer bytes without EOF.
int at_audit_alts_nullable_in(list[at_alt*] alts, int context);

int at_audit_atom_nullable_in(at_element* e, int context):
	if (e.kind == 3): return at_audit_alts_nullable_in(e.group_alts, context)
	if (e.kind == 2):
		if (strcmp(e.text, c"EOF") == 0): return context != 2
		at_rule* target = g_at_rules.get(e.text, 0)
		if ((context == 0) && (target != 0) && target.is_lexer): return 0
		if (context == 2): return e.text in g_at_nullable_without_eof
		return e.text in g_at_nullable
	if ((e.kind == 0) && (e.text != 0)): return strlen(e.text) == 0
	return 0

int at_audit_element_nullable_in(at_element* e, int context):
	if ((e.suffix == '?') || (e.suffix == '*')): return 1
	return at_audit_atom_nullable_in(e, context)

int at_audit_alts_nullable_in(list[at_alt*] alts, int context):
	for at_alt* alt in alts:
		int nullable = 1
		for at_element* element in alt.elements:
			if (at_audit_element_nullable_in(element, context) == 0): nullable = 0
		if (nullable): return 1
	return 0

# Normalization is parser-only: a lexer rule reference consumes one token,
# even when that token matches EOF and has a zero-byte source span.
int at_audit_atom_nullable(at_element* e):
	return at_audit_atom_nullable_in(e, 0)

int at_audit_element_nullable(at_element* e):
	return at_audit_element_nullable_in(e, 0)

int at_audit_alts_nullable(list[at_alt*] alts):
	return at_audit_alts_nullable_in(alts, 0)


# Follow only nullable prefixes. Each DFS has its own visited set, so cycles
# involving nullable siblings cannot recurse indefinitely during the audit.
int at_audit_left_path(list[at_alt*] alts, char* target, map[char*, int] visited):
	int context = 0
	if (target in g_at_rules): context = g_at_rules[target].is_lexer
	int ai = 0
	while (ai < alts.length):
		at_alt* alt = alts[ai]
		int ei = 0
		while (ei < alt.elements.length):
			at_element* e = alt.elements[ei]
			if (e.kind == 2):
				if (strcmp(e.text, target) == 0): return 1
				if ((e.text in g_at_rules) && ((e.text in visited) == 0) && (context || (g_at_rules[e.text].is_lexer == 0))):
					visited[e.text] = 1
					if (at_audit_left_path(g_at_rules[e.text].alts, target, visited)): return 1
			else if (e.kind == 3):
				if (at_audit_left_path(e.group_alts, target, visited)): return 1
			if (at_audit_element_nullable_in(e, context) == 0): break
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


void at_audit_stateful_parser_literal(at_rule* owner, at_element* element):
	int matches = 0
	for at_rule* candidate in g_at_source_rules:
		if ((candidate.is_lexer == 0) || candidate.is_fragment): continue
		if ((candidate.alts.length != 1) || (candidate.alts[0].elements.length != 1)): continue
		at_element* literal = candidate.alts[0].elements[0]
		if ((literal.kind != 0) || (literal.suffix != 0)): continue
		if (strcmp(literal.text, element.text) != 0): continue
		matches++
		for at_command* command in candidate.commands:
			if ((strcmp(command.name, c"type") == 0) || (strcmp(command.name, c"more") == 0)):
				at_loss_code(element.first, owner.name, c"AT_TOKEN_REMAP", c"token_identity", c"unproven", c"parser literal aliases a remapped or accumulated lexer rule")
	if (matches > 1): at_loss_code(element.first, owner.name, c"AT_TOKEN_AMBIGUITY", c"token_identity", c"unproven", c"parser literal has ambiguous lexer token identities")


int at_stateful_fixed_width_alts(list[at_alt*] alts, int depth);
int at_stateful_atom_width(at_element* element, int depth);


int at_stateful_fixed_width(at_element* element, int depth):
	if ((depth > 32) || (element.suffix != 0)): return -1
	return at_stateful_atom_width(element, depth)


int at_stateful_atom_width(at_element* element, int depth):
	if (depth > 32): return -1
	if (element.kind == 0): return strlen(element.text)
	if ((element.kind == 1) || (element.kind == 4) || (element.kind == 5)): return 1
	if (element.kind == 3): return at_stateful_fixed_width_alts(element.group_alts, depth + 1)
	if (element.kind == 2):
		at_rule* referenced = g_at_rules.get(element.text, 0)
		if (referenced != 0): return at_stateful_fixed_width_alts(referenced.alts, depth + 1)
	return -1


int at_stateful_fixed_width_alts(list[at_alt*] alts, int depth):
	int width = -1
	for at_alt* alt in alts:
		int total = 0
		for at_element* element in alt.elements:
			int part = at_stateful_fixed_width(element, depth)
			if (part < 0): return -1
			total = total + part
		if ((width >= 0) && (width != total)): return -1
		width = total
	return width


int at_stateful_charset_contains(at_element* element, int value):
	if (((element.kind != 1) && (element.kind != 5)) || (element.text == 0)): return -1
	char* charset = element.text
	int negated = element.kind == 5
	int index = 1
	if (charset[index] == '^'):
		negated = negated == 0
		index++
	int end = strlen(charset) - 1
	int contains = 0
	while (index < end):
		int advance = 1
		int low = cast(int, charset[index]) & 255
		if (low == 92): low = at_parse_charset_escape(charset, index, end, &advance)
		if ((low < 0) || (advance <= 0)): return -1
		index = index + advance
		int high = low
		if ((index + 1 < end) && (charset[index] == '-')):
			index++
			advance = 1
			high = cast(int, charset[index]) & 255
			if (high == 92): high = at_parse_charset_escape(charset, index, end, &advance)
			if ((high < 0) || (advance <= 0)): return -1
			index = index + advance
		if ((value >= low) && (value <= high)): contains = 1
	if (negated): return contains == 0
	return contains


int at_stateful_alts_start_byte(list[at_alt*] alts, int value, int depth);


int at_stateful_atom_starts_byte(at_element* element, int value, int depth):
	if (depth > 32): return 1
	if (element.kind == 0):
		if (strlen(element.text) == 0): return 0
		return (cast(int, element.text[0]) & 255) == value
	if ((element.kind == 1) || (element.kind == 5)):
		return at_stateful_charset_contains(element, value) != 0
	if (element.kind == 3): return at_stateful_alts_start_byte(element.group_alts, value, depth + 1)
	if (element.kind == 2):
		at_rule* rule = g_at_rules.get(element.text, 0)
		if (rule != 0): return at_stateful_alts_start_byte(rule.alts, value, depth + 1)
	return 1


int at_stateful_alt_starts_byte(at_alt* alt, int value, int depth):
	for at_element* element in alt.elements:
		if (at_stateful_atom_starts_byte(element, value, depth)): return 1
		if (at_audit_element_nullable_in(element, 1) == 0): return 0
	return 0


int at_stateful_alts_start_byte(list[at_alt*] alts, int value, int depth):
	for at_alt* alt in alts:
		if (at_stateful_alt_starts_byte(alt, value, depth)): return 1
	return 0


# A repeated body is safe when it has a fixed width, or each alternative
# has a fixed width and their first-byte sets are disjoint. The latter
# admits escaped-character versus plain-character string bodies without
# guessing which of two overlapping variable-length alternatives to take.
int at_stateful_prefix_free_body(at_element* element):
	if (at_stateful_atom_width(element, 0) >= 0): return 1
	list[at_alt*] alts = 0
	if (element.kind == 3): alts = element.group_alts
	else if (element.kind == 2):
		at_rule* rule = g_at_rules.get(element.text, 0)
		if (rule != 0): alts = rule.alts
	if (alts == 0): return 0
	for i, alt in alts:
		for at_element* part in alt.elements:
			if (at_stateful_fixed_width(part, 0) < 0): return 0
		for j in range(i):
			for value in range(1, 256):
				if (at_stateful_alt_starts_byte(alt, value, 0) && at_stateful_alt_starts_byte(alts[j], value, 0)): return 0
	return 1


# A prefix-free repeated body cannot consume a delimiter absent from its
# first-byte set. This proves common quoted strings and optional CR + LF.
int at_stateful_disjoint_delimiter(at_element* element, at_element* following):
	if ((element.suffix == 0) || (following.kind != 0) || (following.suffix != 0)): return 0
	if (strlen(following.text) == 0): return 0
	if (at_stateful_prefix_free_body(element) == 0): return 0
	int delimiter = cast(int, following.text[0]) & 255
	return at_stateful_atom_starts_byte(element, delimiter, 0) == 0


void at_audit_alts(at_rule* rule, list[at_alt*] alts):
	int ai = 0
	while (ai < alts.length):
		at_alt* alt = alts[ai]
		if (alt.sites != 0):
			int si = 0
			while (si < alt.sites.length):
				at_site* site = alt.sites[si]
				at_loss_code(site.first, rule.name, c"AT_HOST_SITE", c"host_code", c"unsupported", cstr(f"unmapped {site.kind} at atom position {site.position}: {site.raw}"))
				si = si + 1
		int ei = 0
		while (ei < alt.elements.length):
			at_element* e = alt.elements[ei]
			if (g_at_stateful && (at_exact_supported(rule) == 0) && rule.is_lexer && ((e.suffix == '*') || (e.suffix == '+'))):
				if (at_stateful_prefix_free_body(e) == 0):
					at_loss_code(e.first, rule.name, c"AT_LEXER_REPEAT", c"lexer_repetition", c"unproven", c"variable-width lexer repetition requires a prefix-free body proof")
			if (g_at_stateful && (at_exact_supported(rule) == 0) && rule.is_lexer && (ei + 1 < alt.elements.length)):
				if ((at_stateful_fixed_width(e, 0) < 0) && (at_stateful_disjoint_delimiter(e, alt.elements[ei + 1]) == 0)):
					at_loss_code(e.first, rule.name, c"AT_LEXER_CONTINUATION", c"lexer_continuation", c"unproven", c"variable-width lexer continuation requires a backtracking proof")
			if (g_at_stateful && (rule.is_lexer == 0) && (e.kind == 0)):
				at_audit_stateful_parser_literal(rule, e)
			if (g_at_stateful && (rule.is_lexer == 0) && ((e.kind == 4) || (e.kind == 5))):
				at_loss_code(e.first, rule.name, c"AT_PARSER_TOKEN_SET", c"parser_token_set", c"unsupported", c"parser wildcard/token negation requires token-level lowering")
			if (e.sites != 0):
				int si = 0
				while (si < e.sites.length):
					at_site* site = e.sites[si]
					at_loss_code(site.first, rule.name, c"AT_HOST_SITE", c"host_code", c"unsupported", cstr(f"unmapped {site.kind}: {site.raw}"))
					si = si + 1
			if ((e.kind == 2) && (strcmp(e.text, c"EOF") != 0)):
				if (((e.text in g_at_rules) == 0) && (at_has_token_identity(e.text) == 0)): at_loss_code(e.first, rule.name, c"AT_UNDEFINED_SYMBOL", c"token_identity", c"unsupported", cstr(f"unresolved rule/token reference {e.text}"))
			if (e.nongreedy && (at_exact_supported(rule) == 0)): at_loss_code(e.first, rule.name, c"AT_NONGREEDY", c"nongreedy", c"unsupported", c"non-greedy matching requires an explicit adaptation")
			char* raw_atom = e.text
			if ((e.kind == 0) && (e.first != 0)): raw_atom = e.first.text
			if (at_audit_unicode(raw_atom)): at_loss_code(e.first, rule.name, c"AT_UNICODE", c"unicode", c"unproven", c"Unicode escape/property or non-ASCII matching is not verified")
			if (((e.suffix == '*') || (e.suffix == '+')) && at_audit_atom_nullable_in(e, rule.is_lexer)):
				at_loss_code(e.first, rule.name, c"AT_NULLABLE_REPEAT", c"nullable_repetition", c"invalid", c"zero-consumption repetition")
				g_at_structural_hazard = 1
			if (e.group_alts != 0): at_audit_alts(rule, e.group_alts)
			ei = ei + 1
		ai = ai + 1


# Shared fixed-point facts for conservative normalization and the final audit.
# Normalization must rerun the audit after changing the IR.
void at_audit_prepare_rules(list[at_rule*] rules):
	g_at_nullable = new map[char*, int]
	g_at_nullable_without_eof = new map[char*, int]
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
			if (rule.is_lexer && ((rule.name in g_at_nullable_without_eof) == 0) && at_audit_alts_nullable_in(rule.alts, 2)):
				g_at_nullable_without_eof[rule.name] = 1
				changed = 1
			if (((rule.name in g_at_nullable) == 0) && at_audit_alts_nullable_in(rule.alts, rule.is_lexer)):
				g_at_nullable[rule.name] = 1
				changed = 1
			i = i + 1


# Returns 1 for structural hazards that must also stop best-effort generation.
int at_audit(list[at_rule*] rules):
	g_at_loss_lines = new list[char*]
	g_at_semantic_losses = 0
	g_at_structural_hazard = 0
	at_audit_prepare_rules(rules)
	int i = 0
	int unsafe = 0
	i = 0
	while (i < g_at_dependencies.length):
		at_site* site = g_at_dependencies[i]
		if ((site.resolved == 0) && ((g_at_stateful == 0) || (strcmp(site.kind, c"mode declaration") != 0))):
			at_loss_code(site.first, c"<grammar>", c"AT_DECLARATION", c"declaration", c"unsupported", cstr(f"unresolved {site.kind}: {site.raw}"))
		i = i + 1
	i = 0
	while (i < rules.length):
		at_rule* rule = rules[i]
		if (at_audit_left_path(rule.alts, rule.name, new map[char*, int])):
			at_loss_code(rule.first, rule.name, c"AT_LEFT_RECURSION", c"left_recursion", c"unsupported", c"unsupported left recursion (including nullable prefixes)")
			unsafe = 1
		if (rule.is_lexer && (rule.is_fragment == 0) && (rule.name in g_at_nullable) && ((at_exact_supported(rule) == 0) || (rule.name in g_at_nullable_without_eof))):
			at_loss_code(rule.first, rule.name, c"AT_LEXER_EMPTY", c"lexer_progress", c"unsupported", c"zero-consumption lexer rule")
			unsafe = 1
		if ((g_at_stateful == 0) && (rule.is_fragment == 0) && (strcmp(rule.mode, c"DEFAULT_MODE") != 0)): at_loss_code(rule.first, rule.name, c"AT_LEXER_MODE", c"lexer_mode", c"unsupported", cstr(f"lexer mode {rule.mode} is not lowered"))
		int ci = 0
		while (ci < rule.commands.length):
			at_command* cmd = rule.commands[ci]
			int supported = strcmp(cmd.name, c"skip") == 0
			if ((strcmp(cmd.name, c"channel") == 0) && (cmd.argument != 0)):
				supported = strcmp(cmd.argument, c"HIDDEN") == 0
			if (g_at_stateful): supported = at_stateful_command_supported(cmd)
			if (g_at_stateful && (strcmp(cmd.name, c"type") == 0) && (cmd.argument != 0)):
				at_rule* target = g_at_rules.get(cmd.argument, 0)
				if (target == 0): supported = at_has_token_identity(cmd.argument)
				else if ((target.is_lexer == 0) || target.is_fragment): supported = 0
			if (supported == 0):
				char* argument = cmd.argument
				if (argument == 0): argument = c""
				at_loss_code(cmd.first, rule.name, c"AT_LEXER_COMMAND", c"lexer_command", c"unsupported", cstr(f"unsupported command {cmd.name}({argument})"))
			if (g_at_stateful):
				int cj = 0
				while (cj < ci):
					char* previous = rule.commands[cj].name
					int duplicate = strcmp(previous, cmd.name) == 0
					int output_before = (strcmp(previous, c"skip") == 0) || (strcmp(previous, c"channel") == 0)
					int output_now = (strcmp(cmd.name, c"skip") == 0) || (strcmp(cmd.name, c"channel") == 0)
					int more_conflict = ((strcmp(previous, c"more") == 0) && ((strcmp(cmd.name, c"type") == 0) || (strcmp(cmd.name, c"skip") == 0))) || ((strcmp(cmd.name, c"more") == 0) && ((strcmp(previous, c"type") == 0) || (strcmp(previous, c"skip") == 0)))
					if (duplicate || (output_before && output_now) || more_conflict):
						at_loss_code(cmd.first, rule.name, c"AT_LEXER_COMMAND_CONFLICT", c"lexer_command", c"invalid", c"conflicting or repeated lexer commands")
					cj = cj + 1
			ci = ci + 1
		ci = 0
		while (ci < rule.options.length):
			at_site* site = rule.options[ci]
			at_loss_code(site.first, rule.name, c"AT_RULE_OPTION", c"rule_option", c"unsupported", cstr(f"unmapped rule option: {site.raw}"))
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
