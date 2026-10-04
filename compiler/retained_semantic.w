# Independently owned semantic records. IDs are session-local, append-only,
# and survive compiler symbol/type table reuse until checkpoint rollback.
import lib.lib

struct retained_field:
	char* name
	int type
	int offset

struct retained_constant:
	char* name
	int value

struct retained_type:
	int source
	char* name
	char* file
	int line
	int column
	int kind
	int size
	int pointer_level
	int target
	int return_type
	int array_length
	list[retained_field*] fields
	list[int] parameters
	list[retained_constant*] constants
	int origin
	int origin_target
	int origin_return
	int origin_parameters
	int building

struct retained_binding:
	char* key
	char* name
	char* file
	int line
	int column
	int scope
	int slot
	int source
	int owner
	int type
	int return_type
	int origin
	int linkage
	list[int] parameters

list[retained_type*] retained_types
list[retained_binding*] retained_bindings
map[int, int] retained_type_cache
map[char*, int] retained_binding_cache


void retained_semantic_invalidate():
	if (retained_type_cache != 0): retained_type_cache.free()
	retained_type_cache = 0


void retained_semantic_rollback(int types, int bindings):
	retained_semantic_invalidate()
	# Remove retracted names from the canonical index; surviving bindings
	# retain their IDs. The map owns its own copies of the lookup keys.
	if (retained_bindings != 0):
		while (retained_bindings.length > bindings):
			retained_binding* binding = retained_bindings.pop()
			retained_binding_cache.remove(binding.key)
			free(binding.key)
			free(binding.name)
			free(binding.file)
			binding.parameters.free()
			free(binding)
	if (retained_types != 0):
		while (retained_types.length > types):
			retained_type* type = retained_types.pop()
			for i in range(type.fields.length):
				retained_field* field = type.fields[i]
				free(field.name)
				free(field)
			for i in range(type.constants.length):
				retained_constant* member = type.constants[i]
				free(member.name)
				free(member)
			type.constants.free()
			type.fields.free()
			type.parameters.free()
			free(type.name)
			free(type.file)
			free(type)


void retained_semantic_clear():
	retained_semantic_rollback(0, 0)
	if (retained_types != 0): retained_types.free()
	if (retained_bindings != 0): retained_bindings.free()
	if (retained_binding_cache != 0): retained_binding_cache.free()
	retained_types = 0
	retained_bindings = 0
	retained_binding_cache = 0
