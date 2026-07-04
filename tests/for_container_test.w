# for x in <container> — cursor-protocol iteration over the standard
# containers and a user-defined one (docs/projects/iteration.md, design 3).
import lib.testing
import structures.array_list
import structures.linked_list
import structures.hash_map


void test_array_list_sum():
	array_list* a = array_list_new()
	array_list_push(a, 4)
	array_list_push(a, 5)
	array_list_push(a, 6)
	int sum = 0
	int count = 0
	for int x in a:
		sum = sum + x
		count = count + 1
	assert_equal(15, sum)
	assert_equal(3, count)
	array_list_free(a)


void test_array_list_empty():
	array_list* a = array_list_new()
	int count = 0
	for int x in a:
		count = count + 1
	assert_equal(0, count)
	array_list_free(a)


void test_array_list_break():
	array_list* a = array_list_new()
	for int i in range(10):
		array_list_push(a, i)
	int sum = 0
	for int x in a:
		if (x == 3):
			break
		sum = sum + x
	assert_equal(3, sum) /* 0 + 1 + 2 */
	array_list_free(a)


void test_array_list_continue():
	array_list* a = array_list_new()
	for int i in range(10):
		array_list_push(a, i)
	int sum = 0
	for int x in a:
		if (x % 2):
			continue
		sum = sum + x
	assert_equal(20, sum) /* 0 + 2 + 4 + 6 + 8 */
	array_list_free(a)


void test_nested_two_lists():
	array_list* outer = array_list_new()
	array_list_push(outer, 1)
	array_list_push(outer, 2)
	array_list* inner = array_list_new()
	array_list_push(inner, 10)
	array_list_push(inner, 20)
	int sum = 0
	for int x in outer:
		for int y in inner:
			sum = sum + x * y
	assert_equal(90, sum) /* (1+2) * (10+20) */
	array_list_free(outer)
	array_list_free(inner)


void test_nested_same_list():
	array_list* a = array_list_new()
	array_list_push(a, 1)
	array_list_push(a, 2)
	array_list_push(a, 3)
	int count = 0
	for int x in a:
		for int y in a:
			count = count + 1
	assert_equal(9, count)
	array_list_free(a)


void test_nested_break_inner_only():
	array_list* a = array_list_new()
	array_list_push(a, 1)
	array_list_push(a, 2)
	array_list_push(a, 3)
	int count = 0
	for int x in a:
		for int y in a:
			if (y == 2):
				break
			count = count + 1
	assert_equal(3, count) /* inner loop runs once per outer element */
	array_list_free(a)


void test_range_inside_container_loop():
	array_list* a = array_list_new()
	array_list_push(a, 2)
	array_list_push(a, 3)
	int sum = 0
	for int x in a:
		for int i in range(x):
			sum = sum + 1
	assert_equal(5, sum)
	array_list_free(a)


void test_linked_list_values_in_order():
	linked_list* l = linked_list_new()
	linked_list_push(l, 7)
	linked_list_push(l, 8)
	linked_list_push(l, 9)
	int digits = 0
	for int x in l:
		digits = digits * 10 + x
	assert_equal(789, digits)
	linked_list_free(l)


void test_linked_list_empty():
	linked_list* l = linked_list_new()
	int count = 0
	for int x in l:
		count = count + 1
	assert_equal(0, count)
	linked_list_free(l)


void test_hash_map_keys():
	hash_map* m = hash_map_new()
	hash_map_set(m, c"one", 1)
	hash_map_set(m, c"two", 2)
	hash_map_set(m, c"three", 3)
	int count = 0
	int sum = 0
	for char* key in m:
		assert_equal(1, hash_map_contains(m, key))
		count = count + 1
		sum = sum + hash_map_get(m, key)
	assert_equal(3, count)
	assert_equal(6, sum)
	hash_map_free(m)


void test_hash_map_empty():
	hash_map* m = hash_map_new()
	int count = 0
	for char* key in m:
		count = count + 1
	assert_equal(0, count)
	hash_map_free(m)


array_list* make_list(int n):
	array_list* a = array_list_new()
	for int i in range(n):
		array_list_push(a, i + 1)
	return a


void test_iterable_from_call_expression():
	int sum = 0
	for int x in make_list(4):
		sum = sum + x
	assert_equal(10, sum) /* 1 + 2 + 3 + 4 */


# A user-defined container proves the protocol needs no compiler support:
# any struct type with the four _iter_ functions is iterable.
struct countdown:
	int start

countdown* countdown_new(int start):
	countdown* c = malloc(4)
	c.start = start
	return c

int countdown_iter_begin(countdown* c):
	return c.start

int countdown_iter_done(countdown* c, int cursor):
	return cursor <= 0

int countdown_iter_next(countdown* c, int cursor):
	return cursor - 1

int countdown_iter_value(countdown* c, int cursor):
	return cursor


void test_user_defined_container():
	countdown* c = countdown_new(4)
	int digits = 0
	for int x in c:
		digits = digits * 10 + x
	assert_equal(4321, digits)
	free(c)
