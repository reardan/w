/*
Go-style 'defer' statements (docs/projects/defer.md).

	defer close(fd)

registers a deferred statement; every registered statement runs in LIFO
order at each function exit: before each 'return' and at the function's
fall-through end. Defers are function-scoped (not block-scoped).

AST registration captures supported plain-call expressions as unbound
syntax trees. Each exit resolves the names against its live scope and
builds a typed expression tree, so shadowed and later-declared locals
bind at exit time. No arguments or symbol-table offsets are captured at
registration. The same tree can therefore serve different exit scopes.

A source span remains for unsupported syntax or exit-site bindings. That
path reparses from retained bytes (or reopens the source in streaming
mode), preserving existing diagnostics and conversions. See defer_ast.w
for the intentionally conservative reusable subset.

Local addresses use the exit's live stack_pos, never the registration
site's operand-stack depth.

v1 restricts the deferred statement to a simple expression statement
(typically a call) so the re-parse cannot declare variables or change
control flow, keeping stack_pos bookkeeping balanced. defer_register()
rejects the other statement forms up front.

This file is compiled by the committed seed: only seed-understood
syntax here.
*/

# Defined later in the grammar; the single-pass compiler needs the
# declaration up front.
int expression();
int ast_deferred_expression();
int ast_defer_registration();
int ast_scoped_defer_enabled();
int retained_source_next_line_token(int source, int offset);
int defer_tree_capture();
int defer_tree_emit(int index);
void defer_tree_free(int address);
int defer_tree_pending
int defer_tree_captures
int defer_tree_emissions
int defer_reparse_exits


/*
Registry: one record per deferred statement of the function currently
being compiled; defer_reset() clears it at function start.
*/
struct defer_span_record:
	char* file    # path to reopen for the re-parse
	int offset    # byte offset of the span start
	int line      # 0-based, for diagnostics during the re-parse
	int column    # 0-based
	int source    # retained source version holding the span, or -1 (S2.3)
	int tree      # owned unbound deferred-call syntax, 0 for fallback
	int scope     # -1 legacy function defer, -2 retired, otherwise lexical node


list[defer_span_record] defer_spans


int defer_count():
	if (cast(int, defer_spans) == 0): return 0
	return defer_spans.length


# Discards every record past the first n without touching the backing
# capacity: the REPL and the debugger's evaluator roll back a failed
# entry with this (the type_table_truncate trick — list[T]'s '.length'
# is read-only at the language level).
void defer_truncate(int n):
	defer_tree_free(defer_tree_pending)
	defer_tree_pending = 0
	if (cast(int, defer_spans) == 0): return;
	for i in range(n, defer_spans.length):
		defer_tree_free(defer_spans[i].tree)
		free(defer_spans[i].file)
	__w_list* raw = cast(__w_list*, defer_spans)
	raw.length = n


# Armed by function_definition right before it parses the body: the
# next block statement() opens is the function body, and the function's
# fall-through defers must be emitted just before THAT block closes,
# while the body's locals are still in the symbol table and on the
# stack (the block pops both on close). The block handler consumes the
# flag on entry, so nested blocks never see it.
int defer_function_body_pending


# Called at the start of every function body: defers never leak from
# one function into the next.
void defer_reset():
	defer_truncate(0)
	defer_function_body_pending = 0


/*
v1 form check: the deferred statement must be a simple expression
statement. Control flow, declarations and blocks are rejected here,
with the first token of the deferred statement current.
*/
void defer_check_form():
	if ((token_newline != 0) || (token[0] == 0)):
		error(c"a statement must follow 'defer' on the same line")
	if (peek(c"return")): error(c"'return' is not allowed in a deferred statement")
	if (peek(c"defer")): error(c"'defer' cannot be nested in a deferred statement")
	if (peek(c"if") | peek(c"elif") | peek(c"else") | peek(c"while") | peek(c"for") |
			peek(c"break") | peek(c"continue") | peek(c"yield") | peek(c"pass") |
			peek(c"debugger") | peek(c"raw_asm") | peek(c"{") | peek(c":")):
		error(c"deferred statement must be a simple expression statement")
	if (peek(c"const") | (peek(c"map") & (nextc == '[')) |
			(peek(c"set") & (nextc == '[')) | (peek(c"list") & (nextc == '[')) |
			(type_lookup(token) >= 0) | generic_type_starts_here()):
		error(c"deferred statement cannot declare a variable")


# Add a deferred statement's span to the registry (path is owned by the
# record from here on).
void defer_record_span(char* path, int offset, int line, int column):
	if (cast(int, defer_spans) == 0): defer_spans = new list[defer_span_record]
	defer_span_record rec
	rec.file = path
	rec.offset = offset
	rec.line = line
	rec.column = column
	rec.tree = 0
	rec.scope = -1
	if (retained_parent >= 0):
		retained_record* registration = retained_record_at(retained_parent)
		if (strcmp(registration.name, c"scoped defer") == 0): rec.scope = registration.parent
	rec.source = -1
	if (ast_retain_mode): rec.source = retained_source_find(path)
	defer_spans.push(rec)


# Simple statements are newline-terminated, so the span ends at the
# line's end.
void defer_skip_statement():
	while ((token_newline == 0) && (token[0] != 0)): get_token()


# Parse position: the 'defer' keyword has been consumed and the first
# token of the deferred statement is current. Records the span and
# skips the rest of the line without emitting code. Under
# --ast-emit-retained the statement's walk registers the span once the
# line is skipped (ast_defer_registration, grammar/ast_declaration.w).
void defer_register():
	if (accept(c":")):
		if ((ast_scoped_defer_enabled() == 0) || (retained_parent < 0)): error(c"scoped defer requires retained statement emission")
		retained_record* registration = retained_record_at(retained_parent)
		int scope = registration.parent
		if (scope < 0): error(c"scoped defer requires a lexical block")
		char* name = retained_record_at(scope).name
		if ((strcmp(name, c":") != 0) && (strcmp(name, c"{") != 0)): error(c"scoped defer requires a lexical block")
		registration.name = retained_intern(c"scoped defer")
		# This explicit contract selects checking even without --safe.
		type_safe_used = 1
	defer_check_form()
	if (ast_defer_registration()): return
	defer_record_span(strclone(filename), token_start_offset, diag_token_line - 1, diag_token_column - 1)
	defer_skip_statement()


# --stats (S2.3): replays that reopened the file and seeked to the span.
int defer_source_seeks


# Prime the tokenizer at the span start, exactly like
# generic_reparse_start (grammar/generic.w): from the retained source
# version when it holds the span, else by reopening the recorded file and
# seeking to it. Afterwards the span's first token is current.
void defer_reparse_start(int i):
	char* path = defer_spans[i].file
	int follow = retained_source_next_line_token(defer_spans[i].source, defer_spans[i].offset)
	if (retained_source_reparse_begin(path, defer_spans[i].source, defer_spans[i].offset, defer_spans[i].line, defer_spans[i].column, follow)): return
	defer_source_seeks = defer_source_seeks + 1
	file = open(path, 0, 511)
	if (file < 0): error3(c"cannot reopen deferred statement file '", path, c"'")
	filename = path
	getchar_reset(file)
	getchar_seek(file, defer_spans[i].offset)
	byte_offset = defer_spans[i].offset
	line_number = defer_spans[i].line
	column_number = defer_spans[i].column
	tab_level = 0
	token_newline = 0
	# nextc = 0 keeps get_character() from counting the outer parse's
	# stale lookahead character into the new position
	nextc = 0
	nextc = get_character()
	get_token()


# Emit every registered deferred statement in LIFO order at the current
# code position. Each span is re-parsed with the outer tokenizer state
# saved and restored around it, so the outer parse resumes untouched.
void defer_emit_one(int i):
	# Record the actual exit binding for ownership analysis and liveness.
	int deferred = retained_enter(retained_statement, defer_spans[i].file, defer_spans[i].offset, defer_spans[i].line + 1, defer_spans[i].column + 1, c"deferred exit")
	if (defer_tree_emit(i)):
		retained_leave(deferred, token_start_offset)
		return
	defer_reparse_exits = defer_reparse_exits + 1
	char* save = generic_reparse_save()
	defer_reparse_start(i)
	if (ast_deferred_expression() == 0): expression()
	expect_or_newline(c";")
	retained_source_reparse_close(file)
	generic_reparse_restore(save)
	retained_leave(deferred, token_start_offset)


void defer_emit_all():
	int i = defer_count()
	while (i > 0):
		i = i - 1
		if (defer_spans[i].scope != -2): defer_emit_one(i)


# The enclosing block consumes scoped registrations after fall-through
# emission. A loop's emitted cleanup executes on each iteration; no runtime
# list or registration allocation is needed. Legacy registrations survive.
void defer_emit_block(int scope, int function_body):
	int i = defer_count()
	while (i > 0):
		i = i - 1
		int owner = defer_spans[i].scope
		if ((owner >= 0) && (owner == scope)):
			defer_emit_one(i)
			defer_spans[i].scope = -2
		else if (function_body && (owner == -1)): defer_emit_one(i)


# Lexical identity, rather than stack depth, distinguishes empty scopes.
# Continue crosses switches; break stops at the first switch or loop.
int defer_scope_exited(int scope, int jump, int continuing):
	int parent = retained_record_at(jump).parent
	while (parent >= 0):
		retained_record* record = retained_record_at(parent)
		char* name = record.name
		if ((strcmp(name, c"while") == 0) || (strcmp(name, c"for range") == 0) || (strcmp(name, c"for") == 0)): return 0
		if ((continuing == 0) && (strcmp(name, c"switch") == 0)): return 0
		if (parent == scope): return 1
		if (record.kind == retained_function): return 0
		parent = record.parent
	return 0


void defer_emit_jump(int node, int continuing):
	if (node < 0): return
	int i = defer_count()
	while (i > 0):
		i = i - 1
		int scope = defer_spans[i].scope
		if ((scope >= 0) && defer_scope_exited(scope, node, continuing)): defer_emit_one(i)


# Exit path for 'return': the pending return value is already in eax
# (scalars and pointers; struct-by-value returns were already copied
# into the caller's buffer by copy_struct_return_value, and eax is
# preserved either way). Save it around the deferred statements so they
# cannot clobber it.
void defer_emit_returning():
	if (defer_count() == 0): return;
	push_slot()
	defer_emit_all()
	pop_eax_slot()
