# Source envelopes preserve original bytes and report original-document offsets.
# Selectable Mermaid Markdown fences; frontmatter and init directives are read by config.w.
import libs.extras.mermaid.model
import libs.extras.mermaid.config
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
	if (d.error == 0): mm_config_read(d)
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
