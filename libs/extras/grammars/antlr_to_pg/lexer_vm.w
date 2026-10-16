# Continuation lexer VM. Immutable bytecode uses six little-endian 32-bit
# fields per state: opcode, next, alternate/call-return, low, high, nongreedy.
# 1 range, 2 ordered split, 3 jump, 4 call, 5 return, 6 EOF anchor.
# Calls use interned persistent stacks; configurations retain branch order.
# The nongreedy pruning rule follows ANTLR 4.13.2 LexerATNSimulator.closure:
# after an accept, lower-priority configs that crossed a nongreedy decision
# cannot extend that rule. Greedy alternatives remain eligible for maximal munch.
import lib.lib


struct at_lex_result:
	int length
	int status             # 0 mismatch, 1 match, -2 limit, -3 invalid UTF-8
	int steps
	int peak_configs
	int stack_count


struct at_lex_run:
	char* program
	int states
	int limit
	int steps
	int failed
	int accepted
	int peak_configs
	list[int] parents
	list[int] returns
	list[int] depths
	map[int, int] stacks
	map[int, int] seen
	list[int] pending
	list[int] reached


int at_lex_field(char* program, int state, int field):
	int offset = state * 24 + field * 4
	return (cast(int, program[offset]) & 255) | ((cast(int, program[offset + 1]) & 255) << 8) | ((cast(int, program[offset + 2]) & 255) << 16) | ((cast(int, program[offset + 3]) & 255) << 24)


int at_lex_config(at_lex_run* run, int state, int stack, int nongreedy):
	return (stack * run.states + state) * 2 + nongreedy


int at_lex_stack(at_lex_run* run, int parent, int destination):
	int key = parent * run.states + destination
	int found = run.stacks.get(key, 0)
	if (found != 0): return found
	# Limits keep keys in signed 32-bit range on every architecture.
	if ((run.parents.length >= 16384) || (run.depths[parent] >= 512)):
		run.failed = -2
		return 0
	int result = run.parents.length
	run.parents.push(parent)
	run.returns.push(destination)
	run.depths.push(run.depths[parent] + 1)
	run.stacks[key] = result
	return result


void at_lex_closure(at_lex_run* run, int initial, int at_eof):
	run.pending.push(initial)
	while ((run.pending.length > 0) && (run.failed == 0)):
		int config = run.pending.pop()
		run.steps++
		if (run.steps > run.limit):
			run.failed = -2
			break
		int nongreedy = config & 1
		if (run.accepted && nongreedy): continue
		if (config in run.seen): continue
		run.seen[config] = 1
		int state = (config / 2) % run.states
		int stack = (config / 2) / run.states
		int op = at_lex_field(run.program, state, 0)
		int next = at_lex_field(run.program, state, 1)
		if (at_lex_field(run.program, state, 5)): nongreedy = 1
		if (op == 1):
			run.reached.push(at_lex_config(run, state, stack, nongreedy))
		else if (op == 2):
			int other = at_lex_field(run.program, state, 2)
			run.pending.push(at_lex_config(run, other, stack, nongreedy))
			run.pending.push(at_lex_config(run, next, stack, nongreedy))
		else if (op == 3):
			run.pending.push(at_lex_config(run, next, stack, nongreedy))
		else if (op == 4):
			int ret = at_lex_field(run.program, state, 2)
			int called = at_lex_stack(run, stack, ret)
			if (run.failed == 0): run.pending.push(at_lex_config(run, next, called, nongreedy))
		else if (op == 5):
			if (stack == 0): run.accepted = 1
			else: run.pending.push(at_lex_config(run, run.returns[stack], run.parents[stack], nongreedy))
		else if ((op == 6) && at_eof):
			run.pending.push(at_lex_config(run, next, stack, nongreedy))
		if (run.reached.length > run.peak_configs): run.peak_configs = run.reached.length


# Input is NUL-terminated like the existing generated matcher ABI. Reads
# only through the first NUL; token providers separately reject embedded NULs.
# Byte lengths/spans are preserved while consuming Unicode scalar values.
at_lex_result* at_lex_execute(char* program, int states, int start, char* input, int index, int limit):
	at_lex_result* result = new at_lex_result()
	if ((states <= 0) || (states > 32767) || (limit <= 0)):
		result.status = -2
		return result
	at_lex_run* run = new at_lex_run()
	run.program = program
	run.states = states
	run.limit = limit
	run.parents = new list[int]
	run.returns = new list[int]
	run.depths = new list[int]
	run.parents.push(0)
	run.returns.push(0)
	run.depths.push(0)
	run.stacks = new map[int, int]
	run.seen = new map[int, int]
	run.pending = new list[int]
	run.reached = new list[int]
	at_lex_closure(run, at_lex_config(run, start, 0, 0), input[index] == 0)
	if (run.accepted): result.status = 1
	int position = index
	while ((run.reached.length > 0) && (run.failed == 0) && (input[position] != 0)):
		int available = 0
		while ((available < 4) && (input[position + available] != 0)): available++
		int codepoint = 0
		int width = utf8_scan(input + position, available, &codepoint)
		if (width == 0):
			run.failed = -3
			break
		list[int] previous = run.reached
		run.reached = new list[int]
		run.seen.free()
		run.seen = new map[int, int]
		run.accepted = 0
		for int config in previous:
			int nongreedy = config & 1
			if (run.accepted && nongreedy): continue
			int state = (config / 2) % states
			int stack = (config / 2) / states
			int low = at_lex_field(program, state, 3)
			int high = at_lex_field(program, state, 4)
			if ((codepoint >= low) && (codepoint <= high)):
				int next = at_lex_field(program, state, 1)
				at_lex_closure(run, at_lex_config(run, next, stack, nongreedy), input[position + width] == 0)
				if (run.failed): break
		previous.free()
		position = position + width
		if (run.accepted):
			result.status = 1
			result.length = position - index
	if (run.failed): result.status = run.failed
	result.steps = run.steps
	result.peak_configs = run.peak_configs
	result.stack_count = run.parents.length
	run.parents.free()
	run.returns.free()
	run.depths.free()
	run.stacks.free()
	run.seen.free()
	run.pending.free()
	run.reached.free()
	free(run)
	return result


# Existing matcher ABI plus explicit failure/empty-match sentinels.
# The provider must propagate negatives rather than treating them as a miss.
int at_lex_match(char* program, int states, int start, char* input, int index):
	at_lex_result* result = at_lex_execute(program, states, start, input, index, 1000000)
	int length = 0
	if (result.status == 1):
		length = result.length
		if (length == 0): length = -4
	else if (result.status < 0): length = result.status
	free(result)
	return length
