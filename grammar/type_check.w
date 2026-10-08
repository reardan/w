# Unsafe-conversion and control-flow errors (issue #532).
# All findings fail compilation, including without --strict.
#
# The grammar is single pass with no AST, so these checks see only what
# the streaming parser knows at the moment it emits code:
#
# - Constant values: a literal's value is known only while it is the
#   last thing the expression parsed. int_literal(), char literals and
#   'true'/'false' record a note (const_note); a check trusts it only
#   when no token was consumed and no code emitted since, so '300' and
#   '-300' are seen but '(300)' (as a converted value) and '200 + 100'
#   are not. Enum constants are globals, not literals.
# - Fall-through: each statement reports whether it can complete
#   normally (flow_terminates). return/break/continue/goto, an if/else
#   whose every arm terminates, a switch with a default whose every case
#   terminates, a 'while 1'/'while (true)' loop with no break, and an
#   expression statement starting with a call to a noreturn function all
#   terminate. There is no noreturn annotation: exit() and friends are
#   known by name, and a function defined earlier whose body never
#   completes and holds no 'return' is inferred (flow_function_finished).
# - The fall-through and duplicate-case checks read tokens only (token
#   counts, lit_note, flow_true_serial), and the AST statement paths
#   (grammar/ast_statement.w, ast_loop.w, ast_function.w) mirror the
#   bookkeeping, so all compilation modes report them identically
#   (ast_expression_test compares). The conversion checks read
#   const_note, which the streaming grammar records as it parses; the
#   AST front end (grammar/ast_expression.w) records an event where the
#   streaming grammar would check, and replays it with
#   const_note_override standing for the literal the tree holds.

void print_error_type(int type_index); /* grammar/promote.w */


# --- constant notes ---------------------------------------------------

int const_note_value
# token_serial of the literal token itself (0: no note)
int const_note_serial
int const_note_codepos
# The literal's source position, for diagnostics that name it
int const_note_line_number
int const_note_diag_line
int const_note_diag_column
# Set by the AST front end around a replayed check: 1 when the converted
# value is a literal whose value and position it wrote into const_note_*,
# -1 when it is not; 0 reads the streaming note.
int const_note_override


# The current token is an integer, char or bool literal whose value was
# just loaded into eax.
void const_note(int value):
	const_note_value = value
	const_note_serial = token_serial
	const_note_codepos = codepos
	const_note_line_number = line_number
	const_note_diag_line = diag_token_line
	const_note_diag_column = diag_token_column


# Literal decode notes: the last integer or char literal token decoded,
# by either the streaming grammar or the AST replay (both decode while
# the literal is the current token), so token-count checks agree across
# compilation modes. negative says the decode itself consumed a '-'.
int lit_note_value
int lit_note_serial
int lit_note_negative


void lit_note(int value, int negative):
	lit_note_value = value
	lit_note_serial = token_serial
	lit_note_negative = negative


# warning(message) reported at a saved source position instead of the
# parser's current lookahead token (which, after an expression that ends
# a line, is already on the next line).
void warning_at(char* message, int at_line_number, int at_diag_line, int at_diag_column, char* at_token):
	int saved_line_number = line_number
	int saved_diag_line = diag_token_line
	int saved_diag_column = diag_token_column
	char* saved_token = token
	line_number = at_line_number
	diag_token_line = at_diag_line
	diag_token_column = at_diag_column
	token = at_token
	warning(message)
	line_number = saved_line_number
	diag_token_line = saved_diag_line
	diag_token_column = saved_diag_column
	token = saved_token


void type_error_at(char* message, int at_line_number, int at_diag_line, int at_diag_column, char* at_token):
	int saved_line_number = line_number
	int saved_diag_line = diag_token_line
	int saved_diag_column = diag_token_column
	char* saved_token = token
	line_number = at_line_number
	diag_token_line = at_diag_line
	diag_token_column = at_diag_column
	token = at_token
	type_error(message)
	line_number = saved_line_number
	diag_token_line = saved_diag_line
	diag_token_column = saved_diag_column
	token = saved_token


# 1 when the expression that just finished parsing ended with the noted
# literal and nothing was emitted after it: the literal's own token was
# the last one consumed. Integer operators type their result as the
# constant pseudo-type too, but every one of them emits code after its
# right operand, so 'x + 300' never matches.
int const_note_current():
	if (const_note_override): return const_note_override > 0
	if (const_note_serial == 0): return 0
	if (token_serial != const_note_serial + 1): return 0
	return codepos == const_note_codepos


# --- conversion checks ------------------------------------------------

# Writes the construct a conversion diagnostic names: the context
# string, or "function 'f' argument N" when callee_name is set.
void conversion_context(char* context, char* callee_name, int arg_index):
	if (callee_name != 0):
		diag_part(c"function '")
		diag_part(callee_name)
		diag_part(c"' argument ")
		diag_part(itoa(arg_index + 1))
	else: diag_part(context)


# A literal that does not fit a sub-word integer type: 'char c = 300'
# stores 44. Only the bits are checked, not the signedness: a value
# that fits the type's signed or unsigned range is accepted ('char c =
# 200' and 'uint8 b = -1' are common spellings of a bit pattern), as
# with C compilers' constant-overflow warning. Word-sized and wider
# types cannot overflow: literals are 32-bit.
void check_constant_narrowing(char* context, char* callee_name, int arg_index, int want, int got):
	if (got != 3): return
	if (const_note_current() == 0): return
	want = type_unqualified(want)
	if (want < 0): return
	if (type_get_pointer_level(want) != 0): return
	if (type_num_args(want) > 0): return
	if (type_float_kind(want) != 0): return
	if (want == bool_type): return
	if (type_get_kind(want) != 0): return
	int size = type_get_size(want)
	if ((size != 1) && (size != 2)): return
	int bits = size * 8
	int high = (1 << bits) - 1
	int low = 0 - (1 << (bits - 1))
	int value = const_note_value
	if ((value >= low) && (value <= high)): return
	int stored = value & high
	if ((type_is_unsigned_fixed(want) == 0) && (stored > (high >> 1))): stored = stored - high - 1
	conversion_context(context, callee_name, arg_index)
	diag_part(c" narrows constant ")
	diag_part(itoa(value))
	diag_part(c" to '")
	print_error_type(want)
	diag_part(c"' (stored as ")
	diag_part(itoa(stored))
	type_error_at(c"); use cast() if the truncation is intended", const_note_line_number, const_note_diag_line, const_note_diag_column, itoa(value))


# An integer stored into an enum without cast(): docs/projects/
# type_system_p0.md makes enums distinct types ("Integer to enum
# requires a cast"). Enum to integer stays implicit. The constant
# pseudo-type is flagged only for a literal: untyped call results (asm
# stubs, some builtins) also carry it.
void check_enum_conversion(char* context, char* callee_name, int arg_index, int want, int got):
	want = type_unqualified(want)
	if (want < 0): return
	if (type_get_kind(want) != type_kind_enum): return
	if (type_get_pointer_level(want) != 0): return
	int got_real = type_unqualified(got)
	if (got_real == want): return
	if (got_real == 3):
		if (const_note_current() == 0): return
	else:
		if (got_real < 0): return
		if (type_get_pointer_level(got_real) != 0): return
		if (type_num_args(got_real) > 0): return
		if (type_float_kind(got_real) != 0): return
		if (type_is_var(got_real) || type_is_string(got_real)): return
	conversion_context(context, callee_name, arg_index)
	diag_part(c" converts '")
	if (got_real == 3): diag_part(itoa(const_note_value))
	else: print_error_type(got_real)
	diag_part(c"' to enum '")
	print_error_type(want)
	diag_part(c"' implicitly; use cast(")
	print_error_type(want)
	if (got_real == 3): type_error_at(c", ...)", const_note_line_number, const_note_diag_line, const_note_diag_column, itoa(const_note_value))
	else: type_error(c", ...)")


# Recovering a typed pointer from an erased pointer requires cast().
void check_void_pointer_conversion(char* context, char* callee_name, int arg_index, int want, int got):
	want = type_unqualified(want)
	got = type_unqualified(got)
	if ((want < 0) || (got < 0)): return
	int level = type_get_pointer_level(got)
	if ((level == 0) || (type_get_pointer_level(want) != level)): return
	if (type_is_gpu_pointer(want) || type_is_gpu_pointer(got)): return
	if (strcmp(type_get_name(got), c"void") != 0): return
	if (strcmp(type_get_name(want), c"void") == 0): return
	conversion_context(context, callee_name, arg_index)
	diag_part(c" converts '")
	print_error_type(got)
	diag_part(c"' to '")
	print_error_type(want)
	type_error(c"' without cast() [void-pointer-conversion]")


# Whether check_value_conversion can report want <- got for some value:
# lets the AST front end skip recording the common conversions.
int conversion_check_relevant(int want, int got):
	int w = type_unqualified(want)
	if (w < 0): return 0
	if (type_get_pointer_level(w) == 0):
		if (type_get_kind(w) == type_kind_enum): return 1
		if ((got == 3) && ((type_get_size(w) == 1) || (type_get_size(w) == 2))): return 1
	int g = type_unqualified(got)
	return (g >= 0) && (type_get_pointer_level(g) > 0)


# Every conversion check for one conversion site.
void check_value_conversion(char* context, char* callee_name, int arg_index, int want, int got):
	check_constant_narrowing(context, callee_name, arg_index, want, got)
	check_enum_conversion(context, callee_name, arg_index, want, got)
	check_void_pointer_conversion(context, callee_name, arg_index, want, got)


# 'return 5' in a void function: the value is silently dropped. The
# position is the 'return' keyword's (line/column), or the current
# token when line is 0.
void check_void_return(int declared_type, int got, int at_line_number, int at_diag_line, int at_diag_column):
	if (type_unqualified(declared_type) != 0): return
	if (type_unqualified(got) == 0): return
	if (at_diag_line == 0): type_error(c"return with a value in a void function")
	else: type_error_at(c"return with a value in a void function", at_line_number, at_diag_line, at_diag_column, c"return")


# Calling an integer requires an explicit cast to a function pointer.
void check_untyped_callee(int type):
	if (type == 4): return
	int t = type_unqualified(type)
	if ((t < 0) || (t == 4)): return
	if (type_get_pointer_level(t) != 0): return
	if (type_num_args(t) > 0): return
	if (type_float_kind(t) != 0): return
	if (type_is_function_signature(t)): return
	diag_part(c"called object of type '")
	print_error_type(t)
	type_error(c"' is not a function; declare it as a function pointer ('type callback = fn(int) -> int', then 'callback* f') [call-int]")


# --- control flow -----------------------------------------------------

# Set at the end of every statement: 1 when it cannot complete normally
# (control never reaches the statement after it).
int flow_terminates
# A 'break' leaving the innermost loop / switch was parsed. Loops save
# and clear flow_loop_break in loop_enter() and restore it in
# loop_leave(); switches do the same with flow_switch_break.
int flow_loop_break
int flow_switch_break
# The condition statement_guard() just parsed was a nonzero literal
int flow_guard_true


# Functions known never to return: the process/thread exit primitives,
# plus every function whose body could not complete normally and held
# no 'return' (error(), a 'die' helper, a server's 'while 1' loop),
# recorded as each definition finishes. Only calls to functions already
# defined above count: the single pass has not seen later bodies.
map[char*, int] flow_noreturn_functions
# 1 once the function body being parsed holds a 'return'
int flow_saw_return


int function_is_noreturn(char* name):
	if (name == 0): return 0
	if ((strcmp(name, c"exit") == 0) || (strcmp(name, c"_exit") == 0) || (strcmp(name, c"thread_exit") == 0) || (strcmp(name, c"abort") == 0)):
		return 1
	if (flow_noreturn_functions == 0): return 0
	return name in flow_noreturn_functions


# 1 when the statement about to be parsed starts with a call to a
# noreturn function ('exit(1)', 'error(c"...") ...'): its leftmost
# operand runs first, so the statement never completes. Read from the
# tokens alone so the streaming grammar and the AST statement paths
# agree.
int flow_statement_starts_noreturn():
	if (nextc != '('): return 0
	if (is_ident_start_byte(token[0]) == 0): return 0
	return function_is_noreturn(token)


# token_serial of the last 'true' keyword parsed, by the streaming
# grammar or the AST replay
int flow_true_serial


# A loop or if condition is about to be parsed: classify its first
# token so flow_condition_end() can tell a constant-true condition
# ('while 1', 'while true', 'while (1)', 'while (true)') from the
# tokens alone. Returns the state flow_condition_end takes.
int flow_condition_begin():
	int shape = 0
	if (strcmp(token, c"true") == 0): shape = 1
	else if ((token[0] >= '1') && (token[0] <= '9')): shape = 1
	else if ((token[0] == '(') && (token[1] == 0)):
		if ((nextc >= '1') && (nextc <= '9')): shape = 3
		else if (nextc == 't'): shape = 2
	if (shape == 0): return 0
	return (token_serial << 2) | shape


# The condition begun with state just finished parsing: sets
# flow_guard_true when it was exactly the one- or three-token form
# (shape 2: '(' then a token starting with 't', which must have been
# the 'true' keyword).
void flow_condition_end(int state):
	flow_guard_true = 0
	if (state == 0): return
	int shape = state & 3
	int start_serial = state >> 2
	if (shape == 2):
		flow_guard_true = (token_serial == start_serial + 3) && (flow_true_serial == start_serial + 1)
	else: flow_guard_true = token_serial == start_serial + shape


# The body of function name just finished parsing: remember it when it
# can never return.
void flow_function_finished(char* name):
	if (flow_terminates && (flow_saw_return == 0)):
		if (flow_noreturn_functions == 0): flow_noreturn_functions = new map[char*, int]
		flow_noreturn_functions[strclone(name)] = 1


# The return type a top-level definition was written with
# (grammar/program.w sets it right before function_definition): a
# definition after a prototype keeps the prototype's type in the symbol
# table, so 'void main()' below lib/lib.w's 'int main(int, int);'
# would otherwise read as int. 0 in flow_definition_type_set means
# "use the symbol's type" (operators, generic instantiations).
# function_definition consumes it on entry (flow_written_return_type).
int flow_definition_type
int flow_definition_type_set


int flow_written_return_type(int current_symbol):
	int declared = load_int(table + current_symbol + 6)
	if (flow_definition_type_set): declared = flow_definition_type
	flow_definition_type_set = 0
	return declared


# The function body just parsed (written with return type declared,
# named name at line/column) can fall off its end without returning a
# value.
void check_missing_return(int declared, char* name, int line, int column):
	if (flow_terminates): return
	declared = type_unqualified(declared)
	if (declared == 0): return
	if ((declared == 3) || (declared == 4)): return
	diag_part(c"function '")
	diag_part(name)
	type_error_at(c"' can reach the end of its body without returning a value", line - 1, line, column, name)
