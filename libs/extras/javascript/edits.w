/*
Validated byte-span edits. Offsets refer to the original source. Edits can
arrive in any order; overlaps and ambiguous edits at the same offset fail.
Untouched source, including comments, whitespace and NUL bytes, is copied
verbatim. Caller owns the returned buffer and every edit in its list.
*/
import structures.string
import libs.extras.parser_generator.diagnostics
import libs.extras.parser_generator.token


struct js_source_edit:
	int offset
	int length
	char* replacement
	int replacement_length


js_source_edit* js_source_edit_new(int offset, int length, char* replacement, int replacement_length):
	js_source_edit* edit = new js_source_edit()
	edit.offset = offset
	edit.length = length
	edit.replacement_length = replacement_length
	if (replacement_length < 0): replacement_length = 0
	edit.replacement = pg_substr(replacement, 0, replacement_length)
	return edit


void js_source_edit_free(js_source_edit* edit):
	if (edit == 0): return
	free(edit.replacement)
	free(edit)


char* js_source_edits_apply(char* source, int length, list[js_source_edit*] edits, pg_diagnostics* diagnostics, int* output_length):
	*output_length = 0
	list[js_source_edit*] ordered = new list[js_source_edit*]
	int valid = length >= 0
	for i in range(edits.length):
		js_source_edit* edit = edits[i]
		if (edit.offset < 0 || edit.length < 0 || edit.offset > length || edit.replacement_length < 0): valid = 0
		else:
			if (edit.length > length - edit.offset): valid = 0
		ordered.push(edit)
		int j = ordered.length - 1
		while (j > 0 && ordered[j - 1].offset > edit.offset):
			ordered[j] = ordered[j - 1]
			j = j - 1
		ordered[j] = edit
	int end = 0
	int previous_offset = -1
	for i in range(ordered.length):
		js_source_edit* edit = ordered[i]
		if (edit.offset < end || edit.offset == previous_offset): valid = 0
		previous_offset = edit.offset
		if (valid): end = edit.offset + edit.length
	if (valid == 0):
		pg_diagnostics_add(diagnostics, c"<source edits>", 1, 1, c"invalid or overlapping source edits", c"disjoint source byte ranges", c"")
		__w_list_free(cast(__w_list*, ordered))
		return 0
	string_builder* out = string_new()
	int cursor = 0
	for i in range(ordered.length):
		js_source_edit* edit = ordered[i]
		string_append_bytes(out, source + cursor, edit.offset - cursor)
		string_append_bytes(out, edit.replacement, edit.replacement_length)
		cursor = edit.offset + edit.length
	string_append_bytes(out, source + cursor, length - cursor)
	*output_length = out.length
	char* result = out.data
	free(out)
	__w_list_free(cast(__w_list*, ordered))
	return result
