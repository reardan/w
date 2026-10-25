# The Unicode Line Breaking Algorithm (UAX #14, Unicode 15.0.0) in W, with
# no native dependency (issue #826). graphics/ui/itemize.w uses it to wrap
# paragraphs; any program can call it directly.
#
#	char* breaks = cast(char*, malloc(count + 1))
#	lb_breaks(cps, count, lb_tailor_default, breaks)
#	# breaks[i] is the action between cps[i - 1] and cps[i]
#
# Rules LB1-LB31 of https://www.unicode.org/reports/tr14/ over the
# Line_Break table of lib/linebreak_data.w (a build output of
# tools/generate_linebreak_data.w). Numbers use the regular-expression
# LB25 of UAX #14 section 8.2 Example 7, as LineBreakTest.txt does, and
# pass all of its 7,654 lines with the default tailoring
# (bin/linebreak_conformance; tests/linebreak_test.w runs a sample).
#
# Tailorings (flags, combined with |):
#   lb_tailor_cjk_normal  CJ (small kana, the prolonged sound mark) resolves
#                         to ID instead of NS, so a line may start with
#                         them: CSS line-break: normal. Without it the
#                         default is strict kinsoku: NS, CL, CP, EX, IS and
#                         the like never start a line, OP never ends one.
#   lb_tailor_cjk_loose   cjk_normal, and NS (iteration marks, the
#                         katakana middle dot, ...) resolves to ID too:
#                         CSS line-break: loose.
#   lb_tailor_east_asian  AI (ambiguous width) resolves to ID instead of
#                         AL, for text in an East Asian context.
#   lb_tailor_sa_clusters Southeast Asian (SA) text breaks between its
#                         clusters. Thai, Lao, Khmer, Myanmar and the other
#                         SA scripts need a dictionary to find words; none
#                         is shipped, so by default (rule LB1) SA text is
#                         AL and only breaks where its spaces and
#                         punctuation allow. With this flag a break is also
#                         allowed between two SA letters, except inside a
#                         cluster: never before a combining mark (SA Mn/Mc
#                         are CM), a Thai/Lao SARA AM or MAI YAMOK-style
#                         repetition mark, never after a stacking virama
#                         or coeng, and never after a prepended (logical
#                         order exception) vowel.
import lib.lib
import lib.utf8
import lib.unicode_text
import lib.linebreak_data

# Line_Break classes, in tools/generate_linebreak_data.w order.
const int lb_class_xx = 0
const int lb_class_bk = 1
const int lb_class_cr = 2
const int lb_class_lf = 3
const int lb_class_cm = 4
const int lb_class_nl = 5
const int lb_class_sg = 6
const int lb_class_wj = 7
const int lb_class_zw = 8
const int lb_class_gl = 9
const int lb_class_sp = 10
const int lb_class_zwj = 11
const int lb_class_b2 = 12
const int lb_class_ba = 13
const int lb_class_bb = 14
const int lb_class_hy = 15
const int lb_class_cb = 16
const int lb_class_cl = 17
const int lb_class_cp = 18
const int lb_class_ex = 19
const int lb_class_in = 20
const int lb_class_ns = 21
const int lb_class_op = 22
const int lb_class_qu = 23
const int lb_class_is = 24
const int lb_class_nu = 25
const int lb_class_po = 26
const int lb_class_pr = 27
const int lb_class_sy = 28
const int lb_class_ai = 29
const int lb_class_ak = 30
const int lb_class_al = 31
const int lb_class_ap = 32
const int lb_class_as = 33
const int lb_class_cj = 34
const int lb_class_eb = 35
const int lb_class_em = 36
const int lb_class_h2 = 37
const int lb_class_h3 = 38
const int lb_class_hl = 39
const int lb_class_id = 40
const int lb_class_jl = 41
const int lb_class_jv = 42
const int lb_class_jt = 43
const int lb_class_ri = 44
const int lb_class_sa = 45
const int lb_class_vf = 46
const int lb_class_vi = 47

# Break actions: breaks[i] is the action before character i.
const int lb_break_none = 0         # x: no break
const int lb_break_allowed = 1      # a break opportunity
const int lb_break_mandatory = 2    # a hard break (after BK, CR, LF, NL)

const int lb_tailor_default = 0
const int lb_tailor_cjk_normal = 1
const int lb_tailor_cjk_loose = 2
const int lb_tailor_east_asian = 4
const int lb_tailor_sa_clusters = 8

# Property-value flags of the generated table.
const int lb_flag_wide = 64           # an OP or CP with East_Asian_Width F, W or H
const int lb_flag_pictographic = 128  # an unassigned Extended_Pictographic code point

# The Line_Break property of cp as generated: the class with the two
# flags above. SA marks (Mn, Mc) already read as CM.
int lb_property(int cp):
	return ut_range_value(lbd_classes(), lbd_classes_count(), cp)

# The Line_Break class of cp (lb_class_*), before rule LB1's resolution.
int lb_class(int cp):
	return lb_property(cp) & 63

# One unit of rule LB9: a base character and the combining marks and
# joiners that attach to it.
struct lb_units:
	int count
	int32* start      # first character index
	char* cls         # resolved class (LB1, LB10)
	char* last        # original class of the last character (ZWJ for LB8a)
	char* flags       # the generated flags of the base
	char* sa          # the base was SA before LB1
	int32* base_cp
	int32* last_cp

# Rule LB1 with the tailorings: the class a character takes part in the
# rules with. sa receives whether it was SA.
int lb_resolve(int property, int flags, int* sa):
	int c = property & 63
	sa[0] = 0
	if (c == lb_class_ai):
		if (flags & lb_tailor_east_asian): return lb_class_id
		return lb_class_al
	if ((c == lb_class_sg) || (c == lb_class_xx)): return lb_class_al
	if (c == lb_class_sa):
		sa[0] = 1
		return lb_class_al
	if (c == lb_class_cj):
		if (flags & (lb_tailor_cjk_normal | lb_tailor_cjk_loose)): return lb_class_id
		return lb_class_ns
	if ((c == lb_class_ns) && (flags & lb_tailor_cjk_loose)): return lb_class_id
	return c

int lb_is_hard(int c):
	return (c == lb_class_bk) || (c == lb_class_cr) || (c == lb_class_lf) || (c == lb_class_nl)

# Rules LB9 and LB10: group cps into units, writing lb_break_none into
# breaks inside each unit.
lb_units* lb_make_units(int32* cps, int count, int flags, char* breaks):
	lb_units* u = new lb_units()
	u.start = cast(int32*, malloc(count * 4 + 4))
	u.cls = cast(char*, malloc(count + 1))
	u.last = cast(char*, malloc(count + 1))
	u.flags = cast(char*, malloc(count + 1))
	u.sa = cast(char*, malloc(count + 1))
	u.base_cp = cast(int32*, malloc(count * 4 + 4))
	u.last_cp = cast(int32*, malloc(count * 4 + 4))
	int base = -1     # resolved class of the current unit's base
	for i in range(count):
		int property = lb_property(cps[i])
		int sa = 0
		int c = lb_resolve(property, flags, &sa)
		if (((c == lb_class_cm) || (c == lb_class_zwj)) && (base >= 0) && !lb_is_hard(base) && (base != lb_class_sp) && (base != lb_class_zw)):
			breaks[i] = lb_break_none
			u.last[u.count - 1] = c
			u.last_cp[u.count - 1] = cps[i]
			continue
		int k = u.count
		u.start[k] = i
		u.last[k] = c
		u.flags[k] = property & 192
		u.sa[k] = sa
		u.base_cp[k] = cps[i]
		u.last_cp[k] = cps[i]
		base = c
		if ((c == lb_class_cm) || (c == lb_class_zwj)): c = lb_class_al
		u.cls[k] = c
		u.count = k + 1
	return u

void lb_units_free(lb_units* u):
	free(u.start)
	free(u.cls)
	free(u.last)
	free(u.flags)
	free(u.sa)
	free(u.base_cp)
	free(u.last_cp)
	free(u)

int lb_in2(int c, int a, int b):
	return (c == a) || (c == b)

int lb_in3(int c, int a, int b, int d):
	return (c == a) || (c == b) || (c == d)

int lb_ahl(int c):
	return (c == lb_class_al) || (c == lb_class_hl)

int lb_hangul(int c):
	return (c == lb_class_jl) || (c == lb_class_jv) || (c == lb_class_jt) || (c == lb_class_h2) || (c == lb_class_h3)

int lb_num_part(int c):
	return (c == lb_class_nu) || (c == lb_class_sy) || (c == lb_class_is)

# Whether unit j is AK, AS or a dotted circle (rule LB28a).
int lb_aksara(lb_units* u, int j):
	if ((j < 0) || (j >= u.count)): return 0
	return (u.cls[j] == lb_class_ak) || (u.cls[j] == lb_class_as) || (u.base_cp[j] == 0x25cc)

# Rule LB25 (Example 7): whether the run of NU, SY and IS units ending at
# unit j holds a NU.
int lb_number_before(lb_units* u, int j):
	while ((j >= 0) && lb_num_part(u.cls[j])):
		if (u.cls[j] == lb_class_nu): return 1
		j = j - 1
	return 0

# A Thai/Lao/Tai Viet/New Tai Lue vowel written before its consonant.
int lb_prepended_vowel(int cp):
	if ((cp >= 0x0e40) && (cp <= 0x0e44)): return 1
	if ((cp >= 0x0ec0) && (cp <= 0x0ec4)): return 1
	if (((cp >= 0x19b5) && (cp <= 0x19b7)) || (cp == 0x19ba)): return 1
	return (cp == 0xaab5) || (cp == 0xaab6) || (cp == 0xaab9) || (cp == 0xaabb) || (cp == 0xaabc)

# The lb_tailor_sa_clusters action between two SA units.
int lb_sa_cluster_break(lb_units* u, int k):
	int last = u.last_cp[k - 1]
	# Khmer coeng, Myanmar virama/asat stacker, Tai Tham sakot.
	if ((last == 0x17d2) || (last == 0x1039) || (last == 0x1a60)): return lb_break_none
	if (lb_prepended_vowel(u.base_cp[k - 1])): return lb_break_none
	int next = u.base_cp[k]
	if ((next == 0x0e33) || (next == 0x0eb3) || (next == 0x0e46) || (next == 0x0ec6)): return lb_break_none
	return lb_break_allowed

# Rules LB4-LB31 between unit k - 1 and unit k.
int lb_pair(lb_units* u, int k, int flags):
	int a = u.cls[k - 1]
	int b = u.cls[k]
	if (a == lb_class_bk): return lb_break_mandatory
	if ((a == lb_class_cr) && (b == lb_class_lf)): return lb_break_none
	if (lb_in3(a, lb_class_cr, lb_class_lf, lb_class_nl)): return lb_break_mandatory
	if (lb_is_hard(b)): return lb_break_none
	if (lb_in2(b, lb_class_sp, lb_class_zw)): return lb_break_none
	# The unit before any spaces (LB8, LB14-LB17).
	int j = k - 1
	while ((j >= 0) && (u.cls[j] == lb_class_sp)): j = j - 1
	int before = -1
	if (j >= 0): before = u.cls[j]
	if (before == lb_class_zw): return lb_break_allowed
	if (u.last[k - 1] == lb_class_zwj): return lb_break_none
	if (lb_in2(lb_class_wj, a, b)): return lb_break_none
	if (a == lb_class_gl): return lb_break_none
	if ((b == lb_class_gl) && !lb_in3(a, lb_class_sp, lb_class_ba, lb_class_hy)): return lb_break_none
	if (lb_in3(b, lb_class_cl, lb_class_cp, lb_class_ex) || lb_in2(b, lb_class_is, lb_class_sy)): return lb_break_none
	if (before == lb_class_op): return lb_break_none
	if ((before == lb_class_qu) && (b == lb_class_op)): return lb_break_none
	if (lb_in2(before, lb_class_cl, lb_class_cp) && (b == lb_class_ns)): return lb_break_none
	if ((before == lb_class_b2) && (b == lb_class_b2)): return lb_break_none
	if (a == lb_class_sp): return lb_break_allowed
	if (lb_in2(lb_class_qu, a, b)): return lb_break_none
	if (lb_in2(lb_class_cb, a, b)): return lb_break_allowed
	if (lb_in3(b, lb_class_ba, lb_class_hy, lb_class_ns) || (a == lb_class_bb)): return lb_break_none
	if (lb_in2(a, lb_class_hy, lb_class_ba) && (k >= 2) && (u.cls[k - 2] == lb_class_hl)): return lb_break_none
	if ((a == lb_class_sy) && (b == lb_class_hl)): return lb_break_none
	if (b == lb_class_in): return lb_break_none
	if ((lb_ahl(a) && (b == lb_class_nu)) || ((a == lb_class_nu) && lb_ahl(b))): return lb_break_none
	if ((a == lb_class_pr) && lb_in3(b, lb_class_id, lb_class_eb, lb_class_em)): return lb_break_none
	if (lb_in3(a, lb_class_id, lb_class_eb, lb_class_em) && (b == lb_class_po)): return lb_break_none
	if (lb_in2(a, lb_class_pr, lb_class_po) && lb_ahl(b)): return lb_break_none
	if (lb_ahl(a) && lb_in2(b, lb_class_pr, lb_class_po)): return lb_break_none
	# LB25, tailored as in Example 7 (and LineBreakTest.txt).
	if (lb_in2(a, lb_class_pr, lb_class_po)):
		if (b == lb_class_nu): return lb_break_none
		if (lb_in2(b, lb_class_op, lb_class_hy) && (k + 1 < u.count) && (u.cls[k + 1] == lb_class_nu)): return lb_break_none
	if (lb_in2(a, lb_class_op, lb_class_hy) && (b == lb_class_nu)): return lb_break_none
	if ((lb_num_part(b) || lb_in2(b, lb_class_cl, lb_class_cp)) && lb_number_before(u, k - 1)): return lb_break_none
	if (lb_in2(b, lb_class_po, lb_class_pr)):
		j = k - 1
		if (lb_in2(u.cls[j], lb_class_cl, lb_class_cp)): j = j - 1
		if (lb_number_before(u, j)): return lb_break_none
	if ((a == lb_class_jl) && (lb_in2(b, lb_class_jl, lb_class_jv) || lb_in2(b, lb_class_h2, lb_class_h3))): return lb_break_none
	if (lb_in2(a, lb_class_jv, lb_class_h2) && lb_in2(b, lb_class_jv, lb_class_jt)): return lb_break_none
	if (lb_in2(a, lb_class_jt, lb_class_h3) && (b == lb_class_jt)): return lb_break_none
	if (lb_hangul(a) && (b == lb_class_po)): return lb_break_none
	if ((a == lb_class_pr) && lb_hangul(b)): return lb_break_none
	if ((flags & lb_tailor_sa_clusters) && u.sa[k - 1] && u.sa[k]): return lb_sa_cluster_break(u, k)
	if (lb_ahl(a) && lb_ahl(b)): return lb_break_none
	# LB28a: Brahmic aksaras.
	if ((a == lb_class_ap) && lb_aksara(u, k)): return lb_break_none
	if (lb_aksara(u, k - 1) && lb_in2(b, lb_class_vf, lb_class_vi)): return lb_break_none
	if ((a == lb_class_vi) && lb_aksara(u, k - 2) && ((b == lb_class_ak) || (u.base_cp[k] == 0x25cc))): return lb_break_none
	if (lb_aksara(u, k - 1) && lb_aksara(u, k) && (k + 1 < u.count) && (u.cls[k + 1] == lb_class_vf)): return lb_break_none
	if ((a == lb_class_is) && lb_ahl(b)): return lb_break_none
	if ((lb_ahl(a) || (a == lb_class_nu)) && (b == lb_class_op) && ((u.flags[k] & lb_flag_wide) == 0)): return lb_break_none
	if ((a == lb_class_cp) && ((u.flags[k - 1] & lb_flag_wide) == 0) && (lb_ahl(b) || (b == lb_class_nu))): return lb_break_none
	if ((a == lb_class_ri) && (b == lb_class_ri)):
		int run = 0
		j = k - 1
		while ((j >= 0) && (u.cls[j] == lb_class_ri)):
			run = run + 1
			j = j - 1
		if (run & 1): return lb_break_none
	if (b == lb_class_em):
		if (a == lb_class_eb): return lb_break_none
		if (u.flags[k - 1] & lb_flag_pictographic): return lb_break_none
	return lb_break_allowed

# The break actions of count code points: breaks[i] (0 <= i <= count) is
# the action between cps[i - 1] and cps[i]. breaks[0] is lb_break_none
# (no break at the start, LB2) and breaks[count] lb_break_mandatory (the
# end, LB3) unless count is 0. breaks holds count + 1 bytes.
void lb_breaks(int32* cps, int count, int flags, char* breaks):
	breaks[0] = lb_break_none
	if (count <= 0): return
	lb_units* u = lb_make_units(cps, count, flags, breaks)
	for k in range(1, u.count): breaks[u.start[k]] = lb_pair(u, k, flags)
	breaks[count] = lb_break_mandatory
	lb_units_free(u)

# lb_breaks over valid UTF-8 text[0, length): breaks[b] (0 <= b <= length)
# is the action at byte offset b, lb_break_none inside a character.
# breaks holds length + 1 bytes. Returns the number of code points.
int lb_breaks_utf8(char* text, int length, int flags, char* breaks):
	int count = 0
	int at = 0
	while (at < length):
		int cp = 0
		at = at + utf8_scan(text + at, length - at, &cp)
		count = count + 1
	int32* cps = cast(int32*, malloc(count * 4 + 4))
	int32* offsets = cast(int32*, malloc(count * 4 + 4))
	char* actions = cast(char*, malloc(count + 1))
	at = 0
	for i in range(count):
		offsets[i] = at
		int cp = 0
		at = at + utf8_scan(text + at, length - at, &cp)
		cps[i] = cp
	lb_breaks(cps, count, flags, actions)
	for b in range(length + 1): breaks[b] = lb_break_none
	for i in range(count): breaks[offsets[i]] = actions[i]
	if (count > 0): breaks[length] = actions[count]
	free(cps)
	free(offsets)
	free(actions)
	return count
