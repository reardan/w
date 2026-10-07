# S2.2d: local declarations, goto/labels, raw_asm and defer statements
# parsed completely, then emitted by the retained walk
# (--ast-emit-retained). Compiled in both modes by ast_retained_emit_test,
# which requires identical images and diagnostics: the initialization
# warnings below come from the walk's initializer phase, the slots from its
# bind phase, and the ';'-terminated declarations end before the
# dispatcher's terminator. A 'for' header declaration stays with its loop.

int decl_trace

void decl_mark(int n):
	decl_trace = decl_trace * 10 + n

struct decl_pair:
	int first
	int second

struct decl_holder:
	int count
	int[3] items

decl_pair decl_make(int n):
	defer decl_mark(1)
	return decl_pair(n, n + 1)

# Narrowing and pointer/int initializations warn from the walk.
int decl_warnings(int n):
	char c = n
	char* text = n; int after = 2
	byte small = 300
	return c + after + small

int decl_locals(int n):
	int plain
	int[4] numbers
	decl_holder holder
	decl_pair pair = decl_make(n)
	decl_pair copy = pair
	inferred := pair.first + pair.second
	second := copy
	ratio := 1.5
	plain = inferred + second.second; numbers[2] = plain
	holder.items[1] = numbers[2]
	if (n > 0): int nested = n * 2
	if (n > 1):
		int nested = n * 3; plain = plain + nested
	for int i in range(3): plain = plain + i
	for k in range(2):
		int inner = k
		plain = plain + inner
	return holder.items[1] + plain + cast(int, ratio)

# Forward gotos over declarations and backward gotos out of a block.
int decl_jumps(int n):
	int total = 0
	again:
	if (total < n):
		int step = 2
		total = total + step
		goto again
	goto skip;
	int unused = 7
	total = total + unused
	skip:
	int after = total
	if (after > 100): goto done
	after = after + 1
	done:
	return after

void decl_cleanup():
	defer decl_mark(2)
	defer decl_mark(3);
	decl_mark(4)

void decl_raw(int n):
	if (n == 12345): raw_asm(c"\x90\x90")
	raw_asm("")
	if (n == 54321): raw_asm(c"\x90"); raw_asm("\x90")

int main():
	decl_pair pair = decl_make(20)
	if (pair.first + pair.second != 41): return 1
	decl_warnings(3)
	decl_locals(4)
	if (decl_jumps(5) != 7): return 2
	decl_cleanup()
	decl_raw(0)
	if (decl_trace == 0): return 3
	return 0
