# wbuild: x64
import lib.testing
import lib.cloc


cloc_counts cloc_test_scan(char* text):
	cloc_counts c
	cloc_counts_clear(&c)
	cloc_scan_text(text, strlen(text), &c)
	return c


void cloc_test_expect(char* text, int blank, int comment, int code, int tokens):
	cloc_counts c = cloc_test_scan(text)
	assert_equal(1, c.files)
	assert_equal(blank, c.blank)
	assert_equal(comment, c.comment)
	assert_equal(code, c.code)
	assert_equal(tokens, c.tokens)


void test_cloc_empty():
	cloc_test_expect(c"", 0, 0, 0, 0)


void test_cloc_simple_function():
	# int main(): / return 0 -> 5 + 2 tokens
	cloc_test_expect(c"int main():\n\treturn 0\n", 0, 0, 2, 7)


void test_cloc_missing_final_newline():
	cloc_test_expect(c"x = 1", 0, 0, 1, 3)


void test_cloc_blank_lines():
	cloc_test_expect(c"a\n\n\t\n  \nb\n", 3, 0, 2, 2)


void test_cloc_line_comments():
	# A trailing comment keeps its line in code.
	cloc_test_expect(c"# header\n\t# indented\nx = 1 # trailing\n", 0, 2, 1, 3)


void test_cloc_block_comment():
	# The whitespace-only line inside the block is still comment.
	cloc_test_expect(c"/*\nheader\n\n*/\nint x\n", 0, 4, 1, 2)


void test_cloc_block_comment_then_code():
	cloc_test_expect(c"/* note */ int x\n", 0, 0, 1, 2)


void test_cloc_comment_markers_in_strings():
	# '#' and '/*' inside literals are not comments.
	cloc_test_expect(c"s = \"# not /* a comment\"\nch = '#'\n", 0, 0, 2, 6)


void test_cloc_escaped_quote():
	cloc_test_expect(c"s = \"a\\\"b # c\"\n", 0, 0, 1, 3)


void test_cloc_prefixed_strings():
	# c"..." and s"..." are one token each, like the tokenizer's.
	cloc_test_expect(c"p(c\"x\", s\"y\")\n", 0, 0, 1, 6)


void test_cloc_multiline_string():
	# Every line a literal spans is code.
	cloc_test_expect(c"s = \"a\n\nb\"\n", 0, 0, 3, 3)


void test_cloc_operator_merges():
	# a <= b && c != d -> 7 tokens; x += 1 -> 3; i++ -> 2; y := 2 -> 3;
	# z /= 4 -> 3; p -> q -> 4 ('-' and '>' stay separate)
	cloc_test_expect(c"a <= b && c != d\nx += 1\ni++\ny := 2\nz /= 4\np -> q\n", 0, 0, 6, 22)


void test_cloc_numbers():
	# 1.5e-3 and 0x1e are one token each; 0x1e - 2 keeps the minus.
	cloc_test_expect(c"f = 1.5e-3\nh = 0x1e - 2\n", 0, 0, 2, 8)


void test_cloc_template_string():
	# f"a{x}b{y + 1}c" -> chunks f"a{  }b{  }c" (3) + x + y + 1 (4)
	cloc_test_expect(c"f\"a{x}b{y + 1}c\"\n", 0, 0, 1, 7)


void test_cloc_template_escaped_braces():
	# '{{' and '}}' are literal braces, not expressions; a '#' inside is text.
	cloc_test_expect(c"t = f\"{{#}}\"\n", 0, 0, 1, 3)


void test_cloc_template_nested_braces():
	# The map literal's braces nest inside the embedded expression:
	# f"{  m  [  {  1  :  2  }  ]  }" -> 10 tokens
	cloc_test_expect(c"f\"{m[{1: 2}]}\"\n", 0, 0, 1, 10)


void test_cloc_counts_add():
	cloc_counts a = cloc_test_scan(c"x\n\n# c\n")
	cloc_counts b = cloc_test_scan(c"y\n")
	cloc_counts_add(&a, &b)
	assert_equal(2, a.files)
	assert_equal(1, a.blank)
	assert_equal(1, a.comment)
	assert_equal(2, a.code)
	assert_equal(2, a.tokens)
	assert_equal(4, cloc_lines(&a))


void test_cloc_collect():
	# A directory walk finds .w files only, sorted, skipping bin/ and
	# hidden entries; a file argument is returned as-is.
	list[char*] files = new list[char*]
	assert_equal(0, cloc_collect(c"libs/extras/protobuf", files))
	assert_equal(3, files.length)
	assert_strings_equal(c"libs/extras/protobuf/message.w", files[0])
	assert_strings_equal(c"libs/extras/protobuf/varint.w", files[1])
	assert_strings_equal(c"libs/extras/protobuf/wire.w", files[2])

	list[char*] one = new list[char*]
	assert_equal(0, cloc_collect(c"README.md", one))
	assert_equal(1, one.length)
	assert_strings_equal(c"README.md", one[0])

	list[char*] missing = new list[char*]
	assert_equal(-1, cloc_collect(c"no_such_dir_cloc_11aa", missing))
	assert_equal(0, missing.length)


void test_cloc_scan_file():
	cloc_counts c
	cloc_counts_clear(&c)
	assert_equal(0, cloc_scan_file(c"lib/cloc.w", &c))
	assert_equal(1, c.files)
	assert1(c.code > 0)
	assert1(c.comment > 0)
	assert_equal(-1, cloc_scan_file(c"no_such_file_cloc_11aa.w", &c))
	assert_equal(1, c.files)


void test_cloc_unterminated_string():
	# Malformed input is counted to EOF: the final newline an open
	# literal runs into does not add a line.
	cloc_test_expect(c"x = c\"abc\n", 0, 0, 1, 3)
	cloc_test_expect(c"x = \"a\nb\n", 0, 0, 2, 3)


# cloc_count_path groups a directory's files by top-level entry (the
# wcloc default), or keeps one row per file with by_file.
void test_cloc_count_path_rows():
	list[cloc_row*] rows = new list[cloc_row*]
	list[char*] unreadable = new list[char*]
	assert_equal(0, cloc_count_path(c"tests/cloc/sample", 0, rows, unreadable))
	assert_equal(2, rows.length)
	assert_strings_equal(c"tests/cloc/sample/sub", rows[0].path)
	assert_equal(0, rows[0].is_file)
	assert_equal(3, rows[0].counts.code)
	assert_strings_equal(c"tests/cloc/sample", rows[1].path)
	assert_equal(1, rows[1].counts.files)
	assert_equal(0, unreadable.length)

	list[cloc_row*] files = new list[cloc_row*]
	assert_equal(0, cloc_count_path(c"tests/cloc/sample", 1, files, unreadable))
	assert_equal(2, files.length)
	assert_strings_equal(c"tests/cloc/sample/sub/leaf.w", files[0].path)
	assert_equal(1, files[0].is_file)
	assert_equal(-1, cloc_count_path(c"tests/cloc/no_such_dir", 0, files, unreadable))
	assert_equal(2, files.length)


void test_cloc_group_and_display_path():
	assert_strings_equal(c"root/a", cloc_group_path(c"root", c"root/a/b/c.w"))
	assert_strings_equal(c"root/", cloc_group_path(c"root/", c"root/x.w"))
	assert_strings_equal(c"lib", cloc_display_path(c"./lib"))
	assert_strings_equal(c".", cloc_display_path(c"."))
