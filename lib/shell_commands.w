/*
Native coreutils-alike tools for the REPL's shell mode (":sh", issue
#335, docs/projects/repl_shell_mode.md). Each tool is an ordinary,
directly-callable W function -- useful to any program, not only the
REPL -- that repl/shell_translate.w's command-line translator maps a
typed shell command onto (e.g. "ls -a /tmp" -> "shell_commands.ls(c\"/tmp\",
true)"). repl.w synthesizes "import lib.shell_commands as shell_commands"
into the live session the first time ":sh" is used; nothing here is
REPL-specific, so any W program can import it directly too.

Return convention is void (the design doc's Sec 5.6/6.1): a translated
call is a plain call-statement, not a bare echoable expression, and
each tool reports its own errors to its own stderr in coreutils' own
phrasing -- so the wording reads the same whether a command ran
natively or fell back to the real binary via lib/shell.w's
sh_interactive.

None of these take parameter defaults, even though the design doc's
illustrative signature shows one ("char* path = c\".\""): W's
default-parameter grammar (grammar/program.w's parse_constant_default)
only accepts integer literals, char literals, and named enum constants
-- not string or bool literals, both empirically rejected by the
compiler ("default value for parameter must be a compile-time
constant"). This is harmless for the translator, which never relies on
the callee's own defaults and always resolves every parameter to an
explicit literal (including "bare ls"'s documented "." default, filled
in by repl/shell_translate.w itself) -- it only means calling e.g.
"shell_commands.ls()" directly at the W prompt (bypassing translation
entirely) needs an explicit path argument.

Stage 1 scope (design doc Sec 11): pwd (zero-arg), ls (bare and -a; no
-l -- no portable stat/mode/size/mtime wrapper exists yet, Sec 6.2),
cat (one or more paths, no flags). ls's directory walk uses the same
getdents(2) record layout tools/wbuildgen.w and libs/extras/vcs/tree.w
read -- x86/x64 only, matching repl.w's own arch scope (Sec 6.2).

Stage 2 (this file's remaining functions; design doc Sec 11's "rest of
the v1 subset"): echo, head, tail, wc, mkdir_p, rm, cp, mv. rm/cp's
recursive walk reuses the same getdents pattern as ls, and reuses
lib/stat.w's file_lstat_path/file_is_dir (landed via #343, after the
design doc was written) to tell a directory from a file/symlink without
following the symlink -- exactly the "second consumer" promotion Sec
6.2/Sec 3 of the design doc anticipated. Two naming notes:

  - The shell command "mkdir" is implemented here as mkdir_p, not
    mkdir: this file already imports lib.lib, whose transitive
    lib.linux -> lib.__arch__.syscalls import declares a raw
    "int mkdir(char* path, int mode)" syscall wrapper, and W's single
    flat symbol table rejects a second top-level "mkdir" with a
    different signature ("symbol redefined: 'mkdir'", verified against
    bin/wv2 directly). repl/shell_translate.w still recognizes the
    typed word "mkdir" and simply generates a call to mkdir_p --
    the raw syscall/tool naming collision is invisible to anyone typing
    shell-mode commands, and only matters to a W-mode caller spelling
    the qualified name directly.
  - mv uses lib.lib's rename(2) wrapper directly (atomic within one
    filesystem) rather than the design doc's original cp-then-rm
    fallback: the doc's own Sec 6.2 addendum already flagged this as
    "shell mode has not been wired to it yet" once lib/__arch__ grew a
    portable rename wrapper, so wiring it directly is strictly better
    than the fallback the doc describes, not a scope change. It does
    not special-case an existing-directory destination (real mv's
    "move into" behavior) -- a documented v1 simplification, the same
    shape as ls/cat not distinguishing every errno.
*/
import lib.lib
import lib.stream
import lib.file
import lib.path
import lib.stat


# Print the process's current working directory, like the real pwd.
void pwd():
	int size = 4096
	char* buf = malloc(size)
	if (getcwd(buf, size) < 0):
		println2(c"pwd: cannot determine current directory")
	else:
		println(buf)
	free(buf)


# d_reclen is a little-endian 16-bit field two words after the getdents
# record's ino/off fields -- the same layout tools/wbuildgen.w's
# wbg_load_uint16 and libs/extras/vcs/tree.w read.
int shell_commands_load_uint16(char* p):
	return (p[0] & 255) + ((p[1] & 255) << 8)


# Insertion sort: getdents order depends on filesystem state, and ls's
# output must not (same rationale as tools/wbuildgen.w's
# wbg_sort_strings).
void shell_commands_sort_names(list[char*] names):
	int i = 1
	while (i < names.length):
		char* value = names[i]
		int j = i - 1
		while ((j >= 0) && (strcmp(names[j], value) > 0)):
			names[j + 1] = names[j]
			j = j - 1
		names[j + 1] = value
		i = i + 1


# List path's entries, one name per line, sorted; "." and ".." are
# always skipped, and every other dotfile is skipped too unless all is
# set (bare "ls" vs. "ls -a"). No "-l" -- see the module header.
void ls(char* path, bool all):
	# 65536 = O_DIRECTORY: fails with a negative errno on a non-directory
	# path, same as a missing one -- both read as "cannot access" below.
	int fd = open(path, 65536, 0)
	if (fd < 0):
		print_error(c"ls: cannot access '")
		print_error(path)
		println2(c"': No such file or directory")
		return
	list[char*] names = new list[char*]
	int buffer_size = 65536
	char* buffer = malloc(buffer_size)
	int n = getdents(fd, buffer, buffer_size)
	while (n > 0):
		int off = 0
		while (off < n):
			char* entry = buffer + off
			int reclen = shell_commands_load_uint16(entry + 2 * __word_size__)
			char* entry_name = entry + 2 * __word_size__ + 2
			if ((strcmp(entry_name, c".") != 0) && (strcmp(entry_name, c"..") != 0)):
				if (all || (entry_name[0] != '.')):
					names.push(strclone(entry_name))
			off = off + reclen
		n = getdents(fd, buffer, buffer_size)
	free(buffer)
	close(fd)
	shell_commands_sort_names(names)
	int i = 0
	while (i < names.length):
		println(names[i])
		free(names[i])
		i = i + 1


# Print one path's contents to stdout, binary-safe, no size limit.
# Reports a missing path the way the real cat would ("cat: PATH: No
# such file or directory", to stderr) and moves on to the next path --
# the same per-argument recovery a multi-path real cat invocation gives.
void shell_commands_cat_one(char* path):
	wstream* in = stream_open_read(path)
	if (in == 0):
		print_error(c"cat: ")
		print_error(path)
		println2(c": No such file or directory")
		return
	wstream* out = stdout_writer()
	int buffer_size = 65536
	char* buffer = malloc(buffer_size)
	int n = stream_read(in, buffer, buffer_size)
	while (n > 0):
		stream_write(out, buffer, n)
		n = stream_read(in, buffer, buffer_size)
	free(buffer)
	stream_close(in)
	stream_flush(out)


# Concatenate one or more paths to stdout.
void cat(char*... paths):
	int i = 0
	while (i < paths.length):
		shell_commands_cat_one(paths[i])
		i = i + 1


# Print each word separated by a single space, like the real echo; a
# trailing newline unless no_newline (real echo's "-n"). No filesystem
# primitive needed (design doc Sec 6.2).
void echo(bool no_newline, char*... words):
	int i = 0
	while (i < words.length):
		if (i > 0):
			print(c" ")
		print(words[i])
		i = i + 1
	if (no_newline == 0):
		println(c"")


# First n lines of path (real head's default n is 10). Loads the whole
# file first (design doc Sec 6.2: "a streaming version is a later
# optimization").
void head(char* path, int n):
	list[char*] lines = file_read_lines(path)
	if (lines == 0):
		print_error(c"head: cannot open '")
		print_error(path)
		println2(c"' for reading: No such file or directory")
		return
	int count = lines.length
	if (n < count):
		count = n
	if (count < 0):
		count = 0
	int i = 0
	while (i < count):
		println(lines[i])
		i = i + 1
	i = 0
	while (i < lines.length):
		free(lines[i])
		i = i + 1


# Last n lines of path (real tail's default n is 10).
void tail(char* path, int n):
	list[char*] lines = file_read_lines(path)
	if (lines == 0):
		print_error(c"tail: cannot open '")
		print_error(path)
		println2(c"' for reading: No such file or directory")
		return
	int start = lines.length - n
	if (start < 0):
		start = 0
	int i = start
	while (i < lines.length):
		println(lines[i])
		i = i + 1
	i = 0
	while (i < lines.length):
		free(lines[i])
		i = i + 1


# Line/word/byte counts for path, like the real wc; when none of the
# three are requested (a bare "wc"), all three print, matching real wc's
# default. Lines are counted as '\x0a' bytes (real wc's definition, not
# file_read_lines's line count, which can differ for a file with no
# trailing newline); words are maximal runs of non-space/tab/newline
# bytes.
void wc(char* path, bool count_lines, bool count_words, bool count_bytes):
	char* text = file_read_text(path)
	if (text == 0):
		print_error(c"wc: ")
		print_error(path)
		println2(c": No such file or directory")
		return
	int show_lines = count_lines
	int show_words = count_words
	int show_bytes = count_bytes
	if ((show_lines == 0) && (show_words == 0) && (show_bytes == 0)):
		show_lines = 1
		show_words = 1
		show_bytes = 1
	int length = strlen(text)
	int lines = 0
	int words = 0
	int in_word = 0
	int i = 0
	while (i < length):
		char ch = text[i]
		if (ch == 10):
			lines = lines + 1
		if ((ch == ' ') || (ch == 9) || (ch == 10)):
			in_word = 0
		else:
			if (in_word == 0):
				words = words + 1
			in_word = 1
		i = i + 1
	if (show_lines):
		char* s = itoa(lines)
		print(s)
		print(c" ")
		free(s)
	if (show_words):
		char* s = itoa(words)
		print(s)
		print(c" ")
		free(s)
	if (show_bytes):
		char* s = itoa(length)
		print(s)
		print(c" ")
		free(s)
	println(path)
	free(text)


# Creates every missing ancestor of path (real mkdir -p), stopping at
# an already-existing directory; a raced EEXIST (errno 17) at any level
# is tolerated the same way a real "mkdir -p" tolerates it.
int shell_commands_mkdir_ancestors(char* path):
	if ((path == 0) || (strlen(path) == 0) || (strcmp(path, c"/") == 0) || (strcmp(path, c".") == 0)):
		return 0
	if (path_exists(path)):
		return 0
	char* parent = path_dirname(path)
	int err = shell_commands_mkdir_ancestors(parent)
	free(parent)
	if (err != 0):
		return err
	int r = mkdir(path, 493) /* 493 = 0755 */
	if ((r != 0) && (r != (0 - 17))):
		return r
	return 0


void shell_commands_mkdir_one(char* path, int parents):
	int err = 0
	if (parents):
		err = shell_commands_mkdir_ancestors(path)
	else:
		err = mkdir(path, 493) /* 493 = 0755 */
	if (err != 0):
		print_error(c"mkdir: cannot create directory '")
		print_error(path)
		println2(c"': No such file or directory")


# Create one or more directories, like the real mkdir; parents mirrors
# "-p" (create missing ancestors, and tolerate an already-existing
# target) -- named mkdir_p rather than mkdir; see the module header.
void mkdir_p(bool parents, char*... paths):
	int i = 0
	while (i < paths.length):
		shell_commands_mkdir_one(paths[i], parents)
		i = i + 1


# Removes one path: a file/symlink is unlinked directly (never followed
# -- file_lstat_path, not file_stat_path, exactly like real rm); a
# directory requires recursive, and is then walked with the same
# getdents pattern as ls, deleting children before the now-empty
# directory itself (bottom-up, design doc Sec 6.2). force suppresses a
# missing-path error, matching real "rm -f" -- it does not bypass the
# recursive requirement for a directory, matching real rm too.
void shell_commands_rm_one(char* path, int recursive, int force):
	file_stat st
	int err = file_lstat_path(path, &st)
	if (err != 0):
		if (force == 0):
			print_error(c"rm: cannot remove '")
			print_error(path)
			println2(c"': No such file or directory")
		return
	if (file_is_dir(&st) == 0):
		int u = unlink(path)
		if ((u != 0) && (force == 0)):
			print_error(c"rm: cannot remove '")
			print_error(path)
			println2(c"': No such file or directory")
		return
	if (recursive == 0):
		print_error(c"rm: cannot remove '")
		print_error(path)
		println2(c"': Is a directory")
		return
	int fd = open(path, 65536, 0) /* 65536 = O_DIRECTORY */
	if (fd < 0):
		if (force == 0):
			print_error(c"rm: cannot remove '")
			print_error(path)
			println2(c"': No such file or directory")
		return
	int buffer_size = 65536
	char* buffer = malloc(buffer_size)
	int n = getdents(fd, buffer, buffer_size)
	while (n > 0):
		int off = 0
		while (off < n):
			char* entry = buffer + off
			int reclen = shell_commands_load_uint16(entry + 2 * __word_size__)
			char* entry_name = entry + 2 * __word_size__ + 2
			off = off + reclen
			if ((strcmp(entry_name, c".") != 0) && (strcmp(entry_name, c"..") != 0)):
				char* child = path_join(path, entry_name)
				shell_commands_rm_one(child, recursive, force)
				free(child)
		n = getdents(fd, buffer, buffer_size)
	free(buffer)
	close(fd)
	int r = rmdir(path)
	if ((r != 0) && (force == 0)):
		print_error(c"rm: cannot remove '")
		print_error(path)
		println2(c"': Directory not empty")


# Remove one or more paths, like the real rm.
void rm(bool recursive, bool force, char*... paths):
	int i = 0
	while (i < paths.length):
		shell_commands_rm_one(paths[i], recursive, force)
		i = i + 1


void shell_commands_cp_file(char* src, char* dst):
	wstream* in = stream_open_read(src)
	if (in == 0):
		print_error(c"cp: cannot stat '")
		print_error(src)
		println2(c"': No such file or directory")
		return
	wstream* out = stream_open_write(dst)
	if (out == 0):
		print_error(c"cp: cannot create regular file '")
		print_error(dst)
		println2(c"': No such file or directory")
		stream_close(in)
		return
	int buffer_size = 65536
	char* buffer = malloc(buffer_size)
	int n = stream_read(in, buffer, buffer_size)
	while (n > 0):
		stream_write(out, buffer, n)
		n = stream_read(in, buffer, buffer_size)
	free(buffer)
	stream_close(in)
	stream_close(out)


# src's kind (file/symlink vs. directory) decides a plain stream copy
# vs. a recursive getdents walk creating dst as it goes -- the same
# walk shape rm -r uses, mirrored for copying instead of deleting
# (design doc Sec 6.2: "-r reuses the same recursive walk as rm -r").
# Does not special-case an existing-directory dst; see the module
# header.
void shell_commands_cp_one(char* src, char* dst, int recursive):
	file_stat st
	int err = file_lstat_path(src, &st)
	if (err != 0):
		print_error(c"cp: cannot stat '")
		print_error(src)
		println2(c"': No such file or directory")
		return
	if (file_is_dir(&st) == 0):
		shell_commands_cp_file(src, dst)
		return
	if (recursive == 0):
		print_error(c"cp: -r not specified; omitting directory '")
		print_error(src)
		println2(c"'")
		return
	int made = mkdir(dst, 493) /* 493 = 0755 */
	if ((made != 0) && (made != (0 - 17))):
		print_error(c"cp: cannot create directory '")
		print_error(dst)
		println2(c"': No such file or directory")
		return
	int fd = open(src, 65536, 0) /* 65536 = O_DIRECTORY */
	if (fd < 0):
		print_error(c"cp: cannot stat '")
		print_error(src)
		println2(c"': No such file or directory")
		return
	int buffer_size = 65536
	char* buffer = malloc(buffer_size)
	int n = getdents(fd, buffer, buffer_size)
	while (n > 0):
		int off = 0
		while (off < n):
			char* entry = buffer + off
			int reclen = shell_commands_load_uint16(entry + 2 * __word_size__)
			char* entry_name = entry + 2 * __word_size__ + 2
			off = off + reclen
			if ((strcmp(entry_name, c".") != 0) && (strcmp(entry_name, c"..") != 0)):
				char* child_src = path_join(src, entry_name)
				char* child_dst = path_join(dst, entry_name)
				shell_commands_cp_one(child_src, child_dst, recursive)
				free(child_src)
				free(child_dst)
		n = getdents(fd, buffer, buffer_size)
	free(buffer)
	close(fd)


# Copy src to dst, like the real cp; recursive mirrors "-r" (copy a
# directory's contents instead of failing on it).
void cp(bool recursive, char* src, char* dst):
	shell_commands_cp_one(src, dst, recursive)


# Move/rename src to dst via rename(2) directly -- atomic within one
# filesystem; see the module header for why this differs from the
# design doc's original cp-then-rm sketch.
void mv(char* src, char* dst):
	int err = rename(src, dst)
	if (err != 0):
		print_error(c"mv: cannot move '")
		print_error(src)
		print_error(c"' to '")
		print_error(dst)
		println2(c"': No such file or directory")
