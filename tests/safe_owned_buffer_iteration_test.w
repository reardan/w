# wbuild: x64
# wbuild: deps=lib/safe_owned_vector.w
# Checked iteration over owned-element storage (#697). Every contract is
# checked and compiled with and without --safe. Rejections must prevent
# publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int owned_iteration_case_number


void owned_iteration_result(process_result* result, char* diagnostic, int checking, char* path):
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


void owned_iteration_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0, char* runtime_diagnostic = 0):
	owned_iteration_case_number = owned_iteration_case_number + 1
	char* number = itoa(owned_iteration_case_number)
	char* prefix = c"bin/owned_iteration_case32_"
	if (__word_size__ == 8): prefix = c"bin/owned_iteration_case64_"
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
		if (mode && explicit_safe_diagnostic): diagnostic = explicit_safe_diagnostic
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
		owned_iteration_result(checked, diagnostic, 1, full)
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
		owned_iteration_result(compiled, diagnostic, 0, full)
		process_result_free(compiled)
		free(cast(void*, compiling))
		if (diagnostic):
			assert1(open(output, 0, 0) < 0)
		else:
			char** run = strv_new(1)
			strv_set(run, 0, output)
			process_result* executed = process_run(output, run, 0, 0, 30000)
			assert1(executed != 0)
			if (runtime_diagnostic):
				assert_equal(1, executed.status)
				assert_contains(executed.stderr_text, runtime_diagnostic)
			else: assert_equal(0, executed.status)
			process_result_free(executed)
			free(cast(void*, run))
		unlink(output)
	unlink(full)
	free(output)
	free(full)

# Explicit and inferred shared element references over a local owner.
void test_owned_iteration_0():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\tint weight\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value, number * 10)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\tfor i in range(4): owned_buffer_push[Item](values, item(i + 1))\n\tint total = 0\n\tfor ref Item* entry in values:\n\t\tref int* value = entry.value\n\t\ttotal += *value + entry.weight\n\tfor entry in values: total += entry.weight\n\treturn total - 110 - 100\n", 0)

# An empty buffer runs no iterations.
void test_owned_iteration_1():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\tint total = 0\n\tfor entry in values: total += 1 + entry.weight\n\treturn total\n", 0)

# A borrowed buffer parameter is reborrowed for the loop.
void test_owned_iteration_2():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint sum(ref WOwnedBuffer[Item]* values):\n\tint total = 0\n\tfor ref Item* entry in values: total += entry.weight\n\treturn total\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\tfor i in range(3): owned_buffer_push[Item](values, new Item(i + 1))\n\treturn sum(values) - 6\n", 0)

# An exclusive buffer parameter is reborrowed shared for the loop.
void test_owned_iteration_3():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint bump(refmut WOwnedBuffer[Item]* values):\n\tint total = 0\n\tfor ref Item* entry in values: total += entry.weight\n\towned_buffer_push[Item](values, new Item(total))\n\treturn owned_buffer_length[Item](values)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, new Item(2))\n\treturn bump(values) - 2\n", 0)

# Mutation resumes after the loop.
void test_owned_iteration_4():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, new Item(2))\n\tint total = 0\n\tfor entry in values: total += entry.weight\n\towned_buffer_push[Item](values, new Item(total))\n\towned_buffer_clear[Item](values)\n\treturn owned_buffer_length[Item](values)\n", 0)

# Insertion in the body is rejected even with spare capacity.
void test_owned_iteration_5():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, new Item(2))\n\tfor entry in values: owned_buffer_push[Item](values, new Item(3))\n\treturn 0\n", c"borrow")

# Clearing the buffer in the body is rejected, even without naming the element.
void test_owned_iteration_6():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, new Item(2))\n\tfor entry in values: owned_buffer_clear[Item](values)\n\treturn 0\n", c"borrow")

# After the element's last use, a path that leaves the loop may mutate.
void test_owned_iteration_7():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, new Item(2))\n\tint total = 0\n\tfor entry in values:\n\t\ttotal += entry.weight\n\t\towned_buffer_clear[Item](values)\n\t\tbreak\n\treturn total - 2 + owned_buffer_length[Item](values)\n", 0)

# The same mutation is rejected while the element is still used.
void test_owned_iteration_8():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, new Item(2))\n\tint total = 0\n\tfor entry in values:\n\t\towned_buffer_clear[Item](values)\n\t\ttotal += entry.weight\n\t\tbreak\n\treturn total\n", c"borrow")

# Replacing an element in the body is rejected.
void test_owned_iteration_9():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, new Item(2))\n\tfor entry in values: owned_buffer_set[Item](values, 0, new Item(4))\n\treturn 0\n", c"borrow")

# Popping an element in the body is rejected.
void test_owned_iteration_10():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, new Item(2))\n\tfor entry in values:\n\t\town Item* taken = owned_buffer_pop[Item](values)\n\treturn 0\n", c"borrow")

# Moving the owner in the body is rejected.
void test_owned_iteration_11():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, new Item(2))\n\tfor entry in values:\n\t\town WOwnedBuffer[Item]* moved = values\n\treturn 0\n", c"safe:")

# A saved element reference keeps the buffer borrowed after the loop.
void test_owned_iteration_12():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, new Item(2))\n\toptref Item* saved = 0\n\tfor entry in values: saved = entry\n\towned_buffer_clear[Item](values)\n\tif (saved): return saved.weight\n\treturn 0\n", c"borrow")

# Mutation is accepted after the saved reference's last use.
void test_owned_iteration_13():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, new Item(2))\n\toptref Item* saved = 0\n\tfor entry in values: saved = entry\n\tint weight = 0\n\tif (saved): weight = saved.weight\n\towned_buffer_clear[Item](values)\n\treturn weight - 2\n", 0)

# The loop variable is uninitialized after a possibly empty loop.
void test_owned_iteration_14():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\tref Item* entry\n\tfor entry in values: break\n\treturn entry.weight\n", c"initialization")

# Nested loops over the same buffer keep independent shared loans.
void test_owned_iteration_15():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\tfor i in range(3): owned_buffer_push[Item](values, new Item(i + 1))\n\tint total = 0\n\tfor left in values:\n\t\tfor right in values: total += left.weight * right.weight\n\treturn total - 36\n", 0)

# Nested owned buffers iterate through their element references.
void test_owned_iteration_16():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint main():\n\town WOwnedBuffer[WOwnedBuffer[Item]]* outer = owned_buffer_new[WOwnedBuffer[Item]](-1)\n\tfor i in range(3):\n\t\town WOwnedBuffer[Item]* inner = owned_buffer_new[Item](-1)\n\t\tfor j in range(i + 1): owned_buffer_push[Item](inner, new Item(j + 1))\n\t\towned_buffer_push[WOwnedBuffer[Item]](outer, inner)\n\tint total = 0\n\tfor ref WOwnedBuffer[Item]* inner in outer:\n\t\tfor item in inner: total += item.weight\n\treturn total - 10\n", 0)

# break, continue and return exit the loop; owned body locals are dropped.
void test_owned_iteration_17():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint first_over(ref WOwnedBuffer[Item]* values, int limit):\n\tfor entry in values:\n\t\town int* scratch = new int\n\t\t*scratch = entry.weight\n\t\tif *scratch <= limit: continue\n\t\treturn *scratch\n\treturn -1\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\tfor i in range(5): owned_buffer_push[Item](values, new Item(i))\n\tint total = 0\n\tfor entry in values:\n\t\tif entry.weight == 1: continue\n\t\tif entry.weight == 3: break\n\t\ttotal += entry.weight\n\treturn total + first_over(values, 2) - 5\n", 0)

# A borrowed record field holding an owned buffer can be iterated.
void test_owned_iteration_18():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nstruct Box:\n\town WOwnedBuffer[Item]* values\nint main():\n\town Box* box = new Box(owned_buffer_new[Item](-1))\n\towned_buffer_push[Item](box.values, new Item(5))\n\tint total = 0\n\tfor entry in box.values: total += entry.weight\n\treturn total - 5\n", 0)

# Replacing the iterated field in the body is rejected.
void test_owned_iteration_19():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nstruct Box:\n\town WOwnedBuffer[Item]* values\nint main():\n\town Box* box = new Box(owned_buffer_new[Item](-1))\n\towned_buffer_push[Item](box.values, new Item(5))\n\tfor entry in box.values: box.values = owned_buffer_new[Item](-1)\n\treturn 0\n", c"borrow")

# An owning temporary has no owner to destroy it after the loop.
void test_owned_iteration_20():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nown WOwnedBuffer[Item]* make():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, new Item(5))\n\treturn values\nint main():\n\tint total = 0\n\tfor entry in make(): total += entry.weight\n\treturn total - 5\n", c"safe: owned-storage iteration requires a named owner or a borrow")

# Elements are lent, never transferred.
void test_owned_iteration_21():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\tfor own Item* entry in values: return entry.weight\n\treturn 0\n", c"safe: owned-storage iteration requires a shared reference variable")

# Exclusive element iteration is not admitted.
void test_owned_iteration_22():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\tfor refmut Item* entry in values: entry.weight = 1\n\treturn 0\n", 0)

# Raw element pointers cannot escape the container.
void test_owned_iteration_23():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\tfor Item* entry in values: return entry.weight\n\treturn 0\n", c"safe: owned-storage iteration requires a shared reference variable")

# The reference must name the element type.
void test_owned_iteration_24():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nstruct Other:\n\tint weight\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\tfor ref Other* entry in values: return entry.weight\n\treturn 0\n", c"safe: incompatible owned-storage iteration variable type")

# Fields cannot be written through the shared element reference.
void test_owned_iteration_25():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, new Item(1))\n\tfor entry in values: entry.weight = 2\n\treturn 0\n", c"safe:")

# An owned child of an element cannot be moved out through the reference.
void test_owned_iteration_26():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\town int* value = new int\n\towned_buffer_push[Item](values, new Item(value))\n\tfor entry in values:\n\t\town int* taken = entry.value\n\treturn 0\n", c"safe:")

# An element reference may be returned under the container's lifetime.
void test_owned_iteration_27():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\noptref[a] Item* heaviest(ref[a] WOwnedBuffer[Item]* values):\n\toptref Item* best = 0\n\tfor entry in values:\n\t\tif (!best): best = entry\n\t\telse if (entry.weight > best.weight): best = entry\n\treturn best\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\tfor i in range(4): owned_buffer_push[Item](values, new Item((i * 3) % 4))\n\toptref Item* best = heaviest(values)\n\tif (!best): return 1\n\treturn best.weight - 3\n", 0)

# A returned element reference blocks destruction of its container.
void test_owned_iteration_28():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\noptref[a] Item* first(ref[a] WOwnedBuffer[Item]* values):\n\tfor entry in values: return entry\n\treturn 0\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, new Item(4))\n\toptref Item* found = first(values)\n\towned_buffer_clear[Item](values)\n\tif (found): return found.weight\n\treturn 0\n", c"borrow")

# A local container's element cannot escape the function.
void test_owned_iteration_29():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\noptref Item* leak():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, new Item(4))\n\tfor entry in values: return entry\n\treturn 0\nint main():\n\toptref Item* found = leak()\n\treturn 0\n", c"safe:")

# Iteration with a scoped defer and owner-valued elements in the body.
void test_owned_iteration_30():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\tfor i in range(3):\n\t\town int* value = new int\n\t\t*value = i + 1\n\t\towned_buffer_push[Item](values, new Item(value))\n\tint total = 0\n\tfor entry in values:\n\t\tref int* value = entry.value\n\t\town int* copy = new int\n\t\t*copy = *value\n\t\tdefer: total += *copy\n\treturn total - 6\n", 0)

# Imported aliases and inferred element types work together.
void test_owned_iteration_31():
	owned_iteration_case(c"import lib.safe_owned_vector as vector\nstruct Item:\n\tint weight\nint main():\n\town WOwnedBuffer[Item]* values = vector.owned_buffer_new[Item](-1)\n\tvector.owned_buffer_push[Item](values, new Item(7))\n\tint total = 0\n\tfor entry in values: total += entry.weight\n\treturn total - 7\n", 0)

# An optional owner must be tested and bound before iteration.
void test_owned_iteration_32():
	owned_iteration_case(c"import lib.safe_owned_vector\nstruct Item:\n\tint weight\nint main():\n\toptown WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\tfor entry in values: return entry.weight\n\treturn 0\n", c"safe: owned-storage iteration requires a present container")
