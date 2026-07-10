import lib.testing


void test_plain_chars():
	assert_equal(97, 'a')
	assert_equal(32, ' ')
	assert_equal(48, '0')
	assert_equal(126, '~')


void test_simple_escapes():
	assert_equal(10, '\n')
	assert_equal(9, '\t')
	assert_equal(13, '\r')
	assert_equal(0, '\0')
	assert_equal(92, '\\')
	assert_equal(39, '\'')
	assert_equal(34, '\"')


void test_hex_escapes():
	assert_equal(65, '\x41')
	assert_equal(255, '\xff')
	assert_equal(0, '\x00')
	assert_equal(160, '\xA0')


void test_unicode_escapes():
	assert_equal(65, '\u0041')
	assert_equal(233, '\u00e9')
	assert_equal(8364, '\u20AC')
	assert_equal(128512, '\U0001F600')


# Raw UTF-8 sequences evaluate to the Unicode codepoint, matching the
# equivalent \u escape
void test_utf8_char_literals():
	assert_equal(233, 'é')
	assert_equal(8364, '€')
	assert_equal(128512, '😀')


void test_char_typed():
	char c1 = 'a'
	assert_equal(97, c1)
	char c2 = '\x42'
	assert_equal(66, c2)


int char_default(int c = '\x41'):
	return c


void test_char_default_arg():
	assert_equal(65, char_default())
	assert_equal(10, char_default('\n'))


void test_char_in_switch():
	int hits = 0
	switch ('\n'):
		case '\t':
			hits = 2
		case 10:
			hits = 1
		default:
			hits = 3
	assert_equal(1, hits)
