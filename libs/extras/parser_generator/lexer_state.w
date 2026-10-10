/*
Per-parse incremental lexer state. Offsets and columns count source bytes;
line endings are LF, CR, CRLF (one newline), and UTF-8 U+2028/U+2029.
Input and filename are copied. Host hooks must snapshot every mutable host
field: restoring and replaying token actions must have no external effects.
*/
import libs.extras.parser_generator.token
import libs.extras.parser_generator.diagnostics


type pg_lexer_host_save = fn(void*) -> void*
type pg_lexer_host_restore = fn(void*, void*) -> void
type pg_lexer_host_free = fn(void*) -> void


struct pg_lexer_state:
	char* input
	char* filename
	int length
	int offset
	int line
	int column
	int goal
	int mode
	list[int] modes
	list[int] context
	void* host
	pg_lexer_host_save* host_save
	pg_lexer_host_restore* host_restore
	pg_lexer_host_free* host_snapshot_free
	pg_lexer_host_free* host_free


type pg_lexer_next = fn(pg_lexer_state*, pg_diagnostics*) -> pg_token*


struct pg_lexer_snapshot:
	int offset
	int line
	int column
	int goal
	int mode
	list[int] modes
	list[int] context
	void* host
	pg_lexer_host_free* host_free


pg_lexer_state* pg_lexer_state_new(char* input, int length, char* filename):
	pg_lexer_state* state = new pg_lexer_state()
	if (length < 0): length = 0
	state.input = pg_substr(input, 0, length)
	state.filename = strclone(filename)
	state.length = length
	state.offset = 0
	state.line = 1
	state.column = 1
	state.goal = 0
	state.mode = 0
	state.modes = new list[int]
	state.context = new list[int]
	state.host = 0
	state.host_save = 0
	state.host_restore = 0
	state.host_snapshot_free = 0
	state.host_free = 0
	return state


int pg_lexer_at(pg_lexer_state* state, int relative):
	int index = state.offset + relative
	if (index < 0 || index >= state.length): return -1
	return cast(int, state.input[index]) & 255


void pg_lexer_advance(pg_lexer_state* state, int length):
	int end = state.offset + length
	if (end > state.length): end = state.length
	while (state.offset < end):
		int pos = state.offset
		int ch = cast(int, state.input[pos]) & 255
		state.offset = pos + 1
		if (ch == 13):
			state.line = state.line + 1
			state.column = 1
			continue
		if (ch == 10):
			if (pos == 0 || state.input[pos - 1] != 13): state.line = state.line + 1
			state.column = 1
			continue
		# Recognize the final byte, so split advance calls behave identically.
		if ((ch == 168 || ch == 169) && pos >= 2):
			if ((cast(int, state.input[pos - 2]) & 255) == 226 && (cast(int, state.input[pos - 1]) & 255) == 128):
				state.line = state.line + 1
				state.column = 1
				continue
		state.column = state.column + 1


void pg_lexer_push_mode(pg_lexer_state* state, int mode):
	state.modes.push(state.mode)
	state.mode = mode


int pg_lexer_pop_mode(pg_lexer_state* state, pg_diagnostics* diagnostics):
	if (state.modes.length == 0):
		pg_diagnostics_add(diagnostics, state.filename, state.line, state.column, c"lexer mode stack underflow", c"active mode", c"")
		return 0
	state.mode = state.modes.pop()
	return 1


pg_lexer_snapshot* pg_lexer_save(pg_lexer_state* state):
	pg_lexer_snapshot* saved = new pg_lexer_snapshot()
	saved.offset = state.offset
	saved.line = state.line
	saved.column = state.column
	saved.goal = state.goal
	saved.mode = state.mode
	saved.modes = new list[int]
	saved.context = new list[int]
	for i in range(state.modes.length): saved.modes.push(state.modes[i])
	for i in range(state.context.length): saved.context.push(state.context[i])
	saved.host = 0
	saved.host_free = state.host_snapshot_free
	if (state.host_save != 0): saved.host = state.host_save(state.host)
	return saved


void pg_lexer_restore(pg_lexer_state* state, pg_lexer_snapshot* saved):
	state.offset = saved.offset
	state.line = saved.line
	state.column = saved.column
	state.goal = saved.goal
	state.mode = saved.mode
	__w_list* modes = cast(__w_list*, state.modes)
	__w_list* context = cast(__w_list*, state.context)
	modes.length = 0
	context.length = 0
	for i in range(saved.modes.length): state.modes.push(saved.modes[i])
	for i in range(saved.context.length): state.context.push(saved.context[i])
	if (state.host_restore != 0): state.host_restore(state.host, saved.host)


void pg_lexer_snapshot_free(pg_lexer_snapshot* saved):
	if (saved == 0): return
	if (saved.host_free != 0 && saved.host != 0): saved.host_free(saved.host)
	__w_list_free(cast(__w_list*, saved.modes))
	__w_list_free(cast(__w_list*, saved.context))
	free(saved)


void pg_lexer_state_free(pg_lexer_state* state):
	if (state == 0): return
	if (state.host_free != 0 && state.host != 0): state.host_free(state.host)
	__w_list_free(cast(__w_list*, state.modes))
	__w_list_free(cast(__w_list*, state.context))
	free(state.input)
	free(state.filename)
	free(state)
