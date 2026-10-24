# Debuggee for tests/safe_session_debugger_test.w: checked views of outer
# frames suspended in a call, optional owners and references, and inline
# slices at 'debugger' stops (#713).
struct box:
	int value


struct Holder:
	ref[field] box* item
	int tag


void bump(refmut box* b):
	b.value = b.value + 1
	debugger


int peek(ref box* b, int i):
	debugger
	return b.value + i


int present(optref box* m):
	if (m): return m.value
	return 0


int maybe(optref box* m):
	debugger
	return present(m)


int slice_sum(ref int[] s):
	debugger
	int sum = 0
	for i in range(s.length): sum = sum + s[i]
	return sum


int main():
	own box* p = new box
	p.value = 10
	own box* q = new box
	q.value = 20
	ref box* r = q
	optown box* none = 0
	optown box* some = new box
	if (some): some.value = 30
	int[3] data
	data[0] = 1
	data[1] = 2
	data[2] = 3
	ref int[] all = data
	int[2] more
	more[0] = 7
	more[1] = 8
	refmut int[] tail = more
	ref[a] Holder h = Holder(r, 5)
	bump(p)
	refmut box* w = p
	bump(w)
	int a = peek(r, h.tag)
	optref box* look = p
	int b = maybe(look)
	int c = slice_sum(tail)
	int d = all[0] + present(some) + present(none)
	return a + b + c + d - 25 - 12 - 15 - 31
