# The parser-generator suite also parses the literal checked syntax.
int main():
	own int* p = new int
	ref int* r = p
	int n = *r
	refmut int* m = p
	*m = n + 1
	unsafe:
		int value = 1
		int* raw = &value
		*raw = 2
	return *p - 1
