/*
lib.ttf_hangul: the Hangul shaper's text preprocessing behind
lib.ttf_shape (issue #825), a port of HarfBuzz 15's hb-ot-shaper-hangul.

	n = ttf_hangul_preprocess(f, cps, clusters, bits, count, out_cps, out_clusters, out_bits)

rewrites count characters (cps, with their clusters and the caller's
bits above bit 1) into out_cps, out_clusters and out_bits, which hold up
to 3 * count entries, and returns the new count. A syllable the font has a precomposed glyph for composes: <L,V>,
<L,V,T> and <LV,T>. A precomposed syllable the font lacks (or an LV
before a T that does not combine with it) decomposes into jamo when the
font has them all. The jamo of a syllable left decomposed take the
ljmo/vjmo/tjmo feature (out_bits[k] & 3 is ttf_hangul_ljmo, _vjmo,
_tjmo or 0) and merge their clusters. A Hangul tone mark (U+302E, U+302F) after a
syllable moves in front of it unless the font draws it with zero width;
one without a syllable gets a dotted circle. lib.ttf_shape applies the
features, keeps 'calt' away from jamo, and skips recomposition and mark
zeroing for Hangul as HarfBuzz does.
*/
import lib.lib
import lib.ttf

const int ttf_hangul_ljmo = 1
const int ttf_hangul_vjmo = 2
const int ttf_hangul_tjmo = 3

int ttf_hangul_is_l(int u):
	return ((u >= 0x1100) && (u <= 0x115f)) || ((u >= 0xa960) && (u <= 0xa97c))

int ttf_hangul_is_v(int u):
	return ((u >= 0x1160) && (u <= 0x11a7)) || ((u >= 0xd7b0) && (u <= 0xd7c6))

int ttf_hangul_is_t(int u):
	return ((u >= 0x11a8) && (u <= 0x11ff)) || ((u >= 0xd7cb) && (u <= 0xd7fb))

# Any jamo (lib.ttf_shape keeps 'calt' off them).
int ttf_hangul_is_jamo(int u):
	return ttf_hangul_is_l(u) || ttf_hangul_is_v(u) || ttf_hangul_is_t(u)

# The state of a preprocessing pass: HarfBuzz's buffer with its input
# (cps, clusters, read at idx) and output (out_*, out_len).
struct ttf_hangul_buf:
	int32* cps
	int32* clusters
	char* features
	int count
	int idx
	int32* out_cps
	int32* out_clusters
	char* out_features
	int out_len

void ttf_hangul_next(ttf_hangul_buf* h):
	h.out_cps[h.out_len] = h.cps[h.idx]
	h.out_clusters[h.out_len] = h.clusters[h.idx]
	h.out_features[h.out_len] = h.features[h.idx]
	h.out_len = h.out_len + 1
	h.idx = h.idx + 1

# HarfBuzz's merge_clusters on the input: start..end and the characters
# sharing their first and last clusters take the lowest cluster.
void ttf_hangul_merge(ttf_hangul_buf* h, int start, int end):
	if (end - start < 2): return
	int cluster = h.clusters[start]
	for i in range(start + 1, end):
		if (h.clusters[i] < cluster): cluster = h.clusters[i]
	if (cluster != h.clusters[end - 1]):
		while ((end < h.count) && (h.clusters[end - 1] == h.clusters[end])): end = end + 1
	if (cluster != h.clusters[start]):
		while ((h.idx < start) && (h.clusters[start - 1] == h.clusters[start])): start = start - 1
	if ((h.idx == start) && (h.clusters[start] != cluster)):
		int i = h.out_len
		while ((i > 0) && (h.out_clusters[i - 1] == h.clusters[start])):
			h.out_clusters[i - 1] = cluster
			i = i - 1
	for i in range(start, end): h.clusters[i] = cluster

# HarfBuzz's merge_out_clusters: out start..end, extended over equal
# neighbouring clusters (into the input at the end of the output).
void ttf_hangul_merge_out(ttf_hangul_buf* h, int start, int end):
	if (end - start < 2): return
	int cluster = h.out_clusters[start]
	for i in range(start + 1, end):
		if (h.out_clusters[i] < cluster): cluster = h.out_clusters[i]
	while ((start > 0) && (h.out_clusters[start - 1] == h.out_clusters[start])): start = start - 1
	while ((end < h.out_len) && (h.out_clusters[end - 1] == h.out_clusters[end])): end = end + 1
	if (end == h.out_len):
		int i = h.idx
		int last = h.out_clusters[end - 1]
		while ((i < h.count) && (h.clusters[i] == last)):
			h.clusters[i] = cluster
			i = i + 1
	for i in range(start, end): h.out_clusters[i] = cluster

# HarfBuzz's replace_glyphs: num_in input characters (their clusters
# merged) become the num_out characters of chars.
void ttf_hangul_replace(ttf_hangul_buf* h, int num_in, int num_out, int* chars):
	ttf_hangul_merge(h, h.idx, h.idx + num_in)
	int from = h.idx
	for k in range(num_out):
		h.out_cps[h.out_len] = chars[k]
		h.out_clusters[h.out_len] = h.clusters[from]
		h.out_features[h.out_len] = h.features[from]
		h.out_len = h.out_len + 1
	h.idx = h.idx + num_in

int ttf_hangul_has(ttf_font* f, int u):
	return ttf_glyph_id(f, u) != 0

int ttf_hangul_zero_width(ttf_font* f, int u):
	int gid = ttf_glyph_id(f, u)
	return (gid != 0) && (ttf_advance_units(f, gid) == 0)

int ttf_hangul_preprocess(ttf_font* f, int32* cps, int32* clusters, char* bits, int count, int32* out_cps, int32* out_clusters, char* features):
	ttf_hangul_buf hb
	ttf_hangul_buf* h = &hb
	h.cps = cps
	h.clusters = cast(int32*, malloc(count * 4 + 4))
	h.features = cast(char*, malloc(count + 1))
	for i in range(count):
		h.clusters[i] = clusters[i]
		h.features[i] = bits[i] & ~3
	h.count = count
	h.idx = 0
	h.out_cps = out_cps
	h.out_clusters = out_clusters
	h.out_features = features
	h.out_len = 0
	int[3] chars
	# The extent of the last syllable seen, valid when start < end.
	int start = 0
	int end = 0
	while (h.idx < count):
		int u = cps[h.idx]
		if ((u == 0x302e) || (u == 0x302f)):
			if ((start < end) && (end == h.out_len)):
				# After a syllable the tone mark moves in front of it.
				ttf_hangul_next(h)
				if (!ttf_hangul_zero_width(f, u)):
					ttf_hangul_merge_out(h, start, end + 1)
					int tone_cp = out_cps[end]
					int tone_cluster = out_clusters[end]
					int tone_feature = features[end]
					int k = end
					while (k > start):
						out_cps[k] = out_cps[k - 1]
						out_clusters[k] = out_clusters[k - 1]
						features[k] = features[k - 1]
						k = k - 1
					out_cps[start] = tone_cp
					out_clusters[start] = tone_cluster
					features[start] = tone_feature
			else if (ttf_hangul_has(f, 0x25cc)):
				# No syllable: a dotted circle carries the tone mark.
				chars[0] = u
				chars[1] = 0x25cc
				if (ttf_hangul_zero_width(f, u)):
					chars[0] = 0x25cc
					chars[1] = u
				ttf_hangul_replace(h, 1, 2, &chars[0])
			else: ttf_hangul_next(h)
			start = h.out_len
			end = h.out_len
			continue
		start = h.out_len
		if (ttf_hangul_is_l(u) && (h.idx + 1 < count)):
			int l = u
			int v = cps[h.idx + 1]
			if (ttf_hangul_is_v(v)):
				int t = 0
				int tindex = 0
				if (h.idx + 2 < count):
					t = cps[h.idx + 2]
					if (ttf_hangul_is_t(t)): tindex = t - 0x11a7
					else: t = 0
				# <L,V,T?> composes when its parts combine and the font
				# has the syllable.
				if ((l >= 0x1100) && (l <= 0x1112) && (v >= 0x1161) && (v <= 0x1175) && ((t == 0) || ((t >= 0x11a8) && (t <= 0x11c2)))):
					int s = 0xac00 + (l - 0x1100) * 588 + (v - 0x1161) * 28 + tindex
					if (ttf_hangul_has(f, s)):
						chars[0] = s
						int num_in = 2
						if (t != 0): num_in = 3
						ttf_hangul_replace(h, num_in, 1, &chars[0])
						end = start + 1
						continue
				# Otherwise the jamo stay, with their features.
				h.features[h.idx] = h.features[h.idx] | ttf_hangul_ljmo
				ttf_hangul_next(h)
				h.features[h.idx] = h.features[h.idx] | ttf_hangul_vjmo
				ttf_hangul_next(h)
				if (t != 0):
					h.features[h.idx] = h.features[h.idx] | ttf_hangul_tjmo
					ttf_hangul_next(h)
					end = start + 3
				else: end = start + 2
				ttf_hangul_merge_out(h, start, end)
				continue
		else if ((u >= 0xac00) && (u <= 0xd7a3)):
			# <LV>, <LVT> or <LV,T>.
			int s = u
			int has_glyph = ttf_hangul_has(f, s)
			int lindex = (s - 0xac00) / 588
			int nindex = (s - 0xac00) % 588
			int vindex = nindex / 28
			int tindex = nindex % 28
			int next = 0
			if (h.idx + 1 < count): next = cps[h.idx + 1]
			if ((tindex == 0) && (next >= 0x11a8) && (next <= 0x11c2)):
				# <LV,T> composes when the font has the result.
				int new_s = s + next - 0x11a7
				if (ttf_hangul_has(f, new_s)):
					chars[0] = new_s
					ttf_hangul_replace(h, 2, 1, &chars[0])
					end = start + 1
					continue
			# Otherwise decompose a syllable the font lacks, or an LV
			# before a T that did not combine.
			if (!has_glyph || ((tindex == 0) && (h.idx + 1 < count) && ttf_hangul_is_t(next))):
				chars[0] = 0x1100 + lindex
				chars[1] = 0x1161 + vindex
				chars[2] = 0x11a7 + tindex
				if (ttf_hangul_has(f, chars[0]) && ttf_hangul_has(f, chars[1]) && ((tindex == 0) || ttf_hangul_has(f, chars[2]))):
					int s_len = 2
					if (tindex != 0): s_len = 3
					ttf_hangul_replace(h, 1, s_len, &chars[0])
					# An LV decomposed for a following T takes it along.
					if (has_glyph && (tindex == 0)):
						ttf_hangul_next(h)
						s_len = s_len + 1
					end = start + s_len
					features[start] = (features[start] & ~3) | ttf_hangul_ljmo
					features[start + 1] = (features[start + 1] & ~3) | ttf_hangul_vjmo
					if (start + 2 < end): features[start + 2] = (features[start + 2] & ~3) | ttf_hangul_tjmo
					ttf_hangul_merge_out(h, start, end)
					continue
			if (has_glyph): end = start + 1
		# Not a recognizable syllable: no tone mark moves after it.
		ttf_hangul_next(h)
	free(h.clusters)
	free(h.features)
	return h.out_len
