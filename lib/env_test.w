# wbuild: x64
import lib.testing
import lib.env


void test_env_get_path_is_set():
	# Any reasonable launcher sets PATH; the test harness always has it.
	char* path = env_get(c"PATH")
	assert1(path != 0)
	assert1(strlen(path) > 0)


void test_env_get_missing_returns_zero():
	assert1(env_get(c"W_ENV_TEST_NO_SUCH_VARIABLE") == 0)


void test_env_get_ignores_prefix_matches():
	# "PATH" must not match the "PATHEXT_W_TEST=..." entry shape: build a
	# vector where only a longer name is present.
	char** base = env_copy_with(0, c"PATHX", c"long")
	assert1(env_vector_count(base) == 1)
	char* entry = env_entry_at(base, 0)
	assert1(env_match_name(entry, c"PATH") == -1)
	assert1(env_match_name(entry, c"PATHX") == 6)


void test_env_count_and_at_walk_the_vector():
	int count = env_count()
	assert1(count > 0)
	int i = 0
	while (i < count):
		char* entry = env_at(i)
		assert1(entry != 0)
		i = i + 1
	assert1(env_at(count) == 0)
	assert1(env_at(-1) == 0)


void test_env_copy_with_appends_new_name():
	char** modified = env_copy_with(env_current(), c"W_ENV_TEST_ADDED", c"added-value")
	assert_equal(env_count() + 1, env_vector_count(modified))
	# Reading through the copy: find the entry and check its value shape.
	int i = 0
	char* found = 0
	while (env_entry_at(modified, i) != 0):
		char* entry = env_entry_at(modified, i)
		int value_index = env_match_name(entry, c"W_ENV_TEST_ADDED")
		if (value_index >= 0):
			found = entry + value_index
		i = i + 1
	assert1(found != 0)
	assert_strings_equal(c"added-value", found)
	# The parent's own environment is untouched.
	assert1(env_get(c"W_ENV_TEST_ADDED") == 0)


void test_env_copy_with_replaces_existing_name():
	char** first = env_copy_with(env_current(), c"W_ENV_TEST_REPLACED", c"one")
	char** second = env_copy_with(first, c"W_ENV_TEST_REPLACED", c"two")
	# Replacement, not append: same entry count.
	assert_equal(env_vector_count(first), env_vector_count(second))
	int i = 0
	int matches = 0
	char* value = 0
	while (env_entry_at(second, i) != 0):
		char* entry = env_entry_at(second, i)
		int value_index = env_match_name(entry, c"W_ENV_TEST_REPLACED")
		if (value_index >= 0):
			matches = matches + 1
			value = entry + value_index
		i = i + 1
	assert_equal(1, matches)
	assert_strings_equal(c"two", value)


void test_env_copy_with_from_empty_base():
	char** vector = env_copy_with(0, c"ONLY", c"entry")
	assert_equal(1, env_vector_count(vector))
	assert_strings_equal(c"ONLY=entry", env_entry_at(vector, 0))
	assert1(env_entry_at(vector, 1) == 0)
