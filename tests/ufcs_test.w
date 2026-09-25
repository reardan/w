# Uniform call syntax (golf ergonomics wave 5): x.f(args) calls the
# free function f(x, args) where nothing else claims the member. Struct
# fields, T_f methods and the built-in container methods still win.
# wbuild: x64
import lib.testing
import lib.str


struct uf_point:
	int x
	int y


int uf_point_norm1(uf_point* p):
	return p.x + p.y


# A free function with the same name as a method: the method wins
int norm1(uf_point* p):
	return 0 - 1


int uf_scaled(uf_point* p, int k):
	return (p.x + p.y) * k


int uf_twice(int v):
	return v * 2


int uf_add(int a, int b):
	return a + b


int uf_total(list[int] l):
	return l.sum()


int uf_size(map[char*, int] m):
	return m.length


int uf_bytes(string s):
	return len(s)


# 'sum' is a built-in list method: a free function never shadows it
int sum(list[int] l):
	return 0 - 1


void test_struct_receivers():
	uf_point p
	p.x = 3
	p.y = 4
	assert_equal(7, p.norm1())
	assert_equal(14, p.uf_scaled(2))
	uf_point* q = &p
	assert_equal(21, q.uf_scaled(3))


void test_scalar_receivers_chain():
	int v = 21
	assert_equal(42, v.uf_twice())
	assert_equal(43, v.uf_twice().uf_add(1))
	assert_equal(10, (5).uf_twice())


void test_container_receivers():
	list[int] l = list[int]{1, 2, 3}
	assert_equal(6, l.uf_total())
	assert_equal(12, l.map(it * 2).uf_total())
	assert_equal(6, l.sum())
	map[char*, int] m = new map[char*, int]
	m[c"a"] = 1
	assert_equal(1, m.uf_size())


void test_string_receivers():
	char* csv = c"a,b,c"
	assert_equal(3, csv.split(',').length)
	assert_equal(3, c"x y  z".split().length)
	assert_strings_equal(c"q-r", c"q r".split().join(c"-"))
	string s = "abc"
	assert_equal(3, s.uf_bytes())
