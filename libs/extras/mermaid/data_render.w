# Family-specific geometry shared by SVG and the native desktop preview.
import libs.extras.mermaid.scene
import libs.extras.mermaid.style_render
import libs.extras.mermaid.text

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

# Document styles (classDef, ':::', style rules) on primitives from start on;
# theme role paint leaves the fields they set alone.
void mm_data_style_apply(mm_scene* s, int start, mm_style* style):
	if (style.mask == 0): return
	for i in range(start, s.items.length):
		mm_primitive* p = s.items[i]
		p.node_style = 1
		p.user_mask = p.user_mask | style.mask
		mm_style_merge(&p.style, style)

# A sampled outline around (cx,cy) of radius r as a fillable polygon.
mm_primitive* mm_data_disc(mm_scene* s, int cx, int cy, int r):
	mm_primitive* p = mm_data_polygon(s)
	for k in range(48):
		float angle = cast(float, k) * 6.2831853 / 48.0
		mm_data_vertex(s, p, cx + cast(int, fcos(angle) * cast(float, r)), cy + cast(int, fsin(angle) * cast(float, r)))
	return p

# Pie geometry. Wedges wide enough (0.55 radians of chord) carry their
# rounded percentage ("25%") inside, as upstream's textPosition labels. Narrower wedges get
# an outside label beside the pie on the side their middle points to,
# joined to the rim by a two-segment leader (issue #817). Each side's
# labels keep their angular order and are pushed apart to one label pitch,
# first downwards and then, where the stack overruns the bottom, back
# upwards, so no two overlap and leaders on one side never cross.
const int MM_DATA_PIE_CX = 250
const int MM_DATA_PIE_CY = 260
const int MM_DATA_PIE_R = 180
const int MM_DATA_PIE_LABEL_GAP = 18
# Leader elbow radius and the label column's offset from the center.
const int MM_DATA_PIE_ELBOW = 194
const int MM_DATA_PIE_COLUMN = 214

# Resolve one side's label tops (desired, in angular order) in place:
# overlapping neighbours merge into clusters centered on their members'
# desired positions (one pitch apart), then the stack shifts into
# [low, high] when it overruns, preferring low.
void mm_data_pie_spread(list[int] tops, int low, int high):
	int n = tops.length
	if (n == 0): return
	list[int] starts = new list[int]
	list[int] counts = new list[int]
	list[int] firsts = new list[int]
	for k in range(n):
		starts.push(k)
		counts.push(1)
		firsts.push(tops[k])
		while (starts.length >= 2):
			int last = starts.length - 1
			int before = last - 1
			if (firsts[before] + counts[before] * MM_DATA_PIE_LABEL_GAP <= firsts[last]): break
			int merged = counts[before] + counts[last]
			int first = (counts[before] * firsts[before] + counts[last] * (firsts[last] - counts[before] * MM_DATA_PIE_LABEL_GAP)) / merged
			counts[before] = merged
			firsts[before] = first
			starts.pop()
			counts.pop()
			firsts.pop()
	for c in range(starts.length):
		for j in range(counts[c]): tops[starts[c] + j] = firsts[c] + j * MM_DATA_PIE_LABEL_GAP
	if (tops[n - 1] > high):
		int up = tops[n - 1] - high
		for k in range(n): tops[k] = tops[k] - up
	if (tops[0] < low):
		int down = low - tops[0]
		for k in range(n): tops[k] = tops[k] + down
	# Clamping one end can re-merge clusters: restore the minimum pitch.
	for k in range(1, n):
		if (tops[k] < tops[k - 1] + MM_DATA_PIE_LABEL_GAP): tops[k] = tops[k - 1] + MM_DATA_PIE_LABEL_GAP
	__w_list_free(cast(__w_list*, starts))
	__w_list_free(cast(__w_list*, counts))
	__w_list_free(cast(__w_list*, firsts))

char* mm_data_pie_percent(int percent):
	char* number = mm_data_format(percent)
	string_builder* text = string_from(number)
	string_append_char(text, '%')
	free(number)
	char* result = text.data
	free(text)
	return result

# Slice label text as upstream's pie renderer writes it:
# ((value / sum) * 100).toFixed(0) + '%' (percent in thousandths).
char* mm_data_pie_slice_label(int percent):
	string_builder* text = string_from(c"")
	string_append_int(text, (percent + 500) / 1000)
	string_append_char(text, '%')
	char* result = text.data
	free(text)
	return result

# Draw one side's outside labels, precise percentages with a % sign as in the
# legend (upstream drops the labels of slices that round to 0%); returns the
# widest label's right edge.
int mm_data_pie_side(mm_scene* s, list[int] slices, list[float] angles, list[int] tops, list[int] percents, int right):
	int edge = 0
	for k in range(slices.length):
		float middle = angles[k]
		int rx = MM_DATA_PIE_CX + cast(int, fcos(middle) * cast(float, MM_DATA_PIE_R))
		int ry = MM_DATA_PIE_CY + cast(int, fsin(middle) * cast(float, MM_DATA_PIE_R))
		int ex = MM_DATA_PIE_CX + cast(int, fcos(middle) * cast(float, MM_DATA_PIE_ELBOW))
		int ey = MM_DATA_PIE_CY + cast(int, fsin(middle) * cast(float, MM_DATA_PIE_ELBOW))
		int ty = tops[k] + MM_TEXT_LINE / 2
		# Labels hug a circle just outside the pie; above or below it they
		# keep a small offset from the vertical center line.
		int dy = ty - MM_DATA_PIE_CY
		int dx = 16
		if (dy > 0 - MM_DATA_PIE_COLUMN && dy < MM_DATA_PIE_COLUMN): dx = cast(int, fsqrt(cast(float, MM_DATA_PIE_COLUMN * MM_DATA_PIE_COLUMN - dy * dy)))
		if (dx < 16): dx = 16
		int column = MM_DATA_PIE_CX - dx
		if (right): column = MM_DATA_PIE_CX + dx
		mm_line(s, rx, ry, ex, ey, 0)
		mm_line(s, ex, ey, column, ty, 0)
		char* text = mm_data_pie_percent(percents[k])
		int width = mm_text_width(text, 0)
		int x = column + 4
		if (right == 0): x = column - 4 - width
		mm_text(s, x, tops[k], text)
		if (x + width > edge): edge = x + width
		free(text)
	return edge

void mm_data_pie_render(mm_document* d, mm_scene* s):
	float sum = 0.0
	for mm_data_item* item in d.data.items: sum = sum + cast(float, item.a)
	int cx = MM_DATA_PIE_CX
	int cy = MM_DATA_PIE_CY
	float angle = -1.5707963
	# Outside labels per side: slice, middle angle, desired top, percent.
	list[int] right_slices = new list[int]
	list[float] right_angles = new list[float]
	list[int] right_tops = new list[int]
	list[int] right_percents = new list[int]
	list[int] left_slices = new list[int]
	list[float] left_angles = new list[float]
	list[int] left_tops = new list[int]
	list[int] left_percents = new list[int]
	int row = 0
	for mm_data_item* item in d.data.items:
		float sweep = cast(float, item.a) / sum * 6.2831853
		int steps = cast(int, sweep * 180.0 / 3.14159265 / 4.0) + 1
		int start = s.items.length
		mm_primitive* slice = mm_data_polygon(s)
		mm_data_vertex(s, slice, cx, cy)
		for j in range(steps + 1):
			float end = angle + sweep * cast(float, j) / cast(float, steps)
			int x = cx + cast(int, fcos(end) * cast(float, MM_DATA_PIE_R))
			int y = cy + cast(int, fsin(end) * cast(float, MM_DATA_PIE_R))
			mm_data_vertex(s, slice, x, y)
		mm_data_series_paint(s, start, row)
		float middle = angle + sweep / 2.0
		int percent = cast(int, cast(float, item.a) / sum * 100000.0)
		if (sweep >= 0.55):
			int lx = cx + cast(int, fcos(middle) * 125.0)
			int ly = cy + cast(int, fsin(middle) * 125.0)
			char* text = mm_data_pie_slice_label(percent)
			mm_text(s, lx - mm_text_width(text, 0) / 2, ly - 8, text)
			free(text)
			mm_primitive* label = s.items[s.items.length - 1]
			label.style.mask = 4
			label.style.text = 0xffffff
		else:
			int top = cy + cast(int, fsin(middle) * cast(float, MM_DATA_PIE_COLUMN)) - MM_TEXT_LINE / 2
			# Angles run clockwise from the top: right side top-down in order,
			# left side bottom-up, so the left lists are reversed afterwards.
			if (fcos(middle) >= 0.0):
				right_slices.push(row)
				right_angles.push(middle)
				right_tops.push(top)
				right_percents.push(percent)
			else:
				left_slices.push(row)
				left_angles.push(middle)
				left_tops.push(top)
				left_percents.push(percent)
		angle = angle + sweep
		row = row + 1
	# Right-side angles in (-pi/2, pi/2) increase downwards; left-side ones in
	# (pi/2, 3pi/2) increase upwards, so reverse those to top-down order.
	int count = left_slices.length
	for k in range(count / 2):
		int other = count - 1 - k
		int slice_swap = left_slices[k]
		left_slices[k] = left_slices[other]
		left_slices[other] = slice_swap
		float angle_swap = left_angles[k]
		left_angles[k] = left_angles[other]
		left_angles[other] = angle_swap
		int top_swap = left_tops[k]
		left_tops[k] = left_tops[other]
		left_tops[other] = top_swap
		int percent_swap = left_percents[k]
		left_percents[k] = left_percents[other]
		left_percents[other] = percent_swap
	int low = cy - MM_DATA_PIE_COLUMN - 160
	int high = cy + MM_DATA_PIE_COLUMN + 160
	mm_data_pie_spread(right_tops, low, high)
	mm_data_pie_spread(left_tops, low, high)
	int edge = mm_data_pie_side(s, right_slices, right_angles, right_tops, right_percents, 1)
	mm_data_pie_side(s, left_slices, left_angles, left_tops, left_percents, 0)
	# The legend moves right of any outside labels on the right side.
	int legend = 472
	if (edge + 24 > legend): legend = edge + 24
	row = 0
	for mm_data_item* item in d.data.items:
		int start = s.items.length
		mm_draw(s, MM_BOX, legend, 80 + row * 26, legend + 16, 96 + row * 26, 0, c"")
		mm_data_series_paint(s, start, row)
		mm_text(s, legend + 28, 80 + row * 26, item.label)
		int percent = cast(int, cast(float, item.a) / sum * 100000.0)
		char* percentage = mm_data_pie_percent(percent)
		string_builder* label = string_from(percentage)
		free(percentage)
		if (d.data.show_data):
			char* value = mm_data_format(item.a)
			string_append(label, c" (value: ")
			string_append(label, value)
			string_append_char(label, ')')
			free(value)
		mm_text(s, legend + 40 + mm_text_width(item.label, 0), 80 + row * 26, label.data)
		string_free(label)
		row = row + 1
	# The caption stays clear of leaders running to bottom labels.
	int caption = 470
	for int top in right_tops:
		if (top + 40 > caption): caption = top + 40
	for int top in left_tops:
		if (top + 40 > caption): caption = top + 40
	mm_text(s, 170, caption, c"Slice labels: percent")
	__w_list_free(cast(__w_list*, right_slices))
	__w_list_free(cast(__w_list*, right_angles))
	__w_list_free(cast(__w_list*, right_tops))
	__w_list_free(cast(__w_list*, right_percents))
	__w_list_free(cast(__w_list*, left_slices))
	__w_list_free(cast(__w_list*, left_angles))
	__w_list_free(cast(__w_list*, left_tops))
	__w_list_free(cast(__w_list*, left_percents))

void mm_data_quadrant_render(mm_document* d, mm_scene* s):
	mm_data_chart* c = d.data
	mm_draw(s, MM_BOX, 120, 80, 720, 580, 0, c"")
	mm_line(s, 420, 80, 420, 580, 0)
	mm_line(s, 120, 330, 720, 330, 0)
	mm_text(s, 120, 610, c.x_label)
	mm_text(s, 720 - mm_text_width(c.x_end, 0), 610, c.x_end)
	# Y-axis labels right-align against the plot from measured widths.
	mm_text(s, 110 - mm_text_width(c.y_label, 0), 560, c.y_label)
	mm_text(s, 110 - mm_text_width(c.y_end, 0), 80, c.y_end)
	for mm_data_item* item in c.items:
		if (item.kind == 9): continue
		if (item.kind == 8):
			int x = 140
			int y = 100
			if (item.a == 1 || item.a == 4): x = 440
			if (item.a == 3 || item.a == 4): y = 350
			# Quadrant titles wrap inside their 300px quadrant.
			mm_label(s, x, y, item.label, 260, 0)
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
			# A point label that would leave the plot sits left of its point.
			int label_x = x + radius + 4
			int label_width = mm_text_width(item.label, 0)
			if (label_x + label_width > 720 && x - radius - 4 - label_width >= 120): label_x = x - radius - 4 - label_width
			mm_text(s, label_x, y - 18, item.label)

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
	char* orientation = mm_config_value(d, c"xyChart.chartOrientation")
	if (orientation != 0 && strcmp(orientation, c"horizontal") == 0): horizontal = 1
	int left = 140
	int top = 80
	int extent = 400
	# xyChart.width/height size the whole chart (upstream defaults 700 x 500);
	# the category axis runs along the width when vertical, the height when horizontal.
	if (mm_config_has(d, c"xyChart.width") || mm_config_has(d, c"xyChart.height")):
		int across = mm_config_number(d, c"xyChart.width", 700) - 200
		int down = mm_config_number(d, c"xyChart.height", 500) - 180
		if (across < 100): across = 100
		if (down < 100): down = 100
		width = across
		extent = down
		if (horizontal):
			width = down
			extent = across
	# xAxis is the category axis and yAxis the value axis, in either orientation.
	int x_labels = mm_config_flag(d, c"xyChart.xAxis.showLabel", 1)
	int x_title = mm_config_flag(d, c"xyChart.xAxis.showTitle", 1)
	int x_line = mm_config_flag(d, c"xyChart.xAxis.showAxisLine", 1)
	int y_labels = mm_config_flag(d, c"xyChart.yAxis.showLabel", 1)
	int y_title = mm_config_flag(d, c"xyChart.yAxis.showTitle", 1)
	int y_ticks = mm_config_flag(d, c"xyChart.yAxis.showTick", 1)
	int y_line = mm_config_flag(d, c"xyChart.yAxis.showAxisLine", 1)
	int data_labels = mm_config_flag(d, c"xyChart.showDataLabel", 0)
	int legend = mm_config_flag(d, c"xyChart.showLegend", 1)
	int zero = mm_data_scale(0, c.low, c.high, extent)
	if (zero < 0): zero = 0
	if (zero > extent): zero = extent
	if (horizontal):
		if (x_line): mm_line(s, left, top, left, top + width, 0)
		if (y_line): mm_line(s, left, top + width, left + extent, top + width, 0)
	else:
		if (y_line): mm_line(s, left, top, left, top + extent, 0)
		if (x_line): mm_line(s, left, top + extent, left + width, top + extent, 0)
	for tick in range(6):
		int value = c.low + cast(int, cast(float, c.high - c.low) * cast(float, tick) / 5.0)
		if (horizontal):
			if (y_labels):
				char* number = mm_data_format(value)
				mm_text(s, left + tick * extent / 5 - mm_text_width(number, 0) / 2, top + width + 24, number)
				free(number)
			if (y_ticks): mm_line(s, left + tick * extent / 5, top, left + tick * extent / 5, top + width, 1)
		else:
			# Value labels right-align against the axis from measured widths.
			if (y_labels):
				char* number = mm_data_format(value)
				mm_text(s, left - 10 - mm_text_width(number, 0), top + extent - tick * extent / 5 - 8, number)
				free(number)
			if (y_ticks): mm_line(s, left, top + extent - tick * extent / 5, left + width, top + extent - tick * extent / 5, 1)
	# Category labels: right-aligned beside a horizontal chart's axis; under a
	# vertical one centered on their band and wrapped to its width when the
	# widest would run into a neighbour, which moves the axis title and the
	# legend down by the extra lines.
	int category = 0
	int band_width = width
	if (count > 0): band_width = width / count - 8
	if (band_width < 24): band_width = 24
	int wrap = 0
	for mm_data_item* item in c.items:
		if (item.kind == 1 && mm_text_width(item.label, 0) > band_width): wrap = band_width
	int label_extra = 0
	for mm_data_item* item in c.items:
		if (item.kind != 1): continue
		int position = mm_data_x_position(c, category, count, width)
		if (x_labels):
			if (horizontal): mm_text(s, left - 10 - mm_text_width(item.label, 0), top + position - 8, item.label)
			else:
				int height = mm_label(s, left + position, top + extent + 20, item.label, wrap, 1)
				if (height - MM_TEXT_LINE > label_extra): label_extra = height - MM_TEXT_LINE
		category = category + 1
	if (category == 0 && x_labels):
		for i in range(count):
			int position = mm_data_x_position(c, i, count, width)
			int value = (i + 1) * 1000
			if (c.x_numeric):
				value = c.x_low
				if (count > 1): value = c.x_low + cast(int, cast(float, c.x_high - c.x_low) * cast(float, i) / cast(float, count - 1))
			char* number = mm_data_format(value)
			if (horizontal): mm_text(s, left - 10 - mm_text_width(number, 0), top + position - 8, number)
			else: mm_text(s, left + position - mm_text_width(number, 0) / 2, top + extent + 20, number)
			free(number)
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
				if (data_labels):
					# xyChart.showDataLabel: the value just past the bar's end.
					if (horizontal): mm_data_value_text(s, left + high + 6, top + (start + end) / 2 - 8, item.values[i])
					else: mm_data_value_text(s, left + (start + end) / 2 - 8, top + extent - high - 20, item.values[i])
			if (item.kind == 2 && data_labels): mm_data_value_text(s, x + 6, y - 22, item.values[i])
			if (i < item.point_labels.length):
				char* label = item.point_labels[i]
				if (label[0] != 0): mm_text(s, x + 8, y - 20, label)
			last_x = x
			last_y = y
		if (item.kind == 3): bar_index = bar_index + 1
		if (item.label[0] != 0 && legend):
			int legend_y = top + extent + 80 + label_extra
			if (horizontal): legend_y = top + width + 80
			if (item.kind == 3): mm_draw(s, MM_BOX, left, legend_y + series_index * 24, left + 24, legend_y + series_index * 24 + 14, 0, c"")
			else: mm_line(s, left, legend_y + series_index * 24 + 7, left + 24, legend_y + series_index * 24 + 7, series_index % 2)
			mm_text(s, left + 36, legend_y + series_index * 24, item.label)
		mm_data_series_paint(s, series_start, series_index)
		series_index = series_index + 1
	if (horizontal):
		if (y_title): mm_text(s, left, top + width + 52, c.y_label)
		if (x_title): mm_text(s, 10, 44, c.x_label)
	else:
		if (x_title): mm_text(s, left, top + extent + 52 + label_extra, c.x_label)
		if (y_title): mm_text(s, 20, 44, c.y_label)

int mm_data_radar_x(int cx, float angle, int radius):
	return cx + cast(int, fcos(angle) * cast(float, radius))

int mm_data_radar_y(int cy, float angle, int radius):
	return cy + cast(int, fsin(angle) * cast(float, radius))

void mm_data_radar_render(mm_document* d, mm_scene* s):
	mm_data_chart* c = d.data
	list[mm_data_item*] axes = new list[mm_data_item*]
	for mm_data_item* item in c.items:
		if (item.kind == 1): axes.push(item)
	int count = axes.length
	# Native geometry is a 200px radius at (300, 300). radar.width/height and
	# the margins switch to upstream's sizing (600 x 600, margins 50).
	int cx = 300
	int cy = 300
	int radius = 200
	if (mm_config_has(d, c"radar.width") || mm_config_has(d, c"radar.height") || mm_config_has(d, c"radar.marginTop") || mm_config_has(d, c"radar.marginRight") || mm_config_has(d, c"radar.marginBottom") || mm_config_has(d, c"radar.marginLeft")):
		int left = mm_config_number(d, c"radar.marginLeft", 50)
		int top = mm_config_number(d, c"radar.marginTop", 50)
		int across = mm_config_number(d, c"radar.width", 600) - left - mm_config_number(d, c"radar.marginRight", 50)
		int down = mm_config_number(d, c"radar.height", 600) - top - mm_config_number(d, c"radar.marginBottom", 50)
		if (across < 40): across = 40
		if (down < 40): down = 40
		radius = across / 2
		if (down / 2 < radius): radius = down / 2
		cx = left + across / 2
		cy = top + down / 2
	int axis_radius = radius * mm_config_milli(d, c"radar.axisScaleFactor", 1000) / 1000
	int label_radius = radius * mm_config_milli(d, c"radar.axisLabelFactor", 1125) / 1000
	# Upstream draws circle-graticule curves as a closed Catmull-Rom spline
	# (radar.curveTension, default 0.17); polygon graticules keep straight edges.
	int tension = mm_config_milli(d, c"radar.curveTension", 170)
	if (c.polygon): tension = 0
	for tick in range(1, c.ticks + 1):
		int r = radius * tick / c.ticks
		if (c.polygon == 0): mm_ellipse(s, cx, cy, r, r)
		else:
			for i in range(count):
				float a = cast(float, i) * 6.2831853 / cast(float, count) - 1.5707963
				float b = cast(float, i + 1) * 6.2831853 / cast(float, count) - 1.5707963
				mm_line(s, mm_data_radar_x(cx, a, r), mm_data_radar_y(cy, a, r), mm_data_radar_x(cx, b, r), mm_data_radar_y(cy, b, r), 1)
	for i in range(count):
		float angle = cast(float, i) * 6.2831853 / cast(float, count) - 1.5707963
		mm_data_item* axis = axes[i]
		mm_line(s, cx, cy, mm_data_radar_x(cx, angle, axis_radius), mm_data_radar_y(cy, angle, axis_radius), 0)
		mm_text(s, mm_data_radar_x(cx, angle, label_radius) - mm_text_width(axis.label, 0) / 2, mm_data_radar_y(cy, angle, label_radius) - 8, axis.label)
	int series = 0
	list[int] px = new list[int]
	list[int] py = new list[int]
	for mm_data_item* item in c.items:
		if (item.kind != 4): continue
		int series_start = s.items.length
		px.clear()
		py.clear()
		for i in range(count):
			float a = cast(float, i) * 6.2831853 / cast(float, count) - 1.5707963
			int r = mm_data_scale(item.values[i], c.low, c.high, radius)
			px.push(mm_data_radar_x(cx, a, r))
			py.push(mm_data_radar_y(cy, a, r))
		# A styled fill draws the curve as an area (upstream curveOpacity 0.5).
		mm_primitive* area = 0
		if (item.style.mask & MM_STYLE_FILL):
			area = mm_data_polygon(s)
			for i in range(count): mm_data_vertex(s, area, px[i], py[i])
		for i in range(count):
			int j = (i + 1) % count
			if (tension > 0):
				# radar.curveTension: a closed Catmull-Rom spline as sampled cubic Beziers.
				int h = (i + count - 1) % count
				int k = (i + 2) % count
				int c1x = px[i] + (px[j] - px[h]) * tension / 1000
				int c1y = py[i] + (py[j] - py[h]) * tension / 1000
				int c2x = px[j] - (px[k] - px[i]) * tension / 1000
				int c2y = py[j] - (py[k] - py[i]) * tension / 1000
				mm_style_bezier(s, px[i], py[i], c1x, c1y, c2x, c2y, px[j], py[j], series % 2)
			else: mm_line(s, px[i], py[i], px[j], py[j], series % 2)
			mm_draw(s, MM_CIRCLE, px[i] - 3, py[i] - 3, px[i] + 3, py[i] + 3, series % 2, c"")
		if (c.legend):
			mm_line(s, cx + 280, 100 + series * 28, cx + 320, 100 + series * 28, series % 2)
			mm_text(s, cx + 330, 92 + series * 28, item.label)
		mm_data_series_paint(s, series_start, series)
		mm_data_style_apply(s, series_start, &item.style)
		if (area != 0 && (item.style.mask & MM_STYLE_FILL_OPACITY) == 0):
			area.style.mask = area.style.mask | MM_STYLE_FILL_OPACITY
			area.style.fill_opacity = 50
		series = series + 1
	__w_list_free(cast(__w_list*, px))
	__w_list_free(cast(__w_list*, py))
	mm_data_value_text(s, cx + 10, cy, c.low)
	mm_data_value_text(s, cx + 10, cy - radius, c.high)
	__w_list_free(cast(__w_list*, axes))

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

# Source-order index of the top-level section holding item index.
int mm_data_tree_branch(mm_data_chart* c, int index):
	mm_data_item* item = c.items[index]
	while (item.parent >= 0):
		index = item.parent
		item = c.items[index]
	int branch = 0
	for i in range(index):
		mm_data_item* other = c.items[i]
		if (other.parent < 0): branch = branch + 1
	return branch

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
			# Per-depth palette: each top-level section takes a series color,
			# lightened as cells nest (cScale under a theme).
			mm_primitive* box = s.items[style_start]
			box.role = MM_ROLE_TINT
			box.series = mm_data_tree_branch(c, index)
			box.tint = 20 + depth * 10
			if (box.tint > 45): box.tint = 45
			box.style.mask = box.style.mask | MM_STYLE_FILL | MM_STYLE_STROKE
			box.style.stroke = mm_data_series_color(box.series)
			box.style.fill = mm_theme_adjust(box.style.stroke, 0, 0, box.tint + 15)
			# Labels in tiny cells go to a legend rather than crossing boundaries.
			if (ww > mm_text_width(item.label, 0) + 12 && hh > 26): mm_text(s, xx + 6, yy + 6, item.label)
			# classDef and style rules resolved at validation outrank the theme.
			mm_data_style_apply(s, style_start, &item.style)
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
		if (item.kind != 5): mm_data_value_text(s, 1000 + item.depth * 3 + mm_text_width(item.label, 0), 80 + row * 24, item.a)
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
			int style_start = s.items.length
			mm_draw(s, MM_BOX, x, y, right, y + 60, 0, c"")
			mm_data_style_apply(s, style_start, &item.style)
			mm_data_value_text(s, x + 2, y - 20, left_bit * 1000)
			if (last != first): mm_data_value_text(s, right - 24, y - 20, right_bit * 1000)
			if (mm_text_width(item.label, 0) < right - x - 4):
				int label_start = s.items.length
				mm_text(s, x + (right - x - mm_text_width(item.label, 0)) / 2, y + 22, item.label)
				mm_data_style_apply(s, label_start, &item.style)
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
		int start = s.items.length
		mm_text(s, x - mm_text_width(item.label, 0) / 2, y, item.label)
		mm_data_style_apply(s, start, &item.style)
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
void mm_data_venn_region(mm_scene* s, mm_data_item* item, list[int] xs, list[int] ys, list[int] radii, int x, int y);

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
		# Sets are translucent filled discs (venn1..venn8 under a theme), as in
		# the fixed arrangements; `style` statements apply on top.
		int start = s.items.length
		mm_primitive* disc = mm_data_disc(s, cast(int, xs[i]), cast(int, ys[i]), cast(int, rs[i]))
		disc.role = MM_ROLE_VENN
		disc.series = i
		disc.style.mask = MM_STYLE_FILL | MM_STYLE_STROKE | MM_STYLE_FILL_OPACITY
		disc.style.stroke = mm_data_series_color(i)
		disc.style.fill = disc.style.stroke
		disc.style.fill_opacity = 10
		members.clear()
		members.push(i)
		point.clear()
		mm_venn_region_point(xs, ys, rs, n, members, point)
		int x = cast(int, point[0])
		int y = cast(int, point[1])
		mm_text(s, x - mm_text_width(item.label, 0) / 2, y - 8, item.label)
		mm_data_style_apply(s, start, &item.style)
		mm_data_venn_texts(d, s, ids[i], x, y + 14)
	# Pixel geometry indexed by item, as mm_data_venn_region expects.
	list[int] item_x = new list[int]
	list[int] item_y = new list[int]
	list[int] item_r = new list[int]
	for item_index in range(d.data.items.length):
		int set_index = ids.index(item_index)
		if (set_index < 0):
			item_x.push(0)
			item_y.push(0)
			item_r.push(0)
		else:
			item_x.push(cast(int, xs[set_index]))
			item_y.push(cast(int, ys[set_index]))
			item_r.push(cast(int, rs[set_index]))
	for item_index in range(d.data.items.length):
		mm_data_item* item = d.data.items[item_index]
		if (item.kind != 7): continue
		members.clear()
		for int value in item.values: members.push(ids.index(value))
		point.clear()
		mm_venn_region_point(xs, ys, rs, n, members, point)
		int x = cast(int, point[0])
		int y = cast(int, point[1])
		int start = s.items.length
		if (item.style.mask & MM_STYLE_FILL): mm_data_venn_region(s, item, item_x, item_y, item_r, x, y)
		mm_text(s, x - mm_text_width(item.label, 0) / 2, y - 8, item.label)
		mm_data_style_apply(s, start, &item.style)
		mm_data_venn_texts(d, s, item_index, x, y + 14)
	__w_list_free(cast(__w_list*, item_x))
	__w_list_free(cast(__w_list*, item_y))
	__w_list_free(cast(__w_list*, item_r))
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
# Exit distance along unit ray (ux,uy) from (px,py) inside circle (cx,cy,r).
float mm_data_venn_exit(float px, float py, float ux, float uy, float cx, float cy, float r):
	float dx = px - cx
	float dy = py - cy
	float b = ux * dx + uy * dy
	float q = b * b - (dx * dx + dy * dy - r * r)
	if (q < 0.0): return 0.0
	return 0.0 - b + fsqrt(q)

# The region shared by every member set, sampled from a point inside it.
void mm_data_venn_region(mm_scene* s, mm_data_item* item, list[int] xs, list[int] ys, list[int] radii, int x, int y):
	mm_primitive* region = mm_data_polygon(s)
	for k in range(64):
		float angle = cast(float, k) * 6.2831853 / 64.0
		float ux = fcos(angle)
		float uy = fsin(angle)
		float best = 100000.0
		for int i in item.values:
			float exit = mm_data_venn_exit(cast(float, x), cast(float, y), ux, uy, cast(float, xs[i]), cast(float, ys[i]), cast(float, radii[i]))
			if (exit < best): best = exit
		mm_data_vertex(s, region, x + cast(int, ux * best), y + cast(int, uy * best))
	region.role = MM_ROLE_VENN
	region.series = 8

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
		# Sets are translucent filled discs (venn1..venn8 under a theme).
		int start = s.items.length
		mm_primitive* disc = mm_data_disc(s, x, y, radius)
		disc.role = MM_ROLE_VENN
		disc.series = i
		disc.style.mask = MM_STYLE_FILL | MM_STYLE_STROKE | MM_STYLE_FILL_OPACITY
		disc.style.stroke = mm_data_series_color(i)
		disc.style.fill = disc.style.stroke
		disc.style.fill_opacity = 10
		int ty = y - radius + 55
		if (count == 3 && pairs == 3 && i == 2): ty = y + 110
		mm_text(s, x - mm_text_width(item.label, 0) / 2, ty, item.label)
		mm_data_style_apply(s, start, &item.style)
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
		int start = s.items.length
		if (item.style.mask & MM_STYLE_FILL): mm_data_venn_region(s, item, xs, ys, radii, x, y)
		mm_text(s, x - mm_text_width(item.label, 0) / 2, y - 8, item.label)
		mm_data_style_apply(s, start, &item.style)
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
	int rank
	int x
	int y
	int height
	int order

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

# sankey.nodeColors[id], else the categorical series color of the node.
int mm_data_sankey_color(mm_document* d, int index):
	mm_node* node = d.nodes[index]
	string_builder* key = string_from(c"sankey.nodeColors.")
	string_append(key, node.id)
	char* value = mm_config_value(d, key.data)
	string_free(key)
	if (value != 0): return mm_style_color(value)
	return mm_data_series_color(index)

int mm_data_blend(int a, int b):
	int red = (((a >> 16) & 255) + ((b >> 16) & 255)) / 2
	int green = (((a >> 8) & 255) + ((b >> 8) & 255)) / 2
	int blue = ((a & 255) + (b & 255)) / 2
	return (red << 16) | (green << 8) | blue

void mm_data_fill(mm_primitive* p, int color):
	p.style.mask = p.style.mask | MM_STYLE_FILL | MM_STYLE_STROKE
	p.style.fill = color
	p.style.stroke = color

# Global node ordering (issue #817). Each column starts from the weighted
# predecessor order above, then alternating barycenter sweeps (forward by
# weighted source centers, backward by weighted target centers, as
# d3-sankey's relaxation) reorder the columns; the order with the fewest
# value-weighted ribbon crossings wins, the initial one on ties, so the
# result is deterministic and never worse than the single forward pass.
const int MM_DATA_SANKEY_SWEEPS = 8
const int MM_DATA_SANKEY_RELAX_LIMIT = 4000

# Stack one column top-down in node.order.
void mm_data_sankey_place(mm_document* d, list[mm_data_flow_node*] nodes, int rank, float scale, int padding):
	list[int] ordered = new list[int]
	for i in range(nodes.length):
		if (nodes[i].rank == rank): ordered.push(-1)
	for i in range(nodes.length):
		mm_data_flow_node* node = nodes[i]
		if (node.rank == rank && node.order >= 0 && node.order < ordered.length): ordered[node.order] = i
	int y = 100
	for int i in ordered:
		if (i < 0): continue
		mm_data_flow_node* node = nodes[i]
		mm_node* named = d.nodes[i]
		y = y + (mm_data_text_lines(named.label) - 1) * 18
		node.y = y
		node.height = cast(int, node.total * scale)
		if (node.height < 1): node.height = 1
		y = y + node.height + padding
	__w_list_free(cast(__w_list*, ordered))

float mm_data_sankey_mid(mm_data_flow_node* node):
	return cast(float, node.y) + cast(float, node.height) / 2.0

# Weighted center of a node's neighbours: sources (forward) or targets.
float mm_data_sankey_key(mm_document* d, list[mm_data_flow_node*] nodes, int index, int forward):
	float center = 0.0
	float total = 0.0
	for mm_data_item* flow in d.data.items:
		int other = -1
		if (forward && flow.b == index): other = flow.parent
		if (forward == 0 && flow.parent == index): other = flow.b
		if (other < 0): continue
		center = center + mm_data_sankey_mid(nodes[other]) * cast(float, flow.a)
		total = total + cast(float, flow.a)
	if (total == 0.0): return mm_data_sankey_mid(nodes[index])
	return center / total

# Stable reorder of one column by neighbour centers.
void mm_data_sankey_sweep_rank(mm_document* d, list[mm_data_flow_node*] nodes, int rank, int forward, float scale, int padding):
	list[int] ordered = new list[int]
	list[float] keys = new list[float]
	for i in range(nodes.length):
		if (nodes[i].rank == rank):
			ordered.push(-1)
			keys.push(0.0)
	for i in range(nodes.length):
		mm_data_flow_node* node = nodes[i]
		if (node.rank == rank && node.order >= 0 && node.order < ordered.length): ordered[node.order] = i
	for k in range(ordered.length):
		if (ordered[k] >= 0): keys[k] = mm_data_sankey_key(d, nodes, ordered[k], forward)
	for i in range(1, ordered.length):
		int id = ordered[i]
		float key = keys[i]
		int j = i
		while (j > 0 && keys[j - 1] > key):
			ordered[j] = ordered[j - 1]
			keys[j] = keys[j - 1]
			j = j - 1
		ordered[j] = id
		keys[j] = key
	for k in range(ordered.length):
		if (ordered[k] >= 0): nodes[ordered[k]].order = k
	mm_data_sankey_place(d, nodes, rank, scale, padding)
	__w_list_free(cast(__w_list*, ordered))
	__w_list_free(cast(__w_list*, keys))

# Value-weighted crossings between ribbons spanning the same pair of
# columns with distinct endpoints (ribbons sharing an endpoint never cross:
# their slots follow the opposite end's order, see mm_data_sankey_slots).
float mm_data_sankey_crossings(mm_document* d, list[mm_data_flow_node*] nodes):
	float total = 0.0
	int count = d.data.items.length
	for i in range(count):
		mm_data_item* a = d.data.items[i]
		mm_data_flow_node* au = nodes[a.parent]
		mm_data_flow_node* av = nodes[a.b]
		for j in range(i + 1, count):
			mm_data_item* b = d.data.items[j]
			if (a.parent == b.parent || a.b == b.b): continue
			mm_data_flow_node* bu = nodes[b.parent]
			mm_data_flow_node* bv = nodes[b.b]
			if (au.rank != bu.rank || av.rank != bv.rank): continue
			if ((au.order < bu.order) != (av.order < bv.order)): total = total + cast(float, a.a) * cast(float, b.a)
	return total

void mm_data_sankey_relax(mm_document* d, list[mm_data_flow_node*] nodes, int ranks, float scale, int padding):
	if (ranks < 2 || d.data.items.length > MM_DATA_SANKEY_RELAX_LIMIT): return
	list[int] best = new list[int]
	for mm_data_flow_node* node in nodes: best.push(node.order)
	float best_crossings = mm_data_sankey_crossings(d, nodes)
	for sweep in range(MM_DATA_SANKEY_SWEEPS):
		if (best_crossings == 0.0): break
		if (sweep % 2 == 0):
			for rank in range(1, ranks): mm_data_sankey_sweep_rank(d, nodes, rank, 1, scale, padding)
		else:
			int rank = ranks - 2
			while (rank >= 0):
				mm_data_sankey_sweep_rank(d, nodes, rank, 0, scale, padding)
				rank = rank - 1
		float crossings = mm_data_sankey_crossings(d, nodes)
		if (crossings < best_crossings):
			best_crossings = crossings
			for i in range(nodes.length): best[i] = nodes[i].order
	for i in range(nodes.length): nodes[i].order = best[i]
	for rank in range(ranks): mm_data_sankey_place(d, nodes, rank, scale, padding)
	__w_list_free(cast(__w_list*, best))

# Ribbon offsets inside each node: outgoing ribbons stack in the vertical
# order of their targets and incoming ones in that of their sources, as
# d3-sankey's link breadths, so ribbons sharing a node never cross.
void mm_data_sankey_slots(mm_document* d, list[mm_data_flow_node*] nodes, list[float] out_offset, list[float] in_offset):
	int count = d.data.items.length
	for i in range(count):
		out_offset.push(0.0)
		in_offset.push(0.0)
	for i in range(count):
		mm_data_item* item = d.data.items[i]
		float target = mm_data_sankey_mid(nodes[item.b])
		float source = mm_data_sankey_mid(nodes[item.parent])
		float out_used = 0.0
		float in_used = 0.0
		for j in range(count):
			if (j == i): continue
			# Past the relaxation bound slots keep source order (linear work).
			if (count > MM_DATA_SANKEY_RELAX_LIMIT && j > i): break
			mm_data_item* other = d.data.items[j]
			if (other.parent == item.parent):
				float y = mm_data_sankey_mid(nodes[other.b])
				if (count > MM_DATA_SANKEY_RELAX_LIMIT || y < target || (y == target && j < i)): out_used = out_used + cast(float, other.a)
			if (other.b == item.b):
				float y = mm_data_sankey_mid(nodes[other.parent])
				if (count > MM_DATA_SANKEY_RELAX_LIMIT || y < source || (y == source && j < i)): in_used = in_used + cast(float, other.a)
		out_offset[i] = out_used
		in_offset[i] = in_used

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
	# sankey.nodeAlignment (upstream default justify). Unconfigured, nodes keep
	# their longest-path rank from the sources, which is upstream's left.
	char* alignment = mm_config_value(d, c"sankey.nodeAlignment")
	if (alignment != 0 && strcmp(alignment, c"left") != 0):
		list[int] outgoing = new list[int]
		list[int] incoming = new list[int]
		for i in range(nodes.length):
			outgoing.push(0)
			incoming.push(0)
		for mm_data_item* item in d.data.items:
			outgoing[item.parent] = outgoing[item.parent] + 1
			incoming[item.b] = incoming[item.b] + 1
		if (strcmp(alignment, c"right") == 0):
			# Rank by the longest path to a sink, counted from the right.
			list[int] height = new list[int]
			for i in range(nodes.length): height.push(-1)
			for pass in range(nodes.length):
				for i in range(nodes.length):
					if (height[i] >= 0): continue
					int best = 0
					int ready = 1
					for mm_data_item* item in d.data.items:
						if (item.parent != i): continue
						if (height[item.b] < 0): ready = 0
						else if (height[item.b] + 1 > best): best = height[item.b] + 1
					if (ready): height[i] = best
			for i in range(nodes.length):
				mm_data_flow_node* node = nodes[i]
				if (height[i] >= 0 && node.rank >= 0): node.rank = ranks - 1 - height[i]
			__w_list_free(cast(__w_list*, height))
		else if (strcmp(alignment, c"justify") == 0):
			for i in range(nodes.length):
				mm_data_flow_node* node = nodes[i]
				if (outgoing[i] == 0 && node.rank >= 0): node.rank = ranks - 1
		else:
			# center: a source moves right to just before its nearest target.
			for i in range(nodes.length):
				mm_data_flow_node* node = nodes[i]
				if (incoming[i] != 0 || outgoing[i] == 0 || node.rank < 0): continue
				int nearest = ranks
				for mm_data_item* item in d.data.items:
					mm_data_flow_node* to = nodes[item.b]
					if (item.parent == i && to.rank >= 0 && to.rank < nearest): nearest = to.rank
				if (nearest < ranks && nearest - 1 > node.rank): node.rank = nearest - 1
		__w_list_free(cast(__w_list*, outgoing))
		__w_list_free(cast(__w_list*, incoming))
	int node_width = mm_config_number(d, c"sankey.nodeWidth", 20)
	int padding = mm_config_number(d, c"sankey.nodePadding", 50)
	int pitch = 280
	if (mm_config_has(d, c"sankey.width") && ranks > 1):
		pitch = (mm_config_number(d, c"sankey.width", 600) - 160 - node_width) / (ranks - 1)
		if (pitch < node_width + 40): pitch = node_width + 40
	int column = 500
	if (mm_config_has(d, c"sankey.height")):
		column = mm_config_number(d, c"sankey.height", 400) - 200
		if (column < 50): column = 50
	int show_values = mm_config_flag(d, c"sankey.showValues", 1)
	char* prefix = mm_config_value(d, c"sankey.prefix")
	char* suffix = mm_config_value(d, c"sankey.suffix")
	char* link_color = mm_config_value(d, c"sankey.linkColor")
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
	float scale = cast(float, column) / maximum
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
		for k in range(ordered.length): nodes[ordered[k]].order = k
		mm_data_sankey_place(d, nodes, rank, scale, padding)
		__w_list_free(cast(__w_list*, ordered))
	mm_data_sankey_relax(d, nodes, ranks, scale, padding)
	for mm_data_flow_node* node in nodes: node.x = 80 + node.rank * pitch
	list[float] out_offset = new list[float]
	list[float] in_offset = new list[float]
	mm_data_sankey_slots(d, nodes, out_offset, in_offset)
	int item_index = 0
	for mm_data_item* item in d.data.items:
		mm_data_flow_node* from = nodes[item.parent]
		mm_data_flow_node* to = nodes[item.b]
		float out_used = out_offset[item_index]
		float in_used = in_offset[item_index]
		item_index = item_index + 1
		int ay = from.y + cast(int, out_used * scale)
		int by = to.y + cast(int, in_used * scale)
		int ah = from.y + cast(int, (out_used + cast(float, item.a)) * scale)
		int bh = to.y + cast(int, (in_used + cast(float, item.a)) * scale)
		mm_primitive* ribbon = mm_data_polygon(s)
		for j in range(17):
			float t = cast(float, j) / 16.0
			float smooth = t * t * (3.0 - 2.0 * t)
			int xx = from.x + node_width + cast(int, cast(float, to.x - from.x - node_width) * t)
			mm_data_vertex(s, ribbon, xx, ay + cast(int, cast(float, by - ay) * smooth))
		for j in range(17):
			float t = cast(float, 16 - j) / 16.0
			float smooth = t * t * (3.0 - 2.0 * t)
			int xx = from.x + node_width + cast(int, cast(float, to.x - from.x - node_width) * t)
			mm_data_vertex(s, ribbon, xx, ah + cast(int, cast(float, bh - ah) * smooth))
		# sankey.linkColor: source, target, gradient (natively their blend) or a color.
		if (link_color != 0):
			int color = mm_style_color(link_color)
			if (strcmp(link_color, c"source") == 0): color = mm_data_sankey_color(d, item.parent)
			else if (strcmp(link_color, c"target") == 0): color = mm_data_sankey_color(d, item.b)
			else if (strcmp(link_color, c"gradient") == 0): color = mm_data_blend(mm_data_sankey_color(d, item.parent), mm_data_sankey_color(d, item.b))
			mm_data_fill(ribbon, color)
		if (show_values):
			char* number = mm_data_format(item.a)
			string_builder* text = string_new()
			if (prefix != 0): string_append(text, prefix)
			string_append(text, number)
			if (suffix != 0): string_append(text, suffix)
			mm_text(s, (from.x + node_width + to.x) / 2 - mm_text_width(text.data, 0) / 2, (ay + by + ah + bh) / 4 - MM_TEXT_LINE / 2, text.data)
			string_free(text)
			free(number)
	for i in range(nodes.length):
		mm_data_flow_node* node = nodes[i]
		mm_node* named = d.nodes[i]
		mm_draw(s, MM_BOX, node.x, node.y, node.x + node_width, node.y + node.height, 2, c"")
		string_builder* key = string_from(c"sankey.nodeColors.")
		string_append(key, named.id)
		int colored = mm_config_has(d, key.data) || (link_color != 0 && mm_style_color(link_color) < 0)
		string_free(key)
		if (colored): mm_data_fill(s.items[s.items.length - 1], mm_data_sankey_color(d, i))
		mm_data_multiline_text(s, node.x, node.y - 24 - (mm_data_text_lines(named.label) - 1) * 18, named.label)
	for mm_data_flow_node* node in nodes: free(node)
	__w_list_free(cast(__w_list*, nodes))
	__w_list_free(cast(__w_list*, out_offset))
	__w_list_free(cast(__w_list*, in_offset))

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
	# xyChart.showTitle: false hides the chart title.
	if (d.kind == MM_XY && mm_config_flag(d, c"xyChart.showTitle", 1) == 0):
		title = c""
		s.has_title = 1
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
