# Shared differential input for the production x64 backend and wllvm:
# switch, legacy and scoped defer, goto, and records passed, returned and
# copied by value, including records that hold fixed arrays. Output and
# exit status must match exactly.
import lib.lib

struct pair:
	int a
	int b

struct holder:
	int[3] items
	int tag

struct nest:
	pair first
	holder inner

holder shared
int trace


void mark(int digit):
	trace = trace * 10 + digit


int classify(int x):
	switch (x):
		case 1: return 10
		case 2, 3: return 20
		case -4: return 40
		default: return 99
	return 0


int name_code(char* name):
	switch (name):
		case "red": return 1
		case c"green": return 2
	return 0


int text_code(string name):
	switch (name):
		case "red": return 1
		case "blue", "navy": return 3
		default: return 9
	return 0


int switch_loops():
	int total = 0
	for i in range(6):
		switch (i % 3):
			case 0: continue
			case 1:
				total = total + 100
				break
				total = total + 1000
			default: total = total + 1
	return total


int deferred(int n):
	defer mark(1)
	if (n == 1):
		mark(5)
		return 7
	defer mark(2)
	if (n == 2): return 8
	mark(3)
	return 9


void deferred_void():
	defer mark(4)
	mark(6)


int scoped():
	int counter = 0
	for i in range(4):
		defer: counter = counter + 1
		if (i == 1): continue
		if (i == 3): break
		counter = counter + 10
	return counter


int find_pair(int target):
	int result = -1
	for i in range(10):
		for j in range(10):
			if (i * 3 + j * 7 == target):
				result = i * 100 + j
				goto found
	found:
	return result


int count_to(int n):
	int i = 0
	again:
	if (i < n):
		i = i + 1
		goto again
	return i


pair make_pair(int x):
	defer mark(8)
	pair p
	p.a = x
	p.b = x + 1
	return p


int pair_sum(pair p):
	# a by-value parameter is the callee's own copy
	p.a = p.a + 100
	return p.a + p.b


holder make_holder(int seed):
	holder h
	for i in range(3): h.items[i] = seed + i
	h.tag = seed
	return h


int header_offset(holder* h):
	int* raw = cast(int*, h)
	return raw[0] - cast(int, h)


int total(int[] values):
	int sum = 0
	for i in range(len(values)): sum = sum + values[i]
	return sum


int holder_sum(holder h):
	h.items[0] = 1000
	return total(h.items) + h.tag


int main():
	println(classify(1))
	println(classify(3))
	println(classify(-4))
	println(classify(7))
	println(name_code(c"red") * 10 + name_code(c"green"))
	println(text_code("red") * 100 + text_code("navy") * 10 + text_code("x"))
	println(switch_loops())
	trace = 0
	println(deferred(1) * 1000 + trace)
	trace = 0
	println(deferred(2) * 1000 + trace)
	trace = 0
	println(deferred(3) * 1000 + trace)
	trace = 0
	deferred_void()
	println(trace)
	println(scoped())
	println(find_pair(23))
	println(find_pair(1000))
	println(count_to(5))
	trace = 0
	pair q = make_pair(3)
	println(q.a * 10 + q.b + trace * 100)
	println(pair_sum(q) * 10 + q.a)
	q = make_pair(10)
	println(make_pair(20).b + q.b)
	pair literal = pair(a: 4, b: 5)
	pair positional = pair(6, 7)
	println(literal.a * 1000 + literal.b * 100 + positional.a * 10 + positional.b)
	holder h = make_holder(5)
	holder g = h
	g.items[1] = 50
	println(header_offset(&h) + header_offset(&g) + header_offset(&shared))
	println(h.items[1] * 100 + g.items[1] + len(g.items))
	println(holder_sum(h) * 10 + h.items[0])
	holder* heap = new holder
	heap.items[2] = 9
	println(header_offset(heap) + total(heap.items))
	nest n
	n.inner = make_holder(2)
	n.first = make_pair(1)
	println(header_offset(&n.inner) + total(n.inner.items) * 10 + n.first.b)
	shared.items[0] = 3
	println(total(shared.items))
	return classify(2) + count_to(3)
