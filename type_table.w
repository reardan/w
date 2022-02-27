/*
struct type_table_s:
	char* name
	...
	8 fields (32 bytes)
*/
import list


int type_size():
	return 32


int type_push(char* name):
	char* new_type = malloc(type_size())
	int* p = name
	save_int(new_type, p)
	push(new_type)


int type_lookup(char* name):
	int i = 0
	while (i < length):
		int type = get(i)
		if (strcmp(name, *type) == 0):
			return i
		i = i + 1
	return 0-1


void push_basic_types():
	die() /* reset array */
	# type_push("")
	type_push("void")
	type_push("int")
	type_push("char")

