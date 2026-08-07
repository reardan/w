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

Stage 1 scope (design doc Sec 11): pwd (zero-arg), ls (bare and -a;
-l arrived in stage 3 below once lib/stat.w existed), cat (one or more
paths, no flags). ls's directory walk uses the same getdents(2) record
layout tools/wbuildgen.w and libs/extras/vcs/tree.w read -- x86/x64
only, matching repl.w's own arch scope (Sec 6.2).

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

Stage 3 (design doc Sec 11's "stage 3+" items the lib/stat.w wrapper
unblocked): ls's -l long listing, touch, chmod, du. Notes:

  - ls -l lines are single-space separated with no column padding (the
    same v1 output simplification as wc's counts), print owner/group
    names via lib/passwd.w's /etc/passwd//etc/group lookup (numeric
    fallback when an id has no entry), stamp mtime as UTC
    "YYYY-MM-DD HH:MM" (real ls prints local time; this tree has no
    timezone database -- the shape matches "ls --time-style=long-iso"
    under TZ=UTC), and print no "total" header line. The
    setuid/setgid/sticky bits are not rendered into the x positions,
    and non-dir/symlink specials (block/char/fifo/socket) all show '-'.
  - The shell command "chmod" is implemented as chmod_octal, the same
    flat-symbol-table collision mkdir_p documents above: lib.linux's
    import closure already declares the raw chmod(2) syscall wrapper.
    Octal modes only -- repl/shell_translate.w fails symbolic modes
    ("u+x") closed to the real binary.
  - du sums statx stx_blocks (512-byte units, the same figure real du
    sums -- via lib/stat.w's file_stat.blocks, added for this) and
    prints 1024-byte units, per-directory post-order like the real
    tool. Hard links are counted once per link rather than once per
    inode -- a documented v1 simplification.

Stage 4 (design doc Sec 11's "stage 4+" items): ln -s, df, ps, and --
now that lib/regex.w exists as the reusable pattern core Sec 6.3
waited for -- grep. Notes:

  - The shell command "ln" is implemented as ln_s and creates symbolic
    links only: a bare "ln" (a hard link) has no link(2) wrapper in
    lib/ and stays with the real tool via the translator's fail-closed
    rule, and the name says so (the same
    restricted-scope-in-the-name spirit as chmod_octal, though here
    nothing collides -- the raw syscall wrapper is "symlink").
  - df reads f_bsize-block counts through lib/stat.w's file_statfs
    (statfs(2), added for this) and prints 1024-byte units:
    "Filesystem 1K-blocks Used Available Mounted on", single-space
    columns like ls -l's. Used is blocks - bfree (root-reserved blocks
    count as used, like real df); Available is bavail. With no
    arguments every /proc/mounts entry with a nonzero block count
    prints; with path arguments one line per path, resolving the
    owning mount by device-id match against /proc/mounts (first match
    wins on a shared device; "-" when no mount matches). /proc/mounts
    octal escapes (\040) are not decoded -- a documented v1
    simplification. On 32-bit targets the 1K-unit product can exceed
    the word for a multi-TB filesystem, the same accepted limit
    lib/stat.w documents.
  - ps walks /proc/[0-9]*, reads each pid's /proc/PID/stat, and prints
    "PID PPID S COMM" lines sorted by pid -- comm parsed between the
    first '(' and the LAST ')' (comm itself may contain spaces or
    parentheses), state and ppid from the two fields after. No flags:
    "ps aux"/"ps -ef" are real-ps territory and fail closed to native.
  - grep matches with lib/regex.w's documented subset (see that
    module's header): literals, '.', [...] classes, backslash escapes,
    ^/$ anchors, greedy */+/? quantifiers -- NOT the real grep's BRE
    (where + and ? are literals), a deliberate divergence the design
    doc records. Output mirrors the real tool: matching lines, a
    "path:" prefix only for multi-file invocations, "-n" line numbers.
    Patterns lib/regex.w cannot run (\d, a**, an unclosed class) fail
    the translator's recognition test and run the real grep instead.
*/
import lib.lib
import lib.stream
import lib.file
import lib.path
import lib.stat
import lib.time
import lib.passwd
import lib.regex


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


# st_mode -> the 10-character "drwxr-xr-x" display string (type char +
# nine permission bits) written into out, which needs room for 11
# bytes. Directories show 'd', symlinks 'l', everything else '-', and
# the setuid/setgid/sticky bits are not rendered -- see the module
# header.
void shell_commands_mode_string(int mode, char* out):
	int kind = mode & FILE_S_IFMT()
	out[0] = '-'
	if (kind == FILE_S_IFDIR()):
		out[0] = 'd'
	if (kind == FILE_S_IFLNK()):
		out[0] = 'l'
	char* letters = c"rwxrwxrwx"
	int i = 0
	while (i < 9):
		if (mode & (256 >> i)):
			out[i + 1] = letters[i]
		else:
			out[i + 1] = '-'
		i = i + 1
	out[10] = 0


# Owner or group display name: the /etc/passwd//etc/group entry when
# one exists (lib/passwd.w), else the numeric id -- the same fallback
# real ls uses for an unmapped id. Always malloc'd; caller frees.
char* shell_commands_id_name(char* name, int id):
	if (name != 0):
		return name
	return itoa(id)


# One "ls -l" line for entry_name inside dir: mode string, link count,
# owner, group, size, UTC mtime to the minute, name, and " -> target"
# for a symlink. Format notes (single-space columns, UTC long-iso
# stamp, name-lookup fallback) are in the module header.
void shell_commands_ls_long_entry(char* dir, char* entry_name):
	char* full = path_join(dir, entry_name)
	file_stat st
	int err = file_lstat_path(full, &st)
	if (err != 0):
		print_error(c"ls: cannot access '")
		print_error(full)
		println2(c"': No such file or directory")
		free(full)
		return
	char* mode_str = malloc(11)
	shell_commands_mode_string(st.mode, mode_str)
	print(mode_str)
	free(mode_str)
	print(c" ")
	char* nlink_str = itoa(st.nlink)
	print(nlink_str)
	free(nlink_str)
	print(c" ")
	char* owner = shell_commands_id_name(passwd_uid_name(st.uid), st.uid)
	print(owner)
	free(owner)
	print(c" ")
	char* group = shell_commands_id_name(passwd_gid_name(st.gid), st.gid)
	print(group)
	free(group)
	print(c" ")
	char* size_str = itoa(st.size)
	print(size_str)
	free(size_str)
	print(c" ")
	# time_utc_from_unix asserts on negative stamps (i386's 32-bit
	# time_t past 2038, or a deliberately bogus mtime); clamp to the
	# epoch instead of taking the whole REPL session down.
	int mtime = st.mtime
	if (mtime < 0):
		mtime = 0
	char* stamp = time_format_unix_utc(mtime)
	stamp[16] = 0 /* "YYYY-MM-DD HH:MM:SS" cut to the minute */
	print(stamp)
	free(stamp)
	print(c" ")
	print(entry_name)
	if (file_is_lnk(&st)):
		int target_size = 4096
		char* target = malloc(target_size)
		int n = file_readlink(full, target, target_size - 1)
		if (n >= 0):
			target[n] = 0
			print(c" -> ")
			print(target)
		free(target)
	println(c"")
	free(full)


# List path's entries, one name per line, sorted; "." and ".." are
# always skipped, and every other dotfile is skipped too unless all is
# set (bare "ls" vs. "ls -a"). long_format is "-l": one metadata line
# per entry (shell_commands_ls_long_entry above) instead of the bare
# name, with no "total" header line -- see the module header.
void ls(char* path, bool all, bool long_format):
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
		if (long_format):
			shell_commands_ls_long_entry(path, names[i])
		else:
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
# bytes. Reads through a stream directly (not file_read_text) so the
# true byte count is known: deriving it with strlen would stop at the
# first NUL byte and truncate every figure for a binary file.
void wc(char* path, bool count_lines, bool count_words, bool count_bytes):
	wstream* in = stream_open_read(path)
	if (in == 0):
		print_error(c"wc: ")
		print_error(path)
		println2(c": No such file or directory")
		return
	string_builder* contents = string_new()
	stream_read_all(in, contents)
	stream_close(in)
	# Ownership transfer: take .data and .length, free only the wrapper
	# (the string_builder_to_string idiom).
	int length = contents.length
	char* text = contents.data
	free(contents)
	int show_lines = count_lines
	int show_words = count_words
	int show_bytes = count_bytes
	if ((show_lines == 0) && (show_words == 0) && (show_bytes == 0)):
		show_lines = 1
		show_words = 1
		show_bytes = 1
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


# Update one path's atime/mtime to now (lib/stat.w's file_touch,
# utimensat(2) under the hood), creating a missing path as an empty
# file unless no_create -- with no_create a missing path is silent
# success, exactly like the real "touch -c".
void shell_commands_touch_one(char* path, int no_create):
	int create = 1
	if (no_create):
		create = 0
	int err = file_touch(path, create)
	if (err == 0):
		return
	if (no_create && (err == (0 - 2))): /* ENOENT under -c: silent */
		return
	print_error(c"touch: cannot touch '")
	print_error(path)
	println2(c"': No such file or directory")


# Update timestamps of (or create) one or more paths, like the real
# touch; no_create mirrors "-c".
void touch(bool no_create, char*... paths):
	int i = 0
	while (i < paths.length):
		shell_commands_touch_one(paths[i], no_create)
		i = i + 1


# Set each path's permission bits to mode, like "chmod OCTAL path...".
# Octal modes only, and named chmod_octal rather than chmod -- see the
# module header for both.
void chmod_octal(int mode, char*... paths):
	int i = 0
	while (i < paths.length):
		int err = file_chmod(paths[i], mode)
		if (err != 0):
			print_error(c"chmod: cannot access '")
			print_error(paths[i])
			println2(c"': No such file or directory")
		i = i + 1


# Cumulative allocated blocks (512-byte units, statx stx_blocks --
# what real du sums) under path, printing "N<TAB>path" lines in
# 1024-byte units on the way back up: every directory post-order
# (children before parent, real du's own order) unless summarize,
# plus always the top-level argument itself. Files below the top
# contribute silently. Symlinks are never followed (file_lstat_path),
# matching real du.
int shell_commands_du_walk(char* path, int summarize, int top):
	file_stat st
	int err = file_lstat_path(path, &st)
	if (err != 0):
		print_error(c"du: cannot access '")
		print_error(path)
		println2(c"': No such file or directory")
		return 0
	int total = st.blocks
	int is_dir = file_is_dir(&st)
	if (is_dir):
		int fd = open(path, 65536, 0) /* 65536 = O_DIRECTORY */
		if (fd >= 0):
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
						total = total + shell_commands_du_walk(child, summarize, 0)
						free(child)
				n = getdents(fd, buffer, buffer_size)
			free(buffer)
			close(fd)
	if ((top != 0) || ((is_dir != 0) && (summarize == 0))):
		char* count = itoa((total + 1) / 2) /* 512 -> 1024-byte units, rounded up */
		print(count)
		free(count)
		print(c"\x09")
		println(path)
	return total


# Disk usage of path, like the real du: per-directory cumulative
# 1K-unit totals, post-order; summarize mirrors "-s" (only path's own
# total). Hard links count once per link -- see the module header.
void du(bool summarize, char* path):
	shell_commands_du_walk(path, summarize, 1)


# Create a symbolic link at linkpath pointing to target (real
# "ln -s TARGET LINK_NAME"). Symlinks only -- see the module header
# for the name and for why hard links stay native.
void ln_s(char* target, char* linkpath):
	int err = file_symlink(target, linkpath)
	if (err == 0):
		return
	print_error(c"ln: failed to create symbolic link '")
	print_error(linkpath)
	if (err == (0 - 17)): /* EEXIST */
		println2(c"': File exists")
	else:
		println2(c"': No such file or directory")


# The index-th (0-based) space/tab-separated field of line, cloned, or
# 0 when the line has fewer fields. /proc/mounts octal escapes (\040
# for a space inside a mount path) are not decoded -- see the module
# header.
char* shell_commands_field(char* line, int index):
	int i = 0
	int field = 0
	while (line[i] != 0):
		while ((line[i] == ' ') || (line[i] == 9)):
			i = i + 1
		if (line[i] == 0):
			return 0
		if (field == index):
			string_builder* out = string_new()
			while ((line[i] != 0) && (line[i] != ' ') && (line[i] != 9)):
				string_append_char(out, line[i])
				i = i + 1
			char* s = out.data
			free(out)
			return s
		while ((line[i] != 0) && (line[i] != ' ') && (line[i] != 9)):
			i = i + 1
		field = field + 1
	return 0


# count blocks of bsize bytes -> 1024-byte units. bsize is a power of
# two on every real filesystem; on 32-bit targets the product can
# exceed the word for a multi-TB filesystem (module header).
int shell_commands_df_kunits(int count, int bsize):
	if (bsize >= 1024):
		return count * (bsize / 1024)
	if (bsize <= 0):
		return 0
	return count / (1024 / bsize)


# One "source total used avail mount" df line from a successful
# statfs; see the module header for the column semantics.
void shell_commands_df_line(char* source, char* mount, file_fs_stat* fs):
	print(source)
	print(c" ")
	char* total = itoa(shell_commands_df_kunits(fs.blocks, fs.bsize))
	print(total)
	free(total)
	print(c" ")
	char* used = itoa(shell_commands_df_kunits(fs.blocks - fs.bfree, fs.bsize))
	print(used)
	free(used)
	print(c" ")
	char* avail = itoa(shell_commands_df_kunits(fs.bavail, fs.bsize))
	print(avail)
	free(avail)
	print(c" ")
	println(mount)


# df with no arguments: every /proc/mounts entry whose filesystem
# reports a nonzero block count (the pseudo filesystems -- proc,
# sysfs, cgroup -- report zero and are skipped, like real df's
# dummy-filesystem hiding).
void shell_commands_df_all():
	list[char*] lines = file_read_lines(c"/proc/mounts")
	if (lines == 0):
		println2(c"df: cannot read /proc/mounts")
		return
	file_fs_stat fs
	int i = 0
	while (i < lines.length):
		char* source = shell_commands_field(lines[i], 0)
		char* mount = shell_commands_field(lines[i], 1)
		if ((source != 0) && (mount != 0)):
			if (file_statfs(mount, &fs) == 0):
				if (fs.blocks > 0):
					shell_commands_df_line(source, mount, &fs)
		if (source != 0):
			free(source)
		if (mount != 0):
			free(mount)
		free(lines[i])
		i = i + 1


# df for one explicit path argument: statfs the path itself for the
# numbers, then resolve which mount it lives on by matching the path's
# device id against each /proc/mounts entry's mount point (bind mounts
# repeat a device; the first match wins -- a documented
# simplification). When no mount matches, the source column shows "-"
# and the path itself stands in for the mount point.
void shell_commands_df_path(char* path):
	file_fs_stat fs
	if (file_statfs(path, &fs) != 0):
		print_error(c"df: ")
		print_error(path)
		println2(c": No such file or directory")
		return
	char* source = 0
	char* mount = 0
	file_stat st
	file_stat mount_st
	if (file_stat_path(path, &st) == 0):
		list[char*] lines = file_read_lines(c"/proc/mounts")
		if (lines != 0):
			int i = 0
			while (i < lines.length):
				if (mount == 0):
					char* entry_source = shell_commands_field(lines[i], 0)
					char* entry_mount = shell_commands_field(lines[i], 1)
					int matched = 0
					if ((entry_source != 0) && (entry_mount != 0)):
						if (file_stat_path(entry_mount, &mount_st) == 0):
							if (mount_st.dev == st.dev):
								source = entry_source
								mount = entry_mount
								matched = 1
					if (matched == 0):
						if (entry_source != 0):
							free(entry_source)
						if (entry_mount != 0):
							free(entry_mount)
				free(lines[i])
				i = i + 1
	if (mount == 0):
		shell_commands_df_line(c"-", path, &fs)
	else:
		shell_commands_df_line(source, mount, &fs)
		free(source)
		free(mount)


# Filesystem free-space report, like the real df: a header line, then
# one line per mount (no arguments) or per path argument. Columns and
# simplifications are in the module header.
void df(char*... paths):
	println(c"Filesystem 1K-blocks Used Available Mounted on")
	if (paths.length == 0):
		shell_commands_df_all()
		return
	int i = 0
	while (i < paths.length):
		shell_commands_df_path(paths[i])
		i = i + 1


int shell_commands_all_digits(char* s):
	if (s[0] == 0):
		return 0
	int i = 0
	while (s[i] != 0):
		if ((s[i] < '0') || (s[i] > '9')):
			return 0
		i = i + 1
	return 1


# Insertion sort for the collected pids: getdents order over /proc is
# usually numeric already, but is filesystem state, and ps's output
# must not depend on it (shell_commands_sort_names' rationale).
void shell_commands_sort_ints(list[int] values):
	int i = 1
	while (i < values.length):
		int value = values[i]
		int j = i - 1
		while ((j >= 0) && (values[j] > value)):
			values[j + 1] = values[j]
			j = j - 1
		values[j + 1] = value
		i = i + 1


# One "pid ppid state comm" line from /proc/PID/stat. comm sits
# between the first '(' and the LAST ')' -- comm itself may contain
# spaces or parentheses -- and state/ppid are the two fields after. A
# pid that vanished between the /proc walk and this read (or a
# malformed stat line) is skipped silently, like the real ps racing
# process exit.
void shell_commands_ps_line(int pid):
	char* pid_str = itoa(pid)
	char* base = strjoin(c"/proc/", pid_str)
	char* stat_path = strjoin(base, c"/stat")
	free(base)
	char* text = file_read_text(stat_path)
	free(stat_path)
	if (text == 0):
		free(pid_str)
		return
	int lp = -1
	int rp = -1
	int i = 0
	while (text[i] != 0):
		if ((text[i] == '(') && (lp < 0)):
			lp = i
		if (text[i] == ')'):
			rp = i
		i = i + 1
	if ((lp < 0) || (rp <= lp) || (text[rp + 1] != ' ')):
		free(text)
		free(pid_str)
		return
	char state = text[rp + 2]
	if ((state == 0) || (state == ' ') || (state == 10)):
		free(text)
		free(pid_str)
		return
	int k = rp + 3
	while (text[k] == ' '):
		k = k + 1
	string_builder* ppid = string_new()
	while ((text[k] >= '0') && (text[k] <= '9')):
		string_append_char(ppid, text[k])
		k = k + 1
	if (ppid.length == 0):
		string_free(ppid)
		free(text)
		free(pid_str)
		return
	print(pid_str)
	print(c" ")
	print(ppid.data)
	print(c" ")
	put_char(state)
	print(c" ")
	text[rp] = 0
	println(text + lp + 1)
	string_free(ppid)
	free(text)
	free(pid_str)


# Process listing, like a bare real ps but for every process: walks
# /proc's numeric entries and prints "PID PPID S COMM" lines sorted by
# pid. No flags -- see the module header.
void ps():
	int fd = open(c"/proc", 65536, 0) /* 65536 = O_DIRECTORY */
	if (fd < 0):
		println2(c"ps: cannot access /proc")
		return
	list[int] pids = new list[int]
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
			if (shell_commands_all_digits(entry_name)):
				pids.push(atoi(entry_name))
		n = getdents(fd, buffer, buffer_size)
	free(buffer)
	close(fd)
	shell_commands_sort_ints(pids)
	println(c"PID PPID S COMM")
	int i = 0
	while (i < pids.length):
		shell_commands_ps_line(pids[i])
		i = i + 1


# Print path's lines matching pattern; with_name prefixes "path:"
# (multi-file invocations, like the real tool) and line_numbers adds
# real grep's "-n" "N:" prefix (1-based). A missing path reports and
# moves on, cat's per-argument recovery.
void shell_commands_grep_one(char* pattern, char* path, int with_name, int line_numbers):
	list[char*] lines = file_read_lines(path)
	if (lines == 0):
		print_error(c"grep: ")
		print_error(path)
		println2(c": No such file or directory")
		return
	int i = 0
	while (i < lines.length):
		if (regex_search(pattern, lines[i]) >= 0):
			if (with_name):
				print(path)
				print(c":")
			if (line_numbers):
				char* number = itoa(i + 1)
				print(number)
				free(number)
				print(c":")
			println(lines[i])
		free(lines[i])
		i = i + 1


# Print lines matching pattern in one or more files, via lib/regex.w's
# documented pattern subset (module header: deliberately not the real
# grep's BRE). line_numbers mirrors "-n"; the "path:" prefix appears
# exactly when more than one file was named, like the real tool. A
# pattern lib/regex.w rejects reports one error and prints nothing --
# the shell-mode translator already fails such lines closed to the
# real grep, so only a direct W-mode caller sees it.
void grep(bool line_numbers, char* pattern, char*... paths):
	if (regex_valid(pattern) == 0):
		print_error(c"grep: invalid pattern: '")
		print_error(pattern)
		println2(c"'")
		return
	int with_name = 0
	if (paths.length > 1):
		with_name = 1
	int i = 0
	while (i < paths.length):
		shell_commands_grep_one(pattern, paths[i], with_name, line_numbers)
		i = i + 1
