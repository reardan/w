# Owned main-function syntax for the initial word-sized integer subset.
# Unlike incremental statement walks, this tree exists before any emission.
const int function_record_literal = 1
const int function_record_reference = 2
const int function_record_binary = 3
const int function_record_unary = 4
const int function_record_local = 5
const int function_record_assign = 6
const int function_record_if = 7
const int function_record_while = 8
const int function_record_for = 9
const int function_record_return = 10
const int function_record_eq = 256
const int function_record_ne = 257
const int function_record_le = 258
const int function_record_ge = 259
const int function_record_and = 260
const int function_record_or = 261

struct function_local_ast:
	char* name
	int id
	int parameter
	int scope
	int active
	function_local_ast* next

struct function_node_ast:
	int kind
	int op
	int value
	int line
	int column
	int start
	int end
	int retained_id
	function_local_ast* binding
	function_node_ast* left
	function_node_ast* right
	function_node_ast* body
	function_node_ast* otherwise
	function_node_ast* next

struct function_body_ast:
	char* source_file
	int retained_id
	int scope
	int local_count
	int parameter_count
	int analyzed
	function_local_ast* bindings
	function_local_ast* bindings_tail
	function_node_ast* statements

char* function_record_alloc(int size):
	char* result = retained_arena_alloc(size)
	for i in range(size): result[i] = 0
	return result
