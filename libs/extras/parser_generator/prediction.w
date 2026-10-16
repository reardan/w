# Opt-in pure-grammar continuation predictor. Ordered alternatives and greedy
# repetitions are explored with the complete caller continuation. AST nodes are
# allocated only after a successful derivation, never during speculation.
# This is bounded depth-first configuration execution, not an ALL(*) simulator.
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


struct pg_prediction_branch:
	int pc
	int position
	int frame
	int events


pg_prediction_program* pg_prediction_new():
	pg_prediction_program* program = new pg_prediction_program()
	program.ops = new list[pg_prediction_op*]
	program.steps = 0
	program.peak_branches = 0
	program.frames = 0
	program.events = 0
	return program


# Kinds: 0 accept, 1 token, 2 call, 3 return, 4 choice, 5 enter,
# 6 leave, 7 jump. Call value is the callee entry; enter value is AST kind
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


# The caller chooses an explicit work budget. Each step allocates at most one
# frame/branch or event pair; all temporary memory is released on every exit.
# Fixed tokenization is required: generation refuses parser goals and actions.
pg_ast_node* pg_prediction_parse_limit(pg_prediction_program* program, int entry, pg_token_stream* stream, pg_diagnostics* diagnostics, int limit):
	list[int] frames = new list[int]
	list[int] events = new list[int]
	list[pg_prediction_branch*] branches = new list[pg_prediction_branch*]
	int pc = entry
	int position = stream.index
	int initial = position
	int frame = -1
	int steps = 0
	int accepted = 0
	program.peak_branches = 0
	while (1):
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
			branch.events = events.length
			branches.push(branch)
			if (branches.length > program.peak_branches): program.peak_branches = branches.length
			pc = op.next
			continue
		if (op.kind == 2):
			int previous = frame
			frame = frames.length
			frames.push(op.next)
			frames.push(previous)
			pc = op.value
			continue
		if (op.kind == 3):
			if (frame < 0):
				# Public prediction entries recognize complete input, even
				# when the imported start rule omits an explicit EOF term.
				if (pg_token_stream_get(stream, position).kind == pg_token_eof_kind):
					accepted = 1
					break
				if (branches.length == 0): break
				pg_prediction_branch* branch = branches.pop()
				pc = branch.pc
				position = branch.position
				frame = branch.frame
				while (events.length > branch.events): events.pop()
				free(branch)
				continue
			pc = frames[frame]
			frame = frames[frame + 1]
			continue
		if ((op.kind == 5) || (op.kind == 6)):
			events.push(pc)
			events.push(position)
			pc = op.next
			continue
		pg_token* token = pg_token_stream_get(stream, position)
		if (position > stream.max_index): stream.max_index = position
		if (token.kind == op.value):
			events.push(pc)
			events.push(position)
			if (token.kind != pg_token_eof_kind): position++
			pc = op.next
			continue
		if (branches.length == 0): break
		pg_prediction_branch* branch = branches.pop()
		pc = branch.pc
		position = branch.position
		frame = branch.frame
		while (events.length > branch.events): events.pop()
		free(branch)
	program.steps = steps
	program.frames = frames.length / 2
	program.events = events.length / 2
	pg_ast_node* root = 0
	if (accepted && (stream.resource_failed == 0)):
		root = pg_prediction_replay(program, events, stream)
		if (root != 0): stream.index = position
	if (root == 0): stream.index = initial
	for pg_prediction_branch* branch in branches: free(branch)
	__w_list_free(cast(__w_list*, branches))
	__w_list_free(cast(__w_list*, frames))
	__w_list_free(cast(__w_list*, events))
	return root


pg_ast_node* pg_prediction_parse(pg_prediction_program* program, int entry, pg_token_stream* stream, pg_diagnostics* diagnostics):
	return pg_prediction_parse_limit(program, entry, stream, diagnostics, 1000000)
