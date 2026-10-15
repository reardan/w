# Bounded single-instance WebAssembly interpreter (64-bit hosts).
# Values carry raw bits. Host imports share the caller's fuel and depth limits.
# Unsupported proposals fail validation; no native code is generated.
import lib.fmath
import lib.mem

struct wwasm_type:
	list[int] params
	int result

struct wwasm_op:
	int code
	int a
	int b
	int end
	int alternative
	list[int] labels

struct wwasm_function:
	int signature
	char* module_name
	char* name
	list[int] locals
	list[wwasm_op*] ops
	void* context
	int callback

struct wwasm_export:
	char* name
	int kind
	int index

struct wwasm_global:
	int kind
	int mutable
	int bits

struct wwasm:
	char* bytes
	int length
	int pos
	int end
	char* error
	list[wwasm_type*] types
	list[wwasm_function*] functions
	list[wwasm_export*] exports
	map[char*, int] export_names
	list[wwasm_global*] globals
	list[int] table
	char* memory
	int pages
	int max_pages
	int has_memory
	int has_table
	int max_table
	int imports
	int start
	int fuel
	int depth
	int max_depth
	int stack_limit
	int valid
	int op_count
	int grow_hook
	void* grow_context

# Callback returns result bits; set instance.error to trap.
type wwasm_memory_changed = fn(void*, wwasm*, int) -> int

type wwasm_host = fn(void*, wwasm*, list[int]) -> int

void wwasm_fail(wwasm* m, char* message):
	if (m.error == 0): m.error = message

int wwasm_byte(wwasm* m):
	if (m.pos >= m.end):
		wwasm_fail(m, c"truncated WebAssembly")
		return 0
	int v = m.bytes[m.pos] & 255
	m.pos = m.pos + 1
	return v

int wwasm_leb(wwasm* m, int signed_value):
	int result = 0
	int shift = 0
	int v = 0
	for i in range(5):
		v = wwasm_byte(m)
		result = result | ((v & 127) << shift)
		shift = shift + 7
		if ((v & 128) == 0):
			if (i == 4):
				if ((!signed_value && (v & 112) != 0) || (signed_value && (v & 120) != 0 && (v & 120) != 120)): wwasm_fail(m, c"integer representation too large")
			if (signed_value && (v & 64)): result = result | (-1 << shift)
			return result
	wwasm_fail(m, c"integer representation too long")
	return 0

int wwasm_leb64(wwasm* m):
	int result = 0
	for i in range(10):
		int v = wwasm_byte(m)
		if (i == 9 && v != 0 && v != 127): wwasm_fail(m, c"invalid i64 integer")
		result = result | ((v & 127) << (i * 7))
		if ((v & 128) == 0):
			if (i < 9 && (v & 64)): result = result | (-1 << ((i + 1) * 7))
			return result
	wwasm_fail(m, c"integer representation too long")
	return 0

int wwasm_count(wwasm* m):
	int n = wwasm_leb(m, 0)
	if (n > 65536 || n > m.end - m.pos):
		wwasm_fail(m, c"WebAssembly vector limit")
		return 0
	return n

char* wwasm_name(wwasm* m):
	int n = wwasm_count(m)
	if (n > m.end - m.pos):
		wwasm_fail(m, c"truncated name")
		return strclone(c"")
	char* result = cast(char*, malloc(n + 1))
	for i in range(n):
		int v = wwasm_byte(m)
		if (v == 0 || v >= 128): wwasm_fail(m, c"only ASCII export/import names supported")
		result[i] = v
	result[n] = 0
	return result

int wwasm_kind(wwasm* m):
	int k = wwasm_byte(m)
	if (k != 127 && k != 126 && k != 125): wwasm_fail(m, c"unsupported value type")
	return k

int wwasm_i32(int bits):
	return (bits << 32) >> 32

int wwasm_u32(int bits):
	return bits & ((1 << 32) - 1)

int wwasm_init_expr(wwasm* m, int kind):
	int op = wwasm_byte(m)
	int result = 0
	if (op == 65 && kind == 127): result = wwasm_i32(wwasm_leb(m, 1))
	else if (op == 66 && kind == 126): result = wwasm_leb64(m)
	else if (op == 67 && kind == 125):
		for i in range(4): result = result | (wwasm_byte(m) << (i * 8))
	else: wwasm_fail(m, c"unsupported initializer")
	if (wwasm_byte(m) != 11): wwasm_fail(m, c"invalid initializer")
	return result

void wwasm_limits(wwasm* m, int memory):
	int flags = wwasm_byte(m)
	int initial = wwasm_leb(m, 0)
	int maximum = 256
	if (!memory): maximum = 65536
	if (flags == 1): maximum = wwasm_leb(m, 0)
	else if (flags != 0): wwasm_fail(m, c"unsupported limits")
	if ((memory && maximum > 65536) || initial > maximum || (memory && initial > 256) || (!memory && initial > 65536)):
		wwasm_fail(m, c"WebAssembly allocation limit")
		return
	if (memory):
		m.has_memory = 1
		m.pages = initial
		m.max_pages = maximum
		if (m.max_pages > 256): m.max_pages = 256
		m.memory = cast(char*, malloc(initial * 65536 + 1))
		for i in range(initial * 65536 + 1): m.memory[i] = 0
	else:
		m.has_table = 1
		m.max_table = maximum
		if (m.max_table > 65536): m.max_table = 65536
		for i in range(initial): m.table.push(-1)

wwasm_function* wwasm_new_function(wwasm* m):
	wwasm_function* f = new wwasm_function()
	f.signature = wwasm_leb(m, 0)
	if (f.signature >= m.types.length): wwasm_fail(m, c"unknown function type")
	f.locals = new list[int]
	f.ops = new list[wwasm_op*]
	m.functions.push(f)
	return f

# Decode once, recording structured-control destinations. Validation below
# checks operand types even in unreachable code and validates branch depths.
void wwasm_decode(wwasm* m, wwasm_function* f):
	int groups = wwasm_count(m)
	for g in range(groups):
		if (m.error != 0): break
		int count = wwasm_leb(m, 0)
		int kind = wwasm_kind(m)
		if (count > 4096 - f.locals.length):
			wwasm_fail(m, c"local limit")
			return
		for j in range(count): f.locals.push(kind)
	list[int] blocks = new list[int]
	int root_ended = 0
	while (m.pos < m.end && m.error == 0):
		m.op_count = m.op_count + 1
		if (m.op_count > 524288):
			wwasm_fail(m, c"decoded instruction limit")
			break
		wwasm_op* op = new wwasm_op()
		op.code = wwasm_byte(m)
		op.alternative = -1
		op.end = -1
		int pc = f.ops.length
		f.ops.push(op)
		int c = op.code
		if (c >= 2 && c <= 4):
			op.a = wwasm_byte(m)
			if (op.a != 64 && op.a != 127 && op.a != 126 && op.a != 125): wwasm_fail(m, c"unsupported block type")
			if (blocks.length >= 512): wwasm_fail(m, c"control nesting limit")
			blocks.push(pc)
		else if (c == 5):
			if (blocks.length == 0): wwasm_fail(m, c"unexpected else")
			else:
				wwasm_op* begin = f.ops[blocks[blocks.length - 1]]
				if (begin.code != 4 || begin.alternative != -1): wwasm_fail(m, c"unexpected else")
				begin.alternative = pc
		else if (c == 11):
			if (blocks.length == 0):
				root_ended = 1
				break
			int begin_pc = blocks.pop()
			wwasm_op* begin = f.ops[begin_pc]
			begin.end = pc
			if (begin.alternative >= 0): f.ops[begin.alternative].end = pc
		else if (c == 14):
			int count = wwasm_count(m)
			op.labels = new list[int]
			for j in range(count + 1): op.labels.push(wwasm_leb(m, 0))
		else if (c == 12 || c == 13 || c == 16 || (c >= 32 && c <= 36)): op.a = wwasm_leb(m, 0)
		else if (c == 17):
			op.a = wwasm_leb(m, 0)
			op.b = wwasm_leb(m, 0)
		else if (c >= 40 && c <= 62):
			op.a = wwasm_leb(m, 0)
			op.b = wwasm_leb(m, 0)
		else if (c == 63 || c == 64): op.a = wwasm_leb(m, 0)
		else if (c == 65): op.a = wwasm_i32(wwasm_leb(m, 1))
		else if (c == 66): op.a = wwasm_leb64(m)
		else if (c == 67):
			for j in range(4): op.a = op.a | (wwasm_byte(m) << (j * 8))
		else if (c == 252):
			op.a = wwasm_leb(m, 0)
			if (op.a != 0): wwasm_fail(m, c"unsupported extended opcode")
		else if (!(c == 0 || c == 1 || c == 15 || c == 26 || c == 27 || (c >= 69 && c <= 79) || (c >= 91 && c <= 96) || (c >= 103 && c <= 120) || c == 124 || c == 126 || c == 128 || c == 130 || c == 136 || (c >= 146 && c <= 149) || c == 167 || c == 172 || c == 173 || c == 178 || c == 188 || c == 190)):
			wwasm_fail(m, c"unsupported WebAssembly opcode")
	if (!root_ended || blocks.length != 0 || f.ops.length == 0): wwasm_fail(m, c"unterminated function")
	else if (f.ops[f.ops.length - 1].code != 11): wwasm_fail(m, c"unterminated function")
	__w_list_free(cast(__w_list*, blocks))

struct wwasm_control:
	int pc
	int height
	int result
	int unreachable
	int loop
	int had_else

int wwasm_pop_type(wwasm* m, list[int] stack, wwasm_control* control, int expected):
	if (stack.length == control.height && control.unreachable): return expected
	if (stack.length <= control.height):
		wwasm_fail(m, c"operand stack underflow")
		return expected
	int actual = stack.pop()
	if (expected != 0 && actual != 0 && expected != actual): wwasm_fail(m, c"operand type mismatch")
	return actual

void wwasm_unreachable(list[int] stack, wwasm_control* control):
	while (stack.length > control.height): stack.pop()
	control.unreachable = 1

int wwasm_branch_type(wwasm* m, list[wwasm_control*] controls, int depth):
	if (depth >= controls.length):
		wwasm_fail(m, c"unknown branch label")
		return 0
	wwasm_control* target = controls[controls.length - depth - 1]
	if (target.loop): return 0
	return target.result

void wwasm_validate_function(wwasm* m, wwasm_function* f):
	wwasm_type* type = m.types[f.signature]
	list[int] stack = new list[int]
	list[wwasm_control*] controls = new list[wwasm_control*]
	wwasm_control* root = new wwasm_control()
	root.result = type.result
	root.pc = -1
	controls.push(root)
	for pc in range(f.ops.length):
		if (m.error != 0): break
		wwasm_op* op = f.ops[pc]
		int c = op.code
		wwasm_control* control = controls[controls.length - 1]
		if (c == 0): wwasm_unreachable(stack, control)
		else if (c >= 2 && c <= 4):
			if (c == 4): wwasm_pop_type(m, stack, control, 127)
			wwasm_control* next = new wwasm_control()
			next.pc = pc
			next.height = stack.length
			if (op.a != 64): next.result = op.a
			next.loop = c == 3
			controls.push(next)
		else if (c == 5 || c == 11):
			if (control.result): wwasm_pop_type(m, stack, control, control.result)
			if (stack.length != control.height): wwasm_fail(m, c"unbalanced block stack")
			if (c == 5):
				control.unreachable = 0
				control.had_else = 1
			else:
				if (control.pc >= 0 && f.ops[control.pc].code == 4 && !control.had_else && control.result): wwasm_fail(m, c"result if requires else")
				if (control.result): stack.push(control.result)
				controls.pop()
				free(control)
				if (controls.length == 0):
					if (pc != f.ops.length - 1): wwasm_fail(m, c"trailing instructions")
					break
		else if (c == 12 || c == 13 || c == 14 || c == 15):
			if (c == 13 || c == 14): wwasm_pop_type(m, stack, control, 127)
			int kind = 0
			if (c == 15): kind = type.result
			else if (c == 14):
				kind = wwasm_branch_type(m, controls, op.labels[0])
				for int label in op.labels:
					if (wwasm_branch_type(m, controls, label) != kind): wwasm_fail(m, c"branch table type mismatch")
			else: kind = wwasm_branch_type(m, controls, op.a)
			if (kind): wwasm_pop_type(m, stack, control, kind)
			if (c == 13):
				if (kind): stack.push(kind)
			else: wwasm_unreachable(stack, control)
		else if (c == 16 || c == 17):
			wwasm_type* called = 0
			if (c == 16):
				if (op.a >= m.functions.length): wwasm_fail(m, c"unknown function")
				else: called = m.types[m.functions[op.a].signature]
			else:
				if (op.a >= m.types.length || !m.has_table || op.b != 0): wwasm_fail(m, c"invalid indirect call")
				else: called = m.types[op.a]
				wwasm_pop_type(m, stack, control, 127)
			if (called != 0):
				int i = called.params.length
				while (i > 0):
					i = i - 1
					wwasm_pop_type(m, stack, control, called.params[i])
				if (called.result): stack.push(called.result)
		else if (c == 26): wwasm_pop_type(m, stack, control, 0)
		else if (c == 27):
			wwasm_pop_type(m, stack, control, 127)
			int kind = wwasm_pop_type(m, stack, control, 0)
			int other = wwasm_pop_type(m, stack, control, kind)
			if (kind == 0): kind = other
			stack.push(kind)
		else if (c >= 32 && c <= 36):
			int kind = 0
			if (c <= 34):
				if (op.a < type.params.length): kind = type.params[op.a]
				else if (op.a - type.params.length < f.locals.length): kind = f.locals[op.a - type.params.length]
				else: wwasm_fail(m, c"unknown local")
			else:
				if (op.a >= m.globals.length): wwasm_fail(m, c"unknown global")
				else:
					kind = m.globals[op.a].kind
					if (c == 36 && !m.globals[op.a].mutable): wwasm_fail(m, c"immutable global")
			if (c == 32 || c == 35): stack.push(kind)
			else:
				wwasm_pop_type(m, stack, control, kind)
				if (c == 34): stack.push(kind)
		else if (c >= 40 && c <= 62):
			# MVP i32/f32 loads and stores used by W. Reject other widths.
			int width = 4
			if (c == 41): width = 8
			if (c == 44 || c == 45 || c == 58): width = 1
			if (c == 46 || c == 47 || c == 59): width = 2
			if (!(c == 40 || c == 41 || c == 42 || (c >= 44 && c <= 47) || c == 54 || c == 56 || c == 58 || c == 59)): wwasm_fail(m, c"unsupported memory instruction")
			int align = 2
			if (width == 8): align = 3
			if (width == 1): align = 0
			if (width == 2): align = 1
			if (!m.has_memory || op.a > align): wwasm_fail(m, c"invalid memory instruction")
			int kind = 127
			if (c == 42 || c == 56): kind = 125
			if (c == 41): kind = 126
			if (c >= 54): wwasm_pop_type(m, stack, control, kind)
			wwasm_pop_type(m, stack, control, 127)
			if (c < 54): stack.push(kind)
		else if (c == 63 || c == 64):
			if (!m.has_memory || op.a != 0): wwasm_fail(m, c"invalid memory index")
			if (c == 64): wwasm_pop_type(m, stack, control, 127)
			stack.push(127)
		else if (c == 65): stack.push(127)
		else if (c == 66): stack.push(126)
		else if (c == 67): stack.push(125)
		else if (c != 1):
			int input = 127
			int output = 127
			int binary = (c >= 70 && c <= 79) || (c >= 106 && c <= 120)
			if ((c >= 91 && c <= 96) || (c >= 146 && c <= 149)):
				input = 125
				binary = 1
				if (c >= 146): output = 125
			if (c == 124 || c == 126 || c == 128 || c == 130 || c == 136):
				input = 126
				output = 126
				binary = 1
			if (c == 167): input = 126
			if (c == 172 || c == 173): output = 126
			if (c == 178 || c == 190): output = 125
			if (c == 188 || c == 252): input = 125
			wwasm_pop_type(m, stack, control, input)
			if (binary): wwasm_pop_type(m, stack, control, input)
			stack.push(output)
		if (stack.length > m.stack_limit): wwasm_fail(m, c"operand stack limit")
	if (controls.length != 0): wwasm_fail(m, c"unterminated function control")
	for wwasm_control* left in controls: free(left)
	__w_list_free(cast(__w_list*, controls))
	__w_list_free(cast(__w_list*, stack))

wwasm* wwasm_load(char* bytes, int length):
	wwasm* m = new wwasm()
	m.types = new list[wwasm_type*]
	m.functions = new list[wwasm_function*]
	m.exports = new list[wwasm_export*]
	m.export_names = new map[char*, int]
	m.globals = new list[wwasm_global*]
	m.table = new list[int]
	m.start = -1
	m.max_depth = 128
	m.stack_limit = 4096
	if (length < 8 || length > 1048576 || bytes == 0):
		wwasm_fail(m, c"WebAssembly module size limit")
		return m
	m.bytes = cast(char*, malloc(length))
	mem_copy(m.bytes, bytes, length)
	m.length = length
	m.end = length
	if (wwasm_byte(m) != 0 || wwasm_byte(m) != 97 || wwasm_byte(m) != 115 || wwasm_byte(m) != 109 || wwasm_byte(m) != 1 || wwasm_byte(m) != 0 || wwasm_byte(m) != 0 || wwasm_byte(m) != 0): wwasm_fail(m, c"invalid WebAssembly header")
	int last_section = 0
	int code_count = -1
	while (m.pos < length && m.error == 0):
		m.end = length
		int section = wwasm_byte(m)
		int size = wwasm_leb(m, 0)
		if (size > length - m.pos):
			wwasm_fail(m, c"section exceeds module")
			break
		m.end = m.pos + size
		if (section == 0):
			free(wwasm_name(m))
			m.pos = m.end
			continue
		if (section <= last_section || section > 11):
			wwasm_fail(m, c"invalid section order or unsupported section")
			break
		last_section = section
		int count = 1
		if (section != 8): count = wwasm_count(m)
		if (section == 1):
			for i in range(count):
				if (m.error != 0): break
				if (wwasm_byte(m) != 96): wwasm_fail(m, c"invalid function type")
				wwasm_type* t = new wwasm_type()
				t.params = new list[int]
				m.types.push(t)
				int params = wwasm_count(m)
				if (params > 256): wwasm_fail(m, c"parameter limit")
				for j in range(params):
					if (m.error != 0): break
					t.params.push(wwasm_kind(m))
				int results = wwasm_count(m)
				if (results > 1): wwasm_fail(m, c"multi-value unsupported")
				if (results == 1): t.result = wwasm_kind(m)
		else if (section == 2):
			for i in range(count):
				if (m.error != 0): break
				char* module_name = wwasm_name(m)
				char* name = wwasm_name(m)
				if (wwasm_byte(m) != 0):
					free(module_name)
					free(name)
					wwasm_fail(m, c"only function imports supported")
					break
				wwasm_function* f = wwasm_new_function(m)
				f.module_name = module_name
				f.name = name
				m.imports = m.imports + 1
		else if (section == 3):
			for i in range(count): wwasm_new_function(m)
		else if (section == 4 || section == 5):
			if (count > 1): wwasm_fail(m, c"multiple tables/memories unsupported")
			if (count == 1):
				if (section == 4 && wwasm_byte(m) != 112): wwasm_fail(m, c"unsupported table type")
				wwasm_limits(m, section == 5)
		else if (section == 6):
			for i in range(count):
				if (m.error != 0): break
				wwasm_global* g = new wwasm_global()
				m.globals.push(g)
				g.kind = wwasm_kind(m)
				g.mutable = wwasm_byte(m)
				if (g.mutable > 1): wwasm_fail(m, c"invalid global mutability")
				g.bits = wwasm_init_expr(m, g.kind)
		else if (section == 7):
			if (count > 4096): wwasm_fail(m, c"export count limit")
			for i in range(count):
				if (m.error != 0): break
				wwasm_export* e = new wwasm_export()
				e.name = wwasm_name(m)
				e.kind = wwasm_byte(m)
				e.index = wwasm_leb(m, 0)
				if (e.name in m.export_names): wwasm_fail(m, c"duplicate export")
				m.export_names[e.name] = 1
				m.exports.push(e)
				if (e.kind > 3 || (e.kind == 0 && e.index >= m.functions.length) || (e.kind == 1 && (!m.has_table || e.index != 0)) || (e.kind == 2 && (!m.has_memory || e.index != 0)) || (e.kind == 3 && e.index >= m.globals.length)): wwasm_fail(m, c"invalid export index")
		else if (section == 8):
			m.start = wwasm_leb(m, 0)
			if (m.start >= m.functions.length): wwasm_fail(m, c"invalid start function")
			else:
				wwasm_type* t = m.types[m.functions[m.start].signature]
				if (t.params.length != 0 || t.result != 0): wwasm_fail(m, c"invalid start signature")
		else if (section == 9 || section == 11):
			for i in range(count):
				if (m.error != 0): break
				if (wwasm_leb(m, 0) != 0): wwasm_fail(m, c"unsupported segment mode")
				int offset = wwasm_u32(wwasm_init_expr(m, 127))
				int n = wwasm_leb(m, 0)
				if (section == 9):
					if (!m.has_table || offset > m.table.length || n > m.table.length - offset):
						wwasm_fail(m, c"element segment out of bounds")
						break
					for j in range(n):
						int index = wwasm_leb(m, 0)
						if (index >= m.functions.length): wwasm_fail(m, c"invalid element function")
						m.table[offset + j] = index
				else:
					if (!m.has_memory || offset > m.pages * 65536 || n > m.pages * 65536 - offset || n > m.end - m.pos):
						wwasm_fail(m, c"data segment out of bounds")
						break
					mem_copy(m.memory + offset, m.bytes + m.pos, n)
					m.pos = m.pos + n
		else if (section == 10):
			code_count = count
			if (count != m.functions.length - m.imports): wwasm_fail(m, c"function/code count mismatch")
			for i in range(count):
				if (m.error != 0): break
				int body_size = wwasm_leb(m, 0)
				int section_end = m.end
				if (body_size > m.end - m.pos):
					wwasm_fail(m, c"function exceeds section")
					break
				m.end = m.pos + body_size
				wwasm_decode(m, m.functions[m.imports + i])
				if (m.pos != m.end): wwasm_fail(m, c"trailing function bytes")
				m.end = section_end
		if (m.pos != m.end): wwasm_fail(m, c"section length mismatch")
	if (m.functions.length != m.imports && code_count < 0): wwasm_fail(m, c"missing code section")
	if (m.error == 0):
		for i in range(m.imports, m.functions.length): wwasm_validate_function(m, m.functions[i])
	m.valid = m.error == 0
	return m

void wwasm_free(wwasm* m):
	if (m == 0): return
	for wwasm_type* t in m.types:
		__w_list_free(cast(__w_list*, t.params))
		free(t)
	for wwasm_function* f in m.functions:
		for wwasm_op* op in f.ops:
			if (op.labels != 0): __w_list_free(cast(__w_list*, op.labels))
			free(op)
		__w_list_free(cast(__w_list*, f.ops))
		__w_list_free(cast(__w_list*, f.locals))
		free(f.module_name)
		free(f.name)
		free(f)
	for wwasm_export* e in m.exports:
		free(e.name)
		free(e)
	for wwasm_global* g in m.globals: free(g)
	__w_list_free(cast(__w_list*, m.types))
	__w_list_free(cast(__w_list*, m.functions))
	__w_list_free(cast(__w_list*, m.exports))
	__w_map_free(cast(__w_hash_table*, m.export_names))
	__w_list_free(cast(__w_list*, m.globals))
	__w_list_free(cast(__w_list*, m.table))
	free(m.memory)
	free(m.bytes)
	free(m)

int wwasm_grow(wwasm* m, int delta):
	delta = wwasm_u32(delta)
	if (!m.has_memory || delta > m.max_pages - m.pages): return -1
	int old = m.pages
	if (m.grow_hook != 0):
		wwasm_memory_changed* hook = cast(wwasm_memory_changed*, m.grow_hook)
		if (!hook(m.grow_context, m, delta)): return -1
	if (delta == 0 && m.memory != 0): return old
	char* replacement = cast(char*, malloc((old + delta) * 65536 + 1))
	mem_copy(replacement, m.memory, old * 65536)
	for i in range(old * 65536, (old + delta) * 65536 + 1): replacement[i] = 0
	free(m.memory)
	m.memory = replacement
	m.pages = old + delta
	return old

int wwasm_type_equal(wwasm_type* a, wwasm_type* b):
	if (a.result != b.result || a.params.length != b.params.length): return 0
	for i in range(a.params.length):
		if (a.params[i] != b.params[i]): return 0
	return 1

int wwasm_shift_unsigned(int value, int shift):
	shift = shift & 63
	if (shift == 0): return value
	return (value >> shift) & ((1 << (64 - shift)) - 1)

int wwasm_div_u64(wwasm* m, int a, int b, int remainder):
	if (b == 0):
		wwasm_fail(m, c"integer divide by zero")
		return 0
	int quotient = 0
	int rest = 0
	int sign = 1 << 63
	for i in range(64):
		int overflow = rest < 0
		rest = (rest << 1) | ((a >> (63 - i)) & 1)
		if (overflow || (rest ^ sign) >= (b ^ sign)):
			rest = rest - b
			quotient = quotient | (1 << (63 - i))
	if (remainder): return rest
	return quotient

int wwasm_numeric(wwasm* m, int c, int a, int b):
	int x = wwasm_i32(a)
	int y = wwasm_i32(b)
	int ux = wwasm_u32(a)
	int uy = wwasm_u32(b)
	if (c == 69): return x == 0
	if (c == 70): return x == y
	if (c == 71): return x != y
	if (c == 72): return x < y
	if (c == 73): return ux < uy
	if (c == 74): return x > y
	if (c == 75): return ux > uy
	if (c == 76): return x <= y
	if (c == 77): return ux <= uy
	if (c == 78): return x >= y
	if (c == 79): return ux >= uy
	if (c >= 103 && c <= 105):
		int n = 0
		if (c == 103):
			while (n < 32 && (ux & (1 << (31 - n))) == 0): n = n + 1
		else if (c == 104):
			while (n < 32 && (ux & (1 << n)) == 0): n = n + 1
		else:
			for i in range(32): n = n + ((ux >> i) & 1)
		return n
	if (c == 106): return wwasm_i32(x + y)
	if (c == 107): return wwasm_i32(x - y)
	if (c == 108): return wwasm_i32(x * y)
	if (c >= 109 && c <= 112):
		if (y == 0):
			wwasm_fail(m, c"integer divide by zero")
			return 0
		if (c == 109):
			if (x == (-2147483647 - 1) && y == -1):
				wwasm_fail(m, c"integer overflow")
				return 0
			return wwasm_i32(x / y)
		if (c == 110): return wwasm_i32(ux / uy)
		if (c == 111): return wwasm_i32(x % y)
		return wwasm_i32(ux % uy)
	if (c == 113): return wwasm_i32(x & y)
	if (c == 114): return wwasm_i32(x | y)
	if (c == 115): return wwasm_i32(x ^ y)
	if (c == 116): return wwasm_i32(x << (y & 31))
	if (c == 117): return x >> (y & 31)
	if (c == 118): return wwasm_i32(ux >> (y & 31))
	if (c == 119): return wwasm_i32((ux << (y & 31)) | (ux >> ((32 - y) & 31)))
	if (c == 120): return wwasm_i32((ux >> (y & 31)) | (ux << ((32 - y) & 31)))
	if (c == 124): return a + b
	if (c == 126): return a * b
	if (c == 128 || c == 130): return wwasm_div_u64(m, a, b, c == 130)
	if (c == 136): return wwasm_shift_unsigned(a, b)
	if (c == 167 || c == 172 || c == 188 || c == 190): return x
	if (c == 173): return ux
	if (c == 178): return float_bits(cast(float, x))
	float fa = float_from_bits(a)
	float fb = float_from_bits(b)
	if (c >= 91 && c <= 96):
		if (fis_nan(fa) || fis_nan(fb)): return c == 92
		if (c == 91): return fa == fb
		if (c == 92): return fa != fb
		if (c == 93): return fa < fb
		if (c == 94): return fa > fb
		if (c == 95): return fa <= fb
		return fa >= fb
	if (c == 146): return float_bits(fa + fb)
	if (c == 147): return float_bits(fa - fb)
	if (c == 148): return float_bits(fa * fb)
	if (c == 149): return float_bits(fa / fb)
	if (c == 252):
		if (fis_nan(fa)): return 0
		if (fa >= 2147483648.0): return 2147483647
		if (fa <= -2147483648.0): return -2147483647 - 1
		return cast(int, fa)
	wwasm_fail(m, c"unsupported numeric opcode")
	return 0

int wwasm_execute(wwasm* m, int index, list[int] args):
	if (m.error != 0): return 0
	if (!m.valid || index < 0 || index >= m.functions.length):
		wwasm_fail(m, c"invalid function call")
		return 0
	wwasm_function* f = m.functions[index]
	wwasm_type* type = m.types[f.signature]
	if (args.length != type.params.length):
		wwasm_fail(m, c"argument count mismatch")
		return 0
	if (m.depth >= m.max_depth || m.fuel <= 0):
		wwasm_fail(m, c"WebAssembly execution limit")
		return 0
	m.depth = m.depth + 1
	m.fuel = m.fuel - 1
	if (index < m.imports):
		int result = 0
		if (f.callback == 0): wwasm_fail(m, c"unlinked import")
		else:
			wwasm_host* callback = cast(wwasm_host*, f.callback)
			result = callback(f.context, m, args)
		m.depth = m.depth - 1
		return result
	list[int] locals = new list[int]
	for int arg in args: locals.push(arg)
	for int kind in f.locals: locals.push(0)
	list[int] stack = new list[int]
	list[wwasm_control*] controls = new list[wwasm_control*]
	wwasm_control* root = new wwasm_control()
	root.pc = -1
	root.result = type.result
	controls.push(root)
	int pc = 0
	int result = 0
	while (pc < f.ops.length && m.error == 0):
		if (m.fuel <= 0):
			wwasm_fail(m, c"WebAssembly instruction limit")
			break
		m.fuel = m.fuel - 1
		wwasm_op* op = f.ops[pc]
		int c = op.code
		int branch = -1
		if (c == 0): wwasm_fail(m, c"unreachable")
		else if (c >= 2 && c <= 4):
			int condition = 1
			if (c == 4): condition = stack.pop()
			wwasm_control* control = new wwasm_control()
			control.pc = pc
			control.height = stack.length
			control.loop = c == 3
			if (op.a != 64): control.result = op.a
			controls.push(control)
			if (!condition):
				if (op.alternative >= 0): pc = op.alternative
				else: pc = op.end - 1
		else if (c == 5): pc = op.end - 1
		else if (c == 11):
			wwasm_control* control = controls.pop()
			free(control)
			if (controls.length == 0): break
		else if (c == 12): branch = op.a
		else if (c == 13):
			if (stack.pop() != 0): branch = op.a
		else if (c == 14):
			int selector = wwasm_u32(stack.pop())
			if (selector >= op.labels.length - 1): selector = op.labels.length - 1
			branch = op.labels[selector]
		else if (c == 15): break
		else if (c == 16 || c == 17):
			int called_index = op.a
			wwasm_type* called = 0
			if (c == 17):
				int slot = wwasm_u32(stack.pop())
				if (slot >= m.table.length): wwasm_fail(m, c"table access out of bounds")
				else:
					called_index = m.table[slot]
					if (called_index < 0): wwasm_fail(m, c"uninitialized table element")
					else if (!wwasm_type_equal(m.types[op.a], m.types[m.functions[called_index].signature])): wwasm_fail(m, c"indirect call type mismatch")
			if (m.error != 0): break
			called = m.types[m.functions[called_index].signature]
			list[int] arguments = new list[int]
			int start = stack.length - called.params.length
			for i in range(called.params.length): arguments.push(stack[start + i])
			while (stack.length > start): stack.pop()
			int returned = wwasm_execute(m, called_index, arguments)
			__w_list_free(cast(__w_list*, arguments))
			if (called.result): stack.push(returned)
		else if (c == 26): stack.pop()
		else if (c == 27):
			int condition = stack.pop()
			int second = stack.pop()
			int first = stack.pop()
			if (condition): stack.push(first)
			else: stack.push(second)
		else if (c == 32): stack.push(locals[op.a])
		else if (c == 33): locals[op.a] = stack.pop()
		else if (c == 34): locals[op.a] = stack[stack.length - 1]
		else if (c == 35): stack.push(m.globals[op.a].bits)
		else if (c == 36): m.globals[op.a].bits = stack.pop()
		else if (c >= 40 && c <= 62):
			int width = 4
			if (c == 41): width = 8
			if (c == 44 || c == 45 || c == 58): width = 1
			if (c == 46 || c == 47 || c == 59): width = 2
			int value = 0
			if (c >= 54): value = stack.pop()
			int address = wwasm_u32(stack.pop()) + op.b
			if (address > m.pages * 65536 - width):
				wwasm_fail(m, c"memory access out of bounds")
				break
			if (c >= 54):
				for j in range(width): m.memory[address + j] = (value >> (j * 8)) & 255
			else:
				for j in range(width): value = value | ((m.memory[address + j] & 255) << (j * 8))
				if (c == 44): value = (value << 56) >> 56
				if (c == 46): value = (value << 48) >> 48
				if (c == 41): stack.push(value)
				else: stack.push(wwasm_i32(value))
		else if (c == 63): stack.push(m.pages)
		else if (c == 64): stack.push(wwasm_grow(m, stack.pop()))
		else if (c == 65 || c == 66 || c == 67): stack.push(op.a)
		else if (c != 1):
			int b = 0
			int a = stack.pop()
			if ((c >= 70 && c <= 79) || (c >= 91 && c <= 96) || (c >= 106 && c <= 120) || c == 124 || c == 126 || c == 128 || c == 130 || c == 136 || (c >= 146 && c <= 149)):
				b = a
				a = stack.pop()
			stack.push(wwasm_numeric(m, c, a, b))
		if (branch >= 0):
			int target = controls.length - branch - 1
			wwasm_control* control = controls[target]
			int value = 0
			if (control.result && !control.loop): value = stack.pop()
			while (stack.length > control.height): stack.pop()
			if (control.result && !control.loop): stack.push(value)
			while (controls.length > target + 1): free(controls.pop())
			if (control.pc < 0): break
			if (control.loop): pc = control.pc
			else: pc = f.ops[control.pc].end - 1
		pc = pc + 1
	if (type.result && m.error == 0): result = stack.pop()
	for wwasm_control* control in controls: free(control)
	__w_list_free(cast(__w_list*, controls))
	__w_list_free(cast(__w_list*, stack))
	__w_list_free(cast(__w_list*, locals))
	m.depth = m.depth - 1
	return result

wwasm_export* wwasm_find_export(wwasm* m, char* name):
	for wwasm_export* e in m.exports:
		if (strcmp(e.name, name) == 0): return e
	return 0

int wwasm_bind(wwasm* m, char* module_name, char* name, void* context, wwasm_host* callback):
	int found = 0
	for i in range(m.imports):
		wwasm_function* f = m.functions[i]
		if (strcmp(f.module_name, module_name) == 0 && strcmp(f.name, name) == 0):
			f.context = context
			f.callback = cast(int, callback)
			found = 1
	return found

int wwasm_call(wwasm* m, int index, list[int] args, int fuel):
	if (!m.valid): return 0
	if (m.depth == 0):
		m.error = 0
		m.fuel = fuel
	return wwasm_execute(m, index, args)
