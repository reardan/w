# LLVM text lowering of the production retained semantic forest (#337).
# The visitor starts at the program entry and lowers every function and
# global it reaches, across imported modules, as long as each one stays in
# the supported subset (docs/projects/llvm.md). It never reparses source
# and never changes the native compiler's emission path.
#
# Value model: every W word is an i64, and so is every pointer value: W
# pointer arithmetic is unscaled bytes, so add/sub keep W semantics as-is.
# Places (locals, globals, dereferences, fields, subscripts) are LLVM ptr
# operands so LLVM keeps the provenance it needs to promote locals; loads
# and stores use the width and signedness of the place's W type.
import compiler.retained_ast
import lib.file
import lib.stream

# Type classes (llvm_class).
const int llvm_class_none = 0
const int llvm_class_word = 1
const int llvm_class_struct = 2
const int llvm_class_array = 3
const int llvm_class_slice = 4
const int llvm_class_void = 5

string_builder* llvm_out
string_builder* llvm_entry
string_builder* llvm_data
string_builder* llvm_code
# The current function's first diagnostic, until it is reported.
string_builder* llvm_message
int llvm_input
int llvm_stubs
int llvm_failed
int llvm_register
int llvm_label_counter
int llvm_block
int llvm_terminated
int llvm_function
int llvm_function_node
int llvm_reachable
int llvm_expression_depth
int llvm_break_label = -1
int llvm_continue_label = -1
int llvm_constants
int llvm_uses_memory
int llvm_uses_trap
int llvm_uses_bits
list[int] llvm_first
list[int] llvm_next
# linkage -> defining function node; name -> linkage of a defined function
map[int, int] llvm_functions
map[char*, int] llvm_function_names
# Functions queued for emission (by linkage), in discovery order, and the
# function whose body first reached each (for diagnostics).
map[int, int] llvm_queued
list[int] llvm_queue
map[int, int] llvm_reached_from
# linkage -> global declaration node; globals referenced, in order.
map[int, int] llvm_global_decls
map[int, int] llvm_globals_used
list[int] llvm_global_order
map[int, int] llvm_locals
# Bindings owned by each function node, as a linked list over bindings.
map[int, int] llvm_owned_first
list[int] llvm_owned_next


void llvm_put(char* text):
	string_append(llvm_out, text)


char* llvm_number(int value):
	string_builder* text = string_new()
	string_append_int(text, value)
	char* result = retained_intern(text.data)
	string_free(text)
	return result


char* llvm_name(char* prefix, int value):
	string_builder* text = string_new()
	string_append(text, prefix)
	string_append_int(text, value)
	char* result = retained_intern(text.data)
	string_free(text)
	return result


char* llvm_temp():
	llvm_register = llvm_register + 1
	return llvm_name(c"%t", llvm_register)


void llvm_error_at(int id, char* message, char* detail):
	if (llvm_failed): return
	llvm_failed = 1
	retained_node node
	retained_node_load(id, &node)
	string_builder* text = llvm_message
	if (node.source >= 0): string_append(text, retained_sources[node.source].path)
	string_append(text, c":")
	string_append_int(text, node.line)
	string_append(text, c":")
	string_append_int(text, node.column)
	string_append(text, c": wllvm: unsupported ")
	string_append(text, message)
	if (detail != 0):
		string_append(text, c" '")
		string_append(text, detail)
		string_append(text, c"'")
	string_append(text, c"\x0a")
	# Library code is reached through calls: show the path from the entry.
	int walk = llvm_function_node
	int depth = 0
	while ((walk >= 0) && (depth < 32)):
		retained_node caller
		retained_node_load(walk, &caller)
		string_append(text, c"  in ")
		string_append(text, caller.name)
		string_append(text, c" (")
		string_append(text, retained_sources[caller.source].path)
		string_append(text, c":")
		string_append_int(text, caller.line)
		string_append(text, c")\x0a")
		walk = -1
		if (caller.binding >= 0):
			int linkage = retained_bindings[caller.binding].linkage
			if (linkage in llvm_reached_from): walk = llvm_reached_from[linkage]
		depth = depth + 1


# Write and clear the pending diagnostic, prefixed (warnings) or not.
void llvm_report(char* prefix):
	if (llvm_message.length == 0): return
	wstream* err = stderr_writer()
	if (prefix != 0): stream_write_cstr(err, prefix)
	stream_write_cstr(err, llvm_message.data)
	stream_flush(err)
	llvm_message.length = 0
	llvm_message.data[0] = 0


void llvm_error(int id, char* message):
	llvm_error_at(id, message, 0)


# --- types -----------------------------------------------------------------

# Aliases and const qualifiers name their underlying type through target.
retained_type* llvm_type(int type):
	retained_type* t = retained_types[type]
	int guard = 0
	while (((t.kind == 1) || (t.kind == 5)) && (t.pointer_level == 0) && (t.target >= 0) && (guard < 16)):
		t = retained_types[t.target]
		guard = guard + 1
	return t


int llvm_named(retained_type* t, char* name):
	return (t.pointer_level == 0) && (strcmp(t.name, name) == 0)


int llvm_class(int type);
int llvm_has_headers(int type);


int llvm_class_of(retained_type* t):
	# checked pointers (own/ref/optown/... kinds 21-30) carry automatic drops
	# the retained tree does not spell out
	if ((t.kind >= 21) && (t.kind <= 30)): return llvm_class_none
	if (t.pointer_level > 0): return llvm_class_word
	if (t.kind == 6):
		# The native backend leaves element headers zeroed: reject rather
		# than disagree with its bounds checks.
		if (llvm_has_headers(t.target)): return llvm_class_none
		return llvm_class_array
	if (t.kind == 7): return llvm_class_slice
	# string handles, enums and function values are one word
	if ((t.kind == 8) || (t.kind == 4) || (t.kind == 2)): return llvm_class_word
	if (t.fields.length > 0):
		for i in range(t.fields.length):
			int field = llvm_class(t.fields[i].type)
			if ((field == llvm_class_none) || (field == llvm_class_void)): return llvm_class_none
		return llvm_class_struct
	char* n = t.name
	if (strcmp(n, c"void") == 0): return llvm_class_void
	list[char*] words = list[char*]{c"int", c"uint", c"char", c"byte", c"bool", c"constant", c"function", c"pointer", c"int8", c"int16", c"int32", c"int64", c"uint8", c"uint16", c"uint32", c"uint64"}
	int found = 0
	for w in words:
		if (strcmp(n, w) == 0): found = 1
	words.free()
	if (found): return llvm_class_word
	return llvm_class_none


int llvm_class(int type):
	if (type < 0): return llvm_class_none
	return llvm_class_of(llvm_type(type))


# Bytes a load or store of the type touches (word scalars only).
int llvm_width(int type):
	if (type < 0): return 8
	retained_type* t = llvm_type(type)
	if ((t.pointer_level > 0) || (t.kind == 8) || (t.kind == 2)): return 8
	if ((t.size == 1) || (t.size == 2) || (t.size == 4)): return t.size
	return 8


char* llvm_int_type(int width):
	if (width == 1): return c"i8"
	if (width == 2): return c"i16"
	if (width == 4): return c"i32"
	return c"i64"


int llvm_zero_extends(int type):
	if (type < 0): return 0
	retained_type* t = llvm_type(type)
	return llvm_named(t, c"uint8") || llvm_named(t, c"uint16") || llvm_named(t, c"uint32")


# uint and uint64 fill the word: their operations are unsigned.
int llvm_unsigned_word(int type):
	if (type < 0): return 0
	retained_type* t = llvm_type(type)
	return llvm_named(t, c"uint") || llvm_named(t, c"uint64")


int llvm_is_bool(int type):
	return (type >= 0) && llvm_named(llvm_type(type), c"bool")


int llvm_is_string(int type):
	if (type < 0): return 0
	retained_type* t = llvm_type(type)
	return (t.pointer_level == 0) && (t.kind == 8)


int llvm_is_char_pointer(int type):
	if (type < 0): return 0
	retained_type* t = llvm_type(type)
	return (t.pointer_level == 1) && (strcmp(t.name, c"char") == 0)


int llvm_storage(int type):
	int c = llvm_class(type)
	if ((c == llvm_class_struct) || (c == llvm_class_array)): return (llvm_type(type).size + 7) & (0 - 8)
	return 8


# --- instructions ----------------------------------------------------------

char* llvm_op(char* op, char* type, char* a, char* b):
	char* result = llvm_temp()
	llvm_put(c"  ")
	llvm_put(result)
	llvm_put(c" = ")
	llvm_put(op)
	llvm_put(c" ")
	llvm_put(type)
	llvm_put(c" ")
	llvm_put(a)
	llvm_put(c", ")
	llvm_put(b)
	llvm_put(c"\x0a")
	return result


char* llvm_instruction(char* op, char* a, char* b):
	return llvm_op(op, c"i64", a, b)


char* llvm_convert_op(char* op, char* from, char* value, char* to):
	char* result = llvm_temp()
	llvm_put(c"  ")
	llvm_put(result)
	llvm_put(c" = ")
	llvm_put(op)
	llvm_put(c" ")
	llvm_put(from)
	llvm_put(c" ")
	llvm_put(value)
	llvm_put(c" to ")
	llvm_put(to)
	llvm_put(c"\x0a")
	return result


char* llvm_bool(char* value):
	return llvm_instruction(c"icmp ne", value, c"0")


char* llvm_extend(char* value):
	return llvm_convert_op(c"zext", c"i1", value, c"i64")


char* llvm_pointer(char* value):
	return llvm_convert_op(c"inttoptr", c"i64", value, c"ptr")


char* llvm_address_value(char* address):
	return llvm_convert_op(c"ptrtoint", c"ptr", address, c"i64")


char* llvm_offset(char* address, char* offset):
	if (strcmp(offset, c"0") == 0): return address
	char* result = llvm_temp()
	llvm_put(c"  ")
	llvm_put(result)
	llvm_put(c" = getelementptr i8, ptr ")
	llvm_put(address)
	llvm_put(c", i64 ")
	llvm_put(offset)
	llvm_put(c"\x0a")
	return result


char* llvm_load(int type, char* address):
	int width = llvm_width(type)
	char* t = llvm_int_type(width)
	char* result = llvm_temp()
	llvm_put(c"  ")
	llvm_put(result)
	llvm_put(c" = load ")
	llvm_put(t)
	llvm_put(c", ptr ")
	llvm_put(address)
	llvm_put(c", align 1\x0a")
	if (width == 8): return result
	if (llvm_zero_extends(type)): return llvm_convert_op(c"zext", t, result, c"i64")
	return llvm_convert_op(c"sext", t, result, c"i64")


void llvm_store_width(int width, char* value, char* address):
	char* t = llvm_int_type(width)
	if (width != 8): value = llvm_convert_op(c"trunc", c"i64", value, t)
	llvm_put(c"  store ")
	llvm_put(t)
	llvm_put(c" ")
	llvm_put(value)
	llvm_put(c", ptr ")
	llvm_put(address)
	llvm_put(c", align 1\x0a")


void llvm_memory_call(char* name, char* destination, char* source, int size):
	llvm_uses_memory = 1
	llvm_put(c"  call void @")
	llvm_put(name)
	llvm_put(c"(ptr ")
	llvm_put(destination)
	if (strcmp(name, c"llvm.memset.p0.i64") == 0): llvm_put(c", i8 0")
	else:
		llvm_put(c", ptr ")
		llvm_put(source)
	llvm_put(c", i64 ")
	llvm_put(llvm_number(size))
	llvm_put(c", i1 false)\x0a")


int llvm_label_new():
	llvm_label_counter = llvm_label_counter + 1
	return llvm_label_counter


void llvm_label(int label):
	llvm_put(llvm_name(c"b", label))
	llvm_put(c":\x0a")
	llvm_block = label
	llvm_terminated = 0


void llvm_branch(int label):
	if (llvm_terminated): return
	llvm_put(c"  br label %b")
	llvm_put(llvm_number(label))
	llvm_put(c"\x0a")
	llvm_terminated = 1


void llvm_cond_branch(char* condition, int yes, int no):
	llvm_put(c"  br i1 ")
	llvm_put(condition)
	llvm_put(c", label %b")
	llvm_put(llvm_number(yes))
	llvm_put(c", label %b")
	llvm_put(llvm_number(no))
	llvm_put(c"\x0a")
	llvm_terminated = 1


# Branch to a trap block when condition holds; continue in a fresh block.
void llvm_trap_if(char* condition):
	llvm_uses_trap = 1
	int trap = llvm_label_new()
	int valid = llvm_label_new()
	llvm_cond_branch(condition, trap, valid)
	llvm_label(trap)
	llvm_put(c"  call void @llvm.trap()\x0a  unreachable\x0a")
	llvm_terminated = 1
	llvm_label(valid)


# --- module data -------------------------------------------------------------

void llvm_data_bytes(char* bytes, int length):
	string_append(llvm_data, c"[")
	string_append_int(llvm_data, length + 1)
	string_append(llvm_data, c" x i8] c\"")
	for i in range(length):
		int c = bytes[i] & 255
		if ((c >= 32) && (c < 127) && (c != '"') && (c != 92)): string_append_char(llvm_data, c)
		else:
			string_append_char(llvm_data, 92)
			string_append_char(llvm_data, c"0123456789ABCDEF"[c >> 4])
			string_append_char(llvm_data, c"0123456789ABCDEF"[c & 15])
	string_append(llvm_data, c"\\00\"")


# A NUL-terminated constant; returns its global name.
char* llvm_string_constant(char* bytes, int length):
	llvm_constants = llvm_constants + 1
	char* name = llvm_name(c"@.s", llvm_constants)
	string_append(llvm_data, name)
	string_append(llvm_data, c" = private unnamed_addr constant ")
	llvm_data_bytes(bytes, length)
	string_append(llvm_data, c", align 1\x0a")
	return name


# A string value: its {data, length} descriptor in writable data.
char* llvm_string_descriptor(char* bytes, int length):
	char* text = llvm_string_constant(bytes, length)
	llvm_constants = llvm_constants + 1
	char* name = llvm_name(c"@.d", llvm_constants)
	string_append(llvm_data, name)
	string_append(llvm_data, c" = private global { ptr, i64 } { ptr ")
	string_append(llvm_data, text)
	string_append(llvm_data, c", i64 ")
	string_append_int(llvm_data, length)
	string_append(llvm_data, c" }, align 8\x0a")
	return name


char* llvm_function_symbol(int linkage):
	if ((linkage in llvm_queued) == 0):
		llvm_queued[linkage] = 1
		llvm_queue.push(llvm_functions[linkage])
		llvm_reached_from[linkage] = llvm_function_node
	return llvm_name(c"@w", linkage)


char* llvm_global_symbol(int linkage):
	if ((linkage in llvm_globals_used) == 0):
		llvm_globals_used[linkage] = 1
		llvm_global_order.push(linkage)
	return llvm_name(c"@g", linkage)


char* llvm_constant_address(char* symbol):
	string_builder* text = string_new()
	string_append(text, c"ptrtoint (ptr ")
	string_append(text, symbol)
	string_append(text, c" to i64)")
	char* result = retained_intern(text.data)
	string_free(text)
	return result


# --- expressions -------------------------------------------------------------

int llvm_node_id(int group, int operand):
	return group + 1 + operand


char* llvm_value(int group, int operand);
char* llvm_address(int group, int operand);


int llvm_decays(int from, int to);


# Bool stores and arguments hold 0 or 1; a C string becomes a string value
# through the runtime's str_from_cstr, exactly as the native coercion.
char* llvm_convert(int id, char* value, int from, int to):
	if (llvm_is_bool(to)): return llvm_extend(llvm_bool(value))
	if (llvm_is_string(to) && llvm_is_char_pointer(from)):
		if ((c"str_from_cstr" in llvm_function_names) == 0):
			llvm_error(id, c"string conversion without str_from_cstr")
			return c"0"
		char* callee = llvm_function_symbol(llvm_function_names[c"str_from_cstr"])
		char* result = llvm_temp()
		llvm_put(c"  ")
		llvm_put(result)
		llvm_put(c" = call i64 ")
		llvm_put(callee)
		llvm_put(c"(i64 ")
		llvm_put(value)
		llvm_put(c")\x0a")
		return result
	# A fixed array or slice decays to its data pointer.
	if (llvm_decays(from, to)): return llvm_load(-1, llvm_pointer(value))
	return value


void llvm_fix_headers(int type, char* base);
char* llvm_temporary_field(int group, retained_node* node);
char* llvm_record_copy(int type, char* value);
char* llvm_record_buffer(int type);
void llvm_store_record_fields(int group, int id, retained_node* node, int record_type, char* object);
char* llvm_record_literal(int group, int id, retained_node* node);
int llvm_parameter_ok(int type);
void llvm_convert_indirect(int group, int id, retained_node* node, list[char*] values, list[int] types);
char* llvm_length(int group, int id, retained_node* node);


# Store value (already an i64 word, or a struct's address) into a place.
void llvm_store(int id, int type, char* value, char* address):
	int c = llvm_class(type)
	if (c == llvm_class_struct):
		llvm_memory_call(c"llvm.memcpy.p0.p0.i64", address, llvm_pointer(value), llvm_type(type).size)
		llvm_fix_headers(type, address)
		return
	if (c == llvm_class_slice):
		llvm_store_width(8, value, address)
		return
	if (c != llvm_class_word):
		llvm_error(id, c"assignment of this type")
		return
	llvm_store_width(llvm_width(type), value, address)


int llvm_place(retained_node* node):
	int op = node.op
	if ((op == 'd') || (op == 'i') || (op == 'I') || (op == 'B')): return 1
	if (op == '.'): return node.high >= 0
	if (op == 'v'): return (node.binding >= 0) && ((node.binding in llvm_locals) || (retained_bindings[node.binding].linkage in llvm_global_decls))
	return 0


char* llvm_address(int group, int operand):
	if (llvm_failed): return c"null"
	int id = llvm_node_id(group, operand)
	retained_node node
	retained_node_load(id, &node)
	int op = node.op
	if (op == 'v'):
		if ((node.binding >= 0) && (node.binding in llvm_locals)): return llvm_name(c"%v", node.binding)
		if (node.binding >= 0):
			int linkage = retained_bindings[node.binding].linkage
			if (linkage in llvm_global_decls): return llvm_global_symbol(linkage)
		llvm_error_at(id, c"reference to", node.binding_name)
		return c"null"
	if (op == 'd'): return llvm_pointer(llvm_value(group, node.left))
	if (op == '.'):
		if (node.high < 0):
			llvm_error(id, c"field of a temporary record")
			return c"null"
		char* base = c"null"
		if (node.high > 0): base = llvm_pointer(llvm_value(group, node.left))
		else: base = llvm_address(group, node.left)
		return llvm_offset(base, llvm_number(node.value))
	if (op == 'B'): return llvm_offset(llvm_pointer(llvm_value(group, node.left)), llvm_number(node.value))
	if (op == 'i'):
		char* base = llvm_value(group, node.left)
		char* index = llvm_value(group, node.right)
		int size = node.value
		if (size < 1): size = 1
		if (size > 1): index = llvm_instruction(c"mul", index, llvm_number(size))
		return llvm_offset(llvm_pointer(base), index)
	if (op == 'I'):
		retained_node left
		retained_node_load(llvm_node_id(group, node.left), &left)
		char* index = llvm_value(group, node.right)
		char* data = c"null"
		char* length = c"0"
		if ((llvm_class(left.semantic_type) == llvm_class_array) && llvm_place(&left)):
			# A fixed array's header always names its own storage.
			char* descriptor = llvm_address(group, node.left)
			data = llvm_offset(descriptor, c"16")
			length = llvm_number(llvm_type(left.semantic_type).array_length)
		else if (llvm_class(left.semantic_type) == llvm_class_slice):
			char* descriptor = llvm_pointer(llvm_value(group, node.left))
			data = llvm_pointer(llvm_load(-1, descriptor))
			length = llvm_load(-1, llvm_offset(descriptor, c"8"))
		else:
			llvm_error(id, c"buffer subscript")
			return c"null"
		llvm_trap_if(llvm_instruction(c"icmp uge", index, length))
		int size = node.value
		if (size < 1): size = 1
		if (size > 1): index = llvm_instruction(c"mul", index, llvm_number(size))
		return llvm_offset(data, index)
	llvm_error(id, c"assignment target")
	return c"null"


int llvm_unsigned_operands(int group, retained_node* node):
	retained_node a
	retained_node b
	retained_node_load(llvm_node_id(group, node.left), &a)
	retained_node_load(llvm_node_id(group, node.right), &b)
	return llvm_unsigned_word(a.semantic_type) || llvm_unsigned_word(b.semantic_type)


char* llvm_binary(int id, int op, int is_unsigned, char* a, char* b):
	char* instruction = 0
	if (op == '+'): instruction = c"add"
	else if (op == '-'): instruction = c"sub"
	else if (op == '*'): instruction = c"mul"
	else if (op == '&'): instruction = c"and"
	else if (op == '|'): instruction = c"or"
	else if (op == '^'): instruction = c"xor"
	else if (op == 'L'): instruction = c"shl"
	else if (op == 'R'):
		instruction = c"ashr"
		if (is_unsigned): instruction = c"lshr"
	else if (op == 0x94): instruction = c"icmp eq"
	else if (op == 0x95): instruction = c"icmp ne"
	else if (op == 0x9c): instruction = c"icmp slt"
	else if (op == 0x9d): instruction = c"icmp sge"
	else if (op == 0x9e): instruction = c"icmp sle"
	else if (op == 0x9f): instruction = c"icmp sgt"
	if (is_unsigned):
		if (op == 0x9c): instruction = c"icmp ult"
		else if (op == 0x9d): instruction = c"icmp uge"
		else if (op == 0x9e): instruction = c"icmp ule"
		else if (op == 0x9f): instruction = c"icmp ugt"
	if ((op == '/') || (op == '%')):
		# LLVM division by zero and MIN/-1 are poison; x64 W traps. Guard
		# both before evaluating the division, including under optimization.
		char* invalid = llvm_instruction(c"icmp eq", b, c"0")
		if (is_unsigned == 0):
			char* min = llvm_instruction(c"icmp eq", a, c"-9223372036854775808")
			char* minus = llvm_instruction(c"icmp eq", b, c"-1")
			invalid = llvm_op(c"or", c"i1", invalid, llvm_op(c"and", c"i1", min, minus))
		llvm_trap_if(invalid)
		if (is_unsigned):
			instruction = c"udiv"
			if (op == '%'): instruction = c"urem"
		else:
			instruction = c"sdiv"
			if (op == '%'): instruction = c"srem"
	if (instruction == 0):
		llvm_error(id, c"integer operator")
		return c"0"
	if ((op == 'L') || (op == 'R')): b = llvm_instruction(c"and", b, c"63")
	char* result = llvm_instruction(instruction, a, b)
	if ((op >= 0x94) && (op <= 0x9f)): result = llvm_extend(result)
	return result


# Enum constants are bindings of their enum type's constant list.
int llvm_enum_constant(int binding, int* value):
	retained_binding* b = retained_bindings[binding]
	if (b.type < 0): return 0
	retained_type* t = llvm_type(b.type)
	if (t.kind != 4): return 0
	for i in range(t.constants.length):
		if (strcmp(t.constants[i].name, b.name) == 0):
			*value = t.constants[i].value
			return 1
	return 0


char* llvm_call(int group, int id, retained_node* node):
	list[char*] values = new list[char*]
	list[int] types = new list[int]
	int arg = node.left
	if (node.op == 'F'): arg = node.right
	char* callee_value = c"0"
	if (node.op == 'F'): callee_value = llvm_value(group, node.left)
	while ((arg >= 0) && (llvm_failed == 0)):
		char* value = llvm_value(group, arg)
		retained_node argument
		retained_node_load(llvm_node_id(group, arg), &argument)
		# A record argument is the address of the caller's own copy.
		if (llvm_class(argument.semantic_type) == llvm_class_struct): value = llvm_record_copy(argument.semantic_type, value)
		values.push(value)
		types.push(argument.semantic_type)
		arg = argument.next_arg
	char* target = c"null"
	int count = values.length
	int record_result = -1
	if ((node.op == 'F') && (llvm_class(node.semantic_type) == llvm_class_struct)): record_result = node.semantic_type
	if (node.op == 'F'):
		target = llvm_pointer(callee_value)
		llvm_convert_indirect(group, id, node, values, types)
	else:
		retained_binding* callee = retained_bindings[node.binding]
		if ((callee.linkage in llvm_functions) == 0):
			int syscall = (strcmp(callee.name, c"syscall") == 0) || (strcmp(callee.name, c"syscall7") == 0)
			if (syscall && ((values.length == 4) || (values.length == 7))):
				char* result = llvm_temp()
				llvm_put(c"  ")
				llvm_put(result)
				if (values.length == 4): llvm_put(c" = call i64 asm sideeffect \"syscall\", \"={rax},{rax},{rdi},{rsi},{rdx},~{rcx},~{r11},~{memory}\"(")
				else: llvm_put(c" = call i64 asm sideeffect \"syscall\", \"={rax},{rax},{rdi},{rsi},{rdx},{r10},{r8},{r9},~{rcx},~{r11},~{memory}\"(")
				for i in range(values.length):
					if (i > 0): llvm_put(c", ")
					llvm_put(c"i64 ")
					llvm_put(values[i])
				llvm_put(c")\x0a")
				values.free()
				types.free()
				return result
			llvm_error_at(id, c"call to a function without a W body", callee.name)
			values.free()
			types.free()
			return c"0"
		retained_node definition
		retained_node_load(llvm_functions[callee.linkage], &definition)
		retained_binding* defined = retained_bindings[definition.binding]
		# _main passes argc and argv even to a main without parameters.
		if (count > defined.parameters.length): count = defined.parameters.length
		if (count < defined.parameters.length): llvm_error_at(id, c"call argument count", callee.name)
		for i in range(count):
			if (i < defined.parameters.length):
				if (llvm_parameter_ok(defined.parameters[i]) == 0): llvm_error_at(id, c"parameter passed by value to", callee.name)
				values[i] = llvm_convert(id, values[i], types[i], defined.parameters[i])
		if (llvm_class(defined.return_type) == llvm_class_struct): record_result = defined.return_type
		target = llvm_function_symbol(callee.linkage)
	# A record result is written to a caller buffer named by a hidden first
	# argument; the call's value is that buffer's address.
	char* buffer = 0
	if (record_result >= 0): buffer = llvm_address_value(llvm_record_buffer(record_result))
	char* result = llvm_temp()
	llvm_put(c"  ")
	llvm_put(result)
	llvm_put(c" = call i64 ")
	llvm_put(target)
	llvm_put(c"(")
	if (buffer != 0):
		llvm_put(c"i64 ")
		llvm_put(buffer)
		if (count > 0): llvm_put(c", ")
	for i in range(count):
		if (i > 0): llvm_put(c", ")
		llvm_put(c"i64 ")
		llvm_put(values[i])
	llvm_put(c")\x0a")
	values.free()
	types.free()
	if (buffer != 0): return buffer
	return result


# A call of a named runtime helper (print builtins, len/max/min/abs).
char* llvm_helper_call(int id, char* name, list[char*] values):
	if ((name in llvm_function_names) == 0):
		llvm_error_at(id, c"call to a missing runtime helper", name)
		return c"0"
	char* callee = llvm_function_symbol(llvm_function_names[name])
	char* result = llvm_temp()
	llvm_put(c"  ")
	llvm_put(result)
	llvm_put(c" = call i64 ")
	llvm_put(callee)
	llvm_put(c"(")
	for i in range(values.length):
		if (i > 0): llvm_put(c", ")
		llvm_put(c"i64 ")
		llvm_put(values[i])
	llvm_put(c")\x0a")
	return result


# grammar/print_builtin.w's prelude helper table, by index.
char* llvm_prelude_helper(int index):
	if (index == 0): return c"__w_print_int"
	if (index == 1): return c"__w_print_cstr"
	if (index == 2): return c"__w_print_str"
	if (index == 5): return c"__w_print_nl"
	if (index == 9): return c"__w_max"
	if (index == 10): return c"__w_min"
	if (index == 11): return c"__w_abs"
	if (index == 12): return c"strlen"
	if (index == 13): return c"__w_print_char"
	return 0


char* llvm_value_inner(int group, int operand);


char* llvm_value(int group, int operand):
	if (llvm_expression_depth >= 256):
		llvm_error(llvm_node_id(group, operand), c"expression nesting beyond 256 nodes")
		return c"0"
	llvm_expression_depth = llvm_expression_depth + 1
	char* result = llvm_value_inner(group, operand)
	llvm_expression_depth = llvm_expression_depth - 1
	return result


char* llvm_value_inner(int group, int operand):
	if (llvm_failed): return c"0"
	int id = llvm_node_id(group, operand)
	retained_node node
	retained_node_load(id, &node)
	int type = node.semantic_type
	int type_class = llvm_class(type)
	int op = node.op
	if ((type_class == llvm_class_none) && (op != 'C') && (op != 'F')):
		if (type >= 0): llvm_error_at(id, c"expression type", retained_types[type].name)
		else: llvm_error(id, c"expression type")
		return c"0"
	if ((op == 0) || (op == 'c') || (op == 'h')): return llvm_number(node.literal_value)
	if (op == 's'): return llvm_constant_address(llvm_string_constant(node.literal_text, node.literal_length))
	if (op == 'S'): return llvm_constant_address(llvm_string_descriptor(node.literal_text, node.literal_length))
	if (op == 'v'):
		if (llvm_place(&node) == 0):
			if (node.binding < 0):
				llvm_error(id, c"unbound name")
				return c"0"
			int value = 0
			if (llvm_enum_constant(node.binding, &value)): return llvm_number(value)
			int linkage = retained_bindings[node.binding].linkage
			if (linkage in llvm_functions): return llvm_constant_address(llvm_function_symbol(linkage))
			llvm_error_at(id, c"reference to", node.binding_name)
			return c"0"
	if ((op == '.') && (node.high < 0)): return llvm_temporary_field(group, &node)
	if (llvm_place(&node)):
		char* address = llvm_address(group, operand)
		if ((type_class == llvm_class_struct) || (type_class == llvm_class_array)): return llvm_address_value(address)
		if (type_class == llvm_class_slice): return llvm_load(-1, address)
		if (type_class != llvm_class_word):
			llvm_error(id, c"value of this type")
			return c"0"
		return llvm_load(type, address)
	if (op == 'r'):
		retained_node left
		retained_node_load(llvm_node_id(group, node.left), &left)
		if (llvm_place(&left) == 0):
			# '&function' names the function's address
			if ((left.op == 'v') && (left.binding >= 0) && (retained_bindings[left.binding].linkage in llvm_functions)): return llvm_value(group, node.left)
			llvm_error(id, c"address of a value")
			return c"0"
		return llvm_address_value(llvm_address(group, node.left))
	if (op == 'Q'):
		# Limb and bit intrinsics on the operands' low 32 bits, unsigned
		# (grammar/limb_builtin.w, grammar/bit_builtin.w).
		int kind = node.value
		list[char*] arguments = new list[char*]
		int arg = node.left
		while ((arg >= 0) && (llvm_failed == 0)):
			arguments.push(llvm_value(group, arg))
			retained_node argument
			retained_node_load(llvm_node_id(group, arg), &argument)
			arg = argument.next_arg
		if ((kind < 1) || (kind > 9) || (arguments.length < 1)):
			llvm_error_at(id, c"integer intrinsic", llvm_number(kind))
			return c"0"
		char* a = llvm_convert_op(c"trunc", c"i64", arguments[0], c"i32")
		char* b = c"0"
		if (arguments.length > 1): b = llvm_convert_op(c"trunc", c"i64", arguments[1], c"i32")
		char* result = c"0"
		if (kind <= 3):
			char* wa = llvm_convert_op(c"zext", c"i32", a, c"i64")
			char* wb = llvm_convert_op(c"zext", c"i32", b, c"i64")
			char* full = c"0"
			if (kind == 3): full = llvm_instruction(c"add", wa, wb)
			else: full = llvm_instruction(c"mul", wa, wb)
			char* high = llvm_instruction(c"lshr", full, c"32")
			result = llvm_instruction(c"and", full, c"4294967295")
			if (kind == 1): result = high
			else if (arguments.length == 3): llvm_store_width(8, high, llvm_pointer(arguments[2]))
		else:
			llvm_uses_bits = 1
			char* bits = llvm_temp()
			char* count = llvm_op(c"and", c"i32", b, c"31")
			llvm_put(c"  ")
			llvm_put(bits)
			if (kind == 4):
				llvm_put(c" = lshr i32 ")
				llvm_put(a)
				llvm_put(c", ")
				llvm_put(count)
			else if (kind == 5) || (kind == 6):
				if (kind == 5): llvm_put(c" = call i32 @llvm.fshl.i32(i32 ")
				else: llvm_put(c" = call i32 @llvm.fshr.i32(i32 ")
				llvm_put(a)
				llvm_put(c", i32 ")
				llvm_put(a)
				llvm_put(c", i32 ")
				llvm_put(count)
				llvm_put(c")")
			else if (kind == 7):
				llvm_put(c" = call i32 @llvm.ctpop.i32(i32 ")
				llvm_put(a)
				llvm_put(c")")
			else:
				if (kind == 8): llvm_put(c" = call i32 @llvm.ctlz.i32(i32 ")
				else: llvm_put(c" = call i32 @llvm.cttz.i32(i32 ")
				llvm_put(a)
				llvm_put(c", i1 false)")
			llvm_put(c"\x0a")
			result = llvm_convert_op(c"zext", c"i32", bits, c"i64")
		arguments.free()
		return result
	if (op == 'N'):
		# new T: zeroed heap storage for one T
		retained_type* pointer = llvm_type(type)
		int target = llvm_class(pointer.target)
		if ((pointer.pointer_level != 1) || (pointer.target < 0) || ((target != llvm_class_word) && (target != llvm_class_struct))):
			llvm_error(id, c"allocation")
			return c"0"
		int bytes = llvm_type(pointer.target).size
		if ((pointer.pointer_level > 1) || (bytes < 1)): bytes = 8
		list[char*] size = list[char*]{llvm_number(bytes)}
		char* object = llvm_helper_call(id, c"__w_new_object", size)
		size.free()
		if (llvm_has_headers(pointer.target)): llvm_fix_headers(pointer.target, llvm_pointer(object))
		return object
	if (op == 'k'):
		# Host atomics at full word width (grammar/atomic_builtin.w).
		int kind = node.value
		if (kind == 7):
			llvm_put(c"  fence seq_cst\x0a")
			return c"0"
		list[char*] arguments = new list[char*]
		int arg = node.left
		while ((arg >= 0) && (llvm_failed == 0)):
			arguments.push(llvm_value(group, arg))
			retained_node argument
			retained_node_load(llvm_node_id(group, arg), &argument)
			arg = argument.next_arg
		int wanted = 2
		if ((kind == 5) || (kind == 8)): wanted = 1
		if (kind == 4): wanted = 3
		if ((arguments.length != wanted) || (kind == 2) || (kind == 3)):
			llvm_error_at(id, c"atomic intrinsic", llvm_number(kind))
			return c"0"
		char* address = llvm_pointer(arguments[0])
		char* order = c"seq_cst"
		if (kind == 5): order = c"acquire"
		if (kind == 6): order = c"release"
		if ((kind == 8) || (kind == 9)): order = c"monotonic"
		char* result = c"0"
		if ((kind == 6) || (kind == 9)):
			llvm_put(c"  store atomic i64 ")
			llvm_put(arguments[1])
			llvm_put(c", ptr ")
			llvm_put(address)
			llvm_put(c" ")
			llvm_put(order)
			llvm_put(c", align 8\x0a")
		else if ((kind == 5) || (kind == 8)):
			result = llvm_temp()
			llvm_put(c"  ")
			llvm_put(result)
			llvm_put(c" = load atomic i64, ptr ")
			llvm_put(address)
			llvm_put(c" ")
			llvm_put(order)
			llvm_put(c", align 8\x0a")
		else if (kind == 4):
			char* pair = llvm_temp()
			llvm_put(c"  ")
			llvm_put(pair)
			llvm_put(c" = cmpxchg ptr ")
			llvm_put(address)
			llvm_put(c", i64 ")
			llvm_put(arguments[1])
			llvm_put(c", i64 ")
			llvm_put(arguments[2])
			llvm_put(c" seq_cst seq_cst, align 8\x0a")
			result = llvm_temp()
			llvm_put(c"  ")
			llvm_put(result)
			llvm_put(c" = extractvalue { i64, i1 } ")
			llvm_put(pair)
			llvm_put(c", 0\x0a")
		else:
			result = llvm_temp()
			llvm_put(c"  ")
			llvm_put(result)
			llvm_put(c" = atomicrmw add ptr ")
			llvm_put(address)
			llvm_put(c", i64 ")
			llvm_put(arguments[1])
			llvm_put(c" seq_cst, align 8\x0a")
		arguments.free()
		return result
	if (op == 'D'):
		# new T(field: value, ...): zeroed heap storage from the runtime; a
		# T(field: value, ...) value is a zeroed temporary record.
		if (node.high == 0):
			if (type_class != llvm_class_struct):
				llvm_error(id, c"record literal")
				return c"0"
			return llvm_record_literal(group, id, &node)
		retained_type* pointer = llvm_type(type)
		# new int(): one zeroed scalar
		if ((pointer.pointer_level == 1) && (pointer.target >= 0) && (llvm_class(pointer.target) == llvm_class_word) && (node.left < 0)):
			list[char*] scalar = list[char*]{c"8"}
			char* cell = llvm_helper_call(id, c"__w_new_object", scalar)
			scalar.free()
			return cell
		if ((pointer.pointer_level != 1) || (pointer.target < 0) || (llvm_class(pointer.target) != llvm_class_struct)):
			llvm_error(id, c"record allocation")
			return c"0"
		retained_type* record = llvm_type(pointer.target)
		list[char*] size = list[char*]{llvm_number(record.size)}
		char* object = llvm_helper_call(id, c"__w_new_object", size)
		size.free()
		if (llvm_has_headers(pointer.target)): llvm_fix_headers(pointer.target, llvm_pointer(object))
		llvm_store_record_fields(group, id, &node, pointer.target, object)
		return object
	if ((op == 'P') || (op == 'y')):
		int helper = node.high
		if (op == 'y'): helper = node.value
		if ((op == 'y') && (helper == 21)): return llvm_length(group, id, &node)
		char* name = llvm_prelude_helper(helper)
		if ((op == 'P') && (node.left < 0)): name = c"__w_print_nl"
		if ((name == 0) || ((op == 'y') && (helper < 9))):
			llvm_error_at(id, c"builtin helper", llvm_number(helper))
			return c"0"
		list[char*] values = new list[char*]
		int arg = node.left
		while ((arg >= 0) && (llvm_failed == 0)):
			values.push(llvm_value(group, arg))
			retained_node argument
			retained_node_load(llvm_node_id(group, arg), &argument)
			arg = argument.next_arg
			if (op == 'P'): arg = -1
		char* result = c"0"
		if ((op == 'y') || (node.left >= 0)): result = llvm_helper_call(id, name, values)
		if ((op == 'P') && (node.value != 0) && (node.left >= 0)):
			values.free()
			values = new list[char*]
			llvm_helper_call(id, c"__w_print_nl", values)
		values.free()
		return result
	if ((op == 'C') || (op == 'F')):
		if ((op == 'C') && (node.binding < 0)):
			llvm_error(id, c"unbound call")
			return c"0"
		if ((type_class != llvm_class_word) && (type_class != llvm_class_void) && (type_class != llvm_class_struct) && (type_class != llvm_class_slice)):
			llvm_error(id, c"call result type")
			return c"0"
		return llvm_call(group, id, &node)
	if (op == '='):
		retained_node left
		retained_node_load(llvm_node_id(group, node.left), &left)
		retained_node right
		retained_node_load(llvm_node_id(group, node.right), &right)
		if (llvm_place(&left) == 0):
			llvm_error(id, c"assignment target")
			return c"0"
		char* address = llvm_address(group, node.left)
		char* value = c"0"
		if (node.value != 0):
			char* before = llvm_load(left.semantic_type, address)
			value = llvm_value(group, node.right)
			value = llvm_binary(id, node.value, llvm_unsigned_word(left.semantic_type) || llvm_unsigned_word(right.semantic_type), before, value)
		else: value = llvm_value(group, node.right)
		value = llvm_convert(id, value, right.semantic_type, left.semantic_type)
		llvm_store(id, left.semantic_type, value, address)
		return value
	if (op == 'U'):
		retained_node left
		retained_node_load(llvm_node_id(group, node.left), &left)
		if (llvm_place(&left) == 0):
			llvm_error(id, c"increment target")
			return c"0"
		char* address = llvm_address(group, node.left)
		char* before = llvm_load(left.semantic_type, address)
		char* value = llvm_binary(id, node.value, 0, before, c"1")
		llvm_store(id, left.semantic_type, value, address)
		return value
	if ((op == 'a') || (op == 'o')):
		int end = llvm_label_new()
		list[int] predecessors = new list[int]
		list[char*] conditions = new list[char*]
		int child = node.left
		while (child >= 0):
			char* value = llvm_bool(llvm_value(group, child))
			predecessors.push(llvm_block)
			conditions.push(value)
			retained_node part
			retained_node_load(llvm_node_id(group, child), &part)
			child = part.next_arg
			if (child >= 0):
				int next = llvm_label_new()
				if (op == 'a'): llvm_cond_branch(value, next, end)
				else: llvm_cond_branch(value, end, next)
				llvm_label(next)
			else: llvm_branch(end)
		llvm_label(end)
		char* merged = llvm_temp()
		llvm_put(c"  ")
		llvm_put(merged)
		llvm_put(c" = phi i1 ")
		for i in range(predecessors.length):
			if (i > 0): llvm_put(c", ")
			llvm_put(c"[ ")
			llvm_put(conditions[i])
			llvm_put(c", %b")
			llvm_put(llvm_number(predecessors[i]))
			llvm_put(c" ]")
		llvm_put(c"\x0a")
		predecessors.free()
		conditions.free()
		return llvm_extend(merged)
	if (op == '?'):
		int yes = llvm_label_new()
		int no = llvm_label_new()
		int end = llvm_label_new()
		llvm_cond_branch(llvm_bool(llvm_value(group, node.left)), yes, no)
		llvm_label(yes)
		char* a = llvm_value(group, node.right)
		int a_block = llvm_block
		llvm_branch(end)
		llvm_label(no)
		char* b = llvm_value(group, node.high)
		int b_block = llvm_block
		llvm_branch(end)
		llvm_label(end)
		char* merged = llvm_temp()
		llvm_put(c"  ")
		llvm_put(merged)
		llvm_put(c" = phi i64 [ ")
		llvm_put(a)
		llvm_put(c", %b")
		llvm_put(llvm_number(a_block))
		llvm_put(c" ], [ ")
		llvm_put(b)
		llvm_put(c", %b")
		llvm_put(llvm_number(b_block))
		llvm_put(c" ]\x0a")
		return merged
	if (op == 'K'):
		char* value = llvm_value(group, node.left)
		if (type_class != llvm_class_word):
			llvm_error(id, c"cast target")
			return c"0"
		if (llvm_is_bool(type)): return llvm_extend(llvm_bool(value))
		int width = llvm_width(type)
		retained_type* target = llvm_type(type)
		if ((width == 8) || (target.pointer_level > 0) || (strcmp(target.name, c"constant") == 0)): return value
		char* narrow = llvm_convert_op(c"trunc", c"i64", value, llvm_int_type(width))
		if (llvm_zero_extends(type)): return llvm_convert_op(c"zext", llvm_int_type(width), narrow, c"i64")
		return llvm_convert_op(c"sext", llvm_int_type(width), narrow, c"i64")
	if ((op == 'n') || (op == 'p') || (op == '~') || (op == '!') || (op == 'b')):
		char* value = llvm_value(group, node.left)
		if (op == 'n'): return llvm_instruction(c"sub", c"0", value)
		if (op == '~'): return llvm_instruction(c"xor", value, c"-1")
		if (op == '!'): return llvm_extend(llvm_instruction(c"icmp eq", value, c"0"))
		if (op == 'b'): return llvm_extend(llvm_bool(value))
		return value
	if ((node.left >= 0) && (node.right >= 0)):
		int is_unsigned = llvm_unsigned_operands(group, &node)
		retained_node left
		retained_node right
		retained_node_load(llvm_node_id(group, node.left), &left)
		retained_node_load(llvm_node_id(group, node.right), &right)
		char* a = llvm_value(group, node.left)
		char* b = llvm_value(group, node.right)
		# Two strings compare contents (grammar/equality_expr.w).
		if (((op == 0x94) || (op == 0x95)) && llvm_is_string(left.semantic_type) && llvm_is_string(right.semantic_type)):
			list[char*] operands = list[char*]{a, b}
			char* equal = llvm_helper_call(id, c"__w_string_equal", operands)
			operands.free()
			if (op == 0x94): return llvm_extend(llvm_instruction(c"icmp ne", equal, c"0"))
			return llvm_extend(llvm_instruction(c"icmp eq", equal, c"0"))
		return llvm_binary(id, op, is_unsigned, a, b)
	if ((op > 32) && (op < 127)):
		char* spelling = cast(char*, malloc(2))
		spelling[0] = op
		spelling[1] = 0
		llvm_error_at(id, c"expression form", spelling)
	else: llvm_error_at(id, c"expression form", llvm_number(op))
	return c"0"


char* llvm_group(int id):
	retained_node node
	retained_node_load(id, &node)
	return llvm_value(id, node.op)


int llvm_group_type(int id):
	retained_node node
	retained_node_load(id, &node)
	retained_node root
	retained_node_load(llvm_node_id(id, node.op), &root)
	return root.semantic_type


# --- statements --------------------------------------------------------------

# Zero a local's storage, and point a fixed array's header at its data.
void llvm_local_init(int binding):
	int type = retained_bindings[binding].type
	char* address = llvm_name(c"%v", binding)
	int c = llvm_class(type)
	if ((c == llvm_class_struct) || (c == llvm_class_array)):
		llvm_memory_call(c"llvm.memset.p0.i64", address, 0, llvm_storage(type))
		llvm_fix_headers(type, address)
	else: llvm_store_width(8, c"0", address)


int llvm_starts_with_word(int id):
	retained_node node
	retained_node_load(id, &node)
	retained_source* source = retained_sources[node.source]
	if ((node.start < 0) || (node.start >= source.length)): return 1
	int c = source.bytes[node.start]
	return ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z')) || (c == '_') || (c >= 128)


void llvm_statement(int id);


# --- control flow and records by value ---------------------------------------
# switch, legacy and scoped defer, goto, and records passed, returned and
# copied by value. The production front end already expands every defer:
# each exit carries its 'deferred exit' statements, in run order, after the
# exit's own value, so lowering them is ordinary statement lowering.

# The record type the current function returns through its hidden first
# argument %ret (the caller's buffer), or -1.
int llvm_return_record = -1
# label name -> block, for the current function's goto targets
map[char*, int] llvm_labels


int llvm_parameter_ok(int type):
	int c = llvm_class(type)
	return (c == llvm_class_word) || (c == llvm_class_struct) || (c == llvm_class_slice)


# Fixed arrays keep a {data, length} header naming their own storage, also
# inside records.
int llvm_has_headers(int type):
	if (type < 0): return 0
	retained_type* t = llvm_type(type)
	if (t.pointer_level > 0): return 0
	if (t.kind == 6): return 1
	if ((t.kind == 7) || (t.kind == 8) || (t.kind == 4) || (t.kind == 2)): return 0
	for i in range(t.fields.length):
		if (llvm_has_headers(t.fields[i].type)): return 1
	return 0


# Storage for one value in the function's entry block.
char* llvm_entry_slot(int bytes):
	llvm_register = llvm_register + 1
	char* name = llvm_name(c"%r", llvm_register)
	string_append(llvm_entry, c"  ")
	string_append(llvm_entry, name)
	string_append(llvm_entry, c" = alloca [")
	string_append_int(llvm_entry, bytes)
	string_append(llvm_entry, c" x i8], align 8\x0a")
	return name


char* llvm_record_buffer(int type):
	return llvm_entry_slot(llvm_storage(type))


# Point every header in the storage at base back at its own data, as the
# native backend does after each record copy and allocation.
void llvm_fix_headers(int type, char* base):
	if (llvm_has_headers(type) == 0): return
	retained_type* t = llvm_type(type)
	if (t.kind != 6):
		for i in range(t.fields.length):
			retained_field* field = t.fields[i]
			llvm_fix_headers(field.type, llvm_offset(base, llvm_number(field.offset)))
		return
	# Arrays of elements with headers are outside the subset (llvm_class_of).
	llvm_store_width(8, llvm_address_value(llvm_offset(base, c"16")), base)
	llvm_store_width(8, llvm_number(t.array_length), llvm_offset(base, c"8"))


# A record value is its storage's address; passing one by value copies it.
char* llvm_record_copy(int type, char* value):
	char* buffer = llvm_record_buffer(type)
	llvm_memory_call(c"llvm.memcpy.p0.p0.i64", buffer, llvm_pointer(value), llvm_type(type).size)
	llvm_fix_headers(type, buffer)
	return llvm_address_value(buffer)


# A scalar field of a call's record result (grammar/ast_expression.w marks
# it with a negative high).
char* llvm_temporary_field(int group, retained_node* node):
	char* address = llvm_offset(llvm_pointer(llvm_value(group, node.left)), llvm_number(node.value))
	int c = llvm_class(node.semantic_type)
	if ((c == llvm_class_struct) || (c == llvm_class_array)): return llvm_address_value(address)
	if (c == llvm_class_slice): return llvm_load(-1, address)
	return llvm_load(node.semantic_type, address)


# Field initializers of T(...) and new T(...), in source order.
void llvm_store_record_fields(int group, int id, retained_node* node, int record_type, char* object):
	retained_type* record = llvm_type(record_type)
	int entry = node.left
	while ((entry >= 0) && (llvm_failed == 0)):
		retained_node field
		retained_node_load(llvm_node_id(group, entry), &field)
		retained_node argument
		retained_node_load(llvm_node_id(group, field.left), &argument)
		if ((field.value < 0) || (field.value >= record.fields.length)):
			llvm_error(id, c"record field initializer")
			return
		retained_field* target = record.fields[field.value]
		char* value = llvm_convert(id, llvm_value(group, field.left), argument.semantic_type, target.type)
		llvm_store(id, target.type, value, llvm_offset(llvm_pointer(object), llvm_number(target.offset)))
		entry = field.next_arg


# T(field: value, ...): a zeroed temporary record.
char* llvm_record_literal(int group, int id, retained_node* node):
	char* buffer = llvm_record_buffer(node.semantic_type)
	llvm_memory_call(c"llvm.memset.p0.i64", buffer, 0, llvm_storage(node.semantic_type))
	llvm_fix_headers(node.semantic_type, buffer)
	char* object = llvm_address_value(buffer)
	llvm_store_record_fields(group, id, node, node.semantic_type, object)
	return object


# len(x) (prelude helper 21): strlen for a C string; containers and
# buffers (string, slice, decayed fixed array) keep their length one word
# into their header (grammar/print_builtin.w's prelude_len_expr).
char* llvm_length(int group, int id, retained_node* node):
	if (node.left < 0):
		llvm_error(id, c"len without an argument")
		return c"0"
	retained_node argument
	retained_node_load(llvm_node_id(group, node.left), &argument)
	char* value = llvm_value(group, node.left)
	if (llvm_is_char_pointer(argument.semantic_type)):
		list[char*] operands = list[char*]{value}
		char* length = llvm_helper_call(id, c"strlen", operands)
		operands.free()
		return length
	return llvm_load(-1, llvm_offset(llvm_pointer(value), c"8"))


# An array or slice value (its header's address) used as a pointer.
int llvm_decays(int from, int to):
	int c = llvm_class(from)
	if ((c != llvm_class_array) && (c != llvm_class_slice)): return 0
	return (to >= 0) && (llvm_type(to).pointer_level > 0)


# Arguments of a call through a function value convert to the parameter
# types of its fn type (decays and bool normalization, as direct calls).
void llvm_convert_indirect(int group, int id, retained_node* node, list[char*] values, list[int] types):
	retained_node callee
	retained_node_load(llvm_node_id(group, node.left), &callee)
	if (callee.semantic_type < 0): return
	retained_type* t = llvm_type(callee.semantic_type)
	if ((t.pointer_level > 0) && (t.kind != 2) && (t.target >= 0)): t = llvm_type(t.target)
	if (t.kind != 2): return
	for i in range(values.length):
		if (i < t.parameters.length): values[i] = llvm_convert(id, values[i], types[i], t.parameters[i])


# Run an exit's 'deferred exit' children (after its value, if any).
void llvm_deferred_exits(int id):
	int child = llvm_first[id]
	while (child >= 0):
		if ((retained_node_kind(child) == retained_statement) && (strcmp(retained_node_at(child).name, c"deferred exit") == 0)): llvm_statement(child)
		child = llvm_next[child]


int llvm_text_is(int type, char* name):
	return (type >= 0) && llvm_named(llvm_type(type), name)


# One case value against the scrutinee (emit_switch_case_compare): text
# contents for a string or C-string scrutinee, else word equality.
char* llvm_case_matches(int id, char* scrutinee, int scrutinee_type, int group):
	char* value = llvm_group(group)
	int type = llvm_group_type(group)
	int literal = llvm_text_is(type, c"string value")
	char* helper = 0
	if (llvm_is_string(scrutinee_type) && (llvm_is_string(type) || literal)): helper = c"__w_string_equal"
	else if (llvm_is_char_pointer(scrutinee_type) && (llvm_is_char_pointer(type) || literal)):
		helper = c"__w_cstr_equal"
		# A string literal case compares its NUL-terminated bytes.
		if (literal): value = llvm_load(-1, llvm_pointer(value))
	if (helper == 0): return llvm_instruction(c"icmp eq", scrutinee, value)
	list[char*] operands = list[char*]{scrutinee, value}
	char* equal = llvm_helper_call(id, helper, operands)
	operands.free()
	return llvm_instruction(c"icmp ne", equal, c"0")


void llvm_switch(int id):
	int entry_reachable = llvm_reachable
	int scrutinee = llvm_first[id]
	if ((scrutinee < 0) || (retained_node_kind(scrutinee) != retained_expression_group)):
		llvm_error(id, c"switch statement shape")
		return
	char* value = llvm_group(scrutinee)
	int type = llvm_group_type(scrutinee)
	int end = llvm_label_new()
	int previous_break = llvm_break_label
	llvm_break_label = end
	int clause = llvm_next[scrutinee]
	while ((clause >= 0) && (llvm_failed == 0)):
		char* name = retained_node_at(clause).name
		if (strcmp(name, c"default") == 0):
			if (llvm_first[clause] >= 0): llvm_statement(llvm_first[clause])
			llvm_branch(end)
		else if (strcmp(name, c"case") == 0):
			int body = -1
			list[int] values = new list[int]
			int child = llvm_first[clause]
			while (child >= 0):
				if (retained_node_kind(child) == retained_expression_group): values.push(child)
				else if (body < 0): body = child
				child = llvm_next[child]
			if ((body < 0) || (values.length == 0)):
				llvm_error(clause, c"switch case shape")
				values.free()
				return
			int matched = llvm_label_new()
			int next = llvm_label_new()
			for k in range(values.length):
				char* hit = llvm_case_matches(clause, value, type, values[k])
				if (k + 1 < values.length):
					int more = llvm_label_new()
					llvm_cond_branch(hit, matched, more)
					llvm_label(more)
				else: llvm_cond_branch(hit, matched, next)
			values.free()
			llvm_label(matched)
			llvm_statement(body)
			llvm_branch(end)
			llvm_label(next)
		else: llvm_error_at(clause, c"switch clause", name)
		clause = llvm_next[clause]
	llvm_branch(end)
	llvm_label(end)
	llvm_break_label = previous_break
	llvm_reachable = entry_reachable


int llvm_label_for(char* name):
	if ((name in llvm_labels) == 0): llvm_labels[name] = llvm_label_new()
	return llvm_labels[name]


int llvm_identifier_byte(int c):
	return ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z')) || ((c >= '0') && (c <= '9')) || (c == '_') || (c >= 128)


# A label statement is a childless statement spelled 'name:'.
int llvm_is_label(int id, retained_node* node):
	if (llvm_first[id] >= 0): return 0
	retained_source* source = retained_sources[node.source]
	int length = strlen(node.name)
	if ((length == 0) || (node.start < 0) || (node.start + length >= source.length)): return 0
	for i in range(length):
		if (source.bytes[node.start + i] != node.name[i]): return 0
	return source.bytes[node.start + length] == ':'


# goto's target: the identifier after the keyword in the source.
char* llvm_goto_target(retained_node* node):
	retained_source* source = retained_sources[node.source]
	int at = node.start + 4
	while ((at < source.length) && ((source.bytes[at] == ' ') || (source.bytes[at] == 9))): at = at + 1
	int end = at
	while ((end < source.length) && llvm_identifier_byte(source.bytes[end] & 255)): end = end + 1
	if (end == at): return 0
	string_builder* text = string_new()
	for i in range(at, end): string_append_char(text, source.bytes[i])
	char* name = retained_intern(text.data)
	string_free(text)
	return name


void llvm_return(int id):
	int group = llvm_first[id]
	if ((group >= 0) && (retained_node_kind(group) != retained_expression_group)): group = -1
	int return_type = retained_bindings[llvm_function].return_type
	int return_class = llvm_class(return_type)
	char* value = c"0"
	if (group >= 0):
		value = llvm_group(group)
		if (return_class == llvm_class_word): value = llvm_convert(id, value, llvm_group_type(group), return_type)
		# The record result is in the caller's buffer before defers run.
		if (return_class == llvm_class_struct):
			llvm_store(id, return_type, value, llvm_pointer(c"%ret"))
			value = c"%ret"
	else if (return_class == llvm_class_struct): value = c"%ret"
	else if (return_class != llvm_class_void):
		llvm_error(id, c"return without a value")
		return
	llvm_deferred_exits(id)
	llvm_put(c"  ret i64 ")
	llvm_put(value)
	llvm_put(c"\x0a")
	llvm_terminated = 1
	llvm_reachable = 0


# The control-flow statements of this section; 0 when id is another kind.
int llvm_control_statement(int id, retained_node* node):
	char* name = node.name
	if (strcmp(name, c"return") == 0):
		llvm_return(id)
		return 1
	if ((strcmp(name, c"break") == 0) || (strcmp(name, c"continue") == 0)):
		int target = llvm_break_label
		if (strcmp(name, c"continue") == 0): target = llvm_continue_label
		llvm_deferred_exits(id)
		if (target < 0): llvm_error(id, c"jump outside a loop")
		else: llvm_branch(target)
		llvm_reachable = 0
		return 1
	if (strcmp(name, c"switch") == 0):
		llvm_switch(id)
		return 1
	# Registration only: the front end expands each exit's defers.
	if (((strcmp(name, c"defer") == 0) || (strcmp(name, c"scoped defer") == 0)) && (llvm_first[id] < 0)): return 1
	if (strcmp(name, c"deferred exit") == 0):
		int child = llvm_first[id]
		if ((child < 0) || (retained_node_kind(child) != retained_expression_group)): llvm_error(id, c"deferred statement shape")
		else: llvm_group(child)
		return 1
	if ((strcmp(name, c"goto") == 0) && (llvm_first[id] < 0)):
		char* target = llvm_goto_target(node)
		if (target == 0):
			llvm_error(id, c"goto target")
			return 1
		llvm_branch(llvm_label_for(target))
		llvm_reachable = 0
		return 1
	# name := value declares name after its initializer.
	int first = llvm_first[id]
	if ((first >= 0) && (retained_node_kind(first) == retained_expression_group) && (llvm_next[first] >= 0) && (retained_node_kind(llvm_next[first]) == retained_local) && (llvm_next[llvm_next[first]] < 0)):
		retained_node local
		retained_node_load(llvm_next[first], &local)
		if ((local.binding < 0) || ((local.binding in llvm_locals) == 0)):
			llvm_error(id, c"local declaration")
			return 1
		int type = retained_bindings[local.binding].type
		char* value = llvm_convert(id, llvm_group(first), llvm_group_type(first), type)
		llvm_store(id, type, value, llvm_name(c"%v", local.binding))
		return 1
	if (llvm_is_label(id, node)):
		int label = llvm_label_for(name)
		llvm_branch(label)
		llvm_label(label)
		llvm_reachable = 1
		return 1
	return 0


void llvm_range(int id):
	int entry_reachable = llvm_reachable
	int variable = -1
	int body = -1
	list[int] arguments = new list[int]
	int child = llvm_first[id]
	while (child >= 0):
		int kind = retained_node_kind(child)
		if ((kind == retained_local) && (variable < 0)):
			retained_node local
			retained_node_load(child, &local)
			variable = local.binding
		else if (kind == retained_expression_group): arguments.push(child)
		else if ((kind == retained_statement) && (body < 0)): body = child
		else: llvm_error(id, c"for statement shape")
		child = llvm_next[child]
	if ((variable < 0) || (body < 0) || (arguments.length < 1) || (arguments.length > 3) || ((variable in llvm_locals) == 0)):
		llvm_error(id, c"for statement shape")
		arguments.free()
		return
	list[char*] values = new list[char*]
	for i in range(arguments.length): values.push(llvm_group(arguments[i]))
	int type = retained_bindings[variable].type
	char* address = llvm_name(c"%v", variable)
	char* end = values[0]
	char* step = c"1"
	if (values.length >= 2):
		end = values[1]
		llvm_store(id, type, values[0], address)
	else: llvm_store(id, type, c"0", address)
	if (values.length == 3): step = values[2]
	int is_unsigned = llvm_unsigned_word(type) || llvm_unsigned_word(llvm_group_type(arguments[arguments.length - 1]))
	int head = llvm_label_new()
	int yes = llvm_label_new()
	int next = llvm_label_new()
	int done = llvm_label_new()
	llvm_branch(head)
	llvm_label(head)
	char* compare = c"icmp slt"
	if (is_unsigned): compare = c"icmp ult"
	llvm_cond_branch(llvm_instruction(compare, llvm_load(type, address), end), yes, done)
	llvm_label(yes)
	int previous_break = llvm_break_label
	int previous_continue = llvm_continue_label
	llvm_break_label = done
	llvm_continue_label = next
	llvm_statement(body)
	llvm_break_label = previous_break
	llvm_continue_label = previous_continue
	llvm_branch(next)
	llvm_label(next)
	llvm_store(id, type, llvm_instruction(c"add", llvm_load(type, address), step), address)
	llvm_branch(head)
	llvm_label(done)
	llvm_reachable = entry_reachable
	arguments.free()
	values.free()


void llvm_statement(int id):
	if (llvm_failed): return
	retained_node node
	retained_node_load(id, &node)
	# Keep lowering (and checking) unreachable code in a fresh block.
	if (llvm_terminated): llvm_label(llvm_label_new())
	if ((strcmp(node.name, c":") == 0) || (strcmp(node.name, c"{") == 0) || (strcmp(node.name, c"unsafe block") == 0)):
		int child = llvm_first[id]
		while (child >= 0):
			llvm_statement(child)
			child = llvm_next[child]
		return
	if (strcmp(node.name, c"pass") == 0): return
	if (llvm_control_statement(id, &node)): return
	if (strcmp(node.name, c"for range") == 0):
		llvm_range(id)
		return
	if (strcmp(node.name, c"while") == 0):
		int entry_reachable = llvm_reachable
		int body = -1
		int condition = -1
		int child = llvm_first[id]
		while (child >= 0):
			if (retained_node_kind(child) == retained_expression_group): condition = child
			else if (body < 0): body = child
			else: llvm_error(id, c"while statement shape")
			child = llvm_next[child]
		if ((body < 0) || (condition < 0)):
			llvm_error(id, c"while statement shape")
			return
		int head = llvm_label_new()
		int yes = llvm_label_new()
		int end = llvm_label_new()
		llvm_branch(head)
		llvm_label(head)
		llvm_cond_branch(llvm_bool(llvm_group(condition)), yes, end)
		llvm_label(yes)
		int previous_break = llvm_break_label
		int previous_continue = llvm_continue_label
		llvm_break_label = end
		llvm_continue_label = head
		llvm_statement(body)
		llvm_break_label = previous_break
		llvm_continue_label = previous_continue
		llvm_branch(head)
		llvm_label(end)
		llvm_reachable = entry_reachable
		return
	if (strcmp(node.name, c"if") == 0):
		int entry_reachable = llvm_reachable
		int end_reachable = 0
		int has_else = 0
		int end = llvm_label_new()
		int child = llvm_first[id]
		while (child >= 0):
			llvm_reachable = entry_reachable
			if (retained_node_kind(child) == retained_expression_group):
				int yes = llvm_label_new()
				int no = llvm_label_new()
				llvm_cond_branch(llvm_bool(llvm_group(child)), yes, no)
				child = llvm_next[child]
				if ((child < 0) || (retained_node_kind(child) != retained_statement)):
					llvm_error(id, c"if statement shape")
					return
				llvm_label(yes)
				llvm_statement(child)
				end_reachable = end_reachable || llvm_reachable
				llvm_branch(end)
				llvm_label(no)
			else:
				has_else = 1
				llvm_statement(child)
				end_reachable = end_reachable || llvm_reachable
				llvm_branch(end)
			child = llvm_next[child]
		llvm_branch(end)
		llvm_label(end)
		llvm_reachable = end_reachable || (entry_reachable && (has_else == 0))
		return
	int child = llvm_first[id]
	if ((child >= 0) && (retained_node_kind(child) == retained_local)):
		retained_node local
		retained_node_load(child, &local)
		child = llvm_next[child]
		if ((local.binding < 0) || ((local.binding in llvm_locals) == 0)):
			llvm_error(id, c"local declaration")
			return
		if (child < 0):
			llvm_local_init(local.binding)
			return
		if ((retained_node_kind(child) != retained_expression_group) || (llvm_next[child] >= 0)):
			llvm_error(id, c"multiple local declaration")
			return
		int type = retained_bindings[local.binding].type
		if (llvm_class(type) == llvm_class_array):
			llvm_error(id, c"array initializer")
			return
		char* value = llvm_convert(id, llvm_group(child), llvm_group_type(child), type)
		llvm_store(id, type, value, llvm_name(c"%v", local.binding))
		return
	if ((child >= 0) && (retained_node_kind(child) == retained_expression_group) && (llvm_next[child] < 0)):
		retained_node expression
		retained_node_load(child, &expression)
		# Only expression statements use this catch-all: a keyword statement
		# (assert, defer, yield, ...) has an expression starting after it.
		if ((expression.start != node.start) && llvm_starts_with_word(id)):
			llvm_error_at(id, c"statement", node.name)
			return
		llvm_group(child)
		return
	llvm_error_at(id, c"statement", node.name)


int llvm_function_has_body(int id):
	int child = llvm_first[id]
	while (child >= 0):
		if (retained_node_kind(child) == retained_statement): return 1
		child = llvm_next[child]
	return 0


void llvm_emit_body(int id);


void llvm_truncate(string_builder* text, int length):
	text.length = length
	text.data[length] = 0


# A library function outside the subset becomes a trap if it ever runs, with
# a warning naming why; the input module's own functions must lower.
void llvm_emit_function(int id):
	int code_mark = llvm_code.length
	int data_mark = llvm_data.length
	int queue_mark = llvm_queue.length
	int globals_mark = llvm_global_order.length
	int constants_mark = llvm_constants
	llvm_emit_body(id)
	retained_node node
	retained_node_load(id, &node)
	if ((llvm_failed == 0) || (node.source == llvm_input)): return
	llvm_truncate(llvm_code, code_mark)
	llvm_truncate(llvm_data, data_mark)
	llvm_constants = constants_mark
	while (llvm_queue.length > queue_mark):
		retained_node queued
		retained_node_load(llvm_queue.pop(), &queued)
		int linkage = retained_bindings[queued.binding].linkage
		llvm_queued.remove(linkage)
		llvm_reached_from.remove(linkage)
	while (llvm_global_order.length > globals_mark): llvm_globals_used.remove(llvm_global_order.pop())
	llvm_failed = 0
	# One line per trap: the reason's first line, without the call path.
	char* text = llvm_message.data
	int i = 0
	while ((text[i] != 0) && (text[i] != 10)): i = i + 1
	llvm_truncate(llvm_message, i)
	string_append(llvm_message, c"\x0a")
	string_builder* prefix = string_new()
	string_append(prefix, c"wllvm: note: ")
	string_append(prefix, node.name)
	string_append(prefix, c" traps if called: ")
	llvm_report(prefix.data)
	string_free(prefix)
	llvm_uses_trap = 1
	retained_binding* function = retained_bindings[node.binding]
	string_append(llvm_code, c"define internal i64 ")
	string_append(llvm_code, llvm_name(c"@w", function.linkage))
	string_append(llvm_code, c"(")
	int hidden = llvm_class(function.return_type) == llvm_class_struct
	if (hidden): string_append(llvm_code, c"i64")
	for i in range(function.parameters.length):
		if ((i > 0) || hidden): string_append(llvm_code, c", ")
		string_append(llvm_code, c"i64")
	string_append(llvm_code, c") {\x0aentry:\x0a  call void @llvm.trap()\x0a  unreachable\x0a}\x0a\x0a")
	llvm_stubs = llvm_stubs + 1


void llvm_emit_body(int id):
	retained_node node
	retained_node_load(id, &node)
	llvm_function = node.binding
	llvm_function_node = id
	retained_binding* function = retained_bindings[node.binding]
	llvm_register = 0
	llvm_label_counter = 0
	llvm_terminated = 0
	llvm_reachable = 1
	llvm_expression_depth = 0
	llvm_locals = new map[int, int]
	llvm_labels = new map[char*, int]
	llvm_entry = string_new()
	llvm_out = string_new()
	int return_class = llvm_class(function.return_type)
	if ((return_class != llvm_class_word) && (return_class != llvm_class_void) && (return_class != llvm_class_struct) && (return_class != llvm_class_slice)):
		llvm_error_at(id, c"return type of", node.name)
	for p in range(function.parameters.length):
		if (llvm_parameter_ok(function.parameters[p]) == 0): llvm_error_at(id, c"parameter type of", node.name)
	string_append(llvm_code, c"define internal i64 ")
	string_append(llvm_code, llvm_name(c"@w", function.linkage))
	string_append(llvm_code, c"(")
	int child = llvm_first[id]
	int argument = 0
	# A record result goes to the caller's buffer, a hidden first argument.
	llvm_return_record = -1
	if (return_class == llvm_class_struct):
		llvm_return_record = function.return_type
		string_append(llvm_code, c"i64 %ret")
		argument = 1
	# Record parameters arrive as the address of the caller's copy.
	map[int, int] record_parameters = new map[int, int]
	while ((child >= 0) && (retained_node_kind(child) == retained_local)):
		retained_node parameter
		retained_node_load(child, &parameter)
		if (argument > 0): string_append(llvm_code, c", ")
		string_append(llvm_code, c"i64 ")
		string_append(llvm_code, llvm_name(c"%a", parameter.binding))
		if ((parameter.binding >= 0) && (llvm_class(retained_bindings[parameter.binding].type) == llvm_class_struct)): record_parameters[parameter.binding] = 1
		argument = argument + 1
		child = llvm_next[child]
	string_append(llvm_code, c") {\x0aentry:\x0a")
	int local = -1
	if (id in llvm_owned_first): local = llvm_owned_first[id]
	while (local >= 0):
		int type = retained_bindings[local].type
		if ((llvm_class(type) == llvm_class_none) || (llvm_class(type) == llvm_class_void)):
			if (type >= 0): llvm_error_at(id, c"local type", retained_types[type].name)
			else: llvm_error(id, c"local type")
		llvm_locals[local] = 1
		string_append(llvm_entry, c"  ")
		string_append(llvm_entry, llvm_name(c"%v", local))
		if (local in record_parameters):
			string_append(llvm_entry, c" = inttoptr i64 ")
			string_append(llvm_entry, llvm_name(c"%a", local))
			string_append(llvm_entry, c" to ptr\x0a")
		else if (llvm_storage(type) == 8): string_append(llvm_entry, c" = alloca i64, align 8\x0a")
		else:
			string_append(llvm_entry, c" = alloca [")
			string_append_int(llvm_entry, llvm_storage(type))
			string_append(llvm_entry, c" x i8], align 8\x0a")
		local = llvm_owned_next[local]
	llvm_label(0)
	int parameter_id = llvm_first[id]
	while ((parameter_id >= 0) && (retained_node_kind(parameter_id) == retained_local)):
		retained_node parameter
		retained_node_load(parameter_id, &parameter)
		if ((parameter.binding in llvm_locals) && ((parameter.binding in record_parameters) == 0)): llvm_store_width(8, llvm_name(c"%a", parameter.binding), llvm_name(c"%v", parameter.binding))
		parameter_id = llvm_next[parameter_id]
	while (child >= 0):
		llvm_statement(child)
		child = llvm_next[child]
	# Falling off the end returns 0 (a void function's only exit).
	if ((llvm_terminated == 0) && (llvm_return_record >= 0)): llvm_put(c"  ret i64 %ret\x0a")
	else if (llvm_terminated == 0): llvm_put(c"  ret i64 0\x0a")
	string_append(llvm_code, llvm_entry.data)
	string_append(llvm_code, c"  br label %b0\x0a")
	string_append(llvm_code, llvm_out.data)
	string_append(llvm_code, c"}\x0a\x0a")
	string_free(llvm_entry)
	string_free(llvm_out)
	llvm_locals.free()
	llvm_labels.free()
	record_parameters.free()


# --- globals and the entry point -------------------------------------------

# Offsets and lengths of every fixed-array header in a value of type.
void llvm_header_layout(int type, int base, list[int] offsets, list[int] lengths):
	if (llvm_has_headers(type) == 0): return
	retained_type* t = llvm_type(type)
	if (t.kind != 6):
		for i in range(t.fields.length): llvm_header_layout(t.fields[i].type, base + t.fields[i].offset, offsets, lengths)
		return
	offsets.push(base)
	lengths.push(t.array_length)


# A zeroed record global whose array headers name their own storage.
void llvm_global_headers(string_builder* text, int type, int linkage):
	list[int] offsets = new list[int]
	list[int] lengths = new list[int]
	llvm_header_layout(type, 0, offsets, lengths)
	string_builder* shape = string_new()
	string_builder* value = string_new()
	int at = 0
	for i in range(offsets.length):
		string_append(shape, c"[")
		string_append_int(shape, offsets[i] - at)
		string_append(shape, c" x i8], ptr, i64, ")
		string_append(value, c"[")
		string_append_int(value, offsets[i] - at)
		string_append(value, c" x i8] zeroinitializer, ptr getelementptr (i8, ptr ")
		string_append(value, llvm_name(c"@g", linkage))
		string_append(value, c", i64 ")
		string_append_int(value, offsets[i] + 16)
		string_append(value, c"), i64 ")
		string_append_int(value, lengths[i])
		string_append(value, c", ")
		at = offsets[i] + 16
	string_append(shape, c"[")
	string_append_int(shape, llvm_storage(type) - at)
	string_append(shape, c" x i8]")
	string_append(value, c"[")
	string_append_int(value, llvm_storage(type) - at)
	string_append(value, c" x i8] zeroinitializer")
	string_append(text, c"<{ ")
	string_append(text, shape.data)
	string_append(text, c" }> <{ ")
	string_append(text, value.data)
	string_append(text, c" }>")
	string_free(shape)
	string_free(value)
	offsets.free()
	lengths.free()


void llvm_emit_global(int linkage):
	int id = llvm_global_decls[linkage]
	retained_node node
	retained_node_load(id, &node)
	int type = retained_bindings[node.binding].type
	int c = llvm_class(type)
	retained_initializer* init = node.initializer
	# Constants an initializer names are written before the global's line.
	char* value = c"i64 0"
	string_builder* text = string_new()
	if (c == llvm_class_word):
		if (init == 0): string_append(text, c"i64 0")
		else if (init.kind == retained_initializer_constant):
			string_append(text, c"i64 ")
			string_append_int(text, init.value)
		else if (init.kind == retained_initializer_string):
			string_append(text, c"ptr ")
			string_append(text, llvm_string_constant(init.bytes, init.length))
		else if ((init.kind == retained_initializer_global) && (init.binding >= 0) && (retained_bindings[init.binding].linkage in llvm_global_decls)):
			string_append(text, c"ptr ")
			string_append(text, llvm_global_symbol(retained_bindings[init.binding].linkage))
		else if ((init.kind == retained_initializer_function) && (init.binding >= 0) && (retained_bindings[init.binding].linkage in llvm_functions)):
			string_append(text, c"ptr ")
			string_append(text, llvm_function_symbol(retained_bindings[init.binding].linkage))
		else: llvm_error_at(id, c"initializer of global", node.name)
	else if ((c == llvm_class_struct) && (init == 0) && llvm_has_headers(type)): llvm_global_headers(text, type, linkage)
	else if ((c == llvm_class_struct) && (init == 0)):
		string_append(text, c"[")
		string_append_int(text, llvm_storage(type))
		string_append(text, c" x i8] zeroinitializer")
	else if ((c == llvm_class_array) && (init == 0)):
		int data = llvm_storage(type) - 16
		string_append(text, c"<{ ptr, i64, [")
		string_append_int(text, data)
		string_append(text, c" x i8] }> <{ ptr getelementptr (i8, ptr ")
		string_append(text, llvm_name(c"@g", linkage))
		string_append(text, c", i64 16), i64 ")
		string_append_int(text, llvm_type(type).array_length)
		string_append(text, c", [")
		string_append_int(text, data)
		string_append(text, c" x i8] zeroinitializer }>")
	else: llvm_error_at(id, c"type of global", node.name)
	if (text.length > 0): value = text.data
	string_append(llvm_data, llvm_name(c"@g", linkage))
	string_append(llvm_data, c" = internal global ")
	string_append(llvm_data, value)
	string_append(llvm_data, c", align 8\x0a")
	string_free(text)


# Freestanding x86-64 Linux entry: no C runtime. _start passes the initial
# stack's argc and argv to the W entry, then exits with its result.
void llvm_emit_entry(int entry, int arguments):
	string_append(llvm_code, c"module asm \".globl _start\"\x0amodule asm \"_start:\"\x0a")
	string_append(llvm_code, c"module asm \"  xorl %ebp, %ebp\"\x0amodule asm \"  movq (%rsp), %rdi\"\x0a")
	string_append(llvm_code, c"module asm \"  leaq 8(%rsp), %rsi\"\x0amodule asm \"  andq $-16, %rsp\"\x0a")
	string_append(llvm_code, c"module asm \"  callq __wllvm_start\"\x0amodule asm \"  ud2\"\x0a\x0a")
	string_append(llvm_code, c"define void @__wllvm_start(i64 %argc, i64 %argv) noreturn nounwind {\x0aentry:\x0a  %result = call i64 ")
	string_append(llvm_code, llvm_name(c"@w", entry))
	if (arguments == 2): string_append(llvm_code, c"(i64 %argc, i64 %argv)\x0a")
	else: string_append(llvm_code, c"()\x0a")
	string_append(llvm_code, c"  %exit = call i64 asm sideeffect \"syscall\", \"={rax},{rax},{rdi},~{rcx},~{r11},~{memory}\"(i64 231, i64 %result)\x0a")
	string_append(llvm_code, c"  unreachable\x0a}\x0a\x0a")


# LLVM lowers large copies and fills to these C names; without a C library
# the module defines them, as byte loops LLVM must not turn back into calls.
void llvm_emit_memory_runtime():
	string_append(llvm_code, c"define ptr @memset(ptr %d, i32 %c, i64 %n) #0 {\x0aentry:\x0a  %b = trunc i32 %c to i8\x0a  br label %head\x0ahead:\x0a  %i = phi i64 [ 0, %entry ], [ %j, %body ]\x0a  %more = icmp ult i64 %i, %n\x0a  br i1 %more, label %body, label %done\x0abody:\x0a  %p = getelementptr i8, ptr %d, i64 %i\x0a  store volatile i8 %b, ptr %p\x0a  %j = add i64 %i, 1\x0a  br label %head\x0adone:\x0a  ret ptr %d\x0a}\x0a\x0a")
	string_append(llvm_code, c"define ptr @memcpy(ptr %d, ptr %s, i64 %n) #0 {\x0aentry:\x0a  br label %head\x0ahead:\x0a  %i = phi i64 [ 0, %entry ], [ %j, %body ]\x0a  %more = icmp ult i64 %i, %n\x0a  br i1 %more, label %body, label %done\x0abody:\x0a  %q = getelementptr i8, ptr %s, i64 %i\x0a  %v = load volatile i8, ptr %q\x0a  %p = getelementptr i8, ptr %d, i64 %i\x0a  store volatile i8 %v, ptr %p\x0a  %j = add i64 %i, 1\x0a  br label %head\x0adone:\x0a  ret ptr %d\x0a}\x0a\x0a")
	string_append(llvm_code, c"define ptr @memmove(ptr %d, ptr %s, i64 %n) #0 {\x0aentry:\x0a  %di = ptrtoint ptr %d to i64\x0a  %si = ptrtoint ptr %s to i64\x0a  %back = icmp ugt i64 %di, %si\x0a  br i1 %back, label %bhead, label %fhead\x0afhead:\x0a  %i = phi i64 [ 0, %entry ], [ %j, %fbody ]\x0a  %fmore = icmp ult i64 %i, %n\x0a  br i1 %fmore, label %fbody, label %done\x0afbody:\x0a  %q = getelementptr i8, ptr %s, i64 %i\x0a  %v = load volatile i8, ptr %q\x0a  %p = getelementptr i8, ptr %d, i64 %i\x0a  store volatile i8 %v, ptr %p\x0a  %j = add i64 %i, 1\x0a  br label %fhead\x0abhead:\x0a  %k = phi i64 [ %n, %entry ], [ %k1, %bbody ]\x0a  %bmore = icmp ugt i64 %k, 0\x0a  br i1 %bmore, label %bbody, label %done\x0abbody:\x0a  %k1 = sub i64 %k, 1\x0a  %bq = getelementptr i8, ptr %s, i64 %k1\x0a  %bv = load volatile i8, ptr %bq\x0a  %bp = getelementptr i8, ptr %d, i64 %k1\x0a  store volatile i8 %bv, ptr %bp\x0a  br label %bhead\x0adone:\x0a  ret ptr %d\x0a}\x0a\x0a")
	string_append(llvm_code, c"attributes #0 = { nounwind \"no-builtins\" }\x0a\x0a")


void llvm_free_tables():
	llvm_report(0)
	string_free(llvm_message)
	string_free(llvm_data)
	string_free(llvm_code)
	llvm_functions.free()
	llvm_function_names.free()
	llvm_queued.free()
	llvm_queue.free()
	llvm_reached_from.free()
	llvm_global_decls.free()
	llvm_globals_used.free()
	llvm_global_order.free()
	llvm_owned_first.free()
	llvm_owned_next.free()
	llvm_first.free()
	llvm_next.free()


# Called only after a successful x64 production compile with semantic
# retention enabled. Returns 1 on success; unsupported input leaves the
# output untouched. All IR is validated before anything is written.
int llvm_emit(char* filename, char* output_path):
	llvm_failed = 0
	llvm_constants = 0
	llvm_uses_memory = 0
	llvm_uses_trap = 0
	llvm_uses_bits = 0
	llvm_stubs = 0
	llvm_data = string_new()
	llvm_code = string_new()
	llvm_message = string_new()
	llvm_out = llvm_code
	llvm_functions = new map[int, int]
	llvm_function_names = new map[char*, int]
	llvm_queued = new map[int, int]
	llvm_queue = new list[int]
	llvm_reached_from = new map[int, int]
	llvm_function_node = -1
	llvm_global_decls = new map[int, int]
	llvm_globals_used = new map[int, int]
	llvm_global_order = new list[int]
	llvm_owned_first = new map[int, int]
	llvm_owned_next = new list[int]
	llvm_first = new list[int]
	llvm_next = new list[int]
	int input = -1
	for i in range(retained_sources.length):
		if (strcmp(retained_sources[i].path, filename) == 0): input = i
	llvm_input = input
	if (input < 0):
		wstream* err = stderr_writer()
		stream_write_line(err, c"wllvm: input is absent from the retained semantic forest")
		stream_flush(err)
		llvm_free_tables()
		return 0
	int count = retained_node_count()
	for i in range(count):
		llvm_first.push(-1)
		llvm_next.push(-1)
	# Descending insertion preserves production order even when a parent
	# declaration is appended after the body it adopts.
	for i in range(count):
		int id = count - i - 1
		retained_node node
		retained_node_load(id, &node)
		if (node.parent >= 0):
			llvm_next[id] = llvm_first[node.parent]
			llvm_first[node.parent] = id
	for i in range(retained_bindings.length):
		llvm_owned_next.push(-1)
	for i in range(retained_bindings.length):
		int binding = retained_bindings.length - i - 1
		int owner = retained_bindings[binding].owner
		if (owner >= 0):
			if (owner in llvm_owned_first): llvm_owned_next[binding] = llvm_owned_first[owner]
			llvm_owned_first[owner] = binding
	int main_node = -1
	int start_node = -1
	for id in range(count):
		int kind = retained_node_kind(id)
		if ((kind != retained_function) && (kind != retained_declaration)): continue
		retained_node node
		retained_node_load(id, &node)
		if (node.binding < 0): continue
		int linkage = retained_bindings[node.binding].linkage
		if ((kind == retained_declaration) && (node.result_type != 0) && (strcmp(node.result_type, c"global") == 0)): llvm_global_decls[linkage] = id
		if ((kind == retained_function) && llvm_function_has_body(id)):
			llvm_functions[linkage] = id
			if ((node.name in llvm_function_names) == 0): llvm_function_names[node.name] = linkage
			if (strcmp(node.name, c"_main") == 0): start_node = id
			if ((node.source == input) && (strcmp(node.name, c"main") == 0)): main_node = id
	if (main_node < 0):
		llvm_error(retained_sources[input].root, c"program without a main function")
		llvm_free_tables()
		return 0
	# The production entry is lib.lib's _main when the program has one.
	int entry = main_node
	if (start_node >= 0): entry = start_node
	retained_node entry_node
	retained_node_load(entry, &entry_node)
	retained_binding* entry_binding = retained_bindings[entry_node.binding]
	if ((entry_binding.parameters.length != 0) && (entry_binding.parameters.length != 2)): llvm_error(entry, c"entry point parameters")
	llvm_function_symbol(entry_binding.linkage)
	# Every function of the input module lowers, called or not: its own
	# code must fit the subset. Library code lowers only where reached.
	for id in range(count):
		if (retained_node_kind(id) != retained_function): continue
		retained_node node
		retained_node_load(id, &node)
		if ((node.source == input) && (node.binding >= 0) && llvm_function_has_body(id)): llvm_function_symbol(retained_bindings[node.binding].linkage)
	int next = 0
	while ((next < llvm_queue.length) && (llvm_failed == 0)):
		llvm_emit_function(llvm_queue[next])
		next = next + 1
	llvm_out = llvm_code
	llvm_function_node = -1
	int emitted = 0
	while ((emitted < llvm_global_order.length) && (llvm_failed == 0)):
		llvm_emit_global(llvm_global_order[emitted])
		emitted = emitted + 1
	# Globals can name functions that were not called yet.
	while ((next < llvm_queue.length) && (llvm_failed == 0)):
		llvm_emit_function(llvm_queue[next])
		next = next + 1
	while ((emitted < llvm_global_order.length) && (llvm_failed == 0)):
		llvm_emit_global(llvm_global_order[emitted])
		emitted = emitted + 1
	int success = 0
	if (llvm_failed == 0):
		llvm_emit_entry(entry_binding.linkage, entry_binding.parameters.length)
		if (llvm_uses_memory): llvm_emit_memory_runtime()
		string_builder* module = string_new()
		string_append(module, c"; W LLVM offload: production retained AST, signed 64-bit words, freestanding x86-64 Linux\x0a")
		string_append(module, c"target triple = \"x86_64-unknown-linux-gnu\"\x0a\x0a")
		if (llvm_uses_trap): string_append(module, c"declare void @llvm.trap() cold noreturn nounwind\x0a")
		if (llvm_uses_bits):
			string_append(module, c"declare i32 @llvm.fshl.i32(i32, i32, i32)\x0adeclare i32 @llvm.fshr.i32(i32, i32, i32)\x0a")
			string_append(module, c"declare i32 @llvm.ctpop.i32(i32)\x0adeclare i32 @llvm.ctlz.i32(i32, i1)\x0adeclare i32 @llvm.cttz.i32(i32, i1)\x0a")
		if (llvm_uses_memory): string_append(module, c"declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)\x0adeclare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)\x0a")
		string_append(module, c"\x0a")
		string_append(module, llvm_data.data)
		string_append(module, c"\x0a")
		string_append(module, llvm_code.data)
		success = file_write_text(output_path, module.data)
		string_free(module)
		if (success == 0):
			wstream* err = stderr_writer()
			stream_write_cstr(err, c"wllvm: cannot write output: ")
			stream_write_line(err, output_path)
			stream_flush(err)
	llvm_free_tables()
	return success
