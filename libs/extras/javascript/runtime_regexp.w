import libs.extras.javascript.runtime

# Deliberately bounded, non-Unicode ECMAScript RegExp subset. Matching uses
# UTF-16 units (including NUL and lone surrogates), never C string sentinels.
# Ordered bytecode backtracking preserves alternatives/captures/greediness.
# Unsupported grammar/flags terminate with status 6; resource exhaustion is 5.
# See docs/projects/javascript_regexp.md for the precise supported surface.
struct js_re_node:
	int kind
	int ch
	int other
	int nullable
	int first_capture
	int last_capture
	js_re_node* left
	js_re_node* right
	list[int] ranges

struct js_re_instruction:
	int op
	int next
	int other
	js_re_node* node

struct js_regexp:
	js_runtime* owner
	js_text* source
	int flags
	int captures
	int position
	int depth
	int entry
	int guards
	list[js_re_node*] nodes
	list[js_re_instruction*] code

struct js_re_state:
	int pc
	int position
	list[int] captures

void js_regexp_free(void* raw):
	if (raw == 0): return
	js_regexp* re = cast(js_regexp*, raw)
	re.owner.regexp_units = re.owner.regexp_units - re.source.units.length - 1
	for i in range(re.nodes.length):
		js_re_node* node = re.nodes[i]
		__w_list_free(cast(__w_list*, node.ranges))
		free(node)
	for i in range(re.code.length): free(re.code[i])
	__w_list_free(cast(__w_list*, re.nodes))
	__w_list_free(cast(__w_list*, re.code))
	js_text_free(re.source)
	free(re)

void js_re_syntax(js_runtime* rt, char* message):
	if (rt.completion.status != 0): return
	js_runtime_fail(rt, 2, message)
	js_value* error = rt.completion.value
	if (error.kind != 5): return
	error.intrinsic_error_name = c"SyntaxError"
	js_text* key = js_runtime_key(c"name")
	js_value* property = js_runtime_property(error, key)
	js_text_free(key)
	if (property != 0 && property.value.kind == 4):
		js_text_free(property.value.text)
		property.value.text = js_runtime_key(c"SyntaxError")

int js_re_peek(js_regexp* re):
	if (re.position >= re.source.units.length): return -1
	return re.source.units[re.position]

js_re_node* js_re_node_new(js_regexp* re, int kind):
	if (js_runtime_compat_step(re.owner) == 0): return 0
	if (re.nodes.length >= 2048):
		js_runtime_fail(re.owner, 5, c"RegExp node limit")
		return 0
	js_re_node* node = new js_re_node()
	node.kind = kind
	node.ch = 0
	node.other = 0
	node.nullable = 0
	node.first_capture = re.captures + 1
	node.last_capture = re.captures
	node.left = 0
	node.right = 0
	node.ranges = new list[int]
	re.nodes.push(node)
	return node

int js_re_hex(int ch):
	if (ch >= '0' && ch <= '9'): return ch - '0'
	if (ch >= 'a' && ch <= 'f'): return ch - 'a' + 10
	if (ch >= 'A' && ch <= 'F'): return ch - 'A' + 10
	return -1

# Negative values -2..-7 denote d,D,w,W,s,S class escapes.
int js_re_escape(js_regexp* re, int in_class):
	int ch = js_re_peek(re)
	if (ch < 0):
		js_re_syntax(re.owner, c"unterminated RegExp escape")
		return 0
	re.position = re.position + 1
	if (ch == 'd'): return -2
	if (ch == 'D'): return -3
	if (ch == 'w'): return -4
	if (ch == 'W'): return -5
	if (ch == 's'): return -6
	if (ch == 'S'): return -7
	if (ch == 'n'): return 10
	if (ch == 'r'): return 13
	if (ch == 't'): return 9
	if (ch == 'f'): return 12
	if (ch == 'v'): return 11
	if (ch == 'b' && in_class): return 8
	if (ch == '0'):
		int next = js_re_peek(re)
		if (next < '0' || next > '9'): return 0
	if (ch == 'x' || ch == 'u'):
		int count = 2
		if (ch == 'u'): count = 4
		int result = 0
		for i in range(count):
			int digit = js_re_hex(js_re_peek(re))
			if (digit < 0):
				js_runtime_fail(re.owner, 6, c"RegExp requires fixed hexadecimal escapes")
				return 0
			re.position = re.position + 1
			result = result * 16 + digit
		return result
	if ((ch >= '0' && ch <= '9') || ch == 'b' || ch == 'B' || ch == 'c' || ch == 'k' || ch == 'p' || ch == 'P'):
		js_runtime_fail(re.owner, 6, c"unsupported RegExp escape or assertion")
		return 0
	return ch

js_re_node* js_re_disjunction(js_regexp* re);

js_re_node* js_re_atom(js_regexp* re):
	int ch = js_re_peek(re)
	re.position = re.position + 1
	if (ch == '('):
		re.depth = re.depth + 1
		if (re.depth > 32):
			js_runtime_fail(re.owner, 5, c"RegExp nesting limit")
			return 0
		int capture = 0
		int assertion = 0
		if (js_re_peek(re) == '?'):
			re.position = re.position + 1
			int marker = js_re_peek(re)
			if (marker == '='): assertion = 1
			else if (marker == '!'): assertion = 2
			else if (marker != ':'):
				js_runtime_fail(re.owner, 6, c"RegExp lookbehind and named groups are unsupported")
				return 0
			re.position = re.position + 1
		else:
			re.captures = re.captures + 1
			capture = re.captures
			if (capture > 16):
				js_runtime_fail(re.owner, 5, c"RegExp capture limit")
				return 0
		js_re_node* child = js_re_disjunction(re)
		if (re.owner.completion.status != 0): return 0
		if (js_re_peek(re) != ')'):
			js_re_syntax(re.owner, c"unterminated RegExp group")
			return 0
		re.position = re.position + 1
		re.depth = re.depth - 1
		if (assertion != 0):
			js_re_node* lookahead = js_re_node_new(re, 9)
			if (lookahead == 0): return 0
			lookahead.left = child
			lookahead.ch = assertion
			lookahead.nullable = 1
			return lookahead
		if (capture == 0): return child
		js_re_node* group = js_re_node_new(re, 8)
		if (group == 0): return 0
		group.left = child
		group.ch = capture
		group.first_capture = capture
		group.last_capture = re.captures
		group.nullable = child.nullable
		return group
	js_re_node* node = js_re_node_new(re, 1)
	if (node == 0): return 0
	if (ch == '*' || ch == '+' || ch == '?' || ch == ')' || ch < 0):
		js_re_syntax(re.owner, c"unexpected RegExp metacharacter")
		return node
	if (ch == '{' || ch == '}'):
		js_runtime_fail(re.owner, 6, c"RegExp counted quantifiers are unsupported")
		return node
	if (ch == '.'):
		node.kind = 3
		return node
	if (ch == '^' || ch == '$'):
		node.kind = 4
		node.ch = ch
		node.nullable = 1
		return node
	if (ch == '['):
		node.kind = 2
		if (js_re_peek(re) == '^'):
			node.other = 1
			re.position = re.position + 1
		while (re.owner.completion.status == 0 && js_re_peek(re) != ']'):
			int start = js_re_peek(re)
			if (start < 0):
				js_re_syntax(re.owner, c"unterminated RegExp class")
				break
			re.position = re.position + 1
			if (start == 92): start = js_re_escape(re, 1)
			int end = start
			if (js_re_peek(re) == '-' && re.position + 1 < re.source.units.length && re.source.units[re.position + 1] != ']'):
				re.position = re.position + 1
				end = js_re_peek(re)
				re.position = re.position + 1
				if (end == 92): end = js_re_escape(re, 1)
				if (start < 0 || end < 0): js_runtime_fail(re.owner, 6, c"RegExp class escape range endpoints are unsupported")
				else if (end < start): js_re_syntax(re.owner, c"reversed RegExp class range")
			node.ranges.push(start)
			node.ranges.push(end)
		re.position = re.position + 1
		return node
	if (ch == 92): ch = js_re_escape(re, 0)
	if (ch < 0):
		node.kind = 2
		node.ranges.push(ch)
		node.ranges.push(ch)
	else: node.ch = ch
	return node

js_re_node* js_re_sequence(js_regexp* re):
	js_re_node* result = js_re_node_new(re, 0)
	if (result == 0): return 0
	result.nullable = 1
	while (re.owner.completion.status == 0):
		int ch = js_re_peek(re)
		if (ch < 0 || ch == '|' || ch == ')'): break
		int first = re.captures + 1
		js_re_node* node = js_re_atom(re)
		if (re.owner.completion.status != 0): break
		node.first_capture = first
		node.last_capture = re.captures
		ch = js_re_peek(re)
		if (ch == '*' || ch == '+' || ch == '?'):
			re.position = re.position + 1
			if (node.kind == 4 || (node.nullable && ch != '?')):
				js_runtime_fail(re.owner, 6, c"RegExp repeated nullable atoms are unsupported")
				break
			js_re_node* repeat = js_re_node_new(re, 7)
			if (repeat == 0): break
			repeat.left = node
			repeat.ch = ch
			repeat.nullable = ch != '+' || node.nullable
			repeat.first_capture = first
			repeat.last_capture = re.captures
			if (js_re_peek(re) == '?'):
				repeat.other = 1
				re.position = re.position + 1
			node = repeat
		js_re_node* sequence = js_re_node_new(re, 5)
		if (sequence == 0): break
		sequence.left = result
		sequence.right = node
		sequence.nullable = result.nullable && node.nullable
		sequence.first_capture = result.first_capture
		sequence.last_capture = re.captures
		result = sequence
	return result

js_re_node* js_re_disjunction(js_regexp* re):
	js_re_node* result = js_re_sequence(re)
	while (re.owner.completion.status == 0 && js_re_peek(re) == '|'):
		re.position = re.position + 1
		js_re_node* right = js_re_sequence(re)
		js_re_node* alt = js_re_node_new(re, 6)
		if (alt == 0 || right == 0): return result
		alt.left = result
		alt.right = right
		alt.nullable = result.nullable || right.nullable
		alt.first_capture = result.first_capture
		alt.last_capture = re.captures
		result = alt
	return result

int js_re_emit(js_regexp* re, int op, int next, int other, js_re_node* node):
	if (js_runtime_compat_step(re.owner) == 0): return 0
	if (re.code.length >= 4096):
		js_runtime_fail(re.owner, 5, c"RegExp instruction limit")
		return 0
	js_re_instruction* instruction = new js_re_instruction()
	instruction.op = op
	instruction.next = next
	instruction.other = other
	instruction.node = node
	re.code.push(instruction)
	return re.code.length - 1

# Emit backwards so alternatives and repetition need no code relocation.
int js_re_compile_node_guard(js_regexp* re, js_re_node* node, int next, int guard_depth):
	if (re.owner.completion.status != 0): return 0
	if (node.kind == 0): return next
	if (node.kind <= 4): return js_re_emit(re, node.kind, next, 0, node)
	if (node.kind == 5):
		int right = js_re_compile_node_guard(re, node.right, next, guard_depth)
		return js_re_compile_node_guard(re, node.left, right, guard_depth)
	if (node.kind == 6):
		int left = js_re_compile_node_guard(re, node.left, next, guard_depth)
		int right = js_re_compile_node_guard(re, node.right, next, guard_depth)
		return js_re_emit(re, 5, left, right, node)
	if (node.kind == 8):
		int end = js_re_emit(re, 6, next, node.ch * 2 + 1, node)
		int child = js_re_compile_node_guard(re, node.left, end, guard_depth)
		return js_re_emit(re, 6, child, node.ch * 2, node)
	if (node.kind == 9):
		# A separate accept ends the assertion at its first ordered match.
		# Its alternative states never become outer backtracking choices.
		int end = js_re_emit(re, 0, 0, 0, 0)
		int child = js_re_compile_node_guard(re, node.left, end, guard_depth)
		return js_re_emit(re, 8, next, child, node)
	if (node.ch == '?' && node.left.nullable):
		# RepeatMatcher rejects a zero-width optional iteration, even when
		# greedy. Backtrack inside the child before trying the skipped branch.
		# Nested guards use bounded scratch slots after the visible captures;
		# sibling alternatives/sequences reuse slots, and match_at removes them.
		if (guard_depth >= 32):
			js_runtime_fail(re.owner, 5, c"RegExp optional guard nesting limit")
			return 0
		if (re.guards <= guard_depth): re.guards = guard_depth + 1
		int slot = (re.captures + 1) * 2 + guard_depth
		int progress = js_re_emit(re, 10, next, slot, node)
		int child = js_re_compile_node_guard(re, node.left, progress, guard_depth + 1)
		if (node.first_capture <= node.last_capture): child = js_re_emit(re, 7, child, 0, node)
		int start = js_re_emit(re, 9, child, slot, node)
		if (node.other): return js_re_emit(re, 5, next, start, node)
		return js_re_emit(re, 5, start, next, node)
	int branch = js_re_emit(re, 5, 0, next, node)
	int after = branch
	if (node.ch == '?'): after = next
	int child = js_re_compile_node_guard(re, node.left, after, guard_depth)
	if (node.first_capture <= node.last_capture): child = js_re_emit(re, 7, child, 0, node)
	re.code[branch].next = child
	if (node.other):
		re.code[branch].next = next
		re.code[branch].other = child
	if (node.ch == '+'): return child
	return branch

int js_re_compile_node(js_regexp* re, js_re_node* node, int next):
	return js_re_compile_node_guard(re, node, next, 0)

int js_re_flag(int ch):
	if (ch == 'g'): return 1
	if (ch == 'i'): return 2
	if (ch == 'm'): return 4
	if (ch == 's'): return 8
	if (ch == 'y'): return 16
	return 0

js_regexp* js_re_compile(js_runtime* rt, js_text* pattern, js_text* flags):
	if (pattern.units.length > 1024 || pattern.units.length + 1 > 65536 - rt.regexp_units):
		js_runtime_fail(rt, 5, c"RegExp pattern storage limit")
		return 0
	int bits = 0
	for i in range(flags.units.length):
		if (js_runtime_compat_step(rt) == 0): return 0
		int bit = js_re_flag(flags.units[i])
		if (bit == 0):
			int ch = flags.units[i]
			if (ch == 'd' || ch == 'u' || ch == 'v'): js_runtime_fail(rt, 6, c"unsupported RegExp flag (supported: gimsy)")
			else: js_re_syntax(rt, c"invalid RegExp flag")
			return 0
		if (bits & bit):
			js_re_syntax(rt, c"duplicate RegExp flag")
			return 0
		bits = bits | bit
	if (bits & 2):
		for i in range(pattern.units.length):
			if (pattern.units[i] > 127):
				js_runtime_fail(rt, 6, c"RegExp ignoreCase supports ASCII only")
				return 0
	js_regexp* re = new js_regexp()
	re.owner = rt
	re.source = js_text_clone(pattern)
	re.flags = bits
	re.captures = 0
	re.position = 0
	re.depth = 0
	re.entry = 0
	re.guards = 0
	re.nodes = new list[js_re_node*]
	re.code = new list[js_re_instruction*]
	rt.regexp_units = rt.regexp_units + pattern.units.length + 1
	js_re_node* root = js_re_disjunction(re)
	if (rt.completion.status == 0 && re.position != pattern.units.length): js_re_syntax(rt, c"unexpected RegExp closing group")
	if (rt.completion.status == 0 && (bits & 2)):
		for i in range(re.nodes.length):
			js_re_node* node = re.nodes[i]
			if (node.kind == 1 && node.ch > 127): js_runtime_fail(rt, 6, c"RegExp ignoreCase supports ASCII only")
			for j in range(node.ranges.length):
				if (node.ranges[j] > 127): js_runtime_fail(rt, 6, c"RegExp ignoreCase supports ASCII only")
	if (rt.completion.status == 0):
		int end = js_re_emit(re, 0, 0, 0, 0)
		re.entry = js_re_compile_node(re, root, end)
	if (rt.completion.status != 0):
		js_regexp_free(re)
		return 0
	return re

int js_re_line(int ch):
	return ch == 10 || ch == 13 || ch == 8232 || ch == 8233

int js_re_word(int ch):
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_'

int js_re_space(int ch):
	return (ch >= 9 && ch <= 13) || ch == 32 || ch == 160 || ch == 5760 || (ch >= 8192 && ch <= 8202) || ch == 8232 || ch == 8233 || ch == 8239 || ch == 8287 || ch == 12288 || ch == 65279

int js_re_class(js_re_node* node, int ch, int flags):
	int found = 0
	for i in range(0, node.ranges.length, 2):
		int start = node.ranges[i]
		int end = node.ranges[i + 1]
		if (start >= 0):
			if (ch >= start && ch <= end): found = 1
			if (flags & 2):
				int flipped = ch
				if (ch >= 'a' && ch <= 'z'): flipped = ch - 32
				if (ch >= 'A' && ch <= 'Z'): flipped = ch + 32
				if (flipped >= start && flipped <= end): found = 1
		else:
			int item = 0
			if (start == -2 || start == -3): item = ch >= '0' && ch <= '9'
			if (start == -4 || start == -5): item = js_re_word(ch)
			if (start == -6 || start == -7): item = js_re_space(ch)
			if (start == -3 || start == -5 || start == -7): item = item == 0
			if (item): found = 1
	if (node.other): return found == 0
	return found

js_re_state* js_re_state_new(int pc, int position, list[int] captures, int count):
	js_re_state* state = new js_re_state()
	state.pc = pc
	state.position = position
	state.captures = new list[int]
	for i in range(count):
		int value = -1
		if (captures != 0): value = captures[i]
		state.captures.push(value)
	return state

void js_re_state_free(js_re_state* state):
	if (state == 0): return
	__w_list_free(cast(__w_list*, state.captures))
	free(state)

# All nested assertions share the old 4096 pending + 1 active state bound.
# Each call owns its input state and pending alternatives; only its first
# successful state escapes. Recursion depends on pattern nesting, never input.
js_re_state* js_re_match_program(js_regexp* re, js_text* input, js_re_state* state, int depth, int* states):
	list[js_re_state*] stack = new list[js_re_state*]
	js_re_state* result = 0
	while (state != 0 && js_runtime_compat_step(re.owner)):
		js_re_instruction* instruction = re.code[state.pc]
		int op = instruction.op
		int matched = 1
		if (op == 0):
			result = state
			state = 0
			break
		if (op >= 1 && op <= 3):
			matched = state.position < input.units.length
			if (matched):
				int ch = input.units[state.position]
				if (op == 1):
					int expected = instruction.node.ch
					if (re.flags & 2):
						if (ch >= 'A' && ch <= 'Z'): ch = ch + 32
						if (expected >= 'A' && expected <= 'Z'): expected = expected + 32
					matched = ch == expected
				if (op == 2): matched = js_re_class(instruction.node, ch, re.flags)
				if (op == 3): matched = (re.flags & 8) != 0 || js_re_line(ch) == 0
			if (matched): state.position = state.position + 1
		if (op == 4):
			if (instruction.node.ch == '^'):
				matched = state.position == 0
				if ((re.flags & 4) && state.position > 0): matched = js_re_line(input.units[state.position - 1])
			else:
				matched = state.position == input.units.length
				if ((re.flags & 4) && state.position < input.units.length): matched = js_re_line(input.units[state.position])
		if (op == 5):
			if (*states >= 4097):
				js_runtime_fail(re.owner, 5, c"RegExp backtracking stack limit")
				break
			stack.push(js_re_state_new(instruction.other, state.position, state.captures, state.captures.length))
			*states = *states + 1
		if (op == 6): state.captures[instruction.other] = state.position
		if (op == 7):
			for i in range(instruction.node.first_capture * 2, (instruction.node.last_capture + 1) * 2): state.captures[i] = -1
		if (op == 8):
			if (depth >= 32 || *states >= 4097):
				js_runtime_fail(re.owner, 5, c"RegExp assertion nesting or backtracking state limit")
				break
			js_re_state* assertion = js_re_state_new(instruction.other, state.position, state.captures, state.captures.length)
			*states = *states + 1
			for i in range(instruction.node.first_capture * 2, (instruction.node.last_capture + 1) * 2): assertion.captures[i] = -1
			assertion = js_re_match_program(re, input, assertion, depth + 1, states)
			if (re.owner.completion.status != 0):
				if (assertion != 0):
					js_re_state_free(assertion)
					*states = *states - 1
				break
			matched = assertion != 0
			if (instruction.node.ch == 2): matched = assertion == 0
			if (matched):
				for i in range(instruction.node.first_capture * 2, (instruction.node.last_capture + 1) * 2):
					int capture = -1
					if (instruction.node.ch == 1): capture = assertion.captures[i]
					state.captures[i] = capture
			if (assertion != 0):
				js_re_state_free(assertion)
				*states = *states - 1
		if (op == 9): state.captures[instruction.other] = state.position
		if (op == 10): matched = state.position != state.captures[instruction.other]
		if (matched): state.pc = instruction.next
		else:
			js_re_state_free(state)
			*states = *states - 1
			state = 0
			if (stack.length > 0): state = stack.pop()
	if (state != 0):
		js_re_state_free(state)
		*states = *states - 1
	for i in range(stack.length): js_re_state_free(stack[i])
	*states = *states - stack.length
	__w_list_free(cast(__w_list*, stack))
	return result

js_re_state* js_re_match_at(js_regexp* re, js_text* input, int start):
	int captures = (re.captures + 1) * 2
	js_re_state* state = js_re_state_new(re.entry, start, 0, captures + re.guards)
	state.captures[0] = start
	int states = 1
	js_re_state* result = js_re_match_program(re, input, state, 0, &states)
	if (result != 0):
		result.captures[1] = result.position
		while (result.captures.length > captures): result.captures.pop()
	return result

js_re_state* js_re_search(js_regexp* re, js_text* input, int start):
	if (re.flags & 2):
		for i in range(input.units.length):
			if (js_runtime_compat_step(re.owner) == 0): return 0
			if (input.units[i] > 127):
				js_runtime_fail(re.owner, 6, c"RegExp ignoreCase supports ASCII input only")
				return 0
	for i in range(start, input.units.length + 1):
		if (js_runtime_compat_step(re.owner) == 0): break
		js_re_state* result = js_re_match_at(re, input, i)
		if (result != 0): return result
		if (re.flags & 16): break
	return 0

js_value* js_re_slice(js_runtime* rt, js_text* input, int start, int end):
	if (start < 0): return rt.undefined_value
	js_text* text = js_text_new()
	for i in range(start, end):
		if (js_runtime_compat_step(rt) == 0): break
		text.units.push(input.units[i])
	js_value* value = js_runtime_string(rt, text)
	js_text_free(text)
	return value

int js_re_last_index_set(js_runtime* rt, js_value* value, int index):
	if (rt.completion.status != 0): return 0
	if (js_runtime_set(rt, value, c"lastIndex", js_runtime_number(rt, cast(float64, index)))): return 1
	js_runtime_fail(rt, 2, c"RegExp lastIndex is not writable")
	return 0

# Primitive ToLength subset, with explicit rejection of object coercion.
int js_re_last_index(js_runtime* rt, js_value* value, int length):
	js_value* index = js_runtime_get(rt, value, c"lastIndex")
	float64 number = 0.0
	if (index.kind == 3 || index.kind == 2): number = index.number
	else if (index.kind != 0 && index.kind != 1):
		js_runtime_fail(rt, 6, c"RegExp lastIndex requires a numeric primitive")
		return 0
	if (f64is_nan(number) || number <= 0.0): return 0
	if (number > cast(float64, length)): return length + 1
	return cast(int, number)

js_re_state* js_re_exec(js_runtime* rt, js_value* value, js_text* input):
	js_regexp* re = cast(js_regexp*, value.regexp)
	int stateful = re.flags & 17
	int start = 0
	if (stateful): start = js_re_last_index(rt, value, input.units.length)
	js_re_state* state = 0
	if (rt.completion.status == 0): state = js_re_search(re, input, start)
	if (stateful && rt.completion.status == 0):
		int index = 0
		if (state != 0): index = state.position
		js_re_last_index_set(rt, value, index)
	if (rt.completion.status != 0):
		js_re_state_free(state)
		return 0
	return state

js_value* js_re_method(void* runtime, void* context, js_value* receiver, list[js_value*] args);

int js_re_check_exec(js_runtime* rt, js_value* value):
	js_value* method = js_runtime_get(rt, value, c"exec")
	if (rt.completion.status != 0): return 0
	if (method.kind != 7 && method.kind != 9): return 1
	if (method.kind == 9 && method.host == cast(int, js_re_method) && cast(int, method.host_context) == 2): return 1
	js_runtime_fail(rt, 6, c"custom RegExp exec is outside the runtime subset")
	return 0

js_value* js_re_method(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (receiver.regexp == 0):
		js_runtime_fail(rt, 2, c"RegExp method requires RegExp receiver")
		return rt.undefined_value
	if (cast(int, context) == 1 && js_re_check_exec(rt, receiver) == 0): return rt.undefined_value
	js_value* argument = rt.undefined_value
	if (args.length > 0): argument = args[0]
	js_text* input = js_runtime_primitive_text(rt, argument)
	if (input == 0): return rt.undefined_value
	js_re_state* state = js_re_exec(rt, receiver, input)
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0):
		if (cast(int, context) == 1): result = js_runtime_boolean(rt, state != 0)
		else if (state == 0): result = js_runtime_alloc(rt, 1)
		else:
			result = js_runtime_alloc(rt, 6)
			for i in range(0, state.captures.length, 2):
				js_runtime_array_append(rt, result, js_re_slice(rt, input, state.captures[i], state.captures[i + 1]))
			js_runtime_set(rt, result, c"index", js_runtime_number(rt, cast(float64, state.captures[0])))
			js_runtime_set(rt, result, c"input", js_runtime_string(rt, input))
			js_runtime_set(rt, result, c"groups", rt.undefined_value)
	js_re_state_free(state)
	js_text_free(input)
	return result

js_text* js_re_source(js_regexp* re):
	if (re.source.units.length == 0): return js_runtime_key(c"(?:)")
	js_text* text = js_text_new()
	int escaped = 0
	for i in range(re.source.units.length):
		int ch = re.source.units[i]
		if (ch == '/' && escaped == 0): text.units.push(92)
		if (js_re_line(ch)):
			if (escaped): text.units.pop()
			text.units.push(92)
			if (ch == 10): text.units.push('n')
			else if (ch == 13): text.units.push('r')
			else:
				text.units.push('u')
				text.units.push('2')
				text.units.push('0')
				text.units.push('2')
				text.units.push('8' + ch - 8232)
		else: text.units.push(ch)
		if (ch == 92): escaped = escaped == 0
		else: escaped = 0
	return text

js_value* js_re_getter(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	int operation = cast(int, context)
	js_regexp* re = cast(js_regexp*, receiver.regexp)
	if (re == 0):
		if (receiver == rt.regexp_prototype):
			if (operation > 1): return rt.undefined_value
			js_text* text = js_runtime_key(c"")
			if (operation == 0):
				js_text_free(text)
				text = js_runtime_key(c"(?:)")
			js_value* result = js_runtime_string(rt, text)
			js_text_free(text)
			return result
		js_runtime_fail(rt, 2, c"RegExp getter requires RegExp receiver")
		return rt.undefined_value
	if (operation > 1): return js_runtime_boolean(rt, (re.flags & (1 << (operation - 2))) != 0)
	js_text* text = 0
	if (operation == 0): text = js_re_source(re)
	else:
		text = js_text_new()
		char* order = c"gimsy"
		for i in range(5):
			if (re.flags & (1 << i)): text.units.push(order[i])
	js_value* value = js_runtime_string(rt, text)
	js_text_free(text)
	return value

js_value* js_re_create(js_runtime* rt, js_text* pattern, js_text* flags):
	js_regexp* re = js_re_compile(rt, pattern, flags)
	if (re == 0): return rt.undefined_value
	js_value* value = js_runtime_alloc(rt, 5)
	if (rt.completion.status != 0):
		js_regexp_free(re)
		return rt.undefined_value
	value.regexp = re
	value.prototype = rt.regexp_prototype
	js_text* key = js_runtime_key(c"lastIndex")
	js_runtime_define_data(rt, value, key, js_runtime_number(rt, 0.0), 1, 0, 0)
	js_text_free(key)
	return value

js_value* js_regexp_literal(js_runtime* rt, char* raw):
	int end = strlen(raw) - 1
	while (end > 0 && raw[end] != '/'): end = end - 1
	js_text* pattern = js_text_from_utf8(raw + 1, end - 1)
	js_text* flags = js_text_from_utf8(raw + end + 1, strlen(raw + end + 1))
	js_value* value = js_re_create(rt, pattern, flags)
	js_text_free(pattern)
	js_text_free(flags)
	return value

js_value* js_re_constructor(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_text* pattern = 0
	js_text* flags = 0
	if (args.length == 0 || args[0].kind == 0): pattern = js_text_new()
	else: pattern = js_runtime_primitive_text(rt, args[0])
	if (args.length < 2 || args[1].kind == 0): flags = js_text_new()
	else: flags = js_runtime_primitive_text(rt, args[1])
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0): result = js_re_create(rt, pattern, flags)
	js_text_free(pattern)
	js_text_free(flags)
	return result

int js_re_append(js_runtime* rt, js_text* output, js_text* source, int start, int end):
	if (start < 0): return 1
	if (end - start > rt.max_properties - output.units.length):
		js_runtime_fail(rt, 5, c"RegExp replacement output limit")
		return 0
	for i in range(start, end):
		if (js_runtime_compat_step(rt) == 0): return 0
		output.units.push(source.units[i])
	return 1

void js_re_substitute(js_runtime* rt, js_text* output, js_text* replacement, js_text* input, js_re_state* match):
	int start = match.captures[0]
	int end = match.captures[1]
	for i in range(replacement.units.length):
		if (rt.completion.status != 0): break
		int ch = replacement.units[i]
		if (ch == '$' && i + 1 < replacement.units.length):
			int next = replacement.units[i + 1]
			if (next == '$'):
				i = i + 1
			else if (next == '&' || next == 96 || next == 39):
				int begin = start
				int finish = end
				if (next == 96):
					begin = 0
					finish = start
				if (next == 39):
					begin = end
					finish = input.units.length
				js_re_append(rt, output, input, begin, finish)
				i = i + 1
				continue
			else if (next >= '0' && next <= '9'):
				int capture = next - '0'
				int digits = 1
				if (i + 2 < replacement.units.length):
					int second = replacement.units[i + 2] - '0'
					if (second >= 0 && second <= 9 && (capture * 10 + second) * 2 < match.captures.length):
						capture = capture * 10 + second
						digits = 2
				if (capture > 0 && capture * 2 < match.captures.length):
					js_re_append(rt, output, input, match.captures[capture * 2], match.captures[capture * 2 + 1])
					i = i + digits
					continue
		if (output.units.length >= rt.max_properties):
			js_runtime_fail(rt, 5, c"RegExp replacement output limit")
			break
		if (js_runtime_compat_step(rt) == 0): break
		output.units.push(ch)

js_value* js_re_replace(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (receiver.kind != 4):
		js_runtime_fail(rt, 2, c"String.replace requires string receiver")
		return rt.undefined_value
	js_value* search = rt.undefined_value
	js_value* replacement_value = rt.undefined_value
	if (args.length > 0): search = args[0]
	if (args.length > 1): replacement_value = args[1]
	# Callable replacers require the separate observable callback protocol.
	js_text* replacement = js_runtime_primitive_text(rt, replacement_value)
	if (replacement == 0): return rt.undefined_value
	js_text* input = receiver.text
	js_text* output = js_text_new()
	int previous = 0
	if (search.regexp != 0):
		js_re_check_exec(rt, search)
		js_regexp* re = cast(js_regexp*, search.regexp)
		if (re.flags & 1): js_re_last_index_set(rt, search, 0)
		while (rt.completion.status == 0):
			js_re_state* match = js_re_exec(rt, search, input)
			if (match == 0): break
			js_re_append(rt, output, input, previous, match.captures[0])
			js_re_substitute(rt, output, replacement, input, match)
			previous = match.captures[1]
			int empty = match.captures[0] == match.captures[1]
			js_re_state_free(match)
			if ((re.flags & 1) == 0): break
			if (empty): js_re_last_index_set(rt, search, previous + 1)
	else:
		js_text* needle = js_runtime_primitive_text(rt, search)
		if (needle != 0):
			for start in range(input.units.length - needle.units.length + 1):
				if (js_runtime_compat_step(rt) == 0): break
				int found = 1
				for i in range(needle.units.length):
					if (js_runtime_compat_step(rt) == 0 || input.units[start + i] != needle.units[i]):
						found = 0
						break
				if (found):
					js_re_state* match = js_re_state_new(0, start + needle.units.length, 0, 2)
					match.captures[0] = start
					match.captures[1] = match.position
					js_re_append(rt, output, input, 0, start)
					js_re_substitute(rt, output, replacement, input, match)
					previous = match.position
					js_re_state_free(match)
					break
		js_text_free(needle)
	if (rt.completion.status == 0): js_re_append(rt, output, input, previous, input.units.length)
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0): result = js_runtime_string(rt, output)
	js_text_free(output)
	js_text_free(replacement)
	return result

void js_runtime_install_regexp(js_runtime* rt):
	rt.regexp_prototype = js_runtime_alloc(rt, 5)
	js_value* constructor = js_runtime_host_callable(rt, 0, js_re_constructor)
	constructor.host_construct = 1
	js_text* key = js_runtime_key(c"prototype")
	js_runtime_define_data(rt, constructor, key, rt.regexp_prototype, 0, 0, 0)
	js_text_free(key)
	js_runtime_set(rt, rt.global, c"RegExp", constructor)
	key = js_runtime_key(c"constructor")
	js_runtime_define_data(rt, rt.regexp_prototype, key, constructor, 1, 0, 1)
	js_text_free(key)
	js_runtime_collection_method(rt, rt.regexp_prototype, c"test", 1, js_re_method)
	js_runtime_collection_method(rt, rt.regexp_prototype, c"exec", 2, js_re_method)
	list[char*] names = new list[char*]
	names.push(c"source")
	names.push(c"flags")
	names.push(c"global")
	names.push(c"ignoreCase")
	names.push(c"multiline")
	names.push(c"dotAll")
	names.push(c"sticky")
	for i in range(names.length):
		key = js_runtime_key(names[i])
		js_value* getter = js_runtime_host_callable(rt, cast(void*, i), js_re_getter)
		js_runtime_define_accessor(rt, rt.regexp_prototype, key, getter, 0, 0, 1)
		js_text_free(key)
	__w_list_free(cast(__w_list*, names))
	js_runtime_collection_method(rt, rt.string_prototype, c"replace", 0, js_re_replace)
