# Imported module for debug_fixture4.w, mirroring the shapes that used
# to break wdbg's in-process compile: a struct holding a built-in
# container, 'new list[T]' mid-function and bare 'return' statements in
# an imported file (docs/projects/ai_tooling_next_steps.md).
import lib.lib


struct df4_bag:
	list[int] values


df4_bag* df4_bag_new():
	df4_bag* bag = new df4_bag()
	bag.values = new list[int]
	return bag


void df4_bag_add(df4_bag* bag, int value):
	if (value < 0):
		return
	bag.values.push(value)
	return
