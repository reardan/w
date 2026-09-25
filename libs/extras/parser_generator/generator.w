/*
W source generator for the first ParserGenerator milestone.

Output lines are assembled with f-strings (pg_line / pg_open / pg_add).
Grammar names (parser, tokens, literals, rules) are identifiers, which
W string escaping leaves unchanged, so they are spliced into c"..."
literals verbatim; matcher string texts, which may hold quotes or
backslashes, go through pg_c_literal.
*/
import lib.lib
import lib.container
import structures.string
import libs.extras.parser_generator.token
import libs.extras.parser_generator.grammar_model
import libs.extras.parser_generator.analysis
import libs.extras.parser_generator.lexer
import libs.extras.parser_generator.source_writer


# Detach an f-string's NUL-terminated bytes from its descriptor.
char* pg_take(string text):
	char* data = text.data
	free(cast(char*, cast(int, text)))
	return data


# Append a line fragment (no indent, no newline). Takes ownership of
# text: pass f-string results only, never a static "..." literal.
void pg_add(pg_source_writer* writer, string text):
	char* data = pg_take(text)
	pg_source_append(writer, data)
	free(data)


# One output line at the current indent; takes ownership like pg_add.
void pg_line(pg_source_writer* writer, string text):
	pg_source_tabs(writer)
	pg_add(writer, text)
	pg_source_append_char(writer, 10)


# pg_line followed by an indent: the header of a nested block.
void pg_open(pg_source_writer* writer, string text):
	pg_line(writer, text)
	pg_source_indent(writer)


# Constant-text pg_open.
void pg_open_c(pg_source_writer* writer, char* text):
	pg_source_line(writer, text)
	pg_source_indent(writer)


# c"<text>" with W string escaping. Caller frees.
char* pg_c_literal(char* text):
	pg_source_writer* literal = pg_source_writer_new()
	pg_source_append_char(literal, 'c')
	pg_source_append_w_string(literal, text)
	return pg_source_take(literal)


# "<g>_match_token(stream, <kind>, c"<name>")" for a token term, else
# "<g>_parse_<name>(stream, diagnostics)". Caller frees.
char* pg_term_call(pg_grammar* grammar, pg_term* term):
	char* g = grammar.name
	if (pg_grammar_is_token_term(grammar, term.name)):
		return pg_take(f"{g}_match_token(stream, {g}_token_{term.name}, c\"{term.name}\")")
	return pg_take(f"{g}_parse_{term.name}(stream, diagnostics)")


# Extra "import <dotted.path>" lines from the grammar's own "import"
# directives (issue #329 milestone 4). Actions/predicates that call
# host-provided functions declare the module providing them this way; a
# grammar that declares none (every grammar before milestone 4) emits
# nothing extra here, so its generated output is unaffected.
void pg_emit_grammar_imports(pg_source_writer* writer, pg_grammar* grammar):
	for char* path in grammar.imports:
		pg_line(writer, f"import {path}")
	if (grammar.imports.length > 0):
		pg_source_blank(writer)


int pg_matcher_reference_is_expression(pg_grammar* grammar, char* name):
	pg_token_def* token = pg_grammar_find_token(grammar, name)
	if (token != 0):
		return token.expression != 0
	return pg_grammar_find_fragment(grammar, name) != 0


# The call matching a referenced token or fragment at `position`: the
# built-in pg_lexer_matcher_* helper for a token defined by one, else the
# generated expression matcher. Caller frees.
char* pg_matcher_reference_call(pg_grammar* grammar, char* name):
	pg_token_def* token = pg_grammar_find_token(grammar, name)
	if ((token != 0) && (token.expression == 0)):
		return pg_take(f"pg_lexer_matcher_{token.matcher}(input, position)")
	return pg_take(f"{grammar.name}_matcher_{name}(input, position)")


# Membership test of the current byte against a charset, as a
# disjunction of byte ranges. Short-circuit spellings: the operands are
# pure comparisons of the matcher_char_ local, so '||'/'&&' change only
# how many comparisons run, never what matches. Caller frees.
char* pg_matcher_charset_condition(pg_match_expr* expression, int temp):
	pg_source_writer* out = pg_source_writer_new()
	int first_condition = 1
	int start = 1
	while (start < 128):
		if (expression.charset[start] == 0):
			start = start + 1
		else:
			int end = start
			while ((end + 1 < 128) && (expression.charset[end + 1] != 0)):
				end = end + 1
			if (first_condition == 0):
				pg_source_append(out, c" || ")
			if (start == end):
				pg_add(out, f"(matcher_char_{temp} == {start})")
			else:
				pg_add(out, f"((matcher_char_{temp} >= {start}) && (matcher_char_{temp} <= {end}))")
			first_condition = 0
			start = end + 1
	if (first_condition):
		pg_source_append_char(out, '0')
	return pg_source_take(out)


void pg_emit_match_expression(pg_source_writer* writer, pg_grammar* grammar, pg_match_expr* expression, int* next_temp);


# "else: matched = 0", closing the "if (matched):" block that every
# matcher step opens.
void pg_emit_matcher_step_end(pg_source_writer* writer):
	pg_source_dedent(writer)
	pg_open_c(writer, c"else:")
	pg_source_line(writer, c"matched = 0")
	pg_source_dedent(writer)
	pg_source_dedent(writer)


void pg_emit_matcher_string(pg_source_writer* writer, pg_match_expr* expression):
	pg_open_c(writer, c"if (matched):")
	char* literal = pg_c_literal(expression.text)
	pg_open(writer, f"if (starts_with(input + position, {literal})):")
	free(literal)
	pg_line(writer, f"position = position + {strlen(expression.text)}")
	pg_emit_matcher_step_end(writer)


void pg_emit_matcher_charset(pg_source_writer* writer, pg_match_expr* expression, int* next_temp):
	int temp = next_temp[0]
	next_temp[0] = temp + 1
	pg_open_c(writer, c"if (matched):")
	pg_line(writer, f"int matcher_char_{temp} = input[position] & 255")
	char* condition = pg_matcher_charset_condition(expression, temp)
	pg_open(writer, f"if ({condition}):")
	free(condition)
	pg_source_line(writer, c"position = position + 1")
	pg_emit_matcher_step_end(writer)


void pg_emit_matcher_reference(pg_source_writer* writer, pg_grammar* grammar, pg_match_expr* expression, int* next_temp):
	int temp = next_temp[0]
	next_temp[0] = temp + 1
	pg_open_c(writer, c"if (matched):")
	char* call = pg_matcher_reference_call(grammar, expression.text)
	pg_line(writer, f"int matcher_length_{temp} = {call}")
	free(call)
	char* bound = c" > 0"
	if (pg_matcher_reference_is_expression(grammar, expression.text)):
		bound = c" >= 0"
	pg_open(writer, f"if (matcher_length_{temp}{bound}):")
	pg_line(writer, f"position = position + matcher_length_{temp}")
	pg_emit_matcher_step_end(writer)


void pg_emit_matcher_alternation(pg_source_writer* writer, pg_grammar* grammar, pg_match_expr* expression, int* next_temp):
	int temp = next_temp[0]
	next_temp[0] = temp + 1
	pg_open_c(writer, c"if (matched):")
	pg_line(writer, f"int matcher_start_{temp} = position")
	pg_line(writer, f"int matcher_best_{temp} = -1")
	for pg_match_expr* child in expression.children:
		pg_line(writer, f"position = matcher_start_{temp}")
		pg_source_line(writer, c"matched = 1")
		pg_emit_match_expression(writer, grammar, child, next_temp)
		pg_open_c(writer, c"if (matched):")
		pg_open(writer, f"if (position > matcher_best_{temp}):")
		pg_line(writer, f"matcher_best_{temp} = position")
		pg_source_dedent(writer)
		pg_source_dedent(writer)
	pg_open(writer, f"if (matcher_best_{temp} >= 0):")
	pg_line(writer, f"position = matcher_best_{temp}")
	pg_source_line(writer, c"matched = 1")
	pg_source_dedent(writer)
	pg_open_c(writer, c"else:")
	pg_line(writer, f"position = matcher_start_{temp}")
	pg_source_line(writer, c"matched = 0")
	pg_source_dedent(writer)
	pg_source_dedent(writer)


void pg_emit_matcher_optional(pg_source_writer* writer, pg_grammar* grammar, pg_match_expr* expression, int* next_temp):
	int temp = next_temp[0]
	next_temp[0] = temp + 1
	pg_open_c(writer, c"if (matched):")
	pg_line(writer, f"int matcher_start_{temp} = position")
	pg_emit_match_expression(writer, grammar, expression.children[0], next_temp)
	pg_open_c(writer, c"if (matched == 0):")
	pg_line(writer, f"position = matcher_start_{temp}")
	pg_source_line(writer, c"matched = 1")
	pg_source_dedent(writer)
	pg_source_dedent(writer)


void pg_emit_matcher_repeat_tail(pg_source_writer* writer, pg_grammar* grammar, pg_match_expr* child, int* next_temp):
	int temp = next_temp[0]
	next_temp[0] = temp + 1
	pg_line(writer, f"int matcher_repeating_{temp} = 1")
	pg_open(writer, f"while (matcher_repeating_{temp}):")
	pg_line(writer, f"int matcher_start_{temp} = position")
	pg_source_line(writer, c"matched = 1")
	pg_emit_match_expression(writer, grammar, child, next_temp)
	pg_open_c(writer, c"if (matched == 0):")
	pg_line(writer, f"position = matcher_start_{temp}")
	pg_source_line(writer, c"matched = 1")
	pg_line(writer, f"matcher_repeating_{temp} = 0")
	pg_source_dedent(writer)
	pg_source_dedent(writer)


void pg_emit_matcher_repetition(pg_source_writer* writer, pg_grammar* grammar, pg_match_expr* expression, int* next_temp):
	pg_open_c(writer, c"if (matched):")
	if (expression.kind == pg_match_expr_one_or_more_kind()):
		pg_emit_match_expression(writer, grammar, expression.children[0], next_temp)
		pg_open_c(writer, c"if (matched):")
		pg_emit_matcher_repeat_tail(writer, grammar, expression.children[0], next_temp)
		pg_source_dedent(writer)
	else:
		pg_emit_matcher_repeat_tail(writer, grammar, expression.children[0], next_temp)
	pg_source_dedent(writer)


void pg_emit_match_expression(pg_source_writer* writer, pg_grammar* grammar, pg_match_expr* expression, int* next_temp):
	if (expression.kind == pg_match_expr_string_kind()):
		pg_emit_matcher_string(writer, expression)
	else if (expression.kind == pg_match_expr_charset_kind()):
		pg_emit_matcher_charset(writer, expression, next_temp)
	else if (expression.kind == pg_match_expr_reference_kind()):
		pg_emit_matcher_reference(writer, grammar, expression, next_temp)
	else if (expression.kind == pg_match_expr_sequence_kind()):
		for pg_match_expr* child in expression.children:
			pg_emit_match_expression(writer, grammar, child, next_temp)
	else if (expression.kind == pg_match_expr_alternation_kind()):
		pg_emit_matcher_alternation(writer, grammar, expression, next_temp)
	else if (expression.kind == pg_match_expr_optional_kind()):
		pg_emit_matcher_optional(writer, grammar, expression, next_temp)
	else:
		pg_emit_matcher_repetition(writer, grammar, expression, next_temp)


void pg_emit_expression_matcher(pg_source_writer* writer, pg_grammar* grammar, char* name, pg_match_expr* expression):
	pg_open(writer, f"int {grammar.name}_matcher_{name}(char* input, int index):")
	pg_source_line(writer, c"int position = index")
	pg_source_line(writer, c"int matched = 1")
	int next_temp = 0
	pg_emit_match_expression(writer, grammar, expression, &next_temp)
	pg_open_c(writer, c"if (matched):")
	pg_source_line(writer, c"return position - index")
	pg_source_dedent(writer)
	pg_source_line(writer, c"return -1")
	pg_source_dedent(writer)
	pg_source_blank(writer)


void pg_emit_expression_matchers(pg_source_writer* writer, pg_grammar* grammar):
	for pg_token_def* token in grammar.tokens:
		if (token.expression != 0):
			pg_emit_expression_matcher(writer, grammar, token.name, token.expression)
	for pg_token_def* skip in grammar.skips:
		if (skip.expression != 0):
			pg_emit_expression_matcher(writer, grammar, skip.name, skip.expression)
	for pg_fragment_def* fragment in grammar.fragments:
		pg_emit_expression_matcher(writer, grammar, fragment.name, fragment.expression)


# The lexer's call of a token or skip matcher at `index`. Caller frees.
char* pg_lexer_matcher_call(pg_grammar* grammar, pg_token_def* token):
	if (token.expression != 0):
		return pg_take(f"{grammar.name}_matcher_{token.name}(input, index)")
	return pg_take(f"pg_lexer_matcher_{token.matcher}(input, index)")


# Token and AST kinds are plain `const int` globals, one line each:
# "const int <g>_token_<NAME> = <kind>" / "const int <g>_ast_<rule> = <kind>".
void pg_emit_kind_constant(pg_source_writer* writer, char* kind_prefix, char* name, int kind):
	pg_line(writer, f"const int {kind_prefix}{name} = {kind}")


void pg_emit_token_constants(pg_source_writer* writer, pg_grammar* grammar):
	char* prefix = pg_take(f"{grammar.name}_token_")
	pg_emit_kind_constant(writer, prefix, c"EOF", 0)
	for pg_token_def* token in grammar.tokens:
		pg_emit_kind_constant(writer, prefix, token.name, token.kind)
	for pg_literal_def* literal in grammar.literals:
		pg_emit_kind_constant(writer, prefix, literal.name, literal.kind)
	for pg_token_def* skip in grammar.skips:
		pg_emit_kind_constant(writer, prefix, skip.name, skip.kind)
	pg_source_blank(writer)
	free(prefix)


void pg_emit_ast_constants(pg_source_writer* writer, pg_grammar* grammar):
	char* prefix = pg_take(f"{grammar.name}_ast_")
	for pg_rule* rule in grammar.rules:
		pg_emit_kind_constant(writer, prefix, rule.name, rule.kind)
	pg_source_blank(writer)
	free(prefix)


void pg_emit_token_name_case(pg_source_writer* writer, pg_grammar* grammar, char* name):
	pg_line(writer, f"case {grammar.name}_token_{name}: return c\"{name}\"")


void pg_emit_token_name(pg_source_writer* writer, pg_grammar* grammar):
	pg_open(writer, f"char* {grammar.name}_token_name(int kind):")
	pg_open_c(writer, c"switch (kind):")
	pg_emit_token_name_case(writer, grammar, c"EOF")
	for pg_token_def* token in grammar.tokens:
		pg_emit_token_name_case(writer, grammar, token.name)
	for pg_literal_def* literal in grammar.literals:
		pg_emit_token_name_case(writer, grammar, literal.name)
	for pg_token_def* skip in grammar.skips:
		pg_emit_token_name_case(writer, grammar, skip.name)
	pg_source_line(writer, c"case pg_token_whitespace_kind(): return c\"WHITESPACE\"")
	pg_source_dedent(writer)
	pg_source_line(writer, c"return c\"<invalid>\"")
	pg_source_dedent(writer)
	pg_source_blank(writer)


# Matcher-function forward declarations: shared by AST and streaming
# generation, since both emit the same expression-matcher-backed lexer.
void pg_emit_matcher_forward_declarations(pg_source_writer* writer, pg_grammar* grammar):
	char* g = grammar.name
	for pg_token_def* token in grammar.tokens:
		if (token.expression != 0):
			pg_line(writer, f"int {g}_matcher_{token.name}(char* input, int index);")
	for pg_token_def* skip in grammar.skips:
		if (skip.expression != 0):
			pg_line(writer, f"int {g}_matcher_{skip.name}(char* input, int index);")
	for pg_fragment_def* fragment in grammar.fragments:
		pg_line(writer, f"int {g}_matcher_{fragment.name}(char* input, int index);")
	pg_source_blank(writer)


void pg_emit_rule_forward_declarations(pg_source_writer* writer, pg_grammar* grammar):
	for pg_rule* rule in grammar.rules:
		pg_line(writer, f"pg_ast_node* {grammar.name}_parse_{rule.name}(pg_token_stream* stream, pg_diagnostics* diagnostics);")
	pg_source_blank(writer)


void pg_emit_forward_declarations(pg_source_writer* writer, pg_grammar* grammar):
	pg_emit_matcher_forward_declarations(writer, grammar)
	pg_emit_rule_forward_declarations(writer, grammar)


void pg_emit_advance_position(pg_source_writer* writer, pg_grammar* grammar):
	pg_open(writer, f"void {grammar.name}_advance_position(char* input, int start, int length, int* linep, int* columnp):")
	pg_source_line(writer, c"int i = 0")
	pg_open_c(writer, c"while (i < length):")
	pg_open_c(writer, c"if (input[start + i] == 10):")
	pg_source_line(writer, c"linep[0] = linep[0] + 1")
	pg_source_line(writer, c"columnp[0] = 1")
	pg_source_dedent(writer)
	pg_open_c(writer, c"else:")
	pg_source_line(writer, c"columnp[0] = columnp[0] + 1")
	pg_source_dedent(writer)
	pg_source_line(writer, c"i = i + 1")
	pg_source_dedent(writer)
	pg_source_dedent(writer)
	pg_source_blank(writer)


# --- dispatch-table lexer generation -------------------------------------
#
# The generated _lex function used to try every skip, token, and literal
# matcher at every input position to implement longest-match. The emitters
# below keep those matcher attempts byte-for-byte identical but wrap them
# in a first-byte dispatch: each candidate only runs at positions whose
# first byte it could possibly match. Literals sharing a first byte become
# a nested comparison trie, and identifier-shaped literals (keywords) are
# matched by scanning the identifier once and probing a length-bucketed
# keyword chain. Selection semantics are unchanged: longest match wins,
# declaration order breaks token/skip ties, and a literal displaces an
# equal-length token or skip match.


# One lexer candidate (a skip or token definition) in attempt order, with
# the set of first bytes at which its matcher can return a positive length.
struct pg_lexgen_matcher:
	pg_token_def* token
	int is_skip
	char* first_bytes


struct pg_lexgen_literal:
	pg_literal_def* literal
	int text_length
	int first_byte
	int keyword


# An inclusive first-byte range whose bytes all share the same candidate
# set. Ranges are what the generated dispatch tree branches on.
struct pg_lexgen_span:
	int lo
	int hi


void pg_lexgen_bytes_add(char* bytes, int lo, int hi):
	for i in range(lo, hi + 1):
		bytes[i] = 1


# First bytes at which a built-in pg_lexer_matcher_* helper can match.
# These mirror the helpers in libs/extras/parser_generator/lexer.w; an
# unknown helper never prunes, so dispatch stays a pure optimization.
void pg_lexgen_builtin_first_bytes(char* bytes, char* matcher):
	if ((strcmp(matcher, c"letters") == 0) || (strcmp(matcher, c"identifier") == 0)):
		pg_lexgen_bytes_add(bytes, 'a', 'z')
		pg_lexgen_bytes_add(bytes, 'A', 'Z')
		pg_lexgen_bytes_add(bytes, '_', '_')
		if (strcmp(matcher, c"identifier") == 0):
			# UTF-8 lead bytes: pg_lexer_is_ident_start accepts them (#287)
			pg_lexgen_bytes_add(bytes, 194, 244)
	else if ((strcmp(matcher, c"digits") == 0) || (strcmp(matcher, c"number") == 0)):
		pg_lexgen_bytes_add(bytes, '0', '9')
	else if (strcmp(matcher, c"c_number") == 0):
		pg_lexgen_bytes_add(bytes, '0', '9')
		pg_lexgen_bytes_add(bytes, '.', '.')
	else if (strcmp(matcher, c"newline") == 0):
		pg_lexgen_bytes_add(bytes, 10, 10)
	else if ((strcmp(matcher, c"tabs") == 0) || (strcmp(matcher, c"inline_tabs") == 0)):
		pg_lexgen_bytes_add(bytes, 9, 9)
	else if (strcmp(matcher, c"c_control") == 0):
		pg_lexgen_bytes_add(bytes, 1, 8)
		pg_lexgen_bytes_add(bytes, 11, 12)
		pg_lexgen_bytes_add(bytes, 14, 31)
	else if ((strcmp(matcher, c"line_comment") == 0) || (strcmp(matcher, c"c_preprocessor") == 0)):
		pg_lexgen_bytes_add(bytes, '#', '#')
	else if ((strcmp(matcher, c"block_comment") == 0) || (strcmp(matcher, c"c_line_comment") == 0)):
		pg_lexgen_bytes_add(bytes, '/', '/')
	else if (strcmp(matcher, c"sql_line_comment") == 0):
		pg_lexgen_bytes_add(bytes, '-', '-')
	else if ((strcmp(matcher, c"c_string") == 0) || (strcmp(matcher, c"c_char_literal") == 0)):
		if (strcmp(matcher, c"c_string") == 0):
			pg_lexgen_bytes_add(bytes, '"', '"')
		else:
			pg_lexgen_bytes_add(bytes, 39, 39)
		pg_lexgen_bytes_add(bytes, 'u', 'u')
		pg_lexgen_bytes_add(bytes, 'U', 'U')
		pg_lexgen_bytes_add(bytes, 'L', 'L')
	else if (strcmp(matcher, c"string") == 0):
		pg_lexgen_bytes_add(bytes, '"', '"')
		pg_lexgen_bytes_add(bytes, 's', 's')
		pg_lexgen_bytes_add(bytes, 'c', 'c')
		pg_lexgen_bytes_add(bytes, 'f', 'f')
	else if ((strcmp(matcher, c"char_literal") == 0) || (strcmp(matcher, c"doubled_quote_string") == 0)):
		pg_lexgen_bytes_add(bytes, 39, 39)
	else if (strcmp(matcher, c"doubled_double_quote_string") == 0):
		pg_lexgen_bytes_add(bytes, '"', '"')
	else if (strcmp(matcher, c"operator") == 0):
		pg_lexgen_bytes_add(bytes, '<', '>')
		pg_lexgen_bytes_add(bytes, '|', '|')
		pg_lexgen_bytes_add(bytes, '&', '&')
		pg_lexgen_bytes_add(bytes, '!', '!')
	else:
		pg_lexgen_bytes_add(bytes, 1, 255)


int pg_lexgen_path_contains(list[char*] path, char* name):
	for char* entry in path:
		if (strcmp(entry, name) == 0):
			return 1
	return 0


# Collect the possible first bytes of a matcher expression into bytes and
# return whether the expression can match empty. Mirrors the shape of
# pg_reader_matcher_nullable; the reader has already rejected cyclic and
# unknown references, so those paths conservatively stop pruning.
int pg_lexgen_expr_first_bytes(pg_grammar* grammar, pg_match_expr* expression, char* bytes, list[char*] path):
	if (expression.kind == pg_match_expr_string_kind()):
		if (strlen(expression.text) == 0):
			return 1
		bytes[expression.text[0] & 255] = 1
		return 0
	if (expression.kind == pg_match_expr_charset_kind()):
		for i in range(1, 128):
			if (expression.charset[i] != 0):
				bytes[i] = 1
		return 0
	if (expression.kind == pg_match_expr_reference_kind()):
		if (pg_lexgen_path_contains(path, expression.text)):
			pg_lexgen_bytes_add(bytes, 1, 255)
			return 0
		pg_token_def* token = pg_grammar_find_token(grammar, expression.text)
		if ((token != 0) && (token.expression == 0)):
			pg_lexgen_builtin_first_bytes(bytes, token.matcher)
			return 0
		char* name = 0
		pg_match_expr* target = 0
		if (token != 0):
			name = token.name
			target = token.expression
		else:
			pg_fragment_def* fragment = pg_grammar_find_fragment(grammar, expression.text)
			if (fragment == 0):
				pg_lexgen_bytes_add(bytes, 1, 255)
				return 0
			name = fragment.name
			target = fragment.expression
		path.push(name)
		int nullable = pg_lexgen_expr_first_bytes(grammar, target, bytes, path)
		path.pop()
		return nullable
	if (expression.kind == pg_match_expr_sequence_kind()):
		for pg_match_expr* child in expression.children:
			if (pg_lexgen_expr_first_bytes(grammar, child, bytes, path) == 0):
				return 0
		return 1
	if (expression.kind == pg_match_expr_alternation_kind()):
		int any_nullable = 0
		for pg_match_expr* child in expression.children:
			any_nullable = any_nullable | pg_lexgen_expr_first_bytes(grammar, child, bytes, path)
		return any_nullable
	if ((expression.kind == pg_match_expr_optional_kind()) || (expression.kind == pg_match_expr_zero_or_more_kind())):
		pg_lexgen_expr_first_bytes(grammar, expression.children[0], bytes, path)
		return 1
	return pg_lexgen_expr_first_bytes(grammar, expression.children[0], bytes, path)


pg_lexgen_matcher* pg_lexgen_matcher_new(pg_grammar* grammar, pg_token_def* token, int is_skip):
	pg_lexgen_matcher* candidate = new pg_lexgen_matcher()
	candidate.token = token
	candidate.is_skip = is_skip
	char* bytes = malloc(256)
	for i in range(256):
		bytes[i] = 0
	if (token.expression != 0):
		list[char*] path = new list[char*]
		path.push(token.name)
		pg_lexgen_expr_first_bytes(grammar, token.expression, bytes, path)
		list_free[char*](path)
	else:
		pg_lexgen_builtin_first_bytes(bytes, token.matcher)
	candidate.first_bytes = bytes
	return candidate


int pg_lexgen_is_identifier_matcher(pg_token_def* token):
	return (token.expression == 0) && (strcmp(token.matcher, c"identifier") == 0)


# Keyword bucketing is only sound when the built-in identifier matcher is
# among the candidates: it guarantees best_length already covers the whole
# identifier run when the keyword probes execute.
int pg_lexgen_keyword_mode(pg_grammar* grammar):
	for pg_token_def* token in grammar.tokens:
		if (pg_lexgen_is_identifier_matcher(token)):
			return 1
	for pg_token_def* skip in grammar.skips:
		if (pg_lexgen_is_identifier_matcher(skip)):
			return 1
	return 0


int pg_lexgen_literal_is_ident_shaped(char* text):
	if (pg_lexer_is_ident_start(text[0] & 255) == 0):
		return 0
	int i = 1
	while (text[i] != 0):
		if (pg_lexer_is_ident_part(text[i] & 255) == 0):
			return 0
		i = i + 1
	return 1


void pg_lexgen_collect_literals(pg_grammar* grammar, list[pg_lexgen_literal*] literals, int keyword_mode):
	for pg_literal_def* literal in grammar.literals:
		int text_length = strlen(literal.text)
		if (text_length > 0):
			# A duplicate text replaces the earlier declaration, matching
			# the last-wins '>=' update order of the linear sweep.
			int replaced = 0
			for pg_lexgen_literal* existing in literals:
				if (strcmp(existing.literal.text, literal.text) == 0):
					existing.literal = literal
					replaced = 1
			if (replaced == 0):
				pg_lexgen_literal* entry = new pg_lexgen_literal()
				entry.literal = literal
				entry.text_length = text_length
				entry.first_byte = literal.text[0] & 255
				entry.keyword = 0
				if (keyword_mode):
					entry.keyword = pg_lexgen_literal_is_ident_shaped(literal.text)
				literals.push(entry)


int pg_lexgen_byte_has_candidates(list[pg_lexgen_matcher*] matchers, list[pg_lexgen_literal*] literals, int b):
	for pg_lexgen_matcher* candidate in matchers:
		if (candidate.first_bytes[b] != 0):
			return 1
	for pg_lexgen_literal* entry in literals:
		if (entry.first_byte == b):
			return 1
	return 0


int pg_lexgen_same_candidates(list[pg_lexgen_matcher*] matchers, list[pg_lexgen_literal*] literals, int a, int b):
	for pg_lexgen_matcher* candidate in matchers:
		if (candidate.first_bytes[a] != candidate.first_bytes[b]):
			return 0
	# A literal belongs to exactly one first byte, so two bytes can only
	# share a candidate set when neither has literals.
	for pg_lexgen_literal* entry in literals:
		if ((entry.first_byte == a) || (entry.first_byte == b)):
			return 0
	return 1


void pg_lexgen_collect_spans(list[pg_lexgen_matcher*] matchers, list[pg_lexgen_literal*] literals, list[pg_lexgen_span*] spans):
	for b in range(1, 256):
		if (pg_lexgen_byte_has_candidates(matchers, literals, b)):
			int merged = 0
			if (spans.length > 0):
				pg_lexgen_span* last = spans[spans.length - 1]
				if ((last.hi == b - 1) && pg_lexgen_same_candidates(matchers, literals, b - 1, b)):
					last.hi = b
					merged = 1
			if (merged == 0):
				pg_lexgen_span* span = new pg_lexgen_span()
				span.lo = b
				span.hi = b
				spans.push(span)


# "<condition>: best_length, best_kind, best_skip = length, <kind>, <skip>"
# -- a candidate that matched `length` bytes becomes the best match.
void pg_emit_lexer_take_best(pg_source_writer* writer, char* condition, char* kind, int is_skip):
	pg_line(writer, f"{condition}: best_length, best_kind, best_skip = length, {kind}, {is_skip}")


# One skip/token matcher attempt: identical to the block the linear sweep
# used to emit for every candidate at every position.
void pg_emit_lexer_attempt(pg_source_writer* writer, pg_grammar* grammar, pg_token_def* token, int is_skip):
	char* call = pg_lexer_matcher_call(grammar, token)
	pg_line(writer, f"length = {call}")
	free(call)
	char* kind = pg_take(f"{grammar.name}_token_{token.name}")
	pg_emit_lexer_take_best(writer, c"if (length > best_length)", kind, is_skip)
	free(kind)


# Nested comparison trie over literals sharing a first byte. depth bytes
# are already known to match when a node is entered; a literal ending at
# this depth records itself before longer literals get a chance to
# overwrite it, which implements longest-match with prefix fallback.
void pg_emit_lexer_literal_trie(pg_source_writer* writer, pg_grammar* grammar, list[pg_lexgen_literal*] group, int depth):
	for pg_lexgen_literal* accept in group:
		if (accept.text_length == depth):
			pg_line(writer, f"length, literal_kind = {depth}, {grammar.name}_token_{accept.literal.name}")
	char* keyword = c"if"
	for i, entry in group:
		if (entry.text_length > depth):
			int next = entry.literal.text[depth] & 255
			int seen = 0
			for j in range(i):
				pg_lexgen_literal* earlier = group[j]
				if ((earlier.text_length > depth) && ((earlier.literal.text[depth] & 255) == next)):
					seen = 1
			if (seen == 0):
				if (next < 128):
					pg_open(writer, f"{keyword} (input[index + {depth}] == {next}):")
				else:
					pg_open(writer, f"{keyword} ((input[index + {depth}] & 255) == {next}):")
				list[pg_lexgen_literal*] subgroup = new list[pg_lexgen_literal*]
				for pg_lexgen_literal* member in group:
					if ((member.text_length > depth) && ((member.literal.text[depth] & 255) == next)):
						subgroup.push(member)
				pg_emit_lexer_literal_trie(writer, grammar, subgroup, depth + 1)
				list_free[pg_lexgen_literal*](subgroup)
				pg_source_dedent(writer)
				keyword = c"else if"


void pg_emit_lexer_literal_group(pg_source_writer* writer, pg_grammar* grammar, list[pg_lexgen_literal*] group):
	int has_root_accept = 0
	for pg_lexgen_literal* entry in group:
		if (entry.text_length == 1):
			has_root_accept = 1
	if (has_root_accept == 0):
		pg_source_line(writer, c"length = 0")
	pg_emit_lexer_literal_trie(writer, grammar, group, 1)
	pg_emit_lexer_take_best(writer, c"if ((length > 0) && (length >= best_length))", c"literal_kind", 0)


# Identifier-shaped literals: scan the identifier once, then probe only
# the keywords whose length equals the identifier run. A shorter keyword
# prefix can never win here because the identifier candidate has already
# pushed best_length to the full run length. Within a length bucket at
# most one keyword text can be a prefix of the input, so folding the
# best_length test into each probe's condition cannot change which
# branch of the chain fires.
void pg_emit_lexer_keyword_buckets(pg_source_writer* writer, pg_grammar* grammar, list[pg_lexgen_literal*] group, int have_ident_length):
	if (have_ident_length == 0):
		pg_source_line(writer, c"length = pg_lexer_matcher_identifier(input, index)")
	int max_length = 0
	for pg_lexgen_literal* entry in group:
		if (entry.text_length > max_length):
			max_length = entry.text_length
	char* bucket_keyword = c"if"
	for n in range(1, max_length + 1):
		char* keyword = c"if"
		for pg_lexgen_literal* entry in group:
			if (entry.text_length == n):
				if (strcmp(keyword, c"if") == 0):
					pg_open(writer, f"{bucket_keyword} (length == {n}):")
					bucket_keyword = c"else if"
				char* condition = pg_take(f"{keyword} (starts_with(input + index, c\"{entry.literal.text}\") && (length >= best_length))")
				char* kind = pg_take(f"{grammar.name}_token_{entry.literal.name}")
				pg_emit_lexer_take_best(writer, condition, kind, 0)
				free(condition)
				free(kind)
				keyword = c"else if"
		if (strcmp(keyword, c"if") != 0):
			pg_source_dedent(writer)


void pg_emit_lexer_byte_body(pg_source_writer* writer, pg_grammar* grammar, list[pg_lexgen_matcher*] matchers, list[pg_lexgen_literal*] literals, int b):
	int last_is_identifier = 0
	for pg_lexgen_matcher* candidate in matchers:
		if (candidate.first_bytes[b] != 0):
			pg_emit_lexer_attempt(writer, grammar, candidate.token, candidate.is_skip)
			last_is_identifier = pg_lexgen_is_identifier_matcher(candidate.token)
	list[pg_lexgen_literal*] group = new list[pg_lexgen_literal*]
	list[pg_lexgen_literal*] keywords = new list[pg_lexgen_literal*]
	for pg_lexgen_literal* entry in literals:
		if ((entry.first_byte == b) && (entry.keyword == 0)):
			group.push(entry)
		else if (entry.first_byte == b):
			keywords.push(entry)
	if (group.length > 0):
		pg_emit_lexer_literal_group(writer, grammar, group)
		last_is_identifier = 0
	if (keywords.length > 0):
		pg_emit_lexer_keyword_buckets(writer, grammar, keywords, last_is_identifier)
	list_free[pg_lexgen_literal*](group)
	list_free[pg_lexgen_literal*](keywords)


# Binary dispatch over the first-byte ranges: log-depth comparisons on
# first_byte select the single range whose candidate set can match here.
# Bytes outside every range have no possible match and fall through with
# best_length still 0, exactly like the linear sweep. `keyword` is "if"
# for a subtree that opens a block and "else if" for the right half of a
# split, which continues its parent's chain instead of nesting under an
# "else:"; known_lo..known_hi is what the enclosing comparisons already
# establish about first_byte, so a range test they imply is left out.
void pg_emit_lexer_dispatch(pg_source_writer* writer, pg_grammar* grammar, list[pg_lexgen_matcher*] matchers, list[pg_lexgen_literal*] literals, list[pg_lexgen_span*] spans, int lo, int hi, char* keyword, int known_lo, int known_hi):
	if (lo < hi):
		int mid = (lo + hi + 1) / 2
		int pivot = spans[mid].lo
		pg_open(writer, f"{keyword} (first_byte < {pivot}):")
		pg_emit_lexer_dispatch(writer, grammar, matchers, literals, spans, lo, mid - 1, c"if", known_lo, pivot - 1)
		pg_source_dedent(writer)
		pg_emit_lexer_dispatch(writer, grammar, matchers, literals, spans, mid, hi, c"else if", pivot, known_hi)
		return
	pg_lexgen_span* span = spans[lo]
	int need_lo = known_lo < span.lo
	int need_hi = known_hi > span.hi
	if (need_lo && need_hi && (span.lo == span.hi)):
		pg_open(writer, f"{keyword} (first_byte == {span.lo}):")
	else if (need_lo && need_hi):
		pg_open(writer, f"{keyword} ((first_byte >= {span.lo}) && (first_byte <= {span.hi})):")
	else if (need_lo):
		pg_open(writer, f"{keyword} (first_byte >= {span.lo}):")
	else if (need_hi):
		pg_open(writer, f"{keyword} (first_byte <= {span.hi}):")
	else if (strcmp(keyword, c"if") != 0):
		pg_open_c(writer, c"else:")
	else:
		# The whole block is this range: no test, no nesting.
		pg_emit_lexer_byte_body(writer, grammar, matchers, literals, span.lo)
		return
	pg_emit_lexer_byte_body(writer, grammar, matchers, literals, span.lo)
	pg_source_dedent(writer)


void pg_emit_lexer(pg_source_writer* writer, pg_grammar* grammar):
	list[pg_lexgen_matcher*] matchers = new list[pg_lexgen_matcher*]
	for pg_token_def* skip in grammar.skips:
		matchers.push(pg_lexgen_matcher_new(grammar, skip, 1))
	for pg_token_def* token in grammar.tokens:
		matchers.push(pg_lexgen_matcher_new(grammar, token, 0))
	list[pg_lexgen_literal*] literals = new list[pg_lexgen_literal*]
	pg_lexgen_collect_literals(grammar, literals, pg_lexgen_keyword_mode(grammar))
	list[pg_lexgen_span*] spans = new list[pg_lexgen_span*]
	pg_lexgen_collect_spans(matchers, literals, spans)
	int has_trie_literals = 0
	for pg_lexgen_literal* entry in literals:
		if (entry.keyword == 0):
			has_trie_literals = 1
	char* g = grammar.name
	pg_open(writer, f"pg_token_stream* {g}_lex(char* input, char* filename, pg_diagnostics* diagnostics):")
	pg_source_line(writer, c"pg_token_stream* stream = pg_token_stream_new()")
	pg_source_line(writer, c"int index = 0")
	pg_source_line(writer, c"int line = 1")
	pg_source_line(writer, c"int column = 1")
	pg_open_c(writer, c"while (input[index] != 0):")
	pg_source_line(writer, c"int start = index")
	pg_source_line(writer, c"int start_line = line")
	pg_source_line(writer, c"int start_column = column")
	pg_source_line(writer, c"int length = 0")
	pg_source_line(writer, c"int best_kind = 0")
	pg_source_line(writer, c"int best_length = 0")
	pg_source_line(writer, c"int best_skip = 0")
	if (has_trie_literals):
		pg_source_line(writer, c"int literal_kind = 0")
	if (spans.length > 0):
		pg_source_line(writer, c"int first_byte = input[index] & 255")
		# first_byte is never 0: the loop stops at the terminating NUL.
		pg_emit_lexer_dispatch(writer, grammar, matchers, literals, spans, 0, spans.length - 1, c"if", 1, 255)
	for pg_lexgen_matcher* candidate in matchers:
		free(candidate.first_bytes)
		free(candidate)
	list_free[pg_lexgen_matcher*](matchers)
	for pg_lexgen_literal* entry in literals:
		free(entry)
	list_free[pg_lexgen_literal*](literals)
	for pg_lexgen_span* span in spans:
		free(span)
	list_free[pg_lexgen_span*](spans)
	pg_open_c(writer, c"if (best_length > 0):")
	pg_open_c(writer, c"if (best_skip == 0):")
	pg_source_line(writer, c"pg_token_stream_add(stream, pg_token_make(best_kind, input, start, best_length, filename, start_line, start_column))")
	pg_source_dedent(writer)
	pg_open_c(writer, c"else:")
	pg_source_line(writer, c"pg_token_stream_add(stream, pg_token_hide(pg_token_make(best_kind, input, start, best_length, filename, start_line, start_column)))")
	pg_source_dedent(writer)
	pg_line(writer, f"{g}_advance_position(input, start, best_length, &line, &column)")
	pg_source_line(writer, c"index = index + best_length")
	pg_source_dedent(writer)
	pg_open_c(writer, c"else if (pg_lexer_is_inline_space(input[index])):")
	pg_source_line(writer, c"int ws_start = index")
	pg_source_line(writer, c"int ws_line = line")
	pg_source_line(writer, c"int ws_column = column")
	pg_open_c(writer, c"while (pg_lexer_is_inline_space(input[index])):")
	pg_source_line(writer, c"column = column + 1")
	pg_source_line(writer, c"index = index + 1")
	pg_source_dedent(writer)
	pg_source_line(writer, c"pg_token_stream_add(stream, pg_token_hide(pg_token_make(pg_token_whitespace_kind(), input, ws_start, index - ws_start, filename, ws_line, ws_column)))")
	pg_source_dedent(writer)
	pg_open_c(writer, c"else:")
	pg_source_line(writer, c"pg_diagnostics_add(diagnostics, filename, line, column, c\"invalid character\", c\"known token\", pg_substr(input, index, 1))")
	pg_source_line(writer, c"pg_token_stream_add(stream, pg_token_hide(pg_token_make(pg_token_invalid_kind(), input, index, 1, filename, line, column)))")
	pg_source_line(writer, c"index = index + 1")
	pg_source_line(writer, c"column = column + 1")
	pg_source_dedent(writer)
	pg_source_dedent(writer)
	pg_source_line(writer, c"pg_token_stream_add(stream, pg_token_eof(index, filename, line, column))")
	pg_source_line(writer, c"return stream")
	pg_source_dedent(writer)
	pg_source_blank(writer)


void pg_emit_match_token(pg_source_writer* writer, pg_grammar* grammar):
	pg_open(writer, f"pg_ast_node* {grammar.name}_match_token(pg_token_stream* stream, int kind, char* name):")
	pg_source_line(writer, c"pg_token* token = pg_token_stream_peek(stream)")
	pg_open_c(writer, c"if (token.kind == kind):")
	pg_source_line(writer, c"pg_token_stream_consume(stream)")
	pg_source_line(writer, c"return pg_ast_token(kind, token, name)")
	pg_source_dedent(writer)
	pg_source_line(writer, c"return 0")
	pg_source_dedent(writer)
	pg_source_blank(writer)


# --- LL(1) committed dispatch (issue #329 milestone 2) ---------------------
#
# Rule bodies used to attempt every alternative in order, allocating a
# node per attempt and re-parsing shared prefixes. Using the analysis in
# analysis.w, the emitters below (a) guard alternatives and ?/*/+ terms
# with first-set membership tests that only skip attempts which would
# fail without consuming input or recording diagnostics, and (b) parse a
# left-factored shared plain-term prefix of consecutive alternatives
# once, dispatching only the suffix choice. Ordered-choice (PEG)
# semantics, accept/reject behavior, AST shape, and the furthest-token
# error position are unchanged: where first sets overlap or a guard
# would be unsound (nullable or impure attempts), today's mark/rewind
# backtracking code shape is kept.


# Caller-freed "name<alt>_<term>" string for per-term generated locals.
char* pg_guard_var_name(char* name, int alt_index, int term_index):
	return pg_take(f"{name}{alt_index}_{term_index}")


# Parenthesized membership test of var_name against a kind set, as a
# disjunction of ranges over the dense kind numbering, e.g.
# (k == g_token_IDENT) || ((k >= g_token_KW_IF) && (k <= g_token_KW_FOR))
# Emitted with the short-circuit spellings: every operand is a pure
# comparison against a token-kind constant, so skipping the
# rest of the disjunction once a range matches changes nothing but the
# number of comparisons executed. Caller frees.
char* pg_kind_set_test(pg_grammar* grammar, pg_analysis* analysis, char* kinds, char* var_name):
	pg_source_writer* out = pg_source_writer_new()
	char* g = grammar.name
	int first_range = 1
	int kind = 0
	while (kind < analysis.kind_count):
		if (kinds[kind] == 0):
			kind = kind + 1
		else:
			int end = kind
			while ((end + 1 < analysis.kind_count) && (kinds[end + 1] != 0)):
				end = end + 1
			if (first_range == 0):
				pg_source_append(out, c" || ")
			char* low = pg_report_kind_name(grammar, kind)
			if (kind == end):
				pg_add(out, f"({var_name} == {g}_token_{low})")
			else:
				pg_add(out, f"(({var_name} >= {g}_token_{low}) && ({var_name} <= {g}_token_{pg_report_kind_name(grammar, end)}))")
			first_range = 0
			kind = end + 1
	if (first_range):
		pg_source_append_char(out, '0')
	return pg_source_take(out)


# "<before><kind set test><after>", opening a block: e.g. "if (" ... "):".
void pg_emit_kind_set_open(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, char* kinds, char* var_name, char* before, char* after):
	char* test = pg_kind_set_test(grammar, analysis, kinds, var_name)
	pg_open(writer, f"{before}{test}{after}")
	free(test)


# "int <var> = pg_token_stream_peek(stream).kind"
void pg_emit_peek_kind_line(pg_source_writer* writer, char* var_name):
	pg_line(writer, f"int {var_name} = pg_token_stream_peek(stream).kind")


# Error recovery inside a repetition of a recover-marked rule. Emitted in the
# child-failed branch, after the stream has been rewound to the iteration
# mark. At EOF the repetition ends normally; otherwise one diagnostic is
# recorded at the furthest token any attempt reached, the skipped tokens are
# collected under an "error" node, and the repetition resumes after the sync
# token (also skipping sync/skip-led continuations, e.g. blank or indented
# lines).
void pg_emit_recovery(pg_source_writer* writer, pg_grammar* grammar, pg_recover_def* recover, char* rule_name, int alt_index, int term_index):
	char* g = grammar.name
	char* at = pg_take(f"{alt_index}_{term_index}")
	char* sync = pg_take(f"{g}_token_{recover.sync_token}")
	pg_line(writer, f"if (pg_token_stream_peek(stream).kind == {g}_token_EOF): break")
	pg_line(writer, f"pg_syntax_error(diagnostics, pg_token_stream_furthest(stream), c\"{rule_name}\")")
	pg_line(writer, f"pg_ast_node* recover_node_{at} = pg_ast_new(pg_ast_error_kind(), 0, c\"error\")")
	pg_open(writer, f"while (pg_token_stream_peek(stream).kind != {g}_token_EOF):")
	pg_line(writer, f"pg_token* recover_token_{at} = pg_token_stream_consume(stream)")
	pg_line(writer, f"pg_ast_add(recover_node_{at}, pg_ast_token(recover_token_{at}.kind, recover_token_{at}, c\"error_token\"))")
	pg_open(writer, f"if (recover_token_{at}.kind == {sync}):")
	pg_line(writer, f"int recover_next_{at} = pg_token_stream_peek(stream).kind")
	pg_source_tabs(writer)
	pg_add(writer, f"if ((recover_next_{at} != {sync})")
	for char* skip_name in recover.skip_tokens:
		pg_add(writer, f" && (recover_next_{at} != {g}_token_{skip_name})")
	pg_source_line(writer, c"): break")
	pg_source_dedent(writer)
	pg_source_dedent(writer)
	pg_line(writer, f"pg_ast_add(node, recover_node_{at})")
	pg_source_line(writer, c"continue")
	free(at)
	free(sync)


# A term attempt that may fail silently: mark, parse, then attach the child
# or rewind to the mark (pg_ast_add_or_rewind). The mark is its own
# statement so it is taken before the parse runs. Returns the (caller
# freed) attach call, which the caller emits as a statement or a test.
char* pg_attempt_call(pg_source_writer* writer, pg_grammar* grammar, pg_term* term, char* mark_prefix, int alt_index, int term_index):
	pg_line(writer, f"int {mark_prefix}{alt_index}_{term_index} = pg_token_stream_mark(stream)")
	char* call = pg_term_call(grammar, term)
	char* attach = pg_take(f"pg_ast_add_or_rewind(node, stream, {mark_prefix}{alt_index}_{term_index}, {call})")
	free(call)
	return attach


# An optional term: try it, keeping the child when it parsed. A guarded
# token term is already known to match (its match is decided entirely by
# the peeked kind), so it is attached directly with no mark/rewind.
void pg_emit_optional_term(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_term* term, int alt_index, int term_index):
	if (pg_analysis_term_enter_guardable(analysis, term) == 0):
		char* attach = pg_attempt_call(writer, grammar, term, c"optional_mark_", alt_index, term_index)
		pg_line(writer, f"{attach}")
		free(attach)
		return
	# Enter the optional term only when the current token is in its first
	# set; a miss is a provably silent failure, so the skip is exactly
	# what the unguarded failed attempt does.
	char* kinds = pg_kind_set_new(analysis)
	pg_analysis_term_first(analysis, term, kinds)
	char* kind_name = pg_guard_var_name(c"optional_kind_", alt_index, term_index)
	pg_emit_peek_kind_line(writer, kind_name)
	char* test = pg_kind_set_test(grammar, analysis, kinds, kind_name)
	char* call = pg_term_call(grammar, term)
	if (pg_grammar_is_token_term(grammar, term.name)):
		pg_line(writer, f"if ({test}): pg_ast_add(node, {call})")
	else:
		pg_open(writer, f"if ({test}):")
		char* attach = pg_attempt_call(writer, grammar, term, c"optional_mark_", alt_index, term_index)
		pg_line(writer, f"{attach}")
		free(attach)
		pg_source_dedent(writer)
	free(test)
	free(call)
	free(kind_name)
	free(kinds)


# A '*' or '+' term: iterate while the term parses (the guard, when
# sound, stops on the first token outside its first set -- exactly the
# final failed attempt). Only '+' counts iterations. Needs no
# `failed == 0` wrapper: the loop condition is that test, and with the
# loop skipped '+' only re-sets an already set failed.
void pg_emit_repeat_term(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_term* term, int alt_index, int term_index):
	int is_token = pg_grammar_is_token_term(grammar, term.name)
	int guardable = pg_analysis_term_enter_guardable(analysis, term)
	char* count = pg_guard_var_name(c"repeat_count_", alt_index, term_index)
	if (term.modifier == '+'):
		pg_line(writer, f"int {count} = 0")
	pg_open_c(writer, c"while (failed == 0):")
	if (guardable):
		char* kinds = pg_kind_set_new(analysis)
		pg_analysis_term_first(analysis, term, kinds)
		char* kind_name = pg_guard_var_name(c"repeat_kind_", alt_index, term_index)
		pg_emit_peek_kind_line(writer, kind_name)
		char* test = pg_kind_set_test(grammar, analysis, kinds, kind_name)
		pg_line(writer, f"if (({test}) == 0): break")
		free(test)
		free(kind_name)
		free(kinds)
	if (guardable && is_token):
		char* call = pg_term_call(grammar, term)
		pg_line(writer, f"pg_ast_add(node, {call})")
		free(call)
	else:
		char* attach = pg_attempt_call(writer, grammar, term, c"repeat_mark_", alt_index, term_index)
		pg_recover_def* recover = 0
		if (is_token == 0):
			recover = pg_grammar_find_recover(grammar, term.name)
		if (recover == 0):
			pg_line(writer, f"if ({attach} == 0): break")
		else:
			pg_open(writer, f"if ({attach} == 0):")
			pg_emit_recovery(writer, grammar, recover, term.name, alt_index, term_index)
			pg_source_dedent(writer)
		free(attach)
	if (term.modifier == '+'):
		pg_line(writer, f"{count}++")
	pg_source_dedent(writer)
	if (term.modifier == '+'):
		pg_line(writer, f"if ({count} == 0): failed = 1")
	free(count)


# One term of an alternative body. `first` marks the body's first term,
# where failed is known to be 0 (plain terms then set it outright).
void pg_emit_term(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_term* term, int alt_index, int term_index, int first):
	if ((term.modifier == '*') || (term.modifier == '+')):
		pg_emit_repeat_term(writer, grammar, analysis, term, alt_index, term_index)
		return
	char* guard = c"if (failed == 0): "
	if (first):
		guard = c""
	if (term.modifier == 0):
		char* call = pg_term_call(grammar, term)
		pg_line(writer, f"{guard}failed = pg_ast_add_required(node, {call})")
		free(call)
	else if (first):
		pg_emit_optional_term(writer, grammar, analysis, term, alt_index, term_index)
	else:
		pg_open_c(writer, c"if (failed == 0):")
		pg_emit_optional_term(writer, grammar, analysis, term, alt_index, term_index)
		pg_source_dedent(writer)


# "node = pg_ast_new(<rule ast kind>, 0, "<rule>")" plus reattaching any
# already-parsed left-factored prefix children in order.
void pg_emit_node_alloc(pg_source_writer* writer, pg_grammar* grammar, pg_rule* rule, list[char*] prefix_children):
	pg_line(writer, f"node = pg_ast_new({grammar.name}_ast_{rule.name}, 0, c\"{rule.name}\")")
	for char* child in prefix_children:
		pg_line(writer, f"pg_ast_add(node, {child})")


# One alternative's terms from offset on: today's attempt body. With an
# empty remainder (a fully factored alternative) the node is returned
# outright — nothing is left to fail.
void pg_emit_alternative_body(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_rule* rule, int alt_index, int offset, list[char*] prefix_children, char* mark_name):
	pg_alternative* alternative = rule.alternatives[alt_index]
	pg_emit_node_alloc(writer, grammar, rule, prefix_children)
	if (offset >= alternative.terms.length):
		pg_source_line(writer, c"return node")
		return
	# A plain first term assigns failed itself; anything else needs it
	# reset from an earlier alternative's attempt first.
	if (alternative.terms[offset].modifier != 0):
		pg_source_line(writer, c"failed = 0")
	for term_index in range(offset, alternative.terms.length):
		pg_emit_term(writer, grammar, analysis, alternative.terms[term_index], alt_index, term_index, term_index == offset)
	pg_source_line(writer, c"if (failed == 0): return node")
	pg_line(writer, f"pg_token_stream_rewind(stream, {mark_name})")


void pg_emit_choice(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_rule* rule, int alt_start, int alt_count, int offset, list[char*] prefix_children, char* mark_name, char* kind_name);


# A left-factored run: parse the shared prefix once into locals, then
# dispatch the suffix choice from a fresh mark. On any failure the
# stream is restored to the enclosing mark, exactly like the separate
# per-alternative attempts this replaces.
void pg_emit_factored_unit(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_rule* rule, pg_choice_unit* unit, int offset, list[char*] prefix_children, char* mark_name):
	pg_alternative* head = rule.alternatives[unit.alt_start]
	int alt = unit.alt_start
	int prefix_end = offset + unit.prefix_length
	pg_source_line(writer, c"failed = 0")
	list[char*] inner_children = new list[char*]
	for char* child in prefix_children:
		inner_children.push(child)
	# The prefix children are declared at unit level so the suffix
	# alternatives (nested blocks) can attach them to their nodes; the
	# first one is parsed right in its declaration (failed is still 0).
	char* call = pg_term_call(grammar, head.terms[offset])
	pg_line(writer, f"pg_ast_node* child_{alt}_{offset} = {call}")
	free(call)
	for term_index in range(offset + 1, prefix_end):
		pg_line(writer, f"pg_ast_node* child_{alt}_{term_index} = 0")
	for term_index in range(offset, prefix_end):
		if (term_index > offset):
			call = pg_term_call(grammar, head.terms[term_index])
			pg_line(writer, f"if (failed == 0): child_{alt}_{term_index} = {call}")
			free(call)
		pg_line(writer, f"if (child_{alt}_{term_index} == 0): failed = 1")
		inner_children.push(pg_guard_var_name(c"child_", alt, term_index))
	pg_open_c(writer, c"if (failed == 0):")
	char* factored_mark = pg_guard_var_name(c"factored_mark_", alt, offset)
	char* factored_kind = pg_guard_var_name(c"factored_kind_", alt, offset)
	pg_line(writer, f"int {factored_mark} = pg_token_stream_mark(stream)")
	pg_emit_choice(writer, grammar, analysis, rule, alt, unit.member_count, prefix_end, inner_children, factored_mark, factored_kind)
	pg_source_dedent(writer)
	pg_line(writer, f"pg_token_stream_rewind(stream, {mark_name})")
	for i in range(prefix_children.length, inner_children.length):
		free(inner_children[i])
	list_free[char*](inner_children)
	free(factored_mark)
	free(factored_kind)


# Ordered choice over alternatives alt_start..alt_start+alt_count-1 from
# term offset on. Guarded units only run when the current token is in
# their first set; overlapping or unguardable units keep today's ordered
# attempt semantics simply by being tried in sequence.
void pg_emit_choice(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_rule* rule, int alt_start, int alt_count, int offset, list[char*] prefix_children, char* mark_name, char* kind_name):
	list[pg_choice_unit*] units = pg_plan_choice(analysis, rule, alt_start, alt_count, offset)
	for pg_choice_unit* unit in units:
		if (unit.guarded):
			pg_emit_peek_kind_line(writer, kind_name)
			break
	for pg_choice_unit* unit in units:
		if (unit.guarded):
			pg_emit_kind_set_open(writer, grammar, analysis, unit.guard_set, kind_name, c"if (", c"):")
		if (unit.member_count == 1):
			pg_emit_alternative_body(writer, grammar, analysis, rule, unit.alt_start, offset, prefix_children, mark_name)
		else:
			pg_emit_factored_unit(writer, grammar, analysis, rule, unit, offset, prefix_children, mark_name)
		if (unit.guarded):
			pg_source_dedent(writer)
	pg_choice_units_free(units)


void pg_emit_rule(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_rule* rule):
	pg_open(writer, f"pg_ast_node* {grammar.name}_parse_{rule.name}(pg_token_stream* stream, pg_diagnostics* diagnostics):")
	pg_source_line(writer, c"int mark = pg_token_stream_mark(stream)")
	pg_source_line(writer, c"pg_ast_node* node = 0")
	pg_source_line(writer, c"int failed = 0")
	list[char*] prefix_children = new list[char*]
	pg_emit_choice(writer, grammar, analysis, rule, 0, rule.alternatives.length, 0, prefix_children, c"mark", c"first_kind")
	list_free[char*](prefix_children)
	pg_source_line(writer, c"return 0")
	pg_source_dedent(writer)
	pg_source_blank(writer)


void pg_emit_parse_entry(pg_source_writer* writer, pg_grammar* grammar):
	char* g = grammar.name
	pg_open(writer, f"pg_ast_node* {g}_parse(char* input, char* filename, pg_diagnostics* diagnostics):")
	pg_line(writer, f"pg_token_stream* stream = {g}_lex(input, filename, diagnostics)")
	pg_line(writer, f"pg_ast_node* root = {g}_parse_{grammar.start_rule}(stream, diagnostics)")
	pg_line(writer, f"if (root == 0): pg_syntax_error(diagnostics, pg_token_stream_furthest(stream), c\"{grammar.start_rule}\")")
	pg_source_line(writer, c"return root")
	pg_source_dedent(writer)
	pg_source_blank(writer)


# --- streaming mode (issue #329 milestone 3) --------------------------
#
# `pg_streaming_check` (analysis.w) has already proven, before any of
# this runs, that every choice in the grammar is committed dispatch and
# no ?/*/+ term names a rule (pg_generate_streaming_parser below refuses
# to emit anything otherwise). That lets rule bodies commit to an
# alternative with a single first-set test and then run its terms in a
# straight line: no mark, no rewind, anywhere. A mandatory term that
# fails is a hard syntax error -- once the guard chose this alternative
# there was never a sibling to fall back to -- so failure is a direct
# "record diagnostic, return 0" instead of AST mode's rewind-and-try-next.
#
# Callback surface: a generated <parser>_listener carries one context
# pointer plus, per rule, an on_enter_<rule>/on_exit_<rule> pair (fired
# with the token stream, so a listener can peek the token that triggered
# it) and one shared on_token, fired for every consumed token regardless
# of which rule consumed it. Any field left 0 is simply skipped. on_enter
# fires before the rule's alternative is even chosen; on_exit fires only
# once every term of the chosen alternative has matched, so a rule that
# enters but never exits is exactly the rule that failed.


void pg_emit_streaming_types(pg_source_writer* writer, pg_grammar* grammar):
	pg_line(writer, f"type {grammar.name}_listener_fn = fn(pg_token_stream*, void*) -> void")
	pg_line(writer, f"type {grammar.name}_token_fn = fn(pg_token*, void*) -> void")
	pg_source_blank(writer)


void pg_emit_streaming_listener_struct(pg_source_writer* writer, pg_grammar* grammar):
	char* g = grammar.name
	pg_open(writer, f"struct {g}_listener:")
	pg_source_line(writer, c"void* context")
	pg_line(writer, f"{g}_token_fn* on_token")
	for pg_rule* rule in grammar.rules:
		pg_line(writer, f"{g}_listener_fn* on_enter_{rule.name}")
		pg_line(writer, f"{g}_listener_fn* on_exit_{rule.name}")
	pg_source_dedent(writer)
	pg_source_blank(writer)


void pg_emit_streaming_listener_new(pg_source_writer* writer, pg_grammar* grammar):
	char* g = grammar.name
	pg_open(writer, f"{g}_listener* {g}_listener_new():")
	pg_line(writer, f"{g}_listener* listener = new {g}_listener()")
	pg_source_line(writer, c"listener.context = 0")
	pg_source_line(writer, c"listener.on_token = 0")
	for pg_rule* rule in grammar.rules:
		pg_line(writer, f"listener.on_enter_{rule.name} = 0")
		pg_line(writer, f"listener.on_exit_{rule.name} = 0")
	pg_source_line(writer, c"return listener")
	pg_source_dedent(writer)
	pg_source_blank(writer)


void pg_emit_streaming_rule_forward_declarations(pg_source_writer* writer, pg_grammar* grammar):
	char* g = grammar.name
	for pg_rule* rule in grammar.rules:
		pg_line(writer, f"int {g}_parse_{rule.name}(pg_token_stream* stream, pg_diagnostics* diagnostics, {g}_listener* listener);")
	pg_source_blank(writer)


# int <name>_match_token(stream, kind, listener): peeks, and on a kind
# match consumes and fires on_token. Mirrors pg_emit_match_token's
# AST-mode shape but returns a plain success flag instead of building a
# pg_ast_node -- every term emitter below (mandatory, optional, repeat)
# is built on this one primitive.
void pg_emit_streaming_match_token(pg_source_writer* writer, pg_grammar* grammar):
	pg_open(writer, f"int {grammar.name}_match_token(pg_token_stream* stream, int kind, {grammar.name}_listener* listener):")
	pg_source_line(writer, c"pg_token* token = pg_token_stream_peek(stream)")
	pg_open_c(writer, c"if (token.kind == kind):")
	pg_source_line(writer, c"pg_token_stream_consume(stream)")
	pg_source_line(writer, c"if (listener.on_token != 0): listener.on_token(token, listener.context)")
	pg_source_line(writer, c"return 1")
	pg_source_dedent(writer)
	pg_source_line(writer, c"return 0")
	pg_source_dedent(writer)
	pg_source_blank(writer)


# "return pg_syntax_error(...)" at the current token -- the hard-failure
# path every streaming term emitter below shares. Caller frees.
char* pg_streaming_syntax_error(char* expected):
	return pg_take(f"return pg_syntax_error(diagnostics, pg_token_stream_peek(stream), c\"{expected}\")")


# --- actions and predicates (issue #329 milestone 4) -----------------------
#
# `{ code }` action terms are verbatim W statements, one per (trimmed,
# non-empty) source line, spliced into the generated rule function at
# exactly that position -- streaming mode only, so "spliced at that
# position" already means "on the committed, straight-line path" (see
# pg_action_safety_check in analysis.w). `&{ expr }` predicate terms are a
# single boolean expression spliced as-is into an if/else-if branch
# condition by pg_emit_streaming_choice; they are handled entirely there
# and never reach pg_emit_streaming_term.
#
# Binding surface: inside an action, `$n` or `text(n)` is replaced with the
# text of term n (1-based, over the *enclosing alternative's own* term
# list, action/predicate terms included in the count) -- pg_validate_action_bindings
# below requires n to name an earlier, plain (no ?/*/+) token or literal
# term in the same alternative, so by the time pg_action_substitute runs
# every reference it sees is already known-valid.


int pg_action_matches_text_call(char* code, int i, int length):
	if ((i > 0) && pg_lexer_is_ident_part(code[i - 1] & 255)):
		return 0
	return starts_with(code + i, c"text(")


# The decimal digits of a $n / text(n) reference starting at code[j]: their
# value, or -1 when there are none. endp gets the index past the digits.
int pg_action_ref_digits(char* code, int j, int length, int* endp):
	int n = -1
	while ((j < length) && (code[j] >= '0') && (code[j] <= '9')):
		if (n < 0):
			n = 0
		n = n * 10 + (code[j] - '0')
		j = j + 1
	endp[0] = j
	return n


# Walk an action's code for $n / text(n) references, pushing each
# referenced n (1-based; duplicates allowed) to refs. Comments and
# string/char literals are opaque: a stale "$9" there is not a reference.
# Every $n whose digits run directly into an identifier character (e.g.
# `$1x`) also goes to pasted: substituting it would paste
# "action_arg_<alt>_<n-1>.text" and the following character into one
# broken identifier (".textx"), so pg_validate_action_term_bindings rejects
# the reference at generation time instead. With out != 0 the code is also
# copied there with every reference replaced by
# "action_arg_<alt_index>_<n-1>.text" -- the naming pg_emit_streaming_term
# uses when it captures a referenced token.
void pg_action_scan(char* code, int alt_index, list[int] refs, list[int] pasted, pg_source_writer* out):
	int length = strlen(code)
	int i = 0
	while (i < length):
		int start = i
		int c = code[i] & 255
		int ref = -1
		int end = 0
		if (c == '#'):
			while ((i < length) && (code[i] != 10)):
				i = i + 1
		else if ((c == '"') || (c == 39)):
			i = i + 1
			while ((i < length) && (code[i] != c)):
				if ((code[i] == 92) && (i + 1 < length)):
					i = i + 2
				else:
					i = i + 1
			if (i < length):
				i = i + 1
		else if (c == '$'):
			ref = pg_action_ref_digits(code, i + 1, length, &end)
			i = i + 1
			if (ref >= 0):
				if ((end < length) && pg_lexer_is_ident_part(code[end] & 255)):
					pasted.push(ref)
				i = end
		else if ((c == 't') && pg_action_matches_text_call(code, i, length)):
			ref = pg_action_ref_digits(code, i + 5, length, &end)
			i = i + 1
			if ((ref >= 0) && (end < length) && (code[end] == ')')):
				i = end + 1
			else:
				ref = -1
		else:
			i = i + 1
		if (ref >= 0):
			refs.push(ref)
			if (out != 0):
				pg_add(out, f"action_arg_{alt_index}_{ref - 1}.text")
		else if (out != 0):
			for k in range(start, i):
				pg_source_append_char(out, code[k])


# The referenced n values of an action's code (capture planning, the
# predicate no-bindings check).
list[int] pg_action_scan_refs(char* code):
	list[int] refs = new list[int]
	list[int] pasted = new list[int]
	pg_action_scan(code, 0, refs, pasted, 0)
	list_free[int](pasted)
	return refs


# code with every $n/text(n) replaced by "action_arg_<alt_index>_<n-1>.text".
# Caller frees the result.
char* pg_action_substitute(char* code, int alt_index):
	pg_source_writer* out = pg_source_writer_new()
	list[int] refs = new list[int]
	list[int] pasted = new list[int]
	pg_action_scan(code, alt_index, refs, pasted, out)
	list_free[int](refs)
	list_free[int](pasted)
	return pg_source_take(out)


char* pg_action_trim(char* text):
	int start = 0
	while (pg_lexer_is_space(text[start])):
		start = start + 1
	int end = strlen(text)
	while ((end > start) && pg_lexer_is_space(text[end - 1])):
		end = end - 1
	return pg_substr(text, start, end - start)


# Split trimmed code into non-empty, individually trimmed lines -- the
# "flat statements only" contract documented in parser_generator.md: each
# line becomes one pg_source_line at the writer's current indent, so an
# action body may not itself open a nested indented block (if/while/etc).
list[char*] pg_action_split_lines(char* code):
	list[char*] lines = new list[char*]
	int length = strlen(code)
	int start = 0
	for i in range(length + 1):
		if ((i == length) || (code[i] == 10)):
			char* raw = pg_substr(code, start, i - start)
			char* trimmed = pg_action_trim(raw)
			free(raw)
			if (strlen(trimmed) > 0):
				lines.push(trimmed)
			else:
				free(trimmed)
			start = i + 1
	return lines


void pg_emit_streaming_action(pg_source_writer* writer, pg_term* term, int alt_index):
	char* substituted = pg_action_substitute(term.code, alt_index)
	list[char*] lines = pg_action_split_lines(substituted)
	for char* line in lines:
		pg_source_line(writer, line)
		free(line)
	list_free[char*](lines)
	free(substituted)


# 1-indexed (size terms.length + 1, index 0 unused) membership set of term
# positions that some action in this alternative captures via $n/text(n).
# Only ever called once pg_validate_action_bindings has passed, so every
# referenced n is already known to be in range and to name a plain token
# term earlier in the same alternative.
char* pg_alt_capture_set(pg_alternative* alternative):
	int count = alternative.terms.length
	char* captures = malloc(count + 1)
	for i in range(count + 1):
		captures[i] = 0
	for pg_term* term in alternative.terms:
		if (term.kind == pg_term_kind_action()):
			list[int] refs = pg_action_scan_refs(term.code)
			for int n in refs:
				if ((n >= 1) && (n <= count)):
					captures[n] = 1
			list_free[int](refs)
	return captures


# A single term within a chosen alternative. Streaming eligibility
# (pg_streaming_check) has already ruled out ?/*/+ over a rule reference,
# so the modifier cases below only ever guard a token/literal -- always
# safe to test with zero lookahead cost via <name>_match_token. captures
# may be 0 (never capture -- used for a left-factored shared prefix, which
# pg_validate_action_bindings guarantees carries no $n/text(n) references).
void pg_emit_streaming_term(pg_source_writer* writer, pg_grammar* grammar, char* captures, pg_term* term, int alt_index, int term_index):
	if (term.kind == pg_term_kind_action()):
		pg_emit_streaming_action(writer, term, alt_index)
		return
	char* g = grammar.name
	char* match = pg_take(f"{g}_match_token(stream, {g}_token_{term.name}, listener)")
	char* error = pg_streaming_syntax_error(term.name)
	if (term.modifier == 0):
		if (pg_grammar_is_token_term(grammar, term.name) == 0):
			pg_line(writer, f"if ({g}_parse_{term.name}(stream, diagnostics, listener) == 0): return 0")
		else:
			if ((captures != 0) && (captures[term_index + 1] != 0)):
				pg_line(writer, f"pg_token* action_arg_{alt_index}_{term_index} = pg_token_stream_peek(stream)")
			pg_line(writer, f"if ({match} == 0): {error}")
	else if (term.modifier == '?'):
		pg_line(writer, f"{match}")
	else if (term.modifier == '*'):
		pg_line(writer, f"while ({match}): pass")
	else:
		pg_line(writer, f"int repeat_count_{alt_index}_{term_index} = 0")
		pg_line(writer, f"while ({match}): repeat_count_{alt_index}_{term_index}++")
		pg_line(writer, f"if (repeat_count_{alt_index}_{term_index} == 0): {error}")
	free(match)
	free(error)


void pg_emit_streaming_alternative_body(pg_source_writer* writer, pg_grammar* grammar, pg_rule* rule, int alt_index, int offset):
	pg_alternative* alternative = rule.alternatives[alt_index]
	if (offset >= alternative.terms.length):
		# The empty/epsilon alternative (e.g. a trailing unguarded
		# fallback unit, see pg_emit_streaming_choice): nothing to match,
		# so make the no-op explicit instead of emitting an empty block.
		pg_source_line(writer, c"pass")
		return
	char* captures = pg_alt_capture_set(alternative)
	for term_index in range(offset, alternative.terms.length):
		pg_emit_streaming_term(writer, grammar, captures, alternative.terms[term_index], alt_index, term_index)
	free(captures)


void pg_emit_streaming_choice(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_rule* rule, int alt_start, int alt_count, int offset, char* kind_name);


# A left-factored run, streaming mode: parse the shared prefix once (each
# term mandatory-style, per pg_emit_streaming_term) then recurse into the
# suffix choice -- no mark, nothing to rewind to on failure since a
# prefix-term failure is already a hard error by the time control would
# reach here.
void pg_emit_streaming_factored_unit(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_rule* rule, pg_choice_unit* unit, int offset):
	pg_alternative* head = rule.alternatives[unit.alt_start]
	for term_index in range(offset, offset + unit.prefix_length):
		# 0 (no captures): pg_validate_action_bindings rejects any
		# $n/text(n) reference inside an alternative that shares a
		# leading term with a sibling, so a shared prefix never needs to
		# capture a token for a later action to bind.
		pg_emit_streaming_term(writer, grammar, 0, head.terms[term_index], unit.alt_start, term_index)
	char* inner_kind = pg_guard_var_name(c"factored_kind_", unit.alt_start, offset)
	pg_emit_streaming_choice(writer, grammar, analysis, rule, unit.alt_start, unit.member_count, offset + unit.prefix_length, inner_kind)
	free(inner_kind)


# Ordered choice, streaming mode. pg_streaming_check has already proven
# every unit here is guarded, predicate-headed, or the fallback: either a
# trailing unguarded nullable "epsilon" unit or a fallback-equivalent
# nullable unit whose only later siblings are dead strict epsilons
# (mirrors pg_report_choice's empty-suffix, predicate, and
# nullable-fallback exemptions in analysis.w). The live-unit trim below
# demotes a fallback-equivalent nullable unit to the actual trailing
# position: the strict epsilons after it can never run under ordered
# choice -- the nullable suffix always matches first -- so they are not
# emitted. Guarded and predicate-headed units become an if/else-if chain,
# in declaration order, on the current token kind or the predicate
# expression respectively; the final branch is either the fallback's body
# (empty for the epsilon case, the nullable suffix's terms otherwise) or,
# when every unit was guarded/predicated, a syntax error -- there is no
# other outcome left once none of the branches match. A predicate-headed
# unit's body starts one term past the predicate itself, since the
# predicate was already consumed as this branch's condition rather than
# as a matched term.
void pg_emit_streaming_choice(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_rule* rule, int alt_start, int alt_count, int offset, char* kind_name):
	list[pg_choice_unit*] units = pg_plan_choice(analysis, rule, alt_start, alt_count, offset)
	int live_length = units.length
	for i in range(units.length):
		if (pg_choice_unit_is_nullable_fallback(analysis, rule, units, i, offset)):
			live_length = i + 1
			break
	if ((live_length == 1) && (units[0].predicate_code == 0)):
		pg_choice_unit* unit = units[0]
		if (unit.member_count == 1):
			pg_emit_streaming_alternative_body(writer, grammar, rule, unit.alt_start, offset)
		else:
			pg_emit_streaming_factored_unit(writer, grammar, analysis, rule, unit, offset)
		pg_choice_units_free(units)
		return
	int has_fallback = (units[live_length - 1].guarded == 0) && (units[live_length - 1].predicate_code == 0)
	for i in range(live_length):
		int is_fallback = has_fallback && (i == live_length - 1)
		if ((is_fallback == 0) && (units[i].predicate_code == 0)):
			pg_emit_peek_kind_line(writer, kind_name)
			break
	for i in range(live_length):
		pg_choice_unit* unit = units[i]
		char* keyword = c"else if ("
		if (i == 0):
			keyword = c"if ("
		if (has_fallback && (i == live_length - 1)):
			pg_open_c(writer, c"else:")
		else if (unit.predicate_code != 0):
			pg_open(writer, f"{keyword}{unit.predicate_code}):")
		else:
			pg_emit_kind_set_open(writer, grammar, analysis, unit.guard_set, kind_name, keyword, c"):")
		int body_offset = offset
		if (unit.predicate_code != 0):
			body_offset = offset + 1
		if (unit.member_count == 1):
			pg_emit_streaming_alternative_body(writer, grammar, rule, unit.alt_start, body_offset)
		else:
			pg_emit_streaming_factored_unit(writer, grammar, analysis, rule, unit, offset)
		pg_source_dedent(writer)
	if (has_fallback == 0):
		char* error = pg_streaming_syntax_error(rule.name)
		pg_line(writer, f"else: {error}")
		free(error)
	pg_choice_units_free(units)


void pg_emit_streaming_rule(pg_source_writer* writer, pg_grammar* grammar, pg_analysis* analysis, pg_rule* rule):
	char* g = grammar.name
	pg_open(writer, f"int {g}_parse_{rule.name}(pg_token_stream* stream, pg_diagnostics* diagnostics, {g}_listener* listener):")
	pg_line(writer, f"if (listener.on_enter_{rule.name} != 0): listener.on_enter_{rule.name}(stream, listener.context)")
	pg_emit_streaming_choice(writer, grammar, analysis, rule, 0, rule.alternatives.length, 0, c"first_kind")
	pg_line(writer, f"if (listener.on_exit_{rule.name} != 0): listener.on_exit_{rule.name}(stream, listener.context)")
	pg_source_line(writer, c"return 1")
	pg_source_dedent(writer)
	pg_source_blank(writer)


# The grammar's start rule is expected to end with an EOF term (the
# convention AST mode's sample grammars already use), so there is
# nothing extra to check here: whatever the start rule returns is the
# answer.
void pg_emit_streaming_parse_entry(pg_source_writer* writer, pg_grammar* grammar):
	char* g = grammar.name
	pg_open(writer, f"int {g}_parse_streaming(char* input, char* filename, pg_diagnostics* diagnostics, {g}_listener* listener):")
	pg_line(writer, f"pg_token_stream* stream = {g}_lex(input, filename, diagnostics)")
	pg_line(writer, f"return {g}_parse_{grammar.start_rule}(stream, diagnostics, listener)")
	pg_source_dedent(writer)
	pg_source_blank(writer)


# --- action/predicate binding validation (issue #329 milestone 4) ---------
#
# $n/text(n) is deliberately narrow (per docs/projects/parser_generator.md):
# it names the text of an earlier, plain (no ?/*/+) token or literal term
# in the *same* alternative. This also sidesteps a real complication: an
# alternative that shares a leading term with a sibling gets left-factored
# (analysis.w's pg_plan_choice), so its shared-prefix terms are parsed
# once under the factored unit's representative alt_start, not the
# member's own true alternative index -- pg_action_substitute has no way
# to know that renaming without duplicating pg_plan_choice's own factoring
# decision. Rather than do that, an action with any binding is rejected
# outright when its alternative could ever be factored with a sibling;
# rewrite the rule to avoid the shared leading term if this fires.


int pg_alt_shares_leading_term(pg_rule* rule, int alt_index):
	pg_alternative* alternative = rule.alternatives[alt_index]
	if (alternative.terms.length == 0):
		return 0
	pg_term* first = alternative.terms[0]
	if (first.kind != pg_term_kind_normal()):
		return 0
	for i, other in rule.alternatives:
		if ((i != alt_index) && (other.terms.length > 0)):
			pg_term* other_first = other.terms[0]
			if ((other_first.kind == pg_term_kind_normal()) && (other_first.modifier == first.modifier) && (strcmp(other_first.name, first.name) == 0)):
				return 1
	return 0


# "parser_generator: rule <rule>: <message>" on stderr.
void pg_rule_error(pg_rule* rule, string message):
	print2(c"parser_generator: rule ")
	print2(rule.name)
	char* text = pg_take(message)
	println2(text)
	free(text)


# Validates every $n/text(n) reference in one action term; returns the
# number of violations printed (0 == every reference in this action is
# sound). alt_index is the action's enclosing alternative's own index in
# rule.alternatives (needed only for the shared-leading-term check).
int pg_validate_action_term_bindings(pg_grammar* grammar, pg_rule* rule, pg_alternative* alternative, int alt_index, int action_index):
	pg_term* action = alternative.terms[action_index]
	list[int] refs = new list[int]
	list[int] pasted = new list[int]
	pg_action_scan(action.code, 0, refs, pasted, 0)
	int violations = 0
	# A $n whose digits run directly into an identifier character would
	# substitute into one pasted, uncompilable identifier (e.g. `$1x` ->
	# `action_arg_0_0.textx`) -- reject it here instead of splicing broken
	# member access into the generated file.
	for int n in pasted:
		pg_rule_error(rule, f": action binding ${n} is immediately followed by an identifier character -- substitution would paste them into one identifier; separate them with whitespace")
		violations = violations + 1
	list_free[int](pasted)
	if ((refs.length > 0) && pg_alt_shares_leading_term(rule, alt_index)):
		pg_rule_error(rule, f": an action's $n/text(n) binding is not supported in an alternative that shares a leading term with a sibling (left-factoring) -- rewrite the rule to avoid the shared prefix")
		violations = violations + 1
	for int n in refs:
		int ok = (n >= 1) && (n <= alternative.terms.length)
		if (ok):
			pg_term* ref_term = alternative.terms[n - 1]
			ok = (ref_term.kind == pg_term_kind_normal()) && (ref_term.modifier == 0) && pg_grammar_is_token_term(grammar, ref_term.name) && ((n - 1) < action_index)
		if (ok == 0):
			pg_rule_error(rule, f": action references invalid binding ${n} (must name an earlier plain token or literal term in the same alternative)")
			violations = violations + 1
	list_free[int](refs)
	return violations


int pg_validate_action_bindings(pg_grammar* grammar):
	int violations = 0
	for pg_rule* rule in grammar.rules:
		for a, alternative in rule.alternatives:
			for t, term in alternative.terms:
				if (term.kind == pg_term_kind_action()):
					violations = violations + pg_validate_action_term_bindings(grammar, rule, alternative, a, t)
				else if (term.kind == pg_term_kind_predicate()):
					# Predicates run before any term has matched, so
					# $n/text(n) can never bind there -- reject at
					# generation time rather than splicing "$n" verbatim
					# into the generated file as uncompilable W.
					list[int] prefs = pg_action_scan_refs(term.code)
					if (prefs.length > 0):
						pg_rule_error(rule, f": $n/text(n) bindings are not available in a &{{ }} predicate (no term has matched yet)")
						violations = violations + 1
					list_free[int](prefs)
	return violations


# The module header both generation modes share.
pg_source_writer* pg_generated_module_new(pg_grammar* grammar, char* banner):
	pg_source_writer* writer = pg_source_writer_new()
	pg_source_line(writer, banner)
	pg_source_line(writer, c"import lib.lib")
	pg_source_line(writer, c"import libs.extras.parser_generator.runtime")
	pg_source_blank(writer)
	pg_emit_grammar_imports(writer, grammar)
	pg_emit_token_constants(writer, grammar)
	return writer


char* pg_generate_streaming_parser(pg_grammar* grammar):
	if ((pg_action_safety_check(grammar) > 0) || (pg_validate_action_bindings(grammar) > 0) || (pg_streaming_check(grammar) > 0)):
		return 0
	pg_analysis* analysis = pg_analyze_grammar(grammar)
	pg_source_writer* writer = pg_generated_module_new(grammar, c"/* generated by ParserGenerator (streaming mode) */")
	pg_emit_token_name(writer, grammar)
	pg_emit_streaming_types(writer, grammar)
	pg_emit_streaming_listener_struct(writer, grammar)
	pg_emit_streaming_listener_new(writer, grammar)
	pg_emit_matcher_forward_declarations(writer, grammar)
	pg_emit_streaming_rule_forward_declarations(writer, grammar)
	pg_emit_expression_matchers(writer, grammar)
	pg_emit_advance_position(writer, grammar)
	pg_emit_lexer(writer, grammar)
	pg_emit_streaming_match_token(writer, grammar)
	for pg_rule* rule in grammar.rules:
		pg_emit_streaming_rule(writer, grammar, analysis, rule)
	pg_emit_streaming_parse_entry(writer, grammar)
	pg_analysis_free(analysis)
	return pg_source_take(writer)


char* pg_generate_ast_parser(pg_grammar* grammar):
	if (pg_action_safety_check(grammar) > 0):
		return 0
	pg_analysis* analysis = pg_analyze_grammar(grammar)
	pg_source_writer* writer = pg_generated_module_new(grammar, c"/* generated by ParserGenerator */")
	pg_emit_ast_constants(writer, grammar)
	pg_emit_token_name(writer, grammar)
	pg_emit_forward_declarations(writer, grammar)
	pg_emit_expression_matchers(writer, grammar)
	pg_emit_advance_position(writer, grammar)
	pg_emit_lexer(writer, grammar)
	pg_emit_match_token(writer, grammar)
	for pg_rule* rule in grammar.rules:
		pg_emit_rule(writer, grammar, analysis, rule)
	pg_emit_parse_entry(writer, grammar)
	pg_analysis_free(analysis)
	return pg_source_take(writer)


char* pg_generate_parser(pg_grammar* grammar):
	if (grammar.mode == pg_grammar_mode_streaming()):
		return pg_generate_streaming_parser(grammar)
	return pg_generate_ast_parser(grammar)
