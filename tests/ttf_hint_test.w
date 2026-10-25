# wbuild: x64 deps=tests/data/ttf_hint_golden.txt deps=tests/data/ttf_hint_freetype.txt deps=tests/data/fonts/
# The light autohinter (lib/ttf_hint.w, issue #824): golden hinted
# bitmaps for a TrueType and a CFF Noto subset at 9-14 px
# (tests/data/ttf_hint_golden.txt, from bin/ttf_hint_dump --golden),
# agreement with FreeType's light autohinter over the same set
# (tests/data/ttf_hint_freetype.txt, from tools/ttf_hint_ref.py), the
# measured blue zones, and the opt-in contract: no hinting is exactly the
# old rasterizer, and advances never change.
import lib.testing
import lib.stream
import lib.bytes
import lib.ttf
import lib.ttf_hint
import tools.ttf_hint_golden

char* hint_noto_ttf = c"tests/data/fonts/NotoSans-subset.ttf"
char* hint_noto_cff = c"tests/data/fonts/NotoSans-cff-subset.otf"

void test_golden_bitmaps():
	string_builder* got = string_new()
	asserts(c"golden set renders", ttf_hint_golden_format(got))
	wstream* src = stream_open_read(c"tests/data/ttf_hint_golden.txt")
	asserts(c"golden file opens", src != 0)
	string_builder* want = string_new()
	stream_read_all(src, want)
	stream_close(src)
	# Report the first differing line with its strike, then fail.
	int line = 1
	int strike_line = 0
	int i = 0
	while ((i < want.length) && (i < got.length) && (want.data[i] == got.data[i])):
		if (want.data[i] == '\n'):
			line = line + 1
			if ((i + 1 < want.length) && (want.data[i + 1] == '@')): strike_line = i + 1
		i = i + 1
	if ((i < want.length) || (i < got.length)):
		print(c"golden mismatch at line ")
		print(itoa(line))
		print(c" in strike ")
		int e = strike_line
		while ((e < want.length) && (want.data[e] != '\n')): e = e + 1
		print_n(want.data + strike_line, e - strike_line)
		print(c"\n(regenerate with bin/ttf_hint_dump --golden after checking the change)\n")
	assert_equal(want.length, got.length)
	asserts(c"hinted bitmaps match the golden file", bytes_equal(want.data, want.length, got.data, got.length))
	string_free(want)
	string_free(got)

# The next space-separated integer of s from at[0] (advancing it).
int hint_next_int(string_builder* s, int* at):
	int i = at[0]
	while ((i < s.length) && (s.data[i] == ' ')): i = i + 1
	int sign = 1
	if ((i < s.length) && (s.data[i] == '-')):
		sign = 0 - 1
		i = i + 1
	int v = 0
	while ((i < s.length) && (s.data[i] >= '0') && (s.data[i] <= '9')):
		v = v * 10 + s.data[i] - '0'
		i = i + 1
	at[0] = i
	return v * sign

# Row sums of a bitmap, keyed by height above the baseline: sums[k] is
# the row whose top is top - k pixels above it, for k in [0, count).
int hint_row_sums(ttf_bitmap* bm, int* sums, int max, int* top):
	top[0] = bm.bearing_top
	int count = bm.h
	if (count > max): count = max
	for r in range(count):
		int sum = 0
		for x in range(bm.w): sum = sum + (bm.pixels[r * bm.w + x] & 255)
		sums[r] = sum
	return count

# The ink rows' span (rows summing to at least half a pixel), as the
# heights above the baseline of the first and last: lo[0], hi[0].
void hint_ink_span(int* sums, int count, int top, int* hi, int* lo):
	hi[0] = 0 - 999
	lo[0] = 0 - 999
	for r in range(count):
		if (sums[r] >= 128):
			if (hi[0] == 0 - 999): hi[0] = top - r
			lo[0] = top - r

# The L1 distance between two row profiles, in units of b's total ink
# (x 1000).
int hint_profile_distance(int* a, int a_count, int a_top, int* b, int b_count, int b_top):
	int total = 0
	for r in range(b_count): total = total + b[r]
	if (total == 0): total = 1
	int hi = a_top
	if (b_top > hi): hi = b_top
	int lo = a_top - a_count
	if (b_top - b_count < lo): lo = b_top - b_count
	int distance = 0
	int y = hi
	while (y > lo):
		int av = 0
		int bv = 0
		if ((a_top - y >= 0) && (a_top - y < a_count)): av = a[a_top - y]
		if ((b_top - y >= 0) && (b_top - y < b_count)): bv = b[b_top - y]
		int d = av - bv
		if (d < 0): d = 0 - d
		distance = distance + d
		y = y - 1
	return distance * 1000 / total

# Compare hinted and unhinted rows with FreeType's light autohinter:
# hinting must put ink on FreeType's rows far more often, and spread it
# over them more like FreeType does, than the unhinted outlines.
void test_agrees_with_freetype():
	wstream* src = stream_open_read(c"tests/data/ttf_hint_freetype.txt")
	asserts(c"reference opens", src != 0)
	string_builder* line = string_new()
	ttf_font font
	int loaded = 0
	int ppem = 0
	int glyphs = 0
	int[2] span_match
	int[2] distance
	for m in range(2):
		span_match[m] = 0
		distance[m] = 0
	int* want = cast(int*, malloc(64 * __word_size__))
	int* sums = cast(int*, malloc(64 * __word_size__))
	while (stream_read_line(src, line)):
		if ((line.length == 0) || (line.data[0] == '#')): continue
		if (line.data[0] == '@'):
			int space = 1
			while (line.data[space] != ' '): space = space + 1
			line.data[space] = 0
			if (loaded): ttf_free(&font)
			asserts(c"reference font loads", ttf_load(&font, line.data + 1))
			loaded = 1
			int at = space + 1
			ppem = hint_next_int(line, &at)
			continue
		# "U+hex top s0 s1 ..."
		int code = 0
		int at = 2
		while (line.data[at] != ' '):
			int c = line.data[at]
			if (c >= 'a'): c = c - 'a' + 10
			else: c = c - '0'
			code = code * 16 + c
			at = at + 1
		int want_top = hint_next_int(line, &at)
		int want_count = 0
		while ((at < line.length) && (want_count < 64)):
			want[want_count] = hint_next_int(line, &at)
			want_count = want_count + 1
		int want_hi = 0
		int want_lo = 0
		hint_ink_span(want, want_count, want_top, &want_hi, &want_lo)
		for m in range(2):
			ttf_bitmap bm
			asserts(c"rasterizes", ttf_rasterize_hinted(&font, ttf_glyph_id(&font, code), ppem, 0.0, 1 - m, &bm))
			int top = 0
			int count = hint_row_sums(&bm, sums, 64, &top)
			int hi = 0
			int lo = 0
			hint_ink_span(sums, count, top, &hi, &lo)
			if ((hi == want_hi) && (lo == want_lo)): span_match[m] = span_match[m] + 1
			distance[m] = distance[m] + hint_profile_distance(sums, count, top, want, want_count, want_top)
			if (bm.pixels != 0): free(bm.pixels)
		glyphs = glyphs + 1
	stream_close(src)
	if (loaded): ttf_free(&font)
	string_free(line)
	free(cast(char*, want))
	free(cast(char*, sums))
	asserts(c"reference covers both fonts", glyphs == 2 * 6 * 12)
	print(c"ink rows as FreeType's: hinted ")
	print(itoa(span_match[0]))
	print(c", unhinted ")
	print(itoa(span_match[1]))
	print(c" of ")
	print(itoa(glyphs))
	print(c"; mean row-profile distance (1/1000): hinted ")
	print(itoa(distance[0] / glyphs))
	print(c", unhinted ")
	print(itoa(distance[1] / glyphs))
	print(c"\n")
	asserts(c"hinted ink rows match FreeType's for 95% of glyphs", span_match[0] * 100 >= glyphs * 95)
	asserts(c"hinting moves ink toward FreeType's rows", span_match[0] > span_match[1] + glyphs / 10)
	asserts(c"hinted rows spread ink like FreeType's", distance[0] / glyphs < 80)
	asserts(c"closer than unhinted", distance[0] * 2 < distance[1])

void test_blue_zones():
	ttf_font font
	asserts(c"loads", ttf_load(&font, hint_noto_ttf))
	ttf_hint_metrics* h = ttf_hint_metrics_of(&font)
	asserts(c"cached", ttf_hint_metrics_of(&font) == h)
	asserts(c"has an x-height zone", h.xheight >= 0)
	# Flat x (536), round o/e/s/c/r (546).
	assert_equal(1, h.zone_top[h.xheight])
	assert_equal(536, h.zone_ref[h.xheight])
	assert_equal(546, h.zone_shoot[h.xheight])
	# Ascenders average d and b (760) with the flat i and j dots (737).
	int ascender = 0 - 1
	int descender = 0 - 1
	for z in range(h.zone_count):
		if (h.zone_top[z] && (h.zone_ref[z] > 700) && (h.zone_ref[z] < 800)): ascender = z
		if (!h.zone_top[z] && (h.zone_ref[z] < 0 - 100)): descender = z
	asserts(c"ascender zone", ascender >= 0)
	asserts(c"descender zone", descender >= 0)
	assert_equal(0 - 240, h.zone_ref[descender])
	# The x-height overshoot lands on whole pixels: 546 units at 12 px
	# (6.55 px) round up to 7, so the scale grows by 7/6.55.
	float32 scale = ttf_hint_scale(&font, h, 12)
	int scaled = cast(int, cast(float32, h.zone_shoot[h.xheight]) * scale * 64.0 + 0.5)
	assert_equal(7 * 64, scaled)
	# At 11 px it is 6.006 px, rounded down by a hair to 6.
	scale = ttf_hint_scale(&font, h, 11)
	scaled = cast(int, cast(float32, h.zone_shoot[h.xheight]) * scale * 64.0 + 0.5)
	assert_equal(6 * 64, scaled)
	ttf_free(&font)
	# A CFF font goes through the same measurement.
	asserts(c"cff loads", ttf_load(&font, hint_noto_cff))
	h = ttf_hint_metrics_of(&font)
	asserts(c"cff x-height zone", h.xheight >= 0)
	assert_equal(546, h.zone_shoot[h.xheight])
	ttf_free(&font)

# Hinting is opt-in: TTF_HINT_NONE is the old rasterizer byte for byte,
# and a hinted glyph keeps its advance and its horizontal extent.
void hint_check_font(char* path):
	ttf_font font
	asserts(c"loads", ttf_load(&font, path))
	int changed = 0
	for gid in range(font.glyph_count):
		for k in range(3):
			int p = 8 + k * 4
			ttf_bitmap plain
			ttf_bitmap none
			ttf_bitmap light
			asserts(c"plain", ttf_rasterize(&font, gid, p, &plain))
			asserts(c"none", ttf_rasterize_hinted(&font, gid, p, 0.0, TTF_HINT_NONE, &none))
			asserts(c"light", ttf_rasterize_hinted(&font, gid, p, 0.0, TTF_HINT_LIGHT, &light))
			assert_equal(plain.w, none.w)
			assert_equal(plain.h, none.h)
			assert_equal(plain.bearing_x, none.bearing_x)
			assert_equal(plain.bearing_top, none.bearing_top)
			if (plain.pixels != 0): asserts(c"unhinted pixels unchanged", bytes_equal(plain.pixels, plain.w * plain.h, none.pixels, none.w * none.h))
			assert_equal(plain.advance, light.advance)
			assert_equal(plain.w, light.w)
			assert_equal(plain.bearing_x, light.bearing_x)
			if ((plain.h != light.h) || (plain.bearing_top != light.bearing_top)): changed = changed + 1
			else if ((plain.pixels != 0) && !bytes_equal(plain.pixels, plain.w * plain.h, light.pixels, light.w * light.h)): changed = changed + 1
			if (plain.pixels != 0): free(plain.pixels)
			if (none.pixels != 0): free(none.pixels)
			if (light.pixels != 0): free(light.pixels)
	asserts(c"hinting changes most glyphs", changed * 2 > font.glyph_count)
	ttf_free(&font)

void test_opt_in_and_advances():
	hint_check_font(hint_noto_ttf)
	hint_check_font(hint_noto_cff)

void test_skew_and_empty():
	ttf_font font
	asserts(c"loads", ttf_load(&font, hint_noto_ttf))
	# A space has no ink but keeps its advance.
	ttf_bitmap space
	asserts(c"space", ttf_rasterize_hinted(&font, ttf_glyph_id(&font, ' '), 12, 0.0, TTF_HINT_LIGHT, &space))
	assert_equal(0, space.w)
	asserts(c"space advances", space.advance > 0)
	# A synthetic oblique leans the hinted outline: the same rows, wider.
	int gid = ttf_glyph_id(&font, 'l')
	ttf_bitmap upright
	ttf_bitmap leaning
	asserts(c"upright", ttf_rasterize_hinted(&font, gid, 12, 0.0, TTF_HINT_LIGHT, &upright))
	asserts(c"leaning", ttf_rasterize_hinted(&font, gid, 12, 0.25, TTF_HINT_LIGHT, &leaning))
	assert_equal(upright.h, leaning.h)
	assert_equal(upright.bearing_top, leaning.bearing_top)
	asserts(c"oblique is wider", leaning.w > upright.w)
	# The stem's top and bottom rows are whole: the ascender and the
	# baseline sit on pixel boundaries.
	int top = 0
	int[32] sums
	int count = hint_row_sums(&upright, &sums[0], 32, &top)
	int first = 0
	while ((first < count) && (sums[first] == 0)): first = first + 1
	int last = count - 1
	while ((last > 0) && (sums[last] == 0)): last = last - 1
	asserts(c"stem rows", last > first + 5)
	asserts(c"top row is full", sums[first] * 10 >= sums[(first + last) / 2] * 9)
	asserts(c"bottom row is full", sums[last] * 10 >= sums[(first + last) / 2] * 9)
	assert_equal(1, top - last)
	free(upright.pixels)
	free(leaning.pixels)
	ttf_free(&font)
