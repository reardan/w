# Bounded, non-evaluating data inspection for graphical debugger clients.
# Paths are names followed by .field or .* (one explicit dereference).
import debugger.locals
import lib.mem
import structures.json


# A kernel copy through a pipe makes local reads fault-safe, including
# PROT_NONE pages (mincore alone only checks whether a mapping exists).
# Attached targets keep using the debugger's target memory seam.
int dbg_inspect_read(int addr, int width, int* value):
	if ((width != 1) && (width != 2) && (width != 4) && (width != __word_size__)): return 0
	if (dbg_mem_read_fn != cast(int, dbg_mem_read_local)):
		if (dbg_mem_readable(addr, width) == 0): return 0
		*value = dbg_mem_read(addr, width)
		return dbg_mem_read_ok
	int[2] fds
	if (pipe(&fds[0]) != 0): return 0
	int input = load_int32(cast(char*, &fds[0]))
	int output = load_int32(cast(char*, &fds[0]) + 4)
	char[8] bytes
	int copied = write(output, cast(char*, addr), width)
	int ok = 0
	if (copied > 0):
		int received = read(input, &bytes[0], copied)
		if ((received == width) && (copied == width)):
			*value = load_i(&bytes[0], width)
			ok = 1
	close(input)
	close(output)
	return ok


int dbg_inspect_letter(int c):
	return ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z')) || (c == '_')


int dbg_inspect_name_end(char* path, int start):
	if (dbg_inspect_letter(path[start]) == 0): return start
	int end = start + 1
	while (dbg_inspect_letter(path[end]) || ((path[end] >= '0') && (path[end] <= '9'))): end = end + 1
	return end


int dbg_inspect_pointee(int type):
	int level = type_get_pointer_level(type)
	if (level == 0): return -1
	return type_lookup_pointer(type_get_name(type), level - 1)


char* dbg_inspect_resolve(char* path, int pc, int esp, int* address, int* result_type):
	int end = dbg_inspect_name_end(path, 0)
	if ((end == 0) || (strlen(path) > 512)): return c"Expected name.field or name.* (maximum 512 bytes)"
	char* name = mem_dup(path, end)
	int note = dbg_local_find(name, pc)
	int addr = 0
	int type = -1
	if ((note >= 0) && esp):
		addr = dbg_local_runtime_addr(note, esp)
		type = dbg_local_type(note)
	else if (note < 0):
		int symbol = dbg_global_find(name)
		if ((symbol >= 0) && (dbg_sym_symtype(symbol) != 2)):
			addr = dbg_sym_address(symbol)
			type = dbg_sym_type(symbol)
	free(name)
	if (type < 0): return c"Variable is unavailable in this frame"
	while (path[end]):
		if (path[end] != '.'): return c"Only .field and .* are supported; expressions are not executed"
		int start = end + 1
		int dereference = path[start] == '*'
		end = dbg_inspect_name_end(path, start)
		if (dereference): end = start + 1
		if (end == start): return c"Expected field name or * after dot"
		if (type_get_pointer_level(type)):
			int next_type = dbg_inspect_pointee(type)
			if (next_type < 0): return c"Pointee type is unavailable"
			if (dbg_inspect_read(addr, __word_size__, &addr) == 0): return c"Unreadable pointer"
			if (addr == 0): return c"Null pointer"
			type = next_type
		else if (dereference): return c"Value is not a pointer"
		if (dereference): continue
		if (type_get_pointer_level(type)): return c"Dereference with .* before selecting a field"
		name = mem_dup(path + start, end - start)
		int field = -1
		for i in range(type_num_args(type)):
			if (strcmp(name, type_get_field_name_at(type, i)) == 0): field = i
		free(name)
		if (field < 0): return c"Unknown field"
		addr = addr + type_get_field_offset_at(type, field)
		type = type_get_field_type_at(type, field)
	*address = addr
	*result_type = type
	return 0


void dbg_inspect_hex(json_value* node, char* key, int value):
	char* text = hex_word(value)
	json_object_set(node, key, json_string(text))
	free(text)


# Summaries never recurse or call debuggee code. Floats carry numeric
# text in value and their original storage pattern in bits.
json_value* dbg_inspect_value(char* path, char* name, int addr, int type):
	json_value* node = json_object()
	json_object_set(node, c"path", json_string(path))
	json_object_set(node, c"name", json_string(name))
	string_builder* label = string_from(type_get_name(type))
	for i in range(type_get_pointer_level(type)): string_append_char(label, '*')
	json_object_set(node, c"type", json_string(label.data))
	string_free(label)
	dbg_inspect_hex(node, c"address", addr)
	int pointer = type_get_pointer_level(type)
	int fields = type_num_args(type)
	int expandable = (pointer > 0) || (fields > 0)
	json_object_set(node, c"expandable", json_bool(expandable))
	if ((pointer == 0) && fields):
		json_object_set(node, c"value", json_string(c"{...}"))
		return node
	int width = type_get_size(type)
	int value = 0
	if (dbg_inspect_read(addr, width, &value) == 0):
		json_object_set(node, c"value", json_string(c"<unreadable or unsupported width>"))
		json_object_set(node, c"expandable", json_bool(0))
		return node
	if (pointer):
		dbg_inspect_hex(node, c"value", value)
		dbg_inspect_hex(node, c"pointer", value)
		if (value == 0): json_object_set(node, c"expandable", json_bool(0))
	else if (type_float_kind(type)):
		char* text = dbg_float_text(value, type)
		json_object_set(node, c"value", json_string(text))
		free(text)
		char* raw = hex_fixed(value, width * 2)
		json_object_set(node, c"bits", json_string(raw))
		free(raw)
	else if (type_is_unsigned_word(type)):
		dbg_inspect_hex(node, c"value", value)
	else:
		char* name = type_get_name(type)
		if ((width < __word_size__) && ((strcmp(name, c"int8") == 0) || (strcmp(name, c"int16") == 0) || (strcmp(name, c"int32") == 0))):
			int shift = (__word_size__ - width) * 8
			value = (value << shift) >> shift
		char* text = itoa(value)
		json_object_set(node, c"value", json_string(text))
		free(text)
	return node


json_value* dbg_inspect_snapshot(char* path, int pc, int esp):
	int addr = 0
	int type = 0
	char* error = dbg_inspect_resolve(path, pc, esp, &addr, &type)
	json_value* root = json_object()
	json_object_set(root, c"version", json_int(1))
	json_object_set(root, c"path", json_string(path))
	if (error != 0):
		json_object_set(root, c"error", json_string(error))
		return root
	json_object_set(root, c"value", dbg_inspect_value(path, path, addr, type))
	json_value* children = json_array()
	json_object_set(root, c"children", children)
	if (type_get_pointer_level(type)):
		int pointee = dbg_inspect_pointee(type)
		if (pointee < 0): error = c"Pointee type is unavailable"
		else if (dbg_inspect_read(addr, __word_size__, &addr) == 0): error = c"Unreadable pointer"
		else if (addr == 0): error = c"Null pointer"
		if (error != 0):
			json_object_set(root, c"error", json_string(error))
			return root
		type = pointee
		if (type_get_pointer_level(type) || (type_num_args(type) == 0)):
			char* child_path = strjoin(path, c".*")
			json_array_push(children, dbg_inspect_value(child_path, c"*", addr, type))
			free(child_path)
			return root
	int count = type_num_args(type)
	json_object_set(root, c"truncated", json_bool(count > 64))
	if (count > 64): count = 64
	for i in range(count):
		char* name = type_get_field_name_at(type, i)
		char* prefix = strjoin(path, c".")
		char* child_path = strjoin(prefix, name)
		json_array_push(children, dbg_inspect_value(child_path, name, addr + type_get_field_offset_at(type, i), type_get_field_type_at(type, i)))
		free(prefix)
		free(child_path)
	return root


void dbg_inspect_command(char* path, int pc, int esp):
	json_value* snapshot = dbg_inspect_snapshot(path, pc, esp)
	char* text = json_stringify(snapshot)
	print(c"wdbg-data ")
	println(text)
	free(text)
	json_free(snapshot)
