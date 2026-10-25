# Native icon pictograms for icon-font and icon-pack references (issue #820).
#
# Mermaid draws `::icon(fa fa-book)` (mindmap) and `icon(pack:name)`
# (treeView) with a web icon font or a registered iconify pack. Nothing is
# downloaded here: the reference's last name segment is matched against a
# fixed keyword table (docs/projects/mermaid_graph_families.md, "Icons") and
# drawn as a small vector pictogram from scene primitives. Unmatched names
# draw a round badge holding the name's first letter.
import libs.extras.mermaid.scene

# Pictogram keys, in table order. MM_ICON_COUNT is the unknown-name badge.
const int MM_ICON_COUNT = 24

# Icon name without its family prefix: the last space-separated word, after
# any `pack:` prefix, without a leading `fa-`/`mdi-`/`bi-`/`ti-` style tag.
char* mm_icon_name(char* icon):
	int start = 0
	int length = strlen(icon)
	for i in range(length):
		if (icon[i] == ' ' || icon[i] == ':'): start = i + 1
	int dash = -1
	for i in range(start, length):
		if (dash < 0 && icon[i] == '-'): dash = i
	char* name = icon + start
	if (dash > start && dash - start <= 3 && dash + 1 < length): name = icon + dash + 1
	return strclone(name)

# Index of the pictogram drawn for an icon reference, MM_ICON_COUNT when none
# matches, or -1 for `none` / an empty reference (no icon at all).
int mm_icon_kind(char* icon):
	if (icon[0] == 0 || strcmp(icon, c"none") == 0): return -1
	char* name = mm_icon_name(icon)
	for i in range(strlen(name)): name[i] = tolower(name[i])
	# Keyword table: the first entry contained in the name wins.
	list[char*] words = list[char*]{c"folder", c"directory", c"book", c"file", c"document", c"user", c"person", c"people", c"account", c"cog", c"gear", c"setting", c"cloud", c"database", c"server", c"star", c"heart", c"home", c"house", c"check", c"close", c"times", c"xmark", c"info", c"warn", c"exclamation", c"alert", c"search", c"magnif", c"code", c"terminal", c"bulb", c"idea", c"link", c"chain", c"envelope", c"mail", c"calendar", c"lock", c"key", c"globe", c"earth", c"web", c"brain", c"flag"}
	list[int] kinds = list[int]{0, 0, 1, 2, 2, 3, 3, 3, 3, 4, 4, 4, 5, 6, 6, 7, 8, 9, 9, 10, 11, 11, 11, 12, 13, 13, 13, 14, 14, 15, 15, 16, 16, 17, 17, 18, 18, 19, 20, 20, 21, 21, 21, 22, 23}
	int result = MM_ICON_COUNT
	for i in range(words.length):
		if (result == MM_ICON_COUNT && index_of(name, words[i]) >= 0): result = kinds[i]
	__w_list_free(cast(__w_list*, words))
	__w_list_free(cast(__w_list*, kinds))
	free(name)
	return result

void mm_icon_polygon(mm_scene* s, list[int] points):
	int low_x = points[0]
	int low_y = points[1]
	int high_x = low_x
	int high_y = low_y
	for k in range(points.length / 2):
		if (points[k * 2] < low_x): low_x = points[k * 2]
		if (points[k * 2] > high_x): high_x = points[k * 2]
		if (points[k * 2 + 1] < low_y): low_y = points[k * 2 + 1]
		if (points[k * 2 + 1] > high_y): high_y = points[k * 2 + 1]
	mm_draw(s, MM_POLYGON, low_x, low_y, high_x, high_y, 0, c"")
	mm_primitive* p = s.items[s.items.length - 1]
	p.points = points

void mm_icon_paint(mm_scene* s, int start, int color):
	for i in range(start, s.items.length):
		mm_primitive* p = s.items[i]
		p.style.mask = p.style.mask | 2 | 4
		p.style.stroke = color
		p.style.text = color

void mm_icon_circle(mm_scene* s, int x, int y, int r):
	mm_draw(s, MM_CIRCLE, x - r, y - r, x + r, y + r, 0, c"")

# Draws the pictogram for `icon` centred on (x, y) in a 20-pixel square, in
# `color`. Returns 0 when the reference means no icon.
int mm_icon_draw(mm_scene* s, char* icon, int x, int y, int color):
	int kind = mm_icon_kind(icon)
	if (kind < 0): return 0
	int start = s.items.length
	if (kind == 0):
		mm_icon_polygon(s, list[int]{x - 9, y - 6, x - 3, y - 6, x - 1, y - 4, x + 9, y - 4, x + 9, y + 7, x - 9, y + 7})
	else if (kind == 1):
		mm_icon_polygon(s, list[int]{x - 9, y - 6, x, y - 4, x + 9, y - 6, x + 9, y + 7, x, y + 9, x - 9, y + 7})
		mm_line(s, x, y - 4, x, y + 9, 0)
	else if (kind == 2):
		mm_icon_polygon(s, list[int]{x - 7, y - 9, x + 3, y - 9, x + 7, y - 5, x + 7, y + 9, x - 7, y + 9})
		mm_line(s, x + 3, y - 9, x + 3, y - 5, 0)
		mm_line(s, x + 3, y - 5, x + 7, y - 5, 0)
	else if (kind == 3):
		mm_icon_circle(s, x, y - 4, 4)
		mm_icon_polygon(s, list[int]{x - 8, y + 9, x - 6, y + 3, x + 6, y + 3, x + 8, y + 9})
	else if (kind == 4):
		mm_icon_circle(s, x, y, 6)
		mm_icon_circle(s, x, y, 2)
		list[int] spokes = list[int]{0, -9, 6, -6, 9, 0, 6, 6, 0, 9, -6, 6, -9, 0, -6, -6}
		for k in range(8): mm_line(s, x + spokes[k * 2] * 2 / 3, y + spokes[k * 2 + 1] * 2 / 3, x + spokes[k * 2], y + spokes[k * 2 + 1], 0)
		__w_list_free(cast(__w_list*, spokes))
	else if (kind == 5):
		mm_icon_circle(s, x - 5, y + 2, 4)
		mm_icon_circle(s, x + 1, y - 2, 6)
		mm_icon_circle(s, x + 6, y + 3, 4)
	else if (kind == 6):
		mm_ellipse(s, x, y - 6, 8, 3)
		mm_ellipse(s, x, y + 6, 8, 3)
		mm_line(s, x - 8, y - 6, x - 8, y + 6, 0)
		mm_line(s, x + 8, y - 6, x + 8, y + 6, 0)
	else if (kind == 7):
		mm_icon_polygon(s, list[int]{x, y - 9, x + 2, y - 3, x + 9, y - 3, x + 3, y + 1, x + 6, y + 8, x, y + 4, x - 6, y + 8, x - 3, y + 1, x - 9, y - 3, x - 2, y - 3})
	else if (kind == 8):
		mm_icon_polygon(s, list[int]{x, y + 8, x - 8, y, x - 8, y - 4, x - 5, y - 7, x - 2, y - 7, x, y - 4, x + 2, y - 7, x + 5, y - 7, x + 8, y - 4, x + 8, y})
	else if (kind == 9):
		mm_icon_polygon(s, list[int]{x - 8, y, x, y - 8, x + 8, y, x + 6, y, x + 6, y + 8, x - 6, y + 8, x - 6, y})
	else if (kind == 10):
		mm_line(s, x - 7, y, x - 2, y + 6, 0)
		mm_line(s, x - 2, y + 6, x + 8, y - 6, 0)
	else if (kind == 11):
		mm_line(s, x - 6, y - 6, x + 6, y + 6, 0)
		mm_line(s, x - 6, y + 6, x + 6, y - 6, 0)
	else if (kind == 12):
		mm_icon_circle(s, x, y, 9)
		mm_line(s, x, y - 1, x, y + 5, 0)
		mm_icon_circle(s, x, y - 5, 1)
	else if (kind == 13):
		mm_icon_polygon(s, list[int]{x, y - 9, x + 9, y + 8, x - 9, y + 8})
		mm_line(s, x, y - 3, x, y + 3, 0)
		mm_icon_circle(s, x, y + 5, 1)
	else if (kind == 14):
		mm_icon_circle(s, x - 2, y - 2, 6)
		mm_line(s, x + 2, y + 2, x + 8, y + 8, 0)
	else if (kind == 15):
		mm_line(s, x - 3, y - 6, x - 9, y, 0)
		mm_line(s, x - 9, y, x - 3, y + 6, 0)
		mm_line(s, x + 3, y - 6, x + 9, y, 0)
		mm_line(s, x + 9, y, x + 3, y + 6, 0)
		mm_line(s, x + 2, y - 8, x - 2, y + 8, 0)
	else if (kind == 16):
		mm_icon_circle(s, x, y - 3, 6)
		mm_draw(s, MM_BOX, x - 3, y + 4, x + 3, y + 9, 0, c"")
	else if (kind == 17):
		mm_ellipse(s, x - 4, y, 6, 4)
		mm_ellipse(s, x + 4, y, 6, 4)
	else if (kind == 18):
		mm_draw(s, MM_BOX, x - 9, y - 6, x + 9, y + 7, 0, c"")
		mm_line(s, x - 9, y - 6, x, y + 1, 0)
		mm_line(s, x, y + 1, x + 9, y - 6, 0)
	else if (kind == 19):
		mm_draw(s, MM_BOX, x - 8, y - 6, x + 8, y + 8, 0, c"")
		mm_line(s, x - 8, y - 2, x + 8, y - 2, 0)
		mm_line(s, x - 4, y - 9, x - 4, y - 5, 0)
		mm_line(s, x + 4, y - 9, x + 4, y - 5, 0)
	else if (kind == 20):
		mm_draw(s, MM_BOX, x - 7, y - 1, x + 7, y + 9, 0, c"")
		mm_ellipse(s, x, y - 3, 4, 5)
	else if (kind == 21):
		mm_icon_circle(s, x, y, 9)
		mm_ellipse(s, x, y, 4, 9)
		mm_line(s, x - 9, y, x + 9, y, 0)
	else if (kind == 22):
		mm_ellipse(s, x - 3, y, 5, 8)
		mm_ellipse(s, x + 3, y, 5, 8)
	else if (kind == 23):
		mm_line(s, x - 7, y - 9, x - 7, y + 9, 0)
		mm_icon_polygon(s, list[int]{x - 7, y - 9, x + 8, y - 5, x - 7, y - 1})
	else:
		# Unknown icon: a round badge with the name's first letter.
		char* name = mm_icon_name(icon)
		char[2] letter
		letter[0] = cast(char, toupper(name[0]))
		letter[1] = 0
		if (isalnum(name[0]) == 0): letter[0] = '?'
		free(name)
		mm_icon_circle(s, x, y, 9)
		mm_text(s, x - mm_text_width(letter, 0) / 2, y - MM_TEXT_LINE / 2, letter)
	mm_icon_paint(s, start, color)
	return 1
