/*
Shell-style pattern matching (Python's fnmatch) and pathname expansion
(Python's glob.glob with recursive=True).

fnmatch_match(name, pattern) follows fnmatch.fnmatchcase: matching is
always case-sensitive (POSIX normcase is the identity) and '/' is an
ordinary character, so '*' and '?' match it.

	*        any run of characters, including the empty one
	?        any single character
	[seq]    any character in seq; ranges like a-z; ']' first is literal
	[!seq]   any character not in seq
	BS c     the character c literally, BS being a backslash (outside
	         brackets; a trailing backslash is literal)

A '[' without a closing ']' is a literal '['. A reversed range (z-a)
matches nothing. Characters compare as unsigned bytes.

glob_glob(pattern) expands pattern against the filesystem the way
glob.glob(pattern, recursive=True) does, then sorts the result:

- a path segment that is exactly "**" matches zero or more directories
  (and, as the last segment, every file and directory below);
- names starting with '.' are only matched by a segment pattern that
  itself starts with '.' (or an escaped dot), and "**" never descends into them;
- a pattern ending in '/' matches only directories;
- segments without magic are checked with lstat, so a dangling symlink
  still matches a literal name.

Divergences from Python, documented on purpose:

- Backslash escapes a character outside brackets (fnmatch(3) style).
  Python's fnmatch treats a backslash literally; glob_escape uses the bracket
  form Python uses, so its output means the same thing in both.
- The result is sorted (byte order); Python's order is the directory
  order. Duplicates Python would produce (a pattern with two "**"
  segments in a row) are kept.
- "**" follows symlinks to directories like Python does; a symlink
  cycle ends when the kernel reports ELOOP, as it does for Python.

Free a result list with glob_free. Design notes:
libs/standard/plans/05_filesystem.md (Phase 4).
*/
import lib.lib
import lib.path
import lib.dir
import lib.stat


# ---- fnmatch -------------------------------------------------------------


# Index of the ']' closing the bracket expression that opens at
# pattern[i] (== '['), or -1 when there is none (then '[' is literal).
int fnmatch_bracket_end(char* pattern, int i, int plen):
	int j = i + 1
	if ((j < plen) && (pattern[j] == '!')): j = j + 1
	if ((j < plen) && (pattern[j] == ']')): j = j + 1
	while ((j < plen) && (pattern[j] != ']')): j = j + 1
	if (j >= plen): return -1
	return j


# Whether byte ch is in the bracket expression pattern[i..end].
int fnmatch_bracket_has(char* pattern, int i, int end, int ch):
	int k = i + 1
	int negate = 0
	if (pattern[k] == '!'):
		negate = 1
		k = k + 1
	int found = 0
	while (k < end):
		int lo = pattern[k] & 255
		if ((k + 2 < end) && (pattern[k + 1] == '-')):
			int hi = pattern[k + 2] & 255
			if ((lo <= ch) && (ch <= hi)): found = 1
			k = k + 3
		else:
			if (lo == ch): found = 1
			k = k + 1
	if (negate): return !found
	return found


# Matches one non-'*' pattern item at pattern[pi] against byte ch.
# Returns the index after the item, or -1 on a mismatch.
int fnmatch_match_one(char* pattern, int pi, int plen, int ch):
	int c = pattern[pi] & 255
	if (c == '?'): return pi + 1
	if (c == '['):
		int end = fnmatch_bracket_end(pattern, pi, plen)
		if (end >= 0):
			if (fnmatch_bracket_has(pattern, pi, end, ch)): return end + 1
			return -1
	if ((c == '\\') && (pi + 1 < plen)):
		if ((pattern[pi + 1] & 255) == ch): return pi + 2
		return -1
	if (c == ch): return pi + 1
	return -1


# Python's fnmatch.fnmatchcase(name, pattern), plus backslash escapes.
# Returns 1 when name matches pattern, else 0.
int fnmatch_match(char* name, char* pattern):
	int plen = strlen(pattern)
	int nlen = strlen(name)
	int pi = 0
	int ni = 0
	int star_p = -1
	int star_n = 0
	while (ni < nlen):
		if ((pi < plen) && (pattern[pi] == '*')):
			while ((pi < plen) && (pattern[pi] == '*')): pi = pi + 1
			star_p = pi
			star_n = ni
			continue
		if (pi < plen):
			int next = fnmatch_match_one(pattern, pi, plen, name[ni] & 255)
			if (next >= 0):
				pi = next
				ni = ni + 1
				continue
		if (star_p < 0): return 0
		star_n = star_n + 1
		ni = star_n
		pi = star_p
	while ((pi < plen) && (pattern[pi] == '*')): pi = pi + 1
	return pi == plen


# Copies of the names that match pattern (Python's fnmatch.filter), in
# input order. Free with glob_free.
list[char*] fnmatch_filter(list[char*] names, char* pattern):
	list[char*] out = new list[char*]
	for char* name in names:
		if (fnmatch_match(name, pattern)): out.push(strclone(name))
	return out


# ---- glob ----------------------------------------------------------------


# Frees a list returned by glob_glob or fnmatch_filter (and its strings).
void glob_free(list[char*] results):
	if (results == 0): return
	for char* s in results: free(s)
	list_free[char*](results)


# Whether s contains a character fnmatch_match treats specially.
int glob_has_magic(char* s):
	int i = 0
	while (s[i] != 0):
		int c = s[i]
		if ((c == '*') || (c == '?') || (c == '[') || (c == '\\')): return 1
		i = i + 1
	return 0


# path with every magic character wrapped in brackets ("[*]"), so it
# matches only itself (Python's glob.escape; a backslash becomes the
# three bytes [, backslash, ]).
char* glob_escape(char* path):
	int n = strlen(path)
	char* out = cast(char*, malloc(n * 3 + 1))
	int i = 0
	int o = 0
	while (i < n):
		char c = path[i]
		if ((c == '*') || (c == '?') || (c == '[') || (c == '\\')):
			out[o] = '['
			out[o + 1] = c
			out[o + 2] = ']'
			o = o + 3
		else:
			out[o] = c
			o = o + 1
		i = i + 1
	out[o] = 0
	return out


# posixpath.join(a, b) for two parts (owned result).
char* glob_join(char* a, char* b):
	if ((b[0] == '/') || (a[0] == 0)): return strclone(b)
	int n = strlen(a)
	if (a[n - 1] == '/'): return strjoin(a, b)
	char* tmp = strjoin(a, c"/")
	char* joined = strjoin(tmp, b)
	free(tmp)
	return joined


# posixpath.split: *dir_out gets the head (trailing slashes removed
# unless it is all slashes), *base_out the tail; both owned.
void glob_split(char* p, char** dir_out, char** base_out):
	int n = strlen(p)
	int i = n
	while ((i > 0) && (p[i - 1] != '/')): i = i - 1
	base_out[0] = strclone(&p[i])
	int head = i
	while ((head > 0) && (p[head - 1] == '/')): head = head - 1
	if (head == 0): head = i
	dir_out[0] = path_clone_range(p, head)


int glob_is_dir(char* path):
	if (path[0] == 0): return 0
	file_stat* st = new file_stat
	int status = file_stat_path(path, st)
	int result = 0
	if (status == 0): result = file_is_dir(st)
	free(st)
	if (status == 0): return result
	# No stat on this target (or a missing path): ask the directory
	# layer instead.
	list[dir_entry*] entries = dir_read(path)
	if (entries == 0): return 0
	dir_entries_free(entries)
	return 1


# os.path.lexists: a dangling symlink exists.
int glob_lexists(char* path):
	if (path[0] == 0): return 0
	file_stat* st = new file_stat
	int status = file_lstat_path(path, st)
	free(st)
	if (status == 0): return 1
	return path_exists(path)


int glob_is_hidden(char* name):
	return (name[0] == '.') || ((name[0] == '\\') && (name[1] == '.'))


# The entries of dir ("" = the current directory), or only those that
# are directories (following symlinks) when dironly. Never 0.
list[dir_entry*] glob_listdir(char* dir, int dironly):
	char* where = dir
	if (dir[0] == 0): where = c"."
	list[dir_entry*] entries = dir_read(where)
	if (entries == 0): return new list[dir_entry*]
	if (!dironly): return entries
	list[dir_entry*] kept = new list[dir_entry*]
	for dir_entry* e in entries:
		int keep = 0
		if (e.kind == DIR_KIND_DIR): keep = 1
		else if (e.kind != DIR_KIND_FILE):
			char* child = glob_join(where, e.name)
			keep = glob_is_dir(child)
			free(child)
		if (keep): kept.push(e)
		else:
			free(e.name)
			free(e)
	list_free[dir_entry*](entries)
	return kept


# Python's _glob1: names in dir matching a magic segment pattern.
void glob_one(char* dir, char* pattern, int dironly, list[char*] out):
	list[dir_entry*] entries = glob_listdir(dir, dironly)
	int hidden_ok = glob_is_hidden(pattern)
	for dir_entry* e in entries:
		if ((hidden_ok || !glob_is_hidden(e.name)) && fnmatch_match(e.name, pattern)):
			out.push(strclone(e.name))
	dir_entries_free(entries)


# Python's _glob0: a literal segment (or "" for a trailing slash).
void glob_zero(char* dir, char* basename, int dironly, list[char*] out):
	if (basename[0] != 0):
		char* full = glob_join(dir, basename)
		if (glob_lexists(full)): out.push(strclone(basename))
		free(full)
	else if (glob_is_dir(dir)): out.push(strclone(c""))


# Python's _rlistdir: every non-hidden path below dir, as prefix/<rel>.
void glob_rlistdir(char* dir, char* prefix, int dironly, list[char*] out):
	list[dir_entry*] entries = glob_listdir(dir, dironly)
	for dir_entry* e in entries:
		if (!glob_is_hidden(e.name)):
			char* rel = glob_join(prefix, e.name)
			out.push(rel)
			if (e.kind != DIR_KIND_FILE):
				char* where = glob_join(dir, e.name)
				glob_rlistdir(where, rel, dironly, out)
				free(where)
	dir_entries_free(entries)


# Python's _glob2: "" for dir itself, then everything below it.
void glob_two(char* dir, int dironly, list[char*] out):
	if ((dir[0] == 0) || glob_is_dir(dir)): out.push(strclone(c""))
	glob_rlistdir(dir, c"", dironly, out)


# Python's _iglob with recursive=True, appending owned paths to out.
void glob_expand(char* pattern, int dironly, list[char*] out):
	char* dirname = 0
	char* basename = 0
	glob_split(pattern, &dirname, &basename)
	if (!glob_has_magic(pattern)):
		if (basename[0] != 0):
			if (glob_lexists(pattern)): out.push(strclone(pattern))
		else if (glob_is_dir(dirname)): out.push(strclone(pattern))
		free(dirname)
		free(basename)
		return
	int recursive = strcmp(basename, c"**") == 0
	if (dirname[0] == 0):
		if (recursive): glob_two(c"", dironly, out)
		else: glob_one(c"", basename, dironly, out)
		free(dirname)
		free(basename)
		return
	list[char*] dirs = new list[char*]
	if ((strcmp(dirname, pattern) != 0) && glob_has_magic(dirname)): glob_expand(dirname, 1, dirs)
	else: dirs.push(strclone(dirname))
	int basename_magic = glob_has_magic(basename)
	for char* d in dirs:
		list[char*] names = new list[char*]
		if (!basename_magic): glob_zero(d, basename, dironly, names)
		else if (recursive): glob_two(d, dironly, names)
		else: glob_one(d, basename, dironly, names)
		for char* name in names:
			out.push(glob_join(d, name))
			free(name)
		list_free[char*](names)
	glob_free(dirs)
	free(dirname)
	free(basename)


# The paths matching pattern, sorted; an empty list when nothing
# matches. Python's glob.glob(pattern, recursive=True) apart from the
# order (see the header). Free with glob_free.
list[char*] glob_glob(char* pattern):
	list[char*] raw = new list[char*]
	glob_expand(pattern, 0, raw)
	list[char*] out = raw
	if (strcmp(pattern, c"**") == 0):
		# glob("**") skips the "" that stands for the current directory.
		out = new list[char*]
		for char* s in raw:
			if (s[0] == 0): free(s)
			else: out.push(s)
		list_free[char*](raw)
	out.sort()
	return out
