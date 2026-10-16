# Source envelopes preserve original bytes and report original-document offsets.
# One Mermaid Markdown fence per document; frontmatter accepts a plain title.
import libs.extras.mermaid.model
import lib.utf8

int mm_source_line_end(mm_document* d, int start, int limit):
	int end = start
	while (end < limit && d.source[end] != 10): end = end + 1
	return end

char* mm_source_trim(mm_document* d, int start, int end):
	while (start < end && (d.source[start] == 32 || d.source[start] == 9 || d.source[start] == 13)): start = start + 1
	while (end > start && (d.source[end - 1] == 32 || d.source[end - 1] == 9 || d.source[end - 1] == 13)): end = end - 1
	return str_copy_range(d.source, start, end)

void mm_source_fence(mm_document* d):
	int fence = 0
	int fence_count = 0
	int mermaid = 0
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
					if (found): mm_error(d, pos, c"multiple Mermaid fences; open one diagram at a time")
					found = 1
					d.source_start = end
					if (end < d.length): d.source_start = end + 1
			else if (symbol == fence && count >= fence_count && suffix[0] == 0):
				if (mermaid): d.source_end = pos
				fence = 0
				mermaid = 0
			free(suffix)
		pos = end + 1
	if (fence && mermaid): mm_error(d, d.source_start, c"unterminated Mermaid fence")

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
	while (pos < d.source_end):
		end = mm_source_line_end(d, pos, d.source_end)
		line = mm_source_trim(d, pos, end)
		if (strcmp(line, c"---") == 0):
			free(line)
			d.source_start = end
			if (end < d.source_end): d.source_start = end + 1
			return
		if (line[0] != 0 && line[0] != '#'):
			int at = pos
			while (at < end && (d.source[at] == 32 || d.source[at] == 9)): at = at + 1
			if (index_of(line, c"title:") == 0):
				if (title_seen): mm_error(d, pos, c"duplicate frontmatter title")
				title_seen = 1
				free(d.title)
				d.title = mm_source_title(d, at + 6, end)
			else: mm_error(d, pos, c"unsupported frontmatter field; native frontmatter currently supports title")
		free(line)
		pos = end + 1
	mm_error(d, d.source_start, c"unterminated frontmatter")

mm_document* mm_source_prepare(char* source, int length):
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
	mm_source_fence(d)
	if (d.error == 0): mm_source_frontmatter(d)
	return d
