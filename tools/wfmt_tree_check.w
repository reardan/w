/*
wfmt_tree_check: the same-binary check for wfmt (issue #716; run by the
wfmt_test target, docs/projects/wfmt.md).

	bin/wfmt_tree_check deps.txt

deps.txt lists the compiler's import closure, one repo-relative path per
line ('bin/wv2 deps w.w'). Each file is copied to bin/wfmt_tree/ with
only wfmt's blank-line rules applied (wfmt --lines-only), and the copy
of w.w is compiled for x86 and x64 as the reference. Then every file is
fully formatted in place, formatting it again must change nothing, and
the copy is compiled again: both binaries must be byte-identical to
their references. The blank-line rules are applied to the reference
because the lines they drop move the line numbers recorded in the
binary; everything else wfmt does must not change a byte.
*/
import lib.lib
import lib.args
import lib.file
import lib.process
import lib.stream
import tools.wfmt_lib


char* tree_root = c"bin/wfmt_tree"


char* tree_path(char* path):
	string_builder* s = string_new()
	string_append(s, tree_root)
	string_append_char(s, '/')
	string_append(s, path)
	char* text = s.data
	free(s)
	return text


# mkdir -p for the directories above path
void tree_make_parents(char* path):
	int n = strlen(path)
	char* dir = strclone(path)
	for i in range(n):
		if ((i > 0) && (dir[i] == '/')):
			dir[i] = 0
			mkdir(dir, 493)
			dir[i] = '/'
	free(dir)


void tree_fail(char* message, char* detail):
	print2(c"wfmt_tree_check: ")
	print2(message)
	println2(detail)
	exit(1)


void tree_write(char* path, char* text):
	if (file_write_text(path, text) == 0): tree_fail(c"cannot write ", path)


# Compile the tree's w.w from inside the tree, so that every path the
# binary records is the same for the reference and the formatted copy
void tree_compile(char* arch, char* output):
	char** argv = strv_new(7)
	int i = 0
	strv_set(argv, i, c"../wv2")
	i = i + 1
	if (arch != 0):
		strv_set(argv, i, arch)
		i = i + 1
	strv_set(argv, i, c"--quiet")
	strv_set(argv, i + 1, c"w.w")
	strv_set(argv, i + 2, c"-o")
	strv_set(argv, i + 3, output)
	strv_set(argv, i + 4, 0)
	spawn_options* opts = spawn_options_new()
	opts.cwd = tree_root
	process* p = process_spawn(c"../wv2", argv, opts)
	if (p == 0): tree_fail(c"cannot run ", c"bin/wv2")
	int status = process_wait(p)
	if (status != 0): tree_fail(c"compile failed: ", output)


string_builder* tree_read_bytes(char* path):
	wstream* in = stream_open_read(path)
	if (in == 0): tree_fail(c"cannot read ", path)
	string_builder* bytes = string_new()
	stream_read_all(in, bytes)
	stream_close(in)
	return bytes


void tree_same(char* a, char* b):
	string_builder* x = tree_read_bytes(a)
	string_builder* y = tree_read_bytes(b)
	int same = x.length == y.length
	int i = 0
	while (same && (i < x.length)):
		same = x.data[i] == y.data[i]
		i = i + 1
	if (same == 0): tree_fail(c"formatting changed the binary: ", b)


char* tree_format(char* source, char* path, int lines_only):
	wfmt_lines_only = lines_only
	char* result = wfmt_format(source, path)
	if (result == 0): tree_fail(c"", wfmt_error)
	return result


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc != 2):
		println2(c"usage: wfmt_tree_check deps.txt")
		return 2
	list[char*] paths = file_read_lines(args_get(1))
	list[char*] files = new list[char*]
	list[char*] sources = new list[char*]
	for i in range(paths.length):
		char* path = paths[i]
		if (strlen(path) == 0): continue
		char* source = file_read_text(path)
		if (source == 0): tree_fail(c"cannot read ", path)
		char* copy = tree_path(path)
		tree_make_parents(copy)
		tree_write(copy, tree_format(source, path, 1))
		files.push(path)
		sources.push(source)

	tree_compile(0, c"../wfmt_tree_x86_before")
	tree_compile(c"x64", c"../wfmt_tree_x64_before")

	int changed = 0
	for i in range(files.length):
		char* reference = tree_format(sources[i], files[i], 1)
		char* formatted = tree_format(sources[i], files[i], 0)
		char* again = tree_format(formatted, files[i], 0)
		if (strcmp(formatted, again) != 0): tree_fail(c"formatting is not idempotent: ", files[i])
		if (strcmp(reference, formatted) != 0): changed = changed + 1
		tree_write(tree_path(files[i]), formatted)

	tree_compile(0, c"../wfmt_tree_x86_after")
	tree_compile(c"x64", c"../wfmt_tree_x64_after")
	tree_same(c"bin/wfmt_tree_x86_before", c"bin/wfmt_tree_x86_after")
	tree_same(c"bin/wfmt_tree_x64_before", c"bin/wfmt_tree_x64_after")

	print(c"wfmt tree check: ")
	print(itoa(files.length))
	print(c" files, ")
	print(itoa(changed))
	println(c" reformatted beyond blank lines; x86 and x64 binaries unchanged")
	return 0
