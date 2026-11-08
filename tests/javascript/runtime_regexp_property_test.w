# wbuild: name=javascript_runtime_regexp_property_test
# wbuild: target=javascript_runtime_regexp_property_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_regexp_property_test.w -o bin/javascript_runtime_regexp_property_test"
# wbuild: step="bin/javascript_runtime_regexp_property_test" expect_stdout="javascript_runtime_regexp_property_test: OK"
# wbuild: step="bin/javascript_runtime_regexp_property_test memory" expect_stdout="javascript_runtime_regexp_property_test: OK"
# wbuild: step="python3 tools/javascript_regexp_property.py --check"
# wbuild: step="python3 tools/javascript_regexp_property.py --verify bin/javascript_runtime_regexp_property_test"
# RegExp \p{...} / \P{...} matching against the Unicode 12.1 tables
# (reardan/w#901). `dump SCRIPTS` prints every table for the generator's
# exhaustive --verify comparison with the vendored UCD files.
import lib.assert
import lib.args
import lib.stream
import libs.extras.javascript.runtime


void property_true(js_runtime* rt, char* body):
	char* opened = strjoin(c"{ ", body)
	char* source = strjoin(opened, c" }")
	free(opened)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 0 || result.value.kind != 2 || result.value.number != 1.0):
		println2(source)
		println2(result.message)
	assert_equal(0, result.status)
	assert1(result.value.number == 1.0)
	free(source)


int property_status(js_runtime* rt, char* source):
	return js_runtime_eval(rt, source, strlen(source), 100000).status


void test_general_category():
	js_runtime* rt = js_runtime_new()
	property_true(rt, c"/^\\p{Lu}+$/u.test('A\\u00c0\\u0391\\u{10400}') && !/\\p{Lu}/u.test('a') && /\\p{Ll}/u.test('\\u00df') && /\\p{gc=Lt}/u.test('\\u01c5');")
	property_true(rt, c"/^\\p{L}+$/u.test('a\\u4e00\\u02b0\\u01c5') && /^\\p{Letter}+$/u.test('Z') && /^\\p{LC}+$/u.test('aA\\u01c5') && !/\\p{LC}/u.test('\\u4e00');")
	property_true(rt, c"/\\p{General_Category=Decimal_Number}/u.test('\\u0663') && /\\p{digit}/u.test('7') && /\\p{Nl}/u.test('\\u2160') && /\\p{No}/u.test('\\u00bd') && /\\p{N}/u.test('\\u00bd');")
	property_true(rt, c"/\\p{punct}/u.test('!') && /\\p{Pd}/u.test('-') && /\\p{Ps}/u.test('(') && /\\p{Pe}/u.test(')') && /\\p{Pi}/u.test('\\u00ab') && /\\p{Pf}/u.test('\\u00bb') && /\\p{Pc}/u.test('_');")
	property_true(rt, c"/\\p{Sm}/u.test('+') && /\\p{Sc}/u.test('$') && /\\p{Sk}/u.test('^') && /\\p{So}/u.test('\\u00a9') && /\\p{S}/u.test('+') && /\\p{Zs}/u.test(' ') && /\\p{Zl}/u.test('\\u2028') && /\\p{Zp}/u.test('\\u2029');")
	property_true(rt, c"/\\p{Cc}/u.test('\\n') && /\\p{cntrl}/u.test('\\x7f') && /\\p{Cf}/u.test('\\u200b') && /\\p{Co}/u.test('\\ue000') && /\\p{Cs}/u.test('\\ud800') && /\\p{Cn}/u.test('\\u0378') && /\\p{C}/u.test('\\u{10FFFF}');")
	property_true(rt, c"/\\p{Mn}/u.test('\\u0301') && /\\p{Mc}/u.test('\\u0903') && /\\p{Me}/u.test('\\u20dd') && /\\p{Combining_Mark}/u.test('\\u0301') && /\\p{Z}/u.test('\\u3000') && !/\\p{Z}/u.test('\\t');")
	# Unicode 12.1 is the pinned version: U+1FAD0 (assigned in 13.0) is still unassigned.
	property_true(rt, c"/\\p{Cn}/u.test('\\u{1FAD0}') && !/\\p{Assigned}/u.test('\\u{1FAD0}') && /\\p{Assigned}/u.test('\\u{1FA70}') && /\\p{So}/u.test('\\u{1FA70}');")
	js_runtime_free(rt)


void test_scripts():
	js_runtime* rt = js_runtime_new()
	property_true(rt, c"/^\\p{Script=Greek}+$/u.test('\\u03b1\\u03c9') && /\\p{sc=Grek}/u.test('\\u1f00') && !/\\p{sc=Greek}/u.test('a') && /\\p{Script=Latin}/u.test('a') && /\\p{sc=Han}/u.test('\\u4e00');")
	property_true(rt, c"/\\p{sc=Zyyy}/u.test('1') && /\\p{sc=Common}/u.test('\\u0964') && /\\p{sc=Inherited}/u.test('\\u0301') && /\\p{sc=Qaai}/u.test('\\u0301') && /\\p{sc=Zzzz}/u.test('\\u0378') && /\\p{sc=Unknown}/u.test('\\u{10FFFF}');")
	property_true(rt, c"/\\p{sc=Copt}/u.test('\\u2c80') && /\\p{sc=Qaac}/u.test('\\u2c80') && /\\p{Script=Gothic}/u.test('\\u{10330}') && /\\p{sc=Elym}/u.test('\\u{10FE0}') && /\\p{sc=Wancho}/u.test('\\u{1E2C0}');")
	# Script_Extensions: U+0964 DEVANAGARI DANDA is Common with extensions.
	property_true(rt, c"/\\p{scx=Deva}/u.test('\\u0964') && /\\p{Script_Extensions=Bengali}/u.test('\\u0964') && !/\\p{sc=Deva}/u.test('\\u0964') && /\\p{scx=Latn}/u.test('a') && !/\\p{scx=Grek}/u.test('a');")
	property_true(rt, c"/\\p{scx=Hira}/u.test('\\u30fc') && /\\p{scx=Kana}/u.test('\\u30fc') && !/\\p{scx=Zyyy}/u.test('\\u30fc') && /\\p{sc=Zyyy}/u.test('\\u30fc');")
	# 12.1 lists no extensions for U+0300 (later versions add Latin, Greek, ...).
	property_true(rt, c"/\\p{scx=Zinh}/u.test('\\u0300') && !/\\p{scx=Latn}/u.test('\\u0300');")
	property_true(rt, c"/\\P{scx=Arab}/u.test('a') && !/\\P{scx=Arab}/u.test('\\u060c') && /[\\p{scx=Syrc}]/u.test('\\u060c') && /\\p{scx=Zzzz}/u.test('\\u0378');")
	js_runtime_free(rt)


void test_binary():
	js_runtime* rt = js_runtime_new()
	property_true(rt, c"/\\p{ASCII}+/u.exec('abc\\u00e9')[0] === 'abc' && /\\P{ASCII}/u.exec('abc\\u00e9')[0] === '\\u00e9' && /\\p{Any}/u.test('\\u{10FFFF}') && /[\\P{Any}]/u.test('a') === false;")
	property_true(rt, c"/\\p{ID_Start}\\p{IDC}*/u.exec('1abc2 x')[0] === 'abc2' && /\\p{AHex}+/u.exec('xyzBEEFg')[0] === 'BEEF' && /\\p{IDS}/u.test('\\u{10400}') && !/\\p{ASCII_Hex_Digit}/u.test('g');")
	property_true(rt, c"/\\p{Alphabetic}/u.test('\\u0345') && /\\p{Alpha}/u.test('a') && !/\\p{Alpha}/u.test('1') && /\\p{White_Space}/u.test('\\u0085') && /\\p{space}/u.test('\\u3000') && !/\\p{space}/u.test('\\u200b');")
	property_true(rt, c"/\\p{Lowercase}/u.test('\\u00aa') && /\\p{Upper}/u.test('\\u2160') && /\\p{Cased}/u.test('\\u01c5') && /\\p{CI}/u.test('\\u0027') && /\\p{Math}/u.test('\\u2200') && /\\p{Dash}/u.test('\\u2014');")
	property_true(rt, c"/\\p{CWCF}/u.test('A') && !/\\p{CWCF}/u.test('a') && /\\p{CWCM}/u.test('a') && /\\p{CWL}/u.test('A') && /\\p{CWU}/u.test('a') && /\\p{CWT}/u.test('\\u01c4') && /\\p{CWKCF}/u.test('\\u00a0') && !/\\p{CWKCF}/u.test('a');")
	property_true(rt, c"/\\p{XIDS}/u.test('a') && !/\\p{XIDS}/u.test('\\u037a') && /\\p{IDS}/u.test('\\u037a') && /\\p{XIDC}/u.test('\\u00b7') && /\\p{DI}/u.test('\\u00ad') && /\\p{Gr_Base}/u.test('a') && /\\p{Gr_Ext}/u.test('\\u0301');")
	property_true(rt, c"/\\p{Emoji}/u.test('\\u{1F600}') && /\\p{Emoji}/u.test('#') && /\\p{Emoji_Presentation}/u.test('\\u{1F600}') && /\\p{Emoji_Modifier}/u.test('\\u{1F3FB}') && /\\p{Emoji_Modifier_Base}/u.test('\\u{1F44D}');")
	property_true(rt, c"/\\p{Emoji_Component}/u.test('\\u200d') && /\\p{Extended_Pictographic}/u.test('\\u00a9') && /\\p{RI}/u.test('\\u{1F1E6}') && /\\p{Ideo}/u.test('\\u4e00') && /\\p{UIdeo}/u.test('\\u4e00') && /\\p{Radical}/u.test('\\u2e80');")
	property_true(rt, c"/\\p{Bidi_M}/u.test('(') && /\\p{Bidi_C}/u.test('\\u200e') && /\\p{Join_C}/u.test('\\u200d') && /\\p{Dep}/u.test('\\u0149') && /\\p{Dia}/u.test('^') && /\\p{Ext}/u.test('\\u00b7') && /\\p{Hex}/u.test('\\uff21');")
	property_true(rt, c"/\\p{IDSB}/u.test('\\u2ff0') && /\\p{IDST}/u.test('\\u2ff2') && /\\p{LOE}/u.test('\\u0e40') && /\\p{NChar}/u.test('\\ufffe') && /\\p{Pat_Syn}/u.test('!') && /\\p{Pat_WS}/u.test(' ') && /\\p{QMark}/u.test('\"');")
	property_true(rt, c"/\\p{STerm}/u.test('.') && /\\p{SD}/u.test('i') && /\\p{Term}/u.test(',') && /\\p{VS}/u.test('\\ufe0f') && /\\p{Assigned}/u.test('a') && !/\\p{Assigned}/u.test('\\u0378');")
	js_runtime_free(rt)


void test_forms():
	js_runtime* rt = js_runtime_new()
	# Outside and inside classes, negated, in ranges' neighbours and with i.
	property_true(rt, c"/[\\p{Nd}x]/u.test('x') && /[\\p{Nd}x]/u.test('\\u0663') && !/[^\\p{Nd}]/u.test('5') && /[^\\P{Nd}]/u.test('5') && /[\\P{L}]/u.test('1') && !/[\\P{L}]/u.test('a');")
	property_true(rt, c"/[a-c\\p{sc=Greek}]+/u.exec('zab\\u03b1d')[0] === 'ab\\u03b1' && /[\\p{Lu}\\p{Nd}]+/u.exec('aB9c')[0] === 'B9' && /\\P{Lu}+/u.exec('ABcdE')[0] === 'cd';")
	property_true(rt, c"/\\p{Lu}/ui.test('a') && /\\p{Ll}/ui.test('A') && /\\P{Lu}/ui.test('A') && /[^\\p{Lu}]/ui.test('1') && !/[^\\p{Lu}]/ui.test('a') && /\\p{Lu}/ui.test('\\u017f');")
	property_true(rt, c"/^\\p{L}$/u.test('\\u{10400}') && !/^\\p{L}$/u.test('\\ud801') && /^\\p{Cs}$/u.test('\\ud801') && /(?<=\\p{sc=Greek})x/u.test('\\u03b1x') && /\\p{L}(?=\\p{N})/u.exec('ab1')[0] === 'b';")
	# Without u, \\p and \\P are identity escapes (Annex B).
	property_true(rt, c"/\\p{L}/.test('p{L}') && !/\\p{L}/.test('a') && /[\\p{L}]/.test('{') && /\\P/.test('P') && /^[\\p]$/.test('p') && new RegExp('\\\\p{Lu}').test('p{Lu}');")
	property_true(rt, c"new RegExp('\\\\p{Lu}', 'u').test('A') && new RegExp('[\\\\P{Script=Latin}]', 'u').test('1') && new RegExp('\\\\p{scx=Deva}', 'u').test('\\u0964');")
	# Names are validated against 12.1 too: Kawi (Unicode 15) is a SyntaxError.
	property_true(rt, c"let n = ''; try { new RegExp('\\\\p{Script=Kawi}', 'u') } catch (e) { n = e.name } n === 'SyntaxError';")
	# Every validated property now has data: none is unsupported.
	assert_equal(0, property_status(rt, c"/\\p{Lu}/u; /\\p{Script=Greek}/u; /\\p{scx=Deva}/u; new RegExp('\\\\p{Lu}', 'u');"))
	js_runtime_free(rt)


int dump_has(int kind, int id, int cp):
	return js_regexp_property_has(kind, id, cp)


# Tables as the generator's --verify mode expects them (see its expected_dump).
void dump(int scripts):
	string_builder* out = string_new()
	string_append(out, c"gc\n")
	int previous = -1
	for cp in range(1114112):
		int value = js_regexp_property_gc(cp)
		if (value != previous):
			string_append_int(out, cp)
			string_append_char(out, ' ')
			string_append_int(out, value)
			string_append_char(out, 10)
			previous = value
	string_append(out, c"sc\n")
	previous = -1
	for cp in range(1114112):
		int value = js_regexp_property_script(cp)
		if (value != previous):
			string_append_int(out, cp)
			string_append_char(out, ' ')
			string_append_int(out, value)
			string_append_char(out, 10)
			previous = value
	string_append(out, c"scx\n")
	string_builder* line = string_new()
	wstream* input = stdin_reader()
	while (stream_read_line(input, line)):
		int cp = atoi(line.data)
		string_append_int(out, cp)
		for id in range(scripts):
			if (dump_has(JS_RX_PROPERTY_SCX, id, cp)):
				string_append_char(out, ' ')
				string_append_int(out, id)
		string_append_char(out, 10)
	string_free(line)
	for id in range(53):
		string_append(out, c"binary ")
		string_append_int(out, id)
		string_append_char(out, 10)
		int inside = 0
		for cp in range(1114112):
			int has = dump_has(JS_RX_PROPERTY_BINARY, id, cp) != 0
			if (has != inside):
				string_append_int(out, cp)
				string_append_char(out, 10)
				inside = has
	write(1, out.data, out.length)
	string_free(out)


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc == 3 && strcmp(args_get(1), c"dump") == 0):
		dump(atoi(args_get(2)))
		return 0
	if (argc > 1): malloc_force_debug_mode()
	test_general_category()
	test_scripts()
	test_binary()
	test_forms()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_regexp_property_test: OK")
	return 0
