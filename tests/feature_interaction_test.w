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
