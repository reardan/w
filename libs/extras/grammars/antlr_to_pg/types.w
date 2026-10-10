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


struct at_classification:
	int kind                # 0 literal, 1 token, 2 skip, 3 drop, 4 unrecognized
	char* payload


struct at_term:
	char* name
	int suffix


map[char*, at_rule*] g_fragments
map[char*, at_rule*] g_lexer_rules
map[char*, int] g_all_rule_names
map[char*, int] g_used_names
map[char*, char*] g_text_to_name
map[char*, char*] g_literal_text
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
void at_report(char* prefix, char* rule_name, char* payload);
void at_loss(pg_token* location, char* rule_name, char* reason);
char* at_try_generate_matcher(at_rule* rule);
void at_emit_c_char_literal(string_builder* out, int c);




# Current input is borrowed only while collecting its owned semantic text.
char* g_at_source
list[at_site*] g_at_dependencies
int g_at_semantic_losses
