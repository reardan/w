import lib.lib


void const_pointer_assignment_error():
	const int fixed = 1
	const int* p = &fixed
	*p = 2


int main():
	return 0
