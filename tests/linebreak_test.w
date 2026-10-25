# wbuild: x64 deps=tests/data/linebreak_sample.txt
# lib/linebreak.w (UAX #14) against a sample of the Unicode LineBreakTest
# file, plus the property table, the UTF-8 helper and the CJK, East Asian
# and Southeast Asian tailorings.
import lib.testing
import lib.linebreak
import tools.linebreak_conformance_lib

void test_linebreak_sample():
	int total = 0
	int failures = lb_conf_file(c"tests/data/linebreak_sample.txt", lb_tailor_default, 1, &total)
	assert_equal(0, failures)
	asserts(c"sample has test lines", total > 1400)

void test_line_break_properties():
	assert_equal(lb_class_al, lb_class('a'))
	assert_equal(lb_class_sp, lb_class(' '))
	assert_equal(lb_class_lf, lb_class(10))
	assert_equal(lb_class_op, lb_class('('))
	assert_equal(lb_class_cj, lb_class(0x3041))
	assert_equal(lb_class_id, lb_class(0x4e00))
	assert_equal(lb_class_hl, lb_class(0x05d0))
	assert_equal(lb_class_sa, lb_class(0x0e01))
	# SA marks already read as CM (rule LB1).
	assert_equal(lb_class_cm, lb_class(0x0e31))
	assert_equal(lb_class_ai, lb_class(0x00a7))
	# Unassigned defaults: ID in Plane 2, PR among the currency symbols,
	# XX elsewhere.
	assert_equal(lb_class_id, lb_class(0x2fffd))
	assert_equal(lb_class_pr, lb_class(0x20cf))
	assert_equal(lb_class_xx, lb_class(0x0378))
	assert_equal(lb_class_xx, lb_class(0x10ffff + 1))
	# The LB30 and LB30b flags.
	asserts(c"fullwidth ( is wide", (lb_property(0xff08) & lb_flag_wide) != 0)
	asserts(c"ASCII ( is not wide", (lb_property('(') & lb_flag_wide) == 0)
	asserts(c"unassigned pictographic", (lb_property(0x1fffd) & lb_flag_pictographic) != 0)
	asserts(c"assigned emoji is not flagged", (lb_property(0x1f600) & lb_flag_pictographic) == 0)

# The break actions of cps[0, count) under flags, as a string of
# '-' (sot), 'x', '/' and '!' (count + 1 characters).
char* actions(int32* cps, int count, int flags):
	char* breaks = cast(char*, malloc(count + 1))
	lb_breaks(cps, count, flags, breaks)
	char* out = cast(char*, malloc(count + 2))
	for i in range(count + 1):
		out[i] = 'x'
		if (breaks[i] == lb_break_allowed): out[i] = '/'
		if (breaks[i] == lb_break_mandatory): out[i] = '!'
	out[count + 1] = 0
	free(breaks)
	return out

void expect_actions(char* want, int flags, int a, int b):
	int32[2] cps
	cps[0] = a
	cps[1] = b
	char* got = actions(&cps[0], 2, flags)
	assert_strings_equal(want, got)
	free(got)

void test_cjk_tailoring():
	# Small kana (CJ): kinsoku by default, a break with cjk_normal.
	expect_actions(c"xx!", lb_tailor_default, 0x3042, 0x3041)
	expect_actions(c"x/!", lb_tailor_cjk_normal, 0x3042, 0x3041)
	expect_actions(c"x/!", lb_tailor_cjk_loose, 0x3042, 0x3041)
	# The iteration mark (NS) only breaks with cjk_loose.
	expect_actions(c"xx!", lb_tailor_cjk_normal, 0x3042, 0x3005)
	expect_actions(c"x/!", lb_tailor_cjk_loose, 0x3042, 0x3005)
	# Ideographs break between each other; a closing bracket (CL) never
	# starts a line and an opening one (OP) never ends one.
	expect_actions(c"x/!", lb_tailor_default, 0x4e00, 0x4e01)
	expect_actions(c"xx!", lb_tailor_cjk_loose, 0x4e00, 0x3001)
	expect_actions(c"xx!", lb_tailor_cjk_loose, 0x300c, 0x4e00)

void test_east_asian_ambiguous():
	expect_actions(c"xx!", lb_tailor_default, 0x00a7, 0x00a7)
	expect_actions(c"x/!", lb_tailor_east_asian, 0x00a7, 0x00a7)

void test_southeast_asian_clusters():
	# Thai has no breaks inside a run of letters by default (no
	# dictionary), and breaks between clusters with sa_clusters.
	expect_actions(c"xx!", lb_tailor_default, 0x0e01, 0x0e02)
	expect_actions(c"x/!", lb_tailor_sa_clusters, 0x0e01, 0x0e02)
	# Never inside a cluster: before a mark or SARA AM, after a prepended
	# vowel, or after a Khmer coeng.
	expect_actions(c"xx!", lb_tailor_sa_clusters, 0x0e01, 0x0e31)
	expect_actions(c"xx!", lb_tailor_sa_clusters, 0x0e01, 0x0e33)
	expect_actions(c"xx!", lb_tailor_sa_clusters, 0x0e40, 0x0e01)
	int32[4] cps
	cps[0] = 0x1780
	cps[1] = 0x17d2
	cps[2] = 0x1780
	cps[3] = 0x1781
	char* got = actions(&cps[0], 4, lb_tailor_sa_clusters)
	assert_strings_equal(c"xxx/!", got)
	free(got)
	# Latin next to Thai still follows the default rules.
	expect_actions(c"xx!", lb_tailor_sa_clusters, 'a', 0x0e01)

void test_utf8_and_hard_breaks():
	char* text = c"ab cd\nef"
	char* breaks = cast(char*, malloc(9))
	assert_equal(8, lb_breaks_utf8(text, 8, lb_tailor_default, breaks))
	assert_equal(lb_break_none, breaks[0])
	assert_equal(lb_break_none, breaks[2])
	assert_equal(lb_break_allowed, breaks[3])
	assert_equal(lb_break_none, breaks[5])
	assert_equal(lb_break_mandatory, breaks[6])
	assert_equal(lb_break_mandatory, breaks[8])
	# Bytes inside a character are never breaks.
	text = c"\xe4\xb8\x80\xe4\xb8\x81"
	assert_equal(2, lb_breaks_utf8(text, 6, lb_tailor_default, breaks))
	assert_equal(lb_break_none, breaks[1])
	assert_equal(lb_break_none, breaks[2])
	assert_equal(lb_break_allowed, breaks[3])
	assert_equal(lb_break_mandatory, breaks[6])
	assert_equal(0, lb_breaks_utf8(c"", 0, lb_tailor_default, breaks))
	assert_equal(lb_break_none, breaks[0])
	free(breaks)
