# Tile semantics run only after the complete region has been recorded.
# They allocate no stack slots, emit no instructions and never replay source.
# Memory effects remain in the source tree's evaluation order; masked loads
# have zero passthrough and stores discard invalid elements.
import compiler.tile_ast


int tile_scalar_type(int type):
	type = type_unqualified(type)
	if (type == type_lookup(c"int")): return type
	if ((type == float32_type) || (type == float_type)): return float32_type
	return -1


int tile_float_pointer(int type):
	type = type_unqualified(type)
	if (type < 0): return 0
	if (type_get_pointer_level(type) != 1): return 0
	int element = type_unqualified(type_strip_gpu(type_lookup_previous_pointer(type)))
	return (element == float32_type) || (element == float_type)


void tile_analysis_shape(tile_node* node, int rank, int rows, int cols):
	node.rank = rank
	node.rows = rows
	node.cols = cols
	node.uniform = rank == 0


void tile_analysis_effect(tile_program* program, tile_node* node):
	program.effect_count = program.effect_count + 1
	node.effect_order = program.effect_count


void tile_analysis_numeric(tile_node* node):
	if (tile_scalar_type(node.type) < 0):
		tile_error_at(node, c"tile arithmetic requires int or float32 values")


void tile_analysis_uniform_int(tile_node* node):
	if ((node.type != type_lookup(c"int")) || (node.rank != 0) || (node.uniform == 0)):
		tile_error_at(node, c"tile bounds and control flow require a uniform scalar int")


void tile_analysis_header(tile_node* node):
	if ((node.kind == tile_literal) && (node.type == type_lookup(c"int"))): return
	if (node.kind == tile_reference):
		if ((node.binding.kind == tile_binding_capture) && (node.type == type_lookup(c"int"))): return
	else if (node.kind == tile_unary):
		tile_analysis_header(node.left)
		return
	else if (node.kind == tile_binary):
		tile_analysis_header(node.left)
		tile_analysis_header(node.right)
		return
	tile_error_at(node, c"tile range bound requires a host integer expression")


void tile_analysis_matrix(tile_program* program, tile_node* node):
	if (program.width != 1):
		tile_error_at(node, c"rank-two tile operations require gpu[1] and tile_program_id()")
	program.matrix_mode = 1


# Only scalar broadcast is implicit. Rank-two singleton-axis broadcasting
# needs an explicit layout rule before it can be accepted.
void tile_analysis_broadcast(tile_node* result, tile_node* left, tile_node* right):
	if (left.rank == 0):
		tile_analysis_shape(result, right.rank, right.rows, right.cols)
	else if (right.rank == 0):
		tile_analysis_shape(result, left.rank, left.rows, left.cols)
	else:
		if ((left.rank != right.rank) || (left.rows != right.rows) || (left.cols != right.cols)):
			tile_error_at(result, c"tile shape mismatch; only scalar broadcasting is implicit")
		tile_analysis_shape(result, left.rank, left.rows, left.cols)
	result.uniform = left.uniform && right.uniform


void tile_analyze_expression(tile_program* program, tile_node* node, int destination);


int tile_analysis_arguments(tile_program* program, tile_node* node):
	int count = 0
	tile_node* arg = node.args
	while (arg != 0):
		tile_analyze_expression(program, arg, 0)
		count = count + 1
		arg = arg.next
	return count


void tile_analysis_pointer(tile_node* node, int writable):
	if ((node.rank != 0) || (tile_float_pointer(node.type) == 0)):
		tile_error_at(node, c"tile memory operations require a float32 pointer")
	if (writable):
		int element = type_lookup_previous_pointer(type_unqualified(node.type))
		if (type_get_const_target(type_strip_gpu(element)) >= 0):
			tile_error_at(node, c"cannot store through a const tile pointer")


void tile_analysis_address(tile_node* node, int writable):
	tile_node* arg = node.args
	tile_analysis_pointer(arg, writable)
	arg = arg.next
	int i = 0
	while (i < 6):
		tile_analysis_uniform_int(arg)
		arg = arg.next
		i = i + 1


void tile_analysis_binary(tile_node* node):
	tile_analysis_numeric(node.left)
	tile_analysis_numeric(node.right)
	tile_analysis_broadcast(node, node.left, node.right)
	node.type = type_lookup(c"int")
	if ((node.left.type == float32_type) || (node.right.type == float32_type)):
		node.type = float32_type
	int op = node.op
	if ((op == tile_op_and) || (op == tile_op_or)):
		tile_analysis_uniform_int(node.left)
		tile_analysis_uniform_int(node.right)
	if (op == '%'):
		if (node.type == float32_type):
			tile_error_at(node, c"tile remainder requires int operands")
	if ((op == '<') || (op == '>') || (op >= tile_op_eq)):
		node.type = type_lookup(c"int")


void tile_analyze_expression(tile_program* program, tile_node* node, int destination):
	if (node == 0): tile_error_at(node, c"missing tile expression")
	int kind = node.kind
	if (kind == tile_literal):
		if (node.type != float32_type): node.type = type_lookup(c"int")
		tile_analysis_shape(node, 0, 1, 1)
	else if (kind == tile_program_id):
		if (node.args != 0): tile_error_at(node, c"tile_program_id expects no arguments")
		node.type = type_lookup(c"int")
		tile_analysis_shape(node, 0, 1, 1)
	else if (kind == tile_reference):
		tile_binding* binding = node.binding
		if ((binding == 0) || (binding.initialized == 0)):
			tile_error_at(node, c"tile local is used before initialization")
		node.type = binding.type
		tile_analysis_shape(node, binding.rank, binding.rows, binding.cols)
		node.uniform = binding.uniform
	else if (kind == tile_unary):
		tile_analyze_expression(program, node.left, 0)
		tile_analysis_numeric(node.left)
		node.type = node.left.type
		tile_analysis_shape(node, node.left.rank, node.left.rows, node.left.cols)
		node.uniform = node.left.uniform
		if (node.op == '!'): node.type = type_lookup(c"int")
	else if (kind == tile_binary):
		tile_analyze_expression(program, node.left, 0)
		tile_analyze_expression(program, node.right, 0)
		tile_analysis_binary(node)
	else if (kind == tile_index):
		tile_analyze_expression(program, node.left, 0)
		tile_analyze_expression(program, node.right, 0)
		tile_analysis_pointer(node.left, destination)
		if ((node.right.type != type_lookup(c"int")) || (node.right.rank != 1) || (node.right.cols != program.width)):
			tile_error_at(node, c"tile indexing requires an integer tile index of the region width")
		if ((node.right.kind != tile_reference) || (node.right.binding != program.tile_binding)):
			tile_error_at(node, c"tile memory indexing requires the direct region tile identifier")
		node.type = float32_type
		tile_analysis_shape(node, 1, 1, program.width)
		node.masked = 1
		if (destination == 0): tile_analysis_effect(program, node)
	else if (kind == tile_load):
		if (tile_analysis_arguments(program, node) != 9):
			tile_error_at(node, c"tile_load expects pointer, row, column, two strides, two bounds and two static dimensions")
		tile_analysis_address(node, 0)
		tile_node* dimension = node.args
		int i = 0
		while (i < 7):
			dimension = dimension.next
			i = i + 1
		if ((dimension.kind != tile_literal) || (dimension.type != type_lookup(c"int")) || (dimension.value != 16) || (dimension.next.kind != tile_literal) || (dimension.next.type != type_lookup(c"int")) || (dimension.next.value != 16)):
			tile_error_at(node, c"rank-two tile dimensions must be the constant 16 by 16")
		tile_analysis_matrix(program, node)
		node.type = float32_type
		tile_analysis_shape(node, 2, 16, 16)
		node.masked = 1
		tile_analysis_effect(program, node)
	else if (kind == tile_zero):
		if (tile_analysis_arguments(program, node) != 2):
			tile_error_at(node, c"tile_zero expects two static dimensions")
		if ((node.args.kind != tile_literal) || (node.args.type != type_lookup(c"int")) || (node.args.value != 16) || (node.args.next.kind != tile_literal) || (node.args.next.type != type_lookup(c"int")) || (node.args.next.value != 16)):
			tile_error_at(node, c"rank-two tile dimensions must be the constant 16 by 16")
		tile_analysis_matrix(program, node)
		node.type = float32_type
		tile_analysis_shape(node, 2, 16, 16)
	else if (kind == tile_dot):
		if (tile_analysis_arguments(program, node) != 2):
			tile_error_at(node, c"dot expects two rank-two float32 tiles")
		tile_node* left = node.args
		tile_node* right = left.next
		if ((left.rank != 2) || (right.rank != 2) || (left.type != float32_type) || (right.type != float32_type) || (left.cols != right.rows)):
			tile_error_at(node, c"dot requires compatible rank-two float32 tiles")
		tile_analysis_matrix(program, node)
		node.type = float32_type
		tile_analysis_shape(node, 2, left.rows, right.cols)
		# A static dot owns two 16x16 f32 shared operands. Iterations reuse
		# those buffers only after every thread has crossed the final barrier.
		program.shared_bytes = program.shared_bytes + 2048
		if (program.shared_bytes > 49152):
			tile_error_at(node, c"tile region exceeds the 48 KiB shared-memory limit")
		tile_analysis_effect(program, node)
	else:
		tile_error_at(node, c"unsupported expression in a tile body")


void tile_analysis_assignment(tile_node* owner, tile_node* destination, tile_node* value):
	tile_analysis_numeric(value)
	if (destination.type != value.type):
		if ((destination.type != float32_type) || (value.type != type_lookup(c"int"))):
			tile_error_at(owner, c"tile assignment would narrow or change the element type")
	if (value.rank != 0):
		if ((destination.rank != value.rank) || (destination.rows != value.rows) || (destination.cols != value.cols)):
			tile_error_at(owner, c"tile assignment shape mismatch")
	else if (destination.rank == 0):
		if (value.uniform == 0): tile_error_at(owner, c"tile scalar assignments require uniform values")


void tile_analyze_statements(tile_program* program, tile_node* first):
	tile_node* node = first
	while (node != 0):
		int kind = node.kind
		if (kind == tile_declare):
			tile_analyze_expression(program, node.left, 0)
			tile_analysis_numeric(node.left)
			tile_binding* binding = node.binding
			if (binding.declared_type < 0):
				binding.type = node.left.type
				binding.rank = node.left.rank
				binding.rows = node.left.rows
				binding.cols = node.left.cols
			else:
				binding.type = tile_scalar_type(binding.declared_type)
				if ((binding.type < 0) || (node.left.rank != 0)):
					tile_error_at(node, c"explicit tile-body locals must be scalar int or float32")
				if ((binding.type != node.left.type) && (binding.type != float32_type)):
					tile_error_at(node, c"tile local initializer would narrow its element type")
				binding.rank = 0
				binding.rows = 1
				binding.cols = 1
			binding.uniform = node.left.uniform
			binding.initialized = 1
			node.type = binding.type
			tile_analysis_shape(node, binding.rank, binding.rows, binding.cols)
		else if (kind == tile_assign):
			tile_node* destination = node.left
			if ((destination.kind != tile_index) && (destination.kind != tile_reference)):
				tile_error_at(node, c"tile assignments require a local or indexed destination")
			if (destination.kind == tile_reference):
				if (destination.binding.kind != tile_binding_local):
					tile_error_at(node, c"tile captures and loop indices are read-only")
			tile_analyze_expression(program, node.right, 0)
			tile_analyze_expression(program, destination, 1)
			tile_analysis_assignment(node, destination, node.right)
			node.type = destination.type
			tile_analysis_shape(node, destination.rank, destination.rows, destination.cols)
			if (destination.kind == tile_index):
				if (node.op != 0): tile_analysis_effect(program, destination)
				node.masked = 1
				tile_analysis_effect(program, node)
		else if (kind == tile_if):
			tile_analyze_expression(program, node.left, 0)
			tile_analysis_uniform_int(node.left)
			tile_analyze_statements(program, node.body)
			tile_analyze_statements(program, node.otherwise)
		else if (kind == tile_for):
			tile_analyze_expression(program, node.left, 0)
			tile_analyze_expression(program, node.right, 0)
			tile_analysis_uniform_int(node.left)
			tile_analysis_uniform_int(node.right)
			node.binding.type = type_lookup(c"int")
			node.binding.rank = 0
			node.binding.rows = 1
			node.binding.cols = 1
			node.binding.uniform = 1
			node.binding.initialized = 1
			tile_analyze_statements(program, node.body)
		else if (kind == tile_store):
			if (tile_analysis_arguments(program, node) != 8):
				tile_error_at(node, c"tile_store expects pointer, row, column, two strides, two bounds and a tile")
			tile_analysis_address(node, 1)
			tile_node* value = node.args
			while (value.next != 0): value = value.next
			if ((value.rank != 2) || (value.type != float32_type)):
				tile_error_at(node, c"tile_store requires a rank-two float32 tile")
			tile_analysis_matrix(program, node)
			node.type = float32_type
			tile_analysis_shape(node, 2, value.rows, value.cols)
			node.masked = 1
			tile_analysis_effect(program, node)
		else:
			tile_error_at(node, c"unsupported statement in a tile body")
		node = node.next


void tile_analyze(tile_program* program):
	# Analysis may be repeated after owned syntax changes. A lowering plan is
	# valid only for the analysis that produced it; old plans remain arena-owned.
	program.plan = 0
	if ((program.width < 1) || (program.width > 1024)):
		tile_error_at(program.bound, c"tile width must be a constant from 1 to 1024")
	if (program.binding_count > 256):
		tile_error_at(program.bound, c"tile region exceeds the static binding or capture limit")
	program.analyzed = 0
	program.matrix_mode = 0
	program.shared_bytes = 0
	program.effect_count = 0
	tile_binding* binding = program.bindings
	while (binding != 0):
		binding.initialized = 0
		if (binding.kind == tile_binding_capture):
			int scalar = tile_scalar_type(binding.type)
			if (scalar >= 0): binding.type = scalar
			else if (tile_float_pointer(binding.type) == 0):
				tile_error_at(program.bound, c"tile captures support only int, float32 and float32 pointers")
			binding.rank = 0
			binding.rows = 1
			binding.cols = 1
			binding.uniform = 1
			binding.initialized = 1
		else if (binding.kind == tile_binding_index):
			binding.type = type_lookup(c"int")
			binding.rank = 1
			binding.rows = 1
			binding.cols = program.width
			binding.uniform = 0
			binding.initialized = 1
		binding = binding.next
	tile_analyze_expression(program, program.bound, 0)
	tile_analysis_uniform_int(program.bound)
	tile_analysis_header(program.bound)
	tile_analyze_statements(program, program.body)
	program.analyzed = 1
