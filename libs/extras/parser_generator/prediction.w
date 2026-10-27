# Opt-in pure-grammar continuation predictor. Ordered alternatives and greedy
# repetitions are explored with the complete caller continuation. AST nodes are
# allocated only after a successful derivation, never during speculation.
# This is bounded depth-first configuration execution with memoized rule
# calls (see pg_prediction_record), not an ALL(*) simulator.
import libs.extras.parser_generator.runtime


struct pg_prediction_op:
	int kind
	int next
	int other
	int value
	char* name


struct pg_prediction_program:
	list[pg_prediction_op*] ops
	int steps
	int peak_branches
	int frames
	int events


# An ordinary branch resumes at pc; a memo branch (record >= 0) resumes a
# memoized call's next recorded derivation, then continues at pc.
struct pg_prediction_branch:
	int pc
	int position
	int frame
	int events
	int record
	int derivation


pg_prediction_program* pg_prediction_new():
	pg_prediction_program* program = new pg_prediction_program()
	program.ops = new list[pg_prediction_op*]
	program.steps = 0
	program.peak_branches = 0
	program.frames = 0
	program.events = 0
	return program


# Kinds: 0 accept, 1 token, 2 call, 3 return, 4 choice, 5 enter,
# 6 leave, 7 jump, 8 node metadata, 9 child metadata. Call value is the callee entry; enter value is AST kind
# and other is the one-based alternative identity.
int pg_prediction_add(pg_prediction_program* program, int kind, int next, int other, int value, char* name):
	pg_prediction_op* op = new pg_prediction_op()
	op.kind = kind
	op.next = next
	op.other = other
	op.value = value
	op.name = strclone(name)
	int index = program.ops.length
	program.ops.push(op)
	return index


void pg_prediction_free(pg_prediction_program* program):
	for pg_prediction_op* op in program.ops:
		free(op.name)
		free(op)
	__w_list_free(cast(__w_list*, program.ops))
	free(program)


void pg_prediction_resource(pg_token_stream* stream, pg_diagnostics* diagnostics, int position):
	char* message = c"parser prediction resource limit exceeded"
	stream.resource_failed = 1
	stream.resource_message = message
	pg_token* token = pg_token_stream_get(stream, position)
	pg_diagnostics_add(diagnostics, token.filename, token.line, token.column, message, c"bounded prediction", token.text)


# Events are (instruction, token-index) pairs. Only a successful path is replayed.
pg_ast_node* pg_prediction_replay(pg_prediction_program* program, list[int] events, pg_token_stream* stream):
	list[pg_ast_node*] parents = new list[pg_ast_node*]
	pg_ast_node* root = 0
	int failed = 0
	int i = 0
	while (i < events.length):
		pg_prediction_op* op = program.ops[events[i]]
		int position = events[i + 1]
		i = i + 2
		if ((op.kind == 8) || (op.kind == 9)):
			pg_ast_node* node = parents[parents.length - 1]
			if (op.kind == 9): node = node.children[node.children.length - 1]
			pg_ast_set_metadata(node, op.name, op.value)
			continue
		if (op.kind == 6):
			pg_ast_node* node = parents.pop()
			if (parents.length > 0): pg_ast_add(parents[parents.length - 1], node)
			continue
		pg_token* token = 0
		if (op.kind == 1): token = pg_token_stream_get(stream, position)
		pg_ast_node* node = pg_token_stream_ast_new(stream, op.value, token, op.name)
		if (node == 0):
			failed = 1
			break
		if (op.kind == 5):
			pg_ast_set_metadata(node, c"pg_alternative", op.other)
			if (root == 0): root = node
			parents.push(node)
		else: pg_ast_add(parents[parents.length - 1], node)
	if (failed):
		# Unclosed rule nodes are not attached until leave events. Owned
		# streams retain each allocation; independent trees need cleanup.
		if (stream.ast_nodes == 0):
			for pg_ast_node* node in parents: pg_ast_free(node)
		root = 0
	__w_list_free(cast(__w_list*, parents))
	return root


# Memoized rule calls. The search is ordered depth-first, but a rule's
# derivations from one token position do not depend on the caller's
# continuation: they are enumerated in the same order whichever caller asks.
# The first call of a rule at a position records, in order, the end position
# and event chain of each derivation reaching a new end position (a later
# derivation with an already-seen end can only repeat the continuation's
# outcome). Once backtracking has exhausted that call, the record is
# complete, and later calls replay its derivations instead of re-parsing,
# trying the continuation once per distinct end, in the original order. The
# selected derivation is therefore exactly the one plain depth-first search
# selects; only repeated work disappears. Events form a persistent chain so
# a replay splices a recorded segment in O(1).
struct pg_prediction_record:
	int depth
	int start
	int complete
	list[int] ends
	list[int] tails
	map[int, int] seen


struct pg_prediction_state:
	list[int] frames
	list[int] frame_records
	list[int] event_kind
	list[int] event_a
	list[int] event_b
	list[int] event_prev
	list[pg_prediction_branch*] branches
	list[pg_prediction_record*] records
	list[int] open
	map[int, map[int, int]] memo


pg_prediction_state* pg_prediction_state_new():
	pg_prediction_state* state = new pg_prediction_state()
	state.frames = new list[int]
	state.frame_records = new list[int]
	state.event_kind = new list[int]
	state.event_a = new list[int]
	state.event_b = new list[int]
	state.event_prev = new list[int]
	state.branches = new list[pg_prediction_branch*]
	state.records = new list[pg_prediction_record*]
	state.open = new list[int]
	state.memo = new map[int, map[int, int]]
	return state


void pg_prediction_state_free(pg_prediction_state* state):
	for pg_prediction_branch* branch in state.branches: free(branch)
	for pg_prediction_record* record in state.records:
		__w_list_free(cast(__w_list*, record.ends))
		__w_list_free(cast(__w_list*, record.tails))
		__w_map_free(cast(__w_hash_table*, record.seen))
		free(record)
	for int position in state.memo.keys(): __w_map_free(cast(__w_hash_table*, state.memo[position]))
	__w_map_free(cast(__w_hash_table*, state.memo))
	__w_list_free(cast(__w_list*, state.frames))
	__w_list_free(cast(__w_list*, state.frame_records))
	__w_list_free(cast(__w_list*, state.event_kind))
	__w_list_free(cast(__w_list*, state.event_a))
	__w_list_free(cast(__w_list*, state.event_b))
	__w_list_free(cast(__w_list*, state.event_prev))
	__w_list_free(cast(__w_list*, state.branches))
	__w_list_free(cast(__w_list*, state.records))
	__w_list_free(cast(__w_list*, state.open))
	free(state)


# Kind 0 is an (instruction, position) event; kind 1 splices the recorded
# chain segment after node `a` up to and including node `b`.
int pg_prediction_event(pg_prediction_state* state, int kind, int a, int b, int prev):
	state.event_kind.push(kind)
	state.event_a.push(a)
	state.event_b.push(b)
	state.event_prev.push(prev)
	return state.event_kind.length - 1


# The flat (instruction, position) pairs of the chain ending at `tail`.
list[int] pg_prediction_flatten(pg_prediction_state* state, int tail):
	list[int] reversed = new list[int]
	list[int] stack = new list[int]
	stack.push(tail)
	stack.push(-1)
	while (stack.length > 0):
		int stop = stack.pop()
		int node = stack.pop()
		while (node != stop):
			if (state.event_kind[node] == 0):
				reversed.push(state.event_b[node])
				reversed.push(state.event_a[node])
				node = state.event_prev[node]
			else:
				stack.push(state.event_prev[node])
				stack.push(stop)
				stop = state.event_a[node]
				node = state.event_b[node]
	list[int] events = new list[int]
	int i = reversed.length - 1
	while (i >= 0):
		events.push(reversed[i])
		i = i - 1
	__w_list_free(cast(__w_list*, reversed))
	__w_list_free(cast(__w_list*, stack))
	return events


int pg_prediction_lookup(pg_prediction_state* state, int callee, int position):
	if (!(position in state.memo)): return -1
	map[int, int] calls = state.memo[position]
	if (!(callee in calls)): return -1
	return calls[callee]


int pg_prediction_remember(pg_prediction_state* state, int callee, int position, int tail):
	pg_prediction_record* record = new pg_prediction_record()
	record.depth = state.branches.length
	record.start = tail
	record.complete = 0
	record.ends = new list[int]
	record.tails = new list[int]
	record.seen = new map[int, int]
	int index = state.records.length
	state.records.push(record)
	if (!(position in state.memo)): state.memo[position] = new map[int, int]
	map[int, int] calls = state.memo[position]
	calls[callee] = index
	state.open.push(index)
	return index


# Backtracking to a branch older than an open call completes that call.
void pg_prediction_close(pg_prediction_state* state):
	while (state.open.length > 0):
		pg_prediction_record* record = state.records[state.open[state.open.length - 1]]
		if (record.depth <= state.branches.length): return
		record.complete = 1
		state.open.pop()


# The caller chooses an explicit work budget. Each step allocates a bounded
# amount of memory (a frame, branch, event or memo record), and replaying a
# further memoized derivation is charged as a step; all temporary memory is
# released on every exit. Fixed tokenization is required: generation refuses parser goals
# and actions.
pg_ast_node* pg_prediction_parse_limit(pg_prediction_program* program, int entry, pg_token_stream* stream, pg_diagnostics* diagnostics, int limit):
	pg_prediction_state* state = pg_prediction_state_new()
	list[pg_prediction_branch*] branches = state.branches
	list[int] frames = state.frames
	int pc = entry
	int position = stream.index
	int initial = position
	int frame = -1
	int tail = -1
	int steps = 0
	int accepted = 0
	int fail = 0
	program.peak_branches = 0
	while (1):
		if (fail):
			# Resume the most recent alternative: an ordinary branch, or the
			# next recorded derivation of a memoized call.
			fail = 0
			if (branches.length == 0): break
			pg_prediction_branch* branch = branches.pop()
			pg_prediction_close(state)
			frame = branch.frame
			tail = branch.events
			if (branch.record < 0):
				pc = branch.pc
				position = branch.position
				free(branch)
			else:
				steps++
				if (steps > limit):
					pg_prediction_resource(stream, diagnostics, branch.position)
					free(branch)
					break
				pg_prediction_record* record = state.records[branch.record]
				int derivation = branch.derivation
				pc = branch.pc
				position = record.ends[derivation]
				tail = pg_prediction_event(state, 1, record.start, record.tails[derivation], tail)
				if (derivation + 1 < record.ends.length):
					branch.derivation = derivation + 1
					branches.push(branch)
				else: free(branch)
			continue
		if (stream.resource_failed): break
		steps++
		if (steps > limit):
			pg_prediction_resource(stream, diagnostics, position)
			break
		pg_prediction_op* op = program.ops[pc]
		if (op.kind == 0):
			accepted = 1
			break
		if (op.kind == 7):
			pc = op.next
			continue
		if (op.kind == 4):
			pg_prediction_branch* branch = new pg_prediction_branch()
			branch.pc = op.other
			branch.position = position
			branch.frame = frame
			branch.events = tail
			branch.record = -1
			branches.push(branch)
			if (branches.length > program.peak_branches): program.peak_branches = branches.length
			pc = op.next
			continue
		if (op.kind == 2):
			int known = pg_prediction_lookup(state, op.value, position)
			if ((known >= 0) && state.records[known].complete):
				pg_prediction_record* record = state.records[known]
				if (record.ends.length == 0):
					fail = 1
					continue
				if (record.ends.length > 1):
					pg_prediction_branch* branch = new pg_prediction_branch()
					branch.pc = op.next
					branch.position = position
					branch.frame = frame
					branch.events = tail
					branch.record = known
					branch.derivation = 1
					branches.push(branch)
					if (branches.length > program.peak_branches): program.peak_branches = branches.length
				position = record.ends[0]
				tail = pg_prediction_event(state, 1, record.start, record.tails[0], tail)
				pc = op.next
				continue
			# A call re-entered while its first exploration is still open
			# (only possible through an empty derivation) runs unmemoized.
			int created = -1
			if (known < 0): created = pg_prediction_remember(state, op.value, position, tail)
			int previous = frame
			frame = frames.length
			frames.push(op.next)
			frames.push(previous)
			state.frame_records.push(created)
			pc = op.value
			continue
		if (op.kind == 3):
			if (frame < 0):
				# Public prediction entries recognize complete input, even
				# when the imported start rule omits an explicit EOF term.
				if (pg_token_stream_get(stream, position).kind == pg_token_eof_kind):
					accepted = 1
					break
				fail = 1
				continue
			int owner = state.frame_records[frame / 2]
			if ((owner >= 0) && (state.records[owner].complete == 0)):
				pg_prediction_record* record = state.records[owner]
				if (position in record.seen):
					fail = 1
					continue
				record.seen[position] = 1
				record.ends.push(position)
				record.tails.push(tail)
			pc = frames[frame]
			frame = frames[frame + 1]
			continue
		if ((op.kind == 5) || (op.kind == 6) || (op.kind == 8) || (op.kind == 9)):
			tail = pg_prediction_event(state, 0, pc, position, tail)
			pc = op.next
			continue
		pg_token* token = pg_token_stream_get(stream, position)
		if (position > stream.max_index): stream.max_index = position
		if (token.kind == op.value):
			tail = pg_prediction_event(state, 0, pc, position, tail)
			if (token.kind != pg_token_eof_kind): position++
			pc = op.next
			continue
		fail = 1
	program.steps = steps
	program.frames = frames.length / 2
	pg_ast_node* root = 0
	program.events = 0
	if (accepted && (stream.resource_failed == 0)):
		list[int] events = pg_prediction_flatten(state, tail)
		program.events = events.length / 2
		root = pg_prediction_replay(program, events, stream)
		__w_list_free(cast(__w_list*, events))
		if (root != 0): stream.index = position
	if (root == 0): stream.index = initial
	pg_prediction_state_free(state)
	return root


pg_ast_node* pg_prediction_parse(pg_prediction_program* program, int entry, pg_token_stream* stream, pg_diagnostics* diagnostics):
	return pg_prediction_parse_limit(program, entry, stream, diagnostics, 1000000)
