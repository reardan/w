/* Small textwrap subset: wrap/fill/dedent/indent for UTF-8 byte strings. */
import lib.lib
import structures.string
import libs.standard.text.core

int textwrap_is_space(int ch):
	return text_is_ascii_space(ch)

int textwrap_line_blank(char* line):
	int i = 0
	while (line[i] != 0):
		if ((line[i] != ' ') & (line[i] != 9) & (line[i] != 13)):
			return 0
		i = i + 1
	return 1

int textwrap_line_indent(char* line):
	int i = 0
	while ((line[i] == ' ') | (line[i] == 9)):
		i = i + 1
	return i

void textwrap_append_range(string_builder* out, char* text, int start, int length):
	char* part = text_copy_range(text, start, length)
	string_append(out, part)

void textwrap_flush_line(list[char*] lines, string_builder* line):
	if (line.length > 0):
		lines.push(strclone(line.data))
		string_clear(line)

int textwrap_safe_chunk(char* text, int start, int remaining, int limit):
	if (remaining <= limit):
		return remaining
	int cut = limit
	while ((cut > 0) & text_is_utf8_continuation(text[start + cut])):
		cut = cut - 1
	if (cut > 0):
		return cut
	cut = limit
	while ((cut < remaining) & text_is_utf8_continuation(text[start + cut])):
		cut = cut + 1
	return cut

void textwrap_append_segment(list[char*] lines, string_builder* line, char* text, int start, int length, int width):
	if (line.length == 0):
		textwrap_append_range(line, text, start, length)
		return
	if (line.length + 1 + length <= width):
		string_append_char(line, ' ')
		textwrap_append_range(line, text, start, length)
		return
	textwrap_flush_line(lines, line)
	textwrap_append_range(line, text, start, length)

void textwrap_append_word(list[char*] lines, string_builder* line, char* text, int start, int length, int width):
	int offset = 0
	while (offset < length):
		int remaining = length - offset
		if (line.length > 0):
			int available = width - line.length - 1
			if (remaining <= available):
				textwrap_append_segment(lines, line, text, start + offset, remaining, width)
				return
			textwrap_flush_line(lines, line)
		else if (remaining <= width):
			textwrap_append_segment(lines, line, text, start + offset, remaining, width)
			return
		else:
			int chunk = textwrap_safe_chunk(text, start + offset, remaining, width)
			textwrap_append_segment(lines, line, text, start + offset, chunk, width)
			offset = offset + chunk
			if (offset < length):
				textwrap_flush_line(lines, line)

list[char*] textwrap_wrap(char* text, int width):
	text_clear_error()
	list[char*] lines = new list[char*]
	if (text == 0):
		text_set_error(TEXT_ERR_INVALID_ARGUMENT(), c"text must not be null")
		return lines
	if (width <= 0):
		text_set_error(TEXT_ERR_INVALID_ARGUMENT(), c"textwrap width must be positive")
		return lines
	string_builder* line = string_new()
	int i = 0
	while (text[i] != 0):
		while ((text[i] != 0) & textwrap_is_space(text[i])):
			i = i + 1
		if (text[i] == 0):
			break
		int start = i
		while ((text[i] != 0) & (textwrap_is_space(text[i]) == 0)):
			i = i + 1
		textwrap_append_word(lines, line, text, start, i - start, width)
	textwrap_flush_line(lines, line)
	string_free(line)
	return lines

char* textwrap_fill(char* text, int width):
	if (text == 0):
		text_set_error(TEXT_ERR_INVALID_ARGUMENT(), c"text must not be null")
		return strclone(c"")
	if (width <= 0):
		text_set_error(TEXT_ERR_INVALID_ARGUMENT(), c"textwrap width must be positive")
		return strclone(c"")
	list[char*] lines = textwrap_wrap(text, width)
	return text_join_lines(lines)

char* textwrap_dedent(char* text):
	text_clear_error()
	if (text == 0):
		text_set_error(TEXT_ERR_INVALID_ARGUMENT(), c"text must not be null")
		return strclone(c"")
	list[char*] lines = text_split_lines(text)
	int margin = -1
	for char* line in lines:
		if (textwrap_line_blank(line) == 0):
			int indent = textwrap_line_indent(line)
			if ((margin < 0) | (indent < margin)):
				margin = indent
	if (margin <= 0):
		return strclone(text)
	list[char*] out = new list[char*]
	for char* line in lines:
		if (textwrap_line_blank(line)):
			out.push(strclone(c""))
		else:
			out.push(text_copy_range(line, margin, strlen(line) - margin))
	return text_join_lines(out)

char* textwrap_indent(char* text, char* prefix):
	text_clear_error()
	if ((text == 0) | (prefix == 0)):
		text_set_error(TEXT_ERR_INVALID_ARGUMENT(), c"text and prefix must not be null")
		return strclone(c"")
	list[char*] lines = text_split_lines(text)
	list[char*] out_lines = new list[char*]
	for char* line in lines:
		if (textwrap_line_blank(line)):
			out_lines.push(strclone(line))
		else:
			string_builder* out = string_new()
			string_append(out, prefix)
			string_append(out, line)
			out_lines.push(strclone(out.data))
			string_free(out)
	return text_join_lines(out_lines)

int textwrap_supports_option(char* option):
	if ((strcmp(option, c"width") == 0) | (strcmp(option, c"initial_indent") == 0)):
		return 1
	text_set_error(TEXT_ERR_UNSUPPORTED(), c"unsupported textwrap option")
	return 0
