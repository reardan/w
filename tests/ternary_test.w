import lib.testing
import lib.result


int tern_calls
int tern_side(int v):
	tern_calls = tern_calls + 1
	return v


void test_ternary_basic():
	int x = 5
	int y = x > 3 ? 100 : 200
	assert_equal(100, y)
	y = x > 9 ? 100 : 200
	assert_equal(200, y)


void test_ternary_short_circuit():
	# Only the taken arm's code runs
	tern_calls = 0
	int a = 1 ? tern_side(7) : tern_side(8)
	assert_equal(7, a)
	assert_equal(1, tern_calls)
	tern_calls = 0
	int b = 0 ? tern_side(7) : tern_side(8)
	assert_equal(8, b)
	assert_equal(1, tern_calls)


void test_ternary_chained_right_associative():
	int x = 7
	int band = x < 3 ? 1 : x < 10 ? 2 : 3
	assert_equal(2, band)
	x = 42
	band = x < 3 ? 1 : x < 10 ? 2 : 3
	assert_equal(3, band)


void test_ternary_nested_parenthesized():
	int v = (1 ? (0 ? 10 : 20) : 30)
	assert_equal(20, v)


void test_ternary_cstr_arms():
	int n = 4
	char* label = (n % 2 == 0) ? c"even" : c"odd"
	assert_strings_equal(c"even", label)
	label = (n % 2 == 1) ? c"even" : c"odd"
	assert_strings_equal(c"odd", label)


void test_ternary_in_condition_position():
	int hits = 0
	if (1 ? 1 : 0):
		hits = hits + 1
	while (hits < 3 ? 1 : 0):
		hits = hits + 1
	assert_equal(3, hits)


void test_ternary_in_call_and_index():
	char* buf = c"abcdef"
	int i = 2
	assert_equal('c', buf[i > 0 ? 2 : 0])
	assert_equal(30, tern_side(0 ? 20 : 30))


void test_ternary_with_inferred_declaration():
	flag := 1
	msg := flag ? c"on" : c"off"
	assert_strings_equal(c"on", msg)


void test_ternary_float_arms():
	int cold = 1
	float t = cold ? 1.5 : 2.5
	assert_equal(3, cast(int, t * 2.0))


wresult[int]* tern_lookup(int key):
	if (key < 0):
		return result_new_error[int](7)
	return result_new_ok[int](key * 2)


# '?' propagation and the ternary share a token; both must keep working
# in the same function
wresult[int]* tern_score(int key):
	int value = tern_lookup(key)?
	int bonus = value > 5 ? 100 : 50
	return result_new_ok[int](value + bonus)


void test_ternary_and_result_propagation():
	wresult[int]* r = tern_score(4)
	assert_equal(1, r.ok)
	assert_equal(108, r.value)
	r = tern_score(1)
	assert_equal(1, r.ok)
	assert_equal(52, r.value)
	r = tern_score(0 - 3)
	assert_equal(0, r.ok)
	assert_equal(7, r.code)
