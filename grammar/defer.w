/*
Go-style 'defer' statements (docs/projects/defer.md).

	defer close(fd)

registers a deferred statement; every registered statement runs in LIFO
order at each function exit: before each 'return' and at the function's
fall-through end. Defers are function-scoped (not block-scoped).

The compiler is single-pass with no AST, so a deferred statement is
stored as a SOURCE SPAN (file path + byte offset, like generic
definitions in grammar/generic.w) and re-parsed with the ordinary
expression machinery at every exit point, which emits its code inline.
Because of the re-parse, the deferred expression is evaluated AT EXIT
TIME: arguments are not captured where the defer appears (unlike Go).

Local variable references re-parse correctly at any exit point because
sym_get_value computes esp-relative addresses from the live stack_pos
of the emission site, not the registration site.

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


/*
Registry: one record per deferred statement of the function currently
being compiled; defer_reset() clears it at function start.
*/
struct defer_span_record:
	char* file    # path to reopen for the re-parse
	int offset    # byte offset of the span start
	int line      # 0-based, for diagnostics during the re-parse
	int column    # 0-based


list[defer_span_record] defer_spans


int defer_count():
	if (cast(int, defer_spans) == 0):
		return 0
	return defer_spans.length


# Discards every record past the first n without touching the backing
# capacity: the REPL and the debugger's evaluator roll back a failed
# entry with this (the type_table_truncate trick — list[T]'s '.length'
# is read-only at the language level).
void defer_truncate(int n):
	if (cast(int, defer_spans) == 0):
		return;
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
	if ((token_newline != 0) | (token[0] == 0)):
		error(c"a statement must follow 'defer' on the same line")
	if (peek(c"return")):
		error(c"'return' is not allowed in a deferred statement")
	if (peek(c"defer")):
		error(c"'defer' cannot be nested in a deferred statement")
	if (peek(c"if") | peek(c"else") | peek(c"while") | peek(c"for") |
			peek(c"break") | peek(c"continue") | peek(c"yield") | peek(c"pass") |
			peek(c"debugger") | peek(c"raw_asm") | peek(c"{") | peek(c":")):
		error(c"deferred statement must be a simple expression statement")
	if (peek(c"const") | (peek(c"map") & (nextc == '[')) |
			(peek(c"set") & (nextc == '[')) | (peek(c"list") & (nextc == '[')) |
			(type_lookup(token) >= 0) | generic_type_starts_here()):
		error(c"deferred statement cannot declare a variable")


# Parse position: the 'defer' keyword has been consumed and the first
# token of the deferred statement is current. Records the span and
# skips the rest of the line without emitting code; simple statements
# are newline-terminated, so the span ends at the line's end.
void defer_register():
	defer_check_form()
	if (cast(int, defer_spans) == 0):
		defer_spans = new list[defer_span_record]
	defer_span_record rec
	rec.file = strclone(filename)
	rec.offset = token_start_offset
	rec.line = diag_token_line - 1
	rec.column = diag_token_column - 1
	defer_spans.push(rec)
	while ((token_newline == 0) & (token[0] != 0)):
		get_token()


# Open the recorded file, seek to the span start and prime the
# tokenizer, exactly like generic_reparse_start (grammar/generic.w):
# afterwards the span's first token is current.
void defer_reparse_start(int i):
	char* path = defer_spans[i].file
	file = open(path, 0, 511)
	if (file < 0):
		diag_part(c"cannot reopen deferred statement file '")
		diag_part(path)
		error(c"'")
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
void defer_emit_all():
	int i = defer_count()
	while (i > 0):
		i = i - 1
		char* save = generic_reparse_save()
		defer_reparse_start(i)
		expression()
		expect_or_newline(c";")
		close(file)
		generic_reparse_restore(save)


# Exit path for 'return': the pending return value is already in eax
# (scalars and pointers; struct-by-value returns were already copied
# into the caller's buffer by copy_struct_return_value, and eax is
# preserved either way). Save it around the deferred statements so they
# cannot clobber it.
void defer_emit_returning():
	if (defer_count() == 0):
		return;
	push_eax()
	stack_pos = stack_pos + 1
	defer_emit_all()
	pop_eax()
	stack_pos = stack_pos - 1
