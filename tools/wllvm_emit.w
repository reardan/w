# Experimental LLVM text lowering of the production retained semantic forest.
# This leaf tool deliberately accepts only scalar, single-module programs. It
# never reparses source and never changes the native compiler's emission path.
import compiler.retained_ast
import lib.file
import lib.stream

string_builder* llvm_ir
int llvm_failed
int llvm_source
int llvm_register
int llvm_label_counter
int llvm_block
int llvm_terminated
int llvm_function
int llvm_reachable
int llvm_expression_depth
int llvm_break_label = -1
int llvm_continue_label = -1
list[int] llvm_first
list[int] llvm_next
map[int, int] llvm_functions
map[int, int] llvm_locals

void llvm_put(char* text):
	string_append(llvm_ir, text)

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

void llvm_error(int id, char* message):
	if (llvm_failed): return
	llvm_failed = 1
	retained_node node
	retained_node_load(id, &node)
	wstream* err = stderr_writer()
	stream_write_cstr(err, retained_sources[node.source].path)
	stream_write_cstr(err, c":")
	stream_write_cstr(err, llvm_number(node.line))
	stream_write_cstr(err, c":")
	stream_write_cstr(err, llvm_number(node.column))
	stream_write_cstr(err, c": wllvm: unsupported ")
	stream_write_line(err, message)
	stream_flush(err)

int llvm_scalar(int type):
	if (type < 0): return 0
	retained_type* t = retained_types[type]
	if (t.pointer_level != 0): return 0
	return (strcmp(t.name, c"int") == 0) || (strcmp(t.name, c"bool") == 0) || (strcmp(t.name, c"constant") == 0)

int llvm_is_bool(int type):
	return (type >= 0) && (strcmp(retained_types[type].name, c"bool") == 0)

char* llvm_instruction(char* op, char* a, char* b):
	char* result = llvm_temp()
	llvm_put(c"  ")
	llvm_put(result)
	llvm_put(c" = ")
	llvm_put(op)
	llvm_put(c" i64 ")
	llvm_put(a)
	llvm_put(c", ")
	llvm_put(b)
	llvm_put(c"\x0a")
	return result

char* llvm_bool(char* value):
	return llvm_instruction(c"icmp ne", value, c"0")

char* llvm_extend(char* value):
	char* result = llvm_temp()
	llvm_put(c"  ")
	llvm_put(result)
	llvm_put(c" = zext i1 ")
	llvm_put(value)
	llvm_put(c" to i64\x0a")
	return result

char* llvm_coerce(char* value, int type):
	if (llvm_is_bool(type)): return llvm_extend(llvm_bool(value))
	return value

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

char* llvm_load(int binding):
	char* result = llvm_temp()
	llvm_put(c"  ")
	llvm_put(result)
	llvm_put(c" = load i64, ptr ")
	llvm_put(llvm_name(c"%v", binding))
	llvm_put(c"\x0a")
	return result

void llvm_store(int binding, char* value):
	value = llvm_coerce(value, retained_bindings[binding].type)
	llvm_put(c"  store i64 ")
	llvm_put(value)
	llvm_put(c", ptr ")
	llvm_put(llvm_name(c"%v", binding))
	llvm_put(c"\x0a")

char* llvm_binary(int id, int op, char* a, char* b):
	char* instruction = 0
	if (op == '+'): instruction = c"add"
	else if (op == '-'): instruction = c"sub"
	else if (op == '*'): instruction = c"mul"
	else if (op == '&'): instruction = c"and"
	else if (op == '|'): instruction = c"or"
	else if (op == '^'): instruction = c"xor"
	else if (op == 'L'): instruction = c"shl"
	else if (op == 'R'): instruction = c"ashr"
	else if (op == 0x94): instruction = c"icmp eq"
	else if (op == 0x95): instruction = c"icmp ne"
	else if (op == 0x9c): instruction = c"icmp slt"
	else if (op == 0x9d): instruction = c"icmp sge"
	else if (op == 0x9e): instruction = c"icmp sle"
	else if (op == 0x9f): instruction = c"icmp sgt"
	if ((op == '/') || (op == '%')):
		# LLVM division by zero and MIN/-1 are poison; x64 W traps. Guard
		# both before evaluating sdiv/srem, including under optimization.
		char* zero = llvm_instruction(c"icmp eq", b, c"0")
		char* min = llvm_instruction(c"icmp eq", a, c"-9223372036854775808")
		char* minus = llvm_instruction(c"icmp eq", b, c"-1")
		char* overflow = llvm_temp()
		llvm_put(c"  ")
		llvm_put(overflow)
		llvm_put(c" = and i1 ")
		llvm_put(min)
		llvm_put(c", ")
		llvm_put(minus)
		llvm_put(c"\x0a")
		char* invalid = llvm_temp()
		llvm_put(c"  ")
		llvm_put(invalid)
		llvm_put(c" = or i1 ")
		llvm_put(zero)
		llvm_put(c", ")
		llvm_put(overflow)
		llvm_put(c"\x0a")
		int trap = llvm_label_new()
		int valid = llvm_label_new()
		llvm_cond_branch(invalid, trap, valid)
		llvm_label(trap)
		llvm_put(c"  call void @llvm.trap()\x0a  unreachable\x0a")
		llvm_terminated = 1
		llvm_label(valid)
		instruction = c"sdiv"
		if (op == '%'): instruction = c"srem"
	if (instruction == 0):
		llvm_error(id, c"integer operator")
		return c"0"
	if ((op == 'L') || (op == 'R')): b = llvm_instruction(c"and", b, c"63")
	char* result = llvm_instruction(instruction, a, b)
	if ((op >= 0x94) && (op <= 0x9f)): result = llvm_extend(result)
	return result

char* llvm_expression_inner(int group, int operand);

char* llvm_expression(int group, int operand):
	if (llvm_expression_depth >= 256):
		llvm_error(group + 1 + operand, c"expression nesting beyond 256 nodes")
		return c"0"
	llvm_expression_depth = llvm_expression_depth + 1
	char* result = llvm_expression_inner(group, operand)
	llvm_expression_depth = llvm_expression_depth - 1
	return result

char* llvm_expression_inner(int group, int operand):
	if (llvm_failed): return c"0"
	int id = group + 1 + operand
	retained_node node
	retained_node_load(id, &node)
	if (llvm_scalar(node.semantic_type) == 0):
		llvm_error(id, c"expression type (only int and bool are supported)")
		return c"0"
	int op = node.op
	if ((op == 0) || (op == 'c') || (op == 'h')): return llvm_number(node.literal_value)
	if (op == 'v'):
		if ((node.binding < 0) || ((node.binding in llvm_locals) == 0)):
			llvm_error(id, c"nonlocal variable")
			return c"0"
		return llvm_load(node.binding)
	if (op == 'C'):
		if (node.binding < 0):
			llvm_error(id, c"indirect call")
			return c"0"
		retained_binding* callee = retained_bindings[node.binding]
		if ((callee.linkage in llvm_functions) == 0):
			llvm_error(id, c"call outside the input module")
			return c"0"
		list[char*] values = new list[char*]
		int arg = node.left
		while (arg >= 0):
			values.push(llvm_expression(group, arg))
			retained_node argument
			retained_node_load(group + 1 + arg, &argument)
			arg = argument.next_arg
		if (values.length != callee.parameters.length): llvm_error(id, c"call argument count")
		for i in range(values.length):
			if (i < callee.parameters.length): values[i] = llvm_coerce(values[i], callee.parameters[i])
		char* result = llvm_temp()
		llvm_put(c"  ")
		llvm_put(result)
		llvm_put(c" = call i64 ")
		llvm_put(llvm_name(c"@w", callee.linkage))
		llvm_put(c"(")
		for i in range(values.length):
			if (i > 0): llvm_put(c", ")
			llvm_put(c"i64 ")
			llvm_put(values[i])
		llvm_put(c")\x0a")
		values.free()
		return result
	if (op == '='):
		retained_node left
		retained_node_load(group + 1 + node.left, &left)
		if ((left.op != 'v') || ((left.binding in llvm_locals) == 0)):
			llvm_error(id, c"assignment target")
			return c"0"
		char* before = c"0"
		if (node.value != 0): before = llvm_load(left.binding)
		char* value = llvm_expression(group, node.right)
		if (node.value != 0): value = llvm_binary(id, node.value, before, value)
		value = llvm_coerce(value, left.semantic_type)
		llvm_store(left.binding, value)
		return value
	if ((op == 'a') || (op == 'o')):
		int end = llvm_label_new()
		list[int] predecessors = new list[int]
		list[char*] conditions = new list[char*]
		int child = node.left
		while (child >= 0):
			char* value = llvm_bool(llvm_expression(group, child))
			predecessors.push(llvm_block)
			conditions.push(value)
			retained_node part
			retained_node_load(group + 1 + child, &part)
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
	if (op == 'K'): return llvm_coerce(llvm_expression(group, node.left), node.semantic_type)
	if ((op == 'n') || (op == 'p') || (op == '~') || (op == '!') || (op == 'b')):
		char* value = llvm_expression(group, node.left)
		if (op == 'n'): return llvm_instruction(c"sub", c"0", value)
		if (op == '~'): return llvm_instruction(c"xor", value, c"-1")
		if (op == '!'): return llvm_extend(llvm_instruction(c"icmp eq", value, c"0"))
		if (op == 'b'): return llvm_extend(llvm_bool(value))
		return value
	if ((node.left >= 0) && (node.right >= 0)):
		char* a = llvm_expression(group, node.left)
		char* b = llvm_expression(group, node.right)
		return llvm_binary(id, op, a, b)
	llvm_error(id, c"expression form")
	return c"0"

char* llvm_group(int id):
	retained_node node
	retained_node_load(id, &node)
	return llvm_expression(id, node.op)

void llvm_statement(int id):
	if (llvm_failed): return
	retained_node node
	retained_node_load(id, &node)
	# Preserve validation of unreachable code without invalid LLVM blocks.
	if (llvm_terminated): llvm_label(llvm_label_new())
	if ((strcmp(node.name, c":") == 0) || (strcmp(node.name, c"{") == 0)):
		int child = llvm_first[id]
		while (child >= 0):
			llvm_statement(child)
			child = llvm_next[child]
		return
	if (strcmp(node.name, c"pass") == 0): return
	if ((strcmp(node.name, c"break") == 0) || (strcmp(node.name, c"continue") == 0)):
		int target = llvm_break_label
		if (strcmp(node.name, c"continue") == 0): target = llvm_continue_label
		if (target < 0): llvm_error(id, c"jump outside while")
		else: llvm_branch(target)
		llvm_reachable = 0
		return
	if (strcmp(node.name, c"return") == 0):
		int group = llvm_first[id]
		if ((group < 0) || (retained_node_kind(group) != retained_expression_group)):
			llvm_error(id, c"return without an integer value")
			return
		char* value = llvm_coerce(llvm_group(group), retained_bindings[llvm_function].return_type)
		llvm_put(c"  ret i64 ")
		llvm_put(value)
		llvm_put(c"\x0a")
		llvm_terminated = 1
		llvm_reachable = 0
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
		if ((child < 0) || (retained_node_kind(child) != retained_expression_group)):
			llvm_error(id, c"local without an initializer")
			return
		llvm_store(local.binding, llvm_group(child))
		if (llvm_next[child] >= 0): llvm_error(id, c"multiple local declaration")
		return
	if ((child >= 0) && (retained_node_kind(child) == retained_expression_group) && (llvm_next[child] < 0)):
		retained_node expression
		retained_node_load(child, &expression)
		if (expression.start != node.start):
			llvm_error(id, c"statement keyword")
			return
		# Only expression statements can use this catch-all. Keywords such
		# as assert/defer also have an expression but require other semantics.
		if ((strcmp(node.name, c"assert") == 0) || (strcmp(node.name, c"defer") == 0) || (strcmp(node.name, c"yield") == 0)):
			llvm_error(id, c"statement keyword")
			return
		llvm_group(child)
		return
	llvm_error(id, c"statement form")

int llvm_function_has_body(int id):
	int child = llvm_first[id]
	while (child >= 0):
		if (retained_node_kind(child) == retained_statement): return 1
		child = llvm_next[child]
	return 0


void llvm_emit_function(int id):
	retained_node node
	retained_node_load(id, &node)
	llvm_function = node.binding
	retained_binding* function = retained_bindings[node.binding]
	llvm_register = 0
	llvm_label_counter = 0
	llvm_terminated = 0
	llvm_reachable = 1
	llvm_expression_depth = 0
	llvm_locals = new map[int, int]
	llvm_put(c"define internal i64 ")
	llvm_put(llvm_name(c"@w", function.linkage))
	llvm_put(c"(")
	int child = llvm_first[id]
	int argument = 0
	while ((child >= 0) && (retained_node_kind(child) == retained_local)):
		retained_node parameter
		retained_node_load(child, &parameter)
		if (argument > 0): llvm_put(c", ")
		llvm_put(c"i64 ")
		llvm_put(llvm_name(c"%a", parameter.binding))
		argument = argument + 1
		child = llvm_next[child]
	llvm_put(c") {\x0a")
	llvm_label(0)
	for i in range(retained_bindings.length):
		retained_binding* local = retained_bindings[i]
		if (local.owner == id):
			if (llvm_scalar(local.type) == 0): llvm_error(id, c"local type (only int and bool are supported)")
			llvm_locals[i] = 1
			llvm_put(c"  ")
			llvm_put(llvm_name(c"%v", i))
			llvm_put(c" = alloca i64\x0a")
	int parameter_id = llvm_first[id]
	while ((parameter_id >= 0) && (retained_node_kind(parameter_id) == retained_local)):
		retained_node parameter
		retained_node_load(parameter_id, &parameter)
		llvm_store(parameter.binding, llvm_name(c"%a", parameter.binding))
		parameter_id = llvm_next[parameter_id]
	while (child >= 0):
		llvm_statement(child)
		child = llvm_next[child]
	if (llvm_reachable): llvm_error(id, c"function fallthrough without an explicit return")
	if (llvm_terminated == 0): llvm_put(c"  unreachable\x0a")
	llvm_put(c"}\x0a\x0a")
	llvm_locals.free()

# Called only after a successful x64 production compile with semantic
# retention enabled. Return 1 on success; unsupported input leaves output
# untouched. All IR, including declarations, is validated before writing.
int llvm_emit(char* filename, char* output_path):
	llvm_failed = 0
	llvm_ir = string_new()
	llvm_functions = new map[int, int]
	llvm_first = new list[int]
	llvm_next = new list[int]
	llvm_source = -1
	for i in range(retained_sources.length):
		if (strcmp(retained_sources[i].path, filename) == 0): llvm_source = i
	if (llvm_source < 0):
		wstream* err = stderr_writer()
		stream_write_line(err, c"wllvm: input is absent from the retained semantic forest")
		stream_flush(err)
		string_free(llvm_ir)
		llvm_functions.free()
		llvm_first.free()
		llvm_next.free()
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
	int main_binding = -1
	for id in range(count):
		retained_node node
		retained_node_load(id, &node)
		if (node.source == llvm_source):
			if ((node.kind == retained_statement) && (node.parent == retained_sources[llvm_source].root)): llvm_error(id, c"top-level executable statement")
			if (node.kind == retained_import): llvm_error(id, c"import (single-module experiment)")
			if (node.kind == retained_declaration):
				if ((node.result_type == 0) || (strcmp(node.result_type, c"function") != 0)): llvm_error(id, c"top-level declaration (only functions are supported)")
			if (node.kind == retained_function):
				if (node.binding < 0):
					llvm_error(id, c"unbound function")
				else:
					retained_binding* function = retained_bindings[node.binding]
					if (llvm_scalar(function.return_type) == 0): llvm_error(id, c"function return type (only int and bool are supported)")
					for p in range(function.parameters.length):
						if (llvm_scalar(function.parameters[p]) == 0): llvm_error(id, c"function parameter type")
					if (llvm_function_has_body(id)): llvm_functions[function.linkage] = id
					if ((strcmp(node.name, c"main") == 0) && llvm_function_has_body(id)):
						main_binding = node.binding
						if (function.parameters.length != 0): llvm_error(id, c"main parameters")
	if (main_binding < 0): llvm_error(retained_sources[llvm_source].root, c"program without int main()")
	llvm_put(c"; W LLVM offload experiment: production retained AST, signed 64-bit words\x0a")
	llvm_put(c"declare void @llvm.trap()\x0a\x0a")
	for id in range(count):
		retained_node node
		retained_node_load(id, &node)
		if ((node.source == llvm_source) && (node.kind == retained_function) && llvm_function_has_body(id) && (llvm_failed == 0)): llvm_emit_function(id)
	if (llvm_failed == 0):
		llvm_put(c"define i32 @main() {\x0aentry:\x0a  %result = call i64 ")
		llvm_put(llvm_name(c"@w", retained_bindings[main_binding].linkage))
		llvm_put(c"()\x0a  %exit = trunc i64 %result to i32\x0a  ret i32 %exit\x0a}\x0a")
	int success = 0
	if (llvm_failed == 0):
		success = file_write_text(output_path, llvm_ir.data)
		if (success == 0):
			wstream* err = stderr_writer()
			stream_write_cstr(err, c"wllvm: cannot write output: ")
			stream_write_line(err, output_path)
			stream_flush(err)
	string_free(llvm_ir)
	llvm_functions.free()
	llvm_first.free()
	llvm_next.free()
	return success
