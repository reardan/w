# Deterministic hand-drawn geometry for `look: handDrawn` (issue #818),
# shared by the SVG writer (scene.w) and the native preview
# (graphics/mermaid.w) so both draw the same strokes.
#
# It follows rough.js, which upstream mermaid uses for the look, with the
# options mermaid passes it (roughness 0.7, bowing 1, hachure fill with a
# 1.5px gap at -41 degrees): every outline edge is drawn twice as a bowed,
# jittered cubic stroke, ellipses are jittered closed curves drawn twice, and
# fills are hachure lines clipped to the shape. Randomness comes from
# rough.js's Park-Miller generator (seed * 48271 mod 2^31), so the same seed
# always yields the same drawing; the generator call order is native, so the
# strokes are rough.js-like rather than byte-identical to upstream's.
#
# Geometry is in tenths of a pixel. Output polylines are appended to
# strokes / fills as [count, x0, y0, x1, y1, ...] runs.
import lib.fmath

const int MM_ROUGH_ROUGHNESS = 70
const int MM_ROUGH_GAP = 15
const int MM_ROUGH_STEPS = 8
# At most this many hachure lines per shape and points per outline, so huge
# shapes stay bounded.
const int MM_ROUGH_MAX_LINES = 600
const int MM_ROUGH_MAX_POINTS = 512

struct mm_rough:
	int seed
	list[int] strokes
	list[int] fills

mm_rough* mm_rough_new(int seed):
	mm_rough* r = new mm_rough()
	r.seed = seed & 2147483647
	if (r.seed == 0): r.seed = 1
	r.strokes = new list[int]
	r.fills = new list[int]
	return r

void mm_rough_free(mm_rough* r):
	if (r == 0): return
	__w_list_free(cast(__w_list*, r.strokes))
	__w_list_free(cast(__w_list*, r.fills))
	free(r)

# The seed of one primitive: a configured handDrawnSeed restarts every shape
# at that seed, as upstream passes it to each rough.js shape; the default
# (0, random upstream) derives a fixed per-primitive seed instead.
int mm_rough_seed(int configured, int index):
	if (configured != 0): return configured
	return 1 + ((index + 1) * 7919) % 2147483000

# Next uniform value in [0, 65536).
int mm_rough_next(mm_rough* r):
	r.seed = (48271 * r.seed) & 2147483647
	return r.seed >> 15

# rough.js _offsetOpt: roughness * gain * uniform(-x, x); gain in hundredths.
int mm_rough_offset(mm_rough* r, int x, int gain):
	int u = mm_rough_next(r)
	int value = (u * 2 - 65536) * x / 65536
	value = value * MM_ROUGH_ROUGHNESS / 100
	return value * gain / 100

int mm_rough_isqrt(int value):
	if (value <= 0): return 0
	int root = cast(int, fsqrt(cast(float, value)))
	while (root > 0 && root * root > value): root = root - 1
	while ((root + 1) * (root + 1) <= value): root = root + 1
	return root

# Appends a flattened cubic Bezier (MM_ROUGH_STEPS segments) to out.
void mm_rough_curve(list[int] out, int x0, int y0, int x1, int y1, int x2, int y2, int x3, int y3):
	int n = MM_ROUGH_STEPS
	out.push(n + 1)
	for i in range(n + 1):
		int a = n - i
		int b = i
		int cube = n * n * n
		out.push((a * a * a * x0 + 3 * a * a * b * x1 + 3 * a * b * b * x2 + b * b * b * x3) / cube)
		out.push((a * a * a * y0 + 3 * a * a * b * y1 + 3 * a * b * b * y2 + b * b * b * y3) / cube)

# rough.js _line: one bowed stroke; overlay is the second, tighter pass.
void mm_rough_pass(mm_rough* r, list[int] out, int x1, int y1, int x2, int y2, int overlay):
	int dx = x2 - x1
	int dy = y2 - y1
	int lx = dx / 10
	int ly = dy / 10
	if (lx < 0): lx = 0 - lx
	if (ly < 0): ly = 0 - ly
	int length = lx + ly
	if (lx < 20000 && ly < 20000): length = mm_rough_isqrt(lx * lx + ly * ly)
	int gain = 100
	if (length > 500): gain = 40
	else if (length >= 200): gain = 123 - length / 6
	# maxRandomnessOffset 2px, shrunk to a tenth of short lines.
	int offset = 20
	if (length * length < 400): offset = length
	int half = offset / 2
	int diverge = 13107 + mm_rough_next(r) * 13107 / 65536
	int bow_x = mm_rough_offset(r, dy / 100, gain)
	int bow_y = mm_rough_offset(r, 0 - dx / 100, gain)
	int jitter = offset
	if (overlay): jitter = half
	int sx = x1 + mm_rough_offset(r, jitter, gain)
	int sy = y1 + mm_rough_offset(r, jitter, gain)
	int c1x = bow_x + x1 + dx / 4 * diverge / 16384 + mm_rough_offset(r, jitter, gain)
	int c1y = bow_y + y1 + dy / 4 * diverge / 16384 + mm_rough_offset(r, jitter, gain)
	int c2x = bow_x + x1 + dx / 2 * diverge / 16384 + mm_rough_offset(r, jitter, gain)
	int c2y = bow_y + y1 + dy / 2 * diverge / 16384 + mm_rough_offset(r, jitter, gain)
	int ex = x2 + mm_rough_offset(r, jitter, gain)
	int ey = y2 + mm_rough_offset(r, jitter, gain)
	mm_rough_curve(out, sx, sy, c1x, c1y, c2x, c2y, ex, ey)

# rough.js doubleLine: two passes over the same segment.
void mm_rough_line(mm_rough* r, int x1, int y1, int x2, int y2):
	mm_rough_pass(r, r.strokes, x1, y1, x2, y2, 0)
	mm_rough_pass(r, r.strokes, x1, y1, x2, y2, 1)

# Closed outline through points ([x, y, ...] in tenths).
void mm_rough_outline(mm_rough* r, list[int] points):
	int count = points.length / 2
	if (count > MM_ROUGH_MAX_POINTS): count = MM_ROUGH_MAX_POINTS
	for i in range(count):
		int j = (i + 1) % count
		mm_rough_line(r, points[i * 2], points[i * 2 + 1], points[j * 2], points[j * 2 + 1])

# Hachure fill of a closed polygon: parallel lines gap tenths apart at
# -41 degrees, clipped by even-odd intersection with every edge; each line is
# one jittered stroke.
void mm_rough_hachure(mm_rough* r, list[int] points):
	int count = points.length / 2
	if (count < 3): return
	float angle = -41.0 * 3.14159265 / 180.0
	float ux = fcos(angle)
	float uy = fsin(angle)
	# Normal to the hachure direction.
	float nx = 0.0 - uy
	float ny = ux
	float low = 0.0
	float high = 0.0
	for i in range(count):
		float s = cast(float, points[i * 2]) * nx + cast(float, points[i * 2 + 1]) * ny
		if (i == 0 || s < low): low = s
		if (i == 0 || s > high): high = s
	float gap = cast(float, MM_ROUGH_GAP)
	int lines = cast(int, (high - low) / gap)
	if (lines > MM_ROUGH_MAX_LINES):
		gap = (high - low) / cast(float, MM_ROUGH_MAX_LINES)
		lines = MM_ROUGH_MAX_LINES
	list[int] hits = new list[int]
	for k in range(1, lines + 1):
		float level = low + cast(float, k) * gap
		while (hits.length > 0): hits.pop()
		for i in range(count):
			int j = (i + 1) % count
			float ax = cast(float, points[i * 2])
			float ay = cast(float, points[i * 2 + 1])
			float bx = cast(float, points[j * 2])
			float by = cast(float, points[j * 2 + 1])
			float sa = ax * nx + ay * ny
			float sb = bx * nx + by * ny
			if ((sa <= level && sb > level) || (sb <= level && sa > level)):
				float t = (level - sa) / (sb - sa)
				float px = ax + (bx - ax) * t
				float py = ay + (by - ay) * t
				# Position along the hachure direction, sorted by insertion.
				int along = cast(int, px * ux + py * uy)
				int at = hits.length
				hits.push(0)
				while (at > 0 && hits[at - 1] > along):
					hits[at] = hits[at - 1]
					at = at - 1
				hits[at] = along
		int pairs = hits.length / 2
		for p in range(pairs):
			float a = cast(float, hits[p * 2])
			float b = cast(float, hits[p * 2 + 1])
			int x1 = cast(int, level * nx + a * ux)
			int y1 = cast(int, level * ny + a * uy)
			int x2 = cast(int, level * nx + b * ux)
			int y2 = cast(int, level * ny + b * uy)
			mm_rough_pass(r, r.fills, x1, y1, x2, y2, 1)
	__w_list_free(cast(__w_list*, hits))

# Corner points of a box, with `radius` corners approximated by 4 segments each.
list[int] mm_rough_box_points(int x, int y, int x2, int y2, int radius):
	list[int] points = new list[int]
	if (radius <= 0):
		points.push(x)
		points.push(y)
		points.push(x2)
		points.push(y)
		points.push(x2)
		points.push(y2)
		points.push(x)
		points.push(y2)
		return points
	if (radius * 2 > x2 - x): radius = (x2 - x) / 2
	if (radius * 2 > y2 - y): radius = (y2 - y) / 2
	for corner in range(4):
		float cx = cast(float, x2 - radius)
		float cy = cast(float, y + radius)
		if (corner == 1): cy = cast(float, y2 - radius)
		if (corner == 2):
			cx = cast(float, x + radius)
			cy = cast(float, y2 - radius)
		if (corner == 3): cx = cast(float, x + radius)
		float start = cast(float, corner) * 1.5707963 - 1.5707963
		for i in range(5):
			float a = start + cast(float, i) * 1.5707963 / 4.0
			points.push(cast(int, cx + fcos(a) * cast(float, radius)))
			points.push(cast(int, cy + fsin(a) * cast(float, radius)))
	return points

# rough.js ellipse: two jittered closed curves of 9 steps each (curveStepCount),
# each point's radius varied, joined by Catmull-Rom segments.
void mm_rough_ellipse(mm_rough* r, int cx, int cy, int rx, int ry):
	for pass in range(2):
		float increment = 6.2831853 / 9.0
		float start = cast(float, mm_rough_offset(r, 500, 100)) / 1000.0 - 1.5707963
		int grow_x = rx + mm_rough_offset(r, rx / 20 + 5, 100)
		int grow_y = ry + mm_rough_offset(r, ry / 20 + 5, 100)
		list[int] ring = new list[int]
		for i in range(11):
			float a = start + cast(float, i) * increment
			int jx = mm_rough_offset(r, 10, 100)
			int jy = mm_rough_offset(r, 10, 100)
			ring.push(cx + jx + cast(int, fcos(a) * cast(float, grow_x)))
			ring.push(cy + jy + cast(int, fsin(a) * cast(float, grow_y)))
		int n = ring.length / 2
		for i in range(n - 1):
			int p0 = i - 1
			if (p0 < 0): p0 = 0
			int p3 = i + 2
			if (p3 > n - 1): p3 = n - 1
			int x0 = ring[p0 * 2]
			int y0 = ring[p0 * 2 + 1]
			int x1 = ring[i * 2]
			int y1 = ring[i * 2 + 1]
			int x2 = ring[(i + 1) * 2]
			int y2 = ring[(i + 1) * 2 + 1]
			int x3 = ring[p3 * 2]
			int y3 = ring[p3 * 2 + 1]
			mm_rough_curve(r.strokes, x1, y1, x1 + (x2 - x0) / 6, y1 + (y2 - y0) / 6, x2 - (x3 - x1) / 6, y2 - (y3 - y1) / 6, x2, y2)
		__w_list_free(cast(__w_list*, ring))

# Polygon of an ellipse for its hachure fill.
list[int] mm_rough_ellipse_points(int cx, int cy, int rx, int ry):
	list[int] points = new list[int]
	for i in range(24):
		float a = cast(float, i) * 6.2831853 / 24.0
		points.push(cx + cast(int, fcos(a) * cast(float, rx)))
		points.push(cy + cast(int, fsin(a) * cast(float, ry)))
	return points

# One scene primitive's strokes and fill. kind is the scene kind (1 line,
# 2 box, 4 circle, 5 polygon); coordinates are pixels, points the polygon's
# pixel coordinates; hatch asks for a hachure fill.
void mm_rough_shape(mm_rough* r, int kind, int x, int y, int x2, int y2, int radius, list[int] points, int hatch):
	if (kind == 1):
		mm_rough_line(r, x * 10, y * 10, x2 * 10, y2 * 10)
		return
	list[int] outline = 0
	if (kind == 2): outline = mm_rough_box_points(x * 10, y * 10, x2 * 10, y2 * 10, radius * 10)
	else if (kind == 4): outline = mm_rough_ellipse_points((x + x2) * 5, (y + y2) * 5, (x2 - x) * 5, (y2 - y) * 5)
	else if (kind == 5 && points != 0):
		outline = new list[int]
		for int value in points: outline.push(value * 10)
	if (outline == 0): return
	if (hatch): mm_rough_hachure(r, outline)
	if (kind == 4): mm_rough_ellipse(r, (x + x2) * 5, (y + y2) * 5, (x2 - x) * 5, (y2 - y) * 5)
	else: mm_rough_outline(r, outline)
	__w_list_free(cast(__w_list*, outline))
