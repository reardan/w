# RegExp objects for the embedded interpreter: a backtracking matcher compiled
# from the shared pattern parser (regexp_syntax.w), RegExp.prototype.exec/test/
# toString, the flag/source accessors and a RegExp constructor.
# Matching follows ECMA-262 2020 sec-regexp-regular-expression-objects with
# Annex B; it is bounded by the interpreter's step budget. Unicode property
# escapes match the Unicode 12.1 tables in regexp_property.w, the version the
# parser validates names against. Case-insensitive matching uses regexp_case.w.
import libs.extras.javascript.runtime
import libs.extras.javascript.regexp_syntax
import libs.extras.javascript.regexp_case
import libs.extras.javascript.regexp_property


const int JS_RX_OP_CHAR = 1
const int JS_RX_OP_ANY = 2
const int JS_RX_OP_CLASS = 3
const int JS_RX_OP_BOL = 4
const int JS_RX_OP_EOL = 5
const int JS_RX_OP_WORD = 6
const int JS_RX_OP_SAVE = 7
const int JS_RX_OP_SPLIT = 8
const int JS_RX_OP_JMP = 9
const int JS_RX_OP_BACKREF = 10
const int JS_RX_OP_LOOK = 11
const int JS_RX_OP_LOOK_END = 12
const int JS_RX_OP_MATCH = 13
const int JS_RX_OP_RESET = 14
const int JS_RX_OP_MARK = 15
const int JS_RX_OP_CHECK = 16

# Runtime-resolved property set items (see js_regexp_runtime_property).
const int JS_RX_RUNTIME_PROPERTY = 2097152
const int JS_RX_MAX_PROGRAM = 200000
const int JS_RX_MAX_STACK = 3000000


struct js_regexp_program:
	js_regexp* rx
	list[int] code
	list[js_regexp_node*] classes
	int registers
	int flags
	# Pattern source as UTF-16 code units, as given (before escaping).
	js_text* source
	char* error


struct js_regexp_vm:
	js_regexp_program* program
	js_runtime* rt
	list[int] input
	list[int] caps
	list[int] regs
	int unicode
	int ignore
	int multiline
	int dot_all
	int aborted


js_value* js_regexp_match_array(js_runtime* rt, js_regexp_vm* vm, js_text* input);
js_text* js_regexp_escaped_source(js_regexp_program* program);
void js_regexp_append_flags(js_text* text, int flags);
js_value* js_regexp_string(js_runtime* rt, char* raw);


void js_regexp_program_free(void* raw):
	js_regexp_program* program = cast(js_regexp_program*, raw)
	if (program == 0): return
	js_regexp_free(program.rx)
	__w_list_free(cast(__w_list*, program.code))
	__w_list_free(cast(__w_list*, program.classes))
	js_text_free(program.source)
	free(program)


# Resolves a parsed property item (validation table word index) to its
# runtime form: JS_RX_RUNTIME_PROPERTY + kind * 4096 + data id, keeping
# JS_RX_NEGATED. Every validated property has data (regexp_property.w).
int js_regexp_runtime_property(int item):
	int negated = item & JS_RX_NEGATED
	int code = item - JS_RX_PROPERTY - negated
	int kind = code / 4096
	int index = code % 4096
	int id = 0
	if (kind == JS_RX_PROPERTY_GC): id = js_regexp_property_gc_id(index)
	else if (kind == JS_RX_PROPERTY_BINARY): id = js_regexp_property_binary_id(index)
	else: id = js_regexp_property_script_id(index)
	return JS_RX_RUNTIME_PROPERTY + kind * 4096 + id + negated


int js_regexp_canonicalize(int ch, int unicode):
	if (unicode): return js_regexp_case_lookup(js_regexp_fold_data(), js_regexp_fold_count(), ch)
	if (ch > 65535): return ch
	return js_regexp_case_lookup(js_regexp_upper_data(), js_regexp_upper_count(), ch)


int js_regexp_emit(js_regexp_program* program, int op):
	program.code.push(op)
	return program.code.length - 1


# Lowest and highest capture index inside a quantified atom, for the
# per-iteration capture reset of sec-runtime-semantics-repeatmatcher-abstract-operation.
void js_regexp_capture_span(js_regexp_node* node, int* low, int* high):
	if (node.kind == JS_RX_GROUP && node.value > 0):
		if (*low == 0 || node.value < *low): *low = node.value
		if (node.value > *high): *high = node.value
	for js_regexp_node* child in node.children: js_regexp_capture_span(child, low, high)


void js_regexp_compile(js_regexp_program* program, js_regexp_node* node, int dir);


# One quantifier iteration that may be skipped: SPLIT, then MARK/RESET/body/
# CHECK so an empty iteration fails. Returns the SPLIT operand to patch.
int js_regexp_optional(js_regexp_program* program, js_regexp_node* node, int dir, int reg, int low, int high):
	js_regexp_emit(program, JS_RX_OP_SPLIT)
	int split = program.code.length
	js_regexp_emit(program, 0)
	js_regexp_emit(program, 0)
	int body = program.code.length
	js_regexp_emit(program, JS_RX_OP_MARK)
	js_regexp_emit(program, reg)
	if (high > 0):
		js_regexp_emit(program, JS_RX_OP_RESET)
		js_regexp_emit(program, low * 2)
		js_regexp_emit(program, high * 2 + 1)
	js_regexp_compile(program, node.children[0], dir)
	js_regexp_emit(program, JS_RX_OP_CHECK)
	js_regexp_emit(program, reg)
	if (node.greedy): program.code[split] = body
	else: program.code[split + 1] = body
	return split


void js_regexp_patch_exit(js_regexp_program* program, js_regexp_node* node, int split, int target):
	if (node.greedy): program.code[split + 1] = target
	else: program.code[split] = target


void js_regexp_compile_quantifier(js_regexp_program* program, js_regexp_node* node, int dir):
	int low = 0
	int high = 0
	js_regexp_capture_span(node.children[0], &low, &high)
	int reg = program.registers
	program.registers = program.registers + 1
	for i in range(node.min):
		if (program.code.length > JS_RX_MAX_PROGRAM): return
		if (high > 0):
			js_regexp_emit(program, JS_RX_OP_RESET)
			js_regexp_emit(program, low * 2)
			js_regexp_emit(program, high * 2 + 1)
		js_regexp_compile(program, node.children[0], dir)
	if (node.max < 0):
		int loop = program.code.length
		int split = js_regexp_optional(program, node, dir, reg, low, high)
		js_regexp_emit(program, JS_RX_OP_JMP)
		js_regexp_emit(program, loop)
		js_regexp_patch_exit(program, node, split, program.code.length)
		return
	list[int] splits = new list[int]
	for i in range(node.max - node.min):
		if (program.code.length > JS_RX_MAX_PROGRAM): break
		splits.push(js_regexp_optional(program, node, dir, reg, low, high))
	for int split in splits: js_regexp_patch_exit(program, node, split, program.code.length)
	__w_list_free(cast(__w_list*, splits))


void js_regexp_compile(js_regexp_program* program, js_regexp_node* node, int dir):
	if (program.code.length > JS_RX_MAX_PROGRAM): return
	int kind = node.kind
	if (kind == JS_RX_SEQ):
		int count = node.children.length
		for i in range(count):
			if (dir > 0): js_regexp_compile(program, node.children[i], dir)
			else: js_regexp_compile(program, node.children[count - 1 - i], dir)
	else if (kind == JS_RX_ALT):
		list[int] exits = new list[int]
		for i in range(node.children.length):
			if (i + 1 < node.children.length):
				js_regexp_emit(program, JS_RX_OP_SPLIT)
				int split = program.code.length
				js_regexp_emit(program, split + 2)
				js_regexp_emit(program, 0)
				js_regexp_compile(program, node.children[i], dir)
				js_regexp_emit(program, JS_RX_OP_JMP)
				exits.push(js_regexp_emit(program, 0))
				program.code[split + 1] = program.code.length
			else: js_regexp_compile(program, node.children[i], dir)
		for int exit in exits: program.code[exit] = program.code.length
		__w_list_free(cast(__w_list*, exits))
	else if (kind == JS_RX_CHAR):
		js_regexp_emit(program, JS_RX_OP_CHAR)
		int value = node.value
		if (program.flags & JS_RX_IGNORE_CASE): value = js_regexp_canonicalize(value, (program.flags & JS_RX_UNICODE) != 0)
		js_regexp_emit(program, value)
		js_regexp_emit(program, dir)
	else if (kind == JS_RX_DOT):
		js_regexp_emit(program, JS_RX_OP_ANY)
		js_regexp_emit(program, dir)
	else if (kind == JS_RX_CLASS):
		for i in range(node.sets.length):
			int item = node.sets[i]
			if (item >= JS_RX_PROPERTY && item < JS_RX_RUNTIME_PROPERTY): node.sets[i] = js_regexp_runtime_property(item)
		js_regexp_emit(program, JS_RX_OP_CLASS)
		js_regexp_emit(program, program.classes.length)
		program.classes.push(node)
		js_regexp_emit(program, dir)
	else if (kind == JS_RX_BOL || kind == JS_RX_EOL): js_regexp_emit(program, JS_RX_OP_BOL + kind - JS_RX_BOL)
	else if (kind == JS_RX_WORD):
		js_regexp_emit(program, JS_RX_OP_WORD)
		js_regexp_emit(program, node.negate)
	else if (kind == JS_RX_GROUP):
		if (node.value == 0): js_regexp_compile(program, node.children[0], dir)
		else:
			js_regexp_emit(program, JS_RX_OP_SAVE)
			if (dir > 0): js_regexp_emit(program, node.value * 2)
			else: js_regexp_emit(program, node.value * 2 + 1)
			js_regexp_compile(program, node.children[0], dir)
			js_regexp_emit(program, JS_RX_OP_SAVE)
			if (dir > 0): js_regexp_emit(program, node.value * 2 + 1)
			else: js_regexp_emit(program, node.value * 2)
	else if (kind == JS_RX_LOOK):
		js_regexp_emit(program, JS_RX_OP_LOOK)
		js_regexp_emit(program, node.value)
		js_regexp_emit(program, node.negate)
		int end = js_regexp_emit(program, 0)
		int body_dir = 1
		if (node.value): body_dir = -1
		js_regexp_compile(program, node.children[0], body_dir)
		js_regexp_emit(program, JS_RX_OP_LOOK_END)
		program.code[end] = program.code.length
	else if (kind == JS_RX_BACKREF):
		js_regexp_emit(program, JS_RX_OP_BACKREF)
		js_regexp_emit(program, node.value)
		js_regexp_emit(program, dir)
	else if (kind == JS_RX_QUANT):
		if (node.max != 0): js_regexp_compile_quantifier(program, node, dir)


# Compile UTF-16 source units with flag bits. Returns a program whose error
# is a static message (syntax errors start with "invalid regular expression").
js_regexp_program* js_regexp_program_new(js_text* source, int flags):
	js_regexp_program* program = new js_regexp_program()
	program.code = new list[int]
	program.classes = new list[js_regexp_node*]
	program.registers = 0
	program.flags = flags
	program.source = js_text_clone(source)
	program.error = 0
	list[int] pattern = new list[int]
	int count = source.units.length
	int i = 0
	while (i < count):
		int unit = source.units[i]
		if ((flags & JS_RX_UNICODE) && js_regexp_lead(unit) && i + 1 < count && js_regexp_trail(source.units[i + 1])):
			unit = 65536 + ((unit - 55296) << 10) + (source.units[i + 1] - 56320)
			i = i + 1
		pattern.push(unit)
		i = i + 1
	program.rx = js_regexp_parse(pattern, flags)
	__w_list_free(cast(__w_list*, pattern))
	if (program.rx.error != 0):
		program.error = program.rx.error
		return program
	js_regexp_emit(program, JS_RX_OP_SAVE)
	js_regexp_emit(program, 0)
	js_regexp_compile(program, program.rx.root, 1)
	js_regexp_emit(program, JS_RX_OP_SAVE)
	js_regexp_emit(program, 1)
	js_regexp_emit(program, JS_RX_OP_MATCH)
	if (program.error == 0 && program.code.length > JS_RX_MAX_PROGRAM): program.error = c"regular expression program size limit"
	return program


# Literal text "/pattern/flags" as UTF-16 source.
js_regexp_program* js_regexp_program_literal(char* text):
	int end = strlen(text) - 1
	while (end > 0 && text[end] != '/'): end = end - 1
	int flags = js_regexp_flag_bits(text, end + 1)
	js_text* source = js_text_from_utf8(text + 1, end - 1)
	if (source == 0): source = js_text_new()
	js_regexp_program* program = js_regexp_program_new(source, flags)
	js_text_free(source)
	return program


# Runtime preflight: the literal compiles and needs no unshipped data.
int js_regexp_runtime_supported(char* text):
	js_regexp_program* program = js_regexp_program_literal(text)
	int ok = program.error == 0
	js_regexp_program_free(program)
	return ok


int js_regexp_line_terminator(int ch):
	return ch == 10 || ch == 13 || ch == 8232 || ch == 8233


int js_regexp_space(int ch):
	if (ch == 9 || ch == 10 || ch == 11 || ch == 12 || ch == 13 || ch == 32 || ch == 160 || ch == 5760): return 1
	if (ch >= 8192 && ch <= 8202): return 1
	return ch == 8232 || ch == 8233 || ch == 8239 || ch == 8287 || ch == 12288 || ch == 65279


int js_regexp_word_char(js_regexp_vm* vm, int ch):
	if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_'): return 1
	# With u and i, characters that canonicalize into the basic set count too.
	return vm.unicode && vm.ignore && (ch == 383 || ch == 8490)


int js_regexp_set_item(js_regexp_vm* vm, int item, int ch):
	if (item == 'd'): return ch >= '0' && ch <= '9'
	if (item == 'D'): return (ch >= '0' && ch <= '9') == 0
	if (item == 's'): return js_regexp_space(ch)
	if (item == 'S'): return js_regexp_space(ch) == 0
	if (item == 'w'): return js_regexp_word_char(vm, ch)
	if (item == 'W'): return js_regexp_word_char(vm, ch) == 0
	int negated = (item & JS_RX_NEGATED) != 0
	int code = item - JS_RX_RUNTIME_PROPERTY
	if (negated): code = code - JS_RX_NEGATED
	int has = js_regexp_property_has(code / 4096, code % 4096, ch)
	return has != negated


int js_regexp_class_raw(js_regexp_vm* vm, js_regexp_node* node, int ch):
	for i in range(node.ranges.length / 2):
		if (ch >= node.ranges[i * 2] && ch <= node.ranges[i * 2 + 1]): return 1
	for int item in node.sets:
		if (js_regexp_set_item(vm, item, ch)): return 1
	return 0


# CharacterSetMatcher: some member a has Canonicalize(a) == Canonicalize(ch).
int js_regexp_class_match(js_regexp_vm* vm, js_regexp_node* node, int ch):
	int found = 0
	if (vm.ignore == 0): found = js_regexp_class_raw(vm, node, ch)
	else:
		int canonical = js_regexp_canonicalize(ch, vm.unicode)
		list[int] candidates = new list[int]
		candidates.push(canonical)
		if (vm.unicode): js_regexp_case_preimages(js_regexp_fold_data(), js_regexp_fold_count(), canonical, candidates)
		else: js_regexp_case_preimages(js_regexp_upper_data(), js_regexp_upper_count(), canonical, candidates)
		for int candidate in candidates:
			if (found == 0 && js_regexp_canonicalize(candidate, vm.unicode) == canonical && js_regexp_class_raw(vm, node, candidate)): found = 1
		__w_list_free(cast(__w_list*, candidates))
	return found != node.negate


# Character at pos in direction dir (code point with u). Returns -1 at the
# input boundary and stores the width in units.
int js_regexp_read(js_regexp_vm* vm, int pos, int dir, int* width):
	int length = vm.input.length
	*width = 1
	if (dir > 0):
		if (pos >= length): return -1
		int ch = vm.input[pos]
		if (vm.unicode && js_regexp_lead(ch) && pos + 1 < length && js_regexp_trail(vm.input[pos + 1])):
			*width = 2
			return 65536 + ((ch - 55296) << 10) + (vm.input[pos + 1] - 56320)
		return ch
	if (pos <= 0): return -1
	int ch = vm.input[pos - 1]
	if (vm.unicode && js_regexp_trail(ch) && pos >= 2 && js_regexp_lead(vm.input[pos - 2])):
		*width = 2
		return 65536 + ((vm.input[pos - 2] - 55296) << 10) + (ch - 56320)
	return ch


int js_regexp_backref(js_regexp_vm* vm, int index, int pos, int dir):
	int start = vm.caps[index * 2]
	int end = vm.caps[index * 2 + 1]
	if (start < 0 || end < 0): return pos
	int length = end - start
	int from = pos
	if (dir < 0): from = pos - length
	if (from < 0 || from + length > vm.input.length): return -1
	int i = 0
	while (i < length):
		int width = 1
		int left = js_regexp_read(vm, start + i, 1, &width)
		int other = 1
		int right = js_regexp_read(vm, from + i, 1, &other)
		if (vm.ignore):
			left = js_regexp_canonicalize(left, vm.unicode)
			right = js_regexp_canonicalize(right, vm.unicode)
		if (left != right || width != other): return -1
		i = i + width
	if (dir < 0): return from
	return from + length


void js_regexp_push(list[int] stack, int kind, int a, int b):
	stack.push(kind)
	stack.push(a)
	stack.push(b)


int js_regexp_run(js_regexp_vm* vm, int pc, int pos);


# Lookaround: the body runs in its own backtracking scope (it is atomic).
# Positive assertions keep their captures; the outer stack can undo them.
int js_regexp_look(js_regexp_vm* vm, list[int] stack, int pc, int pos):
	int negate = vm.program.code[pc + 2]
	list[int] saved = new list[int]
	for int value in vm.caps: saved.push(value)
	int result = js_regexp_run(vm, pc + 4, pos)
	int ok = (result >= 0) != negate
	if (vm.aborted): ok = 0
	for i in range(saved.length):
		if (negate || ok == 0): vm.caps[i] = saved[i]
		else if (vm.caps[i] != saved[i]): js_regexp_push(stack, 1, i, saved[i])
	__w_list_free(cast(__w_list*, saved))
	return ok


# Backtracking VM. Returns the end position or -1. Stack records are
# (0, pc, pos) branches, (1, slot, old) capture and (2, reg, old) register
# restores. Every instruction charges one interpreter step.
int js_regexp_run(js_regexp_vm* vm, int pc, int pos):
	list[int] code = vm.program.code
	js_runtime* rt = vm.rt
	list[int] stack = new list[int]
	int result = -1
	while (1):
		int fail = 0
		if (rt.remaining <= 0 || stack.length > JS_RX_MAX_STACK):
			js_runtime_fail(rt, 5, c"JavaScript execution limit")
			vm.aborted = 1
			break
		rt.remaining = rt.remaining - 1
		rt.completion.steps = rt.completion.steps + 1
		int op = code[pc]
		if (op == JS_RX_OP_MATCH || op == JS_RX_OP_LOOK_END):
			result = pos
			break
		if (op == JS_RX_OP_CHAR || op == JS_RX_OP_ANY || op == JS_RX_OP_CLASS):
			int dir = code[pc + 2]
			if (op == JS_RX_OP_ANY): dir = code[pc + 1]
			int width = 1
			int ch = js_regexp_read(vm, pos, dir, &width)
			if (ch < 0): fail = 1
			else if (op == JS_RX_OP_CHAR):
				if (vm.ignore): ch = js_regexp_canonicalize(ch, vm.unicode)
				fail = ch != code[pc + 1]
			else if (op == JS_RX_OP_ANY): fail = vm.dot_all == 0 && js_regexp_line_terminator(ch)
			else: fail = js_regexp_class_match(vm, vm.program.classes[code[pc + 1]], ch) == 0
			if (fail == 0):
				pos = pos + width * dir
				pc = pc + 3
				if (op == JS_RX_OP_ANY): pc = pc - 1
		else if (op == JS_RX_OP_BOL):
			fail = pos != 0 && (vm.multiline == 0 || js_regexp_line_terminator(vm.input[pos - 1]) == 0)
			pc = pc + 1
		else if (op == JS_RX_OP_EOL):
			fail = pos != vm.input.length && (vm.multiline == 0 || js_regexp_line_terminator(vm.input[pos]) == 0)
			pc = pc + 1
		else if (op == JS_RX_OP_WORD):
			int before = pos > 0 && js_regexp_word_char(vm, vm.input[pos - 1])
			int after = pos < vm.input.length && js_regexp_word_char(vm, vm.input[pos])
			fail = (before != after) == code[pc + 1]
			pc = pc + 2
		else if (op == JS_RX_OP_SAVE):
			int slot = code[pc + 1]
			js_regexp_push(stack, 1, slot, vm.caps[slot])
			vm.caps[slot] = pos
			pc = pc + 2
		else if (op == JS_RX_OP_SPLIT):
			js_regexp_push(stack, 0, code[pc + 2], pos)
			pc = code[pc + 1]
		else if (op == JS_RX_OP_JMP): pc = code[pc + 1]
		else if (op == JS_RX_OP_BACKREF):
			int next = js_regexp_backref(vm, code[pc + 1], pos, code[pc + 2])
			if (next < 0): fail = 1
			else:
				pos = next
				pc = pc + 3
		else if (op == JS_RX_OP_LOOK):
			if (js_regexp_look(vm, stack, pc, pos)): pc = code[pc + 3]
			else: fail = 1
			if (vm.aborted): break
		else if (op == JS_RX_OP_RESET):
			for slot in range(code[pc + 1], code[pc + 2] + 1):
				if (vm.caps[slot] >= 0):
					js_regexp_push(stack, 1, slot, vm.caps[slot])
					vm.caps[slot] = -1
			pc = pc + 3
		else if (op == JS_RX_OP_MARK):
			int reg = code[pc + 1]
			js_regexp_push(stack, 2, reg, vm.regs[reg])
			vm.regs[reg] = pos
			pc = pc + 2
		else if (op == JS_RX_OP_CHECK):
			fail = vm.regs[code[pc + 1]] == pos
			pc = pc + 2
		if (fail == 0): continue
		int resumed = 0
		while (stack.length > 0):
			int b = stack.pop()
			int a = stack.pop()
			int kind = stack.pop()
			if (kind == 1): vm.caps[a] = b
			else if (kind == 2): vm.regs[a] = b
			else:
				pc = a
				pos = b
				resumed = 1
				break
		if (resumed == 0): break
	__w_list_free(cast(__w_list*, stack))
	return result


# Match at index; fills vm.caps. Returns the end index or -1.
int js_regexp_match_at(js_regexp_vm* vm, int index):
	for i in range(vm.caps.length): vm.caps[i] = -1
	for i in range(vm.regs.length): vm.regs[i] = -1
	return js_regexp_run(vm, 0, index)


js_regexp_vm* js_regexp_vm_new(js_runtime* rt, js_regexp_program* program, list[int] input):
	js_regexp_vm* vm = new js_regexp_vm()
	vm.program = program
	vm.rt = rt
	vm.input = input
	vm.caps = new list[int]
	for i in range((program.rx.captures + 1) * 2): vm.caps.push(-1)
	vm.regs = new list[int]
	for i in range(program.registers): vm.regs.push(-1)
	vm.unicode = (program.flags & JS_RX_UNICODE) != 0
	vm.ignore = (program.flags & JS_RX_IGNORE_CASE) != 0
	vm.multiline = (program.flags & JS_RX_MULTILINE) != 0
	vm.dot_all = (program.flags & JS_RX_DOT_ALL) != 0
	vm.aborted = 0
	return vm


void js_regexp_vm_free(js_regexp_vm* vm):
	__w_list_free(cast(__w_list*, vm.caps))
	__w_list_free(cast(__w_list*, vm.regs))
	free(vm)


js_value* js_regexp_text_value(js_runtime* rt, list[int] units, int start, int end):
	js_text* text = js_text_new()
	for i in range(start, end): text.units.push(units[i])
	js_value* value = js_runtime_string(rt, text)
	js_text_free(text)
	return value


js_value* js_regexp_new_object(js_runtime* rt, js_regexp_program* program):
	if (program.error != 0):
		js_regexp_program_free(program)
		js_runtime_fail(rt, 2, c"invalid regular expression")
		return rt.undefined_value
	js_value* object = js_runtime_alloc(rt, 5)
	if (object == rt.undefined_value):
		js_regexp_program_free(program)
		return object
	object.regexp = program
	object.prototype = rt.regexp_prototype
	js_text* key = js_runtime_key(c"lastIndex")
	js_runtime_define_data(rt, object, key, js_runtime_number(rt, 0.0), 1, 0, 0)
	js_text_free(key)
	return object


# A regular expression literal creates a fresh object on every evaluation.
js_value* js_regexp_literal_value(js_runtime* rt, char* text):
	return js_regexp_new_object(rt, js_regexp_program_literal(text))


js_regexp_program* js_regexp_receiver(js_runtime* rt, js_value* receiver):
	if (receiver == 0 || receiver.regexp == 0):
		js_runtime_fail(rt, 2, c"RegExp method requires a RegExp receiver")
		return 0
	return cast(js_regexp_program*, receiver.regexp)


int js_regexp_last_index(js_runtime* rt, js_value* object):
	js_value* value = js_runtime_get(rt, object, c"lastIndex")
	if (rt.completion.status != 0): return 0
	if (value.kind != 3 && value.kind != 0):
		js_runtime_fail(rt, 6, c"lastIndex conversion outside the runtime subset")
		return 0
	if (value.kind == 0 || f64is_nan(value.number) || value.number <= 0.0): return 0
	if (value.number >= 2147483647.0): return 2147483647
	return cast(int, value.number)


void js_regexp_set_last_index(js_runtime* rt, js_value* object, int index):
	js_text* key = js_runtime_key(c"lastIndex")
	js_value* property = js_runtime_property(object, key)
	if (property != 0 && property.writable == 0): js_runtime_fail(rt, 2, c"assignment to read-only lastIndex")
	else: js_runtime_member_write(rt, object, key, js_runtime_number(rt, cast(float64, index)))
	js_text_free(key)


js_text* js_regexp_argument_text(js_runtime* rt, list[js_value*] args):
	if (args.length == 0): return js_runtime_key(c"undefined")
	return js_runtime_primitive_text(rt, args[0])


# RegExpBuiltinExec. Returns the match array or null.
js_value* js_regexp_exec(js_runtime* rt, js_value* object, js_text* input):
	js_regexp_program* program = js_regexp_receiver(rt, object)
	if (program == 0): return rt.undefined_value
	int flags = program.flags
	int global_or_sticky = (flags & (JS_RX_GLOBAL | JS_RX_STICKY)) != 0
	int index = js_regexp_last_index(rt, object)
	if (rt.completion.status != 0): return rt.undefined_value
	if (global_or_sticky == 0): index = 0
	js_regexp_vm* vm = js_regexp_vm_new(rt, program, input.units)
	# With u, a lastIndex inside a surrogate pair starts at the pair (as V8).
	list[int] units = input.units
	if (vm.unicode && index > 0 && index < units.length && js_regexp_lead(units[index - 1]) && js_regexp_trail(units[index])): index = index - 1
	int end = -1
	while (index <= input.units.length):
		end = js_regexp_match_at(vm, index)
		if (end >= 0 || vm.aborted || (flags & JS_RX_STICKY)): break
		int width = 1
		if (vm.unicode): js_regexp_read(vm, index, 1, &width)
		index = index + width
	js_value* result = rt.undefined_value
	if (vm.aborted == 0):
		if (end < 0):
			if (global_or_sticky): js_regexp_set_last_index(rt, object, 0)
			result = js_runtime_alloc(rt, 1)
		else:
			if (global_or_sticky): js_regexp_set_last_index(rt, object, end)
			result = js_regexp_match_array(rt, vm, input)
	js_regexp_vm_free(vm)
	return result


js_value* js_regexp_match_array(js_runtime* rt, js_regexp_vm* vm, js_text* input):
	js_regexp_program* program = vm.program
	js_value* array = js_runtime_alloc(rt, 6)
	if (array == rt.undefined_value): return array
	for i in range(program.rx.captures + 1):
		int start = vm.caps[i * 2]
		int stop = vm.caps[i * 2 + 1]
		js_value* item = rt.undefined_value
		if (start >= 0 && stop >= 0): item = js_regexp_text_value(rt, input.units, start, stop)
		js_runtime_array_append(rt, array, item)
	js_runtime_set(rt, array, c"index", js_runtime_number(rt, cast(float64, vm.caps[0])))
	js_runtime_set(rt, array, c"input", js_runtime_string(rt, input))
	js_value* groups = rt.undefined_value
	for i in range(program.rx.names.length):
		char* name = program.rx.names[i]
		if (name == 0): continue
		if (groups == rt.undefined_value): groups = js_runtime_alloc(rt, 5)
		int start = vm.caps[(i + 1) * 2]
		int stop = vm.caps[(i + 1) * 2 + 1]
		js_value* item = rt.undefined_value
		if (start >= 0 && stop >= 0): item = js_regexp_text_value(rt, input.units, start, stop)
		js_runtime_set(rt, groups, name, item)
	js_runtime_set(rt, array, c"groups", groups)
	return array


# Methods: 1 exec, 2 test, 3 toString.
js_value* js_regexp_method(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	int operation = cast(int, context)
	js_regexp_program* program = js_regexp_receiver(rt, receiver)
	if (program == 0): return rt.undefined_value
	if (operation == 3):
		js_text* text = js_runtime_key(c"/")
		js_text* source = js_regexp_escaped_source(program)
		for int unit in source.units: text.units.push(unit)
		js_text_free(source)
		text.units.push('/')
		js_regexp_append_flags(text, program.flags)
		js_value* value = js_runtime_string(rt, text)
		js_text_free(text)
		return value
	js_text* input = js_regexp_argument_text(rt, args)
	if (input == 0): return rt.undefined_value
	js_value* result = js_regexp_exec(rt, receiver, input)
	js_text_free(input)
	if (operation == 2 && rt.completion.status == 0): return js_runtime_boolean(rt, result.kind == 6)
	return result


void js_regexp_append_flags(js_text* text, int flags):
	if (flags & JS_RX_GLOBAL): text.units.push('g')
	if (flags & JS_RX_IGNORE_CASE): text.units.push('i')
	if (flags & JS_RX_MULTILINE): text.units.push('m')
	if (flags & JS_RX_DOT_ALL): text.units.push('s')
	if (flags & JS_RX_UNICODE): text.units.push('u')
	if (flags & JS_RX_STICKY): text.units.push('y')


# EscapePatternForRegExp: "/" and line terminators are escaped so the source
# re-parses as a literal; an empty pattern is "(?:)".
js_text* js_regexp_escaped_source(js_regexp_program* program):
	js_text* out = js_text_new()
	list[int] units = program.source.units
	if (units.length == 0):
		char* empty = c"(?:)"
		for i in range(4): out.units.push(empty[i])
		return out
	int in_class = 0
	int i = 0
	while (i < units.length):
		int ch = units[i]
		if (ch == 92 && i + 1 < units.length):
			out.units.push(ch)
			i = i + 1
			ch = units[i]
			if (js_regexp_line_terminator(ch) == 0):
				out.units.push(ch)
				i = i + 1
				continue
			out.units.pop()
		if (ch == '['): in_class = 1
		if (ch == ']'): in_class = 0
		if (ch == '/' && in_class == 0): out.units.push(92)
		if (ch == 10 || ch == 13 || ch == 8232 || ch == 8233):
			out.units.push(92)
			if (ch == 10): out.units.push('n')
			else if (ch == 13): out.units.push('r')
			else:
				out.units.push('u')
				out.units.push('2')
				out.units.push('0')
				out.units.push('2')
				out.units.push('8' + ch - 8232)
		else: out.units.push(ch)
		i = i + 1
	return out


# Accessors on RegExp.prototype: 1 source, 2 flags, 3 global, 4 ignoreCase,
# 5 multiline, 6 dotAll, 7 unicode, 8 sticky.
js_value* js_regexp_accessor(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	int operation = cast(int, context)
	if (receiver == rt.regexp_prototype):
		if (operation == 1):
			js_text* empty = js_runtime_key(c"(?:)")
			js_value* value = js_runtime_string(rt, empty)
			js_text_free(empty)
			return value
		if (operation == 2): return js_regexp_string(rt, c"")
		return rt.undefined_value
	js_regexp_program* program = js_regexp_receiver(rt, receiver)
	if (program == 0): return rt.undefined_value
	if (operation == 1):
		js_text* source = js_regexp_escaped_source(program)
		js_value* value = js_runtime_string(rt, source)
		js_text_free(source)
		return value
	if (operation == 2):
		js_text* flags = js_text_new()
		js_regexp_append_flags(flags, program.flags)
		js_value* value = js_runtime_string(rt, flags)
		js_text_free(flags)
		return value
	int bit = 1 << (operation - 3)
	if (operation == 4): bit = JS_RX_IGNORE_CASE
	if (operation == 5): bit = JS_RX_MULTILINE
	if (operation == 6): bit = JS_RX_DOT_ALL
	if (operation == 7): bit = JS_RX_UNICODE
	if (operation == 8): bit = JS_RX_STICKY
	return js_runtime_boolean(rt, (program.flags & bit) != 0)


js_value* js_regexp_string(js_runtime* rt, char* raw):
	js_text* text = js_runtime_key(raw)
	js_value* value = js_runtime_string(rt, text)
	js_text_free(text)
	return value


# Flags string to bits, or -1 for an unknown or repeated flag.
int js_regexp_parse_flags(js_text* text):
	int flags = 0
	for int ch in text.units:
		int bit = 0
		if (ch == 'g'): bit = JS_RX_GLOBAL
		if (ch == 'i'): bit = JS_RX_IGNORE_CASE
		if (ch == 'm'): bit = JS_RX_MULTILINE
		if (ch == 's'): bit = JS_RX_DOT_ALL
		if (ch == 'u'): bit = JS_RX_UNICODE
		if (ch == 'y'): bit = JS_RX_STICKY
		if (bit == 0 || (flags & bit)): return -1
		flags = flags | bit
	return flags


# RegExp(pattern, flags) and new RegExp(pattern, flags). Pattern and flags
# must be strings, undefined, or (for pattern) a RegExp; other coercions are
# outside the runtime subset. Syntax errors throw SyntaxError.
js_value* js_regexp_constructor(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_text* source = 0
	int flags = 0
	js_value* pattern = rt.undefined_value
	if (args.length > 0): pattern = args[0]
	if (pattern.regexp != 0):
		js_regexp_program* other = cast(js_regexp_program*, pattern.regexp)
		source = js_text_clone(other.source)
		flags = other.flags
	else if (pattern.kind == 0): source = js_text_new()
	else if (pattern.kind == 4): source = js_text_clone(pattern.text)
	else:
		js_runtime_fail(rt, 6, c"RegExp pattern conversion outside the runtime subset")
		return rt.undefined_value
	if (args.length > 1 && args[1].kind != 0):
		if (args[1].kind != 4):
			js_text_free(source)
			js_runtime_fail(rt, 6, c"RegExp flags conversion outside the runtime subset")
			return rt.undefined_value
		flags = js_regexp_parse_flags(args[1].text)
		if (flags < 0):
			js_text_free(source)
			js_runtime_fail(rt, 2, c"invalid regular expression flags")
			return rt.undefined_value
	js_regexp_program* program = js_regexp_program_new(source, flags)
	js_text_free(source)
	if (program.error != 0):
		char* message = program.error
		js_regexp_program_free(program)
		if (js_runtime_prefix(message, c"invalid regular expression")): js_runtime_fail(rt, 2, message)
		else: js_runtime_fail(rt, 6, message)
		return rt.undefined_value
	return js_regexp_new_object(rt, program)


void js_regexp_define_accessor(js_runtime* rt, char* name, int operation):
	js_value* getter = js_runtime_host_callable(rt, cast(void*, operation), js_regexp_accessor)
	js_text* key = js_runtime_key(name)
	js_runtime_define_accessor(rt, rt.regexp_prototype, key, getter, 0, 0, 1)
	js_text_free(key)


void js_runtime_install_regexp(js_runtime* rt):
	rt.regexp_prototype = js_runtime_alloc(rt, 5)
	if (rt.regexp_prototype == rt.undefined_value): return
	js_runtime_collection_method(rt, rt.regexp_prototype, c"exec", 1, js_regexp_method)
	js_runtime_collection_method(rt, rt.regexp_prototype, c"test", 2, js_regexp_method)
	js_runtime_collection_method(rt, rt.regexp_prototype, c"toString", 3, js_regexp_method)
	js_regexp_define_accessor(rt, c"source", 1)
	js_regexp_define_accessor(rt, c"flags", 2)
	js_regexp_define_accessor(rt, c"global", 3)
	js_regexp_define_accessor(rt, c"ignoreCase", 4)
	js_regexp_define_accessor(rt, c"multiline", 5)
	js_regexp_define_accessor(rt, c"dotAll", 6)
	js_regexp_define_accessor(rt, c"unicode", 7)
	js_regexp_define_accessor(rt, c"sticky", 8)
	js_value* constructor = js_runtime_host_callable(rt, 0, js_regexp_constructor)
	if (constructor == rt.undefined_value): return
	constructor.host_construct = 1
	js_text* key = js_runtime_key(c"prototype")
	js_runtime_define_data(rt, constructor, key, rt.regexp_prototype, 0, 0, 0)
	js_text_free(key)
	key = js_runtime_key(c"constructor")
	js_runtime_define_data(rt, rt.regexp_prototype, key, constructor, 1, 0, 1)
	js_text_free(key)
	js_runtime_set(rt, rt.global, c"RegExp", constructor)
