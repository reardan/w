/*
ANTLR4-to-pg translator: shared types, globals, and forward declarations.
Every other module in this directory imports this one; tools/antlr_to_pg.w
imports them all (in dependency order) after the antlr4.pg/pg.pg parsers
its build target generates. The translator walks the pg_ast_node tree
antlr4_parse() produces, re-derives the Rule/Alt/Element shape the old
antlr_to_pg.py worked with, then applies best-effort classification
(charset shapes, the ANTLR per-letter-case-fragment keyword idiom, group
lifting, inline literal collection) to emit .pg text. See README.md for
what this covers and its known gaps.
*/
import lib.lib
import lib.file
import lib.args
import structures.string
import libs.extras.parser_generator.runtime


type at_char_pred = fn(int) -> int


# Forward name for the recursive alternative/element tree.
struct at_alt:


# Semantic sites are retained separately from matching atoms. `position` is
# the number of preceding atoms in the containing alternative; order is stable.
struct at_site:
	char* kind
	char* raw
	pg_token* first
	pg_token* last
	int position
	int resolved


struct at_command:
	char* name
	char* argument
	pg_token* first
	pg_token* last


struct at_rule:
	char* name
	int is_fragment
	int is_lexer
	list[at_alt*] alts       # alternatives
	char* command          # legacy classifier summary; full ordered list below
	list[at_command*] commands
	list[at_site*] options
	char* mode
	pg_token* first
	pg_token* last


# kind: 0 lit, 1 charset, 2 ref, 3 group, 4 wildcard, 5 negated
struct at_element:
	int kind
	char* text             # for lit/charset/ref
	list[at_alt*] group_alts # group alternatives
	list[at_site*] sites
	char* label
	int nongreedy
	pg_token* first
	pg_token* last
	int suffix             # 0, '?', '*' or '+'


struct at_alt:
	list[at_element*] elements   # matching atoms
	list[at_site*] sites
	char* label
	char* source_rule
	int source_alternative
	pg_token* source_first
	char* source_lhs_label


struct at_classification:
	int kind                # 0 literal, 1 token, 2 skip, 3 drop, 4 unrecognized
	char* payload


# Stateful lowering preserves one entry per source lexer rule. Literal text
# is not an identity: two modes may assign different token kinds to it.
struct at_lowered_lexer:
	at_rule* source
	char* literal
	char* matcher


struct at_term:
	char* name
	int suffix
	char* label


map[char*, at_rule*] g_fragments
map[char*, at_rule*] g_lexer_rules
map[char*, int] g_all_rule_names
map[char*, int] g_used_names
map[char*, char*] g_text_to_name
map[char*, char*] g_literal_text
map[char*, list[at_alt*]] g_at_source_alts
map[char*, list[list[at_term*]]] g_rule_alts
map[char*, int] g_group_counter
map[char*, char*] g_name_remap
map[char*, int] g_parser_refs
map[char*, int] g_seen_rule_names
map[char*, char*] g_negset_text_to_name
list[char*] g_literal_order
list[char*] g_token_names
list[char*] g_token_matchers
list[char*] g_skip_names
list[char*] g_skip_matchers
list[char*] g_parser_rule_names
list[char*] g_report_lines
char* g_grammar_name
char* g_any_token_name
int g_negset_counter

# Called from modules that come before their definitions in the import
# order (tools/antlr_to_pg.w): classify.w defines at_report, matchers_emit.w
# the other two.
void at_lowering_finding(char* rule_name, char* code, char* feature, char* reason);
void at_report(char* prefix, char* rule_name, char* payload);
void at_loss_code(pg_token* location, char* rule_name, char* code, char* feature, char* classification, char* reason);
void at_loss(pg_token* location, char* rule_name, char* reason);
char* at_try_generate_matcher(at_rule* rule);
void at_emit_c_char_literal(string_builder* out, int c);




# Current input is borrowed only while collecting its owned semantic text.
char* g_at_source
list[at_site*] g_at_dependencies
int g_at_semantic_losses
int g_at_stateful
int g_at_exact_lexer

int at_exact_supported(at_rule* rule);
int g_at_prediction
int at_exact_case(at_rule* rule);
void at_exact_audit_rule(at_rule* rule);
int at_exact_unicode_atom(at_rule* rule, at_element* element);
list[char*] g_at_modes
list[char*] g_at_channels
list[char*] g_at_declared_modes
list[at_lowered_lexer*] g_at_lowered_lexer
list[char*] g_at_token_identities
list[at_rule*] g_at_source_rules


int at_has_token_identity(char* name):
	if (g_at_token_identities == 0): return 0
	for char* identity in g_at_token_identities:
		if (strcmp(identity, name) == 0): return 1
	return 0


int at_custom_channel(char* name):
	if ((name == 0) || (g_at_channels == 0)): return 0
	for char* channel in g_at_channels:
		if (strcmp(name, channel) == 0): return 1
	return 0


int at_stateful_has_mode(char* name):
	if (name == 0): return 0
	if (strcmp(name, c"DEFAULT_MODE") == 0): return 1
	if (g_at_modes == 0): return 0
	for char* mode in g_at_modes:
		if (strcmp(mode, name) == 0): return 1
	return 0


int at_stateful_command_supported(at_command* command):
	char* name = command.name
	char* argument = command.argument
	if ((strcmp(name, c"skip") == 0) || (strcmp(name, c"popMode") == 0) || (strcmp(name, c"more") == 0)):
		return argument == 0
	if ((strcmp(name, c"mode") == 0) || (strcmp(name, c"pushMode") == 0)):
		return at_stateful_has_mode(argument)
	if (strcmp(name, c"type") == 0):
		return argument != 0
	if ((strcmp(name, c"channel") == 0) && (argument != 0)):
		return (strcmp(argument, c"HIDDEN") == 0) || (strcmp(argument, c"DEFAULT_TOKEN_CHANNEL") == 0) || at_custom_channel(argument)
	return 0


# Best-effort emission may omit a loss already recorded by the audit, but
# must not emit a command the downstream .pg validator cannot represent.
int at_stateful_command_emittable(at_rule* rule, int index):
	at_command* command = rule.commands[index]
	if (at_stateful_command_supported(command) == 0): return 0
	if (strcmp(command.name, c"type") == 0):
		at_rule* target = g_lexer_rules.get(command.argument, 0)
		if (target == 0):
			if (at_has_token_identity(command.argument) == 0): return 0
		else if (target.is_fragment): return 0
	for i in range(index):
		at_command* previous = rule.commands[i]
		if (at_stateful_command_supported(previous) == 0): continue
		if (strcmp(previous.name, command.name) == 0): return 0
		int output_before = (strcmp(previous.name, c"skip") == 0) || (strcmp(previous.name, c"channel") == 0)
		int output_now = (strcmp(command.name, c"skip") == 0) || (strcmp(command.name, c"channel") == 0)
		if (output_before && output_now): return 0
		if ((strcmp(previous.name, c"more") == 0) && ((strcmp(command.name, c"type") == 0) || (strcmp(command.name, c"skip") == 0))): return 0
		if ((strcmp(command.name, c"more") == 0) && ((strcmp(previous.name, c"type") == 0) || (strcmp(previous.name, c"skip") == 0))): return 0
	return 1


void at_prepare_stateful(list[at_rule*] rules, int requested):
	g_at_source_rules = rules
	g_at_stateful = requested
	g_at_modes = new list[char*]
	g_at_lowered_lexer = new list[at_lowered_lexer*]
	if (g_at_token_identities != 0):
		if (g_at_token_identities.length > 0): g_at_stateful = 1
	if (g_at_declared_modes != 0):
		for char* mode in g_at_declared_modes:
			if (at_stateful_has_mode(mode) == 0): g_at_modes.push(mode)
		if (g_at_declared_modes.length > 0): g_at_stateful = 1
	for at_rule* rule in rules:
		if (rule.is_lexer == 0): continue
		if ((rule.mode != 0) && (strcmp(rule.mode, c"DEFAULT_MODE") != 0)):
			g_at_stateful = 1
			if (at_stateful_has_mode(rule.mode) == 0): g_at_modes.push(rule.mode)
		for at_command* command in rule.commands:
			if ((strcmp(command.name, c"skip") != 0) && (strcmp(command.name, c"channel") != 0)):
				g_at_stateful = 1
			if ((strcmp(command.name, c"channel") == 0) && (command.argument != 0)):
				if (strcmp(command.argument, c"HIDDEN") != 0): g_at_stateful = 1
