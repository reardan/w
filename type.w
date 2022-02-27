# name:
char* name

# none, variable, function, class
int symtype

# length of this object
int length

# types of the arguments + return value
#  in the case of a function
int* arguments
int num_arguments


void create():
	name = 0
	symtype = 0
	length = 0
	num_arguments = 0
	arguments = 0
