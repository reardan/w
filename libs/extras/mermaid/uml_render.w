# UML note gutters preserve graph vertices and keep annotations outside groups.
import libs.extras.mermaid.scene
import libs.extras.mermaid.style_render

list[char*] mm_uml_note_lines(char* text):
	list[char*] lines = new list[char*]
	string_builder* line = string_new()
	int i = 0
	while (text[i] != 0):
		int escaped = text[i] == 92 && text[i + 1] == 'n'
		if (text[i] == 10 || escaped):
			lines.push(strclone(line.data))
			string_free(line)
			line = string_new()
			if (escaped): i = i + 1
		else if (text[i] != 13): string_append_char(line, text[i])
		i = i + 1
	if (line.length != 0 || lines.length == 0): lines.push(strclone(line.data))
	string_free(line)
	return lines

int mm_uml_note_width(list[char*] lines):
	int width = 120
	for char* line in lines:
		if (mm_text_width(line, 0) + 32 > width): width = mm_text_width(line, 0) + 32
	return width

void mm_uml_note_lines_free(list[char*] lines):
	for char* line in lines: free(line)
	__w_list_free(cast(__w_list*, lines))

void mm_uml_notes(mm_document* d, mm_scene* s):
	int gutter = 0
	for mm_note* note in d.notes:
		if (note.side >= 0 || note.node < 0): continue
		list[char*] lines = mm_uml_note_lines(note.text)
		int width = mm_uml_note_width(lines) + 60
		if (width > gutter): gutter = width
		mm_uml_note_lines_free(lines)
	if (gutter):
		for mm_bounds* bounds in s.nodes: bounds.x = bounds.x + gutter
		for mm_primitive* item in s.items:
			item.x = item.x + gutter
			item.x2 = item.x2 + gutter
			if (item.points != 0):
				for i in range(0, item.points.length, 2): item.points[i] = item.points[i] + gutter
		s.width = s.width + gutter
	int right = s.width
	int left_y = 60
	int right_y = 60
	int below = s.height
	for mm_note* note in d.notes:
		list[char*] lines = mm_uml_note_lines(note.text)
		int width = mm_uml_note_width(lines)
		int height = lines.length * 22 + 24
		int x = 30
		int y = below
		if (note.node >= 0):
			mm_bounds* bounds = s.nodes[note.node]
			y = bounds.y
			if (note.side < 0):
				if (y < left_y): y = left_y
				left_y = y + height + 24
				mm_line(s, x + width, y + height / 2, bounds.x, bounds.y + bounds.h / 2, 1)
			else:
				x = right
				if (y < right_y): y = right_y
				right_y = y + height + 24
				mm_line(s, bounds.x + bounds.w, bounds.y + bounds.h / 2, x, y + height / 2, 1)
		else:
			if (left_y > y): y = left_y
			if (right_y > y): y = right_y
			below = y + height + 24
		int note_start = s.items.length
		mm_draw(s, MM_BOX, x, y, x + width, y + height, 0, c"")
		mm_line(s, x + width - 12, y, x + width - 12, y + 12, 0)
		mm_line(s, x + width - 12, y + 12, x + width, y + 12, 0)
		for i in range(lines.length): mm_text(s, x + 12, y + 12 + i * 22, lines[i])
		mm_style_role(s, note_start, MM_ROLE_NOTE, 0)
		mm_uml_note_lines_free(lines)
