# Freestanding W library linked into a C program by a system linker
# (tests/object_file_test.w compiles it with --emit=obj --freestanding).
# Every kind of address the object must relocate appears here: calls
# out to C, C data read and written from W, W data C reads, and static
# pointer words to W data, W functions, string bytes and C data.
type unary = fn(int) -> int

extern int c_scale(int x)
extern void c_record(char* text, int value)
extern int c_value

int w_counter = 7
int[4] w_squares
char* w_greeting_text = c"hello from W"
int* w_counter_cell = &w_counter
int* w_c_value_cell = &c_value
int w_triple(int x);
unary* w_ops_triple = w_triple
unary* w_ops_scale = c_scale


int w_double(int x):
	return x * 2


int w_triple(int x):
	return x * 3


unary* w_ops_double = w_double


export int w_add(int a, int b):
	w_counter = w_counter + 1
	return a + b


export int w_sum(int* xs, int n):
	int total = 0
	for i in range(n): total = total + xs[i]
	return total


export void w_fill(int* out, int n):
	for i in range(n): out[i] = i * i


export int w_call_c(int x):
	# W -> C call, then C data read and written from W
	int scaled = c_scale(x)
	c_value = c_value + scaled
	c_record(w_greeting_text, scaled)
	return c_value


export int w_apply(int which, int x):
	# calls through function pointers stored in static data
	if (which == 0): return w_ops_double(x)
	if (which == 1): return w_ops_triple(x)
	return w_ops_scale(x)


export int w_squares_sum():
	for i in range(4): w_squares[i] = (i + 1) * (i + 1)
	int total = 0
	for i in range(4): total = total + w_squares[i]
	return total


export char* w_greeting():
	return w_greeting_text


export int* w_counter_address():
	return w_counter_cell


export int w_c_value_through_cell():
	return *w_c_value_cell


export int w_literal_length():
	char* text = "static descriptor"
	int n = 0
	while (text[n] != 0): n = n + 1
	return n
