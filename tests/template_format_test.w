# wbuild: x64 arch=arm64 arch=wasm
# wbuild: step="bin/wv2 tests/template_format_error_fixture.w -o bin/template_format_error_fixture" expect_fail expect_stderr="invalid template string format spec 'q': expected [[fill]align][0][width][.precision][type] with type one of d x X o b c s f"
# wbuild: step="bin/wv2 tests/template_format_precision_fixture.w -o bin/template_format_precision_fixture" expect_fail expect_stderr="invalid template string format spec '.2': precision needs a float value"
# wbuild: step="bin/wv2 tests/template_format_type_fixture.w -o bin/template_format_type_fixture" expect_fail expect_stderr="invalid template string format spec 'x': a text value takes type s"
# wbuild: step="bin/wv2 tests/template_format_zero_fixture.w -o bin/template_format_zero_fixture" expect_fail expect_stderr="invalid template string format spec '05': zero padding and '=' alignment need a numeric value"
# f-string format specs ('{value:spec}', grammar/template_string.w):
# the Python mini-language subset [[fill]align][0][width][.precision]
# [type], plus float32 interpolation. float64 has its own x64-only
# test (template_format_float64_test.w).
import lib.testing


void check(char* want, string got):
	assert_strings_equal(want, got.data)
	assert_equal(strlen(want), got.length)


void test_radix_types():
	int n = 255
	check(c"ff FF 377 11111111", f"{n:x} {n:X} {n:o} {n:b}")
	check(c"0 d 10", f"{0:x} {13:x} {2:b}")


void test_negative_hex_is_the_unsigned_word():
	if (__word_size__ == 8):
		check(c"ffffffffffffffff", f"{-1:x}")
	else:
		check(c"ffffffff", f"{-1:x}")


void test_char_type():
	char c = 'A'
	# the default rendering of a char stays numeric; ':c' asks for the
	# character, and an int codepoint encodes as UTF-8
	check(c"A 65 \xc3\xa9 z", f"{c:c} {c} {233:c} {'z':c}")


void test_width_and_alignment():
	int n = 42
	check(c"[    42] [42    ] [  42  ] [000042]", f"[{n:6}] [{n:<6}] [{n:^6}] [{n:06}]")
	check(c"[-00042] [****42] [42....]", f"[{-n:06}] [{n:*>6}] [{n:.<6}]")
	# width smaller than the text never truncates
	check(c"12345", f"{12345:3}")


void test_hex_with_padding():
	check(c"00ff 0x0A", f"{255:04x} 0x{10:02X}")


void test_text_values():
	char* name = c"joe"
	string s = s"hé"
	# text aligns left by default; width counts codepoints, not bytes
	check(c"[joe  ] [  joe] [h\xc3\xa9   ] [ h\xc3\xa9  ]", f"[{name:5}] [{name:>5}] [{s:5}] [{s:^5s}]")


void test_float_values():
	float f = 3.14159
	check(c"3.141590 3.142 3 3.1", f"{f} {f:.3} {f:.0} {f:.1f}")
	check(c"[    3.14] [3.1     ] [-0003.14]", f"[{f:8.2}] [{f:<8.1}] [{-f:08.2}]")
	float half = 2.5
	check(c"2.50 0.1", f"{half:.2} {0.05 + 0.05:.1}")


enum fmt_color:
	fmt_red
	fmt_green


void test_enum_bool_and_var():
	fmt_color c = fmt_green
	bool flag = true
	var v = 7
	check(c"001 1  7", f"{c:03} {flag:x} {v:>2}")


void test_empty_spec_is_plain():
	int n = 5
	check(c"5", f"{n:}")


void test_ternary_inside_braces_still_parses():
	int n = 3
	check(c"odd  ", f"{n % 2 == 1 ? c"odd" : c"even":5}")
