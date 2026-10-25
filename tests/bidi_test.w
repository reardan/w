# wbuild: x64 deps=tests/data/bidi_character_sample.txt
# lib/bidi.w (UAX #9) against a sample of the Unicode BidiCharacterTest
# file, plus direct checks of the property tables and the line rules.
import lib.testing
import lib.bidi
import tools.bidi_conformance_lib

void test_bidi_character_sample():
	int total = 0
	int failures = bidi_conf_file(c"tests/data/bidi_character_sample.txt", 1, &total)
	assert_equal(0, failures)
	asserts(c"sample has test lines", total > 600)

void test_unicode_text_properties():
	assert_equal(ut_bidi_l, ut_bidi_class('a'))
	assert_equal(ut_bidi_r, ut_bidi_class(0x05d0))
	assert_equal(ut_bidi_al, ut_bidi_class(0x0627))
	assert_equal(ut_bidi_en, ut_bidi_class('7'))
	assert_equal(ut_bidi_an, ut_bidi_class(0x0661))
	assert_equal(ut_bidi_nsm, ut_bidi_class(0x0301))
	assert_equal(ut_bidi_ws, ut_bidi_class(' '))
	assert_equal(ut_bidi_rli, ut_bidi_class(0x2067))
	# @missing defaults: unassigned Hebrew-block, Arabic-block and
	# currency-block codepoints, and noncharacters.
	assert_equal(ut_bidi_r, ut_bidi_class(0x05ff))
	assert_equal(ut_bidi_al, ut_bidi_class(0x07bf))
	assert_equal(ut_bidi_et, ut_bidi_class(0x20cf))
	assert_equal(ut_bidi_bn, ut_bidi_class(0xfdd0))
	assert_equal(ut_bidi_l, ut_bidi_class(0x10ffff + 1))
	int partner = 0
	assert_equal(1, ut_bracket('(', &partner))
	assert_equal(')', partner)
	assert_equal(2, ut_bracket(']', &partner))
	assert_equal('[', partner)
	assert_equal(0, ut_bracket('a', &partner))
	assert_equal(ut_bracket_canonical(0x3009), ut_bracket_canonical(0x232a))
	assert_equal(')', ut_mirror('('))
	assert_equal(0x2265, ut_mirror(0x2264))
	assert_equal('a', ut_mirror('a'))
	assert_equal(ut_join_d, ut_joining_type(0x0628))
	assert_equal(ut_join_r, ut_joining_type(0x0627))
	assert_equal(ut_join_u, ut_joining_type(0x0621))
	assert_equal(ut_join_t, ut_joining_type(0x064e))
	assert_equal(ut_join_c, ut_joining_type(0x200d))
	assert_equal(ut_join_u, ut_joining_type('a'))
	assert_bytes_equal(c"Latn", ut_script_code(ut_script('a')), 4)
	assert_bytes_equal(c"Arab", ut_script_code(ut_script(0x0628)), 4)
	assert_bytes_equal(c"Hebr", ut_script_code(ut_script(0x05d0)), 4)
	assert_bytes_equal(c"Deva", ut_script_code(ut_script(0x0915)), 4)
	assert_bytes_equal(c"Zyyy", ut_script_code(ut_script(' ')), 4)
	assert_bytes_equal(c"Zinh", ut_script_code(ut_script(0x0301)), 4)
	assert_bytes_equal(c"Zzzz", ut_script_code(ut_script(0x0378)), 4)
	assert_equal(ut_script('b'), ut_script_from_code(c"Latn"))
	assert_equal(-1, ut_script_from_code(c"Qqqq"))
	assert1(ut_script_is_shared(ut_script('1')))
	assert1(!ut_script_is_shared(ut_script('a')))

void test_bidi_resolve_and_reorder():
	# "car is ARABIC" in an auto paragraph: LTR, the Arabic word reversed.
	int32[12] cps
	char* text = c"car is "
	for i in range(7): cps[i] = text[i]
	for i in range(5): cps[7 + i] = 0x0627 + i
	char[12] classes
	char[12] levels
	assert_equal(0, bidi_resolve(&cps[0], 12, -1, &classes[0], &levels[0]))
	for i in range(7): assert_equal(0, levels[i])
	for i in range(7, 12): assert_equal(1, levels[i])
	int32[12] order
	bidi_reorder(&levels[0], 12, &order[0])
	for i in range(7): assert_equal(i, order[i])
	for i in range(5): assert_equal(11 - i, order[7 + i])
	# L1 resets whitespace and isolate controls at the end of a line: the
	# space inside the trailing LRI isolate drops to the paragraph level.
	cps[0] = 0x05d0
	cps[1] = 0x2066
	cps[2] = 'a'
	cps[3] = ' '
	cps[4] = 0x2069
	assert_equal(1, bidi_resolve(&cps[0], 5, -1, &classes[0], &levels[0]))
	assert_equal(2, levels[3])
	bidi_line_levels(&classes[0], &levels[0], 5, 1)
	assert_equal(2, levels[2])
	assert_equal(1, levels[3])
	assert_equal(1, levels[4])
	bidi_reorder(&levels[0], 5, &order[0])
	for i in range(5): assert_equal(4 - i, order[i])
	# An explicit base overrides first-strong detection; empty input works.
	assert_equal(1, bidi_resolve(&cps[0], 0, 1, &classes[0], &levels[0]))
	assert_equal(0, bidi_resolve(&cps[0], 0, -1, &classes[0], &levels[0]))
