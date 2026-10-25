# Family-specific geometry shared by SVG and the native desktop preview.
import libs.extras.mermaid.scene
import libs.extras.mermaid.style_render

char* mm_data_format(int value):
	string_builder* s = string_new()
	if (value < 0):
		string_append_char(s, '-')
		value = 0 - value
	string_append_int(s, value / 1000)
	int fraction = value % 1000
	if (fraction):
		string_append_char(s, '.')
		string_append_char(s, '0' + fraction / 100)
		if (fraction % 100): string_append_char(s, '0' + fraction / 10 % 10)
		if (fraction % 10): string_append_char(s, '0' + fraction % 10)
	char* result = s.data
	free(s)
	return result

void mm_data_value_text(mm_scene* s, int x, int y, int value):
	char* label = mm_data_format(value)
	mm_text(s, x, y, label)
	free(label)

int mm_data_scale(int value, int low, int high, int pixels):
	return cast(int, cast(float, value - low) / cast(float, high - low) * cast(float, pixels))

mm_primitive* mm_data_polygon(mm_scene* s):
	mm_draw(s, MM_POLYGON, 0, 0, 0, 0, 0, c"")
	mm_primitive* p = s.items[s.items.length - 1]
	p.points = new list[int]
	return p

void mm_data_vertex(mm_scene* s, mm_primitive* p, int x, int y):
	p.points.push(x)
	p.points.push(y)
	if (x + 40 > s.width): s.width = x + 40
	if (y + 40 > s.height): s.height = y + 40

# Consistent series colors and matching legend keys in every output backend.
# A configured theme repaints MM_ROLE_SERIES primitives from pie1..pie12
# (pie charts) or cScale0..cScale11 (other chart families).
int mm_data_series_color(int index):
	return mm_style_series_color(index)

void mm_data_series_paint(mm_scene* s, int start, int series):
	int color = mm_data_series_color(series)
	for i in range(start, s.items.length):
		mm_primitive* p = s.items[i]
		if (p.kind == MM_TEXT): continue
		p.style.mask = p.style.mask | 3
		p.style.stroke = color
		p.style.fill = p.style.stroke
		p.role = MM_ROLE_SERIES
		p.series = series

void mm_data_pie_render(mm_document* d, mm_scene* s):
	float sum = 0.0
	for mm_data_item* item in d.data.items: sum = sum + cast(float, item.a)
	float angle = -1.5707963
	int row = 0
	for mm_data_item* item in d.data.items:
		float sweep = cast(float, item.a) / sum * 6.2831853
		int steps = cast(int, sweep * 180.0 / 3.14159265 / 4.0) + 1
		int start = s.items.length
		mm_primitive* slice = mm_data_polygon(s)
		mm_data_vertex(s, slice, 250, 260)
		for j in range(steps + 1):
			float end = angle + sweep * cast(float, j) / cast(float, steps)
			int x = 250 + cast(int, fcos(end) * 180.0)
			int y = 260 + cast(int, fsin(end) * 180.0)
			mm_data_vertex(s, slice, x, y)
		mm_draw(s, MM_BOX, 472, 80 + row * 26, 488, 96 + row * 26, 0, c"")
		mm_data_series_paint(s, start, row)
		float middle = angle + sweep / 2.0
		int lx = 250 + cast(int, fcos(middle) * 125.0)
		int ly = 260 + cast(int, fsin(middle) * 125.0)
		int percent = cast(int, cast(float, item.a) / sum * 100000.0)
		# Dense slices retain their names and percentages in separate legend rows.
		# A 0.55 radian wedge has enough chord width for a percentage label.
		if (sweep >= 0.55):
			mm_data_value_text(s, lx - 16, ly - 8, percent)
			mm_primitive* label = s.items[s.items.length - 1]
			label.style.mask = 4
			label.style.text = 0xffffff
		mm_text(s, 500, 80 + row * 26, item.label)
		char* percentage = mm_data_format(percent)
		string_builder* label = string_from(percentage)
		string_append_char(label, '%')
		free(percentage)
		if (d.data.show_data):
			char* value = mm_data_format(item.a)
			string_append(label, c" (value: ")
			string_append(label, value)
			string_append_char(label, ')')
			free(value)
		mm_text(s, 520 + strlen(item.label) * 8, 80 + row * 26, label.data)
		string_free(label)
		angle = angle + sweep
		row = row + 1
	mm_text(s, 170, 470, c"Slice labels: percent")

void mm_data_quadrant_render(mm_document* d, mm_scene* s):
	mm_data_chart* c = d.data
	mm_draw(s, MM_BOX, 120, 80, 720, 580, 0, c"")
	mm_line(s, 420, 80, 420, 580, 0)
	mm_line(s, 120, 330, 720, 330, 0)
	mm_text(s, 120, 610, c.x_label)
	mm_text(s, 720 - strlen(c.x_end) * 8, 610, c.x_end)
	mm_text(s, 10, 560, c.y_label)
	mm_text(s, 10, 80, c.y_end)
	for mm_data_item* item in c.items:
		if (item.kind == 9): continue
		if (item.kind == 8):
			int x = 140
			int y = 100
			if (item.a == 1 || item.a == 4): x = 440
			if (item.a == 3 || item.a == 4): y = 350
			mm_text(s, x, y, item.label)
		else:
			int x = 120 + item.values[0] * 600 / 1000
			int y = 580 - item.values[1] * 500 / 1000
			int radius = item.radius
			if (radius == 0): radius = 4
			mm_draw(s, MM_CIRCLE, x - radius, y - radius, x + radius, y + radius, 0, c"")
			mm_primitive* point = s.items[s.items.length - 1]
			point.style = item.style
			if ((point.style.mask & 1) == 0):
				point.style.mask = point.style.mask | 1
				point.style.fill = d.palette.stroke
			mm_text(s, x + radius + 4, y - 18, item.label)

int mm_data_x_position(mm_data_chart* c, int index, int count, int width):
	if (c.x_numeric && count > 1): return index * width / (count - 1)
	return (index * 2 + 1) * width / (count * 2)

void mm_data_xy_render(mm_document* d, mm_scene* s):
	mm_data_chart* c = d.data
	int count = 0
	int bars = 0
	for mm_data_item* item in c.items:
		if (item.kind != 1): count = item.values.length
		if (item.kind == 3): bars = bars + 1
	int width = count * 64
	if (width < 600): width = 600
	int horizontal = c.horizontal
	int left = 140
	int top = 80
	int extent = 400
	int zero = mm_data_scale(0, c.low, c.high, extent)
	if (zero < 0): zero = 0
	if (zero > extent): zero = extent
	if (horizontal):
		mm_line(s, left, top, left, top + width, 0)
		mm_line(s, left, top + width, left + extent, top + width, 0)
	else:
		mm_line(s, left, top, left, top + extent, 0)
		mm_line(s, left, top + extent, left + width, top + extent, 0)
	for tick in range(6):
		int value = c.low + cast(int, cast(float, c.high - c.low) * cast(float, tick) / 5.0)
		if (horizontal):
			mm_data_value_text(s, left + tick * extent / 5 - 16, top + width + 24, value)
			mm_line(s, left + tick * extent / 5, top, left + tick * extent / 5, top + width, 1)
		else:
			mm_data_value_text(s, 20, top + extent - tick * extent / 5 - 8, value)
			mm_line(s, left, top + extent - tick * extent / 5, left + width, top + extent - tick * extent / 5, 1)
	int category = 0
	for mm_data_item* item in c.items:
		if (item.kind != 1): continue
		int position = mm_data_x_position(c, category, count, width)
		if (horizontal): mm_text(s, 10, top + position - 8, item.label)
		else: mm_text(s, left + position - strlen(item.label) * 4, top + extent + 20, item.label)
		category = category + 1
	if (category == 0):
		for i in range(count):
			int position = mm_data_x_position(c, i, count, width)
			int value = (i + 1) * 1000
			if (c.x_numeric):
				value = c.x_low
				if (count > 1): value = c.x_low + cast(int, cast(float, c.x_high - c.x_low) * cast(float, i) / cast(float, count - 1))
			if (horizontal): mm_data_value_text(s, 50, top + position - 8, value)
			else: mm_data_value_text(s, left + position - 4, top + extent + 20, value)
	int bar_index = 0
	int series_index = 0
	for mm_data_item* item in c.items:
		if (item.kind == 1): continue
		int last_x = 0
		int last_y = 0
		int series_start = s.items.length
		for i in range(count):
			int position = mm_data_x_position(c, i, count, width)
			int value = mm_data_scale(item.values[i], c.low, c.high, extent)
			int x = left + position
			int y = top + extent - value
			if (horizontal):
				x = left + value
				y = top + position
			if (item.kind == 2):
				if (i != 0): mm_line(s, last_x, last_y, x, y, series_index % 2)
				mm_draw(s, MM_CIRCLE, x - 3, y - 3, x + 3, y + 3, 1, c"")
			else:
				int band = width / count * 3 / 4
				int start = position - band / 2 + band * bar_index / bars
				int end = position - band / 2 + band * (bar_index + 1) / bars - 2
				int low = value
				int high = zero
				if (low > high):
					low = zero
					high = value
				if (horizontal): mm_draw(s, MM_BOX, left + low, top + start, left + high, top + end, 0, c"")
				else: mm_draw(s, MM_BOX, left + start, top + extent - high, left + end, top + extent - low, 0, c"")
			if (i < item.point_labels.length):
				char* label = item.point_labels[i]
				if (label[0] != 0): mm_text(s, x + 8, y - 20, label)
			last_x = x
			last_y = y
		if (item.kind == 3): bar_index = bar_index + 1
		if (item.label[0] != 0):
			int legend_y = top + extent + 80
			if (horizontal): legend_y = top + width + 80
			if (item.kind == 3): mm_draw(s, MM_BOX, left, legend_y + series_index * 24, left + 24, legend_y + series_index * 24 + 14, 0, c"")
			else: mm_line(s, left, legend_y + series_index * 24 + 7, left + 24, legend_y + series_index * 24 + 7, series_index % 2)
			mm_text(s, left + 36, legend_y + series_index * 24, item.label)
		mm_data_series_paint(s, series_start, series_index)
		series_index = series_index + 1
	if (horizontal):
		mm_text(s, left, top + width + 52, c.y_label)
		mm_text(s, 10, 44, c.x_label)
	else:
		mm_text(s, left, top + extent + 52, c.x_label)
		mm_text(s, 20, 44, c.y_label)

void mm_data_radar_render(mm_document* d, mm_scene* s):
	mm_data_chart* c = d.data
	list[mm_data_item*] axes = new list[mm_data_item*]
	for mm_data_item* item in c.items:
		if (item.kind == 1): axes.push(item)
	int count = axes.length
	for tick in range(1, c.ticks + 1):
		int radius = 200 * tick / c.ticks
		if (c.polygon == 0): mm_ellipse(s, 300, 300, radius, radius)
		else:
			for i in range(count):
				float a = cast(float, i) * 6.2831853 / cast(float, count) - 1.5707963
				float b = cast(float, i + 1) * 6.2831853 / cast(float, count) - 1.5707963
				mm_line(s, 300 + cast(int, fcos(a) * cast(float, radius)), 300 + cast(int, fsin(a) * cast(float, radius)), 300 + cast(int, fcos(b) * cast(float, radius)), 300 + cast(int, fsin(b) * cast(float, radius)), 1)
	for i in range(count):
		float angle = cast(float, i) * 6.2831853 / cast(float, count) - 1.5707963
		mm_data_item* axis = axes[i]
		mm_line(s, 300, 300, 300 + cast(int, fcos(angle) * 200.0), 300 + cast(int, fsin(angle) * 200.0), 0)
		mm_text(s, 300 + cast(int, fcos(angle) * 225.0) - strlen(axis.label) * 4, 300 + cast(int, fsin(angle) * 225.0) - 8, axis.label)
	int series = 0
	# Upstream draws circle-graticule curves as a closed Catmull-Rom style
	# spline: segment p1->p2 is a cubic with control points
	# p1 + (p2 - p0) * tension and p2 - (p3 - p1) * tension (radar.curveTension,
	# default 0.17). Polygon graticules keep straight edges.
	float tension = 0.17
	if (d.config_mask & 4): tension = cast(float, d.radar_tension) / 1000.0
	list[int] px = new list[int]
	list[int] py = new list[int]
	for mm_data_item* item in c.items:
		if (item.kind != 4): continue
		int series_start = s.items.length
		px.clear()
		py.clear()
		for i in range(count):
			float a = cast(float, i) * 6.2831853 / cast(float, count) - 1.5707963
			int r1 = mm_data_scale(item.values[i], c.low, c.high, 200)
			px.push(300 + cast(int, fcos(a) * cast(float, r1)))
			py.push(300 + cast(int, fsin(a) * cast(float, r1)))
		for i in range(count):
			int j = (i + 1) % count
			int x = px[i]
			int y = py[i]
			if (c.polygon == 0):
				int h = (i + count - 1) % count
				int k = (i + 2) % count
				int c1x = x + cast(int, cast(float, px[j] - px[h]) * tension)
				int c1y = y + cast(int, cast(float, py[j] - py[h]) * tension)
				int c2x = px[j] - cast(int, cast(float, px[k] - x) * tension)
				int c2y = py[j] - cast(int, cast(float, py[k] - y) * tension)
				mm_style_bezier(s, x, y, c1x, c1y, c2x, c2y, px[j], py[j], series % 2)
			else: mm_line(s, x, y, px[j], py[j], series % 2)
			mm_draw(s, MM_CIRCLE, x - 3, y - 3, x + 3, y + 3, series % 2, c"")
		if (c.legend):
			mm_line(s, 580, 100 + series * 28, 620, 100 + series * 28, series % 2)
			mm_text(s, 630, 92 + series * 28, item.label)
		mm_data_series_paint(s, series_start, series)
		series = series + 1
	mm_data_value_text(s, 310, 300, c.low)
	mm_data_value_text(s, 310, 100, c.high)
	__w_list_free(cast(__w_list*, axes))
	__w_list_free(cast(__w_list*, px))
	__w_list_free(cast(__w_list*, py))

float mm_data_tree_weight(mm_data_chart* c, int index):
	mm_data_item* item = c.items[index]
	if (item.kind != 5): return cast(float, item.a)
	float sum = 0.0
	for i in range(c.items.length):
		mm_data_item* child = c.items[i]
		if (child.parent == index): sum = sum + mm_data_tree_weight(c, i)
	return sum

# Squarify rows in descending weight order, minimizing the worst aspect ratio.
float mm_data_tree_worst(float sum, float smallest, float largest, float side):
	float square = side * side
	float worst = square * largest / (sum * sum)
	float other = sum * sum / (square * smallest)
	if (other > worst): worst = other
	return worst

void mm_data_tree_render_level(mm_data_chart* c, mm_scene* s, int parent, int x, int y, int width, int height, int depth):
	list[int] children = new list[int]
	float total = 0.0
	for i in range(c.items.length):
		mm_data_item* item = c.items[i]
		if (item.parent != parent): continue
		children.push(i)
		total = total + mm_data_tree_weight(c, i)
	# Stable insertion sort keeps equal-weight layouts deterministic.
	for i in range(1, children.length):
		int child = children[i]
		float weight = mm_data_tree_weight(c, child)
		int j = i
		while (j > 0):
			if (mm_data_tree_weight(c, children[j - 1]) >= weight): break
			children[j] = children[j - 1]
			j = j - 1
		children[j] = child
	int start = 0
	while (start < children.length && width > 0 && height > 0):
		float scale = cast(float, width) * cast(float, height) / total
		float side = cast(float, height)
		if (width < height): side = cast(float, width)
		float row_weight = mm_data_tree_weight(c, children[start])
		float largest = row_weight * scale
		float smallest = largest
		float area = largest
		int end = start + 1
		while (end < children.length):
			float next = mm_data_tree_weight(c, children[end])
			float next_area = next * scale
			if (mm_data_tree_worst(area + next_area, next_area, largest, side) > mm_data_tree_worst(area, smallest, largest, side)): break
			row_weight = row_weight + next
			area = area + next_area
			smallest = next_area
			end = end + 1
		int strip = cast(int, area / side)
		int available = width
		if (width < height): available = height
		if (strip < 1): strip = 1
		if (strip > available || end == children.length): strip = available
		float used = 0.0
		for j in range(start, end):
			int index = children[j]
			mm_data_item* item = c.items[index]
			float weight = mm_data_tree_weight(c, index)
			int xx = x
			int yy = y
			int ww = strip
			int hh = height
			if (width >= height):
				yy = y + cast(int, used / row_weight * cast(float, height))
				hh = y + cast(int, (used + weight) / row_weight * cast(float, height)) - yy
				if (j + 1 == end): hh = y + height - yy
			else:
				xx = x + cast(int, used / row_weight * cast(float, width))
				ww = x + cast(int, (used + weight) / row_weight * cast(float, width)) - xx
				if (j + 1 == end): ww = x + width - xx
				hh = strip
			int style_start = s.items.length
			mm_draw(s, MM_BOX, xx, yy, xx + ww, yy + hh, 0, c"")
			# Labels in tiny cells go to a legend rather than crossing boundaries.
			if (ww > strlen(item.label) * 8 + 12 && hh > 26): mm_text(s, xx + 6, yy + 6, item.label)
			# classDef styles resolved at validation; they outrank the theme.
			for k in range(style_start, s.items.length):
				mm_primitive* cell = s.items[k]
				if (item.style.mask != 0): cell.node_style = 1
				mm_style_merge(&cell.style, &item.style)
			if (item.kind == 5):
				if (ww > 20 && hh > 40): mm_data_tree_render_level(c, s, index, xx + 4, yy + 26, ww - 8, hh - 30, depth + 1)
			used = used + weight
		if (width >= height):
			x = x + strip
			width = width - strip
		else:
			y = y + strip
			height = height - strip
		total = total - row_weight
		start = end
	__w_list_free(cast(__w_list*, children))

void mm_data_tree_render(mm_document* d, mm_scene* s):
	mm_data_tree_render_level(d.data, s, -1, 40, 80, 900, 600, 0)
	int row = 0
	for mm_data_item* item in d.data.items:
		mm_text(s, 980 + item.depth * 3, 80 + row * 24, item.label)
		if (item.kind != 5): mm_data_value_text(s, 1000 + item.depth * 3 + strlen(item.label) * 8, 80 + row * 24, item.a)
		row = row + 1

void mm_data_packet_render(mm_document* d, mm_scene* s):
	int bits = d.packet_bits
	int word_width = bits * 24
	for mm_data_item* item in d.data.items:
		int first = item.a
		while (first <= item.b):
			int last = (first / bits + 1) * bits - 1
			if (last > item.b): last = item.b
			int x = 60 + first % bits * 24
			int y = 80 + first / bits * 90
			int right = 60 + (last % bits + 1) * 24
			int left_bit = first
			int right_bit = last
			if (d.packet_msb):
				x = 60 + word_width - (last % bits + 1) * 24
				right = 60 + word_width - first % bits * 24
				left_bit = last
				right_bit = first
			mm_draw(s, MM_BOX, x, y, right, y + 60, 0, c"")
			mm_data_value_text(s, x + 2, y - 20, left_bit * 1000)
			if (last != first): mm_data_value_text(s, right - 24, y - 20, right_bit * 1000)
			if (strlen(item.label) * 8 < right - x - 4): mm_text(s, x + (right - x - strlen(item.label) * 8) / 2, y + 22, item.label)
			else:
				# Bit-width geometry remains proportional; narrow field labels use a key.
				mm_data_value_text(s, x + 2, y + 22, (item.a + 1) * 1000)
				string_builder* text = string_new()
				string_append_int(text, item.a + 1)
				string_append(text, c": ")
				string_append(text, item.label)
				mm_text(s, 112 + word_width, 80 + cast(int, d.data.items.index(item)) * 24, text.data)
				string_free(text)
			first = last + 1

float mm_data_venn_overlap(float first, float second, float distance):
	float small = first
	if (second < small): small = second
	float difference = first - second
	if (difference < 0.0): difference = 0.0 - difference
	if (distance <= difference): return 3.14159265 * small * small
	if (distance >= first + second): return 0.0
	float a = (distance * distance + first * first - second * second) / (2.0 * distance * first)
	float b = (distance * distance + second * second - first * first) / (2.0 * distance * second)
	if (a > 1.0): a = 1.0
	if (a < -1.0): a = -1.0
	if (b > 1.0): b = 1.0
	if (b < -1.0): b = -1.0
	float product = (first + second - distance) * (distance + first - second) * (distance - first + second) * (distance + first + second)
	return first * first * facos(a) + second * second * facos(b) - fsqrt(product) / 2.0

int mm_data_venn_distance(int first, int second, float area):
	float low = cast(float, first - second)
	if (low < 0.0): low = 0.0 - low
	float high = cast(float, first + second)
	for i in range(32):
		float middle = (low + high) / 2.0
		if (mm_data_venn_overlap(cast(float, first), cast(float, second), middle) > area): low = middle
		else: high = middle
	return cast(int, (low + high) / 2.0)

void mm_data_venn_texts(mm_document* d, mm_scene* s, int parent, int x, int y):
	for mm_data_item* item in d.data.items:
		if (item.kind != 10 || item.parent != parent): continue
		mm_text(s, x - strlen(item.label) * 4, y, item.label)
		y = y + 20

# Distance between circle centers whose lens has the given area (bisection).
float mm_venn_target(float first, float second, float area):
	float low = first - second
	if (low < 0.0): low = 0.0 - low
	float high = first + second
	for i in range(48):
		float middle = (low + high) / 2.0
		if (mm_data_venn_overlap(first, second, middle) > area): low = middle
		else: high = middle
	return (low + high) / 2.0

# Pairwise stress of a layout. kinds: 0 exact target, 1 disjoint (only
# closer than the target is penalized), 2 nested (only farther is penalized).
# Only the first `limit` sets in `order` take part (greedy placement).
float mm_venn_loss(list[float] xs, list[float] ys, list[float] targets, list[int] kinds, list[int] order, int limit, int n):
	float loss = 0.0
	for a in range(limit):
		for b in range(a + 1, limit):
			int i = order[a]
			int j = order[b]
			float dx = xs[i] - xs[j]
			float dy = ys[i] - ys[j]
			float distance = fsqrt(dx * dx + dy * dy)
			float diff = distance - targets[i * n + j]
			int kind = kinds[i * n + j]
			if ((kind == 1 && diff > 0.0) || (kind == 2 && diff < 0.0)): diff = 0.0
			loss = loss + diff * diff
	return loss

# Best label point of a region: inside every member circle and outside every
# other one, maximizing the clearance to the nearest boundary (grid search
# with two refinements). Returns the clearance; the point is pushed to out.
float mm_venn_region_point(list[float] xs, list[float] ys, list[float] rs, int n, list[int] members, list[float] out):
	int smallest = members[0]
	for int m in members:
		if (rs[m] < rs[smallest]): smallest = m
	float cx = xs[smallest]
	float cy = ys[smallest]
	float extent = rs[smallest]
	float best = -1000000.0
	float bx = cx
	float by = cy
	for round in range(3):
		for gy in range(21):
			for gx in range(21):
				float x = cx + extent * (cast(float, gx) / 10.0 - 1.0)
				float y = cy + extent * (cast(float, gy) / 10.0 - 1.0)
				float score = 1000000.0
				for i in range(n):
					float dx = x - xs[i]
					float dy = y - ys[i]
					float margin = fsqrt(dx * dx + dy * dy) - rs[i]
					if (members.index(i) >= 0): margin = 0.0 - margin
					if (margin < score): score = margin
				if (score > best):
					best = score
					bx = x
					by = y
		cx = bx
		cy = by
		extent = extent / 5.0
	out.push(bx)
	out.push(by)
	return best

# Upstream (venn.js) style layout for three sized sets and for four to eight
# sets: radii follow set sizes, pairwise target distances follow the sizes of
# two-set unions (unions of three or more sets imply missing pairs at a
# quarter of the smaller set, as upstream does), and centers are placed
# greedily then refined by constrained gradient descent on the pairwise
# distance stress. Higher-order region areas are labeled, not fitted.
void mm_data_venn_general(mm_document* d, mm_scene* s, list[int] ids):
	int n = ids.length
	list[float] rs = new list[float]
	list[float] xs = new list[float]
	list[float] ys = new list[float]
	list[float] overlap = new list[float]
	list[float] targets = new list[float]
	list[int] kinds = new list[int]
	for i in range(n):
		mm_data_item* set_item = d.data.items[ids[i]]
		rs.push(fsqrt(cast(float, set_item.a) / 1000.0 / 3.14159265))
		xs.push(0.0)
		ys.push(0.0)
	for i in range(n * n):
		overlap.push(-1.0)
		targets.push(0.0)
		kinds.push(0)
	for pass in range(2):
		for mm_data_item* item in d.data.items:
			if (item.kind != 7): continue
			if ((pass == 0) != (item.values.length == 2)): continue
			for int a in item.values:
				for int b in item.values:
					int i = ids.index(a)
					int j = ids.index(b)
					if (i == j || overlap[i * n + j] >= 0.0): continue
					if (pass == 0): overlap[i * n + j] = cast(float, item.a) / 1000.0
					else:
						mm_data_item* first = d.data.items[a]
						mm_data_item* second = d.data.items[b]
						int smaller = first.a
						if (second.a < smaller): smaller = second.a
						overlap[i * n + j] = cast(float, smaller) / 4000.0
	list[float] totals = new list[float]
	for i in range(n):
		float total = 0.0
		for j in range(n):
			if (i == j): continue
			float area = overlap[i * n + j]
			if (area < 0.0): area = 0.0
			total = total + area
			float small = rs[i]
			if (rs[j] < small): small = rs[j]
			float full = 3.14159265 * small * small
			if (area <= 0.0):
				targets[i * n + j] = rs[i] + rs[j]
				kinds[i * n + j] = 1
			else if (area >= full * 0.999):
				float nested = rs[i] - rs[j]
				if (nested < 0.0): nested = 0.0 - nested
				targets[i * n + j] = nested
				kinds[i * n + j] = 2
			else: targets[i * n + j] = mm_venn_target(rs[i], rs[j], area)
		totals.push(total)
	# Greedy placement, most-overlapping set first.
	list[int] order = new list[int]
	for k in range(n):
		int pick = -1
		for i in range(n):
			if (order.index(i) >= 0): continue
			if (pick < 0 || totals[i] > totals[pick]): pick = i
		order.push(pick)
	for k in range(1, n):
		int current = order[k]
		float best = -1.0
		float best_x = 0.0
		float best_y = 0.0
		for p in range(k):
			int placed = order[p]
			for step in range(24):
				float angle = cast(float, step) * 6.2831853 / 24.0
				xs[current] = xs[placed] + fcos(angle) * targets[current * n + placed]
				ys[current] = ys[placed] + fsin(angle) * targets[current * n + placed]
				float loss = mm_venn_loss(xs, ys, targets, kinds, order, k + 1, n)
				if (best < 0.0 || loss < best - 0.0000001):
					best = loss
					best_x = xs[current]
					best_y = ys[current]
		xs[current] = best_x
		ys[current] = best_y
	# Constrained gradient descent with a shrinking step.
	float rate = 0.1
	float loss = mm_venn_loss(xs, ys, targets, kinds, order, n, n)
	list[float] gx = new list[float]
	list[float] gy = new list[float]
	for i in range(n):
		gx.push(0.0)
		gy.push(0.0)
	for iteration in range(400):
		if (loss < 0.000001 || rate < 0.00001): break
		for i in range(n):
			gx[i] = 0.0
			gy[i] = 0.0
		for i in range(n):
			for j in range(i + 1, n):
				float dx = xs[i] - xs[j]
				float dy = ys[i] - ys[j]
				float distance = fsqrt(dx * dx + dy * dy)
				if (distance < 0.000001): distance = 0.000001
				float diff = distance - targets[i * n + j]
				int kind = kinds[i * n + j]
				if ((kind == 1 && diff > 0.0) || (kind == 2 && diff < 0.0)): continue
				float factor = 2.0 * diff / distance
				gx[i] = gx[i] + factor * dx
				gy[i] = gy[i] + factor * dy
				gx[j] = gx[j] - factor * dx
				gy[j] = gy[j] - factor * dy
		for i in range(n):
			xs[i] = xs[i] - rate * gx[i]
			ys[i] = ys[i] - rate * gy[i]
		float next = mm_venn_loss(xs, ys, targets, kinds, order, n, n)
		if (next > loss):
			for i in range(n):
				xs[i] = xs[i] + rate * gx[i]
				ys[i] = ys[i] + rate * gy[i]
			rate = rate / 2.0
		else:
			loss = next
			rate = rate * 1.1
	# Fit into the drawing area (900 x 540 at (60, 70)).
	float left = 1000000.0
	float top = 1000000.0
	float right = -1000000.0
	float bottom = -1000000.0
	for i in range(n):
		if (xs[i] - rs[i] < left): left = xs[i] - rs[i]
		if (ys[i] - rs[i] < top): top = ys[i] - rs[i]
		if (xs[i] + rs[i] > right): right = xs[i] + rs[i]
		if (ys[i] + rs[i] > bottom): bottom = ys[i] + rs[i]
	float scale = 900.0 / (right - left)
	if (540.0 / (bottom - top) < scale): scale = 540.0 / (bottom - top)
	for i in range(n):
		xs[i] = 60.0 + (xs[i] - left) * scale
		ys[i] = 70.0 + (ys[i] - top) * scale
		rs[i] = rs[i] * scale
		if (rs[i] < 1.0): rs[i] = 1.0
	list[float] point = new list[float]
	list[int] members = new list[int]
	for i in range(n):
		mm_data_item* item = d.data.items[ids[i]]
		mm_ellipse(s, cast(int, xs[i]), cast(int, ys[i]), cast(int, rs[i]), cast(int, rs[i]))
		members.clear()
		members.push(i)
		point.clear()
		mm_venn_region_point(xs, ys, rs, n, members, point)
		int x = cast(int, point[0])
		int y = cast(int, point[1])
		mm_text(s, x - mm_text_width(item.label, 0) / 2, y - 8, item.label)
		mm_data_venn_texts(d, s, ids[i], x, y + 14)
	for item_index in range(d.data.items.length):
		mm_data_item* item = d.data.items[item_index]
		if (item.kind != 7): continue
		members.clear()
		for int value in item.values: members.push(ids.index(value))
		point.clear()
		mm_venn_region_point(xs, ys, rs, n, members, point)
		int x = cast(int, point[0])
		int y = cast(int, point[1])
		mm_text(s, x - mm_text_width(item.label, 0) / 2, y - 8, item.label)
		mm_data_venn_texts(d, s, item_index, x, y + 14)
	__w_list_free(cast(__w_list*, rs))
	__w_list_free(cast(__w_list*, xs))
	__w_list_free(cast(__w_list*, ys))
	__w_list_free(cast(__w_list*, overlap))
	__w_list_free(cast(__w_list*, targets))
	__w_list_free(cast(__w_list*, kinds))
	__w_list_free(cast(__w_list*, totals))
	__w_list_free(cast(__w_list*, order))
	__w_list_free(cast(__w_list*, gx))
	__w_list_free(cast(__w_list*, gy))
	__w_list_free(cast(__w_list*, point))
	__w_list_free(cast(__w_list*, members))

void mm_data_venn_render(mm_document* d, mm_scene* s):
	list[int] general = new list[int]
	int general_sized = 0
	for i in range(d.data.items.length):
		mm_data_item* item = d.data.items[i]
		if (item.kind == 6): general.push(i)
		if ((item.kind == 6 || item.kind == 7) && item.b): general_sized = 1
	if (general.length > 3 || (general_sized && general.length == 3)):
		mm_data_venn_general(d, s, general)
		__w_list_free(cast(__w_list*, general))
		return
	__w_list_free(cast(__w_list*, general))
	list[int] ids = new list[int]
	list[int] xs = new list[int]
	list[int] ys = new list[int]
	list[int] radii = new list[int]
	int sized = 0
	for i in range(d.data.items.length):
		mm_data_item* item = d.data.items[i]
		if (item.kind == 6): ids.push(i)
		if ((item.kind == 6 || item.kind == 7) && item.b): sized = 1
		xs.push(0)
		ys.push(260)
		radii.push(170)
	int count = ids.length
	list[int] connected = new list[int]
	for i in range(9): connected.push(0)
	int triple = 0
	for mm_data_item* item in d.data.items:
		if (item.kind != 7): continue
		if (item.values.length == 3): triple = 1
		for int a in item.values:
			for int b in item.values:
				int ai = ids.index(a)
				int bi = ids.index(b)
				if (ai != bi): connected[ai * 3 + bi] = 1
	int pairs = 0
	for i in range(count):
		for j in range(i + 1, count):
			if (connected[i * 3 + j]): pairs = pairs + 1
	for i in range(count): xs[ids[i]] = 250 + i * 400
	if (count == 2 && pairs == 1):
		xs[ids[0]] = 270
		xs[ids[1]] = 440
	if (count == 3 && pairs == 1):
		for i in range(count):
			for j in range(i + 1, count):
				if (connected[i * 3 + j] == 0): continue
				xs[ids[i]] = 270
				xs[ids[j]] = 440
				xs[ids[3 - i - j]] = 850
	if (count == 3 && pairs == 2):
		for i in range(count):
			int degree = 0
			for j in range(count): degree = degree + connected[i * 3 + j]
			if (degree != 2): continue
			xs[ids[i]] = 550
			xs[ids[(i + 1) % 3]] = 280
			xs[ids[(i + 2) % 3]] = 820
	if (count == 3 && pairs == 3):
		if (triple):
			xs[ids[0]] = 270
			xs[ids[1]] = 440
			xs[ids[2]] = 355
			ys[ids[2]] = 400
		else:
			# Pairwise intersections without a specified triple intersection.
			xs[ids[0]] = 240
			xs[ids[1]] = 550
			xs[ids[2]] = 395
			ys[ids[2]] = 528
	if (sized && count == 2):
		mm_data_item* first = d.data.items[ids[0]]
		mm_data_item* second = d.data.items[ids[1]]
		int maximum = first.a
		if (second.a > maximum): maximum = second.a
		radii[ids[0]] = cast(int, 170.0 * fsqrt(cast(float, first.a) / cast(float, maximum)))
		radii[ids[1]] = cast(int, 170.0 * fsqrt(cast(float, second.a) / cast(float, maximum)))
		for int id in ids:
			if (radii[id] < 1): radii[id] = 1
		int distance = radii[ids[0]] + radii[ids[1]] + 60
		for mm_data_item* region in d.data.items:
			if (region.kind != 7): continue
			float area = cast(float, region.a) / cast(float, maximum) * 3.14159265 * 170.0 * 170.0
			distance = mm_data_venn_distance(radii[ids[0]], radii[ids[1]], area)
		xs[ids[0]] = 250
		xs[ids[1]] = 250 + distance
	for i in range(count):
		mm_data_item* item = d.data.items[ids[i]]
		int x = xs[ids[i]]
		int y = ys[ids[i]]
		int radius = radii[ids[i]]
		mm_ellipse(s, x, y, radius, radius)
		int ty = y - radius + 55
		if (count == 3 && pairs == 3 && i == 2): ty = y + 110
		mm_text(s, x - strlen(item.label) * 4, ty, item.label)
		mm_data_venn_texts(d, s, ids[i], x, ty + 22)
	for item_index in range(d.data.items.length):
		mm_data_item* item = d.data.items[item_index]
		if (item.kind != 7): continue
		int x = 0
		int y = 0
		for int i in item.values:
			x = x + xs[i]
			y = y + ys[i]
		x = x / item.values.length
		y = y / item.values.length
		if (triple && item.values.length == 2):
			x = 355 + (x - 355) * 2
			y = 306 + (y - 306) * 2
		if (sized && count == 2):
			int left = xs[ids[0]] - radii[ids[0]]
			int right = xs[ids[0]] + radii[ids[0]]
			if (xs[ids[1]] - radii[ids[1]] > left): left = xs[ids[1]] - radii[ids[1]]
			if (xs[ids[1]] + radii[ids[1]] < right): right = xs[ids[1]] + radii[ids[1]]
			x = (left + right) / 2
		mm_text(s, x - strlen(item.label) * 4, y - 8, item.label)
		mm_data_venn_texts(d, s, item_index, x, y + 14)
	__w_list_free(cast(__w_list*, ids))
	__w_list_free(cast(__w_list*, connected))
	__w_list_free(cast(__w_list*, xs))
	__w_list_free(cast(__w_list*, ys))
	__w_list_free(cast(__w_list*, radii))

struct mm_data_flow_node:
	float incoming
	float outgoing
	float total
	float in_used
	float out_used
	int rank
	int x
	int y
	int height

int mm_data_text_lines(char* text):
	int count = 1
	for i in range(strlen(text)):
		if (text[i] == 10): count = count + 1
	return count

void mm_data_multiline_text(mm_scene* s, int x, int y, char* text):
	int start = 0
	int length = strlen(text)
	for i in range(length + 1):
		if (i < length && text[i] != 10): continue
		int end = i
		if (end > start && text[end - 1] == 13): end = end - 1
		char* line = str_copy_range(text, start, end)
		mm_text(s, x, y, line)
		free(line)
		start = i + 1
		y = y + 18

# Weighted predecessor centers put strongly connected flows near each other.
float mm_data_flow_center(mm_document* d, list[mm_data_flow_node*] nodes, int index):
	float center = 0.0
	float total = 0.0
	for mm_data_item* flow in d.data.items:
		if (flow.b != index): continue
		mm_data_flow_node* from = nodes[flow.parent]
		center = center + cast(float, from.y + from.height / 2) * cast(float, flow.a)
		total = total + cast(float, flow.a)
	if (total == 0.0): return 0.0
	return center / total

void mm_data_sankey_render(mm_document* d, mm_scene* s):
	list[mm_data_flow_node*] nodes = new list[mm_data_flow_node*]
	for i in range(d.nodes.length):
		mm_data_flow_node* node = new mm_data_flow_node()
		node.rank = -1
		nodes.push(node)
	for mm_data_item* item in d.data.items:
		mm_data_flow_node* from = nodes[item.parent]
		mm_data_flow_node* to = nodes[item.b]
		from.outgoing = from.outgoing + cast(float, item.a)
		to.incoming = to.incoming + cast(float, item.a)
	for mm_data_flow_node* node in nodes:
		node.total = node.incoming
		if (node.outgoing > node.total): node.total = node.outgoing
	int ranks = 0
	for pass in range(nodes.length):
		for i in range(nodes.length):
			mm_data_flow_node* node = nodes[i]
			if (node.rank >= 0): continue
			int rank = 0
			int ready = 1
			for mm_data_item* item in d.data.items:
				if (item.b != i): continue
				mm_data_flow_node* from = nodes[item.parent]
				if (from.rank < 0): ready = 0
				else if (from.rank + 1 > rank): rank = from.rank + 1
			if (ready):
				node.rank = rank
				if (rank + 1 > ranks): ranks = rank + 1
	float maximum = 0.0
	int max_count = 0
	for rank in range(ranks):
		float sum = 0.0
		int count = 0
		for mm_data_flow_node* node in nodes:
			if (node.rank == rank):
				sum = sum + node.total
				count = count + 1
		if (sum > maximum): maximum = sum
		if (count > max_count): max_count = count
	float scale = 500.0 / maximum
	for rank in range(ranks):
		list[int] ordered = new list[int]
		for i in range(nodes.length):
			mm_data_flow_node* node = nodes[i]
			if (node.rank == rank): ordered.push(i)
		for i in range(1, ordered.length):
			int node_id = ordered[i]
			float center = mm_data_flow_center(d, nodes, node_id)
			int j = i
			while (j > 0):
				if (mm_data_flow_center(d, nodes, ordered[j - 1]) <= center): break
				ordered[j] = ordered[j - 1]
				j = j - 1
			ordered[j] = node_id
		int y = 100
		for int i in ordered:
			mm_data_flow_node* node = nodes[i]
			mm_node* named = d.nodes[i]
			y = y + (mm_data_text_lines(named.label) - 1) * 18
			node.x = 80 + rank * 280
			node.y = y
			node.height = cast(int, node.total * scale)
			if (node.height < 1): node.height = 1
			y = y + node.height + 50
		__w_list_free(cast(__w_list*, ordered))
	for mm_data_item* item in d.data.items:
		mm_data_flow_node* from = nodes[item.parent]
		mm_data_flow_node* to = nodes[item.b]
		int ay = from.y + cast(int, from.out_used * scale)
		int by = to.y + cast(int, to.in_used * scale)
		int ah = from.y + cast(int, (from.out_used + cast(float, item.a)) * scale)
		int bh = to.y + cast(int, (to.in_used + cast(float, item.a)) * scale)
		mm_primitive* ribbon = mm_data_polygon(s)
		for j in range(17):
			float t = cast(float, j) / 16.0
			float smooth = t * t * (3.0 - 2.0 * t)
			int xx = from.x + 20 + cast(int, cast(float, to.x - from.x - 20) * t)
			mm_data_vertex(s, ribbon, xx, ay + cast(int, cast(float, by - ay) * smooth))
		for j in range(17):
			float t = cast(float, 16 - j) / 16.0
			float smooth = t * t * (3.0 - 2.0 * t)
			int xx = from.x + 20 + cast(int, cast(float, to.x - from.x - 20) * t)
			mm_data_vertex(s, ribbon, xx, ah + cast(int, cast(float, bh - ah) * smooth))
		mm_data_value_text(s, (from.x + to.x) / 2, (ay + by + ah + bh) / 4, item.a)
		from.out_used = from.out_used + cast(float, item.a)
		to.in_used = to.in_used + cast(float, item.a)
	for i in range(nodes.length):
		mm_data_flow_node* node = nodes[i]
		mm_node* named = d.nodes[i]
		mm_draw(s, MM_BOX, node.x, node.y, node.x + 20, node.y + node.height, 2, c"")
		mm_data_multiline_text(s, node.x, node.y - 24 - (mm_data_text_lines(named.label) - 1) * 18, named.label)
	for mm_data_flow_node* node in nodes: free(node)
	__w_list_free(cast(__w_list*, nodes))

# Centered labels can extend left/up from a small chart. Translate the complete
# display list so native clipping and SVG viewBox retain those labels equally.
void mm_data_fit_scene(mm_scene* s):
	int min_x = 0
	int min_y = 0
	for mm_primitive* p in s.items:
		if (p.x < min_x): min_x = p.x
		if (p.y < min_y): min_y = p.y
		if (p.kind != MM_TEXT):
			if (p.x2 < min_x): min_x = p.x2
			if (p.y2 < min_y): min_y = p.y2
		if (p.points != 0):
			for i in range(p.points.length / 2):
				if (p.points[i * 2] < min_x): min_x = p.points[i * 2]
				if (p.points[i * 2 + 1] < min_y): min_y = p.points[i * 2 + 1]
	if (min_x == 0 && min_y == 0): return
	int dx = 0
	int dy = 0
	if (min_x < 0): dx = 40 - min_x
	if (min_y < 0): dy = 40 - min_y
	for mm_primitive* p in s.items:
		p.x = p.x + dx
		p.y = p.y + dy
		p.x2 = p.x2 + dx
		p.y2 = p.y2 + dy
		if (p.points != 0):
			for i in range(p.points.length / 2):
				p.points[i * 2] = p.points[i * 2] + dx
				p.points[i * 2 + 1] = p.points[i * 2 + 1] + dy
	s.width = s.width + dx
	s.height = s.height + dy

mm_scene* mm_data_render(mm_document* d):
	mm_scene* s = new mm_scene()
	s.items = new list[mm_primitive*]
	s.nodes = new list[mm_bounds*]
	s.width = 400
	s.height = 300
	char* title = d.title
	if (title[0] == 0): title = d.data.title
	if (title[0] != 0):
		mm_text(s, 40, 20, title)
		s.has_title = 1
	if (d.kind == MM_PIE): mm_data_pie_render(d, s)
	else if (d.kind == MM_QUADRANT): mm_data_quadrant_render(d, s)
	else if (d.kind == MM_XY): mm_data_xy_render(d, s)
	else if (d.kind == MM_SANKEY): mm_data_sankey_render(d, s)
	else if (d.kind == MM_RADAR): mm_data_radar_render(d, s)
	else if (d.kind == MM_TREEMAP): mm_data_tree_render(d, s)
	else if (d.kind == MM_VENN): mm_data_venn_render(d, s)
	else: mm_data_packet_render(d, s)
	mm_data_fit_scene(s)
	return s
