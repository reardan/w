# it-expressions (docs/projects/golf_ergonomics.md, wave 5): a list
# method argument that mentions 'it' is evaluated inline for every
# element, with the enclosing function's locals in scope. The named
# function / fn pointer forms and the count(x)/index(x) value forms
# keep working next to them.
# wbuild: x64
import lib.testing


struct li_person:
	char* name
	int age


int li_double(int x):
	return x * 2


int li_is_odd(int x):
	return x % 2


list[li_person] li_people():
	list[li_person] people = new list[li_person]
	li_person p
	p.name = c"bob"
	p.age = 40
	people.push(p)
	p.name = c"al"
	p.age = 30
	people.push(p)
	p.name = c"cy"
	p.age = 35
	people.push(p)
	return people


void test_map_filter_with_locals():
	list[int] l = list[int]{5, 3, 8, 1, 4}
	int k = 10
	list[int] shifted = l.map(it + k)
	assert_equal(5, shifted.length)
	assert_equal(15, shifted[0])
	assert_equal(14, shifted[4])
	list[int] evens = l.filter(it % 2 == 0)
	assert_equal(2, evens.length)
	assert_equal(8, evens[0])
	assert_equal(4, evens[1])
	# the source is untouched
	assert_equal(5, l[0])


void test_map_changes_element_type():
	list[int] l = list[int]{1, 22, 333}
	list[string] labels = l.map(f"<{it}>")
	assert_equal(3, labels.length)
	assert_equal(5, len(labels[2]))
	list[bool] big = l.map(it > 10)
	assert_equal(0, big[0])
	assert_equal(1, big[1])


void test_predicates():
	list[int] l = list[int]{5, 3, 8, 1, 4}
	assert_equal(3, l.count(it > 3))
	assert_equal(1, l.any(it > 7))
	assert_equal(0, l.any(it > 8))
	assert_equal(1, l.all(it > 0))
	assert_equal(0, l.all(it > 1))
	assert_equal(2, l.index(it > 5))
	assert_equal(0 - 1, l.index(it > 100))


void test_aggregates():
	list[int] l = list[int]{5, 3, 8, 1, 4}
	assert_equal(115, l.sum(it * it))
	assert_equal(0 - 8, l.min(0 - it))
	assert_equal(3, l.max(it % 4))
	# min_by/max_by return the element with the first extreme key
	assert_equal(5, l.min_by(it % 5))
	assert_equal(4, l.max_by(it % 5))


void test_sort_by_key():
	list[int] l = list[int]{5, 3, 8, 1, 4}
	list[int] desc = l.sorted_by(0 - it)
	assert_equal(8, desc[0])
	assert_equal(1, desc[4])
	assert_equal(5, l[0])
	# stable: equal keys keep their order
	l.sort_by(it % 2)
	assert_equal(8, l[0])
	assert_equal(4, l[1])
	assert_equal(5, l[2])
	assert_equal(3, l[3])
	assert_equal(1, l[4])
	list[char*] words = list[char*]{c"pear", c"fig", c"apple"}
	list[char*] by_text = words.sorted_by(it)
	assert_equal(0, strcmp(c"apple", by_text[0]))
	list[char*] by_length = words.sorted_by(len(it))
	assert_equal(0, strcmp(c"fig", by_length[0]))
	assert_equal(0, strcmp(c"apple", by_length[2]))


void test_struct_elements_bind_pointers():
	list[li_person] people = li_people()
	people.sort_by(it.age)
	assert_equal(0, strcmp(c"al", people[0].name))
	assert_equal(0, strcmp(c"bob", people[2].name))
	list[char*] names = people.map(it.name)
	assert_equal(0, strcmp(c"cy", names[1]))
	assert_equal(40, people.max_by(it.age).age)
	assert_equal(0, strcmp(c"al", people.min_by(it.age).name))
	list[li_person] older = people.filter(it.age > 32)
	assert_equal(2, older.length)
	assert_equal(35, older[0].age)
	assert_equal(105, people.sum(it.age))


void test_nested_and_chained():
	list[int] l = list[int]{5, 3, 8, 1, 4}
	# an inner it-expression rebinds 'it' for its own argument
	list[int] plus = l.map(l.filter(it > 3).sum() + it)
	assert_equal(22, plus[0])
	assert_equal(18, plus[3])
	assert_equal(56, list[int]{1, 2, 3, 4, 5, 6}.filter(it % 2 == 0).map(it * it).sum())
	list[list[int]] grid = new list[list[int]]
	grid.push(list[int]{1, 2})
	grid.push(list[int]{3, 4, 5})
	list[int] sizes = grid.map(it.length)
	assert_equal(3, sizes[1])
	assert_equal(12, grid.map(it.sum()).max())


void test_empty_lists():
	list[int] e = new list[int]
	assert_equal(0, e.map(it * 3).length)
	assert_equal(0, e.filter(it > 0).length)
	assert_equal(0, e.count(it > 0))
	assert_equal(0, e.any(it > 0))
	assert_equal(1, e.all(it > 0))
	assert_equal(0, e.sum(it))


void test_old_forms_unchanged():
	list[int] l = list[int]{5, 3, 8, 3}
	list[int] doubled = l.map(li_double)
	assert_equal(10, doubled[0])
	assert_equal(3, l.filter(li_is_odd).length)
	assert_equal(2, l.count(3))
	assert_equal(1, l.index(3))
	assert_equal(19, l.sum())
	# a user variable named 'it' keeps the value forms
	int it = 8
	assert_equal(1, l.count(it))
	assert_equal(2, l.index(it))


void test_reversed():
	list[int] l = list[int]{1, 2, 3}
	list[int] r = l.reversed()
	assert_equal(3, r[0])
	assert_equal(1, r[2])
	assert_equal(1, l[0])
	list[int] e = new list[int]
	assert_equal(0, e.reversed().length)
