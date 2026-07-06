import lib.testing
import lib.lib
import libs.standard.text.core
import libs.standard.text.textwrap

void test_split_join_empty_and_final_newline():
	list[char*] empty = text_split_lines(c"")
	assert_equal(0, empty.length)
	assert_strings_equal(c"", text_join_lines(empty))
	list[char*] lines = text_split_lines(c"alpha\x0abeta\x0a")
	assert_equal(3, lines.length)
	assert_strings_equal(c"alpha", lines[0])
	assert_strings_equal(c"beta", lines[1])
	assert_strings_equal(c"", lines[2])
	assert_strings_equal(c"alpha\x0abeta\x0a", text_join_lines(lines))

void test_split_join_preserves_utf8_bytes():
	list[char*] lines = text_split_lines(c"caf\xc3\xa9\x0afin")
	assert_equal(2, lines.length)
	assert_equal(5, strlen(lines[0]))
	assert_strings_equal(c"caf\xc3\xa9", lines[0])
	assert_strings_equal(c"caf\xc3\xa9\x0afin", text_join_lines(lines))

void test_wrap_and_fill_simple_ascii():
	list[char*] lines = textwrap_wrap(c"alpha beta gamma", 10)
	assert_equal(2, lines.length)
	assert_strings_equal(c"alpha beta", lines[0])
	assert_strings_equal(c"gamma", lines[1])
	assert_strings_equal(c"one two\x0athree", textwrap_fill(c"one two three", 7))

void test_wrap_breaks_long_words_without_splitting_utf8():
	list[char*] ascii = textwrap_wrap(c"abcdefghij", 4)
	assert_equal(3, ascii.length)
	assert_strings_equal(c"abcd", ascii[0])
	assert_strings_equal(c"efgh", ascii[1])
	assert_strings_equal(c"ij", ascii[2])
	list[char*] utf8 = textwrap_wrap(c"\xc3\xa9\xc3\xa9\xc3\xa9", 5)
	assert_equal(2, utf8.length)
	assert_strings_equal(c"\xc3\xa9\xc3\xa9", utf8[0])
	assert_strings_equal(c"\xc3\xa9", utf8[1])

void test_dedent_and_indent_preserve_line_shape():
	assert_strings_equal(c"alpha\x0a  beta\x0a\x0a", textwrap_dedent(c"  alpha\x0a    beta\x0a  \x0a"))
	assert_strings_equal(c"> alpha\x0a\x0a> beta\x0a", textwrap_indent(c"alpha\x0a\x0abeta\x0a", c"> "))

void test_invalid_width_and_unsupported_option_report_errors():
	list[char*] lines = textwrap_wrap(c"alpha", 0)
	assert_equal(0, lines.length)
	assert1(text_last_error() != 0)
	assert_equal(TEXT_ERR_INVALID_ARGUMENT(), text_last_error().code)
	assert_strings_equal(c"textwrap width must be positive", text_error_message())
	assert_strings_equal(c"", textwrap_fill(c"alpha", 0))
	assert_equal(TEXT_ERR_INVALID_ARGUMENT(), text_last_error().code)
	assert_strings_equal(c"textwrap width must be positive", text_error_message())
	assert_equal(0, textwrap_supports_option(c"break_on_hyphens"))
	assert1(text_last_error() != 0)
	assert_equal(TEXT_ERR_UNSUPPORTED(), text_last_error().code)
	assert_strings_equal(c"unsupported textwrap option", text_error_message())
