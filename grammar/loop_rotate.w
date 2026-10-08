# Loop rotation (unit A7 of docs/projects/codegen_gap_plan.md, §2.5):
# while and for loops are bottom-tested.
#
# A top-tested loop costs two taken branches per iteration: the
# conditional exit at the head falls through, and the unconditional
# back edge at the bottom is taken to the head. A rotated loop enters by
# jumping over its body to the condition, which sits at the bottom and
# branches BACK to the body's head while it holds -- one taken branch
# per iteration, and the comparison-branch fusion of #427 / unit A6
# (be_br_nonzero_discard, cond_branch_consume with on_true) gives the
# 'cmp; jcc head' pair directly:
#
#	jmp cond                 (be_loop_entry)
#	[P2 alignment pad]
#   head:                    (be_ctrl_loop: the back edge's target)
#	body
#   continue:                (while: a block region; for: before the step)
#	[for: the step]
#   cond:                    (be_loop_entry_land)
#	condition; jcc head      (branch when TRUE)
#   exit:                    (the break region)
#
# A for loop's condition is synthesized by the grammar from the hidden
# range or cursor slots, so it is simply emitted after the body
# (grammar/for_statement.w, code_generator/loop_ast.w). A while loop's
# condition is source text that precedes the body: the single-pass
# emitter cannot hold its code back, so the loop skips the condition's
# tokens (loop_rotate_skip_condition), parses and emits the body, returns
# the lexer to the condition (loop_rotate_mark / loop_rotate_return, the
# same absolute getchar_seek the generic and defer re-parses use), parses
# it as the bottom test, and returns the lexer to the end of the body.
# The skip is a bracket-depth token walk that understands exactly what
# can end a condition (a ':' outside brackets and ternaries, or a '{'
# block opener after an operand) and declines everything else (a
# template string, an unexpected brace, a newline outside brackets); a
# declined loop is emitted top-tested, byte-for-byte the pre-unit shape,
# so the walk can never misplace a body, only miss a rotation.
#
# x86/x64 (win64 shares the emitter) and arm64, on by default;
# --no-loop-rotate (and -O0) keeps every loop top-tested. wasm and PTX
# have structured control flow (a 'loop' block cannot be entered in the
# middle) and never rotate. tests/loop_rotate_test.w pins the shapes,
# regalloc_diff_test compares every test program with and without the
# flag, and the retained-tree twin (grammar/ast_loop.w,
# code_generator/loop_ast.w) emits the same bytes.

# --stats: while loops rotated, while loops whose condition skip
# declined (emitted top-tested), and returns to a position outside the
# descriptor's buffered window (a seek and a read, not a cursor move).
int loop_rotate_whiles
int loop_rotate_declined
int loop_rotate_seeks


int loop_rotate_on():
	return (target_isa <= 1) && (loop_rotate_disabled == 0)


# Record the lexer at the current token: the snapshot plus the token's
# text (malloc'd, returned). The source position is byte_offset, which
# every path that repositions the descriptor re-derives (compiler/
# tokenizer.w, diag_context_collect), so the snapshot carries it.
char* loop_rotate_mark(tokenizer_snapshot* s):
	tokenizer_snapshot_save(s)
	return strclone(token)


# Return the lexer to a mark, re-reading the source from there, and
# release the mark's text.
void loop_rotate_return(tokenizer_snapshot* s, char* text):
	tokenizer_snapshot_restore(s, text)
	if ((file >= 0) && (file < GETCHAR_MAX_FD)):
		int window_start = getchar_kernel_pos[file] - getchar_limit[file]
		if ((byte_offset < window_start) || (byte_offset > getchar_kernel_pos[file])): loop_rotate_seeks = loop_rotate_seeks + 1
	getchar_seek(file, byte_offset)
	free(text)


int loop_rotate_skip_walk();


# With the condition's first token current, advance to the token that
# opens the body: the ':' outside every bracket and ternary, or the '{'
# of a brace block, which follows an operand (an identifier, a literal,
# a closing bracket). Returns 1 with that token current, 0 when the walk
# declined (the caller returns to its mark and emits the loop
# top-tested). Typed container literals ('map[K, V]{...}', 'set[T]{...}',
# 'list[T]{...}') are the only braces an expression may hold: the '{'
# right after the ']' that closes the type's bracket is one. Template
# strings are declined because their chunks are lexed by the template
# grammar, not get_token.
int loop_rotate_skip_condition():
	if (loop_rotate_skip_walk()):
		loop_rotate_whiles = loop_rotate_whiles + 1
		return 1
	loop_rotate_declined = loop_rotate_declined + 1
	return 0


int loop_rotate_skip_walk():
	int depth = 0
	int ternaries = 0
	int operand = 0        # the previous token ended an operand
	int container = 0      # the previous token was 'map', 'set' or 'list'
	int type_bracket = 0   # depth inside a container type's '[...]', 0 none
	int literal_brace = 0  # a '{' now would open a typed container literal
	while (1):
		int c = token[0] & 255
		if (c == 0): return 0
		if ((depth == 0) && token_newline): return 0
		int single = token[1] == 0
		int next_container = 0
		int next_literal = 0
		if (single && ((c == '(') || (c == '['))):
			if ((c == '[') && container): type_bracket = depth + 1
			depth = depth + 1
			operand = 0
		elif (single && (c == '{')):
			if (literal_brace == 0):
				if ((depth > 0) || (operand == 0)): return 0
				return 1
			depth = depth + 1
			operand = 0
		elif (single && ((c == ')') || (c == ']') || (c == '}'))):
			if (depth == 0): return 0
			if ((c == ']') && (type_bracket == depth)):
				type_bracket = 0
				next_literal = 1
			depth = depth - 1
			operand = 1
		elif (single && (c == '?')):
			if (depth == 0): ternaries = ternaries + 1
			operand = 0
		elif (single && (c == ':')):
			if (depth == 0):
				if (ternaries == 0): return 1
				ternaries = ternaries - 1
			operand = 0
		elif ((c == 'f') && (token[1] == '"')):
			return 0
		else:
			operand = is_ident_start_byte(c) || is_utf8_lead_byte(c) || ((c >= '0') && (c <= '9')) || (c == '"') || (c == 39)
			if (operand):
				if (strcmp(token, c"in") == 0): operand = 0
				elif ((strcmp(token, c"map") == 0) || (strcmp(token, c"set") == 0) || (strcmp(token, c"list") == 0)): next_container = 1
		container = next_container
		literal_brace = next_literal
		get_token()
	return 0
