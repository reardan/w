# S2.3 fixture (compiled by tests/ast_generic_retained_test.w in the
# default mode and with --ast-required --ast-emit-retained): generic struct
# fields, instantiation signatures and inference shapes built from retained
# type trees, plus the shapes that keep a re-parse (served from retained
# source bytes), function bodies and deferred statements.
import lib.testing
import lib.container
import tests.ast_generic_retained_helper


struct pair[A, B]:
	A first
	B second


# Recursive through a pointer: the instance's own name is already in the
# type table when its field is resolved.
struct chain[T]:
	T value
	chain[T]* next


# Container, slice, pointer and nested application fields.
struct bag[T]:
	list[T] items
	map[char*, T] index
	set[int] seen
	T[] window
	T** grid
	pair[T, int] tagged
	pair[T, char*]* link
	list[pair[T, T]*] links
	int count


# A fixed-size array field: not a captured shape, so it is re-parsed.
struct cells[T]:
	T[4] slots
	int used


# A by-value generic struct as a list element: its storage rules are
# known only once it is instantiated, so it is re-parsed.
struct rows[T]:
	list[pair[T, T]] values


struct empty[T]:


int deferred_hits


void deferred_bump():
	deferred_hits = deferred_hits + 1


T larger[T](T a, T b):
	if (a > b): return a
	return b


# The parameter shape 'bag[T]*' is opaque to the syntax shapes, so
# inference walks the header with placeholder types.
int bag_count[T](bag[T]* b, T hint):
	return b.count + cast(int, hint)


T head_or[T](list[T] items, T fallback):
	if (items.length == 0): return fallback
	return items[0]


pair[A, B]* fill_pair[A, B](pair[A, B]* p, A a, B b):
	p.first = a
	p.second = b
	return p


# A deferred statement in a generic body: replayed at both exits of every
# instantiation.
T counted[T](T value, int early):
	defer deferred_bump()
	if (early): return value
	T copy = value
	return copy


int with_defers(int x):
	defer deferred_bump()
	defer deferred_bump()
	if (x > 10): return x - 10
	return x


void test_struct_shapes():
	pair[int, char*] named
	named.first = 7
	named.second = c"seven"
	assert_equal(7, named.first)
	chain[int] tail
	tail.value = 2
	tail.next = 0
	chain[int] head
	head.value = 1
	head.next = &tail
	assert_equal(2, head.next.value)
	bag[int] storage
	bag[int]* b = &storage
	b.items = new list[int]
	b.items.push(4)
	b.items.push(5)
	b.index = new map[char*, int]
	b.index[c"x"] = 9
	b.count = 3
	b.tagged.first = 11
	b.tagged.second = 12
	assert_equal(2, b.items.length)
	assert_equal(9, b.index[c"x"])
	assert_equal(23, b.tagged.first + b.tagged.second)
	cells[int] c
	c.slots[2] = 6
	c.used = 1
	assert_equal(6, c.slots[2])
	rows[int] r
	r.values = new list[pair[int, int]]
	assert_equal(0, r.values.length)
	empty[int]* none = 0
	assert1(none == 0)
	assert_equal(5, bag_count(b, 2))
	assert_equal(3, bag_count[int](b, 0))
	list_free[int](b.items)


void test_functions():
	assert_equal(9, larger[int](4, 9))
	assert_equal(8, larger(8, 3))
	list[int] items = new list[int]
	assert_equal(-1, head_or(items, -1))
	items.push(42)
	assert_equal(42, head_or[int](items, 0))
	pair[int, char*] storage
	pair[int, char*]* p = fill_pair[int, char*](&storage, 3, c"three")
	assert_equal(3, p.first)
	assert_equal(12, helper_wrap_total(5, 7))
	list_free[int](items)


void test_defers():
	deferred_hits = 0
	assert_equal(5, with_defers(15))
	assert_equal(4, with_defers(4))
	assert_equal(4, deferred_hits)
	assert_equal(6, counted[int](6, 1))
	assert_equal(7, counted(7, 0))
	assert_equal(6, deferred_hits)
