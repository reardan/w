import lib.testing
import lib.generator
import lib.utf8
import structures.string

# f-string interpolating a defaulted call and a variadic call
int greet(int base, int bonus = 5):
	return base + bonus

int vsum(int... values):
	int total = 0
	for int v in values:
		total = total + v
	return total

generator int squares(int n):
	int i = 0
	while (i < n):
		yield i * i
		i = i + 1

void test_fstring_with_defaults_and_variadics():
	string s = f"greet={greet(10)} vsum={vsum(1, 2, 3)}"
	assert_equal(0, strcmp(cstr(s), c"greet=15 vsum=6"))

void test_generator_yields_into_fstring():
	string_builder* sb = string_new()
	for int x in squares(4):
		string_append_int(sb, x)
		string_append_char(sb, ',')
	string acc = string_builder_to_string(sb)
	assert_equal(0, strcmp(cstr(acc), c"0,1,4,9,"))

generator int gen_with_default(int n, int step = 2):
	int i = 0
	while (i < n):
		yield i
		i = i + step

void test_generator_with_default_arg():
	int total = 0
	for int x in gen_with_default(10):
		total = total + x
	assert_equal(20, total)

# Wave 2: generics + defaults + variadics + template strings combined
T bigger[T](T a, T b):
	if (a > b):
		return a
	return b

struct box[T]:
	T value

void test_generic_with_wave1_features():
	int m = bigger[int](greet(1), vsum(2, 2, 2))
	assert_equal(6, m)
	string s = f"max={bigger[int](3, 5)}"
	assert_equal(0, strcmp(cstr(s), c"max=5"))
	box[int] b
	b.value = vsum(1, 2)
	assert_equal(3, b.value)

# Wave 2: dynamic var interacting with defaults, variadics and f-strings
void test_var_with_wave1_features():
	var x = greet(10)
	assert_equal(15, x)
	var y = vsum(1, 2, 3)
	var total = x + y
	assert_equal(21, total)
	string s = f"x={x} y={y}"
	assert_equal(0, strcmp(cstr(s), c"x=15 y=6"))

# var flowing through a generator loop body
void test_var_accumulates_generator_values():
	var acc = 0
	for int v in squares(4):
		acc = acc + v
	assert_equal(14, acc)
