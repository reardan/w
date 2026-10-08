# wbuild: x64
# wbuild: step="bin/stdlib_property_test" env="W_DEBUG_ALLOC=1" env="W_TEST_LEAKS=1" expect_stdout="Summary: 3 passed, 0 failed, 0 skipped [leak check]"
# wbuild: step="bin/wv2 x64 tests/stdlib_property_test.w -o bin/stdlib_property_leak64"
# wbuild: step="bin/stdlib_property_leak64" env="W_DEBUG_ALLOC=1" env="W_TEST_LEAKS=1" expect_stdout="Summary: 3 passed, 0 failed, 0 skipped [leak check]"
# Deterministic property tests: fixed seeds, bounded cases, independent
# array models. Failures print their seed and operation before asserting.
import lib.testing
import structures.json


int property_state


# This bounded linear congruential generator stays within signed 32-bit int,
# so each seed generates the same cases on x86 and x64.
int property_next(int limit):
	property_state = (property_state * 251 + 17) % 65521
	return property_state % limit


void property_context(int seed, int operation):
	char* seed_text = itoa(seed)
	char* operation_text = itoa(operation)
	print(c"property seed=")
	print(seed_text)
	print(c" operation=")
	print(operation_text)
	println(c"")
	free(seed_text)
	free(operation_text)


void test_map_and_set_match_array_model():
	for seed in range(1, 9):
		property_state = seed
		map[int, int] actual = new map[int, int]
		set[int] members = new set[int]
		int[64] present
		int[64] values
		for key in range(64): present[key] = 0
		int count = 0
		for operation in range(600):
			int key = property_next(64)
			if (property_next(3) == 0):
				actual.remove(key)
				members.remove(key)
				if (present[key]): count = count - 1
				present[key] = 0
			else:
				int value = property_next(2001) - 1000
				actual[key] = value
				members.add(key)
				if (present[key] == 0): count = count + 1
				present[key] = 1
				values[key] = value
			if ((actual.length != count) || (members.length != count)):
				property_context(seed, operation)
				assert_equal(count, actual.length)
				assert_equal(count, members.length)
			for probe in range(64):
				if (((probe in actual) != present[probe]) || ((probe in members) != present[probe])):
					property_context(seed, operation)
					assert_equal(present[probe], (probe in actual))
					assert_equal(present[probe], (probe in members))
				if (present[probe]):
					if (actual[probe] != values[probe]): property_context(seed, operation)
					assert_equal(values[probe], actual[probe])
		actual.free()
		members.free()


void test_list_sort_preserves_multiset_and_is_idempotent():
	for seed in range(1, 33):
		property_state = seed
		list[int] actual = new list[int]
		int[33] counts
		for i in range(33): counts[i] = 0
		int length = property_next(200)
		if (seed == 1): length = 0
		if (seed == 2): length = 1
		for i in range(length):
			int value = property_next(33)
			counts[value] = counts[value] + 1
			actual.push(value - 16)
		actual.sort()
		property_context(seed, length)
		assert_equal(length, actual.length)
		int position = 0
		for value in range(33):
			for occurrence in range(counts[value]):
				assert_equal(value - 16, actual[position])
				position = position + 1
		actual.sort()
		assert_equal(length, actual.length)
		position = 0
		for value in range(33):
			for occurrence in range(counts[value]):
				assert_equal(value - 16, actual[position])
				position = position + 1
		actual.free()


void test_generated_json_roundtrips_values_and_escapes():
	for seed in range(1, 65):
		property_state = seed
		json_value* original = json_array()
		int length = property_next(25)
		if (seed == 1): length = 0
		if (seed == 2): length = 1
		for i in range(length):
			json_value* row = json_array()
			json_array_push(row, json_int(property_next(20001) - 10000))
			char[33] buffer
			int nchars = property_next(32)
			for j in range(nchars):
				# Includes control characters, backslashes and quotes.
				buffer[j] = cast(char, property_next(127) + 1)
			buffer[nchars] = 0
			json_array_push(row, json_string(buffer))
			json_array_push(row, json_bool(property_next(2)))
			json_array_push(row, json_null())
			json_array_push(original, row)
		char* encoded = json_stringify(original)
		json_value* decoded = json_parse(encoded)
		property_context(seed, length)
		assert1(decoded != 0)
		assert_equal(length, json_array_length(decoded))
		for i in range(length):
			json_value* want = json_array_get(original, i)
			json_value* got = json_array_get(decoded, i)
			assert_equal(4, json_array_length(got))
			for j in range(4):
				json_value* a = json_array_get(want, j)
				json_value* b = json_array_get(got, j)
				assert_equal(a.type, b.type)
				if (j == 1): assert_strings_equal(a.string_value, b.string_value)
				elif (j != 3): assert_equal(a.int_value, b.int_value)
		char* canonical = json_stringify(decoded)
		assert_strings_equal(encoded, canonical)
		free(canonical)
		free(encoded)
		json_free(decoded)
		json_free(original)
