# Fail-fast assertions still produce the runner summary, including the
# earlier passing test. The owning steps exercise every assertion helper.
import lib.testing


void test_before_failure():
	assert_equal(2, 1 + 1)


void test_failure():
	char* kind = env_get(c"W_ASSERT_KIND")
	if (strcmp(kind, c"asserts") == 0): asserts(c"fixture failure", 0)
	elif (strcmp(kind, c"assert1") == 0): assert1(0)
	elif (strcmp(kind, c"equal") == 0): assert_equal(1, 2)
	elif (strcmp(kind, c"hex") == 0): assert_equal_hex(1, 2)
	elif (strcmp(kind, c"strings") == 0): assert_strings_equal(c"a", c"b")
	elif (strcmp(kind, c"contains") == 0): assert_contains(c"abc", c"xyz")
	elif (strcmp(kind, c"lacks") == 0): assert_lacks(c"abc", c"bc")
	elif (strcmp(kind, c"bytes") == 0): assert_bytes_equal(c"abc", c"abd", 3)
	elif (strcmp(kind, c"near") == 0): assert_near(1.0, 2.0)
	else: asserts(c"unknown assertion fixture kind", 0)


void test_unreachable():
	assert1(1)
