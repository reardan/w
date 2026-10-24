# Shared differential input for the production x64 backend and wllvm:
# records, pointers, globals and their initializers, fixed arrays, enums,
# function values, unsigned and narrow integers, strings and the lib.lib
# runtime it prints through. Output and exit status must match exactly.
import lib.lib

struct point:
	int x
	int y

struct node:
	int value
	node* next

enum shade:
	dark
	light = 5

type binary = fn(int, int) -> int

int counter = 7
int* counter_ref = &counter
char* banner = c"globals ok"
int[4] table
point origin
const int limit = 3
uint big = 10
char flag = -2

int add(int a, int b):
	return a + b

int mul(int a, int b):
	return a * b

binary chosen = mul
binary adding = add

int apply(binary f, int a, int b):
	return f(a, b)

void bump(int* p, int by):
	*p = *p + by

int sum_list(node* head):
	int total = 0
	while head != 0:
		total += head.value
		head = head.next
	return total

int strsum(char* s):
	int total = 0
	int i = 0
	while s[i] != 0:
		total = total + s[i]
		i++
	return total

int main():
	println(banner)
	bump(counter_ref, 5)
	print_int(c"counter ", counter)
	for i in range(4): table[i] = i * i
	int acc = 0
	for i in range(1, 4): acc += table[i]
	print_int(c"squares ", acc)
	for i in range(0, 10, 3): acc = acc + i
	print_int(c"stepped ", acc)
	point p
	p.x = 3
	p.y = 4
	point q = p
	q.y = 10
	origin = q
	print_int(c"point ", p.x * 100 + p.y * 10 + origin.y)
	node* a = new node()
	node* b = new node()
	a.value = 40
	a.next = b
	b.value = 2
	b.next = 0
	print_int(c"list ", sum_list(a))
	print_int(c"fn ", apply(adding, 2, 3) + apply(chosen, 4, 5))
	shade s = light
	print_int(c"enum ", s + dark)
	int[3] local
	local[2] = limit
	print_int(c"array ", local[0] + local[2])
	big = big / 3
	print_int(c"uint ", big)
	print_int(c"char ", flag)
	char* text = c"AB"
	print_int(c"bytes ", strsum(text))
	char c = cast(char, 300)
	print_int(c"cast ", c)
	int x = 5
	int* px = &x
	*px = *px * 2
	print_int(c"addr ", x)
	bool t = x > 3
	print_int(c"bool ", t)
	int choose = t ? 11 : 22
	print_int(c"cond ", choose)
	println("string literal")
	string first = "same"
	string second = "same"
	print_int(c"string equal ", first == second)
	println(itoa(-12345))
	print_int(c"rotl ", rotl(cast(int, 0x80000001), 4))
	int high = 0
	print_int(c"mul_wide ", mul_wide(0x10000, 0x30000, &high) + high)
	print_int(c"popcount ", popcount(255) + clz(1) + ctz(8))
	return counter
