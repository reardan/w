import libs.extras.mermaid.parser
import lib.stream
import lib.fs

# Bounded raw read retaining explicit byte length. Null means I/O/budget failure.
# The caller owns the returned bytes, which may include invalid syntax or NUL.
char* mm_read_source(char* path, int* length):
	wstream* input = stream_open_read(path)
	if (input == 0): return 0
	string_builder* text = string_new()
	char[4096] chunk
	int failed = 0
	while (1):
		int count = stream_read(input, &chunk[0], 4096)
		if (count <= 0): break
		if (count > MM_MAX_SOURCE - text.length):
			failed = 1
			break
		string_append_bytes(text, &chunk[0], count)
	if (stream_error(input) != IO_OK): failed = 1
	stream_close(input)
	if (failed):
		string_free(text)
		return 0
	*length = text.length
	char* source = text.data
	free(text)
	return source

mm_document* mm_read_selected(char* path, int selected):
	int length = 0
	char* source = mm_read_source(path, &length)
	if (source == 0): return 0
	mm_document* d = mm_parse_selected(source, length, selected)
	free(source)
	return d

mm_document* mm_read(char* path):
	return mm_read_selected(path, 0)

# Atomic replace with durability reporting. Invalid source is saveable too.
# See lib.fs for supported OSes and post-publication sync-failure semantics.
int mm_save(mm_document* d, char* path, io_result* result):
	return file_write_durable(path, d.source, d.length, result)

char* mm_diagnostic(mm_document* d):
	string_builder* s = string_new()
	if (d.error != 0):
		string_append_int(s, d.error_line)
		string_append_char(s, ':')
		string_append_int(s, d.error_column)
		string_append(s, c": ")
		string_append(s, d.error)
	char* text = s.data
	free(s)
	return text
