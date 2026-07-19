# Migration helper: prefix bare "..." literals with c across every
# git-tracked .w file, skipping literals that already carry a c/s prefix
# and the paths after c_lib / c_import (those take host library names).
#
# Usage: rewrite_c_strings [--check]
#   --check  print files that would change and exit 1 instead of writing
import lib.lib
import lib.args
import lib.file
import lib.process
import lib.stream
import structures.string


int rw_is_ident_char(int c):
	if ((c >= 'a') && (c <= 'z')):
		return 1
	if ((c >= 'A') && (c <= 'Z')):
		return 1
	if ((c >= '0') && (c <= '9')):
		return 1
	return c == '_'


int rw_is_space(int c):
	return (c == ' ') | (c == '\t') | (c == '\r') | (c == '\n')


# The identifier just before quote_index, skipping trailing whitespace.
# Returns a malloc'd string (empty when none).
char* rw_previous_identifier(char* text, int quote_index):
	int i = quote_index - 1
	while ((i >= 0) && rw_is_space(text[i])):
		i = i - 1
	int end = i + 1
	while ((i >= 0) && rw_is_ident_char(text[i])):
		i = i - 1
	int start = i + 1
	char* result = malloc(end - start + 1)
	int j = 0
	while (start + j < end):
		result[j] = text[start + j]
		j = j + 1
	result[j] = 0
	return result


# 1 when the literal at quote index i should keep its bare spelling: it
# already has a c/s prefix, or it names a c_lib / c_import path.
int rw_keep_bare(char* text, int i):
	int prev = 0
	if (i > 0):
		prev = text[i - 1]
	if ((prev == 'c') || (prev == 's')):
		return 1
	char* keyword = rw_previous_identifier(text, i)
	int keep = (strcmp(keyword, c"c_lib") == 0) | (strcmp(keyword, c"c_import") == 0)
	free(keyword)
	return keep


int rw_state_code():
	return 0


int rw_state_line_comment():
	return 1


int rw_state_block_comment():
	return 2


int rw_state_char():
	return 3


# Returns the rewritten text as a string_builder the caller frees.
string_builder* rw_rewrite(char* text):
	string_builder* out = string_new_sized(strlen(text) + 1)
	int i = 0
	int state = rw_state_code()
	while (text[i]):
		int c = text[i]
		int n = text[i + 1]
		if (state == rw_state_line_comment()):
			string_append_char(out, c)
			if (c == '\n'):
				state = rw_state_code()
			i = i + 1
		else if (state == rw_state_block_comment()):
			string_append_char(out, c)
			if ((c == '*') && (n == '/')):
				string_append_char(out, n)
				i = i + 2
				state = rw_state_code()
			else:
				i = i + 1
		else if (state == rw_state_char()):
			string_append_char(out, c)
			if ((c == '\\') && (n != 0)):
				string_append_char(out, n)
				i = i + 2
			else:
				if (c == 39):
					state = rw_state_code()
				i = i + 1
		else if (c == '#'):
			string_append_char(out, c)
			state = rw_state_line_comment()
			i = i + 1
		else if ((c == '/') && (n == '*')):
			string_append_char(out, c)
			string_append_char(out, n)
			state = rw_state_block_comment()
			i = i + 2
		else if (c == 39):
			string_append_char(out, c)
			state = rw_state_char()
			i = i + 1
		else if (c == '"'):
			if (rw_keep_bare(text, i) == 0):
				string_append_char(out, 'c')
			string_append_char(out, c)
			i = i + 1
			while (text[i]):
				string_append_char(out, text[i])
				if ((text[i] == '\\') && (text[i + 1] != 0)):
					i = i + 1
					string_append_char(out, text[i])
					i = i + 1
				else if (text[i] == '"'):
					i = i + 1
					break
				else:
					i = i + 1
		else:
			string_append_char(out, c)
			i = i + 1
	return out


# Git-tracked .w files, one path per stdout line.
list[char*] rw_tracked_w_files():
	char** argv = strv_new(4)
	strv_set(argv, 0, c"env")
	strv_set(argv, 1, c"git")
	strv_set(argv, 2, c"ls-files")
	strv_set(argv, 3, c"*.w")
	process_result* r = process_run(c"/usr/bin/env", argv, 0, 0, 60000)
	free(cast(void*, argv))
	if (r == 0):
		return 0
	if (r.status != 0):
		process_result_free(r)
		return 0
	list[char*] paths = new list[char*]
	string_builder* line = string_new()
	char* text = r.stdout_text
	int i = 0
	while (1):
		int c = text[i]
		if ((c == '\n') || (c == 0)):
			if (line.length > 0):
				paths.push(strclone(line.data))
			string_clear(line)
			if (c == 0):
				break
		else:
			string_append_char(line, c)
		i = i + 1
	string_free(line)
	process_result_free(r)
	return paths


int main(int argc, int argv):
	args_init(argc, argv)
	int check = args_has_flag(c"check")
	list[char*] paths = rw_tracked_w_files()
	if (paths == 0):
		wstream* err = stderr_writer()
		stream_write_line(err, c"rewrite_c_strings: git ls-files failed")
		stream_flush(err)
		return 1
	list[char*] changed = new list[char*]
	for char* path in paths:
		char* original = file_read_text(path)
		if (original == 0):
			continue
		string_builder* updated = rw_rewrite(original)
		if (strcmp(updated.data, original) != 0):
			changed.push(path)
			if (check == 0):
				file_write_text(path, updated.data)
		string_free(updated)
		free(original)
	wstream* out = stdout_writer()
	for char* path in changed:
		stream_write_line(out, path)
	stream_flush(out)
	if (check && (changed.length > 0)):
		return 1
	return 0
