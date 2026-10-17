# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int owned_aggregate_case_number


void owned_aggregate_result(process_result* result, char* diagnostic, int checking, char* path):
	assert1(result != 0)
	char* message = result.stderr_text
	if (checking): message = result.stdout_text
	if (diagnostic == 0):
		if (result.status):
			print(path)
			print(message)
		assert_equal(0, result.status)
	else:
		if ((result.status != 1) || (assert_has(message, diagnostic) == 0)):
			print(path)
			print(message)
		assert_equal(1, result.status)
		assert_contains(message, diagnostic)


void owned_aggregate_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1):
	owned_aggregate_case_number = owned_aggregate_case_number + 1
	char* number = itoa(owned_aggregate_case_number)
	char* prefix = c"bin/owned_aggregate_case32_"
	if (__word_size__ == 8): prefix = c"bin/owned_aggregate_case64_"
	char* path = strjoin(prefix, number)
	free(number)
	if (seed >= 0):
		char* seed_number = itoa(seed)
		char* tagged = strjoin(path, c"_seed_")
		free(path)
		path = strjoin(tagged, seed_number)
		free(tagged)
		free(seed_number)
	char* full = strjoin(path, c".w")
	free(path)
	char* output = strjoin(full, c".out")
	assert1(file_write_text(full, source))
	for mode in range(2):
		unlink(output)
		char** checking = strv_new(7 + mode)
		strv_set(checking, 0, c"bin/wv2")
		strv_set(checking, 1, c"check")
		strv_set(checking, 2, c"--json")
		strv_set(checking, 3, c"--quiet")
		strv_set(checking, 4, c"--strict")
		if (relaxed): strv_set(checking, 4, c"--quiet")
		strv_set(checking, 5, c"--quiet")
		if (__word_size__ == 8): strv_set(checking, 5, c"x64")
		strv_set(checking, 6, full)
		if (mode): strv_set(checking, 7, c"--safe")
		process_result* checked = process_run(checking[0], checking, 0, 0, 30000)
		owned_aggregate_result(checked, diagnostic, 1, full)
		process_result_free(checked)
		free(cast(void*, checking))
		char** compiling = strv_new(8 + mode)
		strv_set(compiling, 0, c"bin/wv2")
		strv_set(compiling, 1, c"--quiet")
		strv_set(compiling, 2, c"--strict")
		if (relaxed): strv_set(compiling, 2, c"--quiet")
		strv_set(compiling, 3, c"--quiet")
		if (__word_size__ == 8): strv_set(compiling, 3, c"x64")
		strv_set(compiling, 4, c"--inline")
		strv_set(compiling, 5, full)
		strv_set(compiling, 6, c"-o")
		strv_set(compiling, 7, output)
		if (mode): strv_set(compiling, 8, c"--safe")
		process_result* compiled = process_run(compiling[0], compiling, 0, 0, 30000)
		owned_aggregate_result(compiled, diagnostic, 0, full)
		process_result_free(compiled)
		free(cast(void*, compiling))
		if (diagnostic):
			assert1(open(output, 0, 0) < 0)
		else:
			char** run = strv_new(1)
			strv_set(run, 0, output)
			process_result* executed = process_run(output, run, 0, 0, 30000)
			assert1(executed != 0)
			assert_equal(0, executed.status)
			process_result_free(executed)
			free(cast(void*, run))
		unlink(output)
	unlink(full)
	free(output)
	free(full)


void test_owned_aggregate_values():
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nint main():\n\town int* item = new int\n\t*item = 7\n\town OwnerBox* b = new OwnerBox(item, 3)\n\tref int* r = b.item\n\treturn *r + b.tag - 10\n", 0)
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nint main():\n\town OwnerBox* b = new OwnerBox(new int, 3)\n\trefmut int* r = b.item\n\t*r = 7\n\treturn b.tag - 3\n", 0)
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nint main():\n\town int* item = new int\n\t*item = 7\n\town OwnerBox* b = new OwnerBox(tag: 3, item: item)\n\tref int* r = b.item\n\treturn *r + b.tag - 10\n", 0)
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nown OwnerBox* make(int value):\n\town int* item = new int\n\t*item = value\n\treturn new OwnerBox(item, 3)\nint main():\n\town OwnerBox* b = make(7)\n\tref int* r = b.item\n\treturn *r + b.tag - 10\n", 0)
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nown OwnerBox* make(int value):\n\town int* item = new int\n\t*item = value\n\treturn new OwnerBox(item, 3)\nown OwnerBox* relay(own OwnerBox* b):\n\treturn b\nint main():\n\town OwnerBox* b = relay(make(7))\n\tref int* r = b.item\n\treturn *r + b.tag - 10\n", 0)
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nown OwnerBox* make(int value):\n\town int* item = new int\n\t*item = value\n\treturn new OwnerBox(item, 3)\nint consume(own OwnerBox* b):\n\tref int* r = b.item\n\treturn *r + b.tag\nint main():\n\town OwnerBox* b = make(7)\n\treturn consume(b) - 10\n", 0)
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nown OwnerBox* make(int value):\n\town int* item = new int\n\t*item = value\n\treturn new OwnerBox(item, 3)\nint main():\n\town OwnerBox* b = make(7)\n\town OwnerBox* c = b\n\tref int* r = c.item\n\treturn *r + c.tag - 10\n", 0)
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nown OwnerBox* make(int value):\n\town int* item = new int\n\t*item = value\n\treturn new OwnerBox(item, 3)\nint main():\n\town OwnerBox* b = make(7)\n\tb = make(9)\n\tref int* r = b.item\n\treturn *r + b.tag - 12\n", 0)
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nown OwnerBox* make(int value):\n\town int* item = new int\n\t*item = value\n\treturn new OwnerBox(item, 3)\ntype Owner = own OwnerBox*\nint main():\n\tOwner b = make(7)\n\tOwner c = b\n\tref int* r = c.item\n\treturn *r + c.tag - 10\n", 0)
	owned_aggregate_case(c"struct OwnerPair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town OwnerPair* p = new OwnerPair(new int, new int, 3)\n\trefmut int* first = p.first\n\t*first = 7\n\trefmut int* second = p.second\n\t*second = 9\n\tref int* a = p.first\n\tref int* b = p.second\n\treturn *a + *b + p.tag - 19\n", 0)


void test_owned_aggregate_borrows():
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nown OwnerBox* make(int value):\n\town int* item = new int\n\t*item = value\n\treturn new OwnerBox(item, 3)\nref[a] int* get(ref[a] OwnerBox* b):\n\treturn b.item\nint main():\n\town OwnerBox* b = make(7)\n\tref int* r = get(b)\n\treturn *r - 7\n", 0)
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nown OwnerBox* make(int value):\n\town int* item = new int\n\t*item = value\n\treturn new OwnerBox(item, 3)\nrefmut[a] int* get(refmut[a] OwnerBox* b):\n\treturn b.item\nint main():\n\town OwnerBox* b = make(7)\n\trefmut int* r = get(b)\n\t*r = 9\n\treturn b.tag - 3\n", 0)
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nown OwnerBox* make(int value):\n\town int* item = new int\n\t*item = value\n\treturn new OwnerBox(item, 3)\nrefmut[a] int* bad(ref[a] OwnerBox* b):\n\treturn b.item\nint main():\n\treturn 0\n", c"mutable reference return requires")
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nown OwnerBox* make(int value):\n\town int* item = new int\n\t*item = value\n\treturn new OwnerBox(item, 3)\nint main():\n\town OwnerBox* b = make(7)\n\tref int* r = b.item\n\tb.tag = 5\n\treturn *r - 7\n", 0)
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nown OwnerBox* make(int value):\n\town int* item = new int\n\t*item = value\n\treturn new OwnerBox(item, 3)\nint main():\n\town OwnerBox* b = make(7)\n\tref int* r = b.item\n\tb = make(9)\n\treturn *r\n", c"conflicting")
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nown OwnerBox* make(int value):\n\town int* item = new int\n\t*item = value\n\treturn new OwnerBox(item, 3)\nint main():\n\town OwnerBox* b = make(7)\n\tref int* r = b.item\n\town OwnerBox* moved = b\n\treturn *r\n", c"moved value")
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nown OwnerBox* make(int value):\n\town int* item = new int\n\t*item = value\n\treturn new OwnerBox(item, 3)\nint main():\n\town OwnerBox* b = make(7)\n\tref int* r = b.item\n\tint old = *r\n\town OwnerBox* moved = b\n\treturn old + moved.tag - 10\n", 0)
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nown OwnerBox* make(int value):\n\town int* item = new int\n\t*item = value\n\treturn new OwnerBox(item, 3)\nint main():\n\town OwnerBox* b = make(7)\n\trefmut int* r = b.item\n\tint n = b.tag\n\t*r = n\n\treturn 0\n", 0)
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nown OwnerBox* make(int value):\n\town int* item = new int\n\t*item = value\n\treturn new OwnerBox(item, 3)\nint bad(ref OwnerBox* b):\n\trefmut int* r = b.item\n\t*r = 9\n\treturn 0\nint main():\n\town OwnerBox* b = make(7)\n\treturn bad(b)\n", c"mutable borrow from a shared")


void test_owned_aggregate_fail_closed():
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nint main():\n\town OwnerBox* b = new OwnerBox\n\treturn b.tag\n", c"safe:")
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nint main():\n\town OwnerBox* b = new OwnerBox()\n\treturn b.tag\n", c"every field")
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nint main():\n\town OwnerBox* b = new OwnerBox(item: new int)\n\treturn b.tag\n", c"every field")
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nint main():\n\town OwnerBox* b = new OwnerBox(item: new int, item: new int)\n\treturn b.tag\n", c"initialized twice")
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nint main():\n\town OwnerBox* b = new OwnerBox(new int)\n\treturn b.tag\n", c"", 1)
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nint main():\n\town OwnerBox* b = new OwnerBox(0, 3)\n\treturn b.tag\n", c"safe:", 1)
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nown OwnerBox* make(int value):\n\town int* item = new int\n\t*item = value\n\treturn new OwnerBox(item, 3)\nint main():\n\town OwnerBox* b = make(7)\n\town int* item = b.item\n\treturn *item - 7\n", 0)
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nown OwnerBox* make(int value):\n\town int* item = new int\n\t*item = value\n\treturn new OwnerBox(item, 3)\nint main():\n\town OwnerBox* b = make(7)\n\tb.item = new int\n\treturn b.tag - 3\n", 0)
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nown OwnerBox* make(int value):\n\town int* item = new int\n\t*item = value\n\treturn new OwnerBox(item, 3)\nint main():\n\town OwnerBox* b = make(7)\n\town OwnerBox* c = b\n\treturn b.tag\n", c"moved value")
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nint main():\n\town int* item = new int\n\town OwnerBox* b = new OwnerBox(item, 3)\n\treturn *item\n", c"moved value")
	owned_aggregate_case(c"struct OwnerPair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town int* item = new int\n\town OwnerPair* b = new OwnerPair(item, item, 3)\n\treturn b.tag\n", c"moved value")
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nint main():\n\town int* item = new int\n\town OwnerBox* b = new OwnerBox(item, *item)\n\treturn b.tag\n", c"moved value")
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nint main():\n\town int* item = new int\n\t*item = 7\n\town OwnerBox* b = new OwnerBox(tag: *item, item: item)\n\treturn b.tag - 7\n", 0)
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nown OwnerBox* make(int value):\n\town int* item = new int\n\t*item = value\n\treturn new OwnerBox(item, 3)\nint main():\n\town OwnerBox* b = make(7)\n\tOwnerBox* raw = b\n\treturn raw.tag\n", c"safe:", 1)
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nint main():\n\tOwnerBox b\n\treturn 0\n", c"safe:")
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nown OwnerBox* make(int value):\n\town int* item = new int\n\t*item = value\n\treturn new OwnerBox(item, 3)\nint main():\n\town OwnerBox* b = make(7)\n\tunsafe:\n\t\tfree(b)\n\treturn 0\n", c"cannot manipulate checked")
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nown OwnerBox* make(int value):\n\town int* item = new int\n\t*item = value\n\treturn new OwnerBox(item, 3)\nint main():\n\town OwnerBox* b = make(7)\n\treturn cast(int, b)\n", c"safe:", 1)
	owned_aggregate_case(c"struct Mixed:\n\town int* item\n\tref[a] int* borrowed\nint main():\n\tint x = 7\n\town Mixed* b = new Mixed(new int, &x)\n\treturn 0\n", c"safe:")
	owned_aggregate_case(c"struct Raw:\n\town int* item\n\tint* raw\nint main():\n\town Raw* b = new Raw(new int, 0)\n\treturn 0\n", c"safe:")


void test_owned_aggregate_nested():
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nstruct Outer:\n\town OwnerBox* inner\n\tint tag\nint main():\n\town Outer* o = new Outer(new OwnerBox(new int, 3), 5)\n\tref OwnerBox* inner = o.inner\n\tref int* item = inner.item\n\treturn *item + inner.tag + o.tag - 8\n", 0)
	owned_aggregate_case(c"struct OwnerBox:\n\town int* item\n\tint tag\nstruct Outer:\n\town OwnerBox* inner\n\tint tag\nint main():\n\town Outer* o = new Outer(new OwnerBox(new int, 3), 5)\n\tref OwnerBox* inner = o.inner\n\tref int* item = inner.item\n\to = new Outer(new OwnerBox(new int, 3), 5)\n\treturn *item\n", c"conflicting")


# The expanded ownership budget also applies when a function only borrows the
# shape and therefore never asks the emitter to generate its destructor.
void test_owned_aggregate_borrowed_shape_budget():
	owned_aggregate_case(c"struct BudgetNode1:\n\town int* left\n\town int* right\nstruct BudgetNode2:\n\town BudgetNode1* left\n\town BudgetNode1* right\nstruct BudgetNode3:\n\town BudgetNode2* left\n\town BudgetNode2* right\nstruct BudgetNode4:\n\town BudgetNode3* left\n\town BudgetNode3* right\nstruct BudgetNode5:\n\town BudgetNode4* left\n\town BudgetNode4* right\nstruct BudgetNode6:\n\town BudgetNode5* left\n\town BudgetNode5* right\nstruct BudgetNode7:\n\town BudgetNode6* left\n\town BudgetNode6* right\nint inspect(ref BudgetNode7* node):\n\treturn 0\nint main():\n\treturn 0\n", 0)
	owned_aggregate_case(c"struct BudgetNode1:\n\town int* left\n\town int* right\nstruct BudgetNode2:\n\town BudgetNode1* left\n\town BudgetNode1* right\nstruct BudgetNode3:\n\town BudgetNode2* left\n\town BudgetNode2* right\nstruct BudgetNode4:\n\town BudgetNode3* left\n\town BudgetNode3* right\nstruct BudgetNode5:\n\town BudgetNode4* left\n\town BudgetNode4* right\nstruct BudgetNode6:\n\town BudgetNode5* left\n\town BudgetNode5* right\nstruct BudgetNode7:\n\town BudgetNode6* left\n\town BudgetNode6* right\nstruct BudgetNode8:\n\town BudgetNode7* left\n\town BudgetNode7* right\nint inspect(ref BudgetNode8* node):\n\treturn 0\nint main():\n\treturn 0\n", c"safe:")

void test_owned_aggregate_expansion_bound():
	owned_aggregate_case(c"struct DropNode0:\n\tint value\nstruct DropNode1:\n\town DropNode0* left\n\town DropNode0* right\nstruct DropNode2:\n\town DropNode1* left\n\town DropNode1* right\nstruct DropNode3:\n\town DropNode2* left\n\town DropNode2* right\nstruct DropNode4:\n\town DropNode3* left\n\town DropNode3* right\nstruct DropNode5:\n\town DropNode4* left\n\town DropNode4* right\nstruct DropNode6:\n\town DropNode5* left\n\town DropNode5* right\nstruct DropNode7:\n\town DropNode6* left\n\town DropNode6* right\nint consume(own DropNode7* value):\n\treturn 0\nint main():\n\treturn 0\n", 0)
	owned_aggregate_case(c"struct DropNode0:\n\tint value\nstruct DropNode1:\n\town DropNode0* left\n\town DropNode0* right\nstruct DropNode2:\n\town DropNode1* left\n\town DropNode1* right\nstruct DropNode3:\n\town DropNode2* left\n\town DropNode2* right\nstruct DropNode4:\n\town DropNode3* left\n\town DropNode3* right\nstruct DropNode5:\n\town DropNode4* left\n\town DropNode4* right\nstruct DropNode6:\n\town DropNode5* left\n\town DropNode5* right\nstruct DropNode7:\n\town DropNode6* left\n\town DropNode6* right\nstruct DropNode8:\n\town DropNode7* left\n\town DropNode7* right\nint consume(own DropNode8* value):\n\treturn 0\nint main():\n\treturn 0\n", c"256 expanded allocations")


void test_owned_contract_after_definition():
	owned_aggregate_case(c"int consume(own int* value):\n\treturn 0\nint consume(own int* value);\nint main():\n\treturn consume(new int)\n", 0)
	owned_aggregate_case(c"int consume(own int* value):\n\treturn 0\nint consume(ref int* value);\nint main():\n\treturn 0\n", c"forward declaration disagrees")


void test_owned_contract_cannot_be_erased_after_definition():
	owned_aggregate_case(c"int consume(own int* value):\n\treturn 0\nown int* produce():\n\treturn new int\nint consume(int* value);\nint main():\n\treturn 0\n", c"forward declaration disagrees")
	owned_aggregate_case(c"int consume(own int* value):\n\treturn 0\nown int* produce():\n\treturn new int\nint* produce();\nint main():\n\treturn 0\n", c"forward declaration disagrees")


# Keep evaluated storage alive until index/RHS evaluation completes.
# Separate replacement and value-only reads remain valid.
void test_owned_evaluation_order():
	owned_aggregate_case(c"struct Box:\n\tint value\nint main():\n\town Box* p = new Box\n\tp.value = (p = new Box) != 0\n\treturn 0\n", c"conflicting")
	owned_aggregate_case(c"struct Box:\n\tint[2] values\nint main():\n\town Box* p = new Box\n\treturn p.values[(p = new Box) != 0]\n", c"conflicting")
	owned_aggregate_case(c"struct Box:\n\tint[2] values\nint main():\n\town Box* p = new Box\n\tp.values[(p = new Box) != 0] = 9\n\treturn 0\n", c"conflicting")
	owned_aggregate_case(c"struct Box:\n\tint[2] values\nint main():\n\town Box* p = new Box\n\tp.values[0] = (p = new Box) != 0\n\treturn 0\n", c"conflicting")
	owned_aggregate_case(c"int main():\n\town int* p = new int\n\t*p += (p = new int) != 0\n\treturn 0\n", c"conflicting")
	owned_aggregate_case(c"struct Box:\n\tint[2] values\nint consume(own Box* p):\n\treturn 0\nint main():\n\town Box* p = new Box\n\treturn p.values[consume(p) + ((p = new Box) != 0)]\n", c"conflicting")
	owned_aggregate_case(c"struct Box:\n\tint[2] values\nint main():\n\town Box* p = new Box\n\tref int* child = &p.values[(p = new Box) != 0]\n\treturn *child\n", c"conflicting")
	owned_aggregate_case(c"int consume(ref int* p, int n):\n\treturn *p + n\nint main():\n\town int* p = new int\n\treturn consume(p, (p = new int) != 0)\n", c"conflicting")
	owned_aggregate_case(c"struct Holder:\n\tref[a] int* p\n\tint value\nint main():\n\town int* p = new int\n\tref Holder h = Holder(p, (p = new int) != 0)\n\treturn h.value\n", c"conflicting")
	owned_aggregate_case(c"int main():\n\town int* p = new int\n\t*p = (p = new int) != 0\n\treturn 0\n", c"conflicting")
	owned_aggregate_case(c"int main():\n\town int* p = new int\n\t*p = 3\n\t*p = *p + 4\n\t*p += *p\n\treturn *p - 14\n", 0)
	owned_aggregate_case(c"int main():\n\town int* p = new int\n\t*p = 3\n\tp = new int\n\t*p = 7\n\treturn *p - 7\n", 0)
	owned_aggregate_case(c"own int* identity(own int* p):\n\treturn p\nint main():\n\town int* p = new int\n\t*p = 7\n\tp = identity(p)\n\treturn *p - 7\n", 0)
	owned_aggregate_case(c"struct Box:\n\tint[2] values\nint main():\n\town Box* p = new Box\n\tp.values[0] = 1\n\tp.values[p.values[0]] = 7\n\treturn p.values[1] - 7\n", 0)
	owned_aggregate_case(c"struct Box:\n\town int* item\n\tint tag\nint main():\n\town int* p = new int\n\t*p = 7\n\town Box* b = new Box(p, (p = new int) != 0)\n\tref int* child = b.item\n\treturn *child - 7\n", 0)
