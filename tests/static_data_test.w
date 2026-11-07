# wbuild: x64
# wbuild: step="bin/wv2 --streaming tests/static_data_test.w -o bin/static_data_streaming_test"
# wbuild: step="bin/static_data_streaming_test" expect_stdout="static data OK"
# wbuild: step="bin/wv2 x64 --pie tests/static_data_test.w -o bin/static_data_pie_test"
# wbuild: step="bin/static_data_pie_test" expect_stdout="static data OK"
# File-scope brace initializers (grammar/program.w,
# global_brace_initializer): a global's bytes laid out item by item --
# integers of each width, address words, padding -- the way a C
# compiler emits static data, with no code run before main. The
# --emit=obj side links the same shapes with C
# (tests/object_file/static_data.w).
import lib.lib
import lib.assert

struct rec:
	int16 a
	uint8 b
	uint8 gap
	int32 c
	char* name
	int* target
	int* inner

struct words:
	int32 a
	int32 b
	int op
	int ref

type unary = fn(int) -> int

int value = 7
int later(int x);

# Items may continue on following lines; a trailing comma is allowed
rec first = {int16 -2, uint8 255, pad 1, int32 70000,
	c"hi", &value,
	&table + 4,
}
rec second = {pad 8, char* c"typed", int* &value}
rec empty = {}
words table = {int32 1, int32 3, later, &first}
int scalar = {int16 -1}
# Forward references: a global and a function neither declared yet
rec cyc_a = {pad 8, c"a", &cyc_b}
rec cyc_b = {pad 8, c"b", &cyc_a}
words forward = {int32 5, int32 6, defined_after, &cyc_b - 8}
int* self = {&self}


int later(int x):
	return x + 2


int defined_after(int x):
	return x * 3


int main():
	assert_equal(-2, first.a)
	assert_equal(255, first.b)
	assert_equal(0, first.gap)
	assert_equal(70000, first.c)
	assert_equal(0, strcmp(first.name, c"hi"))
	assert_equal(7, *first.target)
	int32* raw = cast(int32*, &table)
	assert_equal(3, raw[1])
	assert_equal(3, *cast(int32*, first.inner))
	assert_equal(0, second.a)
	assert_equal(0, strcmp(second.name, c"typed"))
	assert_equal(7, *second.target)
	assert_equal(0, cast(int, empty.name))
	unary* op = cast(unary*, table.op)
	assert_equal(42, op(40))
	assert_equal(cast(int, &first), table.ref)
	# Bytes past the last item stay zero: only the low 16 bits are set
	assert_equal(65535, scalar)
	assert_equal(cast(int, &self), cast(int, self))
	assert_equal(cast(int, &cyc_b), cast(int, cyc_a.target))
	assert_equal(cast(int, &cyc_a), cast(int, cyc_b.target))
	rec* other = cast(rec*, cyc_a.target)
	assert_equal(0, strcmp(other.name, c"b"))
	unary* tripled = cast(unary*, forward.op)
	assert_equal(21, tripled(7))
	assert_equal(cast(int, &cyc_b) - 8, forward.ref)
	println(c"static data OK")
	return 0
