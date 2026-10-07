/*
Opt-in multi-error checking (check --all-errors), in process.

Every declaration and statement is an analysis boundary: analysis_run
records the state the parse is in at its start, then parses it with
error() armed to jump back to that boundary (repl_setjmp/repl_longjmp,
the stubs the REPL's own recovery uses). After an error, the boundary
puts the parse-time state that the failed item had half-updated back,
returns the lexer to the item's first token and skips to the next
sibling (analysis_skip), and parsing continues. Nested boundaries make
the innermost failing statement the unit of recovery, so one function
can report several independent errors and the function itself still
completes.

No executable is written in check mode, so nothing has to be emitted
for a failed item: the code it emitted before the error is never
written, and the code buffer is not rewound (forward call chains may
still thread through those bytes). What is restored is what later
parsing reads: the lexer, the stack depth and the loop, switch, defer,
for-cleanup, control-region and DWARF block stacks, the nesting guards,
the parse-context flags, the device/generator modes and the retained
forest. Symbols and types the failed item declared are kept: a failed
declaration's binding stays visible, poisoned in the sense that the
item it belongs to reported an error, so later uses of it do not
produce follow-on 'Cannot find symbol' diagnostics (see
compiler/diagnostics.w, "Poisoned symbols").

Warnings are reported once, as the parse meets them, including those
of a statement that then fails. analysis_errors counts the recovered
errors; the 100th stops analysis with a final diagnostic.
*/
int analysis_mode
int analysis_errors
# Address of the innermost boundary's jump buffer; 0 outside any.
int analysis_jump
# Byte offset of the token current when the last recovered error was
# reported: analysis_skip lexes everything before it with warnings
# muted, because the failed parse already reported them.
int analysis_error_offset


# The parse state an analysis boundary restores after an error. The
# lexer half mirrors generic_reparse_save's fields.
struct analysis_state:
	char* filename
	int file
	int nextc
	int line_number
	int column_number
	int tab_level
	int token_newline
	int byte_offset
	int diag_token_line
	int diag_token_column
	int token_start_offset
	char* token
	int token_i
	int pointer_indirection
	retained_checkpoint retained
	int stack_pos
	int loop_depth
	int loop_break_chain
	int loop_continue_chain
	int loop_stack_pos
	int switch_depth
	int switch_break_chain
	int switch_stack_pos
	int break_in_switch
	int defer_count
	int for_cleanup_count
	int number_of_args
	int function_symbol
	int ctrl_stack_pos
	int dwarf_blocks
	int dwarf_open_func
	int dwarf_open_depth
	int stmt_nesting_depth
	int expr_nesting_depth
	int enclosing_tab_level
	int defer_function_body_pending
	int target_isa
	int bounds_mode
	int in_generator_body
	int in_gpu_for_body
	int device_symbol_base
	char* generic_subst
	int control_guard_pending
	int loop_iterable_walk


# Defined in compiler/analysis_state.w, which is imported after the
# grammar whose globals they save and restore.
void analysis_capture(analysis_state* state);
void analysis_restore(analysis_state* state);
void analysis_statement_failed();


# error()'s hook while analysis is on (analysis_probe_error_status in
# compiler/tokenizer.w): resume at the innermost boundary. Outside every
# boundary the error is final, and its value is the exit status.
int analysis_error_resume():
	if (analysis_jump == 0): return 1
	# At end of input there is nothing left to synchronise to, and an
	# unterminated literal (the lexer's errors at EOF) would only be
	# reported again by the skip's re-read.
	if (nextc == -1): return 1
	analysis_error_offset = token_start_offset
	repl_longjmp(analysis_jump, 1)
	return 1


void analysis_skip_token():
	int muted = analysis_probe_depth
	if (token_start_offset < analysis_error_offset): analysis_probe_depth = 1
	get_token()
	analysis_probe_depth = muted


# Recover at the next sibling statement/declaration. The production lexer
# keeps comments and quoted strings opaque; delimiters inside them do not
# affect this scan. Lexical errors during synchronization remain fatal.
# Tokens up to the failed item's error were already lexed (and their
# lexer warnings reported) by the failed parse, so they are re-read
# silently.
void analysis_skip(int declaration):
	int start = token_start_offset
	int indent = tab_level
	int guarded = peek(c"if")
	if (declaration): indent = 0
	int braces = 0
	int parens = 0
	int brackets = 0
	while (token[0]):
		if (peek(c"{")): braces = braces + 1
		if (peek(c"(")): parens = parens + 1
		if (peek(c"[")): brackets = brackets + 1
		if (peek(c"}")):
			if (braces == 0):
				# Preserve a containing block's delimiter, but consume an
				# unmatched delimiter that was itself the failing item.
				if (declaration || (token_start_offset == start)): analysis_skip_token()
				return
			braces = braces - 1
		if (peek(c")") && (parens > 0)): parens = parens - 1
		if (peek(c"]") && (brackets > 0)): brackets = brackets - 1
		int semicolon = peek(c";")
		analysis_skip_token()
		if ((braces == 0) && (parens == 0) && (brackets == 0)):
			if (semicolon): return
			if (peek(c"}") && (declaration == 0)): return
			if (token_newline && (tab_level <= indent)):
				# An else/elif at a failed if's own indentation belongs to
				# it. Any other one continues an enclosing if: a shallower
				# line, or the next line after a statement written on its
				# arm's line ('elif x: return y').
				if ((guarded == 0) || (tab_level < indent)): return
				if ((peek(c"else") == 0) && (peek(c"elif") == 0)): return


void analysis_run(int operation, int declaration):
	if ((analysis_mode == 0) || (token[0] == 0)):
		operation()
		return
	analysis_state state
	analysis_capture(&state)
	int outer = analysis_jump
	int[3] resume
	if (repl_setjmp(&resume)):
		# error() came back here: the item failed.
		analysis_jump = 0
		# An error inside a generic reparse is at an offset of another
		# file; none of this item's own tokens are known to be lexed.
		if (file != state.file): analysis_error_offset = 0
		analysis_restore(&state)
		free(state.token)
		analysis_errors = analysis_errors + 1
		if (analysis_errors >= 100): error(c"stopping after 100 semantic errors")
		analysis_skip(declaration)
		if (declaration == 0): analysis_statement_failed()
		analysis_jump = outer
		return
	analysis_jump = cast(int, &resume)
	analysis_probe_error_status = cast(int, analysis_error_resume)
	operation()
	analysis_jump = outer
	free(state.token)
