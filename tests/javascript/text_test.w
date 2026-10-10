# wbuild: name=javascript_text_test
# wbuild: x64 expect_stdout="javascript_text_test: OK"
import lib.assert
import libs.extras.javascript.text


int main():
	char[3] bytes
	bytes[0] = 'a'
	bytes[1] = 0
	bytes[2] = 'b'
	js_text* text = js_text_from_utf8(bytes, 3)
	assert_equal(3, text.units.length)
	int length = 0
	char* utf8 = js_text_to_utf8(text, &length)
	assert_equal(3, length)
	assert_equal(0, utf8[1])
	assert_equal('b', utf8[2])
	free(utf8)
	js_text_free(text)
	char* raw = c"'a\\0\\ud800\\udfff\\u{1f600}z'"
	text = js_text_decode(raw, strlen(raw))
	assert_equal(7, text.units.length)
	assert_equal(0, text.units[1])
	assert_equal(55296, text.units[2])
	assert_equal(57343, text.units[3])
	assert_equal(55357, text.units[4])
	assert_equal(56832, text.units[5])
	js_text* copy = js_text_clone(text)
	assert1(js_text_equal(text, copy))
	js_text_free(copy)
	js_text_free(text)
	text = js_text_decode(c"'\\ud800'", 8)
	assert1(text != 0)
	assert1(js_text_to_utf8(text, &length) == 0)
	assert_equal(0, length)
	js_text_free(text)
	text = js_text_decode(c"'\\udfff'", 8)
	assert1(js_text_to_utf8(text, &length) == 0)
	js_text_free(text)
	text = js_text_decode(c"'\\ud83d\\ude00'", 14)
	utf8 = js_text_to_utf8(text, &length)
	assert_equal(4, length)
	assert_equal(240, utf8[0] & 255)
	free(utf8)
	js_text_free(text)
	assert1(js_text_decode(c"'\\u'", 4) == 0)
	assert1(js_text_decode(c"'\\x0'", 5) == 0)
	assert1(js_text_decode(c"'x'junk", 7) == 0)
	text = js_text_decode(c"'x'junk", 3)
	assert1(text != 0)
	js_text_free(text)
	text = js_text_new()
	text.units.push(65536)
	assert1(js_text_to_utf8(text, &length) == 0)
	js_text_free(text)
	assert1(js_text_decode(0, 3) == 0)
	text = js_text_decode(c"'\\é'", 5)
	assert1(text != 0)
	assert_equal(1, text.units.length)
	assert_equal(233, text.units[0])
	js_text_free(text)
	text = js_text_decode(c"'\xe2\x80\xa8'", 5)
	assert1(text != 0)
	assert_equal(8232, text.units[0])
	js_text_free(text)
	assert1(js_text_from_utf8(c"\xff", 1) == 0)
	println(c"javascript_text_test: OK")
	return 0
