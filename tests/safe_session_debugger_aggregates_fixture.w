# Debuggee for tests/safe_session_debugger_test.w: read-only checked views
# of borrowed records, owners carrying borrowed groups and lifetime-labeled
# locals at 'debugger' stops, and the aggregate forms that stay hidden
# (#713).
struct box:
	int value


struct Holder:
	ref[field] box* item
	int tag


struct Pair:
	ref[left] box* first
	ref[right] box* second


struct Exclusive:
	refmut[field] box* item
	int amount


struct Stored:
	own box* scratch
	ref[item] box* item


own[a] Stored* store(ref[a] box* item):
	own box* scratch = new box
	scratch.value = 100
	return new Stored(scratch, item)


int holder_sum(ref Holder h):
	ref box* item = h.item
	return item.value + h.tag


int pair_sum(ref[a,b] Pair p):
	ref box* first = p.first
	ref box* second = p.second
	return first.value + second.value


int stored_sum(ref Stored* s):
	ref box* item = s.item
	ref box* scratch = s.scratch
	return item.value + scratch.value


int add(refmut Exclusive e):
	int amount = e.amount
	refmut box* item = e.item
	item.value = item.value + amount
	return item.value


int look(ref Holder h):
	debugger
	return h.tag


int main():
	own box* p = new box
	p.value = 10
	own box* q = new box
	q.value = 20
	ref[x] box* r = q
	ref[y] Holder h = Holder(p, 3)
	ref[s,t] Pair pair = Pair(p, q)
	own[z] Stored* stored = store(q)
	own box* other = new box
	other.value = 1
	refmut[w] Exclusive e = Exclusive(other, 4)
	debugger
	int a = holder_sum(h) + pair_sum(pair) + stored_sum(stored) + r.value
	int b = add(e)
	# h, pair and stored are past their last use here, and p is mutated.
	p.value = 11
	debugger
	int c = look(Holder(q, 6))
	return a + b + c - 13 - 30 - 120 - 20 - 5 - 6
