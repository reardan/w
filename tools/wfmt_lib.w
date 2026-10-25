/*
wfmt: the rewriting W formatter (issue #716; docs/projects/wfmt.md).

wfmt_format(source, filename) returns the canonical spelling of a W
source file, or 0 with wfmt_error set. It is built on the
ParserGenerator W grammar (tests/parser_generator/w.pg), whose lexer is
lossless: every byte of the input is a token, whitespace and comments
on the hidden channel. The parser's AST gives each code token a role
(binary operator, unary prefix, call parenthesis, pointer star, ...),
and the output is the token stream re-emitted with canonical spacing.

Only whitespace changes: tokens are never added, removed, reordered or
moved to another line, so the output compiles to the same code. Before
returning, the output is lexed again and its tokens compared with the
input's; a mismatch is reported as an internal error instead of being
written (in practice, a string or char literal left unterminated at
the end of a file with no final newline). The one change to the line
structure is the blank-line rule
also applied by 'w check --fix': blank lines at the start and end of
the file go, and runs of more than two blank lines shrink to two.

The canonical style:
- indentation is tabs; a space indent of at least four columns becomes
  a tab per four columns, the 'w check --fix' rule
- no trailing whitespace, LF line endings, one final newline
- one space around binary and assignment operators, after commas,
  semicolons and ':' (block, label, named argument, map entry), after
  keywords and between words
- no space inside brackets, before ',' ';' ':' ')' ']' '}', around '.',
  after a unary prefix operator, before a postfix '++' '--' '?', before
  a call, index or generic bracket, before a pointer '*', or around a
  slice ':'
- comments keep their text and position (trailing whitespace inside
  them goes); a trailing comment keeps its original separation from the
  code, or gets one space when it had none
- strings, char literals and 'asm' function bodies are left alone

Lines are never joined or split, so long lines stay a 'check --lint'
finding (line-too-long) rather than a formatting change: a line break
moves debug line numbers, and W's newline-sensitive grammar only allows
breaks in a few places. A line containing 'nolint' is copied verbatim,
as 'w check --fix' does, and so is every line from a '# wfmt: off'
comment through the next '# wfmt: on' comment.
*/
import lib.lib
import libs.extras.parser_generator.runtime
import bin.wfmt_w_parser


# Token roles, assigned from the token's kind and its AST parent
const int wfmt_role_word = 0         # names, keywords, literals
const int wfmt_role_binop = 1        # spaced on both sides
const int wfmt_role_unary = 2        # prefix: no space after
const int wfmt_role_postfix = 3      # x++ x-- x?: no space before
const int wfmt_role_comma = 4        # , ;: none before, one after
const int wfmt_role_open_tight = 5   # call/index/generic bracket
const int wfmt_role_open_loose = 6   # grouping paren, brace block
const int wfmt_role_close = 7
const int wfmt_role_dot = 8
const int wfmt_role_colon = 9        # block/label/named-arg colon
const int wfmt_role_tight = 10       # slice ':'
const int wfmt_role_pointer = 11     # 'int* p'
const int wfmt_role_ellipsis = 12
const int wfmt_role_opname = 13      # 'operator+'
const int wfmt_role_verbatim = 14    # asm function body tokens
const int wfmt_role_brace_open = 15  # '{ return 1 }' brace block
const int wfmt_role_brace_close = 16


# Set when wfmt_format returns 0
char* wfmt_error


# 1: apply only the blank-line rules and copy every other line verbatim.
# The tree check compiles this as the reference: the blank lines it
# drops move line numbers, so only the rest of the formatting can be
# held to the same binary.
int wfmt_lines_only


# Role per token, indexed by the token's byte offset in the source
int* wfmt_roles


int wfmt_is_ast_kind(pg_ast_node* node, int kind):
	return (node != 0) && (node.token == 0) && (node.kind == kind)


int wfmt_is_binop_kind(int k):
	if ((k == wlang_token_ASSIGN) || (k == wlang_token_COLON_ASSIGN) || (k == wlang_token_ARROW)): return 1
	if ((k == wlang_token_PLUS_ASSIGN) || (k == wlang_token_MINUS_ASSIGN) || (k == wlang_token_STAR_ASSIGN)): return 1
	if ((k == wlang_token_SLASH_ASSIGN) || (k == wlang_token_PERCENT_ASSIGN) || (k == wlang_token_AMP_ASSIGN)): return 1
	if ((k == wlang_token_PIPE_ASSIGN) || (k == wlang_token_CARET_ASSIGN)): return 1
	if ((k == wlang_token_SHL_ASSIGN) || (k == wlang_token_SHR_ASSIGN)): return 1
	if ((k == wlang_token_AND_AND) || (k == wlang_token_OR_OR) || (k == wlang_token_EQ_EQ) || (k == wlang_token_BANG_EQ)): return 1
	if ((k == wlang_token_LT_EQ) || (k == wlang_token_GT_EQ) || (k == wlang_token_LT) || (k == wlang_token_GT)): return 1
	if ((k == wlang_token_SHIFT_LEFT) || (k == wlang_token_SHIFT_RIGHT)): return 1
	if ((k == wlang_token_PLUS) || (k == wlang_token_MINUS) || (k == wlang_token_STAR) || (k == wlang_token_SLASH)): return 1
	if ((k == wlang_token_PERCENT) || (k == wlang_token_AMP) || (k == wlang_token_PIPE) || (k == wlang_token_CARET)): return 1
	return 0


int wfmt_token_role(pg_token* token, pg_ast_node* parent):
	int k = token.kind
	if ((k == wlang_token_COMMA) || (k == wlang_token_SEMI)): return wfmt_role_comma
	if ((k == wlang_token_LBRACE) || (k == wlang_token_RBRACE)):
		int block = wfmt_is_ast_kind(parent, wlang_ast_block)
		if (k == wlang_token_RBRACE):
			if (block): return wfmt_role_brace_close
			return wfmt_role_close
		if (block): return wfmt_role_brace_open
		return wfmt_role_open_tight
	if ((k == wlang_token_RPAREN) || (k == wlang_token_RBRACK)): return wfmt_role_close
	if (k == wlang_token_DOT): return wfmt_role_dot
	if (k == wlang_token_ELLIPSIS): return wfmt_role_ellipsis
	if (k == wlang_token_LBRACK): return wfmt_role_open_tight
	if (k == wlang_token_LPAREN):
		if (wfmt_is_ast_kind(parent, wlang_ast_grouped_expr) || wfmt_is_ast_kind(parent, wlang_ast_paren_expression_opt)): return wfmt_role_open_loose
		return wfmt_role_open_tight
	if (k == wlang_token_COLON):
		if (wfmt_is_ast_kind(parent, wlang_ast_slice_tail)): return wfmt_role_tight
		if (wfmt_is_ast_kind(parent, wlang_ast_postfix_tail)): return wfmt_role_binop
		return wfmt_role_colon
	if (k == wlang_token_QUESTION):
		# 'c ? a : b' is postfix_tail's four-term alternative; a bare
		# '?' is the result-unwrap suffix
		if (wfmt_is_ast_kind(parent, wlang_ast_postfix_tail) && (pg_ast_child_count(parent) == 4)): return wfmt_role_binop
		return wfmt_role_postfix
	if ((k == wlang_token_PLUS_PLUS) || (k == wlang_token_MINUS_MINUS)):
		if (wfmt_is_ast_kind(parent, wlang_ast_unary_op)): return wfmt_role_unary
		return wfmt_role_postfix
	if ((k == wlang_token_BANG) || (k == wlang_token_TILDE)): return wfmt_role_unary
	if (wfmt_is_ast_kind(parent, wlang_ast_unary_op)): return wfmt_role_unary
	if (wfmt_is_ast_kind(parent, wlang_ast_pointer_part)): return wfmt_role_pointer
	if (wfmt_is_ast_kind(parent, wlang_ast_arith_op) || wfmt_is_ast_kind(parent, wlang_ast_operator_token)): return wfmt_role_opname
	if (wfmt_is_binop_kind(k)): return wfmt_role_binop
	return wfmt_role_word


# Does a binary operator occur under node? (Its roles are assigned.)
int wfmt_has_binop(pg_ast_node* node):
	if (node == 0): return 0
	if (node.token != 0): return wfmt_roles[node.token.offset] == wfmt_role_binop
	for i in range(pg_ast_child_count(node)):
		if (wfmt_has_binop(pg_ast_child(node, i))): return 1
	return 0


# The parent is passed down rather than read from node.parent: leaf nodes
# of factored prefixes are shared with abandoned alternatives, so their
# parent link can name a node that is not in the final tree.
void wfmt_assign_roles(pg_ast_node* node, pg_ast_node* parent, int verbatim):
	if (node == 0): return
	if (node.token != 0):
		int role = wfmt_role_verbatim
		if (verbatim == 0): role = wfmt_token_role(node.token, parent)
		wfmt_roles[node.token.offset] = role
		return
	if (node.kind == wlang_ast_asm_body): verbatim = 1
	int n = pg_ast_child_count(node)
	for i in range(n): wfmt_assign_roles(pg_ast_child(node, i), node, verbatim)
	# A slice ':' is tight between simple bounds ('a[1:n]', 'a[-3:f(x)]')
	# and spaced like a binary operator when a bound has one
	# ('a[i * w : j * w]')
	if (wfmt_is_ast_kind(node, wlang_ast_postfix_tail) && (n == 4) && wfmt_is_ast_kind(pg_ast_child(node, 2), wlang_ast_slice_tail) && (pg_ast_child_count(pg_ast_child(node, 2)) > 0)):
		pg_ast_node* slice = pg_ast_child(node, 2)
		pg_ast_node* upper = 0
		if (pg_ast_child_count(slice) > 1): upper = pg_ast_child(slice, 1)
		if (wfmt_has_binop(pg_ast_child(node, 1)) || wfmt_has_binop(upper)):
			wfmt_roles[pg_ast_child(slice, 0).token.offset] = wfmt_role_binop


int wfmt_is_word_char(int c):
	c = c & 255
	return pg_lexer_is_alnum(c) || (c >= 128)


# Would writing a and b with nothing between them lex differently?
int wfmt_would_merge(pg_token* a, pg_token* b):
	if ((a.length == 0) || (b.length == 0)): return 0
	int x = a.text[a.length - 1] & 255
	int y = b.text[0] & 255
	if (wfmt_is_word_char(x) && (wfmt_is_word_char(y) || (y == '"') || (y == 39))): return 1
	if ((a.kind == wlang_token_NUMBER) && (y == '.')): return 1
	if ((x == '.') && ((b.kind == wlang_token_NUMBER) || (y == '.'))): return 1
	if ((x == '/') && (y == '*')): return 1
	if (y == '='):
		if ((x == '<') || (x == '>') || (x == '=') || (x == '!') || (x == '+') || (x == '-') || (x == ':')): return 1
		if ((x == '*') || (x == '/') || (x == '%') || (x == '&') || (x == '|') || (x == '^')): return 1
	if ((x == y) && ((x == '<') || (x == '>') || (x == '+') || (x == '-') || (x == '&') || (x == '|'))): return 1
	if ((x == '-') && (y == '>')): return 1
	return 0


# The canonical gap between two code tokens on one line: 0 for none,
# 1 for one space
int wfmt_gap(int a, int b):
	if ((a == wfmt_role_brace_open) || (b == wfmt_role_brace_close)): return 1
	if (b == wfmt_role_close): return 0
	if ((a == wfmt_role_open_tight) || (a == wfmt_role_open_loose)): return 0
	if (b == wfmt_role_comma): return 0
	if (a == wfmt_role_comma): return 1
	if ((a == wfmt_role_tight) || (b == wfmt_role_tight)): return 0
	if (b == wfmt_role_colon): return 0
	if (a == wfmt_role_colon): return 1
	if ((a == wfmt_role_dot) || (b == wfmt_role_dot)): return 0
	if (b == wfmt_role_postfix): return 0
	if (a == wfmt_role_unary): return 0
	if (b == wfmt_role_open_tight): return 0
	if ((a == wfmt_role_opname) || (b == wfmt_role_opname)): return 0
	if ((a == wfmt_role_binop) || (b == wfmt_role_binop)): return 1
	if (b == wfmt_role_ellipsis): return 0
	if (b == wfmt_role_pointer): return 0
	return 1


# Keywords that never name a callee. The grammar's name_token accepts
# every keyword (for the compiler's contextual ones), so the parser can
# read 'if (a) || (b):' as a call of 'if'; the space after the keyword
# is kept regardless.
int wfmt_is_control_keyword(int k):
	if ((k == wlang_token_KW_IF) || (k == wlang_token_KW_ELIF) || (k == wlang_token_KW_ELSE) || (k == wlang_token_KW_WHILE)): return 1
	if ((k == wlang_token_KW_FOR) || (k == wlang_token_KW_IN) || (k == wlang_token_KW_SWITCH) || (k == wlang_token_KW_CASE)): return 1
	if ((k == wlang_token_KW_RETURN) || (k == wlang_token_KW_YIELD) || (k == wlang_token_KW_DEFER)): return 1
	return 0


int wfmt_ends_operand(int role):
	return (role == wfmt_role_word) || (role == wfmt_role_close) || (role == wfmt_role_postfix)


int wfmt_is_space_kind(int k):
	return (k == pg_token_whitespace_kind()) || (k == wlang_token_TAB) || (k == wlang_token_INLINE_TAB)


int wfmt_is_comment_kind(int k):
	return (k == wlang_token_LINE_COMMENT) || (k == wlang_token_BLOCK_COMMENT)


int wfmt_contains(char* text, int start, int end, char* word):
	int n = strlen(word)
	int i = start
	while (i + n <= end):
		int j = 0
		while ((j < n) && (text[i + j] == word[j])): j = j + 1
		if (j == n): return 1
		i = i + 1
	return 0


# Append a comment's text without the whitespace before each of its line
# ends (a line comment's single end is the end of the token)
void wfmt_append_comment(string_builder* out, pg_token* token):
	int i = 0
	while (i < token.length):
		int end = i
		while ((end < token.length) && (token.text[end] != 10)): end = end + 1
		int stop = end
		while ((stop > i) && ((token.text[stop - 1] == ' ') || (token.text[stop - 1] == 9) || (token.text[stop - 1] == 13))): stop = stop - 1
		string_append_bytes(out, &token.text[i], stop - i)
		if (end < token.length): string_append_char(out, 10)
		i = end + 1


# Leading whitespace: kept when it is all tabs, otherwise re-indented
# like 'w check --fix' (a tab per four columns, tabs advancing to the
# next stop; an indent narrower than one tab is left alone)
void wfmt_append_indent(string_builder* out, char* text, int length):
	int has_space = 0
	int width = 0
	for i in range(length):
		if (text[i] == 9): width = width + 4 - width % 4
		else:
			has_space = 1
			width = width + 1
	if ((has_space == 0) || (width < 4)):
		string_append_bytes(out, text, length)
		return
	for i in range(width / 4): string_append_char(out, 9)
	for i in range(width % 4): string_append_char(out, ' ')


# Line assembly and the blank-line rules
struct wfmt_writer:
	string_builder* out
	int seen_code
	int pending_blanks
	int blank_run


void wfmt_emit_line(wfmt_writer* w, char* text, int length, int blank):
	if (blank):
		if (w.seen_code == 0): return
		w.blank_run = w.blank_run + 1
		if (w.blank_run <= 2): w.pending_blanks = w.pending_blanks + 1
		return
	for i in range(w.pending_blanks): string_append_char(w.out, 10)
	w.pending_blanks = 0
	w.blank_run = 0
	w.seen_code = 1
	string_append_bytes(w.out, text, length)
	string_append_char(w.out, 10)


# The non-whitespace tokens of a stream must survive formatting
# unchanged, comments up to the trailing whitespace their lines lose.
# Caller frees the key.
char* wfmt_comment_key(pg_token* token):
	string_builder* s = string_new()
	wfmt_append_comment(s, token)
	char* text = s.data
	free(s)
	return text


int wfmt_next_kept(pg_token_stream* stream, int i):
	int n = pg_token_stream_all_count(stream)
	while (i < n):
		int k = pg_token_stream_all_get(stream, i).kind
		if ((wfmt_is_space_kind(k) == 0) && (k != wlang_token_NEWLINE) && (k != wlang_token_EOF)): return i
		i = i + 1
	return n


int wfmt_same_tokens(pg_token_stream* a, pg_token_stream* b):
	int i = wfmt_next_kept(a, 0)
	int j = wfmt_next_kept(b, 0)
	while ((i < pg_token_stream_all_count(a)) && (j < pg_token_stream_all_count(b))):
		pg_token* x = pg_token_stream_all_get(a, i)
		pg_token* y = pg_token_stream_all_get(b, j)
		if (x.kind != y.kind): return 0
		if (wfmt_is_comment_kind(x.kind)):
			char* kx = wfmt_comment_key(x)
			char* ky = wfmt_comment_key(y)
			int differ = strcmp(kx, ky) != 0
			free(kx)
			free(ky)
			if (differ): return 0
		else if (strcmp(x.text, y.text) != 0): return 0
		i = wfmt_next_kept(a, i + 1)
		j = wfmt_next_kept(b, j + 1)
	return (i == pg_token_stream_all_count(a)) && (j == pg_token_stream_all_count(b))


char* wfmt_fail(char* filename, int line, char* message):
	string_builder* s = string_new()
	string_append(s, filename)
	string_append_char(s, ':')
	string_append(s, itoa(line))
	string_append(s, c": ")
	string_append(s, message)
	wfmt_error = s.data
	free(s)
	return 0


char* wfmt_format(char* source, char* filename):
	wfmt_error = 0
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = wlang_lex(source, filename, diagnostics)
	# The stream owns every AST node, so one free releases the parse
	pg_token_stream_own_ast(stream)
	pg_ast_node* root = 0
	if (pg_diagnostics_count(diagnostics) == 0): root = wlang_parse_program(stream, diagnostics)
	if ((root == 0) || (pg_diagnostics_count(diagnostics) > 0)):
		if (pg_diagnostics_count(diagnostics) > 0):
			pg_diagnostic* d = pg_diagnostics_get(diagnostics, 0)
			wfmt_fail(filename, d.line, d.message)
		else: wfmt_fail(filename, 1, c"syntax error")
		pg_token_stream_free(stream)
		pg_diagnostics_free(diagnostics)
		return 0

	int source_length = strlen(source)
	wfmt_roles = cast(int*, malloc((source_length + 1) * sizeof(int)))
	for i in range(source_length + 1): wfmt_roles[i] = wfmt_role_word
	wfmt_assign_roles(root, 0, 0)

	wfmt_writer* w = new wfmt_writer()
	w.out = string_new()
	string_builder* line = string_new()
	string_builder* space = string_new()
	int line_start = 0
	int at_line_start = 1
	int blank = 1
	int verbatim = 0
	int off = 0
	int turn_off = 0
	int turn_on = 0
	pg_token* prev = 0
	int prev_role = 0
	int prev_first = 0
	int prev_prev_role = -1
	int n = pg_token_stream_all_count(stream)
	for i in range(n):
		pg_token* t = pg_token_stream_all_get(stream, i)
		int k = t.kind
		if ((k == wlang_token_NEWLINE) || (k == wlang_token_EOF)):
			int end = t.offset
			if ((k == wlang_token_EOF) && (end == line_start) && blank): break
			if (wfmt_lines_only && (blank == 0)): wfmt_emit_line(w, &source[line_start], end - line_start, 0)
			else if (off || turn_off || turn_on || wfmt_contains(source, line_start, end, c"nolint")):
				wfmt_emit_line(w, &source[line_start], end - line_start, 0)
			else: wfmt_emit_line(w, line.data, line.length, blank)
			if (turn_off): off = 1
			if (turn_on): off = 0
			turn_off = 0
			turn_on = 0
			string_clear(line)
			string_clear(space)
			line_start = end + t.length
			at_line_start = 1
			blank = 1
			prev = 0
			if (k == wlang_token_EOF): break
			continue
		if (wfmt_is_space_kind(k)):
			string_append_bytes(space, t.text, t.length)
			continue
		if (k == wlang_token_LINE_COMMENT):
			if (wfmt_contains(t.text, 0, t.length, c"wfmt: off")): turn_off = 1
			if (wfmt_contains(t.text, 0, t.length, c"wfmt: on")): turn_on = 1
		int role = wfmt_roles[t.offset]
		int first = 0
		if (at_line_start):
			wfmt_append_indent(line, space.data, space.length)
			at_line_start = 0
			first = 1
		else if (wfmt_is_comment_kind(k) || wfmt_is_comment_kind(prev.kind) || (role == wfmt_role_verbatim) || (prev_role == wfmt_role_verbatim)):
			# Comments and asm bodies keep their original separation;
			# a trailing comment gets at least one space
			if ((space.length == 0) && (k == wlang_token_LINE_COMMENT)): string_append_char(line, ' ')
			else: string_append_bytes(line, space.data, space.length)
		else:
			int gap = wfmt_gap(prev_role, role)
			# A binary operator that opens a continuation line keeps
			# hugging its operand: the grammar is permissive there
			if (prev_first && (prev_role == wfmt_role_binop) && (space.length == 0)): gap = 0
			# A prefix operator straight after an operand ('range * n'
			# with a variable named range) is the permissive grammar
			# misreading a binary operator: keep its original spacing
			if ((prev_role == wfmt_role_unary) && wfmt_ends_operand(prev_prev_role) && (space.length > 0)): gap = 1
			if ((role == wfmt_role_open_tight) && wfmt_is_control_keyword(prev.kind)): gap = 1
			if ((gap == 0) && wfmt_would_merge(prev, t)): gap = 1
			if (gap): string_append_char(line, ' ')
		string_clear(space)
		if (wfmt_is_comment_kind(k)): wfmt_append_comment(line, t)
		else: string_append_bytes(line, t.text, t.length)
		blank = 0
		prev = t
		prev_prev_role = prev_role
		if (first): prev_prev_role = -1
		prev_role = role
		prev_first = first

	char* result = w.out.data
	free(w.out)
	free(w)
	string_free(line)
	string_free(space)
	free(wfmt_roles)

	pg_diagnostics* check = pg_diagnostics_new()
	pg_token_stream* again = wlang_lex(result, filename, check)
	int same = (pg_diagnostics_count(check) == 0) && wfmt_same_tokens(stream, again)
	pg_token_stream_free(stream)
	pg_token_stream_free(again)
	pg_diagnostics_free(diagnostics)
	pg_diagnostics_free(check)
	if (same == 0):
		free(result)
		return wfmt_fail(filename, 1, c"formatting would change a token (an unterminated literal at the end of the file?); file left unchanged")
	return result
