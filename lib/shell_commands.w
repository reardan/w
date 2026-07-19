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
*/
import lib.lib
import lib.stream


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
