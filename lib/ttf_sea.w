/*
lib.ttf_sea: what lib.ttf_khmer and lib.ttf_myanmar share (issue #825):
HarfBuzz's shaping categories for the Khmer and Myanmar blocks, and its
hb_syllabic_insert_dotted_circles.

	int cat = ttf_sea_category(cp)

returns HarfBuzz's category number (hb_indic_get_categories & 0xFF) for
the Khmer, Khmer Symbols, Myanmar and Myanmar Extended blocks and the
variation selectors, from HarfBuzz 15's generated
hb-ot-shaper-indic-table.cc, and lib.unicode_text's Indic categories
everywhere else (with SMPst renumbered to HarfBuzz's 57). Each shaper maps
these numbers onto its own syllable machine's symbols.
*/
import lib.lib
import lib.ttf
import lib.ttf_layout
import lib.unicode_text

# HarfBuzz's category numbers (the indic, khmer and myanmar machines'
# exports share one numbering).
const int ttf_sea_x = 0
const int ttf_sea_c = 1
const int ttf_sea_v = 2         # Myanmar IV
const int ttf_sea_n = 3         # Myanmar DB
const int ttf_sea_h = 4         # Khmer Coeng, Myanmar virama
const int ttf_sea_zwnj = 5
const int ttf_sea_zwj = 6
const int ttf_sea_sm = 8
const int ttf_sea_a = 9
const int ttf_sea_placeholder = 10   # Myanmar GB
const int ttf_sea_dottedcircle = 11
const int ttf_sea_ra = 15
const int ttf_sea_cs = 18
const int ttf_sea_vabv = 20
const int ttf_sea_vblw = 21
const int ttf_sea_vpre = 22
const int ttf_sea_vpst = 23
const int ttf_sea_robatic = 25
const int ttf_sea_xgroup = 26
const int ttf_sea_ygroup = 27
const int ttf_sea_as = 32
const int ttf_sea_mh = 35
const int ttf_sea_mr = 36
const int ttf_sea_mw = 37
const int ttf_sea_my = 38
const int ttf_sea_pt = 39
const int ttf_sea_vs = 40
const int ttf_sea_ml = 41
const int ttf_sea_smpst = 57

# Range table (4-byte entries: 24-bit start, category; 255 = not covered
# here) transcribed from HarfBuzz 15's hb-ot-shaper-indic-table.cc.
char* ttf_sea_table():
	return c"\x00\x00\x00\xff\x00\x10\x00\x01\x00\x10\x04\x0f\x00\x10\x05\x01\x00\x10\x1b\x0f\x00\x10\x1c\x01\x00\x10\x21\x02\x00\x10\x2b\x17\x00\x10\x2d\x14\x00\x10\x2f\x15\x00\x10\x31\x16\x00\x10\x32\x09\x00\x10\x33\x14\x00\x10\x36\x09\x00\x10\x37\x03\x00\x10\x38\x08\x00\x10\x39\x04\x00\x10\x3a\x20\x00\x10\x3b\x26\x00\x10\x3c\x24\x00\x10\x3d\x25\x00\x10\x3e\x23\x00\x10\x3f\x01\x00\x10\x40\x0a\x00\x10\x4c\x00\x00\x10\x4e\x01\x00\x10\x4f\x00\x00\x10\x50\x01\x00\x10\x52\x02\x00\x10\x56\x17\x00\x10\x58\x15\x00\x10\x5a\x0f\x00\x10\x5b\x01\x00\x10\x5e\x26\x00\x10\x60\x29\x00\x10\x61\x01\x00\x10\x62\x17\x00\x10\x63\x27\x00\x10\x65\x01\x00\x10\x67\x17\x00\x10\x69\x27\x00\x10\x6e\x01\x00\x10\x71\x14\x00\x10\x75\x01\x00\x10\x82\x25\x00\x10\x83\x17\x00\x10\x84\x16\x00\x10\x85\x14\x00\x10\x87\x08\x00\x10\x8e\x01\x00\x10\x8f\x08\x00\x10\x90\x0a\x00\x10\x9a\x08\x00\x10\x9d\x14\x00\x10\x9e\x00\x00\x10\xa0\xff\x00\x17\x80\x01\x00\x17\x9a\x0f\x00\x17\x9b\x01\x00\x17\xa3\x02\x00\x17\xb4\x00\x00\x17\xb6\x17\x00\x17\xb7\x14\x00\x17\xbb\x15\x00\x17\xbe\x14\x00\x17\xbf\x17\x00\x17\xc1\x16\x00\x17\xc4\x17\x00\x17\xc6\x1a\x00\x17\xc7\x1b\x00\x17\xc9\x19\x00\x17\xcb\x1a\x00\x17\xcc\x19\x00\x17\xcd\x1a\x00\x17\xd2\x04\x00\x17\xd3\x1b\x00\x17\xd4\x00\x00\x17\xd9\x0a\x00\x17\xda\x00\x00\x17\xdc\x11\x00\x17\xdd\x1b\x00\x17\xde\x00\x00\x17\xe0\x0a\x00\x17\xea\x00\x00\x18\x00\xff\x00\x19\xe0\x00\x00\x1a\x00\xff\x00\xa9\xe0\x01\x00\xa9\xe5\x14\x00\xa9\xe6\x00\x00\xa9\xe7\x01\x00\xa9\xf0\x0a\x00\xa9\xfa\x01\x00\xa9\xff\x00\x00\xaa\x00\xff\x00\xaa\x60\x01\x00\xaa\x70\x00\x00\xaa\x71\x01\x00\xaa\x74\x0a\x00\xaa\x77\x00\x00\xaa\x7a\x01\x00\xaa\x7b\x27\x00\xaa\x7c\x03\x00\xaa\x7e\x01\x00\xaa\x80\xff\x00\xfe\x00\x28\x00\xfe\x10\xff\x01\x16\xd0\x0a\x01\x16\xe4\x00\x01\x17\x00\xff"

int ttf_sea_category(int cp):
	if (cp < 0): return ttf_sea_x
	int cat = ut_range_value(ttf_sea_table(), 110, cp)
	if (cat != 255): return cat
	cat = ut_indic_category(cp)
	if (cat == ut_icat_smpst): return ttf_sea_smpst
	return cat

# HarfBuzz's syllable serial wraps after 15 (it has four bits), so per-
# syllable matching sees syllable 16 as syllable 1 again.
int ttf_sea_next_serial(int serial):
	if (serial == 15): return 1
	return serial + 1

# HarfBuzz's hb_syllabic_insert_dotted_circles without a repha category:
# a U+25CC glyph (category circle_cat) opens every syllable of type
# broken (low four bits of otl_glyph.syllable), taking the cluster, mask
# and syllable of the glyph it precedes. Nothing happens when the font
# has no dotted circle.
void ttf_sea_dotted_circles(ttf_font* f, otl_buffer* b, int broken, int circle_cat):
	int circle = ttf_glyph_id(f, 0x25cc)
	if (circle == 0): return
	int last = 0
	int i = 0
	while (i < b.count):
		int syllable = b.glyphs[i].syllable
		if ((syllable == last) || ((syllable & 15) != broken)):
			i = i + 1
			continue
		last = syllable
		otl_buffer_insert_copy(b, i, i)
		otl_glyph* g = &b.glyphs[i]
		g.gid = circle
		g.cp = 0x25cc
		g.icat = circle_cat
		g.ipos = 0
		g.props = 0
		g.unicode_mark = 0
		g.subst = 0
		g.lig_id = 0
		g.lig_comp = 0
		i = i + 2
