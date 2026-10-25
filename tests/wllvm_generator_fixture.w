# Shared differential input for the production x64 backend and wllvm:
# generators (lib/generator.w stackful coroutines) driven by cursor loops
# and by gen_next/gen_value, with register and stack-passed arguments,
# early return and break out of generator loops, nested and chained
# generators, and a generator on a resized stack. Output and exit status
# must match exactly.
import lib.lib
import lib.generator


generator int count(int n, int step):
	int i = 0
	while (i < n):
		yield i * step
		i = i + 1
	if (n > 100): return
	yield 99


# More arguments than x86-64 passes in registers.
generator int weights(int a, int b, int c, int d, int e, int f, int g, int h):
	yield a
	yield b * 2 + c * 3
	yield d * 4 + e * 5 + f * 6
	yield g * 7 + h * 8


# A generator consuming another generator.
generator int doubled(int n):
	for x in count(n, 1): yield x * 2


generator char* words():
	yield c"alpha"
	yield c"beta"
	return


int deep(int n):
	if (n == 0): return 1
	return deep(n - 1) + 1


generator int recursive(int n):
	yield deep(n)
	yield deep(n * 2)


int first_over(int limit):
	for x in count(50, 3):
		if (x > limit): return x
	return -1


void check(char* label, int value):
	print(label)
	print(c" ")
	println(value)


int main():
	int total = 0
	for x in count(3, 2): total = total + x
	check(c"loop", total)
	generator* g = count(2, 5)
	int pulled = 0
	while (gen_next(g)): pulled = pulled * 10 + gen_value(g) % 10
	check(c"manual", pulled + gen_done(g) * 1000)
	gen_free(g)
	int partial = 0
	for y in count(10, 1):
		if (y == 4): break
		partial = partial + y
	check(c"break", partial)
	int weighted = 0
	for w in weights(1, 2, 3, 4, 5, 6, 7, 8): weighted = weighted * 100 + w
	check(c"stack arguments", weighted)
	int chained = 0
	for d in doubled(4): chained = chained * 10 + d
	check(c"chained", chained)
	int pairs = 0
	for a in count(3, 1):
		for b in count(2, 10): pairs = pairs + a * b
	check(c"nested", pairs)
	for word in words(): println(cast(char*, word))
	check(c"early return", first_over(20))
	generator* big = recursive(300)
	gen_set_stack_size(big, 262144)
	int depth = 0
	while (gen_next(big)): depth = depth + gen_value(big)
	gen_free(big)
	check(c"resized stack", depth)
	return (total + partial + chained) % 100
