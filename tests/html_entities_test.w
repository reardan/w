# wbuild: tool=tools/html_entities.w
# wbuild: x64
# wbuild: deps=libs/extras/html/entities.json
# wbuild: step="bin/html_entities --check"
# wbuild: step="bin/html_entities_test --filter contexts,numeric,limits" env="W_TEST_LEAKS=1"
import lib.testing
import lib.file
import structures.json
import libs.extras.html.html


void html_reference_fixture(char* source, char* expected, int diagnostics, int attribute):
	string_builder* input = string_new()
	if (attribute == 1): string_append(input, c"<p a=\"")
	else if (attribute == 2): string_append(input, c"<p a='")
	else if (attribute == 3): string_append(input, c"<p a=")
	string_append(input, source)
	if (attribute == 1): string_append(input, c"\">")
	else if (attribute == 2): string_append(input, c"'>")
	else if (attribute == 3): string_append(input, c">")
	html_tokenizer* t = html_tokenizer_new(input.data, input.length, 0)
	html_token* token = html_tokenizer_next(t)
	if (attribute):
		assert_equal(HTML_START, token.kind)
		assert_strings_equal(expected, token.attributes.value)
		assert_equal(strlen(expected), token.attributes.value_length)
	else:
		assert_equal(HTML_TEXT, token.kind)
		assert_strings_equal(expected, token.text)
		assert_equal(strlen(expected), token.text_length)
	assert_equal(0, token.start)
	assert_equal(input.length, token.end)
	assert_equal(diagnostics, t.diagnostic_count)
	assert_equal(0, t.failed)
	html_token_free(token)
	token = html_tokenizer_next(t)
	assert_equal(HTML_EOF, token.kind)
	html_token_free(token)
	html_tokenizer_free(t)
	string_free(input)


void test_html_reference_all_names():
	# Read the upstream JSON directly: expectations do not use the generated table.
	char* source = file_read_text(c"libs/extras/html/entities.json")
	assert1(source != 0)
	json_value* references = json_parse(source)
	free(source)
	assert1(references != 0)
	assert_equal(2231, references.object_values.length)
	int legacy_count = 0
	for char* name, json_value* entry in references.object_values:
		json_value* value = json_object_get(entry, c"characters")
		assert1(value != 0)
		int legacy = name[strlen(name) - 1] != ';'
		legacy_count = legacy_count + legacy
		for attribute in range(4):
			html_reference_fixture(name, value.string_value, legacy, attribute)
		if (legacy):
			string_builder* input = string_new()
			string_append(input, name)
			string_append(input, c"x")
			# Legacy spellings followed by an ASCII letter stay literal in attributes.
			for attribute in range(1, 4): html_reference_fixture(input.data, input.data, 0, attribute)
			string_free(input)
	assert_equal(106, legacy_count)
	json_free(references)


void test_html_reference_contexts():
	html_reference_fixture(c"&notin;&notit;&notin &not;", c"\xe2\x88\x89\xc2\xacit;\xc2\xacin \xc2\xac", 2, 0)
	html_reference_fixture(c"&notin;&notit;&notin &not;", c"\xe2\x88\x89&notit;&notin \xc2\xac", 0, 1)
	html_reference_fixture(c"&amp=&ampx &copy! &copy9", c"&=&x \xc2\xa9! \xc2\xa99", 4, 0)
	html_reference_fixture(c"&amp=&ampx &copy! &copy9", c"&amp=&ampx \xc2\xa9! &copy9", 1, 2)
	html_reference_fixture(c"&AMP;&amp;&Amp;&apos &apos;", c"&&&Amp;&apos '", 1, 0)
	html_reference_fixture(c"&NotEqualTilde;&fjlig;&Afr;&CounterClockwiseContourIntegral;", c"\xe2\x89\x82\xcc\xb8fj\xf0\x9d\x94\x84\xe2\x88\xb3", 0, 0)
	html_reference_fixture(c"&amp;lt;&#38;copy;&lt;b&gt;", c"&lt;&copy;<b>", 0, 0)
	html_reference_fixture(c"&; &unknown; &unknown &! &", c"&; &unknown; &unknown &! &", 1, 0)
	html_reference_fixture(c"&copy\xc3\xa9", c"\xc2\xa9\xc3\xa9", 1, 1)
	html_reference_fixture(c"&#65x&#x41g&#65=", c"AxAgA=", 3, 3)
	# RCDATA decodes; raw text, script and comments preserve spelling.
	char* source = c"<title>&copy &NotEqualTilde;</title><style>&copy;&#128;</style><script>&copy;&#128;</script><!--&copy;&#128;-->"
	html_tokenizer* t = html_tokenizer_new(source, strlen(source), 0)
	for index in range(10):
		html_token* token = html_tokenizer_next(t)
		if (index == 1): assert_strings_equal(c"\xc2\xa9 \xe2\x89\x82\xcc\xb8", token.text)
		if ((index == 4) || (index == 7) || (index == 9)): assert_strings_equal(c"&copy;&#128;", token.text)
		html_token_free(token)
	assert_equal(1, t.diagnostic_count)
	html_tokenizer_free(t)
	# Decoded markup remains text, and the copied source/spans remain original.
	source = c"<p title='&notit;'>&lt;b&gt;&copy;</p>"
	html_document* doc = html_parse(source, strlen(source))
	html_node* p = doc.root.first_child.first_child.next_sibling.first_child
	assert_strings_equal(c"&notit;", p.attributes.value)
	assert_equal(HTML_TEXT, p.first_child.kind)
	assert_strings_equal(c"<b>\xc2\xa9", p.first_child.text)
	assert_equal(19, p.first_child.start)
	assert_equal(34, p.first_child.end)
	assert_equal(0, cast(int, p.first_child.next_sibling))
	assert_strings_equal(source, doc.source)
	html_document_free(doc)


void test_html_reference_numeric():
	html_reference_fixture(c"&#65;&#x41;&#X1f600;&#0000065;", c"AA\xf0\x9f\x98\x80A", 0, 0)
	html_reference_fixture(c"&#65 &#x41! &#x41g &#65x", c"A A! Ag Ax", 4, 0)
	html_reference_fixture(c"&#; &#x; &#Xz; &#-1; &#", c"&#; &#x; &#Xz; &#-1; &#", 5, 0)
	html_reference_fixture(c"&#0;&#xD800;&#xDFFF;&#1114112;&#999999999999999999999999999999999999999;", c"\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd", 5, 0)
	html_reference_fixture(c"&#xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF", c"\xef\xbf\xbd", 2, 0)
	html_reference_fixture(c"&#xFDD0;&#xFFFF;&#x10FFFF;", c"\xef\xb7\x90\xef\xbf\xbf\xf4\x8f\xbf\xbf", 3, 0)
	html_reference_fixture(c"&#9;&#10;&#12;&#13;&#1;&#127;&#129;", c"\t\n\x0c\r\x01\x7f\xc2\x81", 4, 0)
	html_reference_fixture(c"&#128;&#x82;&#x9F;", c"\xe2\x82\xac\xe2\x80\x9a\xc5\xb8", 3, 0)
	# Character-reference CR is emitted after source newline normalization.
	html_reference_fixture(c"\r\n&#13;\r&#10;", c"\n\r\n\n", 1, 1)
	html_reference_fixture(c"&#xD7FF;&#xE000;&#x10FFFD;", c"\xed\x9f\xbf\xee\x80\x80\xf4\x8f\xbf\xbd", 0, 0)
	# Independently spell every C1 repair, including the five preserved controls.
	char* expected = c"\xe2\x82\xac\xc2\x81\xe2\x80\x9a\xc6\x92\xe2\x80\x9e\xe2\x80\xa6\xe2\x80\xa0\xe2\x80\xa1\xcb\x86\xe2\x80\xb0\xc5\xa0\xe2\x80\xb9\xc5\x92\xc2\x8d\xc5\xbd\xc2\x8f\xc2\x90\xe2\x80\x98\xe2\x80\x99\xe2\x80\x9c\xe2\x80\x9d\xe2\x80\xa2\xe2\x80\x93\xe2\x80\x94\xcb\x9c\xe2\x84\xa2\xc5\xa1\xe2\x80\xba\xc5\x93\xc2\x9d\xc5\xbe\xc5\xb8"
	string_builder* references = string_new()
	for cp in range(128, 160):
		string_append(references, c"&#")
		string_append_int(references, cp)
		string_append_char(references, ';')
	html_reference_fixture(references.data, expected, 32, 0)
	string_free(references)


void test_html_reference_limits():
	char* source = c"&bogus; &copy &#0; &#x;"
	html_limits limits = html_default_limits()
	limits.diagnostics = 2
	html_tokenizer* t = html_tokenizer_new(source, strlen(source), &limits)
	html_token* token = html_tokenizer_next(t)
	assert_equal(2, t.diagnostic_count)
	assert_equal(0, t.failed)
	assert_equal(0, t.diagnostics.start)
	assert_equal(7, t.diagnostics.end)
	assert_strings_equal(c"unknown named character reference", t.diagnostics.message)
	assert_equal(8, t.diagnostics.next.start)
	assert_equal(13, t.diagnostics.next.end)
	assert_strings_equal(c"missing semicolon after character reference", t.diagnostics.next.message)
	html_token_free(token)
	html_tokenizer_free(t)
	limits.diagnostics = 0
	t = html_tokenizer_new(source, strlen(source), &limits)
	token = html_tokenizer_next(t)
	assert_strings_equal(c"&bogus; \xc2\xa9 \xef\xbf\xbd &#x;", token.text)
	assert_equal(0, cast(int, t.diagnostics))
	html_token_free(token)
	html_tokenizer_free(t)
	# All truncated prefixes use only the explicit length, including EOF after '#x'.
	source = c"&CounterClockwiseContourIntegral;&copy;&#x1F600;&notit;&#999999999999999999999;"
	for length in range(1, strlen(source) + 1):
		t = html_tokenizer_new(source, length, 0)
		token = html_tokenizer_next(t)
		assert_equal(length, token.end)
		assert_equal(0, t.failed)
		html_diagnostic* d = t.diagnostics
		while (d != 0):
			asserts(c"reference diagnostic span", d.start >= 0 && d.end >= d.start && d.end <= length)
			d = d.next
		html_token_free(token)
		token = html_tokenizer_next(t)
		assert_equal(HTML_EOF, token.kind)
		html_token_free(token)
		html_tokenizer_free(t)
	# A digit run longer than the machine word saturates, but is fully consumed.
	string_builder* long_input = string_new()
	string_append(long_input, c"&#")
	for i in range(20000): string_append_char(long_input, '9')
	string_append(long_input, c";&copy;")
	html_reference_fixture(long_input.data, c"\xef\xbf\xbd\xc2\xa9", 1, 0)
	string_free(long_input)
	long_input = string_new()
	string_append_char(long_input, '&')
	for i in range(20000): string_append_char(long_input, 'z')
	string_append_char(long_input, ';')
	html_reference_fixture(long_input.data, long_input.data, 1, 0)
	string_free(long_input)
