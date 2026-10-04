# Resolved object/import/enum declarations. Extern function nodes own
# their names and ABI class vector for the duration of their visit.
const int ast_linkage_object = 1
const int ast_linkage_native = 2
const int ast_linkage_wasm = 3
const int ast_linkage_enum = 4

struct linkage_ast:
	int kind
	int binding
	int source_file
	int start_offset
	int end_offset
	int split
	int size
	int value
	int parameter_count
	int variadic
	int return_class
	int return_kind
	char* name
	char* import_name
	char* module_name
	char* parameter_classes

int ast_extern_objects_emitted
int ast_extern_functions_emitted
int ast_enum_values_emitted
