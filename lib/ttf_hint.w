/*
lib.ttf_hint: an opt-in light autohinter for lib.ttf's rasterizer
(issue #824), in the style of FreeType's "light" autohinting mode: it
fits outlines to the pixel grid vertically only, so horizontal metrics,
advances and shaped positions never change.

	ttf_rasterize_hinted(font, gid, ppem, skew, TTF_HINT_LIGHT, &bitmap)

Both outline formats take the same path. TrueType bytecode (fpgm, prep,
glyph instructions) and CFF stem hints are ignored; the hinter reads the
outline itself:

- Per face, once: blue zones measured from FreeType's Latin reference
  letters (capital and small-letter tops with their round overshoots,
  both baselines, ascender and descender): each letter's extreme point
  counts as flat or round by its neighbours, the reference is the flat
  mean and the overshoot the round mean. A font without the letters
  gets no zones, and only its stems are fitted.
- Per size: the vertical scale changes slightly so the x-height
  overshoot lands on a pixel boundary (rounding up from 0.375 px, unless
  that moves anything by two pixels or more), zones snap to whole pixels, and a
  zone stays active only while its overshoot is under 3/4 pixel
  (suppressed below 1/2, half a pixel below 3/4).
- Per glyph: horizontal edges (runs of near-horizontal outline segments,
  round when they pass through off-curve points), merged within 1/4 pixel
  and paired into stems (each bottom edge with its best top edge above,
  mutually, at most upem/4 apart). Edges in a blue zone snap to it and
  carry their stem partner with them; the remaining stems move whole,
  their bottom edge (or, when thinner than 1.5 px, their centre) on the
  grid. As in FreeType's light mode, stem widths keep their scaled
  size: only positions are fitted.
- The fitted edges define a monotonic piecewise-linear map of y, applied
  to every flattened outline point: points between fitted edges are
  interpolated, points beyond them move with the nearest one.
*/
import lib.lib
import lib.ttf


const int TTF_HINT_NONE = 0
const int TTF_HINT_LIGHT = 1


const int ttf_hint_max_zones = 8


# A face's blue zones in font units (y up). top = 1 for a zone whose
# edges have ink below them (x-height, cap height, ascender).
struct ttf_hint_metrics:
	int zone_count
	int* zone_top       # ttf_hint_max_zones each, in the same block
	int* zone_ref       # the flat edges' position
	int* zone_shoot     # the round edges' overshoot
	int xheight         # index of the small-letter top zone, or -1
	int max_height      # upem or the reference glyphs' largest extent


# A horizontal edge of one glyph: font units, y up.
struct ttf_hint_edge:
	float32 y
	float32 x0
	float32 x1
	float32 length
	int top             # ink below (a top edge) or above (0)
	int round           # passes through an off-curve point
	int blue            # the zone it snaps to + 1, 0 none
	float32 blue_fit    # that zone's fitted position, pixels
	int link            # the stem partner's index, or -1
	int done            # fitted (in the map)


# The fitted y map: anchors sorted by orig (font units), with strictly
# increasing fit (pixels).
struct ttf_hint_map:
	float32* orig
	float32* fit
	int count
	int cap
	float32 scale       # pixels per font unit, after x-height fitting


float32 ttf_hint_abs(float32 v):
	if (v < 0.0): return 0.0 - v
	return v


float32 ttf_hint_round(float32 v):
	return cast(float32, ttf_floor(v + 0.5))


# Pixels to whole 1/64 pixels (FreeType's 26.6 positions), as a count.
float32 ttf_hint_px64(float32 v):
	return cast(float32, ttf_floor(v * 64.0 + 0.5))


# ---- per-face metrics -------------------------------------------------

int ttf_hint_next(ttf_points* p, int start);
int ttf_hint_outline(ttf_font* f, int gid, int ppem, float32 skew, ttf_outline* o, ttf_points* pts);
void ttf_hint_outline_free(ttf_outline* o);


# Running sums for one blue zone's reference characters.
struct ttf_hint_blue_sums:
	int flat_sum
	int flats
	int round_sum
	int rounds


# Measure one reference glyph for a zone, as FreeType's autohinter does:
# its highest (top) or lowest point, round when the first points off
# the extremum's horizontal run (more than 5 units and about 3 degrees
# away) are off-curve. Also widens h.max_height to the glyph's extent.
void ttf_hint_blue_glyph(ttf_font* f, ttf_hint_metrics* h, int gid, int top, ttf_hint_blue_sums* sums):
	ttf_outline o
	ttf_points pts
	if (ttf_hint_outline(f, gid, f.upem, 0.0, &o, &pts) && (pts.count > 0)):
		int best = 0
		for i in range(pts.count):
			if (top && (pts.y[i] > pts.y[best])): best = i
			if (!top && (pts.y[i] < pts.y[best])): best = i
			int extent = ttf_floor(ttf_hint_abs(pts.y[i]))
			if (extent > h.max_height): h.max_height = extent
		# The contour holding best.
		int first = 0
		int end = ttf_hint_next(&pts, 0)
		while (end <= best):
			first = end
			end = ttf_hint_next(&pts, first)
		int n = end - first
		float32 bx = pts.x[best]
		float32 by = pts.y[best]
		int prev = best
		int k = 0
		while (k < n):
			prev = prev - 1
			if (prev < first): prev = end - 1
			float32 d = ttf_hint_abs(pts.y[prev] - by)
			if ((d > 5.0) && (ttf_hint_abs(pts.x[prev] - bx) <= 20.0 * d)): k = n
			k = k + 1
		int next = best
		k = 0
		while (k < n):
			next = next + 1
			if (next >= end): next = first
			float32 d = ttf_hint_abs(pts.y[next] - by)
			if ((d > 5.0) && (ttf_hint_abs(pts.x[next] - bx) <= 20.0 * d)): k = n
			k = k + 1
		int y = ttf_floor(by + 0.5)
		if (((pts.flags[prev] & 1) == 0) || ((pts.flags[next] & 1) == 0)):
			sums.round_sum = sums.round_sum + y
			sums.rounds = sums.rounds + 1
		else:
			sums.flat_sum = sums.flat_sum + y
			sums.flats = sums.flats + 1
	ttf_hint_outline_free(&o)


# Add the zone measured over the characters of s (FreeType's Latin blue
# strings): the reference is the flat extrema's mean, the overshoot the
# round ones'. With only one kind both take it, and an overshoot on the
# wrong side of the reference meets it halfway. Returns the zone's
# index, or -1 when f has none of the characters.
int ttf_hint_zone_add(ttf_font* f, ttf_hint_metrics* h, char* s, int top):
	ttf_hint_blue_sums sums
	sums.flat_sum = 0
	sums.flats = 0
	sums.round_sum = 0
	sums.rounds = 0
	int i = 0
	while (s[i] != 0):
		int gid = ttf_glyph_id(f, s[i] & 255)
		if (gid != 0): ttf_hint_blue_glyph(f, h, gid, top, &sums)
		i = i + 1
	if ((sums.flats + sums.rounds == 0) || (h.zone_count >= ttf_hint_max_zones)): return 0 - 1
	int ref = 0
	int shoot = 0
	if (sums.flats == 0):
		ref = sums.round_sum / sums.rounds
		shoot = ref
	else if (sums.rounds == 0):
		ref = sums.flat_sum / sums.flats
		shoot = ref
	else:
		ref = sums.flat_sum / sums.flats
		shoot = sums.round_sum / sums.rounds
		if ((top != 0) != (shoot > ref)):
			ref = (ref + shoot) / 2
			shoot = ref
	int z = h.zone_count
	h.zone_top[z] = top
	h.zone_ref[z] = ref
	h.zone_shoot[z] = shoot
	h.zone_count = z + 1
	return z


void ttf_hint_points_free(ttf_points* p):
	if (p.cap == 0): return
	free(cast(char*, p.x))
	free(cast(char*, p.y))
	free(p.flags)
	p.cap = 0
	p.count = 0


# Flatten gid into o (allocated here; release with ttf_hint_outline_free)
# at ppem, recording its points into pts. Returns 1, or 0 on a
# malformed outline.
int ttf_hint_outline(ttf_font* f, int gid, int ppem, float32 skew, ttf_outline* o, ttf_points* pts):
	o.cap = 1024
	o.count = 0
	o.overflow = 0
	o.xs0 = cast(float32*, malloc(o.cap * 4))
	o.ys0 = cast(float32*, malloc(o.cap * 4))
	o.xs1 = cast(float32*, malloc(o.cap * 4))
	o.ys1 = cast(float32*, malloc(o.cap * 4))
	o.scale = cast(float32, ppem) / cast(float32, f.upem)
	o.skew = skew
	pts.cap = 0
	pts.count = 0
	o.points = pts
	ttf_xform identity
	identity.a = 1.0
	identity.b = 0.0
	identity.c = 0.0
	identity.d = 1.0
	identity.dx = 0.0
	identity.dy = 0.0
	return ttf_add_glyph(f, o, gid, &identity, 0)


void ttf_hint_outline_free(ttf_outline* o):
	free(cast(char*, o.xs0))
	free(cast(char*, o.ys0))
	free(cast(char*, o.xs1))
	free(cast(char*, o.ys1))
	if (o.points != 0): ttf_hint_points_free(o.points)


# The blue zones of f, measured on first use and kept with the font.
ttf_hint_metrics* ttf_hint_metrics_of(ttf_font* f):
	if (f.hint_metrics != 0): return cast(ttf_hint_metrics*, f.hint_metrics)
	# One block, so ttf_free's plain free releases it.
	int zones_size = ttf_hint_max_zones * __word_size__
	char* block = cast(char*, malloc(sizeof(ttf_hint_metrics) + zones_size * 3))
	ttf_hint_metrics* h = cast(ttf_hint_metrics*, block)
	h.zone_top = cast(int*, block + sizeof(ttf_hint_metrics))
	h.zone_ref = cast(int*, block + sizeof(ttf_hint_metrics) + zones_size)
	h.zone_shoot = cast(int*, block + sizeof(ttf_hint_metrics) + zones_size * 2)
	h.zone_count = 0
	h.xheight = 0 - 1
	h.max_height = f.upem
	# FreeType's Latin zones: capital top and bottom, small-letter
	# ascender, x-height and bottom, and descender. A font without these
	# letters has no zones, and only its stems are fitted.
	ttf_hint_zone_add(f, h, c"THEZOCQS", 1)
	ttf_hint_zone_add(f, h, c"HEZLOCUS", 0)
	ttf_hint_zone_add(f, h, c"fijkdbh", 1)
	h.xheight = ttf_hint_zone_add(f, h, c"xzroesc", 1)
	ttf_hint_zone_add(f, h, c"xzroesc", 0)
	ttf_hint_zone_add(f, h, c"pqgjy", 0)
	f.hint_metrics = cast(char*, h)
	return h


# ---- per-glyph edges --------------------------------------------------

int ttf_hint_next(ttf_points* p, int start):
	int end = start + 1
	while ((end < p.count) && ((p.flags[end] & 2) == 0)): end = end + 1
	return end


# Segment k of the contour at [start, start + n): point k to point k + 1.
int ttf_hint_flat(ttf_points* p, int start, int n, int k):
	int a = start + k % n
	int b = start + (k + 1) % n
	float32 dx = ttf_hint_abs(p.x[b] - p.x[a])
	float32 dy = ttf_hint_abs(p.y[b] - p.y[a])
	return dy * 12.0 <= dx


# Collect the glyph's horizontal edges (runs of segments within about
# 5 degrees of horizontal, at least upem/64 long) into out, at most max,
# sorted by y. Returns the count.
int ttf_hint_edges(ttf_font* f, ttf_points* p, ttf_hint_edge* out, int max):
	# Outline orientation: clockwise (TrueType) puts ink right of travel.
	float32 area = 0.0
	int start = 0
	while (start < p.count):
		int end = ttf_hint_next(p, start)
		for k in range(start, end):
			int k1 = k + 1
			if (k1 == end): k1 = start
			area = area + p.x[k] * p.y[k1] - p.x[k1] * p.y[k]
		start = end
	int clockwise = area < 0.0
	float32 min_length = cast(float32, f.upem) / 64.0
	int count = 0
	start = 0
	while (start < p.count):
		int end = ttf_hint_next(p, start)
		int n = end - start
		# Begin the scan after a segment that is not horizontal, so no run
		# wraps around the contour's first point.
		int first = 0 - 1
		int k = 0
		while ((k < n) && (first < 0)):
			if (!ttf_hint_flat(p, start, n, k)): first = k
			k = k + 1
		k = 1
		while ((first >= 0) && (k < n)):
			int seg = (first + k) % n
			if (!ttf_hint_flat(p, start, n, seg)):
				k = k + 1
				continue
			int len = 1
			while ((k + len < n) && ttf_hint_flat(p, start, n, (first + k + len) % n)): len = len + 1
			# The run's points: seg .. seg + len.
			float32 sum = 0.0
			float32 x0 = p.x[start + seg]
			float32 x1 = x0
			int round = 0
			for j in range(len + 1):
				int q = start + (seg + j) % n
				sum = sum + p.y[q]
				if (p.x[q] < x0): x0 = p.x[q]
				if (p.x[q] > x1): x1 = p.x[q]
				if ((p.flags[q] & 1) == 0): round = 1
			float32 dx = p.x[start + (seg + len) % n] - p.x[start + seg]
			if ((ttf_hint_abs(dx) >= min_length) && (count < max)):
				ttf_hint_edge* e = &out[count]
				e.y = sum / cast(float32, len + 1)
				e.x0 = x0
				e.x1 = x1
				e.length = ttf_hint_abs(dx)
				e.top = (dx > 0.0) == clockwise
				e.round = round
				e.blue = 0
				e.blue_fit = 0.0
				e.link = 0 - 1
				e.done = 0
				count = count + 1
			k = k + len
		start = end
	# Sort by y (insertion sort; glyphs have few edges).
	int i = 1
	while (i < count):
		ttf_hint_edge key = out[i]
		int j = i - 1
		while ((j >= 0) && (out[j].y > key.y)):
			out[j + 1] = out[j]
			j = j - 1
		out[j + 1] = key
		i = i + 1
	return count


# Merge same-side edges closer than threshold font units (they hint as
# one). Returns the new count.
int ttf_hint_merge(ttf_hint_edge* edges, int count, float32 threshold):
	int i = 0
	while (i < count):
		int j = i + 1
		while ((j < count) && (edges[j].y - edges[i].y <= threshold)):
			if (edges[j].top != edges[i].top):
				j = j + 1
				continue
			ttf_hint_edge* a = &edges[i]
			ttf_hint_edge* b = &edges[j]
			float32 total = a.length + b.length
			a.y = (a.y * a.length + b.y * b.length) / total
			a.length = total
			if (b.x0 < a.x0): a.x0 = b.x0
			if (b.x1 > a.x1): a.x1 = b.x1
			a.round = a.round && b.round
			for k in range(j, count - 1): edges[k] = edges[k + 1]
			count = count - 1
		i = i + 1
	return count


# Pair edges into stems: each bottom edge (ink above) with the top edge
# above it that scores best (nearest, longest overlap), kept only when
# the choice is mutual and thinner than max_width font units.
void ttf_hint_link(ttf_font* f, ttf_hint_edge* edges, int count, float32 max_width):
	float32 len_score = 6000.0 * cast(float32, f.upem) / 2048.0
	int* best = cast(int*, malloc((count + 1) * __word_size__))
	for i in range(count):
		best[i] = 0 - 1
		edges[i].link = 0 - 1
	for i in range(count):
		float32 best_score = 0.0
		for j in range(count):
			int lower = i
			int upper = j
			if (edges[i].top):
				lower = j
				upper = i
			if ((edges[lower].top != 0) || (edges[upper].top == 0)): continue
			float32 dist = edges[upper].y - edges[lower].y
			if ((dist <= 0.0) || (dist > max_width)): continue
			float32 lo = edges[lower].x0
			if (edges[upper].x0 > lo): lo = edges[upper].x0
			float32 hi = edges[lower].x1
			if (edges[upper].x1 < hi): hi = edges[upper].x1
			float32 overlap = hi - lo
			if (overlap <= 0.0): continue
			float32 score = dist + len_score / overlap
			if ((best[i] < 0) || (score < best_score)):
				best[i] = j
				best_score = score
	for i in range(count):
		int j = best[i]
		if ((j >= 0) && (best[j] == i)): edges[i].link = j
	free(cast(char*, best))


# ---- fitting ----------------------------------------------------------

# The vertical scale at ppem, adjusted so the x-height overshoot lands
# on a whole pixel (rounding up from 0.375 px, down below it) unless
# that moves any point of the face two pixels, as FreeType's autohinter
# does.
float32 ttf_hint_scale(ttf_font* f, ttf_hint_metrics* h, int ppem):
	float32 scale = cast(float32, ppem) / cast(float32, f.upem)
	if (h.xheight < 0): return scale
	# In 1/64 pixels, rounded as FreeType's 26.6 arithmetic rounds.
	float32 scaled = ttf_hint_px64(cast(float32, h.zone_shoot[h.xheight]) * scale)
	float32 fitted = cast(float32, ttf_floor((scaled + 40.0) / 64.0) * 64)
	if ((scaled <= 0.0) || (fitted <= 0.0) || (fitted == scaled)): return scale
	float32 grown = scale * fitted / scaled
	if (ttf_hint_abs(cast(float32, h.max_height) * (grown - scale)) < 2.0): return grown
	return scale


# The map's value at u font units.
float32 ttf_hint_map_at(ttf_hint_map* m, float32 u):
	if (m.count == 0): return u * m.scale
	if (u <= m.orig[0]): return m.fit[0] + (u - m.orig[0]) * m.scale
	int last = m.count - 1
	if (u >= m.orig[last]): return m.fit[last] + (u - m.orig[last]) * m.scale
	int i = 1
	while (m.orig[i] < u): i = i + 1
	float32 t = (u - m.orig[i - 1]) / (m.orig[i] - m.orig[i - 1])
	return m.fit[i - 1] + t * (m.fit[i] - m.fit[i - 1])


# Add the anchor (u, fit) if the map stays strictly increasing. Returns
# 1 when added (or already present with that fit).
int ttf_hint_map_add(ttf_hint_map* m, float32 u, float32 fit):
	int i = 0
	while ((i < m.count) && (m.orig[i] < u)): i = i + 1
	if ((i < m.count) && (m.orig[i] == u)): return m.fit[i] == fit
	if ((i > 0) && (m.fit[i - 1] >= fit)): return 0
	if ((i < m.count) && (m.fit[i] <= fit)): return 0
	if (m.count >= m.cap): return 0
	int k = m.count
	while (k > i):
		m.orig[k] = m.orig[k - 1]
		m.fit[k] = m.fit[k - 1]
		k = k - 1
	m.orig[i] = u
	m.fit[i] = fit
	m.count = m.count + 1
	return 1


void ttf_hint_map_remove(ttf_hint_map* m, float32 u):
	int i = 0
	while ((i < m.count) && (m.orig[i] != u)): i = i + 1
	if (i >= m.count): return
	for k in range(i, m.count - 1):
		m.orig[k] = m.orig[k + 1]
		m.fit[k] = m.fit[k + 1]
	m.count = m.count - 1


# Fix edge e at pos (and, when given, its partner at partner_pos) if the
# map allows it.
void ttf_hint_place(ttf_hint_map* m, ttf_hint_edge* e, float32 pos, ttf_hint_edge* partner, float32 partner_pos):
	int before = m.count
	if (!ttf_hint_map_add(m, e.y, pos)): return
	if (partner != 0):
		if (!ttf_hint_map_add(m, partner.y, partner_pos)):
			# Undo e's anchor unless another edge had already set it.
			if (m.count > before): ttf_hint_map_remove(m, e.y)
			return
		partner.done = 1
	e.done = 1


# Snap edges to the active blue zones: an edge compares with a zone's
# flat reference, and a round edge beyond the reference also with its
# overshoot; the nearest within min(1/2 px, upem/40) wins.
void ttf_hint_blues(ttf_font* f, ttf_hint_metrics* h, float32 scale, ttf_hint_edge* edges, int count):
	float32[8] ref_fit
	float32[8] shoot_fit
	int[8] active
	for z in range(h.zone_count):
		# 1/64 pixels: the zone is active while under 3/4 pixel tall.
		float32 ref = ttf_hint_px64(cast(float32, h.zone_ref[z]) * scale)
		float32 dist = ttf_hint_px64(cast(float32, h.zone_ref[z] - h.zone_shoot[z]) * scale)
		active[z] = ttf_hint_abs(dist) <= 48.0
		float32 delta = ttf_hint_abs(dist)
		if (delta < 32.0): delta = 0.0
		else if (delta < 48.0): delta = 0.5
		else: delta = 1.0
		if (dist < 0.0): delta = 0.0 - delta
		ref_fit[z] = cast(float32, ttf_floor((ref + 32.0) / 64.0))
		shoot_fit[z] = ref_fit[z] - delta
	float32 limit = cast(float32, f.upem) / 40.0 * scale
	if (limit > 0.5): limit = 0.5
	for i in range(count):
		ttf_hint_edge* e = &edges[i]
		float32 best = limit
		for z in range(h.zone_count):
			if (!active[z] || (h.zone_top[z] != e.top)): continue
			float32 d = ttf_hint_abs(e.y - cast(float32, h.zone_ref[z])) * scale
			if (d < best):
				best = d
				e.blue = z + 1
				e.blue_fit = ref_fit[z]
			int beyond = e.y > cast(float32, h.zone_ref[z])
			if (!e.top): beyond = e.y < cast(float32, h.zone_ref[z])
			if (e.round && (d != 0.0) && beyond):
				d = ttf_hint_abs(e.y - cast(float32, h.zone_shoot[z])) * scale
				if (d < best):
					best = d
					e.blue = z + 1
					e.blue_fit = shoot_fit[z]


# Fit the glyph's edges into the map m.
void ttf_hint_fit(ttf_font* f, ttf_hint_metrics* h, ttf_hint_edge* edges, int count, ttf_hint_map* m):
	float32 scale = m.scale
	ttf_hint_blues(f, h, scale, edges, count)
	# Blue edges first, each carrying its stem partner.
	for i in range(count):
		ttf_hint_edge* e = &edges[i]
		if (e.done): continue
		ttf_hint_edge* a = 0
		ttf_hint_edge* b = 0
		if (e.blue):
			a = e
			if (e.link >= 0): b = &edges[e.link]
		else if ((e.link >= 0) && edges[e.link].blue):
			a = &edges[e.link]
			b = e
		if (a == 0): continue
		if ((b != 0) && (b.blue || b.done)): b = 0
		if (b == 0):
			ttf_hint_place(m, a, a.blue_fit, 0, 0.0)
			continue
		ttf_hint_place(m, a, a.blue_fit, b, a.blue_fit + (b.y - a.y) * scale)
	# Any remaining blue edge whose partner pass failed.
	for i in range(count):
		if (!edges[i].done && edges[i].blue): ttf_hint_place(m, &edges[i], edges[i].blue_fit, 0, 0.0)
	# Then the other stems, bottom to top, placed whole as FreeType's
	# autohinter places a stem with no blue edge: a thin one centred on
	# a pixel (or, between 1 and 1.5 px, just off one), a thicker one
	# with whichever edge rounds closer to the original centre.
	for i in range(count):
		ttf_hint_edge* lo = &edges[i]
		if (lo.done || (lo.link <= i)): continue
		ttf_hint_edge* hi = &edges[lo.link]
		if (hi.done): continue
		float32 org_len = (hi.y - lo.y) * scale
		float32 org_pos = ttf_hint_map_at(m, lo.y)
		float32 org_center = org_pos + org_len / 2.0
		float32 len = org_len
		float32 pos = 0.0
		if (len < 1.5):
			float32 center = ttf_hint_round(org_center)
			float32 up = 0.5
			float32 down = 0.5
			if (len > 1.0):
				up = 38.0 / 64.0
				down = 26.0 / 64.0
			float32 below = ttf_hint_abs(org_center - (center - up))
			if (below < ttf_hint_abs(org_center - (center + down))): center = center - up
			else: center = center + down
			pos = center - len / 2.0
		else:
			float32 pos1 = ttf_hint_round(org_pos)
			float32 pos2 = ttf_hint_round(org_pos + org_len) - len
			if (ttf_hint_abs(pos1 + len / 2.0 - org_center) <= ttf_hint_abs(pos2 + len / 2.0 - org_center)): pos = pos1
			else: pos = pos2
		ttf_hint_place(m, lo, pos, hi, pos + len)


# Build the y map for glyph points pts at ppem. m's arrays are allocated
# here; free them with ttf_hint_map_free.
void ttf_hint_build_map(ttf_font* f, ttf_points* pts, int ppem, ttf_hint_map* m):
	ttf_hint_metrics* h = ttf_hint_metrics_of(f)
	m.scale = ttf_hint_scale(f, h, ppem)
	int max = pts.count + 1
	m.cap = max * 2
	m.count = 0
	m.orig = cast(float32*, malloc(m.cap * 4))
	m.fit = cast(float32*, malloc(m.cap * 4))
	ttf_hint_edge* edges = cast(ttf_hint_edge*, malloc(max * sizeof(ttf_hint_edge)))
	int count = ttf_hint_edges(f, pts, edges, max)
	float32 threshold = cast(float32, f.upem) / 40.0
	if (threshold * m.scale > 0.25): threshold = 0.25 / m.scale
	count = ttf_hint_merge(edges, count, threshold)
	ttf_hint_link(f, edges, count, cast(float32, f.upem) / 4.0)
	ttf_hint_fit(f, h, edges, count, m)
	free(cast(char*, edges))


void ttf_hint_map_free(ttf_hint_map* m):
	free(cast(char*, m.orig))
	free(cast(char*, m.fit))


# Move every flattened point of o (y-down pixels, sheared by o.skew)
# through the map.
void ttf_hint_apply(ttf_outline* o, ttf_hint_map* m):
	for i in range(o.count):
		float32 ty0 = 0.0 - o.ys0[i]
		float32 ty1 = 0.0 - o.ys1[i]
		float32 fy0 = ttf_hint_map_at(m, ty0 / o.scale)
		float32 fy1 = ttf_hint_map_at(m, ty1 / o.scale)
		o.xs0[i] = o.xs0[i] + o.skew * (fy0 - ty0)
		o.xs1[i] = o.xs1[i] + o.skew * (fy1 - ty1)
		o.ys0[i] = 0.0 - fy0
		o.ys1[i] = 0.0 - fy1


# Rasterize gid at ppem with the given hinting mode (TTF_HINT_NONE is
# exactly ttf_rasterize_skewed). The advance is the unhinted one in
# every mode. Returns 1, or 0 on a malformed outline.
int ttf_rasterize_hinted(ttf_font* f, int gid, int ppem, float32 skew, int hinting, ttf_bitmap* out):
	if (hinting != TTF_HINT_LIGHT): return ttf_rasterize_skewed(f, gid, ppem, skew, out)
	out.pixels = 0
	out.w = 0
	out.h = 0
	out.bearing_x = 0
	out.bearing_top = 0
	out.advance = ttf_scale_round(f, ppem, ttf_advance_units(f, gid))
	ttf_outline outline
	ttf_points pts
	int ok = ttf_hint_outline(f, gid, ppem, skew, &outline, &pts)
	if (ok && (outline.count > 0)):
		ttf_hint_map m
		ttf_hint_build_map(f, &pts, ppem, &m)
		ttf_hint_apply(&outline, &m)
		ttf_hint_map_free(&m)
	if (ok): ok = ttf_fill(&outline, out)
	ttf_hint_outline_free(&outline)
	return ok
