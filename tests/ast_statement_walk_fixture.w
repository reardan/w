# S2.2a: simple, expression and return/yield statements parsed completely,
# then emitted by the retained walk (--ast-emit-retained). Compiled in both
# modes by ast_retained_emit_test, which requires identical images and
# diagnostics: the warnings below are emitted by the walk's value step,
# before or after the next token's lexing exactly as during the parse, and
# the ';'-terminated statements make the walk emit before the terminator.
import lib.generator

int walk_trace

void walk_mark(int n):
	walk_trace = walk_trace * 10 + n

struct walk_pair:
	int first
	int second

walk_pair walk_make_pair(int n):
	defer walk_mark(1)
	return walk_pair(n, n + 1)

# A return type mismatch, then the same with an explicit terminator.
char* walk_mismatch(int n):
	walk_mark(2)
	return n

char* walk_mismatch_terminated(int n):
	walk_mark(3); return n;

void walk_void_value(int n):
	walk_mark(n); return n

generator int walk_values(int limit):
	for i in range(limit):
		if (i == 3): return
		yield i + 10; walk_mark(4)

T walk_identity[T](T value):
	walk_mark(5)
	return value

int walk_loops():
	int total = 0
	int i = 0
	while (i < 9):
		i = i + 1; if (i == 2): continue
		switch i:
			case 4: break
			case 6:
				total = total + 100; break
			default: total = total + i
		if (i == 8): break; pass
	return total;

int main():
	walk_pair pair = walk_make_pair(20)
	if (pair.first + pair.second != 41): return 1
	walk_mismatch(1); walk_mismatch_terminated(2)
	walk_void_value(7)
	int sum = 0
	for value in walk_values(5): sum = sum + value
	if (sum != 33): return 2
	if (walk_identity[int](6) != 6): return 3
	if (walk_loops() != 124): return 4
	if (walk_trace == 0): return 5
	pass;
	if (0): debugger;
	return 0
