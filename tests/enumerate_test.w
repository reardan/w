# Two-variable list iteration (issue #360): 'for i, x in l' binds the
# element index and the element — the list counterpart of the map
# key/value form — and 'for i, x in enumerate(l)' is explicit sugar for
# the same loop, claimed only when no user symbol shadows 'enumerate'
# (the prelude resolve rule, single-pass like any/all).
# wbuild: x64
import lib.assert


struct en_pair:
	int a
	int b


# Parsed before the user 'enumerate' below exists, so the sugar applies
int sugar_checks():
	l := list[int]{7, 8, 9}
	indexes := 0
	weighted := 0
	for i, x in enumerate(l):
		indexes += i
		weighted += i * x
	assert_equal(3, indexes)
	assert_equal(8 + 18, weighted)

	# Typed loop variables work through the same path
	total := 0
	for int i, int x in enumerate(l):
		total += x
	assert_equal(24, total)
	return 1


# A user 'enumerate' shadows the sugar at every later call site
list[int] enumerate(list[int] l):
	doubled := new list[int]
	for x in l:
		doubled.push(x * 2)
	return doubled


int main():
	assert_equal(1, sugar_checks())

	# Bare two-variable list iteration: index and element
	l := list[int]{5, 6, 7}
	indexes := 0
	values := 0
	for i, x in l:
		indexes += i
		values += x
	assert_equal(3, indexes)
	assert_equal(18, values)

	# Typed form
	sum := 0
	for int i, int x in l:
		sum += (i + 1) * x
	assert_equal(5 + 12 + 21, sum)

	# Empty list: zero passes
	list[int] empty = new list[int]
	passes := 0
	for i, x in empty:
		passes += 1
	assert_equal(0, passes)

	# Same-line body, and sequential loops each declare their own i/x
	acc := 0
	for i, x in l: acc += i * x
	assert_equal(6 + 14, acc)

	# break and continue behave like the one-variable form
	stopped := 0
	for i, x in l:
		if x == 6:
			continue
		if i == 2:
			break
		stopped += x
	assert_equal(5, stopped)

	# Sub-word elements load at their own width; the index stays int
	chars := list[char]{'a', 'b'}
	codes := 0
	for i, c in chars:
		codes += i + c
	assert_equal('a' + 'b' + 1, codes)

	# Struct elements bind the second variable to the element address,
	# matching the one-variable 'for en_pair* p in l' rule
	list[en_pair] pairs = new list[en_pair]
	en_pair p
	p.a = 1
	p.b = 2
	pairs.push(p)
	p.a = 3
	p.b = 4
	pairs.push(p)
	weighted := 0
	for i, en_pair* q in pairs:
		weighted += (i + 1) * (q.a + q.b)
	assert_equal(3 + 14, weighted)

	# Inferred second variable over struct elements is the pointer too
	fields := 0
	for i, q in pairs:
		fields += q.a
	assert_equal(4, fields)

	# The user 'enumerate' defined above wins here: plain one-variable
	# iteration over the list it returns
	base := list[int]{1, 2}
	doubled_sum := 0
	for x in enumerate(base):
		doubled_sum += x
	assert_equal(6, doubled_sum)

	println(c"enumerate_test passed")
	return 0
