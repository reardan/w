# Debuggee exercising the built-in containers under wdbg: the
# in-process debug compile must preload the container runtime exactly
# like the normal driver does, or the first 'new list[T]' loses symbol
# resolution (docs/projects/ai_tooling_next_steps.md wdbg entries).
import lib.lib
import tests.debug_fixture4_import


int main(int argc, int argv):
	list[int] items = new list[int]
	items.push(40)
	items.push(2)
	int total = items[0] + items[1]
	map[char*, int] ages = new map[char*, int]
	ages[c"answer"] = total
	list[df4_bag] pool = new list[df4_bag]
	df4_bag* bag = df4_bag_new()
	df4_bag_add(bag, ages[c"answer"])
	df4_bag_add(bag, -1)
	debugger
	int result = bag.values[0] + bag.values.length + pool.length
	println(c"containers ok")
	return result
