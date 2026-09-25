# wbuild: target=wcloc dep=wv2 input=tools/wcloc.w input=lib/cloc.w output=bin/wcloc
# wbuild: step="bin/wv2 tools/wcloc.w -o bin/wcloc"
/*
wcloc: count lines of W code (issue #437), a cloc for .w sources built
on lib/cloc.w.

Usage: wcloc [--by-file] [--json] [path ...]

Each path is a .w file or a directory searched recursively for .w files
(hidden entries and bin/ are skipped); with no path, the current
directory. Every file's lines are split into blank / comment / code the
way cloc counts them, plus the number of lexical tokens -- see
lib/cloc.w for the exact rules.

By default a directory argument prints one row per top-level entry
under it (its subdirectories, and the directory itself for the .w
files directly inside), so "wcloc ." reads as a per-subsystem
breakdown; --by-file prints one row per file instead. A file argument
is always its own row. A total row closes the table.

--json prints the same rows as NDJSON, one object per line:
	{"kind": "group", "path": "compiler", "files": 14, "blank": 310, "comment": 820, "code": 4410, "tokens": 30512}
with kind "group", "file" or "total" (the total row has no "path").

Exit status: 0 on success, 2 on a usage error or when a path does not
exist (the remaining paths are still counted). An unreadable file is
reported on stderr and skipped.
*/
import lib.lib
import lib.stream
import lib.cloc


struct wcloc_row:
	char* path
	int is_file
	cloc_counts* counts


void wcloc_usage():
	wstream* err = stderr_writer()
	stream_write_line(err, c"usage: wcloc [--by-file] [--json] [path ...]")
	stream_flush(err)


void wcloc_error(char* what, char* path):
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"wcloc: ")
	stream_write_cstr(err, what)
	stream_write_cstr(err, c" '")
	stream_write_cstr(err, path)
	stream_write_line(err, c"'")
	stream_flush(err)


# The row a file under directory root is grouped into: root itself for
# a file directly inside it, else root/<first path component>. file
# always starts with root + '/' (cloc_collect builds it with
# path_join).
char* wcloc_group_path(char* root, char* file):
	int start = strlen(root)
	if ((start > 0) && (root[start - 1] != '/')):
		start = start + 1
	int end = start
	while ((file[end] != 0) && (file[end] != '/')):
		end = end + 1
	if (file[end] == 0):
		return strclone(root)
	char* group = malloc(end + 1)
	int i = 0
	while (i < end):
		group[i] = file[i]
		i = i + 1
	group[end] = 0
	return group


wcloc_row* wcloc_new_row(char* path, int is_file):
	wcloc_row* row = new wcloc_row
	row.path = path
	row.is_file = is_file
	row.counts = new cloc_counts
	cloc_counts_clear(row.counts)
	return row


# The display form of a collected path: "wcloc" with no argument (or
# ".") walks "." and cloc_collect joins every result as "./x"; showing
# "x" reads the way the tree is usually named.
char* wcloc_display_path(char* path):
	if ((path[0] == '.') && (path[1] == '/') && (path[2] != 0)):
		return strclone(path + 2)
	return strclone(path)


# The row in rows[first..] whose path is key, or 0.
wcloc_row* wcloc_find_row(list[wcloc_row*] rows, int first, char* key):
	int i = first
	while (i < rows.length):
		if (strcmp(rows[i].path, key) == 0):
			return rows[i]
		i = i + 1
	return 0


# Count every file of one argument into rows. Returns 0, or 2 when the
# path does not exist.
int wcloc_count_path(char* path, int by_file, list[wcloc_row*] rows):
	list[char*] files = new list[char*]
	if (cloc_collect(path, files) != 0):
		wcloc_error(c"cannot access", path)
		return 2
	int path_is_file = (files.length == 1) && (strcmp(files[0], path) == 0)
	int first = rows.length
	int i = 0
	while (i < files.length):
		char* file = files[i]
		char* raw = 0
		int is_file = 1
		if (by_file || path_is_file):
			raw = strclone(file)
		else:
			raw = wcloc_group_path(path, file)
			is_file = 0
		char* key = wcloc_display_path(raw)
		free(raw)
		wcloc_row* row = wcloc_find_row(rows, first, key)
		if (row == 0):
			row = wcloc_new_row(key, is_file)
			rows.push(row)
		else:
			free(key)
		cloc_counts counts
		cloc_counts_clear(&counts)
		if (cloc_scan_file(file, &counts) == 0):
			cloc_counts_add(row.counts, &counts)
		else:
			wcloc_error(c"cannot read", file)
		free(file)
		i = i + 1
	return 0


void wcloc_pad_left(wstream* out, int value, int width):
	char* text = itoa(value)
	int n = strlen(text)
	while (n < width):
		stream_write_byte(out, ' ')
		n = n + 1
	stream_write_cstr(out, text)
	free(text)


void wcloc_table_row(wstream* out, char* path, cloc_counts* c, int path_width):
	stream_write_cstr(out, path)
	int n = strlen(path)
	while (n < path_width):
		stream_write_byte(out, ' ')
		n = n + 1
	wcloc_pad_left(out, c.files, 7)
	wcloc_pad_left(out, c.blank, 9)
	wcloc_pad_left(out, c.comment, 9)
	wcloc_pad_left(out, c.code, 9)
	wcloc_pad_left(out, c.tokens, 10)
	stream_write_byte(out, 10)


void wcloc_rule(wstream* out, int width):
	int n = 0
	while (n < width):
		stream_write_byte(out, '-')
		n = n + 1
	stream_write_byte(out, 10)


void wcloc_print_table(wstream* out, list[wcloc_row*] rows, cloc_counts* total):
	int path_width = 5
	int i = 0
	while (i < rows.length):
		int n = strlen(rows[i].path)
		if (n > path_width):
			path_width = n
		i = i + 1
	path_width = path_width + 2
	int width = path_width + 7 + 9 + 9 + 9 + 10
	stream_write_cstr(out, c"path")
	int n = 4
	while (n < path_width):
		stream_write_byte(out, ' ')
		n = n + 1
	stream_write_line(out, c"  files    blank  comment     code    tokens")
	wcloc_rule(out, width)
	i = 0
	while (i < rows.length):
		wcloc_table_row(out, rows[i].path, rows[i].counts, path_width)
		i = i + 1
	wcloc_rule(out, width)
	wcloc_table_row(out, c"total", total, path_width)


# Writes s as a JSON string literal.
void wcloc_json_string(wstream* out, char* s):
	stream_write_byte(out, '"')
	int i = 0
	while (s[i] != 0):
		int ch = s[i] & 255
		if ((ch == '"') || (ch == 92)):
			stream_write_byte(out, 92)
			stream_write_byte(out, ch)
		else if (ch < 32):
			stream_write_cstr(out, c"\\u00")
			stream_write_byte(out, '0' + (ch >> 4))
			int low = ch & 15
			if (low < 10):
				stream_write_byte(out, '0' + low)
			else:
				stream_write_byte(out, 'a' + low - 10)
		else:
			stream_write_byte(out, ch)
		i = i + 1
	stream_write_byte(out, '"')


void wcloc_json_field(wstream* out, char* name, int value):
	stream_write_cstr(out, c", \"")
	stream_write_cstr(out, name)
	stream_write_cstr(out, c"\": ")
	stream_write_int(out, value)


void wcloc_json_row(wstream* out, char* kind, char* path, cloc_counts* c):
	stream_write_cstr(out, c"{\"kind\": \"")
	stream_write_cstr(out, kind)
	stream_write_byte(out, '"')
	if (path != 0):
		stream_write_cstr(out, c", \"path\": ")
		wcloc_json_string(out, path)
	wcloc_json_field(out, c"files", c.files)
	wcloc_json_field(out, c"blank", c.blank)
	wcloc_json_field(out, c"comment", c.comment)
	wcloc_json_field(out, c"code", c.code)
	wcloc_json_field(out, c"tokens", c.tokens)
	stream_write_line(out, c"}")


void wcloc_print_json(wstream* out, list[wcloc_row*] rows, cloc_counts* total):
	int i = 0
	while (i < rows.length):
		char* kind = c"group"
		if (rows[i].is_file):
			kind = c"file"
		wcloc_json_row(out, kind, rows[i].path, rows[i].counts)
		i = i + 1
	wcloc_json_row(out, c"total", 0, total)


int main(int argc, int argv):
	int by_file = 0
	int json = 0
	list[char*] paths = new list[char*]
	int i = 1
	while (i < argc):
		char** arg_slot = argv + i * __word_size__
		char* arg = *arg_slot
		if (strcmp(arg, c"--by-file") == 0):
			by_file = 1
		else if (strcmp(arg, c"--json") == 0):
			json = 1
		else if ((arg[0] == '-') && (arg[1] != 0)):
			wcloc_usage()
			return 2
		else:
			paths.push(arg)
		i = i + 1
	if (paths.length == 0):
		paths.push(c".")

	int status = 0
	list[wcloc_row*] rows = new list[wcloc_row*]
	i = 0
	while (i < paths.length):
		if (wcloc_count_path(paths[i], by_file, rows) != 0):
			status = 2
		i = i + 1

	cloc_counts total
	cloc_counts_clear(&total)
	i = 0
	while (i < rows.length):
		cloc_counts_add(&total, rows[i].counts)
		i = i + 1

	wstream* out = stdout_writer()
	if (json):
		wcloc_print_json(out, rows, &total)
	else:
		wcloc_print_table(out, rows, &total)
	stream_flush(out)
	return status
