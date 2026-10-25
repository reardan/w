# Differential fixture for bin/wllvm: generic functions, generic structs
# and checked pointers. tests/wllvm_test.w builds it with W's x64 backend
# and with wllvm and compares exit status and output.
import lib.lib
import lib.memory_debug
import lib.safe_buffer


T smaller[T](T a, T b):
	if (a < b):
		return a
	return b


T largest[T](T a, T b):
	if (a > b):
		return a
	return b


T largest3[T](T a, T b, T c):
	return largest[T](largest[T](a, b), c)


K pick_first[K, V](K key, V value):
	return key


struct pair[T]:
	T first
	T second


T pair_sum[T](pair[T]* p):
	return p.first + p.second


struct pstore[T]:
	int length
	T* items


int pstore_first_chars[T](pstore[T]* s):
	int sum = 0
	for i in range(s.length):
		T element = s.items[i]
		sum = sum + element[0]
	return sum


void swap[T](T* a, T* b):
	T tmp = *a
	*a = *b
	*b = tmp


T first_of[T](T* p):
	return *p


T rec_sum[T](T a, T depth):
	if (depth <= 0):
		return a
	return rec_sum(a, depth - 1) + a


T scaled[T](T a, int factor):
	return a * factor


struct infer_two[K, V]:
	K key
	V value


V infer_two_value[K, V](infer_two[K, V]* two, K key):
	if (two.key == key): return two.value
	return two.value


# A generic method: the receiver binds T.
T pair_max[T](pair[T]* self):
	return largest(self.first, self.second)


int inferred():
	int x = 7
	int y = 42
	int* px = &x
	int* py = &y
	swap(px, py)
	if ((x != 42) || (y != 7)): return -1
	int total = first_of(py) + rec_sum(5, 2) + scaled(6, 7) + largest(largest(9, 2), largest(4, 8))
	char* s = c"hi"
	total = total + first_of(s) - 'h'
	infer_two[int, char*] two
	two.key = 3
	two.value = c"x"
	infer_two[int, char*]* pairing = &two
	total = total + infer_two_value(pairing, 3)[0] - 'x'
	pair[int16] wide
	wide.first = cast(int16, -300)
	wide.second = cast(int16, 200)
	total = total + wide.pair_max()
	return total


int generics():
	int total = smaller[int](12, 7) + largest[int](3, 5) + largest3[int](4, 9, 2)
	char z = largest[char]('a', 'z')
	total = total + z - 'z'
	total = total + pick_first[int, char*](11, c"ignored")
	if (strcmp(pick_first[char*, int](c"hello", 42), c"hello") != 0): return -1
	pair[int] p
	p.first = 20
	p.second = 22
	pair[int]* pp = &p
	total = total + pair_sum[int](pp)
	pair[uint8] small
	small.first = cast(uint8, 250)
	small.second = cast(uint8, 10)
	total = total + pair_sum[uint8](&small)
	pstore[char*] s
	s.length = 2
	s.items = cast(char**, malloc(2 * __word_size__))
	s.items[0] = c"apple"
	s.items[1] = c"banana"
	total = total + pstore_first_chars[char*](&s) - 'a' - 'b'
	return total


# Checked owners: moves clear their source, and every owner still in scope
# is freed at block ends, jumps and returns (leaks are counted below).
struct owned_leaf:
	own int* value
	int tag


struct owned_node:
	own int* value
	own owned_leaf* next
	int tag


own int* make_owned(int value):
	own int* p = new int
	*p = value
	return p


int consume_owned(own int* p):
	return *p


own owned_node* chain(int depth):
	own owned_node* head = new owned_node(make_owned(depth), new owned_leaf(make_owned(depth - 1), depth - 1), depth)
	if (depth > 2): head.next = new owned_leaf(make_owned(depth * 2), depth * 2)
	return head


int owners(int n):
	own int* kept = make_owned(10)
	int sum = 0
	while (n > 0):
		own int* step = make_owned(n)
		n = n - 1
		if (n == 3): continue
		if (n == 1): break
		sum = sum + consume_owned(step)
	own owned_node* list = chain(4)
	list.value = make_owned(100)
	moved := list
	sum = sum + *moved.value + moved.next.tag
	own WIntBuffer* buffer = int_buffer_new()
	for i in range(50): int_buffer_push(buffer, i)
	sum = sum + int_buffer_get(buffer, 49)
	int[3] storage
	storage[2] = 5
	ref int[] view = storage
	sum = sum + view.length + view[2]
	kept = make_owned(sum)
	return consume_owned(kept)


int main():
	int g = generics()
	print(c"generics ")
	println(itoa(g))
	int i = inferred()
	print(c"inferred ")
	println(itoa(i))
	unsafe:
		malloc_force_debug_mode()
	int before = debug_alloc_report_leaks()
	int o = owners(6) + owners(0)
	int leaks = debug_alloc_report_leaks() - before
	print(c"owners ")
	println(itoa(o))
	print(c"leaks ")
	println(itoa(leaks))
	return (g + i + o + leaks) & 255
