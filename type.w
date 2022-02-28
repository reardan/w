/*
type is the parent for all type classes

type
	basic
		char
		int
		float




*/


/*# name:
char* _type_name

# index into type list
int _type_index

# none, variable, function, class
int _type_symtype

# size of this object
int _type_size

# types of the arguments + return value
# in the case of a function
int* _type_arguments
int _type_num_arguments


void create(char* name):
	_type_name = name
	_type_index = 0
	_type_symtype = 0
	_type_size = 0
	_type_arguments = 0
	_type_num_arguments = 0
*/