# wbuild: x64
# wbuild: step="bin/toml_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
# TOML 1.0 compliance subset in the style of toml-test
# (https://github.com/toml-lang/toml-test): each valid case pairs a
# document with its expected tagged JSON (written with ` for " to keep
# the literals readable), each invalid case a document with a fragment
# of the expected error.
import lib.testing
import libs.standard.formats.toml


# Expected tagged JSON with ` standing for ".
char* tt_unquote(char* text):
	char* out = strclone(text)
	int i = 0
	while (out[i] != 0):
		if (out[i] == '`'): out[i] = '"'
		i = i + 1
	return out


void tv(char* input, char* expected):
	char* want = tt_unquote(expected)
	toml_doc* doc = toml_parse(input)
	if (doc.root == 0): assert_strings_equal(want, doc.error)
	else:
		char* got = toml_tagged_json(doc.root)
		assert_strings_equal(want, got)
		free(got)
	toml_doc_free(doc)
	free(want)


void ti(char* input, char* fragment):
	toml_doc* doc = toml_parse(input)
	if (doc.root != 0):
		char* got = toml_tagged_json(doc.root)
		print2(c"unexpectedly valid: ")
		println2(got)
		free(got)
	asserts(c"document should be invalid", doc.root == 0)
	if (doc.error != 0): assert_contains(doc.error, fragment)
	toml_doc_free(doc)


void ti_at(char* input, char* error):
	toml_doc* doc = toml_parse(input)
	asserts(c"document should be invalid", doc.root == 0)
	assert_strings_equal(error, doc.error)
	toml_doc_free(doc)


# ---- valid: keys -------------------------------------------------------

void test_valid_empty_and_comments():
	tv(c"", c"{}")
	tv(c"# just a comment\n\n   \t\n# another\n", c"{}")
	tv(c"a = 1 # trailing comment\n", c"{`a`:{`type`:`integer`,`value`:`1`}}")
	tv(c"a = 1", c"{`a`:{`type`:`integer`,`value`:`1`}}")
	tv(c"\xef\xbb\xbfk = 1\n", c"{`k`:{`type`:`integer`,`value`:`1`}}")
	tv(c"\ta\t=\t1\t\n", c"{`a`:{`type`:`integer`,`value`:`1`}}")


void test_valid_bare_keys():
	tv(c"key = 1\nbare_key = 2\nbare-key = 3\n1234 = 4\nA_Z-09 = 5\n", c"{`key`:{`type`:`integer`,`value`:`1`},`bare_key`:{`type`:`integer`,`value`:`2`},`bare-key`:{`type`:`integer`,`value`:`3`},`1234`:{`type`:`integer`,`value`:`4`},`A_Z-09`:{`type`:`integer`,`value`:`5`}}")
	tv(c"true = 1\nfalse = 2\ninf = 3\nnan = 4\n", c"{`true`:{`type`:`integer`,`value`:`1`},`false`:{`type`:`integer`,`value`:`2`},`inf`:{`type`:`integer`,`value`:`3`},`nan`:{`type`:`integer`,`value`:`4`}}")


void test_valid_quoted_keys():
	tv(c"\"127.0.0.1\" = 1\n\"ʎǝʞ\" = 2\n'quoted \"value\"' = 3\n\"\" = 4\n\"a\\tb\" = 5\n", c"{`127.0.0.1`:{`type`:`integer`,`value`:`1`},`ʎǝʞ`:{`type`:`integer`,`value`:`2`},`quoted \\`value\\``:{`type`:`integer`,`value`:`3`},``:{`type`:`integer`,`value`:`4`},`a\\tb`:{`type`:`integer`,`value`:`5`}}")


void test_valid_dotted_keys():
	tv(c"name = \"Orange\"\nphysical.color = \"orange\"\nphysical.shape = \"round\"\nsite.\"google.com\" = true\n", c"{`name`:{`type`:`string`,`value`:`Orange`},`physical`:{`color`:{`type`:`string`,`value`:`orange`},`shape`:{`type`:`string`,`value`:`round`}},`site`:{`google.com`:{`type`:`bool`,`value`:`true`}}}")
	tv(c"fruit . flavor = 1\nfruit.\tcolor = 2\n", c"{`fruit`:{`flavor`:{`type`:`integer`,`value`:`1`},`color`:{`type`:`integer`,`value`:`2`}}}")
	tv(c"3.14159 = \"pi\"\n", c"{`3`:{`14159`:{`type`:`string`,`value`:`pi`}}}")
	tv(c"a.b.c = 1\na.b.d = 2\na.e = 3\n", c"{`a`:{`b`:{`c`:{`type`:`integer`,`value`:`1`},`d`:{`type`:`integer`,`value`:`2`}},`e`:{`type`:`integer`,`value`:`3`}}}")


# ---- valid: strings ----------------------------------------------------

void test_valid_basic_strings():
	tv(c"s = \"I'm a string. \\\"You can quote me\\\". Tab\\tnew\\nline \\\\ \\b\\f\\r\"\n", c"{`s`:{`type`:`string`,`value`:`I'm a string. \\`You can quote me\\`. Tab\\tnew\\nline \\\\ \\b\\f\\r`}}")
	tv(c"s = \"\\u00e9 \\u20AC \\U0001F600 \\u0041\"\n", c"{`s`:{`type`:`string`,`value`:`é € 😀 A`}}")
	tv(c"s = \"\"\n", c"{`s`:{`type`:`string`,`value`:``}}")
	tv(c"s = \"raw é and tab\there\"\n", c"{`s`:{`type`:`string`,`value`:`raw é and tab\\there`}}")


void test_valid_multiline_basic_strings():
	tv(c"s = \"\"\"\nRoses are red\nViolets are blue\"\"\"\n", c"{`s`:{`type`:`string`,`value`:`Roses are red\\nViolets are blue`}}")
	tv(c"s = \"\"\"\nThe quick brown \\\n\n\n  fox jumps over \\\n    the lazy dog.\"\"\"\n", c"{`s`:{`type`:`string`,`value`:`The quick brown fox jumps over the lazy dog.`}}")
	tv(c"s = \"\"\"\\\n       The quick brown \\   \n       fox.\\\n       \"\"\"\n", c"{`s`:{`type`:`string`,`value`:`The quick brown fox.`}}")
	tv(c"a = \"\"\"Here are two quotation marks: \"\". Simple enough.\"\"\"\nb = \"\"\"x\"\"\"\"\nc = \"\"\"y\"\"\"\"\"\nd = \"\"\"\"z\"\"\"\n", c"{`a`:{`type`:`string`,`value`:`Here are two quotation marks: \\`\\`. Simple enough.`},`b`:{`type`:`string`,`value`:`x\\``},`c`:{`type`:`string`,`value`:`y\\`\\``},`d`:{`type`:`string`,`value`:`\\`z`}}")
	tv(c"s = \"\"\"a\r\nb\\\r\n  c\"\"\"\r\n", c"{`s`:{`type`:`string`,`value`:`a\\nbc`}}")
	tv(c"s = \"\"\"\"\"\"\n", c"{`s`:{`type`:`string`,`value`:``}}")


void test_valid_literal_strings():
	tv(c"winpath = 'C:\\Users\\nodejs\\templates'\nquoted = 'Tom \"Dubs\" Preston-Werner'\nregex = '<\\i\\c*\\s*>'\n", c"{`winpath`:{`type`:`string`,`value`:`C:\\\\Users\\\\nodejs\\\\templates`},`quoted`:{`type`:`string`,`value`:`Tom \\`Dubs\\` Preston-Werner`},`regex`:{`type`:`string`,`value`:`<\\\\i\\\\c*\\\\s*>`}}")
	tv(c"re = '''I [dw]on't need \\d{2} apples'''\nlines = '''\nThe first newline is\ntrimmed in raw strings.\n'''\nq = '''Here are fifteen quotation marks: \"\"\"\"\"\"\"\"\"\"\"\"\"\"\"'''\napos = ''''That,' she said, 'is still pointless.''''\n", c"{`re`:{`type`:`string`,`value`:`I [dw]on't need \\\\d{2} apples`},`lines`:{`type`:`string`,`value`:`The first newline is\\ntrimmed in raw strings.\\n`},`q`:{`type`:`string`,`value`:`Here are fifteen quotation marks: \\`\\`\\`\\`\\`\\`\\`\\`\\`\\`\\`\\`\\`\\`\\``},`apos`:{`type`:`string`,`value`:`'That,' she said, 'is still pointless.'`}}")
	tv(c"e = ''\n", c"{`e`:{`type`:`string`,`value`:``}}")


# ---- valid: numbers, booleans, datetimes ------------------------------

void test_valid_integers():
	tv(c"a = +99\nb = 42\nc = 0\nd = -17\ne = 1_000\nf = 5_349_221\ng = 1_2_3_4_5\nh = -0\ni = +0\n", c"{`a`:{`type`:`integer`,`value`:`99`},`b`:{`type`:`integer`,`value`:`42`},`c`:{`type`:`integer`,`value`:`0`},`d`:{`type`:`integer`,`value`:`-17`},`e`:{`type`:`integer`,`value`:`1000`},`f`:{`type`:`integer`,`value`:`5349221`},`g`:{`type`:`integer`,`value`:`12345`},`h`:{`type`:`integer`,`value`:`0`},`i`:{`type`:`integer`,`value`:`0`}}")
	tv(c"h1 = 0xDEAD\nh3 = 0x00ff\no1 = 0o01234567\no2 = 0o755\nb1 = 0b11010110\nb2 = 0b1_0\n", c"{`h1`:{`type`:`integer`,`value`:`57005`},`h3`:{`type`:`integer`,`value`:`255`},`o1`:{`type`:`integer`,`value`:`342391`},`o2`:{`type`:`integer`,`value`:`493`},`b1`:{`type`:`integer`,`value`:`214`},`b2`:{`type`:`integer`,`value`:`2`}}")


void test_valid_integer_limits():
	tv(c"max = 2147483647\nmin = -2147483648\n", c"{`max`:{`type`:`integer`,`value`:`2147483647`},`min`:{`type`:`integer`,`value`:`-2147483648`}}")
	if (__word_size__ == 8):
		tv(c"max = 9223372036854775807\nmin = -9223372036854775808\nh = 0x7FFFFFFFFFFFFFFF\nb = 0b111\nh2 = 0xdead_beef\n", c"{`max`:{`type`:`integer`,`value`:`9223372036854775807`},`min`:{`type`:`integer`,`value`:`-9223372036854775808`},`h`:{`type`:`integer`,`value`:`9223372036854775807`},`b`:{`type`:`integer`,`value`:`7`},`h2`:{`type`:`integer`,`value`:`3735928559`}}")
		ti(c"a = 9223372036854775808\n", c"integer out of range")
		ti(c"a = -9223372036854775809\n", c"integer out of range")
		ti(c"a = 0x8000000000000000\n", c"integer out of range")
	else:
		ti(c"a = 2147483648\n", c"integer out of range")
		ti(c"a = -2147483649\n", c"integer out of range")
		ti(c"a = 9223372036854775807\n", c"integer out of range")


void test_valid_floats():
	tv(c"a = +1.0\nb = 3.14\nc = -0.01\nd = 5e+22\ne = 1e06\nf = -2E-2\ng = 6.626e-34\nh = 1_000.5\ni = 1e1_0\nj = 0e0\nk = 0.5e-1\n", c"{`a`:{`type`:`float`,`value`:`1.0`},`b`:{`type`:`float`,`value`:`3.14`},`c`:{`type`:`float`,`value`:`-0.01`},`d`:{`type`:`float`,`value`:`5e22`},`e`:{`type`:`float`,`value`:`1000000.0`},`f`:{`type`:`float`,`value`:`-0.02`},`g`:{`type`:`float`,`value`:`6.626e-34`},`h`:{`type`:`float`,`value`:`1000.5`},`i`:{`type`:`float`,`value`:`10000000000.0`},`j`:{`type`:`float`,`value`:`0.0`},`k`:{`type`:`float`,`value`:`0.05`}}")
	tv(c"a = inf\nb = +inf\nc = -inf\nd = nan\ne = +nan\nf = -nan\n", c"{`a`:{`type`:`float`,`value`:`inf`},`b`:{`type`:`float`,`value`:`inf`},`c`:{`type`:`float`,`value`:`-inf`},`d`:{`type`:`float`,`value`:`nan`},`e`:{`type`:`float`,`value`:`nan`},`f`:{`type`:`float`,`value`:`nan`}}")
	json_value* root = toml_loads(c"z = -0.0\npi = 3.141592653589793\n")
	json_value* z = toml_get(root, c"z")
	assert_equal(json_type_float(), z.type)
	if (__word_size__ == 8):
		assert1(z.has_float64)
		assert1(z.float64_bits < 0)
		char* got = toml_tagged_json(toml_get(root, c"pi"))
		assert_strings_equal(c"{\"type\":\"float\",\"value\":\"3.141592653589793\"}", got)
		free(got)
	json_free(root)


void test_valid_booleans():
	tv(c"t = true\nf = false\n", c"{`t`:{`type`:`bool`,`value`:`true`},`f`:{`type`:`bool`,`value`:`false`}}")


void test_valid_datetimes():
	tv(c"odt1 = 1979-05-27T07:32:00Z\nodt2 = 1979-05-27T00:32:00-07:00\nodt3 = 1979-05-27T00:32:00.999999+07:00\nodt4 = 1979-05-27 07:32:00z\n", c"{`odt1`:{`type`:`datetime`,`value`:`1979-05-27T07:32:00Z`},`odt2`:{`type`:`datetime`,`value`:`1979-05-27T00:32:00-07:00`},`odt3`:{`type`:`datetime`,`value`:`1979-05-27T00:32:00.999999+07:00`},`odt4`:{`type`:`datetime`,`value`:`1979-05-27T07:32:00Z`}}")
	tv(c"ldt1 = 1979-05-27T07:32:00\nldt2 = 1979-05-27t00:32:00.999999\nld = 1979-05-27\nlt1 = 07:32:00\nlt2 = 00:32:00.999999\nleap = 2000-02-29\nleap4 = 2024-02-29\nend = 1999-12-31T23:59:59\n", c"{`ldt1`:{`type`:`datetime-local`,`value`:`1979-05-27T07:32:00`},`ldt2`:{`type`:`datetime-local`,`value`:`1979-05-27T00:32:00.999999`},`ld`:{`type`:`date-local`,`value`:`1979-05-27`},`lt1`:{`type`:`time-local`,`value`:`07:32:00`},`lt2`:{`type`:`time-local`,`value`:`00:32:00.999999`},`leap`:{`type`:`date-local`,`value`:`2000-02-29`},`leap4`:{`type`:`date-local`,`value`:`2024-02-29`},`end`:{`type`:`datetime-local`,`value`:`1999-12-31T23:59:59`}}")
	tv(c"a = [1979-05-27, 07:32:00]\nd = 1979-05-27 # date then comment\n", c"{`a`:[{`type`:`date-local`,`value`:`1979-05-27`},{`type`:`time-local`,`value`:`07:32:00`}],`d`:{`type`:`date-local`,`value`:`1979-05-27`}}")
	json_value* root = toml_loads(c"a = 1979-05-27T07:32:00Z\nb = 1979-05-27T07:32:00\nc = 1979-05-27\nd = 07:32:00\ne = \"1979-05-27\"\n")
	assert_equal(toml_kind_offset_datetime, toml_string_kind(toml_get(root, c"a")))
	assert_equal(toml_kind_local_datetime, toml_string_kind(toml_get(root, c"b")))
	assert_equal(toml_kind_local_date, toml_string_kind(toml_get(root, c"c")))
	assert_equal(toml_kind_local_time, toml_string_kind(toml_get(root, c"d")))
	assert_equal(toml_kind_string, toml_string_kind(toml_get(root, c"e")))
	assert_equal(json_type_string(), toml_get(root, c"a").type)
	json_free(root)


# ---- valid: arrays and inline tables ----------------------------------

void test_valid_arrays():
	tv(c"integers = [ 1, 2, 3 ]\ncolors = [ \"red\", \"yellow\" ]\nnested = [ [ 1, 2 ], [3, 4, 5] ]\nmixed = [ [ 1, 2 ], [\"a\", 'b'] ]\nnum = [ 0.5, 1 ]\nobjs = [ { x = 1, y = 2 }, { x = 7 } ]\nempty = []\nnested_empty = [[], [[]]]\n", c"{`integers`:[{`type`:`integer`,`value`:`1`},{`type`:`integer`,`value`:`2`},{`type`:`integer`,`value`:`3`}],`colors`:[{`type`:`string`,`value`:`red`},{`type`:`string`,`value`:`yellow`}],`nested`:[[{`type`:`integer`,`value`:`1`},{`type`:`integer`,`value`:`2`}],[{`type`:`integer`,`value`:`3`},{`type`:`integer`,`value`:`4`},{`type`:`integer`,`value`:`5`}]],`mixed`:[[{`type`:`integer`,`value`:`1`},{`type`:`integer`,`value`:`2`}],[{`type`:`string`,`value`:`a`},{`type`:`string`,`value`:`b`}]],`num`:[{`type`:`float`,`value`:`0.5`},{`type`:`integer`,`value`:`1`}],`objs`:[{`x`:{`type`:`integer`,`value`:`1`},`y`:{`type`:`integer`,`value`:`2`}},{`x`:{`type`:`integer`,`value`:`7`}}],`empty`:[],`nested_empty`:[[],[[]]]}")
	tv(c"a = [\n  1, # one\n  2,\n  # dangling comment\n]\nb = [\n\n]\nc = [ \"x\" , ]\n", c"{`a`:[{`type`:`integer`,`value`:`1`},{`type`:`integer`,`value`:`2`}],`b`:[],`c`:[{`type`:`string`,`value`:`x`}]}")
	tv(c"a = [\r\n1,\r\n2]\r\n", c"{`a`:[{`type`:`integer`,`value`:`1`},{`type`:`integer`,`value`:`2`}]}")


void test_valid_inline_tables():
	tv(c"name = { first = \"Tom\", last = \"Preston-Werner\" }\npoint = {x=1,y=2}\nanimal = { type.name = \"pug\" }\nempty = {}\nnest = { a = { b = { c = 1 } }, d = [ {e = 2} ] }\n", c"{`name`:{`first`:{`type`:`string`,`value`:`Tom`},`last`:{`type`:`string`,`value`:`Preston-Werner`}},`point`:{`x`:{`type`:`integer`,`value`:`1`},`y`:{`type`:`integer`,`value`:`2`}},`animal`:{`type`:{`name`:{`type`:`string`,`value`:`pug`}}},`empty`:{},`nest`:{`a`:{`b`:{`c`:{`type`:`integer`,`value`:`1`}}},`d`:[{`e`:{`type`:`integer`,`value`:`2`}}]}}")
	tv(c"t = { a.b = 1, a.c = 2 }\n", c"{`t`:{`a`:{`b`:{`type`:`integer`,`value`:`1`},`c`:{`type`:`integer`,`value`:`2`}}}}")


# ---- valid: tables and arrays of tables -------------------------------

void test_valid_tables():
	tv(c"[table-1]\nkey1 = \"some string\"\nkey2 = 123\n\n[table-2]\nkey1 = \"another string\"\n", c"{`table-1`:{`key1`:{`type`:`string`,`value`:`some string`},`key2`:{`type`:`integer`,`value`:`123`}},`table-2`:{`key1`:{`type`:`string`,`value`:`another string`}}}")
	tv(c"[ j . \"ʞ\" . 'l' ]  # spaces\nx = 1\n", c"{`j`:{`ʞ`:{`l`:{`x`:{`type`:`integer`,`value`:`1`}}}}}")
	tv(c"[x.y.z.w]\na = 1\n[x]\nb = 2\n", c"{`x`:{`y`:{`z`:{`w`:{`a`:{`type`:`integer`,`value`:`1`}}}},`b`:{`type`:`integer`,`value`:`2`}}}")
	tv(c"[a]\n[a.b]\n[c.d]\n", c"{`a`:{`b`:{}},`c`:{`d`:{}}}")
	tv(c"[fruit]\napple.color = \"red\"\napple.taste.sweet = true\n[fruit.apple.texture]\nsmooth = true\n", c"{`fruit`:{`apple`:{`color`:{`type`:`string`,`value`:`red`},`taste`:{`sweet`:{`type`:`bool`,`value`:`true`}},`texture`:{`smooth`:{`type`:`bool`,`value`:`true`}}}}}")
	tv(c"a.b = 1\n[c]\nd = 2\n", c"{`a`:{`b`:{`type`:`integer`,`value`:`1`}},`c`:{`d`:{`type`:`integer`,`value`:`2`}}}")
	tv(c"[\"a.b\"]\n['c d']\n", c"{`a.b`:{},`c d`:{}}")


void test_valid_arrays_of_tables():
	tv(c"[[products]]\nname = \"Hammer\"\nsku = 738594937\n\n[[products]]  # empty table\n\n[[products]]\nname = \"Nail\"\ncolor = \"gray\"\n", c"{`products`:[{`name`:{`type`:`string`,`value`:`Hammer`},`sku`:{`type`:`integer`,`value`:`738594937`}},{},{`name`:{`type`:`string`,`value`:`Nail`},`color`:{`type`:`string`,`value`:`gray`}}]}")
	tv(c"[[fruits]]\nname = \"apple\"\n[fruits.physical]\ncolor = \"red\"\n[[fruits.varieties]]\nname = \"red delicious\"\n[[fruits.varieties]]\nname = \"granny smith\"\n[[fruits]]\nname = \"banana\"\n[[fruits.varieties]]\nname = \"plantain\"\n", c"{`fruits`:[{`name`:{`type`:`string`,`value`:`apple`},`physical`:{`color`:{`type`:`string`,`value`:`red`}},`varieties`:[{`name`:{`type`:`string`,`value`:`red delicious`}},{`name`:{`type`:`string`,`value`:`granny smith`}}]},{`name`:{`type`:`string`,`value`:`banana`},`varieties`:[{`name`:{`type`:`string`,`value`:`plantain`}}]}]}")
	tv(c"[[ a . b ]]\nx = 1\n[a]\ny = 2\n", c"{`a`:{`b`:[{`x`:{`type`:`integer`,`value`:`1`}}],`y`:{`type`:`integer`,`value`:`2`}}}")


# ---- invalid ------------------------------------------------------------

void test_invalid_keys():
	ti(c"key = # INVALID\n", c"expected a value")
	ti(c"key =\n", c"expected a value")
	ti(c"key\n", c"expected '='")
	ti(c"first = \"Tom\" last = \"Preston-Werner\"\n", c"expected a newline after value")
	ti(c"= \"no key name\"\n", c"expected a key")
	ti(c"\"\"\"key\"\"\" = 1\n", c"expected '='")
	ti(c"a. = 1\n", c"expected a key")
	ti(c".a = 1\n", c"expected a key")
	ti(c"a..b = 1\n", c"expected a key")
	ti(c"ʎ = 1\n", c"expected a key")
	ti(c"a b = 1\n", c"expected '='")
	ti(c"\"a\nb\" = 1\n", c"unterminated string")


void test_invalid_redefinition():
	ti_at(c"name = \"Tom\"\nname = \"Pradyun\"\n", c"line 2, column 1: duplicate key")
	ti(c"spelling = \"favorite\"\n\"spelling\" = \"favourite\"\n", c"duplicate key")
	ti(c"fruit.apple = 1\nfruit.apple.smooth = true\n", c"not a table")
	ti(c"[fruit]\napple = \"red\"\n[fruit]\norange = 1\n", c"table redefined")
	ti(c"[a]\n[a]\n", c"table redefined")
	ti(c"[a.b]\n[a]\n[a]\n", c"table redefined")
	ti(c"[fruit]\napple = \"red\"\n[fruit.apple]\n", c"table redefined")
	ti(c"[fruit]\napple.color = \"red\"\n[fruit.apple]\n", c"table redefined")
	ti(c"[fruit]\napple.taste.sweet = true\n[fruit.apple.taste]\n", c"table redefined")
	ti(c"a.b = 1\n[a]\n", c"table redefined")
	ti(c"[a.b]\nx = 1\n[a]\nb.y = 2\n", c"cannot extend")
	ti(c"[a]\nb = 1\n[a.b.c]\n", c"already defined as a value")
	ti(c"a = {x = 1}\na.y = 2\n", c"cannot extend")
	ti(c"a = {x = 1}\n[a.b]\n", c"cannot extend an inline table")
	ti(c"a = {x = 1}\n[a]\n", c"table redefined")
	ti(c"a = [1]\n[[a]]\n", c"cannot make it an array of tables")
	ti(c"a = []\n[a.b]\n", c"cannot extend a static array")
	ti(c"[[a]]\n[a]\n", c"table redefined")
	ti(c"[a]\n[[a]]\n", c"cannot make it an array of tables")
	ti(c"a = [{b = 1}]\n[[a]]\n", c"cannot make it an array of tables")
	ti(c"[[a]]\nb = {c = 1}\n[a.b.d]\n", c"cannot extend an inline table")


void test_invalid_inline_tables():
	ti(c"a = {x = 1, }\n", c"trailing comma")
	ti(c"a = {x = 1\n, y = 2}\n", c"newline in inline table")
	ti(c"a = {\nx = 1}\n", c"expected a key")
	ti(c"a = {x = 1, x = 2}\n", c"duplicate key")
	ti(c"a = {b = {c = 1}, b.d = 2}\n", c"cannot extend")
	ti(c"a = {x = 1 y = 2}\n", c"expected ',' or '}'")
	ti(c"a = {x = 1", c"unterminated inline table")
	ti(c"a = {,}\n", c"expected a key")


void test_invalid_arrays():
	ti(c"a = [1 2]\n", c"expected ',' or ']'")
	ti(c"a = [1,,2]\n", c"invalid value")
	ti(c"a = [,]\n", c"invalid value")
	ti(c"a = [\n1\n", c"unterminated array")
	ti(c"a = [1]]\n", c"expected a newline after value")


void test_invalid_strings():
	ti(c"s = \"\\q\"\n", c"invalid escape sequence")
	ti(c"s = \"\\e\"\n", c"invalid escape sequence")
	ti(c"s = \"\\x41\"\n", c"invalid escape sequence")
	ti(c"s = \"\\ \"\n", c"invalid escape sequence")
	ti(c"s = \"\\uD800\"\n", c"not a Unicode scalar value")
	ti(c"s = \"\\U00110000\"\n", c"not a Unicode scalar value")
	ti(c"s = \"\\UFFFFFFFF\"\n", c"not a Unicode scalar value")
	ti(c"s = \"\\u12\"\n", c"expected hex digits")
	ti(c"s = \"\\u12g4\"\n", c"expected hex digits")
	ti(c"s = \"unterminated\n", c"unterminated string")
	ti(c"s = \"unterminated", c"unterminated string")
	ti(c"s = 'a\nb'\n", c"unterminated string")
	ti(c"s = \"a\x01z\"\n", c"control character in string")
	ti(c"s = 'a\x7fz'\n", c"control character in string")
	ti(c"s = \"\"\"a\x1fz\"\"\"\n", c"control character in string")
	ti(c"s = \"\"\"a\"\"\"\"\"\"\n", c"too many quotes")
	ti(c"s = '''a''''''\n", c"too many quotes")
	ti(c"s = \"\"\"abc\n", c"unterminated multi-line string")
	ti(c"s = '''abc", c"unterminated multi-line string")
	ti(c"s = \"\"\"a\\  b\"\"\"\n", c"invalid escape sequence")
	ti(c"s = \"\"\"a\rb\"\"\"\n", c"bare carriage return")
	ti(c"s = \"\"\"a\"\"\" \"\"\n", c"expected a newline after value")
	ti(c"s = \"a\" \"b\"\n", c"expected a newline after value")


void test_invalid_numbers():
	ti(c"a = 01\n", c"leading zeros")
	ti(c"a = -012\n", c"leading zeros")
	ti(c"a = 0_1\n", c"leading zeros")
	ti(c"a = 00.5\n", c"leading zeros")
	ti(c"a = 1__2\n", c"invalid number")
	ti(c"a = 1_\n", c"invalid number")
	ti(c"a = _1\n", c"invalid value")
	ti(c"a = +0x10\n", c"sign not allowed")
	ti(c"a = -0b1\n", c"sign not allowed")
	ti(c"a = 0xG\n", c"invalid number")
	ti(c"a = 0x\n", c"invalid number")
	ti(c"a = 0X10\n", c"invalid number")
	ti(c"a = 0o8\n", c"invalid number")
	ti(c"a = 0b2\n", c"invalid number")
	ti(c"a = 0x_1\n", c"invalid number")
	ti(c"a = 1.\n", c"invalid number")
	ti(c"a = .5\n", c"invalid value")
	ti(c"a = 1.e5\n", c"invalid number")
	ti(c"a = 1e\n", c"invalid number")
	ti(c"a = 1e_5\n", c"invalid number")
	ti(c"a = 1e5.5\n", c"invalid number")
	ti(c"a = 1.5_\n", c"invalid number")
	ti(c"a = 1_.5\n", c"invalid number")
	ti(c"a = 0x1.5\n", c"invalid number")
	ti(c"a = infinity\n", c"invalid number")
	ti(c"a = NaN\n", c"invalid value")
	ti(c"a = Inf\n", c"invalid value")
	ti(c"a = ++1\n", c"invalid number")
	ti(c"a = 1 2\n", c"expected a newline after value")
	ti(c"a = 1,\n", c"expected a newline after value")


void test_invalid_booleans():
	ti(c"a = tru\n", c"invalid value")
	ti(c"a = True\n", c"invalid value")
	ti(c"a = truex\n", c"expected a newline after value")
	ti(c"a = falsey\n", c"expected a newline after value")


void test_invalid_datetimes():
	ti(c"d = 1979-13-27\n", c"invalid date or time")
	ti(c"d = 1979-00-27\n", c"invalid date or time")
	ti(c"d = 1979-02-30\n", c"invalid date or time")
	ti(c"d = 2001-02-29\n", c"invalid date or time")
	ti(c"d = 1900-02-29\n", c"invalid date or time")
	ti(c"d = 1979-04-31\n", c"invalid date or time")
	ti(c"d = 1979-05-00\n", c"invalid date or time")
	ti(c"d = 1979-5-27\n", c"invalid date or time")
	ti(c"d = 1979-05-27T25:00:00\n", c"invalid date or time")
	ti(c"d = 1979-05-27T07:60:00\n", c"invalid date or time")
	ti(c"d = 1979-05-27T07:32:61\n", c"invalid date or time")
	ti(c"d = 1979-05-27T07:32\n", c"invalid date or time")
	ti(c"t = 07:32\n", c"invalid date or time")
	ti(c"t = 7:32:00\n", c"invalid number")
	ti(c"t = 07:32:00Z\n", c"invalid date or time")
	ti(c"t = 07:32:00+01:00\n", c"invalid date or time")
	ti(c"d = 1979-05-27T07:32:00+7:00\n", c"invalid date or time")
	ti(c"d = 1979-05-27T07:32:00+07:60\n", c"invalid date or time")
	ti(c"d = 1979-05-27T07:32:00+0700\n", c"invalid date or time")
	ti(c"d = 1979-05-27T07:32:00.\n", c"invalid date or time")
	ti(c"d = 1979-05-27X07:32:00\n", c"invalid date or time")
	ti(c"d = 1979-05-27T\n", c"invalid date or time")
	ti(c"d = 1979-05-27 07:32\n", c"invalid date or time")
	ti(c"d = 1979-05-27T07:32:00Zx\n", c"invalid date or time")


void test_invalid_tables():
	ti(c"[a\nb = 1\n", c"expected ']'")
	ti(c"[]\n", c"expected a key")
	ti(c"[a.]\n", c"expected a key")
	ti(c"[ [a] ]\n", c"expected a key")
	ti(c"[[a]\n", c"expected ']]'")
	ti(c"[[a] ]\n", c"expected ']]'")
	ti(c"[a] b = 1\n", c"expected a newline after table header")
	ti(c"[a]]\n", c"expected a newline after table header")


void test_invalid_encoding_and_whitespace():
	ti_at(c"a = 1\nb = \"\xff\"\n", c"line 2, column 6: invalid UTF-8")
	ti(c"a = \"\xc0\x80\"\n", c"invalid UTF-8")
	ti(c"a = \"\xed\xa0\x80\"\n", c"invalid UTF-8")
	ti(c"a = \"\xe2\x82\"\n", c"invalid UTF-8")
	ti(c"a = \"\xf4\x90\x80\x80\"\n", c"invalid UTF-8")
	ti(c"a = 1\rb = 2\n", c"bare carriage return")
	ti(c"a = 1 # comment\x01\n", c"control character in comment")
	ti(c"a = 1 # comment\x7f\n", c"control character in comment")
	ti(c"a = 1\r", c"bare carriage return")


void test_error_positions():
	ti_at(c"a = 1\nb = \"x\\q\"\n", c"line 2, column 7: invalid escape sequence")
	ti_at(c"s = \"ééé\\q\"\n", c"line 1, column 9: invalid escape sequence")
	ti_at(c"\n\n  [a]\n  [a]\n", c"line 4, column 3: table redefined")
	ti_at(c"x = {a = 1}\nx.b = 2\n", c"line 2, column 1: dotted key cannot extend a table defined elsewhere")
	ti_at(c"n = 0x\n", c"line 1, column 5: invalid number")
	ti_at(c"s = \"open\n", c"line 1, column 5: unterminated string")
	toml_doc* doc = toml_parse(c"a = 1\nb = 1979-02-30\n")
	assert_equal(0, cast(int, doc.root))
	assert_equal(2, doc.line)
	assert_equal(5, doc.column)
	toml_doc_free(doc)


void test_nesting_limit():
	string_builder* sb = string_new()
	string_append(sb, c"a = ")
	for i in range(200): string_append_char(sb, '[')
	for k in range(200): string_append_char(sb, ']')
	string_append_char(sb, '\n')
	ti(sb.data, c"nesting too deep")
	string_free(sb)


# ---- API ----------------------------------------------------------------

void test_get_and_loads():
	json_value* root = toml_loads(c"title = \"TOML\"\n[owner]\nname = \"Tom\"\n[servers.\"alpha.1\"]\nip = \"10.0.0.1\"\nports = [8000, 8001]\n")
	assert1(root != 0)
	assert_equal(json_type_object(), root.type)
	assert_strings_equal(c"TOML", toml_get(root, c"title").string_value)
	assert_strings_equal(c"Tom", toml_get(root, c"owner.name").string_value)
	assert_strings_equal(c"10.0.0.1", toml_get(root, c"servers.\"alpha.1\".ip").string_value)
	assert_strings_equal(c"10.0.0.1", toml_get(root, c" servers . 'alpha.1' . ip ").string_value)
	json_value* ports = toml_get(root, c"servers.\"alpha.1\".ports")
	assert_equal(2, json_array_length(ports))
	assert_equal(8001, json_array_get(ports, 1).int_value)
	json_value* owner = toml_get(root, c"owner")
	assert_strings_equal(c"Tom", toml_get(owner, c"name").string_value)
	assert_equal(0, cast(int, toml_get(root, c"missing")))
	assert_equal(0, cast(int, toml_get(root, c"title.x")))
	assert_equal(0, cast(int, toml_get(root, c"owner.")))
	assert_equal(0, cast(int, toml_get(root, c"")))
	assert_equal(0, cast(int, toml_get(0, c"a")))
	# the tree is an ordinary json tree: json_stringify walks it
	char* text = json_stringify(toml_get(root, c"servers"))
	assert_strings_equal(c"{\"alpha.1\":{\"ip\":\"10.0.0.1\",\"ports\":[8000,8001]}}", text)
	free(text)
	# no parse-time flags leak into the returned tree
	assert_equal(0, root.int_value)
	assert_equal(0, ports.int_value)
	json_free(root)
	assert_equal(0, cast(int, toml_loads(c"a = \n")))


void test_doc_take_root():
	toml_doc* doc = toml_parse(c"a = 1\n")
	assert_equal(0, cast(int, doc.error))
	json_value* root = toml_doc_take_root(doc)
	assert_equal(0, cast(int, doc.root))
	toml_doc_free(doc)
	assert_equal(1, toml_get(root, c"a").int_value)
	json_free(root)
	toml_doc_free(0)


void test_types_distinct():
	json_value* root = toml_loads(c"i = 1\nf = 1.0\nb = true\ns = \"1\"\n")
	assert_equal(json_type_int(), toml_get(root, c"i").type)
	assert_equal(json_type_float(), toml_get(root, c"f").type)
	assert_equal(json_type_bool(), toml_get(root, c"b").type)
	assert_equal(json_type_string(), toml_get(root, c"s").type)
	json_free(root)
