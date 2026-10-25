# wbuild: target=wfmt dep=wv2 input=tools/wfmt.w input=tools/wfmt_lib.w input=tools/parser_generator.w input=tests/parser_generator/w.pg input=libs/extras/parser_generator/ output=bin/wfmt
# wbuild: step="bin/wv2 tools/parser_generator.w -o bin/parser_generator_wfmt"
# wbuild: step="bin/parser_generator_wfmt tests/parser_generator/w.pg -o bin/wfmt_w_parser.w"
# wbuild: step="bin/wv2 tools/wfmt.w -o bin/wfmt"
# wbuild: target=wfmt_check tag=tests dep=wfmt
# wbuild: step="git ls-files *.w" stdout_file="bin/wfmt_check_files.txt"
# wbuild: step="bin/wfmt --check --files-from=bin/wfmt_check_files.txt --exclude-from=tools/wfmt_exclude.txt"
/*
wfmt: rewrite W source in the canonical style (issue #716;
docs/projects/wfmt.md, tools/wfmt_lib.w).

	bin/wfmt file.w            print the formatted file on stdout
	bin/wfmt -                 format stdin to stdout
	bin/wfmt -w file.w...      rewrite the files in place
	bin/wfmt --check file.w... list the files that are not formatted
	--files-from=list          also take the file names in list, one per line
	--exclude-from=list        skip the files list names: one path per
	                           line, a path ending in '/' skips the whole
	                           directory, '#' starts a comment
	--lines-only               apply only the blank-line rules (the
	                           reference the same-binary check compiles)

The wfmt_check target (in tests) runs --check over every tracked .w file
minus tools/wfmt_exclude.txt.

Exit status: 0 when everything is formatted (or was rewritten), 1 when
--check found an unformatted file, 2 on a usage, read or parse error
(the file is then left untouched).
*/
import lib.lib
import lib.args
import lib.file
import lib.stream
import tools.wfmt_lib


void wfmt_usage():
	println2(c"usage: wfmt [-w | --check] file.w...   (or 'wfmt -' for stdin)")


char* wfmt_read_stdin():
	wstream* in = stream_reader(0)
	string_builder* contents = string_new()
	stream_read_all(in, contents)
	char* text = contents.data
	free(contents)
	return text


# 0 = already formatted, 1 = changed, 2 = error
int wfmt_file(char* path, int write, int check):
	char* source = 0
	if (strcmp(path, c"-") == 0): source = wfmt_read_stdin()
	else: source = file_read_text(path)
	if (source == 0):
		print2(c"wfmt: cannot read ")
		println2(path)
		return 2
	char* result = wfmt_format(source, path)
	if (result == 0):
		print2(c"wfmt: ")
		println2(wfmt_error)
		return 2
	int changed = strcmp(source, result) != 0
	if (check):
		if (changed): println(path)
	else if (write && (strcmp(path, c"-") != 0)):
		if (changed && (file_write_text(path, result) == 0)):
			print2(c"wfmt: cannot write ")
			println2(path)
			return 2
	else: print(result)
	return changed


list[char*] wfmt_read_list(char* path):
	list[char*] lines = file_read_lines(path)
	if (lines == 0):
		print2(c"wfmt: cannot read ")
		println2(path)
		exit(2)
	return lines


int wfmt_excluded(list[char*] excludes, char* path):
	for i in range(excludes.length):
		char* entry = excludes[i]
		int n = strlen(entry)
		if ((n == 0) || (entry[0] == '#')): continue
		if (entry[n - 1] == '/'):
			if (starts_with(path, entry)): return 1
		else if (strcmp(path, entry) == 0): return 1
	return 0


int main(int argc, int argv):
	args_init(argc, argv)
	int write = args_has_bool_flag(c"w")
	int check = args_has_bool_flag(c"check")
	wfmt_lines_only = args_has_bool_flag(c"lines-only")
	list[char*] files = new list[char*]
	for i in range(args_positional_count()): files.push(args_positional(i))
	char* files_from = args_value(c"files-from")
	if (files_from != 0):
		list[char*] listed = wfmt_read_list(files_from)
		for i in range(listed.length):
			if (strlen(listed[i]) > 0): files.push(listed[i])
	list[char*] excludes = new list[char*]
	char* exclude_from = args_value(c"exclude-from")
	if (exclude_from != 0): excludes = wfmt_read_list(exclude_from)
	int count = files.length
	# A lone '-' is stdin, which args.w would read as a flag
	int stdin_only = (argc == 2) && (strcmp(args_get(1), c"-") == 0)
	if (stdin_only):
		int r = wfmt_file(c"-", 0, 0)
		if (r == 2): return 2
		return 0
	if ((count == 0) || (write && check) || ((write == 0) && (check == 0) && (count != 1))):
		wfmt_usage()
		return 2
	int status = 0
	for i in range(count):
		if (wfmt_excluded(excludes, files[i])): continue
		int r = wfmt_file(files[i], write, check)
		if (r == 2): status = 2
		else if ((r == 1) && check && (status == 0)): status = 1
	return status
