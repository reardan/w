# A ternary whose struct-valued arms leave different numbers of words on
# the stack: a struct-returning call parks its return buffer there, a
# plain struct lvalue does not. Both paths must reach the join at the
# same stack depth, and the else arm must not be compiled as if the then
# arm's words were pushed, or locals read after (or inside) the
# ternary come from the wrong slots.
# wbuild: x64
import lib.assert


struct ct_pair:
	int lo
	int hi


struct ct_wide:
	int a
	int b
	int c
	int d


ct_pair ct_make(int v):
	ct_pair r
	r.lo = v
	r.hi = v * 2
	return r


ct_pair ct_same(ct_pair p):
	return p


ct_wide ct_widen(int v):
	ct_wide w
	w.a = v
	w.b = v + 1
	w.c = v + 2
	w.d = v + 3
	return w


ct_pair ct_pick_return(int c, ct_pair a, int v):
	return c ? a : ct_make(v)


ct_pair ct_pick_local(int c, ct_pair a, int v):
	int before = 77
	ct_pair t = c ? a : ct_make(v)
	assert_equal(77, before)
	return t


ct_pair ct_pick_then_call(int c, ct_pair a, int v):
	int before = 55
	ct_pair t = c ? ct_make(v) : a
	assert_equal(55, before)
	return t


ct_pair ct_pick_both(int c, ct_pair a, int v):
	int keep = v
	ct_pair t = c ? ct_same(a) : ct_make(keep)
	assert_equal(v, keep)
	return t


int ct_sum(ct_pair p, int extra):
	return p.lo + p.hi + extra


ct_wide ct_pick_wide(int c, ct_wide w, int v):
	return c ? w : ct_widen(v)


int main():
	ct_pair x = ct_make(5)
	int guard = 1234
	for c in range(2):
		ct_pair r = ct_pick_return(c, x, 9)
		ct_pair l = ct_pick_local(c, x, 9)
		ct_pair t = ct_pick_then_call(c, x, 9)
		ct_pair b = ct_pick_both(c, x, 9)
		if (c):
			assert_equal(5, r.lo)
			assert_equal(5, l.lo)
			assert_equal(9, t.lo)
			assert_equal(5, b.lo)
		else:
			assert_equal(9, r.lo)
			assert_equal(18, l.hi)
			assert_equal(5, t.lo)
			assert_equal(9, b.lo)
		# as a call argument, followed by another argument
		assert_equal(ct_sum(c ? x : ct_make(9), 1), 1 + (c ? 15 : 27))
		# nested: the inner ternary's arms differ too
		ct_pair n = c ? (c ? x : ct_make(1)) : ct_make(2)
		assert_equal(c ? 5 : 2, n.lo)
		ct_wide w = ct_widen(40)
		ct_wide p = ct_pick_wide(c, w, 70)
		assert_equal(c ? 43 : 73, p.d)
	# many iterations: an unbalanced join would walk the stack
	int total = 0
	for i in range(1000):
		ct_pair q = (i & 1) ? x : ct_make(i)
		total = total + q.lo
	assert_equal(1234, guard)
	assert_equal(500 * 5 + 249500, total)
	return 0
