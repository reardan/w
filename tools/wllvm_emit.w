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
# Target: 0 x86-64 Linux (default), 1 AArch64 Linux. Set by the driver
# before llvm_emit; the front end ran for the same architecture.
int llvm_arm64


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


# Float kinds of a value: 1 for float32 (float, float32, their value type,
# and the storage-only float16/bfloat16, whose values are float32), 2 for
# float64, 0 for anything else.
int llvm_float_kind_of(retained_type* t):
	if (t.pointer_level > 0): return 0
	char* n = t.name
	if ((strcmp(n, c"float32") == 0) || (strcmp(n, c"float") == 0) || (strcmp(n, c"float32 value") == 0)): return 1
	if ((strcmp(n, c"float16") == 0) || (strcmp(n, c"bfloat16") == 0)): return 1
	if ((strcmp(n, c"float64") == 0) || (strcmp(n, c"float64 value") == 0)): return 2
	return 0


# 1 for float16, 2 for bfloat16: 2-byte storage that loads widen to a
# float32 value and stores narrow (docs/projects/float.md).
int llvm_narrow_float(int type):
	if (type < 0): return 0
	retained_type* t = llvm_type(type)
	if (t.pointer_level > 0): return 0
	if (strcmp(t.name, c"float16") == 0): return 1
	if (strcmp(t.name, c"bfloat16") == 0): return 2
	return 0


int llvm_float_kind(int type):
	if (type < 0): return 0
	return llvm_float_kind_of(llvm_type(type))


int llvm_class(int type);


int llvm_class_of(retained_type* t):
	# Checked pointers (kinds 21-23, 26, 27, 29) are words; checked slices
	# (24, 30) and borrowed records (25, 28) are records by fields below.
	if (t.pointer_level > 0): return llvm_class_word
	if (t.kind == 6): return llvm_class_array
	# slices (7) and slice values (9) are one word: a {data, length} descriptor's address
	if ((t.kind == 7) || (t.kind == 9)): return llvm_class_word
	# string handles, enums and function values are one word
	if ((t.kind == 8) || (t.kind == 4) || (t.kind == 2)): return llvm_class_word
	# list (12), map (10) and set (11) handles (see "containers" below)
	if ((t.kind == 10) || (t.kind == 11) || (t.kind == 12)): return llvm_class_word
	int float_kind = llvm_float_kind_of(t)
	if ((float_kind == 1) || (float_kind == 2)): return llvm_class_word
	if (t.fields.length > 0):
		for i in range(t.fields.length):
			# c_import's layout padding (__ci_bytes_N) is never accessed:
			# record copies move whole records.
			if (starts_with(llvm_type(t.fields[i].type).name, c"__ci_bytes_")): continue
			int field = llvm_class(t.fields[i].type)
			# fixed-array fields keep an inline header (see "arrays inside records")
			if ((field == llvm_class_none) || (field == llvm_class_void)): return llvm_class_none
		return llvm_class_struct
	char* n = t.name
	if (strcmp(n, c"void") == 0): return llvm_class_void
	# A C bit-field reads and writes as a word (see "C bit-fields").
	if (starts_with(n, c"__ci_bit_field_") && (t.origin >= 0) && ci_is_bit_field_access(t.origin)):
		if (ci_bit_field_unit_size(t.origin) > 0): return llvm_class_word
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


# Strings, slices and slice values: a word naming a {data, length}
# descriptor, the layout a fixed array's header shares.
int llvm_is_buffer(int type):
	if (type < 0): return 0
	retained_type* t = llvm_type(type)
	return (t.pointer_level == 0) && ((t.kind == 7) || (t.kind == 8) || (t.kind == 9))


# Any word type, for llvm_decays: the tail of a variadic call has no
# declared type, and an array or slice there decays as to one.
const int llvm_word_type = -2


# An array, slice or slice value converted to a pointer (or cast to a
# word integer) decays to its data pointer, the descriptor's first word
# (type_decays_to_pointer, coerce_explicit).
int llvm_decays(int from, int to):
	if ((from < 0) || ((to < 0) && (to != llvm_word_type))): return 0
	retained_type* f = llvm_type(from)
	if ((f.pointer_level != 0) || ((f.kind != 6) && (f.kind != 7) && (f.kind != 9))): return 0
	if (to == llvm_word_type): return 1
	retained_type* t = llvm_type(to)
	return (t.pointer_level > 0) || (t.kind == 0)


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


char* llvm_narrow_widen(char* bits, int narrow);
char* llvm_narrow_bits(char* value, int narrow);


# ---- C bit-fields --------------------------------------------------------
# c_import gives each bit-field member its own access type, whose side table
# (libs/extras/c_import/importer.w) holds the storage unit's size, the
# field's bit offset in it, its width and signedness; a member access names
# the unit's address. Reads and writes reproduce grammar/promote.w's
# bit_field_promote and bit_field_assign_store on the zero-extended unit.

void llvm_store_width(int width, char* value, char* address);


# The type-table index of a bit-field access type, or -1.
int llvm_bit_field(int type):
	if (type < 0): return -1
	retained_type* t = llvm_type(type)
	if ((t.pointer_level != 0) || (t.origin < 0) || (starts_with(t.name, c"__ci_bit_field_") == 0)): return -1
	if (ci_is_bit_field_access(t.origin) == 0): return -1
	return t.origin


char* llvm_load_unit(int size, char* address):
	char* t = llvm_int_type(size)
	char* result = llvm_temp()
	llvm_put(c"  ")
	llvm_put(result)
	llvm_put(c" = load ")
	llvm_put(t)
	llvm_put(c", ptr ")
	llvm_put(address)
	llvm_put(c", align 1\x0a")
	if (size == 8): return result
	return llvm_convert_op(c"zext", t, result, c"i64")


# The field's value as a word: sign-extended, or shifted down and masked.
char* llvm_bit_field_read(int field, char* address):
	int width = ci_bit_field_width(field)
	int shift = ci_bit_field_bit_offset(field)
	char* unit = llvm_load_unit(ci_bit_field_unit_size(field), address)
	if (ci_bit_field_is_signed(field)):
		if (64 - shift - width > 0): unit = llvm_instruction(c"shl", unit, llvm_number(64 - shift - width))
		if (64 - width > 0): unit = llvm_instruction(c"ashr", unit, llvm_number(64 - width))
		return unit
	if (shift > 0): unit = llvm_instruction(c"lshr", unit, llvm_number(shift))
	if (width < 64): unit = llvm_instruction(c"and", unit, llvm_number((1 << width) - 1))
	return unit


# Read-modify-write of the field's bits in its unit.
void llvm_bit_field_write(int field, char* value, char* address):
	int width = ci_bit_field_width(field)
	int shift = ci_bit_field_bit_offset(field)
	int size = ci_bit_field_unit_size(field)
	if (width >= 64):
		llvm_store_width(8, value, address)
		return
	int mask = ((1 << width) - 1) << shift
	char* bits = llvm_instruction(c"and", llvm_instruction(c"shl", value, llvm_number(shift)), llvm_number(mask))
	char* rest = llvm_instruction(c"and", llvm_load_unit(size, address), llvm_number(~mask))
	llvm_store_width(size, llvm_instruction(c"or", rest, bits), address)


char* llvm_load(int type, char* address):
	int field = llvm_bit_field(type)
	if (field >= 0): return llvm_bit_field_read(field, address)
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
	if (llvm_narrow_float(type)): return llvm_narrow_widen(llvm_convert_op(c"zext", t, result, c"i64"), llvm_narrow_float(type))
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


# x64 W division faults with #DE (SIGFPE, like idiv): a guarded invalid
# division divides by zero the same way instead of executing ud2. AArch64
# division does not fault, so there it is an ordinary trap.
void llvm_divide_trap_if(char* condition):
	if (llvm_arm64):
		llvm_trap_if(condition)
		return
	int trap = llvm_label_new()
	int valid = llvm_label_new()
	llvm_cond_branch(condition, trap, valid)
	llvm_label(trap)
	llvm_put(c"  call void asm sideeffect \"xorl %ecx, %ecx\\0Adivl %ecx\", \"~{eax},~{ecx},~{edx},~{dirflag},~{fpsr},~{flags}\"()\x0a  unreachable\x0a")
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


char* llvm_function_label(int linkage);


char* llvm_function_symbol(int linkage):
	if ((linkage in llvm_queued) == 0):
		llvm_queued[linkage] = 1
		llvm_queue.push(llvm_functions[linkage])
		llvm_reached_from[linkage] = llvm_function_node
	return llvm_function_label(linkage)


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


# --- floats ------------------------------------------------------------------
# A float value travels in its i64 word as the bit pattern, a float32 in the
# low 32 bits, as the native backend keeps one in rax between SSE operations
# (grammar/binary_op.w, grammar/promote.w). Operations bitcast around LLVM
# float and double arithmetic.

int llvm_uses_float_conversion


char* llvm_float_type(int kind):
	if (kind == 2): return c"double"
	return c"float"


char* llvm_float_from_word(char* value, int kind):
	if (kind == 2): return llvm_convert_op(c"bitcast", c"i64", value, c"double")
	char* low = llvm_convert_op(c"trunc", c"i64", value, c"i32")
	return llvm_convert_op(c"bitcast", c"i32", low, c"float")


char* llvm_float_to_word(char* value, int kind):
	if (kind == 2): return llvm_convert_op(c"bitcast", c"double", value, c"i64")
	char* bits = llvm_convert_op(c"bitcast", c"float", value, c"i32")
	return llvm_convert_op(c"zext", c"i32", bits, c"i64")


# A word of float kind got (0 for a signed integer word) as an LLVM float of
# kind want: cvtsi2ss/cvtsi2sd take the whole signed word, cvtss2sd and
# cvtsd2ss round to nearest like fpext and fptrunc.
char* llvm_float_operand(char* value, int got, int want):
	char* type = llvm_float_type(want)
	if (got == 0): return llvm_convert_op(c"sitofp", c"i64", value, type)
	char* x = llvm_float_from_word(value, got)
	if (got == want): return x
	if (want == 2): return llvm_convert_op(c"fpext", c"float", x, c"double")
	return llvm_convert_op(c"fptrunc", c"double", x, c"float")


char* llvm_float_select(char* condition, char* yes, char* no);


# Convert a word between float kinds (0: signed integer word), as coerce()
# does. Float to integer truncates toward zero; fptosi is poison out of
# range, so the saturating llvm.fptosi.sat carries the conversion. That is
# AArch64's fcvtzs exactly (NaN gives 0). x86's cvttss2si/cvttsd2si instead
# return the integer indefinite 0x8000000000000000 for NaN and for every
# value outside the i64 range, which differs from saturation only at or
# above 2^63 and for NaN: fcmp uge catches both.
char* llvm_float_coerce(char* value, int got, int want):
	if (got == want): return value
	if (want != 0): return llvm_float_to_word(llvm_float_operand(value, got, want), want)
	llvm_uses_float_conversion = 1
	char* x = llvm_float_from_word(value, got)
	char* type = llvm_float_type(got)
	char* result = llvm_temp()
	llvm_put(c"  ")
	llvm_put(result)
	if (got == 2): llvm_put(c" = call i64 @llvm.fptosi.sat.i64.f64(double ")
	else: llvm_put(c" = call i64 @llvm.fptosi.sat.i64.f32(float ")
	llvm_put(x)
	llvm_put(c")\x0a")
	if (llvm_arm64): return result
	# 0x43e0000000000000 is 2^63 (LLVM spells float constants as doubles).
	char* high = llvm_op(c"fcmp uge", type, x, c"0x43E0000000000000")
	return llvm_float_select(high, c"-9223372036854775808", result)


char* llvm_float_select(char* condition, char* yes, char* no):
	char* result = llvm_temp()
	llvm_put(c"  ")
	llvm_put(result)
	llvm_put(c" = select i1 ")
	llvm_put(condition)
	llvm_put(c", i64 ")
	llvm_put(yes)
	llvm_put(c", i64 ")
	llvm_put(no)
	llvm_put(c"\x0a")
	return result


# A float32 word's float16 bits (vcvtps2ph on x86-64 and fcvt on AArch64:
# nearest-even, exactly the native conversions) or bfloat16 bits (code_generator/bfloat.w's integer
# rounding: nearest-even, NaNs keep sign and payload and turn quiet).
char* llvm_narrow_bits(char* value, int narrow):
	if ((narrow == 1) && llvm_arm64):
		char* half = llvm_convert_op(c"fptrunc", c"float", llvm_float_from_word(value, 1), c"half")
		return llvm_convert_op(c"zext", c"i16", llvm_convert_op(c"bitcast", c"half", half, c"i16"), c"i64")
	if (narrow == 1):
		char* single = llvm_float_from_word(value, 1)
		char* vector = llvm_temp()
		llvm_put(c"  ")
		llvm_put(vector)
		llvm_put(c" = insertelement <4 x float> undef, float ")
		llvm_put(single)
		llvm_put(c", i32 0\x0a")
		char* half = llvm_temp()
		llvm_put(c"  ")
		llvm_put(half)
		llvm_put(c" = call <8 x i16> asm \"vcvtps2ph $$0, $1, $0\", \"=x,x\"(<4 x float> ")
		llvm_put(vector)
		llvm_put(c")\x0a")
		char* bits = llvm_temp()
		llvm_put(c"  ")
		llvm_put(bits)
		llvm_put(c" = extractelement <8 x i16> ")
		llvm_put(half)
		llvm_put(c", i32 0\x0a")
		return llvm_convert_op(c"zext", c"i16", bits, c"i64")
	char* x = llvm_convert_op(c"trunc", c"i64", value, c"i32")
	char* magnitude = llvm_op(c"and", c"i32", x, c"2147483647")
	char* nan = llvm_op(c"icmp ugt", c"i32", magnitude, c"2139095040")
	char* quiet = llvm_op(c"or", c"i32", llvm_op(c"lshr", c"i32", x, c"16"), c"64")
	char* odd = llvm_op(c"and", c"i32", llvm_op(c"lshr", c"i32", x, c"16"), c"1")
	char* rounded = llvm_op(c"lshr", c"i32", llvm_op(c"add", c"i32", llvm_op(c"add", c"i32", x, odd), c"32767"), c"16")
	char* result = llvm_temp()
	llvm_put(c"  ")
	llvm_put(result)
	llvm_put(c" = select i1 ")
	llvm_put(nan)
	llvm_put(c", i32 ")
	llvm_put(quiet)
	llvm_put(c", i32 ")
	llvm_put(rounded)
	llvm_put(c"\x0a")
	return llvm_convert_op(c"zext", c"i32", result, c"i64")


# The float32 word of float16 (vcvtph2ps, fcvt) or bfloat16 (shift) bits.
char* llvm_narrow_widen(char* bits, int narrow):
	if (narrow == 2): return llvm_instruction(c"shl", bits, c"16")
	char* half = llvm_convert_op(c"trunc", c"i64", bits, c"i16")
	if (llvm_arm64): return llvm_float_to_word(llvm_convert_op(c"fpext", c"half", llvm_convert_op(c"bitcast", c"i16", half, c"half"), c"float"), 1)
	char* vector = llvm_temp()
	llvm_put(c"  ")
	llvm_put(vector)
	llvm_put(c" = insertelement <8 x i16> undef, i16 ")
	llvm_put(half)
	llvm_put(c", i32 0\x0a")
	char* single = llvm_temp()
	llvm_put(c"  ")
	llvm_put(single)
	llvm_put(c" = call <4 x float> asm \"vcvtph2ps $1, $0\", \"=x,x\"(<8 x i16> ")
	llvm_put(vector)
	llvm_put(c")\x0a")
	char* x = llvm_temp()
	llvm_put(c"  ")
	llvm_put(x)
	llvm_put(c" = extractelement <4 x float> ")
	llvm_put(single)
	llvm_put(c", i32 0\x0a")
	return llvm_float_to_word(x, 1)


# A float32 word rounded to float16/bfloat16 precision.
char* llvm_narrow_round(char* value, int narrow):
	return llvm_narrow_widen(llvm_narrow_bits(value, narrow), narrow)


# The word of a hardware arithmetic result. LLVM leaves a NaN result's sign
# and payload unspecified (and constant folding picks 0x7ff8...), so spell
# out the native rule; folded and run-time results then both match the
# native backend bit for bit. SSE returns the first NaN operand quieted,
# else the second, else the default NaN 0xfff8.../0xffc00000 for an
# invalid operation. AArch64 (FPCR.DN clear, as Linux runs it) prefers a
# signaling NaN, the first operand's before the second's, then a quiet
# NaN in the same order, quieting the one it returns, and its default NaN
# is positive: 0x7ff8.../0x7fc00000.
char* llvm_float_nan_result(char* x, char* y, char* result, int kind):
	char* type = llvm_float_type(kind)
	char* quiet = c"4194304"
	char* default_nan = c"4290772992"
	if (llvm_arm64): default_nan = c"2143289344"
	if (kind == 2):
		quiet = c"2251799813685248"
		default_nan = c"-2251799813685248"
		if (llvm_arm64): default_nan = c"9221120237041090560"
	char* word = llvm_float_to_word(result, kind)
	char* x_nan = llvm_op(c"fcmp uno", type, x, x)
	char* y_nan = llvm_op(c"fcmp uno", type, y, y)
	char* r_nan = llvm_op(c"fcmp uno", type, result, result)
	char* x_bits = llvm_float_to_word(x, kind)
	char* y_bits = llvm_float_to_word(y, kind)
	char* x_quiet = llvm_instruction(c"or", x_bits, quiet)
	char* y_quiet = llvm_instruction(c"or", y_bits, quiet)
	word = llvm_float_select(r_nan, default_nan, word)
	word = llvm_float_select(y_nan, y_quiet, word)
	word = llvm_float_select(x_nan, x_quiet, word)
	if (llvm_arm64 == 0): return word
	# A NaN whose quiet bit is clear is signaling.
	char* y_signaling = llvm_op(c"and", c"i1", y_nan, llvm_op(c"icmp eq", c"i64", llvm_instruction(c"and", y_bits, quiet), c"0"))
	char* x_signaling = llvm_op(c"and", c"i1", x_nan, llvm_op(c"icmp eq", c"i64", llvm_instruction(c"and", x_bits, quiet), c"0"))
	word = llvm_float_select(y_signaling, y_quiet, word)
	return llvm_float_select(x_signaling, x_quiet, word)


# A binary operator with a float operand (grammar/binary_op.w): both sides
# at the wider float kind. On x86 float == is ucomis + sete, true when
# unordered, and != false then; AArch64's fcmp + cset eq/ne gives the IEEE
# answers (== false, != true). The ordered comparisons are false on NaN on
# both: < and <= swap their operands into seta/setae, which AArch64 reads
# as gt/ge.
# Returns the result word and sets *kind to the result's float kind (0 for
# a comparison's bool).
char* llvm_float_binary(int id, int op, char* a, int a_type, char* b, int b_type, int* result_kind):
	int left = llvm_float_kind(a_type)
	int right = llvm_float_kind(b_type)
	int kind = left
	if (right > kind): kind = right
	*result_kind = 0
	char* instruction = 0
	if (op == '+'): instruction = c"fadd"
	else if (op == '-'): instruction = c"fsub"
	else if (op == '*'): instruction = c"fmul"
	else if (op == '/'): instruction = c"fdiv"
	else if ((op == 0x94) && llvm_arm64): instruction = c"fcmp oeq"
	else if ((op == 0x95) && llvm_arm64): instruction = c"fcmp une"
	else if (op == 0x94): instruction = c"fcmp ueq"
	else if (op == 0x95): instruction = c"fcmp one"
	else if (op == 0x9c): instruction = c"fcmp olt"
	else if (op == 0x9d): instruction = c"fcmp oge"
	else if (op == 0x9e): instruction = c"fcmp ole"
	else if (op == 0x9f): instruction = c"fcmp ogt"
	if (instruction == 0):
		llvm_error(id, c"float operator")
		return c"0"
	char* type = llvm_float_type(kind)
	char* x = llvm_float_operand(a, left, kind)
	char* y = llvm_float_operand(b, right, kind)
	char* result = llvm_op(instruction, type, x, y)
	if ((op >= 0x94) && (op <= 0x9f)): return llvm_extend(result)
	*result_kind = kind
	return llvm_float_nan_result(x, y, result, kind)


# A float literal's retained bits: the high half and the low 32 bits.
char* llvm_float_literal(retained_node* node):
	int low = node.literal_value & ((1 << 32) - 1)
	return llvm_number((node.literal_high << 32) | low)


# Unary minus flips the sign bit (xor eax / btc rax in grammar/unary_expression.w).
char* llvm_float_negate(char* value, int kind):
	if (kind == 2): return llvm_instruction(c"xor", value, c"-9223372036854775808")
	return llvm_instruction(c"xor", value, c"2147483648")


# --- expressions -------------------------------------------------------------

int llvm_node_id(int group, int operand):
	return group + 1 + operand


char* llvm_value(int group, int operand);
char* llvm_address(int group, int operand);
int llvm_is_checked_slice(int type);
# containers (defined below the statements)
int llvm_operand_type(int group, int operand);
int llvm_container_op(int op);
char* llvm_container_expression(int group, int id, retained_node* node);
char* llvm_list_element(int group, int id, retained_node* node);
char* llvm_map_read(int group, int id, retained_node* node);
char* llvm_it_slot(int id);
int llvm_container_prelude_helper(int op, int helper);
char* llvm_container_prelude(int group, int id, retained_node* node);
void llvm_container_for(int id);
# slices, parallel assignment and enum_name (defined after the containers)
char* llvm_slice_range(int group, int id, retained_node* node);
char* llvm_parallel_assign(int group, int id, retained_node* node);
char* llvm_enum_name(int group, int id, retained_node* node);
# generators (defined after the slices)
int llvm_generator_self
int llvm_uses_gen_switch
char* llvm_generator_create(int group, int id, retained_node* node);
char* llvm_generator_switch(int id, list[char*] values);
void llvm_generator_begin(int id);
void llvm_generator_finish(int id);
void llvm_generator_yield(int id);
void llvm_generator_free_loops(int id);
void llvm_generator_loop(char* container, int open);
void llvm_generator_emit_runtime();
# arrays inside records (defined after the generators)
void llvm_init_array_fields(int type, char* address);
int llvm_global_record_headers(int linkage, int type, string_builder* text);


# Bool stores and arguments hold 0 or 1; a C string becomes a string value
# through the runtime's str_from_cstr, exactly as the native coercion.
char* llvm_convert(int id, char* value, int from, int to):
	if (llvm_is_bool(to)): return llvm_extend(llvm_bool(value))
	int want_float = llvm_float_kind(to)
	int got_float = llvm_float_kind(from)
	# A float16/bfloat16 value is a float32 already rounded to the type.
	int narrow = llvm_narrow_float(to)
	if (narrow && (narrow != llvm_narrow_float(from)) && (from >= 0)):
		if ((got_float != 0) || (llvm_type(from).pointer_level == 0)): return llvm_narrow_round(llvm_float_coerce(value, got_float, 1), narrow)
	if ((want_float != got_float) && (to >= 0) && (from >= 0) && ((llvm_type(to).pointer_level == 0) || (want_float != 0))): return llvm_float_coerce(value, got_float, want_float)
	# A string literal or f-string value decays to its data pointer where a
	# char* is wanted (type_decays_to_pointer).
	if (llvm_is_char_pointer(to) && (from >= 0) && llvm_named(retained_types[from], c"string value")): return llvm_load(-1, llvm_pointer(value))
	if (llvm_decays(from, to) && (llvm_type(to).pointer_level > 0)): return llvm_load(-1, llvm_pointer(value))
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
	return value


# Store value (already an i64 word, or a struct's address) into a place.
void llvm_store(int id, int type, char* value, char* address):
	int field = llvm_bit_field(type)
	if (field >= 0):
		llvm_bit_field_write(field, value, address)
		return
	int c = llvm_class(type)
	if (c == llvm_class_struct):
		llvm_memory_call(c"llvm.memcpy.p0.p0.i64", address, llvm_pointer(value), llvm_type(type).size)
		llvm_init_array_fields(type, address)
		return
	if (c != llvm_class_word):
		llvm_error(id, c"assignment of this type")
		return
	if (llvm_narrow_float(type)): value = llvm_narrow_bits(value, llvm_narrow_float(type))
	llvm_store_width(llvm_width(type), value, address)


char* llvm_import_address(int binding);


int llvm_place(retained_node* node):
	int op = node.op
	if ((op == 'd') || (op == 'i') || (op == 'I') || (op == 'B') || (op == 'j') || (op == 134)): return 1
	if (op == '.'): return node.high >= 0
	if (op == 'v'): return (node.binding >= 0) && ((node.binding in llvm_locals) || (retained_bindings[node.binding].linkage in llvm_global_decls) || (llvm_import_address(node.binding) != 0))
	return 0


int llvm_is_thread_local(int linkage);
char* llvm_tls_address(int id, int linkage);


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
			if ((linkage in llvm_global_decls) && llvm_is_thread_local(linkage)): return llvm_tls_address(id, linkage)
			if (linkage in llvm_global_decls): return llvm_global_symbol(linkage)
			char* imported = llvm_import_address(node.binding)
			if (imported != 0): return imported
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
	if (op == 'j'): return llvm_list_element(group, id, &node)
	if (op == 134): return llvm_it_slot(id)
	# A record-valued m[key] names its value slot.
	if (((op == 'm') || (op == 'q')) && (llvm_class(node.semantic_type) == llvm_class_struct)): return llvm_pointer(llvm_map_read(group, id, &node))
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
		else if (llvm_is_buffer(left.semantic_type) || llvm_is_checked_slice(left.semantic_type)):
			# A checked slice is the {data, length} pair itself (a record).
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
		llvm_divide_trap_if(invalid)
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


# --- symbols, line tables and runtime stubs ----------------------------------
# Functions keep their W names as ELF symbols: lib/stack_trace.w reads them
# from the mapped image, and its walk ends at the frame named main. A name
# defined twice, or one the module runtime reserves, gets a ".<linkage>"
# suffix. Statements leave line markers that become !dbg locations, so the
# DWARF 2 line table the native trace reader parses maps code to W lines.

map[char*, int] llvm_symbol_owner
map[int, char*] llvm_symbols
string_builder* llvm_meta
int llvm_meta_next
map[int, int] llvm_meta_files
map[int, int] llvm_meta_lines
int llvm_meta_scope
# 1 once lib/stack_trace.w code is emitted: every frame must then survive
# optimization (noinline) for traces to match native.
int llvm_traces
map[char*, int] llvm_runtime_used


int llvm_symbol_reserved(char* name):
	if (starts_with(name, c"__wllvm_") || starts_with(name, c"llvm.")): return 1
	return (strcmp(name, c"memset") == 0) || (strcmp(name, c"memcpy") == 0) || (strcmp(name, c"memmove") == 0) || (strcmp(name, c"_start") == 0) || (strcmp(name, c"__w_test_main") == 0)


void llvm_symbol_claim(int linkage, char* name):
	if (llvm_symbol_reserved(name) || (name in llvm_symbol_owner)): return
	llvm_symbol_owner[name] = linkage


# Quoted LLVM names and metadata strings spell other bytes as \XX.
void llvm_quoted_text(string_builder* text, char* name):
	char* hex = c"0123456789ABCDEF"
	int i = 0
	while (name[i] != 0):
		int c = name[i] & 255
		if ((c < 32) || (c > 126) || (c == 34) || (c == 92)):
			string_append_char(text, 92)
			string_append_char(text, hex[c >> 4])
			string_append_char(text, hex[c & 15])
		else: string_append_char(text, c)
		i = i + 1


char* llvm_function_label(int linkage):
	if (linkage in llvm_symbols): return llvm_symbols[linkage]
	retained_node node
	retained_node_load(llvm_functions[linkage], &node)
	string_builder* text = string_new()
	string_append(text, c"@\"")
	llvm_quoted_text(text, node.name)
	if (((node.name in llvm_symbol_owner) == 0) || (llvm_symbol_owner[node.name] != linkage)):
		string_append(text, c".")
		string_append_int(text, linkage)
	string_append(text, c"\"")
	char* result = retained_intern(text.data)
	string_free(text)
	llvm_symbols[linkage] = result
	return result


int llvm_debug_file(int source):
	if (source in llvm_meta_files): return llvm_meta_files[source]
	int id = llvm_meta_next
	llvm_meta_next = id + 1
	llvm_meta_files[source] = id
	string_append(llvm_meta, c"!")
	string_append_int(llvm_meta, id)
	string_append(llvm_meta, c" = !DIFile(filename: \"")
	llvm_quoted_text(llvm_meta, retained_sources[source].path)
	string_append(llvm_meta, c"\", directory: \"\")\x0a")
	return id


# A function's DISubprogram; it scopes the locations of the body that follows.
int llvm_debug_function(retained_node* node):
	int file = llvm_debug_file(node.source)
	int id = llvm_meta_next
	llvm_meta_next = id + 1
	string_append(llvm_meta, c"!")
	string_append_int(llvm_meta, id)
	string_append(llvm_meta, c" = distinct !DISubprogram(name: \"")
	llvm_quoted_text(llvm_meta, node.name)
	string_append(llvm_meta, c"\", scope: !")
	string_append_int(llvm_meta, file)
	string_append(llvm_meta, c", file: !")
	string_append_int(llvm_meta, file)
	string_append(llvm_meta, c", line: ")
	string_append_int(llvm_meta, node.line)
	string_append(llvm_meta, c", type: !3, scopeLine: ")
	string_append_int(llvm_meta, node.line)
	string_append(llvm_meta, c", spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)\x0a")
	llvm_meta_scope = id
	llvm_meta_lines.free()
	llvm_meta_lines = new map[int, int]
	return id


void llvm_debug_mark(int line):
	if (line <= 0): return
	llvm_put(c"  ;@")
	llvm_put(llvm_number(line))
	llvm_put(c"\x0a")


int llvm_debug_location(int line):
	if (line in llvm_meta_lines): return llvm_meta_lines[line]
	int id = llvm_meta_next
	llvm_meta_next = id + 1
	llvm_meta_lines[line] = id
	string_append(llvm_meta, c"!")
	string_append_int(llvm_meta, id)
	string_append(llvm_meta, c" = !DILocation(line: ")
	string_append_int(llvm_meta, line)
	string_append(llvm_meta, c", scope: !")
	string_append_int(llvm_meta, llvm_meta_scope)
	string_append(llvm_meta, c")\x0a")
	return id


# Offset of word in the length bytes at line, or -1.
int llvm_line_find(char* line, int length, char* word):
	int n = strlen(word)
	int i = 0
	while (i + n <= length):
		int k = 0
		while ((k < n) && (line[i + k] == word[k])): k = k + 1
		if (k == n): return i
		i = i + 1
	return -1


# Append one IR line, its load or store made volatile under mode 1 (a
# function that calls setjmp: natively every local lives in memory, so a
# longjmp sees its latest value) or, under mode 2, only where the place is
# a global (a program that starts threads: native code rereads a global
# another thread writes, as spin loops on a flag rely on).
void llvm_append_memory_line(string_builder* out, char* line, int length, int mode):
	int at = -1
	if (mode != 0):
		if (llvm_line_find(line, length, c"  store ") == 0): at = 8
		int load = llvm_line_find(line, length, c" = load ")
		if (load >= 0): at = load + 8
		if ((at >= 0) && (llvm_line_find(line + at, length - at, c"atomic ") == 0)): at = at + 7
		if ((at >= 0) && (llvm_line_find(line + at, length - at, c"volatile ") == 0)): at = -1
		if ((mode == 2) && (llvm_line_find(line, length, c", ptr @g") < 0)): at = -1
	if (at < 0):
		string_append_bytes(out, line, length)
		return
	string_append_bytes(out, line, at)
	string_append(out, c"volatile ")
	string_append_bytes(out, line + at, length - at)


# The code with every global load and store volatile (mode 2 above).
string_builder* llvm_volatile_globals(char* text):
	string_builder* out = string_new()
	int i = 0
	while (text[i] != 0):
		int end = i
		while ((text[end] != 0) && (text[end] != 10)): end = end + 1
		llvm_append_memory_line(out, text + i, end - i, 2)
		string_append_char(out, 10)
		i = end
		if (text[i] == 10): i = i + 1
	return out


# 1 while the function being emitted calls setjmp.
int llvm_function_setjmp


# Append a body to out with its line markers turned into !dbg attachments
# on the instructions after them (labels and comments carry none).
void llvm_debug_lines(string_builder* out, char* text):
	int location = 0
	int i = 0
	while (text[i] != 0):
		int end = i
		while ((text[end] != 0) && (text[end] != 10)): end = end + 1
		if ((end - i > 4) && (text[i] == ' ') && (text[i + 1] == ' ') && (text[i + 2] == ';') && (text[i + 3] == '@')):
			int line = 0
			for k in range(i + 4, end): line = line * 10 + text[k] - '0'
			location = llvm_debug_location(line)
		else:
			llvm_append_memory_line(out, text + i, end - i, llvm_function_setjmp)
			int instruction = (end - i > 2) && (text[i] == ' ') && (text[i + 1] == ' ') && (text[i + 2] != ' ') && (text[i + 2] != ';') && (text[end - 1] != '[')
			if (instruction && (location > 0)):
				string_append(out, c", !dbg !")
				string_append_int(out, location)
			string_append_char(out, 10)
		i = end
		if (text[i] == 10): i = i + 1


# The compile unit and module flags every !dbg location hangs from.
void llvm_debug_finish(string_builder* module):
	int file = llvm_debug_file(llvm_input)
	string_append(module, c"\x0a!llvm.dbg.cu = !{!0}\x0a!llvm.module.flags = !{!1, !2}\x0a")
	string_append(module, c"!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !")
	string_append_int(module, file)
	string_append(module, c", producer: \"wllvm\", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)\x0a")
	string_append(module, c"!1 = !{i32 7, !\"Dwarf Version\", i32 2}\x0a!2 = !{i32 2, !\"Debug Info Version\", i32 3}\x0a")
	string_append(module, c"!3 = !DISubroutineType(types: !{})\x0a")
	string_append(module, llvm_meta.data)


# Function attributes: frame-pointer chains and real call frames (no tail
# calls) for the stack walker, null reads that fault as natively, and no
# inlining once traces can observe frames.
void llvm_function_attributes(string_builder* module):
	string_append(module, c"attributes #1 = { \"frame-pointer\"=\"all\" \"disable-tail-calls\"=\"true\" null_pointer_is_valid")
	if (llvm_traces): string_append(module, c" noinline")
	string_append(module, c" }\x0a")


# thread_local globals (docs/projects/thread_local.md) share one
# per-thread block: word 0 is its self pointer, the variables follow at
# word-aligned offsets, and gs holds the block, as natively. The tree marks
# them only in the source text: their declaration line starts with the
# keyword.
map[int, int] llvm_tls_offsets
int llvm_tls_size


int llvm_thread_local(retained_node* node):
	retained_source* source = retained_sources[node.source]
	if ((node.start < 0) || (node.start > source.length)): return 0
	int i = node.start
	while ((i > 0) && (source.bytes[i - 1] != 10)): i = i - 1
	while ((i < source.length) && ((source.bytes[i] == 9) || (source.bytes[i] == ' '))): i = i + 1
	return (i + 12 <= source.length) && starts_with(source.bytes + i, c"thread_local")


int llvm_is_thread_local(int linkage):
	retained_node declaration
	retained_node_load(llvm_global_decls[linkage], &declaration)
	return llvm_thread_local(&declaration)


# The calling thread's copy of a thread_local global: gs:[0] + offset
# (x86-64 only).
char* llvm_tls_address(int id, int linkage):
	if ((linkage in llvm_tls_offsets) == 0):
		retained_node declaration
		retained_node_load(llvm_global_decls[linkage], &declaration)
		int type = retained_bindings[declaration.binding].type
		int c = llvm_class(type)
		if (((c != llvm_class_word) && (c != llvm_class_struct)) || (declaration.initializer != 0) || llvm_arm64):
			llvm_error_at(id, c"thread_local global", declaration.name)
			return c"null"
		llvm_tls_offsets[linkage] = llvm_tls_size
		llvm_tls_size = llvm_tls_size + llvm_storage(type)
	char* self = llvm_temp()
	llvm_put(c"  ")
	llvm_put(self)
	llvm_put(c" = call i64 asm sideeffect \"movq %gs:0, $0\", \"=r\"()\x0a")
	return llvm_offset(llvm_pointer(self), llvm_number(llvm_tls_offsets[linkage]))


# The block size __w_tls_size() reports, rounded to 16 bytes like the
# native stub; 0 without thread_local globals.
int llvm_tls_block():
	if (llvm_tls_size == 8): return 0
	return (llvm_tls_size + 15) & (0 - 16)


# The main thread installs its block (zeroed, in .data) before the entry
# runs, as the native ELF entry thunk does.
void llvm_tls_entry():
	if (llvm_tls_block() == 0): return
	llvm_runtime_used[c"tls_set"] = 1
	string_append(llvm_data, c"@__wllvm_tls_main = internal global [")
	string_append_int(llvm_data, llvm_tls_block())
	string_append(llvm_data, c" x i8] zeroinitializer, section \".data\", align 16\x0a")
	string_append(llvm_code, c"  call i64 @__wllvm_tls_set(i64 ptrtoint (ptr @__wllvm_tls_main to i64))\x0a")


void llvm_tls_finish():
	if ((c"tls_size" in llvm_runtime_used) == 0): return
	string_append(llvm_data, c"@__wllvm_tls_size = internal constant i64 ")
	string_append_int(llvm_data, llvm_tls_block())
	string_append(llvm_data, c", align 8\x0a")


# Runtime functions the native backends write in assembly
# (code_generator/x64_asm.w), as SysV twins in module asm. Returns the
# stub a call of name with count arguments lowers to, or 0 (always on
# AArch64, which has no twins yet).
char* llvm_runtime_stub(char* name, int count):
	if (llvm_arm64): return 0
	if (((strcmp(name, c"repl_setjmp") == 0) || (strcmp(name, c"setjmp") == 0)) && (count == 1)): return c"repl_setjmp"
	if (((strcmp(name, c"repl_longjmp") == 0) || (strcmp(name, c"longjmp") == 0)) && (count == 2)): return c"repl_longjmp"
	if ((strcmp(name, c"thread_create") == 0) && (count == 1)): return c"thread_create"
	if ((strcmp(name, c"stack_create") == 0) && (count == 0)): return c"stack_create"
	if ((strcmp(name, c"__w_tls_size") == 0) && (count == 0)): return c"tls_size"
	if ((strcmp(name, c"__w_tls_set") == 0) && (count == 1)): return c"tls_set"
	return 0


char* llvm_runtime_call(char* stub, list[char*] values):
	if (strcmp(stub, c"repl_setjmp") == 0): llvm_function_setjmp = 1
	llvm_runtime_used[stub] = 1
	# The block size is known once every function is emitted.
	if (strcmp(stub, c"tls_size") == 0): return llvm_load(-1, c"@__wllvm_tls_size")
	if (strcmp(stub, c"thread_create") == 0): llvm_runtime_used[c"stack_create"] = 1
	char* result = llvm_temp()
	llvm_put(c"  ")
	llvm_put(result)
	llvm_put(c" = call i64 @__wllvm_")
	llvm_put(stub)
	llvm_put(c"(")
	for i in range(values.length):
		if (i > 0): llvm_put(c", ")
		llvm_put(c"i64 ")
		llvm_put(values[i])
	llvm_put(c")\x0a")
	return result


void llvm_asm(string_builder* module, char* line):
	string_append(module, c"module asm \"")
	string_append(module, line)
	string_append(module, c"\"\x0a")


void llvm_asm_function(string_builder* module, char* stub, char* declaration):
	string_append(module, declaration)
	string_append(module, c"\x0a")
	llvm_asm(module, c".p2align 4")
	string_append(module, c"module asm \".type __wllvm_")
	string_append(module, stub)
	string_append(module, c",@function\"\x0amodule asm \"__wllvm_")
	string_append(module, stub)
	string_append(module, c":\"\x0a")


void llvm_asm_function_end(string_builder* module, char* stub):
	string_append(module, c"module asm \".size __wllvm_")
	string_append(module, stub)
	string_append(module, c", .-__wllvm_")
	string_append(module, stub)
	string_append(module, c"\"\x0a\x0a")


# The same buffer layout as the native stubs (lib/setjmp.w): resume pc,
# the caller's sp and rbp, then rbx and r12-r15.
void llvm_emit_runtime_stubs(string_builder* module):
	if (c"repl_setjmp" in llvm_runtime_used):
		llvm_asm_function(module, c"repl_setjmp", c"declare i64 @__wllvm_repl_setjmp(i64) returns_twice")
		llvm_asm(module, c"  movq (%rsp), %rcx")
		llvm_asm(module, c"  movq %rcx, (%rdi)")
		llvm_asm(module, c"  leaq 8(%rsp), %rcx")
		llvm_asm(module, c"  movq %rcx, 8(%rdi)")
		llvm_asm(module, c"  movq %rbp, 16(%rdi)")
		llvm_asm(module, c"  movq %rbx, 24(%rdi)")
		llvm_asm(module, c"  movq %r12, 32(%rdi)")
		llvm_asm(module, c"  movq %r13, 40(%rdi)")
		llvm_asm(module, c"  movq %r14, 48(%rdi)")
		llvm_asm(module, c"  movq %r15, 56(%rdi)")
		llvm_asm(module, c"  xorl %eax, %eax")
		llvm_asm(module, c"  retq")
		llvm_asm_function_end(module, c"repl_setjmp")
	if (c"repl_longjmp" in llvm_runtime_used):
		llvm_asm_function(module, c"repl_longjmp", c"declare i64 @__wllvm_repl_longjmp(i64, i64) noreturn")
		llvm_asm(module, c"  movq %rsi, %rax")
		llvm_asm(module, c"  movq 24(%rdi), %rbx")
		llvm_asm(module, c"  movq 32(%rdi), %r12")
		llvm_asm(module, c"  movq 40(%rdi), %r13")
		llvm_asm(module, c"  movq 48(%rdi), %r14")
		llvm_asm(module, c"  movq 56(%rdi), %r15")
		llvm_asm(module, c"  movq 8(%rdi), %rsp")
		llvm_asm(module, c"  movq 16(%rdi), %rbp")
		llvm_asm(module, c"  jmpq *(%rdi)")
		llvm_asm_function_end(module, c"repl_longjmp")
	# thread_create(func): clone onto a fresh 4MB stack whose top slot holds
	# func, so the child's ret enters func; the child's rbp chain ends there.
	if (c"thread_create" in llvm_runtime_used):
		llvm_asm_function(module, c"thread_create", c"declare i64 @__wllvm_thread_create(i64)")
		llvm_asm(module, c"  pushq %rdi")
		llvm_asm(module, c"  callq __wllvm_stack_create")
		llvm_asm(module, c"  popq %rdx")
		llvm_asm(module, c"  leaq 0x3ffff0(%rax), %rsi")
		llvm_asm(module, c"  movq %rdx, (%rsi)")
		llvm_asm(module, c"  movl $-0x7ffe7100, %edi")
		llvm_asm(module, c"  movl $56, %eax")
		llvm_asm(module, c"  syscall")
		llvm_asm(module, c"  testl %eax, %eax")
		llvm_asm(module, c"  jne 1f")
		llvm_asm(module, c"  xorl %ebp, %ebp")
		llvm_asm(module, c"1:")
		llvm_asm(module, c"  retq")
		llvm_asm_function_end(module, c"thread_create")
	# __w_tls_set(block): block[0] = block, then make it the gs base.
	if (c"tls_set" in llvm_runtime_used):
		llvm_asm_function(module, c"tls_set", c"declare i64 @__wllvm_tls_set(i64)")
		llvm_asm(module, c"  movq %rdi, (%rdi)")
		llvm_asm(module, c"  movq %rdi, %rsi")
		llvm_asm(module, c"  movl $0x1001, %edi")
		llvm_asm(module, c"  movl $158, %eax")
		llvm_asm(module, c"  syscall")
		llvm_asm(module, c"  retq")
		llvm_asm_function_end(module, c"tls_set")
	# stack_create(): mmap(0, 4MB, RW, PRIVATE|ANONYMOUS|GROWSDOWN, -1, 0)
	if (c"stack_create" in llvm_runtime_used):
		llvm_asm_function(module, c"stack_create", c"declare i64 @__wllvm_stack_create()")
		llvm_asm(module, c"  xorl %edi, %edi")
		llvm_asm(module, c"  movl $0x400000, %esi")
		llvm_asm(module, c"  movl $3, %edx")
		llvm_asm(module, c"  movl $0x122, %r10d")
		llvm_asm(module, c"  movq $-1, %r8")
		llvm_asm(module, c"  xorl %r9d, %r9d")
		llvm_asm(module, c"  movl $9, %eax")
		llvm_asm(module, c"  syscall")
		llvm_asm(module, c"  retq")
		llvm_asm_function_end(module, c"stack_create")


# --- C math calls --------------------------------------------------------------
# Natively, extern and c_import declarations of libm's sqrt/floor/... reach
# the C library through the dynamic linker; W code uses lib/fmath*.w. The
# freestanding LLVM build has no C library, so the functions with an exact
# inline equivalent lower in place and the others stay unsupported.

# Bit 1: llvm.sqrt.f32 is used; bit 2: llvm.sqrt.f64; 4/8: minnum/maxnum.
int llvm_uses_math


int llvm_math_arity(char* name):
	if ((strcmp(name, c"sqrt") == 0) || (strcmp(name, c"fabs") == 0) || (strcmp(name, c"floor") == 0) || (strcmp(name, c"ceil") == 0) || (strcmp(name, c"trunc") == 0)): return 1
	if ((strcmp(name, c"fmin") == 0) || (strcmp(name, c"fmax") == 0) || (strcmp(name, c"copysign") == 0)): return 2
	return 0


char* llvm_math_mask(int kind, int sign):
	if (kind == 2):
		if (sign): return c"-9223372036854775808"
		return c"9223372036854775807"
	if (sign): return c"2147483648"
	return c"2147483647"


# copysign(x, y) on words of float kind.
char* llvm_math_copysign(char* x, char* y, int kind):
	char* magnitude = llvm_instruction(c"and", x, llvm_math_mask(kind, 0))
	return llvm_instruction(c"or", magnitude, llvm_instruction(c"and", y, llvm_math_mask(kind, 1)))


# trunc/floor/ceil without SSE4.1 or libm: below 2^52 (2^23) the cvtt
# round trip truncates exactly; larger values and infinities are already
# integral, and a NaN comes back quiet. The sign of a zero result follows x.
char* llvm_math_round(char* name, char* x, int kind):
	char* type = llvm_float_type(kind)
	char* limit = c"8388608.0"
	char* quiet_bit = c"4194304"
	if (kind == 2):
		limit = c"4503599627370496.0"
		quiet_bit = c"2251799813685248"
	char* magnitude = llvm_float_from_word(llvm_instruction(c"and", x, llvm_math_mask(kind, 0)), kind)
	char* small = llvm_op(c"fcmp olt", type, magnitude, limit)
	char* truncated = llvm_float_coerce(llvm_float_coerce(x, kind, 0), 0, kind)
	char* result = truncated
	if ((strcmp(name, c"floor") == 0) || (strcmp(name, c"ceil") == 0)):
		char* t = llvm_float_from_word(truncated, kind)
		char* xf = llvm_float_from_word(x, kind)
		char* past = 0
		char* step = 0
		if (strcmp(name, c"floor") == 0):
			past = llvm_op(c"fcmp ogt", type, t, xf)
			step = llvm_float_to_word(llvm_op(c"fsub", type, t, c"1.0"), kind)
		else:
			past = llvm_op(c"fcmp olt", type, t, xf)
			step = llvm_float_to_word(llvm_op(c"fadd", type, t, c"1.0"), kind)
		result = llvm_float_select(past, step, truncated)
	result = llvm_math_copysign(result, x, kind)
	char* xf = llvm_float_from_word(x, kind)
	char* nan = llvm_op(c"fcmp uno", type, xf, xf)
	char* large = llvm_float_select(nan, llvm_instruction(c"or", x, quiet_bit), x)
	return llvm_float_select(small, result, large)


char* llvm_math_intrinsic(char* intrinsic, int kind, list[char*] values):
	char* type = llvm_float_type(kind)
	list[char*] operands = new list[char*]
	for i in range(values.length): operands.push(llvm_float_from_word(values[i], kind))
	char* result = llvm_temp()
	llvm_put(c"  ")
	llvm_put(result)
	llvm_put(c" = call ")
	llvm_put(type)
	llvm_put(c" @llvm.")
	llvm_put(intrinsic)
	if (kind == 2): llvm_put(c".f64(")
	else: llvm_put(c".f32(")
	for i in range(operands.length):
		if (i > 0): llvm_put(c", ")
		llvm_put(type)
		llvm_put(c" ")
		llvm_put(operands[i])
	llvm_put(c")\x0a")
	operands.free()
	return llvm_float_to_word(result, kind)


# The call's value, or 0 when callee is not a lowered math function with
# float parameters and result of one kind (a name ending in f: float32).
char* llvm_math_call(int id, retained_binding* callee, list[char*] values, list[int] types):
	char* name = callee.name
	int kind = 2
	if (llvm_math_arity(name) == 0):
		int length = strlen(name)
		if ((length < 2) || (name[length - 1] != 'f')): return 0
		string_builder* text = string_new()
		string_append_bytes(text, name, length - 1)
		name = retained_intern(text.data)
		string_free(text)
		kind = 1
	int arity = llvm_math_arity(name)
	if ((arity == 0) || (values.length != arity) || (callee.parameters.length != arity)): return 0
	if (llvm_float_kind(callee.return_type) != kind): return 0
	for i in range(arity):
		if (llvm_float_kind(callee.parameters[i]) != kind): return 0
	for i in range(arity): values[i] = llvm_convert(id, values[i], types[i], callee.parameters[i])
	if (strcmp(name, c"sqrt") == 0):
		llvm_uses_math = llvm_uses_math | kind
		return llvm_math_intrinsic(c"sqrt", kind, values)
	if (strcmp(name, c"fmin") == 0):
		llvm_uses_math = llvm_uses_math | 4
		return llvm_math_intrinsic(c"minnum", kind, values)
	if (strcmp(name, c"fmax") == 0):
		llvm_uses_math = llvm_uses_math | 8
		return llvm_math_intrinsic(c"maxnum", kind, values)
	if (strcmp(name, c"fabs") == 0): return llvm_instruction(c"and", values[0], llvm_math_mask(kind, 0))
	if (strcmp(name, c"copysign") == 0): return llvm_math_copysign(values[0], values[1], kind)
	return llvm_math_round(name, values[0], kind)


# The intrinsics llvm_math_call used (fminf/fmaxf share bit 4/8 with the
# float64 forms, so both widths are declared).
void llvm_math_declarations(string_builder* module):
	if (llvm_uses_math & 1): string_append(module, c"declare float @llvm.sqrt.f32(float)\x0a")
	if (llvm_uses_math & 2): string_append(module, c"declare double @llvm.sqrt.f64(double)\x0a")
	if (llvm_uses_math & 4): string_append(module, c"declare float @llvm.minnum.f32(float, float)\x0adeclare double @llvm.minnum.f64(double, double)\x0a")
	if (llvm_uses_math & 8): string_append(module, c"declare float @llvm.maxnum.f32(float, float)\x0adeclare double @llvm.maxnum.f64(double, double)\x0a")


int llvm_is_owner(int type);
void llvm_owner_move(int group, int operand, int destination);
char* llvm_owner_assign(int group, int id, retained_node* node);


# ---- C imports ---------------------------------------------------------
# An extern function or object (declared by hand or by c_import) has no W
# body: the front end binds its symbol to a dynamic-registry import, a
# function through its GOT slot (sym_got_vaddr), an object through the
# address it was given (its COPY space, or for an array the slot holding
# the library's address). wllvm declares the import under its library
# name and calls it with the C ABI: each fixed parameter and the result
# take the LLVM type of their W type (ptr, i8-i64, float, double), and a
# variadic call passes its extra arguments as words, float32 promoted to
# double. Internal W functions keep the i64 ABI. A module that uses an
# import sets llvm_dynamic, and the driver links it against the libraries
# the program names (llvm_link_libraries).
string_builder* llvm_imports
# binding -> import index, or -1 for a binding without one
map[int, int] llvm_import_cache
# Library names declared; extern aliases can name one import twice.
map[char*, int] llvm_imports_declared
int llvm_dynamic
# The program's c_lib sonames, in declaration order, once each; kept after
# llvm_emit returns for the driver's link.
list[char*] llvm_link_libraries


# The dynamic-registry import binding names, or -1.
int llvm_import_of(int binding):
	if (binding < 0): return -1
	if (binding in llvm_import_cache): return llvm_import_cache[binding]
	retained_binding* b = retained_bindings[binding]
	int found = -1
	int t = b.origin
	if (t >= 0):
		int function = load_int(table + t + 10) == 2
		int got = sym_got_vaddr(t)
		int address = sym_value_at(t)
		for i in range(dyn_import_count):
			if (found >= 0): break
			if (function):
				if ((got != 0) && (dyn_import_got_vaddr(i) == got)): found = i
			else if ((dyn_import_got_vaddr(i) == address) && (strcmp(dyn_import_name(i), b.name) == 0)): found = i
	llvm_import_cache[binding] = found
	return found


# An import's LLVM global name (quoted: library names are not W names).
char* llvm_import_symbol(int import):
	string_builder* text = string_new()
	string_append(text, c"@\"")
	string_append(text, dyn_import_name(import))
	string_append(text, c"\"")
	char* result = retained_intern(text.data)
	string_free(text)
	return result


# The module uses an import: it links against every c_lib the program
# names, as the native image lists each one as DT_NEEDED and the loader
# resolves an import in any of them.
void llvm_import_used():
	if (llvm_dynamic): return
	llvm_dynamic = 1
	for i in range(dyn_lib_count):
		char* soname = dyn_lib_name(i)
		int seen = 0
		for name in llvm_link_libraries:
			if (strcmp(name, soname) == 0): seen = 1
		if (seen == 0): llvm_link_libraries.push(strclone(soname))


# A c_import enumerator or integer macro (SEEK_END, ENOENT): the front end
# emits each as a word constant global with no W declaration.
int llvm_c_constant(int binding, int* value):
	retained_binding* b = retained_bindings[binding]
	if ((ci_const_values == 0) || ((b.name in ci_const_values) == 0)): return 0
	if ((b.origin < 0) || (load_int(table + b.origin + 10) != 1) || (llvm_import_of(binding) >= 0)): return 0
	*value = ci_const_values[b.name]
	return 1


# The C ABI type of W type type, or 0 when it has none (records by value,
# float16/bfloat16).
char* llvm_c_type(int type):
	if (type < 0): return c"i64"
	retained_type* t = llvm_type(type)
	int kind = llvm_float_kind_of(t)
	if (kind == 1): return c"float"
	if (kind == 2): return c"double"
	if (kind == 3): return 0
	if (llvm_class_of(t) != llvm_class_word): return 0
	if (t.pointer_level > 0): return c"ptr"
	return llvm_int_type(llvm_width(type))


int llvm_is_void(int type):
	return (type >= 0) && llvm_named(llvm_type(type), c"void")


int llvm_c_zero_extends(int type):
	return llvm_zero_extends(type) || llvm_is_bool(type)


# An i8/i16 argument or result is extended to 32 bits by the caller, as
# Clang's x86-64 and AArch64 C conventions expect.
char* llvm_c_extension(int type, char* c_type):
	if ((strcmp(c_type, c"i8") != 0) && (strcmp(c_type, c"i16") != 0)): return c""
	if (llvm_c_zero_extends(type)): return c" zeroext"
	return c" signext"


# A word of W type type as a C value of c_type.
char* llvm_c_argument(char* value, int type, char* c_type):
	if (strcmp(c_type, c"ptr") == 0): return llvm_pointer(value)
	if ((strcmp(c_type, c"float") == 0) || (strcmp(c_type, c"double") == 0)): return llvm_float_from_word(value, llvm_float_kind(type))
	if (strcmp(c_type, c"i64") == 0): return value
	return llvm_convert_op(c"trunc", c"i64", value, c_type)


# A C result of c_type back as a word of W type type.
char* llvm_c_result(char* value, int type, char* c_type):
	if (strcmp(c_type, c"ptr") == 0): return llvm_address_value(value)
	if ((strcmp(c_type, c"float") == 0) || (strcmp(c_type, c"double") == 0)): return llvm_float_to_word(value, llvm_float_kind(type))
	if (strcmp(c_type, c"i64") == 0): return value
	if (llvm_c_zero_extends(type)): return llvm_convert_op(c"zext", c_type, value, c"i64")
	return llvm_convert_op(c"sext", c_type, value, c"i64")


# The module defines these for LLVM's own use; an import of the same name
# calls that definition instead of a second declaration.
int llvm_import_is_memory_runtime(char* name):
	return (strcmp(name, c"memset") == 0) || (strcmp(name, c"memcpy") == 0) || (strcmp(name, c"memmove") == 0)


# A C ABI call of function import import, which binding names.
char* llvm_import_call(int id, int import, int binding, list[char*] values, list[int] types):
	retained_binding* b = retained_bindings[binding]
	int fixed = b.parameters.length
	int variadic = sym_variadic_fixed_args(b.origin) >= 0
	if (variadic): fixed = sym_variadic_fixed_args(b.origin)
	if ((values.length < fixed) || ((variadic == 0) && (values.length != fixed))):
		llvm_error_at(id, c"call argument count", b.name)
		return c"0"
	char* return_type = c"void"
	if (llvm_is_void(b.return_type) == 0): return_type = llvm_c_type(b.return_type)
	if (return_type == 0):
		llvm_error_at(id, c"C result type of", b.name)
		return c"0"
	# The fixed parameter list, shared by the declaration and a variadic
	# call's function type.
	string_builder* parameters = string_new()
	for i in range(fixed):
		char* c_type = llvm_c_type(b.parameters[i])
		if (c_type == 0):
			llvm_error_at(id, c"C parameter type of", b.name)
			string_free(parameters)
			return c"0"
		if (i > 0): string_append(parameters, c", ")
		string_append(parameters, c_type)
	if (variadic):
		if (fixed > 0): string_append(parameters, c", ")
		string_append(parameters, c"...")
	char* symbol = llvm_import_symbol(import)
	char* name = dyn_import_name(import)
	if (llvm_import_is_memory_runtime(name)): llvm_uses_memory = 1
	else if ((name in llvm_imports_declared) == 0):
		llvm_imports_declared[name] = 1
		llvm_import_used()
		string_append(llvm_imports, c"declare ")
		if (dyn_import_get_binding(import) == 2): string_append(llvm_imports, c"extern_weak ")
		string_append(llvm_imports, return_type)
		string_append(llvm_imports, c" ")
		string_append(llvm_imports, symbol)
		string_append(llvm_imports, c"(")
		string_append(llvm_imports, parameters.data)
		string_append(llvm_imports, c")\x0a")
	string_builder* arguments = string_new()
	for i in range(values.length):
		int type = types[i]
		char* value = values[i]
		if (i < fixed):
			type = b.parameters[i]
			value = llvm_convert(id, value, types[i], type)
		else if (llvm_decays(type, llvm_word_type)):
			# A fixed array or slice in the variadic tail passes its data
			# pointer, like C (#229).
			value = llvm_load(-1, llvm_pointer(value))
			type = -1
		char* c_type = llvm_c_type(type)
		if (c_type == 0):
			llvm_error_at(id, c"C argument type in a call to", b.name)
			string_free(parameters)
			string_free(arguments)
			return c"0"
		char* c_value = llvm_c_argument(value, type, c_type)
		if (i >= fixed):
			# Default argument promotions: a variadic float32 travels as a
			# double, a narrower integer as its sign- or zero-extended word.
			if (strcmp(c_type, c"float") == 0):
				c_value = llvm_convert_op(c"fpext", c"float", c_value, c"double")
				c_type = c"double"
			else if ((strcmp(c_type, c"ptr") != 0) && (strcmp(c_type, c"double") != 0)):
				c_value = value
				c_type = c"i64"
		if (i > 0): string_append(arguments, c", ")
		string_append(arguments, c_type)
		string_append(arguments, llvm_c_extension(type, c_type))
		string_append(arguments, c" ")
		string_append(arguments, c_value)
	char* result = 0
	llvm_put(c"  ")
	if (strcmp(return_type, c"void") != 0):
		result = llvm_temp()
		llvm_put(result)
		llvm_put(c" = ")
	llvm_put(c"call ")
	llvm_put(return_type)
	if (variadic):
		llvm_put(c" (")
		llvm_put(parameters.data)
		llvm_put(c")")
	llvm_put(c" ")
	llvm_put(symbol)
	llvm_put(c"(")
	llvm_put(arguments.data)
	llvm_put(c")\x0a")
	string_free(parameters)
	string_free(arguments)
	if (result == 0): return c"0"
	return llvm_c_result(result, b.return_type, return_type)


# A function import used as a value (a callback, a function-typed global)
# is a W function: as natively, where the symbol names the import's ABI
# shim, it takes and returns i64 words, and this per-binding thunk makes
# the C ABI call. A variadic import's thunk passes the fixed parameters
# only, as the native shim does.
map[int, int] llvm_import_thunks
string_builder* llvm_thunk_code


char* llvm_import_thunk(int id, int binding, int import):
	char* name = llvm_name(c"@wllvm.cthunk.", binding)
	if (binding in llvm_import_thunks): return name
	llvm_import_thunks[binding] = 1
	retained_binding* b = retained_bindings[binding]
	int fixed = b.parameters.length
	if (sym_variadic_fixed_args(b.origin) >= 0): fixed = sym_variadic_fixed_args(b.origin)
	string_builder* saved_out = llvm_out
	int saved_register = llvm_register
	llvm_out = string_new()
	llvm_register = 0
	list[char*] values = new list[char*]
	list[int] types = new list[int]
	llvm_put(c"define internal i64 ")
	llvm_put(name)
	llvm_put(c"(")
	for i in range(fixed):
		if (i > 0): llvm_put(c", ")
		char* parameter = llvm_name(c"%a", i)
		llvm_put(c"i64 ")
		llvm_put(parameter)
		values.push(parameter)
		types.push(b.parameters[i])
	llvm_put(c") {\x0aentry:\x0a")
	char* result = llvm_import_call(id, import, binding, values, types)
	llvm_put(c"  ret i64 ")
	llvm_put(result)
	llvm_put(c"\x0a}\x0a\x0a")
	string_append(llvm_thunk_code, llvm_out.data)
	string_free(llvm_out)
	llvm_out = saved_out
	llvm_register = saved_register
	values.free()
	types.free()
	return name


# The address of an imported object binding names, or 0 when it is not
# one: the library's object, or for an array imported by address an
# internal slot holding the library array's address, as natively.
char* llvm_import_address(int binding):
	int import = llvm_import_of(binding)
	if (import < 0): return 0
	if (load_int(table + retained_bindings[binding].origin + 10) == 2): return 0
	char* symbol = llvm_import_symbol(import)
	char* slot = llvm_name(c"@wllvm.import.", import)
	int array = dyn_import_get_symtype(import) == 2
	char* name = dyn_import_name(import)
	if ((name in llvm_imports_declared) == 0):
		llvm_imports_declared[name] = 1
		llvm_import_used()
		string_append(llvm_imports, symbol)
		if (dyn_import_get_binding(import) == 2): string_append(llvm_imports, c" = extern_weak global ")
		else: string_append(llvm_imports, c" = external global ")
		if (array): string_append(llvm_imports, c"i8\x0a")
		else:
			string_append(llvm_imports, c"[")
			string_append_int(llvm_imports, dyn_import_get_size(import))
			string_append(llvm_imports, c" x i8]\x0a")
		if (array):
			string_append(llvm_imports, slot)
			string_append(llvm_imports, c" = internal global ptr ")
			string_append(llvm_imports, symbol)
			string_append(llvm_imports, c"\x0a")
	if (array): return slot
	return symbol


# ---- Generics ----------------------------------------------------------
# A generic call ('G' explicit type arguments, 'W' inferred) names its
# committed instantiation by mangled name (payload_text, e.g.
# "smaller$int"); each instantiation is retained as an ordinary function
# record under that name. Returns the instance's linkage, -1 when it has
# no W body, or -2 for a non-generic call.
int llvm_generic_callee(retained_node* node):
	if ((node.op != 'G') && (node.op != 'W')): return -2
	if (node.payload_text == 0): return -1
	if (node.payload_text in llvm_function_names): return llvm_function_names[node.payload_text]
	return -1
# --- test registry -------------------------------------------------------------
# lib/testing.w calls __w_test_main, which the native driver synthesizes
# (compiler/test_registry.w): one __w_run_tests(name, fn) call per defined
# zero-argument test_* function, in definition order. wllvm builds the same
# function from the retained forest.

list[int] llvm_tests
int llvm_tests_wanted


char* llvm_test_main_call(int id):
	if ((c"__w_run_tests" in llvm_function_names) == 0):
		llvm_error(id, c"test registry without __w_run_tests")
		return c"0"
	if (llvm_tests_wanted == 0):
		llvm_tests_wanted = 1
		llvm_function_symbol(llvm_function_names[c"__w_run_tests"])
		map[int, int] seen = new map[int, int]
		int count = retained_node_count()
		for node_id in range(count):
			if (retained_node_kind(node_id) != retained_function): continue
			retained_node function
			retained_node_load(node_id, &function)
			if ((function.binding < 0) || (starts_with(function.name, c"test_") == 0)): continue
			int linkage = retained_bindings[function.binding].linkage
			if ((linkage in llvm_functions) && (retained_bindings[function.binding].parameters.length == 0) && ((linkage in seen) == 0)):
				seen[linkage] = 1
				llvm_tests.push(linkage)
				llvm_function_symbol(linkage)
		seen.free()
	char* result = llvm_temp()
	llvm_put(c"  ")
	llvm_put(result)
	llvm_put(c" = call i64 @__w_test_main()\x0a")
	return result


void llvm_emit_test_main():
	if (llvm_tests_wanted == 0): return
	# Private like native's zero-sized __w_test_main symbol: traces skip it.
	string_append(llvm_code, c"define private i64 @__w_test_main() #1 {\x0aentry:\x0a")
	int run = llvm_function_names[c"__w_run_tests"]
	int complete = run in llvm_queued
	for i in range(llvm_tests.length):
		if ((llvm_tests[i] in llvm_queued) == 0): complete = 0
	if (complete == 0):
		llvm_uses_trap = 1
		string_append(llvm_code, c"  call void @llvm.trap()\x0a  unreachable\x0a}\x0a\x0a")
		return
	for i in range(llvm_tests.length):
		retained_node definition
		retained_node_load(llvm_functions[llvm_tests[i]], &definition)
		char* name = llvm_string_constant(definition.name, strlen(definition.name))
		string_append(llvm_code, c"  call i64 ")
		string_append(llvm_code, llvm_function_label(run))
		string_append(llvm_code, c"(i64 ")
		string_append(llvm_code, llvm_constant_address(name))
		string_append(llvm_code, c", i64 ")
		string_append(llvm_code, llvm_constant_address(llvm_function_label(llvm_tests[i])))
		string_append(llvm_code, c")\x0a")
	string_append(llvm_code, c"  ret i64 0\x0a}\x0a\x0a")


char* llvm_call(int group, int id, retained_node* node):
	list[char*] values = new list[char*]
	list[int] types = new list[int]
	int arg = node.left
	if (node.op == 'F'): arg = node.right
	char* callee_value = c"0"
	if (node.op == 'F'): callee_value = llvm_value(group, node.left)
	list[int] operands = new list[int]
	while ((arg >= 0) && (llvm_failed == 0)):
		operands.push(arg)
		values.push(llvm_value(group, arg))
		retained_node argument
		retained_node_load(llvm_node_id(group, arg), &argument)
		types.push(argument.semantic_type)
		arg = argument.next_arg
	char* target = c"null"
	int count = values.length
	if (node.op == 'F'):
		# Coerce through the signature's parameter types when it has them.
		int callee_type = llvm_operand_type(group, node.left)
		if (callee_type >= 0):
			retained_type* signature = llvm_type(callee_type)
			if ((signature.parameters.length == 0) && (signature.target >= 0)): signature = llvm_type(signature.target)
			for i in range(count):
				if (i < signature.parameters.length): values[i] = llvm_convert(id, values[i], types[i], signature.parameters[i])
		retained_node callee_node
		retained_node_load(llvm_node_id(group, node.left), &callee_node)
		retained_type* owner_signature = llvm_type(callee_node.semantic_type)
		if ((owner_signature.parameters.length == 0) && (owner_signature.target >= 0)): owner_signature = llvm_type(owner_signature.target)
		for i in range(count):
			if (i < owner_signature.parameters.length): llvm_owner_move(group, operands[i], owner_signature.parameters[i])
		target = llvm_pointer(callee_value)
	else:
		char* callee_name = node.payload_text
		int linkage = llvm_generic_callee(node)
		if (linkage == -2):
			retained_binding* callee = retained_bindings[node.binding]
			linkage = callee.linkage
			callee_name = callee.name
		if ((linkage in llvm_functions) == 0):
			int syscall = (strcmp(callee_name, c"syscall") == 0) || (strcmp(callee_name, c"syscall7") == 0)
			if (syscall && ((values.length == 4) || (values.length == 7))):
				char* result = llvm_temp()
				llvm_put(c"  ")
				llvm_put(result)
				# The number, then up to six arguments: rax/rdi.. on x86-64,
				# x8/x0.. with svc #0 on AArch64 (lib/arm64/syscalls.w).
				if (llvm_arm64 && (values.length == 4)): llvm_put(c" = call i64 asm sideeffect \"svc #0\", \"={x0},{x8},{x0},{x1},{x2},~{memory}\"(")
				else if (llvm_arm64): llvm_put(c" = call i64 asm sideeffect \"svc #0\", \"={x0},{x8},{x0},{x1},{x2},{x3},{x4},{x5},~{memory}\"(")
				else if (values.length == 4): llvm_put(c" = call i64 asm sideeffect \"syscall\", \"={rax},{rax},{rdi},{rsi},{rdx},~{rcx},~{r11},~{memory}\"(")
				else: llvm_put(c" = call i64 asm sideeffect \"syscall\", \"={rax},{rax},{rdi},{rsi},{rdx},{r10},{r8},{r9},~{rcx},~{r11},~{memory}\"(")
				for i in range(values.length):
					if (i > 0): llvm_put(c", ")
					llvm_put(c"i64 ")
					llvm_put(values[i])
				llvm_put(c")\x0a")
				values.free()
				types.free()
				operands.free()
				return result
			if ((strcmp(callee_name, c"gen_switch") == 0) && (values.length == 2)):
				char* switched = llvm_generator_switch(id, values)
				values.free()
				types.free()
				return switched
			if ((strcmp(callee_name, c"__w_test_main") == 0) && (values.length == 0)):
				values.free()
				types.free()
				return llvm_test_main_call(id)
			char* stub = llvm_runtime_stub(callee_name, values.length)
			if (stub != 0):
				char* stub_result = llvm_runtime_call(stub, values)
				values.free()
				types.free()
				operands.free()
				return stub_result
			int import = -1
			if ((node.op != 'G') && (node.op != 'W')): import = llvm_import_of(node.binding)
			# libm itself where the program links dynamically; inline where
			# it cannot (AArch64 dynamic links are not covered).
			if ((node.binding >= 0) && ((import < 0) || llvm_arm64)):
				char* math = llvm_math_call(id, retained_bindings[node.binding], values, types)
				if (math != 0):
					values.free()
					types.free()
					operands.free()
					return math
			if (import >= 0):
				char* imported = llvm_import_call(id, import, node.binding, values, types)
				values.free()
				types.free()
				operands.free()
				return imported
			llvm_error_at(id, c"call to a function without a W body", callee_name)
			values.free()
			types.free()
			operands.free()
			return c"0"
		retained_node definition
		retained_node_load(llvm_functions[linkage], &definition)
		retained_binding* defined = retained_bindings[definition.binding]
		# _main passes argc and argv even to a main without parameters.
		if (count > defined.parameters.length): count = defined.parameters.length
		if (count < defined.parameters.length): llvm_error_at(id, c"call argument count", callee_name)
		for i in range(count):
			if (i < defined.parameters.length):
				if (llvm_class(defined.parameters[i]) != llvm_class_word): llvm_error_at(id, c"record parameter passed by value to", callee_name)
				values[i] = llvm_convert(id, values[i], types[i], defined.parameters[i])
				llvm_owner_move(group, operands[i], defined.parameters[i])
		target = llvm_function_symbol(linkage)
	char* result = llvm_temp()
	llvm_put(c"  ")
	llvm_put(result)
	llvm_put(c" = call i64 ")
	llvm_put(target)
	llvm_put(c"(")
	for i in range(count):
		if (i > 0): llvm_put(c", ")
		llvm_put(c"i64 ")
		llvm_put(values[i])
	llvm_put(c")\x0a")
	values.free()
	types.free()
	operands.free()
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


# A conditional's branch at the conditional's float kind.
char* llvm_float_branch(int group, int operand, int type):
	retained_node branch
	retained_node_load(llvm_node_id(group, operand), &branch)
	char* value = llvm_value(group, operand)
	int got = llvm_float_kind(branch.semantic_type)
	int want = llvm_float_kind(type)
	if ((got != want) && (got <= 2) && (want <= 2)): return llvm_float_coerce(value, got, want)
	return value


# Integer builtins (limb, bit and atomic intrinsics) truncate a float
# argument to an integer word, as their coerce() to int does.
char* llvm_float_integer_argument(int group, int operand):
	retained_node argument
	retained_node_load(llvm_node_id(group, operand), &argument)
	char* value = llvm_value(group, operand)
	int got = llvm_float_kind(argument.semantic_type)
	if ((got == 1) || (got == 2)): return llvm_float_coerce(value, got, 0)
	return value


# --- f-strings -----------------------------------------------------------------
# f"..." lowers to the __w_template_* helpers exactly as
# grammar/template_string.w does: a builder, one append per chunk and value,
# then __w_template_finish. The retained 'E' node chains its raw chunks
# ('t', bytes already decoded) and values through next_arg; a chunk's right
# names the ast_template_format spec of the value after it.

const int llvm_template_format = 131


# The runtime kind of a value under a spec (template_format_class): 0-5
# int-like renderings, 6 char*, 7 string, 8 float32, 9 float64; -1 when
# the value cannot be interpolated here.
int llvm_template_kind(int type, int spec_type):
	int float_kind = llvm_float_kind(type)
	if (float_kind == 1): return 8
	if (float_kind == 2): return 9
	if (llvm_is_string(type)): return 7
	if (llvm_is_char_pointer(type)): return 6
	if ((type < 0) || (llvm_class(type) != llvm_class_word) || (llvm_type(type).pointer_level > 0) || (llvm_type(type).kind == 2)): return -1
	if (spec_type == 'x'): return 1
	if (spec_type == 'X'): return 2
	if (spec_type == 'o'): return 3
	if (spec_type == 'b'): return 4
	if (spec_type == 'c'): return 5
	return 0


char* llvm_template(int group, int id, retained_node* node):
	list[char*] none = new list[char*]
	char* builder = llvm_helper_call(id, c"__w_template_new", none)
	none.free()
	int part = node.left
	while ((part >= 0) && (llvm_failed == 0)):
		retained_node chunk
		retained_node_load(llvm_node_id(group, part), &chunk)
		if (chunk.op != 't'):
			llvm_error(id, c"template string shape")
			return c"0"
		if (chunk.literal_length > 0):
			char* data = llvm_constant_address(llvm_string_constant(chunk.literal_text, chunk.literal_length))
			list[char*] bytes = list[char*]{builder, data, llvm_number(chunk.literal_length)}
			llvm_helper_call(id, c"__w_template_bytes", bytes)
			bytes.free()
		if (chunk.next_arg < 0): part = -1
		else:
			retained_node value
			retained_node_load(llvm_node_id(group, chunk.next_arg), &value)
			int present = 0
			int fill = ' '
			int align = 0
			int width = 0
			int precision = -1
			int spec_type = 0
			if (chunk.right >= 0):
				retained_node spec
				retained_node_load(llvm_node_id(group, chunk.right), &spec)
				# An empty '{value:}' spec is typed void and means no spec.
				if ((spec.op == llvm_template_format) && (spec.semantic_type >= 0) && (strcmp(retained_types[spec.semantic_type].name, c"void") != 0)):
					present = 1
					width = spec.left
					precision = spec.right
					fill = spec.value
					align = spec.high
					spec_type = spec.symbol
			int kind = llvm_template_kind(value.semantic_type, spec_type)
			if (kind < 0):
				if (value.semantic_type >= 0): llvm_error_at(id, c"template string value type", retained_types[value.semantic_type].name)
				else: llvm_error(id, c"template string value type")
				return c"0"
			char* word = llvm_value(group, chunk.next_arg)
			list[char*] arguments = list[char*]{builder, word}
			char* helper = c"__w_template_fmt"
			if ((present == 0) && (kind < 8)):
				helper = c"__w_template_int"
				if (kind == 6): helper = c"__w_template_cstr"
				if (kind == 7): helper = c"__w_template_str"
			else:
				if (kind == 8): helper = c"__w_template_float"
				else if (kind == 9): helper = c"__w_template_float64"
				else: arguments.push(llvm_number(kind))
				# numbers align right by default, text left (Python's rule)
				if (align == 0):
					align = '>'
					if ((kind == 6) || (kind == 7)): align = '<'
				arguments.push(llvm_number(width))
				arguments.push(llvm_number(precision))
				arguments.push(llvm_number((fill << 8) | align))
			llvm_helper_call(id, helper, arguments)
			arguments.free()
			part = value.next_arg
	list[char*] finish = list[char*]{builder}
	char* result = llvm_helper_call(id, c"__w_template_finish", finish)
	finish.free()
	return result


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
	# A generic named before its declaration ('f[T]' as a value or callee)
	# is its instance's address.
	if (op == 135):
		if ((node.payload_text != 0) && (node.payload_text in llvm_function_names)): return llvm_constant_address(llvm_function_symbol(llvm_function_names[node.payload_text]))
		llvm_error_at(id, c"reference to", node.payload_text)
		return c"0"
	if ((type_class == llvm_class_none) && (op != 'C') && (op != 'F') && (op != 'G') && (op != 'W')):
		if (type >= 0): llvm_error_at(id, c"expression type", retained_types[type].name)
		else: llvm_error(id, c"expression type")
		return c"0"
	if ((op == 0) || (op == 'c') || (op == 'h')): return llvm_number(node.literal_value)
	if (op == 'f'): return llvm_float_literal(&node)
	if (op == 'E'): return llvm_template(group, id, &node)
	if (op == 's'): return llvm_constant_address(llvm_string_constant(node.literal_text, node.literal_length))
	if (op == 'S'): return llvm_constant_address(llvm_string_descriptor(node.literal_text, node.literal_length))
	if (op == 'v'):
		if (llvm_place(&node) == 0):
			if (node.binding < 0):
				llvm_error(id, c"unbound name")
				return c"0"
			int value = 0
			if (llvm_enum_constant(node.binding, &value)): return llvm_number(value)
			if (llvm_c_constant(node.binding, &value)): return llvm_number(value)
			int linkage = retained_bindings[node.binding].linkage
			if (linkage in llvm_functions): return llvm_constant_address(llvm_function_symbol(linkage))
			int import = llvm_import_of(node.binding)
			if ((import >= 0) && (load_int(table + retained_bindings[node.binding].origin + 10) == 2)): return llvm_constant_address(llvm_import_thunk(id, node.binding, import))
			llvm_error_at(id, c"reference to", node.binding_name)
			return c"0"
	if (llvm_place(&node)):
		char* address = llvm_address(group, operand)
		if ((type_class == llvm_class_struct) || (type_class == llvm_class_array)): return llvm_address_value(address)
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
			arguments.push(llvm_float_integer_argument(group, arg))
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
		if (target == llvm_class_struct): llvm_init_array_fields(pointer.target, llvm_pointer(object))
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
			arguments.push(llvm_float_integer_argument(group, arg))
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
		# new T(field=value, ...): zeroed heap storage from the runtime
		retained_type* pointer = llvm_type(type)
		if ((node.high == 0) || (pointer.pointer_level != 1) || (pointer.target < 0) || (llvm_class(pointer.target) != llvm_class_struct)):
			llvm_error(id, c"record allocation")
			return c"0"
		retained_type* record = llvm_type(pointer.target)
		list[char*] size = list[char*]{llvm_number(record.size)}
		char* object = llvm_helper_call(id, c"__w_new_object", size)
		size.free()
		llvm_init_array_fields(pointer.target, llvm_pointer(object))
		int entry = node.left
		while ((entry >= 0) && (llvm_failed == 0)):
			retained_node field
			retained_node_load(llvm_node_id(group, entry), &field)
			retained_node argument
			retained_node_load(llvm_node_id(group, field.left), &argument)
			if ((field.value < 0) || (field.value >= record.fields.length)):
				llvm_error(id, c"record field initializer")
				return c"0"
			retained_field* target = record.fields[field.value]
			char* value = llvm_convert(id, llvm_value(group, field.left), argument.semantic_type, target.type)
			llvm_owner_move(group, field.left, target.type)
			llvm_store(id, target.type, value, llvm_offset(llvm_pointer(object), llvm_number(target.offset)))
			entry = field.next_arg
		return object
	if ((op == 'P') || (op == 'y')):
		int helper = node.high
		if (op == 'y'): helper = node.value
		if (llvm_container_prelude_helper(op, helper)): return llvm_container_prelude(group, id, &node)
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
	if (op == 'Z'): return llvm_slice_range(group, id, &node)
	if (op == 'A'): return llvm_parallel_assign(group, id, &node)
	if (op == 'X'): return llvm_generator_create(group, id, &node)
	if (llvm_container_op(op)): return llvm_container_expression(group, id, &node)
	if ((op == 'C') || (op == 'F') || (op == 'G') || (op == 'W')):
		if ((op == 'C') && (node.binding < 0)):
			llvm_error(id, c"unbound call")
			return c"0"
		if ((type_class != llvm_class_word) && (type_class != llvm_class_void)):
			llvm_error(id, c"call result type")
			return c"0"
		return llvm_call(group, id, &node)
	if (op == '='):
		retained_node left
		retained_node_load(llvm_node_id(group, node.left), &left)
		retained_node right
		retained_node_load(llvm_node_id(group, node.right), &right)
		if (llvm_is_owner(left.semantic_type)): return llvm_owner_assign(group, id, &node)
		if (llvm_place(&left) == 0):
			llvm_error(id, c"assignment target")
			return c"0"
		char* address = llvm_address(group, node.left)
		char* value = c"0"
		int from = right.semantic_type
		if (node.value != 0):
			# '<<=' and '>>=' spell their operator 'l' and 'r'.
			int compound = node.value
			if (compound == 'l'): compound = 'L'
			else if (compound == 'r'): compound = 'R'
			char* before = llvm_load(left.semantic_type, address)
			value = llvm_value(group, node.right)
			if (llvm_float_kind(left.semantic_type) || llvm_float_kind(right.semantic_type)):
				int kind = 0
				value = llvm_float_binary(id, compound, before, left.semantic_type, value, right.semantic_type, &kind)
				value = llvm_float_coerce(value, kind, llvm_float_kind(left.semantic_type))
				from = left.semantic_type
			else: value = llvm_binary(id, compound, llvm_unsigned_word(left.semantic_type) || llvm_unsigned_word(right.semantic_type), before, value)
		else: value = llvm_value(group, node.right)
		value = llvm_convert(id, value, from, left.semantic_type)
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
		char* value = c"0"
		int float_kind = llvm_float_kind(left.semantic_type)
		if (float_kind):
			int kind = 0
			value = llvm_float_binary(id, node.value, before, left.semantic_type, llvm_float_coerce(c"1", 0, float_kind), left.semantic_type, &kind)
		else: value = llvm_binary(id, node.value, 0, before, c"1")
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
		char* a = llvm_float_branch(group, node.right, type)
		int a_block = llvm_block
		llvm_branch(end)
		llvm_label(no)
		char* b = llvm_float_branch(group, node.high, type)
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
		if (llvm_decays(llvm_operand_type(group, node.left), type)): value = llvm_load(-1, llvm_pointer(value))
		retained_node source
		retained_node_load(llvm_node_id(group, node.left), &source)
		# Float casts are coerce()'s conversions; a float cast to a narrow
		# integer keeps cvtt's whole word, as natively.
		if (llvm_float_kind(type) || llvm_float_kind(source.semantic_type)):
			if (llvm_type(type).pointer_level > 0): return value
			char* converted = llvm_float_coerce(value, llvm_float_kind(source.semantic_type), llvm_float_kind(type))
			if (llvm_narrow_float(type) && (llvm_narrow_float(type) != llvm_narrow_float(source.semantic_type))): return llvm_narrow_round(converted, llvm_narrow_float(type))
			return converted
		int width = llvm_width(type)
		retained_type* target = llvm_type(type)
		if ((width == 8) || (target.pointer_level > 0) || (strcmp(target.name, c"constant") == 0)): return value
		char* narrow = llvm_convert_op(c"trunc", c"i64", value, llvm_int_type(width))
		if (llvm_zero_extends(type)): return llvm_convert_op(c"zext", llvm_int_type(width), narrow, c"i64")
		return llvm_convert_op(c"sext", llvm_int_type(width), narrow, c"i64")
	if ((op == 'n') || (op == 'p') || (op == '~') || (op == '!') || (op == 'b')):
		char* value = llvm_value(group, node.left)
		if ((op == 'n') && llvm_float_kind(type)): return llvm_float_negate(value, llvm_float_kind(type))
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
		if (llvm_float_kind(left.semantic_type) || llvm_float_kind(right.semantic_type)):
			int kind = 0
			return llvm_float_binary(id, op, a, left.semantic_type, b, right.semantic_type, &kind)
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


# ---- Checked pointers ----------------------------------------------------
# Checked pointers (own/optown/ref/refmut/optref/optrefmut) use the plain
# pointer ABI, as natively (grammar/safe_cleanup.w). Unique owners add two
# behaviors the tree leaves implicit, reproduced here from types alone:
# transferring an owner out of a named local, parameter or owned field
# clears its source, and every owner in scope is dropped when its block
# ends or a jump leaves it (locals newest first, then a function's
# parameters on its exits). Dropping a null owner does nothing.

# Owners declared so far in the function being lowered, in declaration
# order, and the stack depth a break/continue unwinds to.
list[int] llvm_owner_stack
int llvm_loop_owner_mark


int llvm_is_owner(int type):
	if (type < 0): return 0
	int kind = llvm_type(type).kind
	return (kind == 21) || (kind == 29)


# ref T[] / refmut T[]: a {data, length} record value, not a slice handle.
int llvm_is_checked_slice(int type):
	if (type < 0): return 0
	int kind = llvm_type(type).kind
	return (kind == 24) || (kind == 30)


# The record (or scalar) an owner of type points at.
int llvm_owner_element(int type):
	retained_type* pointer = llvm_type(llvm_type(type).target)
	return pointer.target


# The audited destructor that replaces free for element, or -1
# (safe_owner_drop_helper).
int llvm_owner_helper(int id, int element):
	if (element < 0): return -1
	retained_type* t = llvm_type(element)
	char* name = t.name
	char* helper = 0
	if (ends_with(t.file, c"/lib/safe_thread.w")):
		if (strcmp(name, c"WSafeThread") == 0): helper = c"__w_safe_thread_drop"
		else if (starts_with(name, c"WSafeGuard$")): helper = c"__w_safe_guard_drop"
	else if (ends_with(t.file, c"/lib/safe_buffer.w")):
		if (strcmp(name, c"WIntBuffer") == 0): helper = c"__w_int_buffer_drop"
		else if (strcmp(name, c"WByteString") == 0): helper = c"__w_byte_string_drop"
		else if (strcmp(name, c"WOwnedIntBuffer") == 0): helper = c"__w_owned_int_buffer_drop"
		else if (strcmp(name, c"WByteArena") == 0): helper = c"__w_byte_arena_drop"
	if (helper == 0): return -1
	if ((helper in llvm_function_names) == 0):
		llvm_error_at(id, c"call to a missing runtime helper", helper)
		return -1
	return llvm_function_names[helper]


void llvm_owner_call(int id, int linkage, char* pointer):
	llvm_put(c"  call i64 ")
	llvm_put(llvm_function_symbol(linkage))
	llvm_put(c"(i64 ")
	llvm_put(pointer)
	llvm_put(c")\x0a")


void llvm_owner_free(int id, char* pointer):
	if ((c"free" in llvm_function_names) == 0):
		llvm_error_at(id, c"call to a missing runtime helper", c"free")
		return
	llvm_owner_call(id, llvm_function_names[c"free"], pointer)


# Drop the owned value pointer of owner type type: its owned fields in
# reverse declaration order, then the allocation (safe_owner_drop_value).
void llvm_owner_drop_value(int id, int type, char* pointer, int depth):
	if (depth > 32):
		llvm_error(id, c"recursive owned aggregate destruction")
		return
	int drop = llvm_label_new()
	int done = llvm_label_new()
	llvm_cond_branch(llvm_instruction(c"icmp ne", pointer, c"0"), drop, done)
	llvm_label(drop)
	int element = llvm_owner_element(type)
	int helper = llvm_owner_helper(id, element)
	if (helper >= 0): llvm_owner_call(id, helper, pointer)
	else:
		retained_type* record = llvm_type(element)
		int field = record.fields.length
		while (field > 0):
			field = field - 1
			retained_field* f = record.fields[field]
			if (llvm_is_owner(f.type)):
				char* child = llvm_load(f.type, llvm_offset(llvm_pointer(pointer), llvm_number(f.offset)))
				llvm_owner_drop_value(id, f.type, child, depth + 1)
		llvm_owner_free(id, pointer)
	llvm_branch(done)
	llvm_label(done)


# Drop the owner stored at address and clear it.
void llvm_owner_drop_slot(int id, int type, char* address):
	llvm_owner_drop_value(id, type, llvm_load(type, address), 0)
	llvm_store_width(8, c"0", address)


# Drop the owners declared since mark, newest first; with parameters, also
# the function's owner parameters (a function exit).
void llvm_owner_cleanup(int id, int mark, int parameters):
	if (llvm_terminated): llvm_label(llvm_label_new())
	int i = llvm_owner_stack.length
	while (i > mark):
		i = i - 1
		int binding = llvm_owner_stack[i]
		llvm_owner_drop_slot(id, retained_bindings[binding].type, llvm_name(c"%v", binding))
	if (parameters == 0): return
	list[int] owners = new list[int]
	int child = llvm_first[llvm_function_node]
	while ((child >= 0) && (retained_node_kind(child) == retained_local)):
		retained_node parameter
		retained_node_load(child, &parameter)
		if ((parameter.binding >= 0) && llvm_is_owner(retained_bindings[parameter.binding].type)): owners.push(parameter.binding)
		child = llvm_next[child]
	i = owners.length
	while (i > 0):
		i = i - 1
		llvm_owner_drop_slot(id, retained_bindings[owners[i]].type, llvm_name(c"%v", owners[i]))
	owners.free()


void llvm_owner_end_scope(int id, int mark):
	llvm_owner_cleanup(id, mark, 0)
	while (llvm_owner_stack.length > mark): llvm_owner_stack.pop()


void llvm_owner_declare(int binding):
	if (llvm_is_owner(retained_bindings[binding].type)): llvm_owner_stack.push(binding)


# Moving an owner into a destination of owner type clears its named source:
# a local or parameter, or an owned field along a named path
# (safe_owner_move).
void llvm_owner_move(int group, int operand, int destination):
	if ((llvm_is_owner(destination) == 0) || (operand < 0)): return
	retained_node source
	retained_node_load(llvm_node_id(group, operand), &source)
	if (llvm_is_owner(source.semantic_type) == 0): return
	if ((source.op == 'v') && (source.binding >= 0) && (source.binding in llvm_locals)):
		llvm_store_width(8, c"0", llvm_name(c"%v", source.binding))
	else if (source.op == '.'): llvm_store_width(8, c"0", llvm_address(group, operand))


# An assignment to an owner drops the value it replaces; returns its value.
char* llvm_owner_assign(int group, int id, retained_node* node):
	retained_node left
	retained_node_load(llvm_node_id(group, node.left), &left)
	retained_node right
	retained_node_load(llvm_node_id(group, node.right), &right)
	int type = left.semantic_type
	if ((node.value != 0) || ((left.op != '.') && ((left.op != 'v') || ((left.binding in llvm_locals) == 0)))):
		llvm_error(id, c"owner assignment target")
		return c"0"
	char* address = c"0"
	if (left.op == '.'): address = llvm_address(group, node.left)
	char* value = llvm_convert(id, llvm_value(group, node.right), right.semantic_type, type)
	llvm_owner_move(group, node.right, type)
	if (left.op == '.'): llvm_owner_drop_value(id, type, llvm_load(type, address), 0)
	else:
		address = llvm_name(c"%v", left.binding)
		llvm_owner_drop_slot(id, type, address)
	llvm_store_width(8, value, address)
	return value


# --- statements --------------------------------------------------------------

# Zero a local's storage, and point a fixed array's header at its data.
void llvm_local_init(int binding):
	int type = retained_bindings[binding].type
	char* address = llvm_name(c"%v", binding)
	int c = llvm_class(type)
	if ((c == llvm_class_struct) || (c == llvm_class_array)): llvm_memory_call(c"llvm.memset.p0.i64", address, 0, llvm_storage(type))
	else: llvm_store_width(8, c"0", address)
	if (c == llvm_class_array):
		llvm_store_width(8, llvm_address_value(llvm_offset(address, c"16")), address)
		llvm_store_width(8, llvm_number(llvm_type(type).array_length), llvm_offset(address, c"8"))
	if (c == llvm_class_struct): llvm_init_array_fields(type, address)


int llvm_starts_with_word(int id):
	retained_node node
	retained_node_load(id, &node)
	retained_source* source = retained_sources[node.source]
	if ((node.start < 0) || (node.start >= source.length)): return 1
	int c = source.bytes[node.start]
	return ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z')) || (c == '_') || (c >= 128)


void llvm_statement(int id);


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
	int previous_mark = llvm_loop_owner_mark
	llvm_break_label = done
	llvm_continue_label = next
	llvm_loop_owner_mark = llvm_owner_stack.length
	llvm_statement(body)
	llvm_break_label = previous_break
	llvm_continue_label = previous_continue
	llvm_loop_owner_mark = previous_mark
	llvm_branch(next)
	llvm_label(next)
	llvm_store(id, type, llvm_instruction(c"add", llvm_load(type, address), step), address)
	llvm_branch(head)
	llvm_label(done)
	llvm_reachable = entry_reachable
	arguments.free()
	values.free()


# --- containers --------------------------------------------------------------
# Built-in list[T], map[K, V] and set[T] values are runtime handles, one
# word each. Every operation is a call into structures/w_list.w or
# structures/hash_table.w (auto-imported, lowered like any W code) with
# the argument protocol of code_generator/expression_ast.w and
# grammar/for_statement.w; the protocol's slot sizes and key kinds come
# from the retained container types.

char* llvm_join(char* a, char* b):
	string_builder* text = string_new()
	string_append(text, a)
	string_append(text, b)
	char* result = retained_intern(text.data)
	string_free(text)
	return result


# 12 list, 10 map, 11 set; 0 for any other type.
int llvm_container_kind(int type):
	if (type < 0): return 0
	retained_type* t = llvm_type(type)
	if (t.pointer_level > 0): return 0
	if ((t.kind == 10) || (t.kind == 11) || (t.kind == 12)): return t.kind
	return 0


# A list's element, a set's key or a map's key.
int llvm_container_key(int type):
	return llvm_type(type).target


# A list's element or a map's value.
int llvm_container_value_type(int type):
	retained_type* t = llvm_type(type)
	if (t.kind == 10): return t.return_type
	return t.target


# grammar/list_builtin.w's list_element_slot_size: record slots round up
# to whole words.
int llvm_slot_size(int type):
	if (type < 0): return 8
	if (llvm_class(type) == llvm_class_struct):
		int size = (llvm_type(type).size + 7) & (0 - 8)
		if (size < 8): size = 8
		return size
	# an untyped constant infers int
	if (llvm_type(type).size < 1): return 8
	return llvm_type(type).size


# grammar/hash_builtin.w's hash_key_kind_for_type: 3 string, 2 char*, 1 word.
int llvm_key_kind(int type):
	if (llvm_is_string(type)): return 3
	if (llvm_is_char_pointer(type)): return 2
	return 1


int llvm_is_record(int type):
	return llvm_class(type) == llvm_class_struct


char* llvm_call1(int id, char* name, char* a):
	list[char*] values = list[char*]{a}
	char* result = llvm_helper_call(id, name, values)
	values.free()
	return result


char* llvm_call2(int id, char* name, char* a, char* b):
	list[char*] values = list[char*]{a, b}
	char* result = llvm_helper_call(id, name, values)
	values.free()
	return result


char* llvm_call3(int id, char* name, char* a, char* b, char* c):
	list[char*] values = list[char*]{a, b, c}
	char* result = llvm_helper_call(id, name, values)
	values.free()
	return result


int llvm_operand_type(int group, int operand):
	retained_node node
	retained_node_load(llvm_node_id(group, operand), &node)
	return node.semantic_type


# The operand's value, coerced to a container's key or element type.
char* llvm_container_operand(int group, int operand, int want):
	char* value = llvm_value(group, operand)
	return llvm_convert(llvm_node_id(group, operand), value, llvm_operand_type(group, operand), want)


# A new container of the given type, as hash_emit_new_container and
# list_emit_new_container build it.
char* llvm_container_new(int id, int type):
	int kind = llvm_container_kind(type)
	if (kind == 12): return llvm_call1(id, c"__w_list_new", llvm_number(llvm_slot_size(llvm_container_key(type))))
	if (kind == 11): return llvm_call1(id, c"__w_set_new", llvm_number(llvm_key_kind(llvm_container_key(type))))
	if (kind == 10): return llvm_call2(id, c"__w_map_new", llvm_number(llvm_key_kind(llvm_container_key(type))), llvm_number(llvm_type(llvm_container_value_type(type)).size))
	llvm_error(id, c"container type")
	return c"0"


# grammar/hash_builtin.w's hash_default_container_descriptor.
int llvm_default_descriptor(int type):
	int kind = llvm_container_kind(type)
	if (kind == 12): return 3 | (llvm_slot_size(llvm_container_key(type)) << 5)
	if (kind == 11): return 2 | (llvm_key_kind(llvm_container_key(type)) << 2)
	int value = llvm_container_value_type(type)
	int desc = 1 | (llvm_key_kind(llvm_container_key(type)) << 2)
	desc = desc | (llvm_type(value).size << 5)
	# hash_default_inner_zero: plain arithmetic scalars default to zero
	int scalar = (llvm_class(value) == llvm_class_word) && (llvm_container_kind(value) == 0) && (llvm_is_string(value) == 0) && (llvm_type(value).pointer_level == 0)
	if (scalar): desc = desc | 16
	return desc


# ast_expression_method_helper (compiler/expression_ast.w).
char* llvm_method_helper(int method):
	method = method & 255
	if (method == 11): return c"__w_map_remove"
	if (method == 12): return c"__w_set_add"
	if (method == 13): return c"__w_map_free"
	if (method == 14): return c"__w_map_get"
	if (method == 15): return c"__w_map_get_or"
	if (method == 16): return c"__w_map_keys"
	if (method == 17): return c"__w_map_values"
	if (method == 18): return c"__w_map_add"
	if (method == 142): return c"__w_map_get_addr"
	if (method == 143): return c"__w_map_get_or_addr"
	if (method == 129): return c"__w_list_push_bytes"
	if (method == 130): return c"__w_list_pop_addr"
	if (method == 131): return c"__w_list_insert_bytes"
	if (method == 1): return c"__w_list_push"
	if (method == 2): return c"__w_list_pop"
	if (method == 3): return c"__w_list_insert"
	if (method == 4): return c"__w_list_remove"
	if (method == 5): return c"__w_list_clear"
	if (method == 6): return c"__w_list_free"
	if (method == 20): return c"__w_list_sort"
	if (method == 21): return c"__w_list_sorted"
	if (method == 22): return c"__w_list_sum"
	if (method == 23): return c"__w_list_min"
	if (method == 24): return c"__w_list_max"
	if (method == 25): return c"__w_list_reverse"
	if (method == 26): return c"__w_list_reversed"
	if (method == 27): return c"__w_list_count"
	if (method == 28): return c"__w_list_index"
	if (method == 30): return c"__w_list_sort_by"
	if (method == 31): return c"__w_list_sorted_by"
	if (method == 32): return c"__w_list_map"
	if (method == 33): return c"__w_list_filter"
	if (method == 34): return c"__w_list_reduce"
	if (method == 158): return c"__w_list_sort_by_addr"
	if (method == 159): return c"__w_list_sorted_by_addr"
	return 0


# A container method call ('M'): the receiver, each argument coerced as
# the native emitter coerces it, then the method's trailing constant.
char* llvm_container_method(int group, int id, retained_node* node):
	int container = llvm_operand_type(group, node.left)
	int kind = llvm_container_kind(container)
	int method = node.value & 127
	char* helper = llvm_method_helper(node.value)
	if ((kind == 0) || (helper == 0)):
		llvm_error_at(id, c"method call", llvm_number(node.value))
		return c"0"
	int key = llvm_container_key(container)
	int value_type = -1
	if (kind == 10): value_type = llvm_container_value_type(container)
	if ((method == 18) && (llvm_class(value_type) != llvm_class_word)):
		llvm_error(id, c"map add of this value type")
		return c"0"
	list[char*] values = new list[char*]
	values.push(llvm_value(group, node.left))
	int arg = node.right
	int count = 0
	while ((arg >= 0) && (llvm_failed == 0)):
		int want = -1
		if ((method == 1) || ((method == 3) && (count == 1))): want = key
		if ((((method >= 11) && (method <= 18)) || (method == 27) || (method == 28)) && (count == 0)): want = key
		if (((method == 15) || (method == 18)) && (count == 1)): want = value_type
		retained_node argument
		retained_node_load(llvm_node_id(group, arg), &argument)
		char* value = llvm_value(group, arg)
		if (want >= 0): value = llvm_convert(id, value, argument.semantic_type, want)
		values.push(value)
		count = count + 1
		arg = argument.next_arg
	# m.add(key) adds one
	if ((method == 18) && (count == 1)): values.push(c"1")
	if ((method == 16) || (method == 17)): values.push(llvm_number(node.high))
	if ((method == 20) || (method == 21) || (method == 27) || (method == 28)): values.push(llvm_number(llvm_key_kind(key)))
	if (method == 32): values.push(llvm_number(llvm_slot_size(llvm_container_key(node.semantic_type))))
	char* result = llvm_helper_call(id, helper, values)
	values.free()
	return result


# m[key] read: the value word, or a record value's slot address.
char* llvm_map_read(int group, int id, retained_node* node):
	int map = llvm_operand_type(group, node.left)
	char* table = llvm_value(group, node.left)
	char* key = llvm_container_operand(group, node.right, llvm_container_key(map))
	char* helper = c"__w_map_get"
	if (llvm_is_record(llvm_container_value_type(map))): helper = c"__w_map_get_addr"
	return llvm_call2(id, helper, table, key)


# m[key] = value and m[key] op= value ('w'; its left is the 'm' node).
char* llvm_map_store(int group, int id, retained_node* node):
	retained_node index
	retained_node_load(llvm_node_id(group, node.left), &index)
	int map = llvm_operand_type(group, index.left)
	int element = llvm_container_value_type(map)
	char* table = llvm_value(group, index.left)
	char* key = llvm_container_operand(group, index.right, llvm_container_key(map))
	int right_type = llvm_operand_type(group, node.right)
	char* value = c"0"
	if (node.value != 0):
		if (llvm_class(element) != llvm_class_word):
			llvm_error(id, c"compound map assignment of this type")
			return c"0"
		char* before = llvm_call2(id, c"__w_map_get", table, key)
		value = llvm_value(group, node.right)
		value = llvm_binary(id, node.value, llvm_unsigned_word(element) || llvm_unsigned_word(right_type), before, value)
	else: value = llvm_value(group, node.right)
	value = llvm_convert(id, value, right_type, element)
	char* helper = c"__w_map_set"
	if (llvm_is_record(element) && llvm_is_record(right_type)): helper = c"__w_map_set_bytes"
	llvm_call3(id, helper, table, key, value)
	return value


# A container literal ('O'): a new container, then each entry pushed,
# added or set in order.
char* llvm_container_literal(int group, int id, retained_node* node):
	int type = node.semantic_type
	int kind = llvm_container_kind(type)
	char* container = llvm_container_new(id, type)
	int entry = node.left
	while ((entry >= 0) && (llvm_failed == 0)):
		retained_node item
		retained_node_load(llvm_node_id(group, entry), &item)
		if (kind == 10):
			char* key = llvm_container_operand(group, item.left, llvm_container_key(type))
			char* value = llvm_container_operand(group, item.right, llvm_container_value_type(type))
			char* helper = c"__w_map_set"
			if (item.value): helper = c"__w_map_set_bytes"
			llvm_call3(id, helper, container, key, value)
		else if (kind == 12):
			char* element = llvm_container_operand(group, item.left, llvm_container_key(type))
			char* helper = c"__w_list_push"
			if (item.value): helper = c"__w_list_push_bytes"
			llvm_call2(id, helper, container, element)
		else: llvm_call2(id, c"__w_set_add", container, llvm_container_operand(group, item.left, llvm_container_key(type)))
		entry = item.next_arg
	return container


# new list[T], new set[T], new map[K, V] and new map[K, V](default) ('V').
char* llvm_container_allocation(int group, int id, retained_node* node):
	int type = node.semantic_type
	char* container = llvm_container_new(id, type)
	if (node.high == 0): return container
	char* value = c"0"
	if (node.high == 3): value = llvm_number(llvm_default_descriptor(llvm_container_value_type(type)))
	else:
		value = llvm_value(group, node.left)
		if (node.high == 1): value = llvm_convert(id, value, llvm_operand_type(group, node.left), llvm_container_value_type(type))
	llvm_call3(id, c"__w_map_set_default", container, llvm_number(node.high), value)
	return container


# A word of stack in the function's entry block.
char* llvm_entry_slot():
	char* slot = llvm_temp()
	string_append(llvm_entry, c"  ")
	string_append(llvm_entry, slot)
	string_append(llvm_entry, c" = alloca i64, align 8\x0a")
	return slot


# The hidden 'it' slots of the enclosing l.method(<expression of it>)
# forms, innermost last: 'it' names the innermost one.
list[char*] llvm_it_slots


char* llvm_it_slot(int id):
	if ((llvm_it_slots == 0) || (llvm_it_slots.length == 0)):
		llvm_error(id, c"'it' outside a list method")
		return c"null"
	return llvm_it_slots[llvm_it_slots.length - 1]


# l.method(<expression of it>) (ast_list_it): evaluate the expression once
# per element into a lazily built key list, then hand the keys to the
# method's runtime helper, as code_generator/expression_ast.w does.
char* llvm_list_it(int group, int id, retained_node* node):
	int mode = node.value
	int element = llvm_container_key(llvm_operand_type(group, node.left))
	int key_type = llvm_operand_type(group, node.right)
	int key_size = llvm_slot_size(key_type)
	if (llvm_class(key_type) != llvm_class_word):
		llvm_error(id, c"list method key of this type")
		return c"0"
	char* list = llvm_value(group, node.left)
	char* cursor = llvm_entry_slot()
	char* keys = llvm_entry_slot()
	char* it = llvm_entry_slot()
	llvm_store_width(8, c"0", cursor)
	llvm_store_width(8, c"0", keys)
	char* value_fn = c"__w_list_iter_value"
	if (llvm_is_record(element)): value_fn = c"__w_list_addr"
	int head = llvm_label_new()
	int yes = llvm_label_new()
	int done = llvm_label_new()
	llvm_branch(head)
	llvm_label(head)
	char* index = llvm_load(-1, cursor)
	char* length = llvm_load(-1, llvm_offset(llvm_pointer(list), c"8"))
	llvm_cond_branch(llvm_instruction(c"icmp slt", index, length), yes, done)
	llvm_label(yes)
	llvm_store_width(8, llvm_call2(id, value_fn, list, index), it)
	if (llvm_it_slots == 0): llvm_it_slots = new list[char*]
	llvm_it_slots.push(it)
	char* key = llvm_value(group, node.right)
	llvm_it_slots.pop()
	llvm_store_width(8, llvm_call3(id, c"__w_list_push_lazy", llvm_load(-1, keys), key, llvm_number(key_size)), keys)
	llvm_store_width(8, llvm_instruction(c"add", index, c"1"), cursor)
	llvm_branch(head)
	llvm_label(done)
	char* gathered = llvm_call2(id, c"__w_list_or_new", llvm_load(-1, keys), llvm_number(key_size))
	int kind = llvm_key_kind(key_type)
	if (mode == 0): return gathered
	if (mode == 1): return llvm_call2(id, c"__w_list_filter_keys", list, gathered)
	if ((mode >= 2) && (mode <= 5)): return llvm_call2(id, c"__w_list_truth", gathered, llvm_number(mode - 2))
	if (mode == 6): return llvm_call1(id, c"__w_list_sum", gathered)
	if (mode == 7): return llvm_call1(id, c"__w_list_min", gathered)
	if (mode == 8): return llvm_call1(id, c"__w_list_max", gathered)
	if (mode == 9): return llvm_call3(id, c"__w_list_sort_keys", list, gathered, llvm_number(kind))
	if (mode == 10): return llvm_call3(id, c"__w_list_sorted_keys", list, gathered, llvm_number(kind))
	# min_by / max_by: the best element itself
	char* best = llvm_call2(id, c"__w_list_best_key", gathered, llvm_number(kind | ((mode - 11) << 2)))
	char* address = llvm_call2(id, c"__w_list_addr", list, best)
	if (llvm_is_record(element)): return address
	return llvm_load(element, llvm_pointer(address))


# Prelude builtins over containers and stdin (grammar/print_builtin.w's
# helper table): print(list) 4, input() 6, read_all() 7, ints() 8,
# any/all 14/15, lines()/words() 16/17, split 18, join 19 and len 21.
int llvm_container_prelude_helper(int op, int helper):
	if (op == 'P'): return helper == 4
	return ((helper >= 6) && (helper <= 8)) || ((helper >= 14) && (helper <= 21))


char* llvm_container_prelude(int group, int id, retained_node* node):
	if (node.op == 'P'):
		# __w_print_list(list, kind): 4 string, 2 char* or 3 word elements
		int element = llvm_container_key(llvm_operand_type(group, node.left))
		int kind = 3
		if (llvm_is_string(element)): kind = 4
		else if (llvm_is_char_pointer(element)): kind = 2
		llvm_call2(id, c"__w_print_list", llvm_value(group, node.left), llvm_number(kind))
		if (node.value != 0):
			list[char*] none = new list[char*]
			llvm_helper_call(id, c"__w_print_nl", none)
			none.free()
		return c"0"
	int helper = node.value
	if (helper == 20): return llvm_enum_name(group, id, node)
	if (helper == 21):
		# len(x): strlen of a char*, else the length word of a container,
		# string or buffer
		char* value = llvm_value(group, node.left)
		if (node.high): return llvm_call1(id, c"strlen", value)
		return llvm_load(-1, llvm_offset(llvm_pointer(value), c"8"))
	list[char*] values = new list[char*]
	int arg = node.left
	while ((arg >= 0) && (llvm_failed == 0)):
		values.push(llvm_value(group, arg))
		if ((helper == 18) && (arg == node.left)):
			values.push(llvm_number(node.high))
			retained_node first
			retained_node_load(llvm_node_id(group, arg), &first)
			if (first.next_arg < 0): values.push(c"0")
		retained_node argument
		retained_node_load(llvm_node_id(group, arg), &argument)
		arg = argument.next_arg
	if (helper == 19): values.push(llvm_number(node.high))
	char* name = c"input"
	if (helper == 7): name = c"read_all"
	if (helper == 8): name = c"ints"
	if (helper == 14): name = c"__w_any"
	if (helper == 15): name = c"__w_all"
	if (helper == 16): name = c"__w_lines"
	if (helper == 17): name = c"__w_words"
	if (helper == 18): name = c"__w_split"
	if (helper == 19): name = c"__w_join"
	char* result = llvm_helper_call(id, name, values)
	values.free()
	return result


int llvm_container_op(int op):
	return (op == 'V') || (op == 'O') || (op == 'M') || (op == 'm') || (op == 'q') || (op == 'w') || (op == 'H') || (op == 'J') || (op == 133)


char* llvm_container_expression(int group, int id, retained_node* node):
	int op = node.op
	if (op == 'V'): return llvm_container_allocation(group, id, node)
	if (op == 'O'): return llvm_container_literal(group, id, node)
	if (op == 'M'): return llvm_container_method(group, id, node)
	if ((op == 'm') || (op == 'q')): return llvm_map_read(group, id, node)
	if (op == 'w'): return llvm_map_store(group, id, node)
	if (op == 133): return llvm_list_it(group, id, node)
	if (op == 'H'):
		# key in container: the key is evaluated first
		int container = llvm_operand_type(group, node.right)
		char* key = llvm_container_operand(group, node.left, llvm_container_key(container))
		char* handle = llvm_value(group, node.right)
		char* helper = c"__w_list_contains"
		if (node.value == 1): helper = c"__w_map_contains"
		if (node.value == 2): helper = c"__w_set_contains"
		if (node.value == 3): helper = c"__w_list_contains_cstr"
		return llvm_extend(llvm_bool(llvm_call2(id, helper, handle, key)))
	# l[start:end] copies the range into a new list
	char* list = llvm_value(group, node.left)
	char* start = c"0"
	if (node.right >= 0): start = llvm_value(group, node.right)
	char* end = c"0"
	if (node.high >= 0): end = llvm_value(group, node.high)
	list[char*] values = list[char*]{list, start, end, llvm_number(node.high >= 0)}
	char* result = llvm_helper_call(id, c"__w_list_slice", values)
	values.free()
	return result


# l[index]: the element's address from __w_list_addr, a normal place.
char* llvm_list_element(int group, int id, retained_node* node):
	char* list = llvm_value(group, node.left)
	char* index = llvm_value(group, node.right)
	return llvm_pointer(llvm_call2(id, c"__w_list_addr", list, index))


int llvm_word_byte(int c):
	return ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z')) || ((c >= '0') && (c <= '9')) || (c == '_')


# Offset of the binding's name as a whole word in the for header (the
# statement's text before its iterable).
int llvm_header_position(int id, int group, int binding):
	retained_node statement
	retained_node_load(id, &statement)
	retained_node iterable
	retained_node_load(group, &iterable)
	retained_source* source = retained_sources[statement.source]
	char* name = retained_bindings[binding].name
	int length = strlen(name)
	int at = statement.start + 3
	while ((at + length <= iterable.start) && (at + length <= source.length)):
		int matched = 1
		for i in range(length):
			if (source.bytes[at + i] != name[i]): matched = 0
		int after = source.bytes[at + length]
		int before = source.bytes[at - 1]
		if (matched && (llvm_word_byte(before) == 0) && (llvm_word_byte(after) == 0)): return at
		at = at + 1
	return iterable.start


# for x in l, for i, x in l, for k in m, for k, v in m, for k in s:
# for_cursor_loop's begin/done/value/next protocol. The container is
# evaluated once; the cursor is a phi over the loop.
void llvm_container_for(int id):
	int entry_reachable = llvm_reachable
	int group = -1
	int body = -1
	list[int] variables = new list[int]
	int child = llvm_first[id]
	while (child >= 0):
		int kind = retained_node_kind(child)
		if ((kind == retained_expression_group) && (group < 0)): group = child
		else if (kind == retained_local):
			retained_node local
			retained_node_load(child, &local)
			variables.push(local.binding)
		else if ((kind == retained_statement) && (body < 0)): body = child
		else: llvm_error(id, c"for statement shape")
		child = llvm_next[child]
	if ((group < 0) || (body < 0) || (variables.length < 1) || (variables.length > 2)):
		llvm_error(id, c"for statement shape")
		variables.free()
		return
	# Typed loop variables are recorded before the iterable and inferred
	# ones after it, so order the two by where the header names them.
	if ((variables.length == 2) && (llvm_header_position(id, group, variables[1]) < llvm_header_position(id, group, variables[0]))):
		int swap = variables[0]
		variables[0] = variables[1]
		variables[1] = swap
	for i in range(variables.length):
		if ((variables[i] < 0) || ((variables[i] in llvm_locals) == 0)): llvm_error(id, c"for loop variable")
	int type = llvm_group_type(group)
	int kind = llvm_container_kind(type)
	# Other iterables (for_container_loop): 1 a fixed array or slice by
	# index, 2 a string's code points (lib.utf8), 3 a struct pointer's
	# T_iter_begin/done/next/value functions.
	int sequence = 0
	int element = -1
	char* custom = 0
	int generator = 0
	if ((kind == 0) && (type >= 0)):
		retained_type* t = llvm_type(type)
		if ((t.pointer_level == 0) && ((t.kind == 6) || (t.kind == 7) || (t.kind == 9))):
			sequence = 1
			element = t.target
			if (llvm_class(element) != llvm_class_word): llvm_error_at(id, c"for loop over", t.name)
		else if (llvm_is_string(type)): sequence = 2
		else if ((t.pointer_level == 1) && (t.target >= 0) && (llvm_class(t.target) == llvm_class_struct)):
			sequence = 3
			custom = llvm_join(llvm_type(t.target).name, c"_iter_")
			generator = strcmp(llvm_type(t.target).name, c"generator") == 0
	if ((kind == 0) && (sequence == 0)):
		if (type >= 0): llvm_error_at(id, c"for loop over", retained_types[type].name)
		else: llvm_error(id, c"for loop iterable")
	if ((kind == 11) && (variables.length == 2)): llvm_error(id, c"two loop variables over a set")
	if ((sequence != 0) && (variables.length == 2)): llvm_error(id, c"two loop variables over this iterable")
	if (llvm_failed):
		variables.free()
		return
	char* prefix = c"__w_list_iter_"
	if (kind != 12): prefix = c"__w_map_iter_"
	if (sequence == 3): prefix = custom
	char* container = llvm_group(group)
	char* begin = c"0"
	if ((sequence == 0) || (sequence == 3)): begin = llvm_call1(id, llvm_join(prefix, c"begin"), container)
	int before = llvm_block
	char* cursor = llvm_temp()
	char* advanced = llvm_temp()
	int head = llvm_label_new()
	int yes = llvm_label_new()
	int next = llvm_label_new()
	int done = llvm_label_new()
	llvm_branch(head)
	llvm_label(head)
	llvm_put(c"  ")
	llvm_put(cursor)
	llvm_put(c" = phi i64 [ ")
	llvm_put(begin)
	llvm_put(c", %b")
	llvm_put(llvm_number(before))
	llvm_put(c" ], [ ")
	llvm_put(advanced)
	llvm_put(c", %b")
	llvm_put(llvm_number(next))
	llvm_put(c" ]\x0a")
	char* finished = c"0"
	if ((sequence == 1) || (sequence == 2)):
		# a slice, array header or string: {data, length}
		finished = llvm_extend(llvm_instruction(c"icmp sge", cursor, llvm_load(-1, llvm_offset(llvm_pointer(container), c"8"))))
	else: finished = llvm_call2(id, llvm_join(prefix, c"done"), container, cursor)
	llvm_cond_branch(llvm_bool(finished), done, yes)
	llvm_label(yes)
	int first_storage = retained_bindings[variables[0]].type
	char* first = c"0"
	if (sequence == 1):
		char* data = llvm_pointer(llvm_load(-1, llvm_pointer(container)))
		char* offset = llvm_instruction(c"mul", cursor, llvm_number(llvm_type(element).size))
		first = llvm_convert(id, llvm_load(element, llvm_offset(data, offset)), element, first_storage)
	else if (sequence == 2): first = llvm_call2(id, c"utf8_decode", container, cursor)
	else if (sequence == 3): first = llvm_call2(id, llvm_join(prefix, c"value"), container, cursor)
	else:
		# The first variable: a list element (its index when there are two)
		# or a map or set key. Record elements bind their slot's address.
		element = llvm_container_key(type)
		char* first_helper = c"__w_map_iter_key"
		int first_type = element
		if (kind == 12):
			first_helper = c"__w_list_iter_value"
			if (llvm_is_record(element)):
				first_helper = c"__w_list_addr"
				first_type = -1
			if (variables.length == 2):
				first_helper = c"__w_list_iter_index"
				first_type = -1
		first = llvm_call2(id, first_helper, container, cursor)
		if (first_type >= 0): first = llvm_convert(id, first, first_type, first_storage)
	llvm_store(id, first_storage, first, llvm_name(c"%v", variables[0]))
	if (variables.length == 2):
		int value_type = llvm_container_value_type(type)
		char* second_helper = c"__w_map_iter_value"
		if (kind == 12): second_helper = c"__w_list_iter_value"
		if (llvm_is_record(value_type)):
			second_helper = c"__w_map_iter_value_addr"
			if (kind == 12): second_helper = c"__w_list_addr"
		int second_storage = retained_bindings[variables[1]].type
		char* second = llvm_call2(id, second_helper, container, cursor)
		if (llvm_is_record(value_type) == 0): second = llvm_convert(id, second, value_type, second_storage)
		llvm_store(id, second_storage, second, llvm_name(c"%v", variables[1]))
	int previous_break = llvm_break_label
	int previous_continue = llvm_continue_label
	llvm_break_label = done
	llvm_continue_label = next
	if (generator): llvm_generator_loop(container, 1)
	llvm_statement(body)
	if (generator): llvm_generator_loop(container, 0)
	llvm_break_label = previous_break
	llvm_continue_label = previous_continue
	llvm_branch(next)
	llvm_label(next)
	char* stepped = c"0"
	if (sequence == 1): stepped = llvm_instruction(c"add", cursor, c"1")
	else if (sequence == 2): stepped = llvm_call2(id, c"utf8_next", container, cursor)
	else: stepped = llvm_call2(id, llvm_join(prefix, c"next"), container, cursor)
	llvm_put(c"  ")
	llvm_put(advanced)
	llvm_put(c" = add i64 ")
	llvm_put(stepped)
	llvm_put(c", 0\x0a")
	llvm_branch(head)
	llvm_label(done)
	if (generator): llvm_call1(id, c"gen_free", container)
	llvm_reachable = entry_reachable
	variables.free()

# --- end of containers -------------------------------------------------------


# --- slices, parallel assignment and enum_name ------------------------------
# base[start:end] over an array, slice or string, as grammar/postfix_expr.w
# lowers it: trap unless 0 <= start <= end <= length, then return a fresh
# malloc'd {data + start * element size, end - start} descriptor that
# names the range in place (the legacy, unchecked-slice ABI).
char* llvm_slice_range(int group, int id, retained_node* node):
	int base_type = llvm_operand_type(group, node.left)
	int element_size = 1
	if (llvm_is_string(base_type) == 0):
		retained_type* t = llvm_type(base_type)
		if ((t.target >= 0) && (llvm_type(t.target).size > 1)): element_size = llvm_type(t.target).size
	char* descriptor = llvm_pointer(llvm_value(group, node.left))
	char* start = c"0"
	if (node.right >= 0): start = llvm_value(group, node.right)
	char* end = 0
	if (node.high >= 0): end = llvm_value(group, node.high)
	char* length = llvm_load(-1, llvm_offset(descriptor, c"8"))
	if (end == 0): end = length
	char* invalid = llvm_instruction(c"icmp slt", start, c"0")
	invalid = llvm_op(c"or", c"i1", invalid, llvm_instruction(c"icmp slt", end, c"0"))
	invalid = llvm_op(c"or", c"i1", invalid, llvm_instruction(c"icmp sgt", end, length))
	invalid = llvm_op(c"or", c"i1", invalid, llvm_instruction(c"icmp sgt", start, end))
	llvm_trap_if(invalid)
	char* offset = start
	if (element_size > 1): offset = llvm_instruction(c"mul", start, llvm_number(element_size))
	char* data = llvm_instruction(c"add", llvm_load(-1, descriptor), offset)
	char* result = llvm_call1(id, c"malloc", llvm_number(16))
	char* slot = llvm_pointer(result)
	llvm_store_width(8, data, slot)
	llvm_store_width(8, llvm_instruction(c"sub", end, start), llvm_offset(slot, c"8"))
	return result


# a, b = b, a (emit_ast_parallel): every target's address, then every
# value, then the stores. The 'A' node chains 'T' pairs (left = target,
# right = value) through next_arg.
char* llvm_parallel_assign(int group, int id, retained_node* node):
	list[char*] addresses = new list[char*]
	list[char*] values = new list[char*]
	list[int] types = new list[int]
	int pair = node.left
	while ((pair >= 0) && (llvm_failed == 0)):
		retained_node p
		retained_node_load(llvm_node_id(group, pair), &p)
		retained_node target
		retained_node_load(llvm_node_id(group, p.left), &target)
		if ((llvm_place(&target) == 0) || (llvm_class(target.semantic_type) != llvm_class_word)): llvm_error(id, c"parallel assignment target")
		else:
			addresses.push(llvm_address(group, p.left))
			types.push(target.semantic_type)
		pair = p.next_arg
	pair = node.left
	int i = 0
	while ((pair >= 0) && (llvm_failed == 0)):
		retained_node p
		retained_node_load(llvm_node_id(group, pair), &p)
		values.push(llvm_convert(id, llvm_value(group, p.right), llvm_operand_type(group, p.right), types[i]))
		i = i + 1
		pair = p.next_arg
	if (llvm_failed == 0):
		for j in range(addresses.length): llvm_store(id, types[j], values[j], addresses[j])
	addresses.free()
	values.free()
	types.free()
	return c"0"


# enum_name(e) (prelude_emit_enum_name): __w_enum_name over a table of
# "value\0name\0" entries for the enum's constants, ending in an empty one.
char* llvm_enum_name(int group, int id, retained_node* node):
	retained_type* t = llvm_type(llvm_operand_type(group, node.left))
	string_builder* table = string_new()
	for entry in t.constants:
		char* digits = itoa(entry.value)
		string_append(table, digits)
		string_append_char(table, 0)
		string_append(table, entry.name)
		string_append_char(table, 0)
		free(digits)
	char* text = llvm_address_value(llvm_string_constant(table.data, table.length))
	string_free(table)
	return llvm_call2(id, c"__w_enum_name", text, llvm_value(group, node.left))
# --- end of slices, parallel assignment and enum_name ------------------------


# --- generators --------------------------------------------------------------
# Stackful coroutines (lib/generator.w, grammar/generator_decl.w). A
# generator body is an ordinary function with the hidden trailing
# __w_gen_self parameter; yield and return call __w_gen_yield and
# __w_gen_return. A call builds argv and calls __w_gen_create with a
# per-generator entry thunk in place of the body: __w_gen_create seeds
# the new stack for the native stack-argument convention (a zero return
# address, then self, then the arguments last-first), so the thunk reads
# them above its return address and calls the body with register
# arguments. gen_switch is module assembly with the native stub's
# register protocol.

# Generator linkage -> argument count, for the thunks.
map[int, int] llvm_generator_thunks
# Handles of the enclosing generator cursor loops, innermost last: a
# return frees them first (for_cleanup_emit_all).
list[char*] llvm_generator_loops


# Record the body's hidden self parameter, if this is a generator.
void llvm_generator_begin(int id):
	llvm_generator_self = -1
	if (cast(int, llvm_generator_loops) != 0): llvm_generator_loops.clear()
	int child = llvm_first[id]
	while ((child >= 0) && (retained_node_kind(child) == retained_local)):
		retained_node parameter
		retained_node_load(child, &parameter)
		if (strcmp(parameter.name, c"__w_gen_self") == 0): llvm_generator_self = parameter.binding
		child = llvm_next[child]


char* llvm_generator_self_value():
	return llvm_load(-1, llvm_name(c"%v", llvm_generator_self))


void llvm_generator_finish(int id):
	llvm_call1(id, c"__w_gen_return", llvm_generator_self_value())
	# __w_gen_return never comes back; the thunk traps if it did.
	llvm_put(c"  ret i64 0\x0a")
	llvm_terminated = 1
	llvm_reachable = 0


void llvm_generator_yield(int id):
	int group = llvm_first[id]
	if ((llvm_generator_self < 0) || (group < 0) || (retained_node_kind(group) != retained_expression_group)):
		llvm_error(id, c"yield outside a generator")
		return
	int yield_type = retained_bindings[llvm_function].return_type
	char* value = llvm_convert(id, llvm_group(group), llvm_group_type(group), yield_type)
	llvm_call2(id, c"__w_gen_yield", llvm_generator_self_value(), value)


void llvm_generator_loop(char* container, int open):
	if (cast(int, llvm_generator_loops) == 0): llvm_generator_loops = new list[char*]
	if (open): llvm_generator_loops.push(container)
	else: llvm_generator_loops.pop()


void llvm_generator_free_loops(int id):
	if (cast(int, llvm_generator_loops) == 0): return
	int i = llvm_generator_loops.length
	while (i > 0):
		i = i - 1
		llvm_call1(id, c"gen_free", llvm_generator_loops[i])


# counter(a, b) -> __w_gen_create(thunk, argv, argc), argv[0] the last
# argument (generator_call_suffix).
char* llvm_generator_create(int group, int id, retained_node* node):
	retained_binding* callee = retained_bindings[node.binding]
	if ((callee.linkage in llvm_functions) == 0):
		llvm_error_at(id, c"generator without a W body", callee.name)
		return c"0"
	# The entry thunk and gen_switch follow the x86-64 stack layout.
	if (llvm_arm64):
		llvm_error_at(id, c"AArch64 generator", callee.name)
		return c"0"
	list[char*] values = new list[char*]
	int arg = node.left
	while ((arg >= 0) && (llvm_failed == 0)):
		int want = -1
		if (values.length < callee.parameters.length): want = callee.parameters[values.length]
		values.push(llvm_container_operand(group, arg, want))
		retained_node argument
		retained_node_load(llvm_node_id(group, arg), &argument)
		arg = argument.next_arg
	int count = values.length
	if (count != callee.parameters.length): llvm_error_at(id, c"generator call argument count", callee.name)
	if (llvm_failed):
		values.free()
		return c"0"
	char* argv = llvm_temp()
	string_append(llvm_entry, c"  ")
	string_append(llvm_entry, argv)
	string_append(llvm_entry, c" = alloca [")
	string_append_int(llvm_entry, count + 1)
	string_append(llvm_entry, c" x i64], align 8\x0a")
	for i in range(count): llvm_store_width(8, values[i], llvm_offset(argv, llvm_number((count - 1 - i) * 8)))
	values.free()
	llvm_function_symbol(callee.linkage)
	llvm_generator_thunks[callee.linkage] = count
	char* thunk = llvm_address_value(llvm_name(c"@wg", callee.linkage))
	return llvm_call3(id, c"__w_gen_create", thunk, llvm_address_value(argv), llvm_number(count))


char* llvm_generator_switch(int id, list[char*] values):
	if (llvm_arm64):
		llvm_error(id, c"AArch64 generator switch")
		return c"0"
	llvm_uses_gen_switch = 1
	char* result = llvm_temp()
	llvm_put(c"  ")
	llvm_put(result)
	llvm_put(c" = call i64 @__wllvm_gen_switch(i64 ")
	llvm_put(values[0])
	llvm_put(c", i64 ")
	llvm_put(values[1])
	llvm_put(c")\x0a")
	return result


void llvm_generator_emit_runtime():
	if (llvm_uses_gen_switch):
		# gen_switch(save, restore): push the callee-saved registers, store
		# rsp through save, load restore, pop them there and return.
		string_append(llvm_code, c"declare i64 @__wllvm_gen_switch(i64, i64)\x0a")
		string_append(llvm_code, c"module asm \".text\"\x0amodule asm \".globl __wllvm_gen_switch\"\x0amodule asm \"__wllvm_gen_switch:\"\x0a")
		string_append(llvm_code, c"module asm \"  pushq %rbx\"\x0amodule asm \"  pushq %rbp\"\x0amodule asm \"  pushq %r12\"\x0a")
		string_append(llvm_code, c"module asm \"  pushq %r13\"\x0amodule asm \"  pushq %r14\"\x0amodule asm \"  pushq %r15\"\x0a")
		string_append(llvm_code, c"module asm \"  movq %rsp, (%rdi)\"\x0amodule asm \"  movq %rsi, %rsp\"\x0a")
		string_append(llvm_code, c"module asm \"  popq %r15\"\x0amodule asm \"  popq %r14\"\x0amodule asm \"  popq %r13\"\x0a")
		string_append(llvm_code, c"module asm \"  popq %r12\"\x0amodule asm \"  popq %rbp\"\x0amodule asm \"  popq %rbx\"\x0a")
		string_append(llvm_code, c"module asm \"  retq\"\x0a\x0a")
	int any = 0
	for linkage, count in llvm_generator_thunks:
		if ((linkage in llvm_queued) == 0): continue
		any = 1
		# Entered by gen_switch's ret with rsp at the zero return address;
		# the stack is not call-aligned, hence stackrealign.
		string_append(llvm_code, c"define internal void ")
		string_append(llvm_code, llvm_name(c"@wg", linkage))
		string_append(llvm_code, c"() #1 {\x0aentry:\x0a  %frame = call ptr @llvm.addressofreturnaddress.p0()\x0a")
		for i in range(count + 1):
			string_append(llvm_code, c"  %p")
			string_append_int(llvm_code, i)
			string_append(llvm_code, c" = getelementptr i8, ptr %frame, i64 ")
			# self above the return address, then argument i at 16 + 8 * (count - 1 - i)
			if (i == count): string_append_int(llvm_code, 8)
			else: string_append_int(llvm_code, 16 + 8 * (count - 1 - i))
			string_append(llvm_code, c"\x0a  %a")
			string_append_int(llvm_code, i)
			string_append(llvm_code, c" = load i64, ptr %p")
			string_append_int(llvm_code, i)
			string_append(llvm_code, c", align 8\x0a")
		string_append(llvm_code, c"  %done = call i64 ")
		string_append(llvm_code, llvm_function_label(linkage))
		string_append(llvm_code, c"(")
		for i in range(count + 1):
			if (i > 0): string_append(llvm_code, c", ")
			string_append(llvm_code, c"i64 %a")
			string_append_int(llvm_code, i)
		string_append(llvm_code, c")\x0a  call void @llvm.trap()\x0a  unreachable\x0a}\x0a\x0a")
	if (any):
		llvm_uses_trap = 1
		string_append(llvm_code, c"declare ptr @llvm.addressofreturnaddress.p0()\x0a")
		string_append(llvm_code, c"attributes #1 = { noinline \"stackrealign\" }\x0a\x0a")
# --- end of generators -------------------------------------------------------


# --- arrays inside records ---------------------------------------------------
# A T[N] field is stored inline like a fixed-array local: a {data, length}
# header followed by the elements, with data naming the elements. Every
# place a record comes into being points its headers at its own storage
# (grammar/array_field_init.w): declarations, new T, record copies and
# globals. The headers of arrays of records stay zero, as natively.

# Header offsets and lengths of type's array fields, nested records included.
void llvm_array_headers(int type, int offset, list[int] offsets, list[int] lengths):
	retained_type* t = llvm_type(type)
	if ((t.pointer_level == 0) && (t.kind == 6)):
		offsets.push(offset)
		lengths.push(t.array_length)
		return
	if ((t.pointer_level != 0) || (t.kind == 8) || (t.kind == 10) || (t.kind == 11) || (t.kind == 12)): return
	for field in t.fields: llvm_array_headers(field.type, offset + field.offset, offsets, lengths)


void llvm_init_array_fields(int type, char* address):
	list[int] offsets = new list[int]
	list[int] lengths = new list[int]
	llvm_array_headers(type, 0, offsets, lengths)
	for i in range(offsets.length):
		char* header = llvm_offset(address, llvm_number(offsets[i]))
		llvm_store_width(8, llvm_address_value(llvm_offset(header, c"16")), header)
		llvm_store_width(8, llvm_number(lengths[i]), llvm_offset(header, c"8"))
	offsets.free()
	lengths.free()


# A zeroed global record with array fields: a packed constant whose
# headers point into the global itself. Returns 0 when there are none.
int llvm_global_record_headers(int linkage, int type, string_builder* text):
	list[int] offsets = new list[int]
	list[int] lengths = new list[int]
	llvm_array_headers(type, 0, offsets, lengths)
	int count = offsets.length
	if (count > 0):
		string_builder* shape = string_new()
		string_builder* fill = string_new()
		int at = 0
		for i in range(count + 1):
			int end = llvm_storage(type)
			if (i < count): end = offsets[i]
			if (end > at):
				string_append(shape, c"[")
				string_append_int(shape, end - at)
				string_append(shape, c" x i8], ")
				string_append(fill, c"[")
				string_append_int(fill, end - at)
				string_append(fill, c" x i8] zeroinitializer, ")
			if (i < count):
				string_append(shape, c"ptr, i64, ")
				string_append(fill, c"ptr getelementptr (i8, ptr ")
				string_append(fill, llvm_name(c"@g", linkage))
				string_append(fill, c", i64 ")
				string_append_int(fill, offsets[i] + 16)
				string_append(fill, c"), i64 ")
				string_append_int(fill, lengths[i])
				string_append(fill, c", ")
				at = offsets[i] + 16
		# drop the trailing ", "
		shape.length = shape.length - 2
		shape.data[shape.length] = 0
		fill.length = fill.length - 2
		fill.data[fill.length] = 0
		string_append(text, c"<{ ")
		string_append(text, shape.data)
		string_append(text, c" }> <{ ")
		string_append(text, fill.data)
		string_append(text, c" }>")
		string_free(shape)
		string_free(fill)
	offsets.free()
	lengths.free()
	return count > 0
# --- end of arrays inside records --------------------------------------------


void llvm_statement(int id):
	if (llvm_failed): return
	retained_node node
	retained_node_load(id, &node)
	# Keep lowering (and checking) unreachable code in a fresh block.
	if (llvm_terminated): llvm_label(llvm_label_new())
	llvm_debug_mark(node.line)
	if ((strcmp(node.name, c":") == 0) || (strcmp(node.name, c"{") == 0) || (strcmp(node.name, c"unsafe block") == 0)):
		int owner_mark = llvm_owner_stack.length
		int child = llvm_first[id]
		while (child >= 0):
			llvm_statement(child)
			child = llvm_next[child]
		llvm_owner_end_scope(id, owner_mark)
		return
	if (strcmp(node.name, c"pass") == 0): return
	if ((strcmp(node.name, c"break") == 0) || (strcmp(node.name, c"continue") == 0)):
		int target = llvm_break_label
		if (strcmp(node.name, c"continue") == 0): target = llvm_continue_label
		if (target < 0): llvm_error(id, c"jump outside a loop")
		else:
			llvm_owner_cleanup(id, llvm_loop_owner_mark, 0)
			llvm_branch(target)
		llvm_reachable = 0
		return
	if (strcmp(node.name, c"yield") == 0):
		llvm_generator_yield(id)
		return
	if (strcmp(node.name, c"return") == 0):
		llvm_generator_free_loops(id)
		if (llvm_generator_self >= 0):
			llvm_generator_finish(id)
			return
		int group = llvm_first[id]
		int return_type = retained_bindings[llvm_function].return_type
		char* value = c"0"
		if ((group >= 0) && (retained_node_kind(group) == retained_expression_group)):
			value = llvm_group(group)
			if (llvm_class(return_type) == llvm_class_word): value = llvm_convert(id, value, llvm_group_type(group), return_type)
			retained_node returned
			retained_node_load(group, &returned)
			llvm_owner_move(group, returned.op, return_type)
		else if (llvm_class(return_type) != llvm_class_void):
			llvm_error(id, c"return without a value")
			return
		llvm_owner_cleanup(id, 0, 1)
		llvm_put(c"  ret i64 ")
		llvm_put(value)
		llvm_put(c"\x0a")
		llvm_terminated = 1
		llvm_reachable = 0
		return
	if (strcmp(node.name, c"for range") == 0):
		llvm_range(id)
		return
	if (strcmp(node.name, c"for") == 0):
		llvm_container_for(id)
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
		int previous_mark = llvm_loop_owner_mark
		llvm_break_label = end
		llvm_continue_label = head
		llvm_loop_owner_mark = llvm_owner_stack.length
		llvm_statement(body)
		llvm_break_label = previous_break
		llvm_continue_label = previous_continue
		llvm_loop_owner_mark = previous_mark
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
	# 'name := value' retains its initializer before the inferred local.
	if ((child >= 0) && (retained_node_kind(child) == retained_expression_group) && (llvm_next[child] >= 0) && (retained_node_kind(llvm_next[child]) == retained_local) && (llvm_next[llvm_next[child]] < 0)):
		retained_node inferred
		retained_node_load(llvm_next[child], &inferred)
		if ((inferred.binding < 0) || ((inferred.binding in llvm_locals) == 0)):
			llvm_error(id, c"local declaration")
			return
		int inferred_type = retained_bindings[inferred.binding].type
		if (llvm_class(inferred_type) == llvm_class_array):
			llvm_error(id, c"array initializer")
			return
		char* inferred_value = llvm_convert(id, llvm_group(child), llvm_group_type(child), inferred_type)
		retained_node inferred_root
		retained_node_load(child, &inferred_root)
		llvm_owner_move(child, inferred_root.op, inferred_type)
		llvm_store(id, inferred_type, inferred_value, llvm_name(c"%v", inferred.binding))
		llvm_owner_declare(inferred.binding)
		return
	if ((child >= 0) && (retained_node_kind(child) == retained_local)):
		retained_node local
		retained_node_load(child, &local)
		child = llvm_next[child]
		if ((local.binding < 0) || ((local.binding in llvm_locals) == 0)):
			llvm_error(id, c"local declaration")
			return
		if (child < 0):
			llvm_local_init(local.binding)
			llvm_owner_declare(local.binding)
			return
		if ((retained_node_kind(child) != retained_expression_group) || (llvm_next[child] >= 0)):
			llvm_error(id, c"multiple local declaration")
			return
		int type = retained_bindings[local.binding].type
		if (llvm_class(type) == llvm_class_array):
			llvm_error(id, c"array initializer")
			return
		char* value = llvm_convert(id, llvm_group(child), llvm_group_type(child), type)
		retained_node initializer
		retained_node_load(child, &initializer)
		llvm_owner_move(child, initializer.op, type)
		llvm_store(id, type, value, llvm_name(c"%v", local.binding))
		llvm_owner_declare(local.binding)
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
	string_append(llvm_code, llvm_function_label(function.linkage))
	string_append(llvm_code, c"(")
	int stub_parameter = llvm_first[id]
	int stub_count = 0
	while ((stub_parameter >= 0) && (retained_node_kind(stub_parameter) == retained_local)):
		if (stub_count > 0): string_append(llvm_code, c", ")
		string_append(llvm_code, c"i64")
		stub_count = stub_count + 1
		stub_parameter = llvm_next[stub_parameter]
	# The trap's location is the function's own line in traces.
	int subprogram = llvm_debug_function(&node)
	int location = llvm_debug_location(node.line)
	string_append(llvm_code, c") #1 !dbg !")
	string_append_int(llvm_code, subprogram)
	string_append(llvm_code, c" {\x0aentry:\x0a  call void @llvm.trap(), !dbg !")
	string_append_int(llvm_code, location)
	string_append(llvm_code, c"\x0a  unreachable\x0a}\x0a\x0a")
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
	llvm_owner_stack = new list[int]
	llvm_loop_owner_mark = 0
	llvm_entry = string_new()
	llvm_out = string_new()
	int return_class = llvm_class(function.return_type)
	if ((return_class != llvm_class_word) && (return_class != llvm_class_void)):
		llvm_error_at(id, c"return type of", node.name)
	for p in range(function.parameters.length):
		if (llvm_class(function.parameters[p]) != llvm_class_word): llvm_error_at(id, c"parameter type of", node.name)
	if (ends_with(retained_sources[node.source].path, c"lib/stack_trace.w")): llvm_traces = 1
	int subprogram = llvm_debug_function(&node)
	llvm_function_setjmp = 0
	string_append(llvm_code, c"define internal i64 ")
	string_append(llvm_code, llvm_function_label(function.linkage))
	string_append(llvm_code, c"(")
	int child = llvm_first[id]
	int argument = 0
	while ((child >= 0) && (retained_node_kind(child) == retained_local)):
		retained_node parameter
		retained_node_load(child, &parameter)
		if (argument > 0): string_append(llvm_code, c", ")
		string_append(llvm_code, c"i64 ")
		string_append(llvm_code, llvm_name(c"%a", parameter.binding))
		argument = argument + 1
		child = llvm_next[child]
	string_append(llvm_code, c") #1 !dbg !")
	string_append_int(llvm_code, subprogram)
	string_append(llvm_code, c" {\x0aentry:\x0a")
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
		if (llvm_storage(type) == 8): string_append(llvm_entry, c" = alloca i64, align 8\x0a")
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
		if (parameter.binding in llvm_locals):
			int narrow = llvm_narrow_float(retained_bindings[parameter.binding].type)
			if (narrow): llvm_store_width(2, llvm_narrow_bits(llvm_name(c"%a", parameter.binding), narrow), llvm_name(c"%v", parameter.binding))
			else: llvm_store_width(8, llvm_name(c"%a", parameter.binding), llvm_name(c"%v", parameter.binding))
		parameter_id = llvm_next[parameter_id]
	llvm_generator_begin(id)
	while (child >= 0):
		llvm_statement(child)
		child = llvm_next[child]
	# Falling off the end returns 0 (a void function's only exit) or
	# finishes a generator.
	if (llvm_terminated == 0): llvm_owner_cleanup(id, 0, 1)
	if ((llvm_terminated == 0) && (llvm_generator_self >= 0)): llvm_generator_finish(id)
	if (llvm_terminated == 0): llvm_put(c"  ret i64 0\x0a")
	string_append(llvm_code, llvm_entry.data)
	string_append(llvm_code, c"  br label %b0\x0a")
	llvm_debug_lines(llvm_code, llvm_out.data)
	string_append(llvm_code, c"}\x0a\x0a")
	string_free(llvm_entry)
	string_free(llvm_out)
	llvm_locals.free()
	llvm_owner_stack.free()


# --- globals and the entry point -------------------------------------------

void llvm_emit_global(int linkage):
	int id = llvm_global_decls[linkage]
	retained_node node
	retained_node_load(id, &node)
	# thread_local globals live in per-thread blocks (llvm_tls_address).
	if (llvm_thread_local(&node)):
		llvm_error_at(id, c"thread_local global", node.name)
		return
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
	else if ((c == llvm_class_struct) && (init == 0) && llvm_global_record_headers(linkage, type, text)): value = text.data
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
	# No .bss: the image maps its file tail for lib/stack_trace.w (wllvm.w).
	string_append(llvm_data, c", section \".data\", align 8\x0a")
	string_free(text)


# Freestanding Linux entry: no C runtime. _start passes the initial
# stack's argc and argv to the W entry, then exits with its result.
void llvm_emit_entry(int entry, int arguments):
	string_append(llvm_code, c"module asm \".globl _start\"\x0amodule asm \"_start:\"\x0a")
	if (llvm_arm64):
		# The kernel enters with sp 16-byte aligned and argc at [sp].
		string_append(llvm_code, c"module asm \"  mov x29, #0\"\x0amodule asm \"  mov x30, #0\"\x0a")
		string_append(llvm_code, c"module asm \"  ldr x0, [sp]\"\x0amodule asm \"  add x1, sp, #8\"\x0a")
		string_append(llvm_code, c"module asm \"  bl __wllvm_start\"\x0amodule asm \"  brk #0\"\x0a\x0a")
	else:
		string_append(llvm_code, c"module asm \"  xorl %ebp, %ebp\"\x0amodule asm \"  movq (%rsp), %rdi\"\x0a")
		string_append(llvm_code, c"module asm \"  leaq 8(%rsp), %rsi\"\x0amodule asm \"  andq $-16, %rsp\"\x0a")
		string_append(llvm_code, c"module asm \"  callq __wllvm_start\"\x0amodule asm \"  ud2\"\x0a\x0a")
	string_append(llvm_code, c"define void @__wllvm_start(i64 %argc, i64 %argv) noreturn nounwind #1 {\x0aentry:\x0a")
	llvm_tls_entry()
	string_append(llvm_code, c"  %result = call i64 ")
	string_append(llvm_code, llvm_function_label(entry))
	if (arguments == 2): string_append(llvm_code, c"(i64 %argc, i64 %argv)\x0a")
	else: string_append(llvm_code, c"()\x0a")
	# exit_group: 94 on AArch64, 231 on x86-64
	if (llvm_arm64): string_append(llvm_code, c"  %exit = call i64 asm sideeffect \"svc #0\", \"={x0},{x8},{x0},~{memory}\"(i64 94, i64 %result)\x0a")
	else: string_append(llvm_code, c"  %exit = call i64 asm sideeffect \"syscall\", \"={rax},{rax},{rdi},~{rcx},~{r11},~{memory}\"(i64 231, i64 %result)\x0a")
	string_append(llvm_code, c"  unreachable\x0a}\x0a\x0a")


# LLVM lowers large copies and fills to these C names; without a C library
# the module defines them, as byte loops LLVM must not turn back into calls.
void llvm_emit_memory_runtime():
	string_append(llvm_code, c"define hidden ptr @memset(ptr %d, i32 %c, i64 %n) #0 {\x0aentry:\x0a  %b = trunc i32 %c to i8\x0a  br label %head\x0ahead:\x0a  %i = phi i64 [ 0, %entry ], [ %j, %body ]\x0a  %more = icmp ult i64 %i, %n\x0a  br i1 %more, label %body, label %done\x0abody:\x0a  %p = getelementptr i8, ptr %d, i64 %i\x0a  store volatile i8 %b, ptr %p\x0a  %j = add i64 %i, 1\x0a  br label %head\x0adone:\x0a  ret ptr %d\x0a}\x0a\x0a")
	string_append(llvm_code, c"define hidden ptr @memcpy(ptr %d, ptr %s, i64 %n) #0 {\x0aentry:\x0a  br label %head\x0ahead:\x0a  %i = phi i64 [ 0, %entry ], [ %j, %body ]\x0a  %more = icmp ult i64 %i, %n\x0a  br i1 %more, label %body, label %done\x0abody:\x0a  %q = getelementptr i8, ptr %s, i64 %i\x0a  %v = load volatile i8, ptr %q\x0a  %p = getelementptr i8, ptr %d, i64 %i\x0a  store volatile i8 %v, ptr %p\x0a  %j = add i64 %i, 1\x0a  br label %head\x0adone:\x0a  ret ptr %d\x0a}\x0a\x0a")
	string_append(llvm_code, c"define hidden ptr @memmove(ptr %d, ptr %s, i64 %n) #0 {\x0aentry:\x0a  %di = ptrtoint ptr %d to i64\x0a  %si = ptrtoint ptr %s to i64\x0a  %back = icmp ugt i64 %di, %si\x0a  br i1 %back, label %bhead, label %fhead\x0afhead:\x0a  %i = phi i64 [ 0, %entry ], [ %j, %fbody ]\x0a  %fmore = icmp ult i64 %i, %n\x0a  br i1 %fmore, label %fbody, label %done\x0afbody:\x0a  %q = getelementptr i8, ptr %s, i64 %i\x0a  %v = load volatile i8, ptr %q\x0a  %p = getelementptr i8, ptr %d, i64 %i\x0a  store volatile i8 %v, ptr %p\x0a  %j = add i64 %i, 1\x0a  br label %fhead\x0abhead:\x0a  %k = phi i64 [ %n, %entry ], [ %k1, %bbody ]\x0a  %bmore = icmp ugt i64 %k, 0\x0a  br i1 %bmore, label %bbody, label %done\x0abbody:\x0a  %k1 = sub i64 %k, 1\x0a  %bq = getelementptr i8, ptr %s, i64 %k1\x0a  %bv = load volatile i8, ptr %bq\x0a  %bp = getelementptr i8, ptr %d, i64 %k1\x0a  store volatile i8 %bv, ptr %bp\x0a  br label %bhead\x0adone:\x0a  ret ptr %d\x0a}\x0a\x0a")
	string_append(llvm_code, c"attributes #0 = { nounwind \"no-builtins\" \"frame-pointer\"=\"all\" }\x0a\x0a")


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
	llvm_tests.free()
	llvm_symbol_owner.free()
	llvm_symbols.free()
	string_free(llvm_meta)
	llvm_meta_files.free()
	llvm_meta_lines.free()
	llvm_runtime_used.free()
	llvm_tls_offsets.free()
	string_free(llvm_imports)
	string_free(llvm_thunk_code)
	llvm_import_thunks.free()
	llvm_import_cache.free()
	llvm_imports_declared.free()
	llvm_generator_thunks.free()


# Called only after a successful x64 production compile with semantic
# retention enabled. Returns 1 on success; unsupported input leaves the
# output untouched. All IR is validated before anything is written.
int llvm_emit(char* filename, char* output_path):
	llvm_failed = 0
	llvm_constants = 0
	llvm_uses_memory = 0
	llvm_uses_trap = 0
	llvm_uses_bits = 0
	llvm_uses_float_conversion = 0
	llvm_tests = new list[int]
	llvm_tests_wanted = 0
	llvm_symbol_owner = new map[char*, int]
	llvm_symbols = new map[int, char*]
	llvm_meta = string_new()
	llvm_meta_next = 4
	llvm_meta_files = new map[int, int]
	llvm_meta_lines = new map[int, int]
	llvm_traces = 0
	llvm_runtime_used = new map[char*, int]
	llvm_uses_math = 0
	llvm_tls_offsets = new map[int, int]
	llvm_tls_size = 8
	llvm_stubs = 0
	llvm_imports = string_new()
	llvm_import_cache = new map[int, int]
	llvm_imports_declared = new map[char*, int]
	llvm_dynamic = 0
	llvm_link_libraries = new list[char*]
	llvm_import_thunks = new map[int, int]
	llvm_thunk_code = string_new()
	llvm_uses_gen_switch = 0
	llvm_generator_thunks = new map[int, int]
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
	int input_start = -1
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
			# A program can define the entry itself.
			if ((node.source == input) && (strcmp(node.name, c"_main") == 0)): input_start = id
	# A lib/testing.w program's main is the library's.
	if ((main_node < 0) && (c"__w_run_tests" in llvm_function_names) && (c"main" in llvm_function_names)): main_node = llvm_functions[llvm_function_names[c"main"]]
	if (main_node < 0): main_node = input_start
	if (main_node < 0):
		llvm_error(retained_sources[input].root, c"program without a main function")
		llvm_free_tables()
		return 0
	# The entry's main keeps the bare name main; other names go first-defined.
	retained_node main_definition
	retained_node_load(main_node, &main_definition)
	llvm_symbol_claim(retained_bindings[main_definition.binding].linkage, main_definition.name)
	for id in range(count):
		if (retained_node_kind(id) != retained_function): continue
		retained_node node
		retained_node_load(id, &node)
		if ((node.binding >= 0) && llvm_function_has_body(id)): llvm_symbol_claim(retained_bindings[node.binding].linkage, node.name)
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
		llvm_emit_test_main()
		llvm_emit_entry(entry_binding.linkage, entry_binding.parameters.length)
		llvm_generator_emit_runtime()
		llvm_tls_finish()
		llvm_emit_runtime_stubs(llvm_code)
		if (c"thread_create" in llvm_runtime_used):
			string_builder* shared = llvm_volatile_globals(llvm_code.data)
			string_free(llvm_code)
			llvm_code = shared
			llvm_out = llvm_code
		if (llvm_uses_memory): llvm_emit_memory_runtime()
		string_builder* module = string_new()
		if (llvm_arm64):
			string_append(module, c"; W LLVM offload: production retained AST, signed 64-bit words, freestanding AArch64 Linux\x0a")
			string_append(module, c"target triple = \"aarch64-unknown-linux-gnu\"\x0a\x0a")
		else:
			string_append(module, c"; W LLVM offload: production retained AST, signed 64-bit words, freestanding x86-64 Linux\x0a")
			string_append(module, c"target triple = \"x86_64-unknown-linux-gnu\"\x0a\x0a")
		if (llvm_uses_trap): string_append(module, c"declare void @llvm.trap() cold noreturn nounwind\x0a")
		if (llvm_uses_bits):
			string_append(module, c"declare i32 @llvm.fshl.i32(i32, i32, i32)\x0adeclare i32 @llvm.fshr.i32(i32, i32, i32)\x0a")
			string_append(module, c"declare i32 @llvm.ctpop.i32(i32)\x0adeclare i32 @llvm.ctlz.i32(i32, i1)\x0adeclare i32 @llvm.cttz.i32(i32, i1)\x0a")
		llvm_math_declarations(module)
		if (llvm_uses_float_conversion): string_append(module, c"declare i64 @llvm.fptosi.sat.i64.f32(float)\x0adeclare i64 @llvm.fptosi.sat.i64.f64(double)\x0a")
		if (llvm_uses_memory): string_append(module, c"declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)\x0adeclare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)\x0a")
		if (llvm_dynamic):
			# C imports: the module links dynamically, keeping W's _start.
			string_append(module, c"\x0a; C imports; link with: clang -nostartfiles")
			for soname in llvm_link_libraries:
				string_append(module, c" -l:")
				string_append(module, soname)
			string_append(module, c"\x0a")
			string_append(module, llvm_imports.data)
		string_append(module, c"\x0a")
		string_append(module, llvm_data.data)
		string_append(module, c"\x0a")
		string_append(module, llvm_code.data)
		string_append(module, llvm_thunk_code.data)
		llvm_function_attributes(module)
		llvm_debug_finish(module)
		success = file_write_text(output_path, module.data)
		string_free(module)
		if (success == 0):
			wstream* err = stderr_writer()
			stream_write_cstr(err, c"wllvm: cannot write output: ")
			stream_write_line(err, output_path)
			stream_flush(err)
	llvm_free_tables()
	return success
