# Source envelopes preserve original bytes and report original-document offsets.
# Selectable Mermaid Markdown fences; bounded title and theme configuration frontmatter.
import libs.extras.mermaid.model
import libs.extras.mermaid.style
import lib.utf8

int mm_source_line_end(mm_document* d, int start, int limit):
	int end = start
	while (end < limit && d.source[end] != 10): end = end + 1
	return end

char* mm_source_trim(mm_document* d, int start, int end):
	while (start < end && (d.source[start] == 32 || d.source[start] == 9 || d.source[start] == 13)): start = start + 1
	while (end > start && (d.source[end - 1] == 32 || d.source[end - 1] == 9 || d.source[end - 1] == 13)): end = end - 1
	return str_copy_range(d.source, start, end)

int mm_source_fence_selected(mm_document* d, int selected):
	int fence = 0
	int fence_count = 0
	int mermaid = 0
	int mermaid_open = 0
	int found = 0
	int pos = d.source_start
	while (pos < d.length):
		int end = mm_source_line_end(d, pos, d.length)
		int at = pos
		while (at < end && d.source[at] == 32 && at - pos < 3): at = at + 1
		int symbol = 0
		if (at < end): symbol = d.source[at]
		int count = 0
		if (symbol == '`' || symbol == '~'):
			while (at + count < end && d.source[at + count] == symbol): count = count + 1
		if (count >= 3):
			char* suffix = mm_source_trim(d, at + count, end)
			if (fence == 0):
				fence = symbol
				fence_count = count
				mermaid = strcmp(suffix, c"mermaid") == 0
				if (mermaid):
					mermaid_open = pos
					if (found == selected):
						d.source_start = end
						if (end < d.length): d.source_start = end + 1
					found = found + 1
			else if (symbol == fence && count >= fence_count && suffix[0] == 0):
				if (mermaid && found - 1 == selected): d.source_end = pos
				fence = 0
				mermaid = 0
			free(suffix)
		pos = end + 1
	if (fence && mermaid): mm_error(d, mermaid_open, c"unterminated Mermaid fence")
	if (selected < 0 || (found > 0 && selected >= found) || (found == 0 && selected != 0)): mm_error(d, 0, c"Mermaid diagram index out of range")
	return found

char* mm_source_title(mm_document* d, int start, int end):
	char* value = mm_source_trim(d, start, end)
	int length = strlen(value)
	if (length > 0 && (value[0] == '"' || value[0] == '\'')):
		int quote = value[0]
		if (length < 2 || value[length - 1] != quote): mm_error(d, start, c"unterminated frontmatter title")
		else:
			for i in range(1, length - 1):
				if (value[i] == '\\' || value[i] == quote): mm_error(d, start + i, c"escaped YAML title values are not yet supported")
			char* inner = str_copy_range(value, 1, length - 1)
			free(value)
			value = inner
	else:
		if (length > 0 && (value[0] == '|' || value[0] == '>' || value[0] == '{' || value[0] == '[' || value[0] == '&' || value[0] == '*')): mm_error(d, start, c"frontmatter title must be a scalar string")
		for i in range(length):
			if (value[i] == '#' && (i == 0 || value[i - 1] == 32)):
				int stop = i
				while (stop > 0 && value[stop - 1] == 32): stop = stop - 1
				value[stop] = 0
				break
	return value

void mm_source_frontmatter(mm_document* d):
	int pos = d.source_start
	int end = mm_source_line_end(d, pos, d.source_end)
	char* line = mm_source_trim(d, pos, end)
	int present = strcmp(line, c"---") == 0
	free(line)
	if (present == 0): return
	pos = end + 1
	int title_seen = 0
	int config_seen = 0
	int theme_seen = 0
	int variables_seen = 0
	int config = 0
	int variables = 0
	int packet = 0
	int packet_seen = 0
	int bits_seen = 0
	int order_seen = 0
	int layout_seen = 0
	mm_style custom
	custom.mask = 0
	custom.fill = 0
	custom.stroke = 0
	custom.text = 0
	custom.width = 0
	int line_color = -2
	int label_color = -2
	int background = -2
	while (pos < d.source_end):
		end = mm_source_line_end(d, pos, d.source_end)
		line = mm_source_trim(d, pos, end)
		if (strcmp(line, c"---") == 0):
			free(line)
			if (variables_seen && d.theme != 2): mm_error(d, pos, c"themeVariables require theme: base")
			mm_style_merge(&d.palette, &custom)
			if (line_color != -2): d.palette_line = line_color
			if (label_color != -2): d.palette_label = label_color
			if (background != -2): d.background = background
			d.source_start = end
			if (end < d.source_end): d.source_start = end + 1
			return
		if (line[0] != 0 && line[0] != '#'):
			int at = pos
			while (at < end && d.source[at] == 32): at = at + 1
			int indent = at - pos
			if (indent == 0 && index_of(line, c"title:") == 0):
				config = 0
				variables = 0
				packet = 0
				if (title_seen): mm_error(d, pos, c"duplicate frontmatter title")
				title_seen = 1
				free(d.title)
				d.title = mm_source_title(d, at + 6, end)
			else if (indent == 0 && strcmp(line, c"config:") == 0):
				if (config_seen): mm_error(d, pos, c"duplicate frontmatter config")
				config_seen = 1
				config = 1
				mm_style_theme(d, c"default")
			else if (config && indent == 2 && index_of(line, c"theme:") == 0):
				variables = 0
				packet = 0
				if (theme_seen): mm_error(d, pos, c"duplicate theme setting")
				theme_seen = 1
				char* value = mm_source_title(d, at + 6, end)
				if (mm_style_theme(d, value) == 0): mm_error(d, pos, c"unsupported theme; supported: default, base, dark, forest, neutral")
				free(value)
			else if (config && indent == 2 && index_of(line, c"layout:") == 0):
				variables = 0
				packet = 0
				if (layout_seen): mm_error(d, pos, c"duplicate layout setting")
				layout_seen = 1
				char* value = mm_source_title(d, at + 7, end)
				if (strcmp(value, c"force") == 0): d.layout_algorithm = 1
				else if (strcmp(value, c"dagre") != 0): mm_error(d, pos, c"supported native layouts: dagre, force")
				free(value)
			else if (config && indent == 2 && strcmp(line, c"packet:") == 0):
				variables = 0
				if (packet_seen): mm_error(d, pos, c"duplicate packet configuration")
				packet_seen = 1
				packet = 1
			else if (config && packet && indent == 4):
				int colon = index_of(line, c":")
				if (colon < 0): mm_error(d, pos, c"packet setting requires colon")
				else:
					char* key = str_copy_range(line, 0, colon)
					char* value = mm_source_title(d, at + colon + 1, end)
					if (strcmp(key, c"bitsPerRow") == 0):
						if (bits_seen): mm_error(d, pos, c"duplicate bitsPerRow")
						bits_seen = 1
						int bits = 0
						if (strlen(value) == 0 || strlen(value) > 3): mm_error(d, pos, c"bitsPerRow must be 1..128")
						for i in range(strlen(value)):
							if (value[i] < '0' || value[i] > '9' || bits > 128):
								mm_error(d, pos, c"bitsPerRow must be 1..128")
								break
							bits = bits * 10 + value[i] - '0'
						if (bits < 1 || bits > 128): mm_error(d, pos, c"bitsPerRow must be 1..128")
						if (d.error == 0): d.packet_bits = bits
					else if (strcmp(key, c"bitOrder") == 0):
						if (order_seen): mm_error(d, pos, c"duplicate bitOrder")
						order_seen = 1
						if (strcmp(value, c"descending") == 0): d.packet_msb = 1
						else if (strcmp(value, c"ascending") != 0): mm_error(d, pos, c"bitOrder must be ascending or descending")
					else: mm_error(d, pos, c"unsupported packet setting")
					free(key)
					free(value)
			else if (config && indent == 2 && strcmp(line, c"themeVariables:") == 0):
				packet = 0
				if (variables_seen): mm_error(d, pos, c"duplicate themeVariables setting")
				variables_seen = 1
				variables = 1
			else if (config && variables && indent == 4):
				int colon = index_of(line, c":")
				if (colon < 0): mm_error(d, pos, c"theme variable requires colon")
				else:
					char* key = str_copy_range(line, 0, colon)
					char* value = mm_source_title(d, at + colon + 1, end)
					int color = mm_style_color(value)
					if (value[0] != '#' || color < 0): mm_error(d, pos, c"theme variables require quoted #RGB or #RRGGBB colors")
					if (strcmp(key, c"primaryColor") == 0):
						custom.mask = custom.mask | 1
						custom.fill = color
					else if (strcmp(key, c"primaryBorderColor") == 0):
						custom.mask = custom.mask | 2
						custom.stroke = color
					else if (strcmp(key, c"primaryTextColor") == 0):
						custom.mask = custom.mask | 4
						custom.text = color
					else if (strcmp(key, c"lineColor") == 0): line_color = color
					else if (strcmp(key, c"textColor") == 0): label_color = color
					else if (strcmp(key, c"background") == 0): background = color
					else: mm_error(d, pos, c"unsupported theme variable")
					free(key)
					free(value)
			else: mm_error(d, pos, c"unsupported frontmatter field or indentation")
		free(line)
		pos = end + 1
	mm_error(d, d.source_start, c"unterminated frontmatter")

mm_document* mm_source_prepare_selected(char* source, int length, int selected):
	mm_document* d = mm_document_new()
	if (length < 0 || length > MM_MAX_SOURCE || (source == 0 && length != 0)):
		mm_error(d, 0, c"invalid input or source limit exceeded")
		return d
	free(d.source)
	d.source = str_copy_range(source, 0, length)
	d.length = length
	d.source_end = length
	if (utf8_validate_bytes(source, length) == 0):
		mm_error(d, 0, c"invalid UTF-8 source")
		return d
	for i in range(length):
		int c = source[i] & 255
		if (c < 32 && c != 9 && c != 10 && c != 13):
			mm_error(d, i, c"embedded NUL or unsupported control character")
			return d
	if (length >= 3 && (source[0] & 255) == 239 && (source[1] & 255) == 187 && (source[2] & 255) == 191): d.source_start = 3
	mm_source_fence_selected(d, selected)
	if (d.error == 0): mm_source_frontmatter(d)
	return d

mm_document* mm_source_prepare(char* source, int length):
	return mm_source_prepare_selected(source, length, 0)

# Count Mermaid fences; a raw Mermaid source is one editable diagram.
int mm_source_diagram_count(char* source, int length):
	if (length < 0 || length > MM_MAX_SOURCE || source == 0): return 0
	mm_document* d = mm_document_new()
	free(d.source)
	d.source = str_copy_range(source, 0, length)
	d.length = length
	d.source_end = length
	if (length >= 3 && (source[0] & 255) == 239 && (source[1] & 255) == 187 && (source[2] & 255) == 191): d.source_start = 3
	int count = mm_source_fence_selected(d, 0)
	if (count == 0): count = 1
	mm_document_free(d)
	return count
