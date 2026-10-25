# Shared differential input for the production x64 backend and wllvm:
# the built-in list, map and set containers (new, literals, indexing,
# methods, membership, slices, defaults and cursor for loops) over word,
# narrow, string, char* and record elements. Output and exit status must
# match exactly.
import lib.lib
import lib.utf8

struct pair:
	int a
	int b


# A user cursor protocol: for v in counter*
struct counter:
	int limit


int counter_iter_begin(counter* c):
	return 0


int counter_iter_done(counter* c, int cursor):
	return cursor >= c.limit


int counter_iter_next(counter* c, int cursor):
	return cursor + 1


int counter_iter_value(counter* c, int cursor):
	return cursor * 10


list[int] squares


int twice(int x):
	return x * 2


int odd(int x):
	return x & 1


int by_desc(int a, int b):
	return b - a


int add(int acc, int x):
	return acc + x


int fresh():
	return 40


void check(char* label, int value):
	print(label)
	print(c" ")
	println(value)


int main():
	list[int] xs = new list[int]
	for i in range(6): xs.push(i * 3)
	xs[1] = 100
	xs[2] += 5
	check(c"index", xs[1] + xs[2] + xs.length)
	int total = 0
	for x in xs: total = total + x
	check(c"for list", total)
	for i, x in xs:
		if (i == 4): break
		total = total + i * x
	check(c"for index", total)
	xs.insert(0, 7)
	xs.remove(1)
	check(c"pop", xs.pop() + xs.length)
	check(c"contains", (100 in xs) + (5 in xs))
	list[int] part = xs[1:3]
	check(c"slice", part[0] + part[1] + part.length)
	xs.sort()
	check(c"sort", xs[0] * 1000 + xs[xs.length - 1])
	list[int] mapped = xs.map(twice)
	list[int] kept = xs.filter(odd)
	check(c"map filter", mapped.sum() + kept.length)
	check(c"reduce", xs.reduce(add, 1))
	xs.sort_by(by_desc)
	check(c"sort_by", xs[0] + xs.index(7) + xs.count(7))
	check(c"min max", xs.min() * 1000 + xs.max())
	xs.reverse()
	list[int] back = xs.reversed()
	check(c"reverse", xs[0] + back[0])
	list[int] doubled = xs.map(it * 2)
	list[int] big = xs.filter(it > 50)
	check(c"it map filter", doubled.sum() + big.length)
	check(c"it count", xs.count(it % 2 == 0) * 100 + xs.any(it > 100) * 10 + xs.all(it >= 0))
	check(c"it sum", xs.sum(it + 1) + xs.min_by(0 - it) + xs.max_by(0 - it))
	xs.sort_by(0 - it)
	check(c"it sort", xs[0])
	list[pair] ordered = new list[pair]
	for i in range(4):
		pair entry
		entry.a = (i * 7) % 4
		entry.b = i
		ordered.push(entry)
	list[pair] by_a = ordered.sorted_by(it.a)
	check(c"it records", by_a[0].b * 10 + by_a[3].b + ordered.index(it.b == 2))
	println(xs)
	check(c"len", len(xs) + len(c"four") + any(xs) * 10 + all(list[int]{1, 0}) * 100)
	list[char*] words = split(c"a,bb,ccc", ',')
	println(words)
	println(join(words, c"+"))
	xs.clear()
	check(c"clear", xs.length)

	list[char*] names = list[char*]{c"ada", c"bob", c"cy"}
	int letters = 0
	for name in names: letters = letters + strlen(name)
	check(c"names", letters + (c"bob" in names))
	list[char] small = new list[char]
	small.push(cast(char, -3))
	small.push(cast(char, 120))
	check(c"narrow", small[0] + small[1])
	list[pair] pairs = new list[pair]
	pair p
	p.a = 3
	p.b = 4
	pairs.push(p)
	p.a = 10
	pairs.push(p)
	pairs[0].b = 9
	int sum = 0
	for pair* q in pairs: sum = sum + q.a * q.b
	for i, pair* r in pairs: sum = sum + i * r.a
	for i, s in pairs: sum = sum + i * s.b
	check(c"records", sum)

	int[4] fixed
	fixed[1] = 5
	fixed[3] = 7
	int walked = 0
	for x in fixed: walked = walked * 3 + x
	string text = "h\xc3\xa9llo"
	for ch in text: walked = walked + ch
	counter c
	c.limit = 3
	counter* counted = &c
	for v in counted: walked = walked + v
	check(c"sequences", walked)

	map[int, int] counts = new map[int, int]
	for x in list[int]{1, 2, 2, 3, 3, 3}: counts.add(x)
	counts[10] = 5
	counts[10] += 2
	check(c"map", counts[3] * 100 + counts[10] + counts.length)
	check(c"map in", (2 in counts) + (9 in counts) * 10)
	check(c"map get", counts.get(9, -1) + counts.get(1))
	counts.remove(1)
	int keyed = 0
	for k, v in counts: keyed = keyed + k * v
	check(c"map for", keyed)
	list[int] keys = counts.keys()
	list[int] values = counts.values()
	check(c"keys values", keys.length + values.sum())

	map[string, int] ages = map[string, int]{"ada": 36, "bob": 41}
	ages["cy"] = 7
	string who = "bob"
	check(c"string keys", ages[who] + ages["cy"] + ("ada" in ages))
	map[char*, int] by_cstr = new map[char*, int]
	by_cstr[c"x"] = 2
	check(c"cstr keys", by_cstr[c"x"])

	map[int, int] defaulted = new map[int, int](-1)
	map[int, int] made = new map[int, int](fresh)
	check(c"defaults", defaulted[4] + made[5] + defaulted.length)
	map[int, list[int]] groups = new map[int, list[int]]()
	groups[1].push(5)
	groups[1].push(6)
	groups[2].push(7)
	check(c"nested", groups[1].length * 10 + groups[2][0])
	map[int, pair] records = new map[int, pair]
	records[1] = p
	records[1].b = 2
	check(c"map records", records[1].a + records[1].b)

	set[int] seen = new set[int]
	for x in list[int]{4, 4, 5, 9}: seen.add(x)
	int set_total = 0
	for k in seen: set_total = set_total + k
	seen.remove(9)
	check(c"set", set_total * 10 + seen.length + (5 in seen))
	set[char*] tags = set[char*]{c"a", c"b"}
	check(c"set literal", tags.length + (c"a" in tags))

	squares = new list[int]
	for i in range(4): squares.push(i * i)
	check(c"global", squares[3])
	names.free()
	counts.free()
	seen.free()
	return squares.length + 10
